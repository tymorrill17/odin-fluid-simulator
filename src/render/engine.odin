package render

import "core:dynlib"
import "base:runtime"
import "core:log"
import "core:c"
import "core:math"
import "core:strings"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"
import vma "../../thirdparty/vma"

NULL_HANDLE :: 0
TIMEOUT :: 1000000000

VulkanLibrary :: struct {
    get_instance_proc_addr: vk.ProcGetInstanceProcAddr,
    library:                dynlib.Library,
    instance_api_version:   u32,
}

glob_ctx: runtime.Context
glob_vk_lib: VulkanLibrary

pool_sizes := []PoolSizeRatio {
    {vk.DescriptorType.UNIFORM_BUFFER,         100},
    {vk.DescriptorType.UNIFORM_BUFFER_DYNAMIC, 100},
    {vk.DescriptorType.STORAGE_BUFFER,         100},
    {vk.DescriptorType.COMBINED_IMAGE_SAMPLER, 100},
};

device_features: vk.PhysicalDeviceFeatures
device_features_11 := vk.PhysicalDeviceVulkan11Features{ sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
    shaderDrawParameters = true,
}
device_features_12 := vk.PhysicalDeviceVulkan12Features{ sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    descriptorIndexing  = true,
    bufferDeviceAddress = true,
}
device_features_13 := vk.PhysicalDeviceVulkan13Features{ sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
    synchronization2                = true,
    dynamicRendering                = true,
    shaderDemoteToHelperInvocation  = true,
}
device_features_14 := vk.PhysicalDeviceVulkan14Features{ sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES, }
fifo_latest_ready_feature := vk.PhysicalDevicePresentModeFifoLatestReadyFeaturesKHR{
    sType = .PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_KHR,
    presentModeFifoLatestReady = true
}

pool_size_ratios :: []PoolSizeRatio{
    {vk.DescriptorType.UNIFORM_BUFFER,         100},
    {vk.DescriptorType.UNIFORM_BUFFER_DYNAMIC, 100},
    {vk.DescriptorType.STORAGE_BUFFER,         100},
    {vk.DescriptorType.COMBINED_IMAGE_SAMPLER, 100},
};

DrawPushConstants :: struct {
    world_matrix:           float4x4,
    vertex_buffer_addr:     vk.DeviceAddress,
    instance_buffer_addr:   vk.DeviceAddress,
}

RendererConfig :: struct {
    app_name:                       cstring,
    extent:                         int2,
    validation_layers:              []cstring,
    device_extensions:              []cstring,
    use_discrete_GPU:               bool,
    initial_descriptor_set_count:   uint,
}

Renderer :: struct {
    window:                     Window,
    instance:                   vk.Instance,
    debug_messenger:            vk.DebugUtilsMessengerEXT,
    logical_device:             vk.Device,
    physical_device:            vk.PhysicalDevice,
    physical_device_properties: vk.PhysicalDeviceProperties,
    queues:                     [QueueFamily]vk.Queue,
    queue_indices:              [QueueFamily]u32,
    surface:                    vk.SurfaceKHR,
    allocator:                  vma.Allocator,
    swapchain:                  Swapchain,
    draw_image:                 Image,
    depth_image:                Image,
    command_pool:               vk.CommandPool,
    frame_commands:             []vk.CommandBuffer,
    immediate_command_pool:     vk.CommandPool,
    immediate_command:          vk.CommandBuffer,
    immediate_submit_fence:     vk.Fence,
    descriptor_allocator:       DescriptorAllocator, // Contains descriptor pools to allocate descriptor sets
    input_manager:              InputManager,

    frame_acquired_image_sem:   []vk.Semaphore, // Semaphore to let the GPU know the swapchain image has been acquired. One per frame
    frame_render_fence:         []vk.Fence, // Lets the GPU know that the CPU is done issuing rendering commands. One per frame
    swapchain_render_sem:       []vk.Semaphore, // Semaphore to let the GPU know no more rendering commands will be submitted. One per swapchain image

    // To avoid indexing the wrong frame-specific sync objects or command buffer
    current_command:            ^vk.CommandBuffer,
    current_acquired_image_sem: ^vk.Semaphore,
    current_render_fence:       ^vk.Fence,
    current_swpch_render_sem:   ^vk.Semaphore,

    renderables:                [dynamic]RenderObject,
    scene_descriptors:          [dynamic]^DescriptorSet,
    scene_descriptor_layouts:   [dynamic]vk.DescriptorSetLayout,
    scene_buffers:              [dynamic]Buffer,

    frame_number:               u64,
    frame_index:                u32,
    frames_in_flight:           u32,

    render_scale:               f32,
    draw_gui:                   bool,

    capturing_primed:           bool,
    recorder:                   Recorder,

    timer:                      Timer,
    frame_time:                 f32,    // Seconds the frame should advance the simulation by
}

