package render

import stbi "vendor:stb/image"
import vk "vendor:vulkan"
import "core:path/filepath"
import "core:time"
import "core:mem"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:os"
import "base:runtime"

CAPTURE_DIR :: #config(CAPTURE_DIR, ".")
NUM_CHANNELS :: 4
g_ffmpeg_quality: i32 = 20

Recorder :: struct {
    process:                os.Process,
    pipe:                   ^os.File,
    framerate:              i32,
    recording:              bool,
    screenshot_requested:   bool,
    resolution:             [2]u32,
    capture_buffers:        []Buffer,
}

recorder_initialize :: proc(renderer: ^Renderer, recorder: ^Recorder) {
    recorder^ = {
        recording = false,
        screenshot_requested = false,
        framerate = renderer.window.glfw_mode.refresh_rate, // By default
        resolution = { renderer.draw_image.extent.width, renderer.draw_image.extent.height }
    }
    recorder.capture_buffers = make([]Buffer, renderer.frames_in_flight)
    buffer_size := image_get_size(renderer.draw_image.extent)
    for &buffer in recorder.capture_buffers {
        buffer = buffer_create(renderer, buffer_size, 1, { .TRANSFER_DST }, .GPU_TO_CPU)
    }
}

recorder_destroy :: proc(renderer: ^Renderer, recorder: ^Recorder) {
    for &buffer in recorder.capture_buffers {
        buffer_destroy(renderer, &buffer)
    }
    delete(recorder.capture_buffers)
    recorder^ = {}
}

recorder_resize_buffers :: proc(renderer: ^Renderer, recorder: ^Recorder) {
    new_size := image_get_size(renderer.draw_image.extent)
    for &buffer in recorder.capture_buffers {
        buffer_destroy(renderer, &buffer)
        buffer = buffer_create(renderer, new_size, 1, { .TRANSFER_DST }, .GPU_TO_CPU)
    }
}

@(private)
capture_get_output_filename :: proc(filename: string, extension: string, allocator: runtime.Allocator) -> string {
    right_now := time.now()
    hour, min, sec, nanos := time.precise_clock_from_time(right_now)
    year, month, day := time.date(right_now)
    return fmt.aprintf("%s-%d-%2d-%2d_%2d:%2d:%2d:%9d%s", filename, year, month, day, hour, min, sec, nanos, extension, allocator=allocator)
}

capture_request_screenshot :: proc(renderer: ^Renderer) {
    if !renderer.capturing_primed do return
    renderer.recorder.screenshot_requested = true
}

// Map the capture_buffer memory and write the contents to a .png file. capture_buffer must not be in UNKNOWN layout.
// Either transition it before this call or call capture_copy_image()
capture_screenshot :: proc(renderer: ^Renderer) {
    if !renderer.capturing_primed do return

    capture_buffer := &renderer.recorder.capture_buffers[renderer.frame_index]
    capture_extent := renderer.draw_image.extent

    filename             := capture_get_output_filename("screenshot", ".png", context.temp_allocator)
    complete_filepath, _ := filepath.join({CAPTURE_DIR, filename}, context.temp_allocator)
    complete_filepath_c  := strings.clone_to_cstring(complete_filepath, context.temp_allocator)

    stbi.write_png(complete_filepath_c, i32(capture_extent.width), i32(capture_extent.height), NUM_CHANNELS, capture_buffer.data_ptr, 0)
    log.infof("Saved screenshot: %s", filename)
    renderer.recorder.screenshot_requested = false

    free_all(context.temp_allocator)
}

@(private)
capture_copy_image :: proc(cmd: vk.CommandBuffer, renderer: ^Renderer) {
    draw_image := &renderer.draw_image
    capture_buffer := &renderer.recorder.capture_buffers[renderer.frame_index]

    // Default to draw image size if no specific size specified
    capture_extent: vk.Extent3D = renderer.draw_image.extent
    recorder_res := vk.Extent3D{ renderer.recorder.resolution.x, renderer.recorder.resolution.y, 1 }

    // Copy the draw image to the capture_buffer buffer
    copy_info := vk.BufferImageCopy{
        bufferOffset        = 0,
        bufferRowLength     = 0,
        bufferImageHeight   = 0,
        imageExtent         = draw_image.extent,
        imageSubresource    = {
            aspectMask  = draw_image.aspect_flags,
            mipLevel    = 0,
            layerCount  = 1,
        },
    }
    vk.CmdCopyImageToBuffer(cmd, draw_image.handle, draw_image.layout, capture_buffer.handle, 1, &copy_info)
}
// Copies the draw image to the capture_buffer immediately
@(private)
capture_copy_image_now :: proc(renderer: ^Renderer) {
    draw_image := &renderer.draw_image
    capture_buffer := &renderer.recorder.capture_buffers[renderer.frame_index]

    // Default to draw image size if no specific size specified
    capture_extent: vk.Extent3D = renderer.draw_image.extent
    recorder_res := vk.Extent3D{ renderer.recorder.resolution.x, renderer.recorder.resolution.y, 1 }
    // Recreate the image if requesting a different size than what already exists

    if capture_extent != recorder_res {
        if renderer.recorder.recording do capture_end_recording(renderer)
        buffer_destroy(renderer, capture_buffer)
        capture_buffer^ = buffer_create(renderer, image_get_size(capture_extent), 1, { .TRANSFER_DST }, .GPU_TO_CPU)
    }

    // Copy the draw image to the capture_buffer buffer
    CommandCtx :: struct{ draw_image: Image, capture_buffer: Buffer}
    copy_command_ctx := CommandCtx{
        draw_image = draw_image^,
        capture_buffer = capture_buffer^,
    }
    immediate_command_submit(renderer, &copy_command_ctx, proc(cmd: vk.CommandBuffer, user_data: rawptr) {
        ctx := (^CommandCtx)(user_data)
        draw_image := ctx.draw_image
        capture_buffer := ctx.capture_buffer
        copy_info := vk.BufferImageCopy{
            bufferOffset        = 0,
            bufferRowLength     = 0,
            bufferImageHeight   = 0,
            imageExtent         = draw_image.extent,
            imageSubresource    = {
                aspectMask  = draw_image.aspect_flags,
                mipLevel    = 0,
                layerCount  = 1,
            },
        }
        vk.CmdCopyImageToBuffer(cmd, draw_image.handle, draw_image.layout, capture_buffer.handle, 1, &copy_info)
    })

}

