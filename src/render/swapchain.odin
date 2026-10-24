package render

import "core:c"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

Swapchain :: struct {
    handle:             vk.SwapchainKHR,
    images:             []Image,
    render_semaphores:  []vk.Semaphore, // Semaphore to let the GPU know no more rendering commands will be submitted. One per swapchain image
    current_image:      ^Image,
    image_index:        u32,
    image_format:       vk.Format,
    extent:             vk.Extent2D,
    n_swapchain_images: u32,
}

RetiredSwapchain :: struct {
    swapchain:           Swapchain,
    retire_frame_number: u64,
}

@(private)
acquire_next_swapchain_image :: proc(renderer: ^Renderer) -> (swapchain_image: ^Image, swapchain_image_index: u32, success: bool) {
    result := vk.AcquireNextImageKHR(renderer.logical_device, renderer.swapchain.handle,
                TIMEOUT, renderer.frame_acquired_image_sem[renderer.frame_index], NULL_HANDLE, &renderer.swapchain.image_index)
    #partial switch result {
    case .SUCCESS:
    case .SUBOPTIMAL_KHR:
        renderer.window.resized = true
    case .ERROR_OUT_OF_DATE_KHR:
        renderer.window.resized = true
        return nil, 0, false
    case:
        log.panic("Failed to acquire next swapchain image!")
    }

    renderer.swapchain.current_image = &renderer.swapchain.images[renderer.swapchain.image_index]
    return renderer.swapchain.current_image, renderer.swapchain.image_index, true
}

@(private)
present_to_screen :: proc(renderer: ^Renderer, queue: vk.Queue, render_semaphore: ^vk.Semaphore) {
    present_info := vk.PresentInfoKHR{
        sType               = .PRESENT_INFO_KHR,
        pNext               = nil,
        waitSemaphoreCount  = 1,
        pWaitSemaphores     = render_semaphore,
        swapchainCount      = 1,
        pSwapchains         = &renderer.swapchain.handle,
        pImageIndices       = &renderer.swapchain.image_index
    }
    result := vk.QueuePresentKHR(queue, &present_info)
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        renderer.window.resized = true
    } else if result != .SUCCESS {
        log.panic("Failed to present to screen!")
    }
}

@(private)
swapchain_recreate :: proc(renderer: ^Renderer) {
    old_swapchain := renderer.swapchain
    renderer.swapchain = swapchain_create(renderer, old_swapchain.handle)
    append(&renderer.retired_swapchains, RetiredSwapchain{ old_swapchain, renderer.frame_number })
}