renderer_initialize :: proc(renderer: ^Renderer, renderer_cfg: RendererConfig) {

    glob_ctx = context // Save this for the debug messenger callback

    // Load vulkan function pointers from the library
    did_load: bool
    when ODIN_OS == .Windows {
        glob_vk_lib.library, did_load = dynlib.load_library("vulkan-1.dll")
    } else {
        glob_vk_lib.library, did_load = dynlib.load_library("libvulkan.so.1")
        if !did_load { glob_vk_lib.library, did_load = dynlib.load_library("libvulkan.so") }
    }

    if !did_load || glob_vk_lib.library == nil {
        log.panic("Failed to load vulkan function pointers!")
    }
    get_instance_proc_addr, found := dynlib.symbol_address(glob_vk_lib.library, "vkGetInstanceProcAddr")
    if !found {
        log.panic("Could not find vkGetInstanceProcAddr in vulkan library!")
    }

    vk.load_proc_addresses_global(get_instance_proc_addr)
    assert(vk.CreateInstance != nil, "Vulkan procs not loaded!")
    glob_vk_lib.get_instance_proc_addr = (vk.ProcGetInstanceProcAddr)(get_instance_proc_addr)

    renderer.window = window_create(renderer_cfg.extent.x, renderer_cfg.extent.y, renderer_cfg.app_name)
    window_set_callbacks(renderer)
    instance_initialize(renderer, renderer_cfg.app_name, "OdinRenderer", renderer_cfg.validation_layers, []cstring{})
    // The window surface needs the instance to be created, so do it now

    // Get the vulkan instance version
    glob_vk_lib.instance_api_version = vk.API_VERSION_1_0
    if vk.EnumerateInstanceVersion != nil {
        res := vk.EnumerateInstanceVersion(&glob_vk_lib.instance_api_version)
        if res != .SUCCESS {
            glob_vk_lib.instance_api_version = vk.API_VERSION_1_0
        }
    }

    surface_initialize(renderer)
    devices_initialize(renderer, renderer_cfg.use_discrete_GPU, renderer_cfg.device_extensions)
    vulkan_allocator_initialize(renderer)
    swapchain_create(renderer)
    renderer.frames_in_flight = renderer.swapchain.n_swapchain_images

    // Create the draw and depth images
    render_extent := vk.Extent3D{ u32(renderer.window.draw_extent.x), u32(renderer.window.draw_extent.y), 1}
    renderer.draw_image = image_create_device(renderer, render_extent, renderer.swapchain.image_format,
        { .TRANSFER_SRC, .TRANSFER_DST, .COLOR_ATTACHMENT })
    renderer.depth_image = image_create_device(renderer, render_extent, .D32_SFLOAT, { .DEPTH_STENCIL_ATTACHMENT })

    command_pool_initialize(renderer)
    // Allocate a command buffer for each frame in flight
    renderer.frame_commands = make([]vk.CommandBuffer, renderer.frames_in_flight)
    command_buffer_allocate(renderer, raw_data(renderer.frame_commands), u32(len(renderer.frame_commands)))

    // Initialize per-frame synchronization objects
    renderer.frame_acquired_image_sem = make([]vk.Semaphore, renderer.frames_in_flight)
    renderer.frame_render_fence       = make([]vk.Fence, renderer.frames_in_flight)
    for i in 0..<renderer.frames_in_flight {
        renderer.frame_acquired_image_sem[i] = semaphore_create(renderer)
        renderer.frame_render_fence[i]       = fence_create(renderer, { .SIGNALED })
    }
    renderer.swapchain_render_sem = make([]vk.Semaphore, renderer.swapchain.n_swapchain_images)
    for i in 0..<renderer.swapchain.n_swapchain_images {
        renderer.swapchain_render_sem[i] = semaphore_create(renderer)
    }

    // inititalizes immediate_command_pool, immediate_command, and immediate_submit_fence
    immediate_command_initialize(renderer)

    // initialize descriptor allocator
    descriptor_allocator_initialize(renderer, renderer_cfg.initial_descriptor_set_count, pool_size_ratios)

    renderer.renderables                = make([dynamic]RenderObject)
    renderer.scene_descriptors          = make([dynamic]^DescriptorSet)
    renderer.scene_descriptor_layouts   = make([dynamic]vk.DescriptorSetLayout)
    renderer.scene_buffers              = make([dynamic]Buffer)

    renderer.render_scale = 1
    renderer.frame_index  = 0
    renderer.frame_number = 0
    renderer.timer = timer_create()

    renderer.current_acquired_image_sem = &renderer.frame_acquired_image_sem[renderer.frame_index]
    renderer.current_render_fence       = &renderer.frame_render_fence[renderer.frame_index]
    renderer.current_swpch_render_sem   = &renderer.swapchain_render_sem[renderer.swapchain.image_index]
    renderer.current_command            = &renderer.frame_commands[renderer.frame_index]

    renderer.input_manager = input_manager_create(&renderer.window)

    // Create a buffer to copy the draw image to for capturing screenshots
    renderer.capturing_primed = false
    recorder_initialize(renderer, &renderer.recorder)
    // initialize the debug gui
    gui_initialize(renderer)
    renderer.draw_gui = true
}