// Initialize the ffmpeg process
capture_start_recording :: proc(renderer: ^Renderer) {
    if !renderer.capturing_primed || renderer.recorder.recording do return

    renderer.recorder.resolution = { renderer.draw_image.extent.width, renderer.draw_image.extent.height }

    recorder := &renderer.recorder
    resolution := fmt.aprintf("%dx%d", renderer.recorder.resolution.x, renderer.recorder.resolution.y, allocator=context.temp_allocator)
    framerate  := fmt.aprintf("%d", recorder.framerate, allocator=context.temp_allocator)
    quality    := fmt.aprintf("%d", g_ffmpeg_quality, allocator=context.temp_allocator)

    filename := capture_get_output_filename("recording", ".mp4", context.temp_allocator)

    args := []string {
        "ffmpeg",
        "-loglevel", "info",
        "-y",

        "-f", "rawvideo",
        "-pix_fmt", "rgba",
        "-s", resolution,
        "-r", framerate,
        "-i", "-",

        "-c:v", "libx264",
        "-crf", quality, // Quality level
        "-vf", "scale=out_color_matrix=bt709:out_range=tv",
        "-pix_fmt", "yuv420p",
        "-colorspace", "bt709", "-color_primaries", "bt709",
        "-color_trc", "bt709", "-color_range", "tv",
        "-movflags", "+faststart",
        filename,
    }

    read_end, write_end, pipe_err := os.pipe()
    if pipe_err != nil {
        log.error("Failed to create pipes: %v!", pipe_err)
        return
    }

    process, process_err := os.process_start(os.Process_Desc{
        working_dir = CAPTURE_DIR,
        command     = args,
        stdin       = read_end,
        stdout      = os.stdout,
        stderr      = os.stderr,
    })
    if process_err != nil {
        log.errorf("Failed to start ffmpeg process: %v!", process_err)
        os.close(read_end)
        os.close(write_end)
        return
    }

    os.close(read_end) // Need to close the read end or else we will wait on process forever
    recorder.process   = process
    recorder.pipe      = write_end
    renderer.recorder.recording = true

    log.infof("Began recording: %s", filename)
    free_all(context.temp_allocator)
}

capture_end_recording :: proc(renderer: ^Renderer) {
    if !renderer.recorder.recording || !renderer.capturing_primed do return

    recorder := &renderer.recorder
    renderer.recorder.recording = false

    os.close(recorder.pipe)
    recorder.pipe = nil

    // wait must be after the close, or this deadlocks. process_wait also releases the process handle
    state, err := os.process_wait(recorder.process)
    if err != nil {
        log.errorf("Failed to wait on ffmpeg: %v", err)
    } else if !state.success {
        log.errorf("ffmpeg exited with code %d", state.exit_code)
    }

    recorder.pipe = nil
    recorder.process = {}
    log.infof("Recording Ended.")
}

@(private)
capture_send_recorded_image :: proc(renderer: ^Renderer) {
    if !renderer.capturing_primed do return

    recorder := &renderer.recorder
    capture_buffer := &renderer.recorder.capture_buffers[renderer.frame_index]
    capture_extent: vk.Extent3D = renderer.draw_image.extent

    total_bytes := int(image_get_size(capture_extent))
    image_data_ptr := mem.slice_ptr((^u8)(capture_buffer.data_ptr), total_bytes)

    // Pipe writes go short as soon as the pipe buffer fills, which at 8 MB a frame is
    // every frame, so loop until the whole thing is out.
    for written := 0; written < total_bytes; {
        bytes_written, err := os.write(recorder.pipe, image_data_ptr[written:])
        if err != nil {
            log.errorf("Lost the ffmpeg pipe: %v", err)
            capture_end_recording(renderer)
            return
        }
        written += bytes_written
    }
}