@(private)
swapchain_create :: proc(renderer: ^Renderer, old_swapchain: vk.SwapchainKHR = 0) -> Swapchain {

    swapchain: Swapchain

    capabilities: vk.SurfaceCapabilitiesKHR
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(renderer.physical_device, renderer.surface, &capabilities)

    surface_format_count: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(renderer.physical_device, renderer.surface, &surface_format_count, nil)
    assert(surface_format_count > 0)
    surface_formats := make([]vk.SurfaceFormatKHR, surface_format_count)
    defer delete(surface_formats)
    vk.GetPhysicalDeviceSurfaceFormatsKHR(renderer.physical_device, renderer.surface, &surface_format_count, raw_data(surface_formats))

    present_mode_count: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(renderer.physical_device, renderer.surface, &present_mode_count, nil)
    assert(present_mode_count > 0)
    present_modes := make([]vk.PresentModeKHR, present_mode_count)
    defer delete(present_modes)
    vk.GetPhysicalDeviceSurfacePresentModesKHR(renderer.physical_device, renderer.surface, &present_mode_count, raw_data(present_modes))

    swapchain.image_index = 0

    // Set the defaults first
    surface_format: vk.SurfaceFormatKHR = surface_formats[0]
    present_mode: vk.PresentModeKHR = vk.PresentModeKHR.FIFO
    for format in surface_formats {
        if format.format == vk.Format.R8G8B8A8_UNORM &&
            format.colorSpace == vk.ColorSpaceKHR.SRGB_NONLINEAR {
            surface_format = format
            break
        }
    }
    // TODO: Selection in order of preference
    for mode in present_modes {
        if mode == vk.PresentModeKHR.MAILBOX {
            present_mode = mode
            break
        } else if mode == vk.PresentModeKHR.FIFO_LATEST_READY {
            present_mode = mode
            break
        }
    }

    // An extent of size UINT32_MAX means the window resolution should be used
    if capabilities.currentExtent.width != c.UINT32_MAX {
        swapchain.extent = capabilities.currentExtent
    } else {
        swapchain.extent = vk.Extent2D{ u32(renderer.window.framebuffer_size.x), u32(renderer.window.framebuffer_size.y) }
        // Truncate the extent to within the surface capabilities
        swapchain.extent.width = math.max(capabilities.minImageExtent.width,
            math.min(capabilities.maxImageExtent.width, swapchain.extent.width))
        swapchain.extent.height = math.max(capabilities.minImageExtent.height,
            math.min(capabilities.maxImageExtent.height, swapchain.extent.height))
    }

    swapchain.image_format = surface_format.format

    swapchain.n_swapchain_images = capabilities.minImageCount + 1
    if capabilities.maxImageCount > 0 &&
        swapchain.n_swapchain_images > capabilities.maxImageCount {

        swapchain.n_swapchain_images = capabilities.maxImageCount
    }

    swapchain_create_info := vk.SwapchainCreateInfoKHR{
        sType               = .SWAPCHAIN_CREATE_INFO_KHR,
        oldSwapchain        = old_swapchain,
        surface             = renderer.surface,
        minImageCount       = swapchain.n_swapchain_images,
        imageFormat         = swapchain.image_format,
        imageColorSpace     = surface_format.colorSpace,
        imageExtent         = swapchain.extent,
        imageArrayLayers    = 1,
        imageUsage          = { .TRANSFER_DST, .COLOR_ATTACHMENT },
        preTransform        = capabilities.currentTransform,
        compositeAlpha      = { .OPAQUE },
        presentMode         = present_mode,
        clipped             = true,
    }

    // Exclusive mode is faster when the graphics and present queue are the same
    if renderer.queue_indices[.graphics] == renderer.queue_indices[.present] {
        swapchain_create_info.imageSharingMode      = vk.SharingMode(.EXCLUSIVE)
        swapchain_create_info.queueFamilyIndexCount = 0
        swapchain_create_info.pQueueFamilyIndices   = nil
    } else {
        swapchain_create_info.imageSharingMode      = vk.SharingMode(.CONCURRENT)
        swapchain_create_info.queueFamilyIndexCount = 2
        swapchain_create_info.pQueueFamilyIndices   = raw_data(&renderer.queue_indices)
    }

    if vk.CreateSwapchainKHR(renderer.logical_device, &swapchain_create_info, nil, &swapchain.handle) != .SUCCESS {
        log.panic("Failed to create swapchain!")
    }

    vk.GetSwapchainImagesKHR(renderer.logical_device, swapchain.handle, &swapchain.n_swapchain_images, nil)
    swapchain.images = make([]Image, swapchain.n_swapchain_images)
    image_handles := make([]vk.Image, swapchain.n_swapchain_images)
    defer delete(image_handles)
    vk.GetSwapchainImagesKHR(renderer.logical_device, swapchain.handle, &swapchain.n_swapchain_images, raw_data(image_handles))

    for image, i in image_handles {
        swapchain.images[i] = Image{
            handle          = image,
            layout          = .UNDEFINED,
            extent          = vk.Extent3D{ height = swapchain.extent.height, width = swapchain.extent.width, depth = 1 },
            format          = swapchain.image_format,
            aspect_flags    = { .COLOR, },
            mip_levels      = 1,
        }

        // Create associated image view. This is going to be a color aspect image view
        subresource_range := vk.ImageSubresourceRange{
            aspectMask = swapchain.images[i].aspect_flags,
            baseMipLevel = 0,
            levelCount = swapchain.images[i].mip_levels,
            baseArrayLayer = 0,
            layerCount = 1
        }
        image_view_info := vk.ImageViewCreateInfo{
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = swapchain.images[i].handle,
            viewType = .D2,
            format = swapchain.images[i].format,
            subresourceRange = subresource_range
        }
        vk.CreateImageView(renderer.logical_device, &image_view_info, nil, &swapchain.images[i].view)

    }

    swapchain.current_image = &swapchain.images[swapchain.image_index]

    swapchain.render_semaphores = make([]vk.Semaphore, swapchain.n_swapchain_images)
    for i in 0..<swapchain.n_swapchain_images {
        swapchain.render_semaphores[i] = semaphore_create(renderer)
    }

    return swapchain
}

@(private)
swapchain_destroy :: proc(renderer: ^Renderer, swapchain: ^Swapchain) {
    for image in swapchain.images do vk.DestroyImageView(renderer.logical_device, image.view, nil)
    delete(swapchain.images)
    vk.DestroySwapchainKHR(renderer.logical_device, swapchain.handle, nil)
    for semaphore in swapchain.render_semaphores do semaphore_destroy(renderer, semaphore)
    delete(swapchain.render_semaphores)
    swapchain^ = {}
}