renderer_shutdown :: proc(renderer: ^Renderer) {
    wait_idle(renderer)

    gui_destroy(renderer)

    recorder_destroy(renderer, &renderer.recorder)

    delete(renderer.scene_buffers)
    delete(renderer.scene_descriptor_layouts)
    delete(renderer.scene_descriptors)
    delete(renderer.renderables)

    descriptor_allocator_destroy(renderer)

    // immediate command cleanup
    fence_destroy(renderer, renderer.immediate_submit_fence)
    vk.DestroyCommandPool(renderer.logical_device, renderer.immediate_command_pool, nil)

    // frame synchronization cleanup
    for i in 0..<renderer.frames_in_flight {
        semaphore_destroy(renderer, renderer.frame_acquired_image_sem[i])
        fence_destroy(renderer, renderer.frame_render_fence[i])
    }
    for i in 0..<renderer.swapchain.n_swapchain_images {
        semaphore_destroy(renderer, renderer.swapchain_render_sem[i])
    }
    delete(renderer.swapchain_render_sem)
    delete(renderer.frame_render_fence)
    delete(renderer.frame_acquired_image_sem)

    // Command buffer cleanup
    delete(renderer.frame_commands)
    vk.DestroyCommandPool(renderer.logical_device, renderer.command_pool, nil)

    // image cleanup
    image_destroy(renderer, &renderer.depth_image)
    image_destroy(renderer, &renderer.draw_image)

    swapchain_destroy(renderer)

    // vma cleanup
    vma.DestroyAllocator(renderer.allocator)

    // Device cleanup
    vk.DestroyDevice(renderer.logical_device, nil)
    vk.DestroySurfaceKHR(renderer.instance, renderer.surface, nil)

    // Instance cleanup
    vk.DestroyInstance(renderer.instance, nil)

    // Window cleanup
    window_destroy(&renderer.window)

    // Unload the vulkan library
    dynlib.unload_library(glob_vk_lib.library)
}

window_should_close :: proc(renderer: ^Renderer) -> bool {
    return bool(glfw.WindowShouldClose(renderer.window.glfw_window))
}

wait_idle :: proc(renderer: ^Renderer) {
    vk.DeviceWaitIdle(renderer.logical_device)
}

// Called at the beginning of every frame by the program
start_frame :: proc(renderer: ^Renderer) {
    poll_events()
    resize_callback(renderer)
    input_update(&renderer.input_manager, renderer)
    gui_start_frame()
    timer_update(&renderer.timer)

    if renderer.recorder.recording && renderer.recorder.framerate > 0 {
        renderer.frame_time = 1.0 / f32(renderer.recorder.framerate)
    } else {
        renderer.frame_time = renderer.timer.frame_time
    }
}

