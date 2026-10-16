package render

import "vendor:glfw"
import "core:log"
import "core:math"

Window :: struct {
    glfw_window:            glfw.WindowHandle,
    glfw_monitor:           glfw.MonitorHandle,
    glfw_mode:              ^glfw.VidMode,

    resolution:             int2, // The size of the window in physical pixels
    framebuffer_size:       int2, // The number of pixels the extent takes up. (== resolution * scale)
    aspect_ratio:           f32,
    position:               int2,
    scale:                  float2,
    max_resolution:         int2, // The maximum monitor resolution over all monitors
    max_framebuffer_size:   int2, // The max framebuffer size over all monitors (max_resolution * scale)

    // To save the windowed position and size when going into fullscreen
    saved_position:         int2,
    saved_resolution:       int2,

    should_close:           bool,
    minimized:              bool,
    fullscreen:             bool,
    resized:                bool,

}

@(private)
window_create :: proc(width, height: i32, name: cstring) -> Window {
    window: Window

    window.should_close = false
    window.fullscreen   = false
    window.resized      = false
    window.minimized    = false

    when ODIN_OS == .Linux {
        // glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_X11)
        glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_WAYLAND)
    }
    when ODIN_OS == .Windows {
        glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_WIN32)
    }

    if !glfw.Init() {
        log.panic("GLFW initialization failed!")
    }

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
    glfw.WindowHint(glfw.VISIBLE, glfw.TRUE)
    window.glfw_window = glfw.CreateWindow(
        width,
        height,
        name,
        nil, // May specify a monitor here to start in fullscreen
        nil)

    if window.glfw_window == nil {
        log.panic("Window creation failure")
    }
    log.infof("Created a window titled: %s", name);

    window.glfw_monitor = glfw.GetPrimaryMonitor()
    if window.glfw_monitor == nil {
        log.panic("Failed to find monitor!")
    }

    window.glfw_mode = glfw.GetVideoMode(window.glfw_monitor)
    if window.glfw_mode == nil {
        log.panic("Failed to get video mode!")
    }

    glfw.ShowWindow(window.glfw_window)
    update_window_info(&window)

    return window
}

@(private)
window_destroy :: proc(window: ^Window) {
    glfw.DestroyWindow(window.glfw_window)
    glfw.Terminate()
}

set_fullscreen :: proc(window: ^Window, enable: bool) {
    if enable {
        window.saved_resolution.x, window.saved_resolution.y     = glfw.GetWindowSize(window.glfw_window)
        window.saved_position.x, window.saved_position.y = glfw.GetWindowPos(window.glfw_window)

        glfw.SetWindowMonitor(window.glfw_window, window.glfw_monitor, 0, 0,
            window.glfw_mode.width, window.glfw_mode.height, window.glfw_mode.refresh_rate)
    } else { // disable
        glfw.SetWindowMonitor(window.glfw_window, nil,
            window.saved_position.x, window.saved_position.y,
            window.saved_resolution.x, window.saved_resolution.y, 0)
    }

    window.fullscreen = enable
    window.resized    = true
}

// Hide the cursor and lock it to the window so it can't leave while dragging
set_cursor_locked :: proc(window: ^Window, locked: bool) {
    if locked {
        glfw.SetInputMode(window.glfw_window, glfw.CURSOR, glfw.CURSOR_DISABLED)
        if glfw.RawMouseMotionSupported() {
            glfw.SetInputMode(window.glfw_window, glfw.RAW_MOUSE_MOTION, 1)
        }
    } else {
        glfw.SetInputMode(window.glfw_window, glfw.RAW_MOUSE_MOTION, 0)
        glfw.SetInputMode(window.glfw_window, glfw.CURSOR, glfw.CURSOR_NORMAL)
    }
}

@(private)
poll_events :: proc() {
    glfw.PollEvents()
}

@(private)
update_window_info :: proc(window: ^Window) {
    window.scale.x, window.scale.y                       = glfw.GetWindowContentScale(window.glfw_window)
    window.resolution.x, window.resolution.y             = glfw.GetWindowSize(window.glfw_window)
    window.framebuffer_size.x, window.framebuffer_size.y = glfw.GetFramebufferSize(window.glfw_window)
    window.position.x, window.position.y                 = glfw.GetWindowPos(window.glfw_window)
    window.aspect_ratio                                  = f32(window.resolution.x) / f32(window.resolution.y)

    window.max_resolution = {}
    window.max_framebuffer_size = window.framebuffer_size // never smaller than what the window has right now

    for monitor in glfw.GetMonitors() {
        mode := glfw.GetVideoMode(monitor)
        if mode == nil do continue

        resolution  := int2{ mode.width, mode.height }
        framebuffer := resolution

        // To account for WAYLAND desktop scaling
        if glfw.GetPlatform() == glfw.PLATFORM_WAYLAND {
            scale_x, scale_y := glfw.GetMonitorContentScale(monitor)
            if scale_x > 0 do framebuffer.x = i32(math.ceil(f32(mode.width)  / scale_x * math.ceil(scale_x)))
            if scale_y > 0 do framebuffer.y = i32(math.ceil(f32(mode.height) / scale_y * math.ceil(scale_y)))
        }

        window.max_resolution.x = math.max(window.max_resolution.x, resolution.x)
        window.max_resolution.y = math.max(window.max_resolution.y, resolution.y)
        window.max_framebuffer_size.x = math.max(window.max_framebuffer_size.x, framebuffer.x)
        window.max_framebuffer_size.y = math.max(window.max_framebuffer_size.y, framebuffer.y)
    }
}

@(private)
get_required_vulkan_extensions :: proc(using_validation_layers: bool) -> [dynamic]cstring {
    extensions_cstr := glfw.GetRequiredInstanceExtensions()
    extensions := make([dynamic]cstring, 0, len(extensions_cstr))
    for extension in extensions_cstr {
        append(&extensions, extension)
    }
    if using_validation_layers {
        append(&extensions, "VK_EXT_debug_utils")
    }
    return extensions
}

@(private)
surface_initialize :: proc(renderer: ^Renderer) {
    if glfw.CreateWindowSurface(renderer.instance, renderer.window.glfw_window, nil, &renderer.surface) != .SUCCESS {
        log.panic("Failed to create window surface!")
    }
}

@(private)
window_set_callbacks :: proc(renderer: ^Renderer) {
    glfw.SetWindowUserPointer(renderer.window.glfw_window, renderer)
    glfw.SetFramebufferSizeCallback(renderer.window.glfw_window, window_resize_callback)
    glfw.SetWindowSizeCallback(renderer.window.glfw_window, window_resize_callback)
}

@(private)
window_resize_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
    renderer := cast(^Renderer)glfw.GetWindowUserPointer(window)
    renderer.window.resized = true
}
