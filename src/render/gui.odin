package render

import "core:log"
import "core:strings"
import "core:path/filepath"
import vk "vendor:vulkan"
import "thirdparty:imgui"
import "thirdparty:imgui/imgui_impl_glfw"
import "thirdparty:imgui/imgui_impl_vulkan"

CACHE_DIR :: #config(CACHE_DIR, ".")

@(private="file")
pool_sizes := []vk.DescriptorPoolSize{
    { .SAMPLED_IMAGE, imgui_impl_vulkan.MINIMUM_SAMPLED_IMAGE_POOL_SIZE },
    { .SAMPLER, imgui_impl_vulkan.MINIMUM_SAMPLER_POOL_SIZE },
}

@(private="file")
gui_descriptor_pool: vk.DescriptorPool

@(private)
gui_initialize :: proc(renderer: ^Renderer) {

	// Initialize core structures of ImGui
    imgui.CreateContext()

    // Set the location of the imgui.ini
    imgui_io := imgui.GetIO()
    imgui_ini_file, _ := filepath.join({ CACHE_DIR, "imgui.ini" }, context.temp_allocator)
    imgui_log_file, _ := filepath.join({ CACHE_DIR, "imgui.log" }, context.temp_allocator)
    defer free_all(context.temp_allocator)
    imgui_io.IniFilename = strings.clone_to_cstring(imgui_ini_file, context.allocator)
    imgui_io.LogFilename = strings.clone_to_cstring(imgui_log_file, context.allocator)

	// Initializes ImGui for glfw
    imgui_impl_glfw.InitForVulkan(renderer.window.glfw_window, true)

    // Now we need to build a few vulkan structures to initialize for vulkan
    pipeline_rendering_info := vk.PipelineRenderingCreateInfoKHR{
        sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
        colorAttachmentCount    = 1,
        pColorAttachmentFormats = &renderer.swapchain.image_format,
        depthAttachmentFormat   = renderer.depth_image.format,
    }

    descriptor_pool_info := vk.DescriptorPoolCreateInfo{
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        flags = { .FREE_DESCRIPTOR_SET, },
        poolSizeCount = u32(len(pool_sizes)),
        pPoolSizes = raw_data(pool_sizes),
    }
    for pool_size in pool_sizes {
        descriptor_pool_info.maxSets += pool_size.descriptorCount
    }

    if vk.CreateDescriptorPool(renderer.logical_device, &descriptor_pool_info, nil, &gui_descriptor_pool) != .SUCCESS {
        log.panic("Failed to create the gui descriptor pool!")
    }

    vulkan_init := imgui_impl_vulkan.InitInfo{
        Instance            = renderer.instance,
        PhysicalDevice      = renderer.physical_device,
        Device              = renderer.logical_device,
        QueueFamily         = renderer.queue_indices[.graphics],
        Queue               = renderer.queues[.graphics],
        MinImageCount       = renderer.frames_in_flight,
        ImageCount          = renderer.frames_in_flight,
        DescriptorPool      = gui_descriptor_pool,
        UseDynamicRendering = true,
        PipelineInfoMain    = { PipelineRenderingCreateInfo = pipeline_rendering_info },
    }

    loaded := imgui_impl_vulkan.LoadFunctions( glob_vk_lib.instance_api_version,
        proc "c" (function_name: cstring, user_data: rawptr) -> vk.ProcVoidFunction {
            renderer := cast(^Renderer)user_data
            return vk.GetInstanceProcAddr(renderer.instance, function_name)
        },
        renderer)
    if !loaded {
        log.panic("Failed to load imgui function pointers")
    }

    imgui_impl_vulkan.Init(&vulkan_init)

}

@(private)
gui_destroy :: proc(renderer: ^Renderer) {
    imgui_io := imgui.GetIO()
    imgui_impl_vulkan.Shutdown()
    imgui_impl_glfw.Shutdown()
    imgui.DestroyContext()
    vk.DestroyDescriptorPool(renderer.logical_device, gui_descriptor_pool, nil)
    delete(imgui_io.IniFilename)
    delete(imgui_io.LogFilename)
}

@(private)
gui_start_frame :: proc() {
    imgui_impl_vulkan.NewFrame()
    imgui_impl_glfw.NewFrame()
    imgui.NewFrame()
}

gui_skip_frame :: proc() {
    imgui.EndFrame()
}

@(private)
gui_draw :: proc(renderer: ^Renderer) {
    cmd := renderer.current_command^ // Get the current frame's command buffer

    // We will be drawing to the swapchain image, so make sure it is in the GENERAL layout
    if renderer.swapchain.current_image.layout != .GENERAL {
        image_transition(cmd, renderer.swapchain.current_image, .GENERAL)
    }
    color_attachment_info := color_attachment_info_struct(renderer.swapchain.current_image^, nil)

    // QUESTION: Should this be the image extent or the swapchain extent? I should test out.
    //           This may be a bug with desktop scaling issues
    //           Methinks it should be swapchain image, since I don't want the gui to enlarge with the screen
    draw_extent := renderer.swapchain.extent
    render_info := rendering_info_struct(draw_extent, 1, &color_attachment_info, nil)

    vk.CmdBeginRendering(cmd, &render_info)
    if renderer.draw_gui {
        imgui.Render()
        imgui_impl_vulkan.RenderDrawData(imgui.GetDrawData(), cmd)
    }
    vk.CmdEndRendering(cmd)
    imgui.EndFrame()

}