draw :: proc(renderer: ^Renderer) {
    if renderer.window.minimized do return
    frame_index := renderer.frame_index

    frame_render_fence := renderer.frame_render_fence[frame_index]
    vk.WaitForFences(renderer.logical_device, 1, &frame_render_fence, true, TIMEOUT)

    current_swapchain_image, swapchain_image_index := acquire_next_swapchain_image(renderer)
    renderer.current_swpch_render_sem   = &renderer.swapchain_render_sem[swapchain_image_index]
    vk.ResetFences(renderer.logical_device, 1, &frame_render_fence)

    cmd := renderer.frame_commands[frame_index]
    vk.ResetCommandBuffer(cmd, {})
    begin_info := command_buffer_begin_info_struct()
    if vk.BeginCommandBuffer(cmd, &begin_info) != .SUCCESS {
        log.panic("Failed to begin draw command buffer!")
    }

    // Transition the images to writable format
    image_transition(cmd, &renderer.draw_image, .GENERAL)
    image_transition(cmd, &renderer.depth_image, .GENERAL)

    clear_value := vk.ClearValue{
        color = vk.ClearColorValue{ float32 = {0, 0, 0, 1 } },
    }
    color_attachment := color_attachment_info_struct(renderer.draw_image, &clear_value)
    depth_attachment := depth_attachment_info_struct(renderer.depth_image)

    draw_extent := vk.Extent2D{
        width   = math.min(renderer.draw_image.extent.width, renderer.swapchain.extent.width),
        height  = math.min(renderer.draw_image.extent.height, renderer.swapchain.extent.height)
    }

    render_info := rendering_info_struct(draw_extent, 1, &color_attachment, &depth_attachment)

    viewport := vk.Viewport{
        x           = 0,
        y           = 0,
        width       = f32(draw_extent.width),
        height      = f32(draw_extent.height),
        minDepth    = 0,
        maxDepth    = 1,
    }

    scissor := vk.Rect2D{
        offset = { 0, 0 },
        extent = draw_extent,
    }

    vk.CmdBeginRendering(cmd, &render_info)

    vk.CmdSetViewport(cmd, 0, 1, &viewport)
    vk.CmdSetScissor(cmd, 0, 1, &scissor)

    // Sort render objects so minimize pipeline and descriptor rebinds
    // TODO: make this more robust
    slice.sort_by(renderer.renderables[:], proc(a, b: RenderObject) -> bool {
        if a.material.pipeline.handle == b.material.pipeline.handle do return a.index_buffer < b.index_buffer
        return a.material.pipeline.handle < b.material.pipeline.handle
    })

    last_pipeline: Pipeline
    last_material: ^MaterialInstance
    for render_object in renderer.renderables {
        if render_object.material.pipeline != last_pipeline {
            // Then we need to bind the new pipeline
            vk.CmdBindPipeline(cmd, render_object.material.pipeline.bind_point, render_object.material.pipeline.handle)
            if (len(renderer.scene_descriptors) > 0) {
                descriptor_set_bind(cmd, render_object.material.pipeline.bind_point, render_object.material.pipeline.layout,
                    0, renderer.scene_descriptors[:], renderer.frame_index)
            }
            last_pipeline = render_object.material.pipeline
        }
        if render_object.material != last_material {
            // Then we need to bind the new material descriptors (if they exist)
            if render_object.material.descriptor != nil {
                descriptor_set_bind(cmd, render_object.material.pipeline.bind_point, render_object.material.pipeline.layout,
                    0, { render_object.material.descriptor }, renderer.frame_index)
            }
            last_material = render_object.material
        }

        vk.CmdBindIndexBuffer(cmd, render_object.index_buffer, 0, .UINT32)
        push_constants := DrawPushConstants{
            world_matrix         = render_object.transform,
            vertex_buffer_addr   = render_object.vertex_buffer_addr,
            instance_buffer_addr = render_object.instance_buffer_addr,
        }
        vk.CmdPushConstants(cmd, render_object.material.pipeline.layout, render_object.material.pipeline.push_constant_stages, 0, size_of(push_constants), &push_constants)
        vk.CmdDrawIndexed(cmd, render_object.index_count, render_object.instance_count, render_object.first_index, 0, 0)
    }

    vk.CmdEndRendering(cmd)

    // Transition images for copying and then presenting
    // Draw image is going to be copied to the swapchain image, so transition it to a transfer source layout
    image_transition(cmd, &renderer.draw_image, .TRANSFER_SRC_OPTIMAL)
    image_transition(cmd, current_swapchain_image, .TRANSFER_DST_OPTIMAL) // Swapchain image needs to be transitioned to a transfer destination layout
    image_copy(cmd, renderer.draw_image, current_swapchain_image^)
    if renderer.capturing_primed do capture_copy_image(cmd, renderer)

    gui_draw(renderer)

    // Transition swapchain image to a presentation-ready layout
    image_transition(cmd, current_swapchain_image, .PRESENT_SRC_KHR)

    if vk.EndCommandBuffer(cmd) != .SUCCESS {
        log.panic("Failed to end the draw command buffer!")
    }

    if renderer.capturing_primed {
        // capture_copy_image_now(renderer)
        if renderer.recorder.screenshot_requested {
            capture_screenshot(renderer)
        }
        if renderer.recorder.recording {
            // Send the capture_image to the ffmpeg process
            capture_send_recorded_image(renderer)
        }
    }

    present_queue := renderer.queues[.present]
    submit_to_queue(renderer, cmd, present_queue,
        renderer.frame_acquired_image_sem[frame_index],
        renderer.swapchain_render_sem[swapchain_image_index],
        renderer.frame_render_fence[frame_index]
    )
    present_to_screen(renderer, present_queue, &renderer.swapchain_render_sem[swapchain_image_index])

    renderer.frame_number += 1
    renderer.frame_index = u32(renderer.frame_number % u64(renderer.frames_in_flight))

    renderer.current_acquired_image_sem = &renderer.frame_acquired_image_sem[renderer.frame_index]
    renderer.current_render_fence       = &renderer.frame_render_fence[renderer.frame_index]
    renderer.current_command            = &renderer.frame_commands[renderer.frame_index]

    if renderer.recorder.recording {
        timer_limit_framerate(&renderer.timer, renderer.recorder.framerate)
    }
}

resize_callback :: proc(renderer: ^Renderer) {
    if renderer.window.resized {
        wait_idle(renderer)
        update_window_info(&renderer.window)
        swapchain_recreate(renderer)
        image_recreate(renderer, &renderer.draw_image, vk.Extent3D{ u32(renderer.window.draw_extent.x), u32(renderer.window.draw_extent.y), 1 })
        image_recreate(renderer, &renderer.depth_image, vk.Extent3D{ u32(renderer.window.draw_extent.x), u32(renderer.window.draw_extent.y), 1 })
        if renderer.recorder.recording do capture_end_recording(renderer)
        recorder_resize_buffers(renderer, &renderer.recorder)
        renderer.window.resized = false // swapchain and draw images remade, resize was handled
    }
}

@(private)
rendering_info_struct :: proc(extent: vk.Extent2D, color_attachment_count: u32, color_attachments: ^vk.RenderingAttachmentInfo, depth_attachment: ^vk.RenderingAttachmentInfo) -> vk.RenderingInfoKHR {
    return vk.RenderingInfoKHR{
        sType                   = .RENDERING_INFO_KHR,
        layerCount              = 1,
        colorAttachmentCount    = color_attachment_count,
        pColorAttachments       = color_attachments,
        pDepthAttachment        = depth_attachment,
        renderArea              = { extent = extent, offset = { 0, 0 }, },
    }
}

// Instance

@(private)
instance_initialize :: proc(renderer: ^Renderer,
    app_name, engine_name: cstring,
    requested_validation_layers, requested_extensions: []cstring) {

    check_validation_layer_support :: proc(requested_layers: []cstring) -> bool {
        layer_count: u32
        vk.EnumerateInstanceLayerProperties(&layer_count, nil)
        supported_layers := make([]vk.LayerProperties, layer_count)
        vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(supported_layers))
        defer delete(supported_layers)
        check: for requested_layer in requested_layers {
            for &found_layer in supported_layers {
                if requested_layer == cstring(&found_layer.layerName[0]) {
                    continue check
                }
            }
            log.errorf("Layer not supported: %s", requested_layer)
            return false
        }
        return true
    }

    // If we pass in validation layers, we know we are using them
    validation_layers_enabled := false
    when ODIN_DEBUG {
        validation_layers_enabled = true
    }

    if validation_layers_enabled && !check_validation_layer_support(requested_validation_layers) {
        log.error("One or more of requested validation layers not supported.")
    }

    instance_version: u32
    vk.EnumerateInstanceVersion(&instance_version)

    app_info := vk.ApplicationInfo{
        sType               = .APPLICATION_INFO,
        pApplicationName    = app_name,
        applicationVersion  = vk.MAKE_API_VERSION(1, 0, 0, 0),
        pEngineName         = engine_name,
        engineVersion       = vk.MAKE_API_VERSION(1, 0, 0, 0),
        apiVersion          = instance_version
    }

    // This will return required extensions for the windowing API and validation layers, if used
    extensions := get_required_vulkan_extensions(validation_layers_enabled)
    for ext in requested_extensions {
        append(&extensions, ext)
    }
    defer delete(extensions)

    instance_create_info := vk.InstanceCreateInfo{
        sType = .INSTANCE_CREATE_INFO,
        pApplicationInfo = &app_info,
        enabledExtensionCount = u32(len(extensions)),
        ppEnabledExtensionNames = raw_data(extensions),
        // Initialize explicitly first, overwrite if using layers
        enabledLayerCount = validation_layers_enabled ? u32(len(requested_validation_layers)) : 0,
        ppEnabledLayerNames = validation_layers_enabled ? raw_data(requested_validation_layers) : nil,
    }

    if validation_layers_enabled {
        debug_create_info := vk.DebugUtilsMessengerCreateInfoEXT{
            sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            messageSeverity = { .VERBOSE, .ERROR },
            messageType     = { .GENERAL, .VALIDATION, .PERFORMANCE },
            pfnUserCallback = vk.ProcDebugUtilsMessengerCallbackEXT(vk_debug_callback)
        }
        instance_create_info.pNext = &debug_create_info
    }

    result := vk.CreateInstance(&instance_create_info, nil, &renderer.instance)
    if result != .SUCCESS {
        log.panic("Failed to create Vulkan instance: ", result)
    }

    log.info("Created Instance")
    vk.load_proc_addresses_instance(renderer.instance)
}

// Queues

@(private)
QueueFamily :: enum {
    graphics,
    present,
}

@(private)
DeviceQueues :: struct {
    indices:    [QueueFamily]int,
    queues:     [QueueFamily]vk.Queue,
}

@(private)
get_queue_indices :: proc(renderer: ^Renderer) {
    for &queue in renderer.queue_indices {
        queue = c.UINT32_MAX
    }

    // Get the properties of queue families from the physical device
    queue_family_count: u32 = 0
    vk.GetPhysicalDeviceQueueFamilyProperties(renderer.physical_device, &queue_family_count, nil)
    queue_family_properties := make([]vk.QueueFamilyProperties, queue_family_count)
    vk.GetPhysicalDeviceQueueFamilyProperties(renderer.physical_device, &queue_family_count, raw_data(queue_family_properties))
    defer delete(queue_family_properties)

    for queue_family, i in queue_family_properties {
        // If the queue is a graphics queue and we haven't already found a graphics queue
        if .GRAPHICS in queue_family.queueFlags && renderer.queue_indices[.graphics] == c.UINT32_MAX {
            renderer.queue_indices[.graphics] = u32(i)
        }

        // The present queue may also be the graphics queue, which is ok
        present_queue_support: b32
        vk.GetPhysicalDeviceSurfaceSupportKHR(renderer.physical_device, u32(i), renderer.surface, &present_queue_support)
        if present_queue_support && renderer.queue_indices[.present] == c.UINT32_MAX {
            renderer.queue_indices[.present] = u32(i)
        }

        // Did we find all of our queues?
        for q in renderer.queue_indices do if q == c.UINT32_MAX do continue;
        break;
    }

    // Make sure we actually found queues
    for q in renderer.queue_indices do if q == c.UINT32_MAX do log.panic("Failed to find device queues!");
}

// Devices

@(private)
devices_initialize :: proc(renderer: ^Renderer, request_discrete_GPU: bool, requested_extensions: []cstring) {

    select_physical_device(renderer, request_discrete_GPU, requested_extensions)
    get_queue_indices(renderer)

    unique_queues: map[u32]b8
    defer delete(unique_queues)
    for i in renderer.queue_indices {
        unique_queues[i] = true
    }

    priority: f32 = 1.0
    queue_create_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(unique_queues))
    defer delete(queue_create_infos)
    for queue_index, _ in unique_queues {
        queue_create_info := vk.DeviceQueueCreateInfo{
            sType               = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex    = u32(queue_index),
            queueCount          = 1,
            pQueuePriorities    = &priority,
        }
        append(&queue_create_infos, queue_create_info)
    }

    version_features := vk.PhysicalDeviceFeatures2{
        sType       = .PHYSICAL_DEVICE_FEATURES_2,
        features    = device_features,
        pNext       = &device_features_11,
    }
    device_features_11.pNext = &device_features_12
    device_features_12.pNext = &device_features_13
    device_features_13.pNext = &device_features_14
    device_features_14.pNext = &fifo_latest_ready_feature

    device_create_info := vk.DeviceCreateInfo{
        sType                   = .DEVICE_CREATE_INFO,
        pNext                   = &version_features,
        queueCreateInfoCount    = u32(len(queue_create_infos)),
        pQueueCreateInfos       = raw_data(queue_create_infos),
        enabledExtensionCount   = u32(len(requested_extensions)),
        ppEnabledExtensionNames = raw_data(requested_extensions),
    }

    result := vk.CreateDevice(renderer.physical_device, &device_create_info, nil, &renderer.logical_device)
    if result != .SUCCESS {
        log.panic("Failed to create Vulkan device: ", result)
    }

    // Get the actual device queues
    for queue_index, i in renderer.queue_indices {
        vk.GetDeviceQueue(renderer.logical_device, queue_index, 0, &renderer.queues[i])
    }

    device_limits: vk.PhysicalDeviceLimits

}

@(private)
select_physical_device :: proc(renderer: ^Renderer, request_discrete_GPU: bool, requested_extensions: []cstring) {
    device_count: u32 = 0
    vk.EnumeratePhysicalDevices(renderer.instance, &device_count, nil)

    if device_count == 0 {
        log.panic("Failed to find a GPU with Vulkan support!")
    }

    devices := make([]vk.PhysicalDevice, device_count)
    vk.EnumeratePhysicalDevices(renderer.instance, &device_count, raw_data(devices))
    defer delete(devices)

    get_device_name :: proc(device: vk.PhysicalDevice) -> string {
        device_properties: vk.PhysicalDeviceProperties
        vk.GetPhysicalDeviceProperties(device, &device_properties);
        return strings.clone(string(cstring(&device_properties.deviceName[0])), context.temp_allocator)
    }

    device_suitable :: proc(device: vk.PhysicalDevice, request_discrete_GPU: bool, requested_extensions: []cstring) -> bool {
        supported_extension_count: u32 = 0
        vk.EnumerateDeviceExtensionProperties(device, nil, &supported_extension_count, nil)
        supported_extensions := make([]vk.ExtensionProperties, supported_extension_count)
        vk.EnumerateDeviceExtensionProperties(device, nil, &supported_extension_count, raw_data(supported_extensions))
        defer delete(supported_extensions)

        check: for extension in requested_extensions {
            for &found_extension in supported_extensions {
                if extension == cstring(&found_extension.extensionName[0]) {
                    continue check
                }
            }
            log.errorf("Layer not supported: %s", extension)
            return false
        }

        free_all(context.temp_allocator)

        // If we request a discrete GPU and found a discrete GPU, use it
        // If we request an integrated GPU and found one, use it
        properties: vk.PhysicalDeviceProperties
        vk.GetPhysicalDeviceProperties(device, &properties)
        return (request_discrete_GPU == (properties.deviceType == vk.PhysicalDeviceType.DISCRETE_GPU))
    }

    for device in devices {
        if device_suitable(device, request_discrete_GPU, requested_extensions) {
            log.infof("Found suitable device: %s\n", get_device_name(device))
            renderer.physical_device = device
            break
        }
    }

    if renderer.physical_device == nil do log.panic("No suitable device found!")

    vk.GetPhysicalDeviceProperties(renderer.physical_device, &renderer.physical_device_properties)
}

// Allocator

@(private)
vulkan_allocator_initialize :: proc(renderer: ^Renderer) {
    // First, vma needs to be informed of the vulkan procedures
    vulkan_functions := vma.VulkanFunctions{
        GetPhysicalDeviceProperties       = vk.GetPhysicalDeviceProperties,
        GetPhysicalDeviceMemoryProperties = vk.GetPhysicalDeviceMemoryProperties,
        AllocateMemory                    = vk.AllocateMemory,
        FreeMemory                        = vk.FreeMemory,
        MapMemory                         = vk.MapMemory,
        UnmapMemory                       = vk.UnmapMemory,
        FlushMappedMemoryRanges           = vk.FlushMappedMemoryRanges,
        InvalidateMappedMemoryRanges      = vk.InvalidateMappedMemoryRanges,
        BindBufferMemory                  = vk.BindBufferMemory,
        BindImageMemory                   = vk.BindImageMemory,
        GetBufferMemoryRequirements       = vk.GetBufferMemoryRequirements,
        GetImageMemoryRequirements        = vk.GetImageMemoryRequirements,
        CreateBuffer                      = vk.CreateBuffer,
        DestroyBuffer                     = vk.DestroyBuffer,
        CreateImage                       = vk.CreateImage,
        DestroyImage                      = vk.DestroyImage,
        CmdCopyBuffer                     = vk.CmdCopyBuffer,
    }

    // Now create the allocator, passing in the vulkan function pointers
    allocator_create_info := vma.AllocatorCreateInfo{
        flags               = { .BUFFER_DEVICE_ADDRESS },
        physicalDevice      = renderer.physical_device,
        device              = renderer.logical_device,
        instance            = renderer.instance,
        pVulkanFunctions    = &vulkan_functions,
    }

    if vma.CreateAllocator(&allocator_create_info, &renderer.allocator) != .SUCCESS {
        log.panic("Failed to create Vulkan memory allocator!")
    }
}

// Command Pools and Buffers

@(private)
command_pool_initialize :: proc(renderer: ^Renderer) {

    command_pool_info := vk.CommandPoolCreateInfo{
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = { .RESET_COMMAND_BUFFER },
        queueFamilyIndex = renderer.queue_indices[.graphics], // Creating for the graphics queue only
    }

    if vk.CreateCommandPool(renderer.logical_device, &command_pool_info, nil, &renderer.command_pool) != .SUCCESS {
        log.panic("Failed to create command pool!")
    }
}

@(private)
command_buffer_allocate :: proc(renderer: ^Renderer, command_buffers: [^]vk.CommandBuffer, n_command_buffers: u32) {
    alloc_info := vk.CommandBufferAllocateInfo{
        sType               = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool         = renderer.command_pool,
        level               = .PRIMARY,
        commandBufferCount  = n_command_buffers,
    }

    if vk.AllocateCommandBuffers(renderer.logical_device, &alloc_info, command_buffers) != .SUCCESS {
        log.panic("Failed to allocate command buffers from the pool!")
    }
}

@(private)
submit_to_queue :: proc(renderer: ^Renderer, cmd: vk.CommandBuffer, queue: vk.Queue,
    wait_sem: vk.Semaphore, signal_sem: vk.Semaphore, fence: vk.Fence) {

    cmd_submit_info := vk.CommandBufferSubmitInfo{
        sType           = .COMMAND_BUFFER_SUBMIT_INFO,
        commandBuffer   = cmd,
    }

    wait_sem_info := vk.SemaphoreSubmitInfo{
        sType       = .SEMAPHORE_SUBMIT_INFO,
        semaphore   = wait_sem,
        value       = 1,
        stageMask   = { .COLOR_ATTACHMENT_OUTPUT_KHR },
        deviceIndex = 0
    }

    signal_sem_info := vk.SemaphoreSubmitInfo{
        sType       = .SEMAPHORE_SUBMIT_INFO,
        semaphore   = signal_sem,
        value       = 1,
        stageMask   = { .ALL_GRAPHICS },
        deviceIndex = 0
    }

    submit_info := vk.SubmitInfo2{
        sType                       = .SUBMIT_INFO_2,
        waitSemaphoreInfoCount      = 1,
        pWaitSemaphoreInfos         = &wait_sem_info,
        commandBufferInfoCount      = 1,
        pCommandBufferInfos         = &cmd_submit_info,
        signalSemaphoreInfoCount    = 1,
        pSignalSemaphoreInfos       = &signal_sem_info,
    }

    if vk.QueueSubmit2(queue, 1, &submit_info, fence) != .SUCCESS {
        log.panic("Failed to submit command buffer to queue!")
    }
}

@(private)
immediate_command_initialize :: proc(renderer: ^Renderer) {
    command_pool_info := vk.CommandPoolCreateInfo{
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = { .TRANSIENT },
        queueFamilyIndex = renderer.queue_indices[.graphics], // Creating for the graphics queue only
    }

    if vk.CreateCommandPool(renderer.logical_device, &command_pool_info, nil, &renderer.immediate_command_pool) != .SUCCESS {
        log.panic("Failed to create immediate command pool!")
    }

    command_buffer_allocate(renderer, &renderer.immediate_command, 1)
    renderer.immediate_submit_fence = fence_create(renderer, { .SIGNALED })
}

immediate_command_submit :: proc(renderer: ^Renderer, user_data: rawptr,
    submit_proc: proc(cmd: vk.CommandBuffer, user_data: rawptr)) {

    cmd := renderer.immediate_command
    vk.ResetFences(renderer.logical_device, 1, &renderer.immediate_submit_fence)
    vk.ResetCommandBuffer(cmd, {})

    cmd_begin_info := command_buffer_begin_info_struct()
    if vk.BeginCommandBuffer(cmd, &cmd_begin_info) != .SUCCESS {
        log.panic("Failed to begin immediate command buffer!")
    }

    submit_proc(cmd, user_data)

    vk.EndCommandBuffer(cmd)

    // Submit the immediate command
    cmd_submit_info := vk.CommandBufferSubmitInfo{
        sType           = .COMMAND_BUFFER_SUBMIT_INFO,
        commandBuffer   = cmd,
    }

    submit_info := vk.SubmitInfo2{
        sType                       = .SUBMIT_INFO_2,
        waitSemaphoreInfoCount      = 0,
        pWaitSemaphoreInfos         = nil,
        commandBufferInfoCount      = 1,
        pCommandBufferInfos         = &cmd_submit_info,
        signalSemaphoreInfoCount    = 0,
        pSignalSemaphoreInfos       = nil,
    }

    if vk.QueueSubmit2(renderer.queues[.graphics], 1, &submit_info, renderer.immediate_submit_fence) != .SUCCESS {
        log.panic("Failed to submit immediate command to queue!")
    }

    vk.WaitForFences(renderer.logical_device, 1, &renderer.immediate_submit_fence, true, TIMEOUT)
}

@(private)
command_buffer_begin_info_struct :: proc(flags: vk.CommandBufferUsageFlags = {}) -> vk.CommandBufferBeginInfo {
    begin_info := vk.CommandBufferBeginInfo{
        sType               = .COMMAND_BUFFER_BEGIN_INFO,
        flags               = flags,
        pInheritanceInfo    = nil
    }
    return begin_info
}

@(private)
semaphore_create :: proc(renderer: ^Renderer, flags: vk.SemaphoreCreateFlags = {}) -> vk.Semaphore {
    semaphore_info := vk.SemaphoreCreateInfo{
        sType = .SEMAPHORE_CREATE_INFO,
        flags = flags
    }
    new_sem: vk.Semaphore
    if vk.CreateSemaphore(renderer.logical_device, &semaphore_info, nil, &new_sem) != .SUCCESS {
        log.panic("Failed to create semaphore!")
    }
    return new_sem
}

@(private)
semaphore_destroy :: proc(renderer: ^Renderer, semaphore: vk.Semaphore) {
    vk.DestroySemaphore(renderer.logical_device, semaphore, nil)
}

@(private)
fence_create :: proc(renderer: ^Renderer, flags: vk.FenceCreateFlags = {}) -> vk.Fence {
    fence_info := vk.FenceCreateInfo{
        sType = .FENCE_CREATE_INFO,
        flags = flags
    }
    new_fence: vk.Fence
    if vk.CreateFence(renderer.logical_device, &fence_info, nil, &new_fence) != .SUCCESS {
        log.panic("Failed to create fence!")
    }
    return new_fence
}

@(private)
fence_destroy :: proc(renderer: ^Renderer, fence: vk.Fence) {
    vk.DestroyFence(renderer.logical_device, fence, nil)
}

@(private)
vk_debug_callback :: proc "system" (
    messageSeverity:   vk.DebugUtilsMessageSeverityFlagsEXT,
    messageType:       vk.DebugUtilsMessageTypeFlagsEXT,
    pCallbackData:    ^vk.DebugUtilsMessengerCallbackDataEXT,
    pUserData:        ^rawptr) -> b32 {

    context = glob_ctx
    if .ERROR in messageSeverity {
        log.error("Validation Layer -- ", pCallbackData.pMessage)
    } else if .WARNING in messageSeverity {
        log.warn("Validation Layer -- ", pCallbackData.pMessage)
    } else { // Info
        log.info("Validation Layer -- ", pCallbackData.pMessage)
    }
    return false
}


