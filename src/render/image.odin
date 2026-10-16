package render

import vk "vendor:vulkan"
import vma "../../thirdparty/vma"
import "core:math"
import "core:log"

Image :: struct {
    handle:         vk.Image,
    view:           vk.ImageView,
    sampler:        vk.Sampler,
    allocation:     vma.Allocation, // if nil, then the image has or needs no allocation

    layout:         vk.ImageLayout,
    extent:         vk.Extent3D,
    format:         vk.Format,
    aspect_flags:   vk.ImageAspectFlags,
    usage_flags:    vk.ImageUsageFlags, // only needed for images with an allocation
    tiling:         vk.ImageTiling,
    mem_flags:      vma.AllocationCreateFlags,
    mem_usage:      vma.MemoryUsage,
    mip_levels:     u32,
}

@(private="file")
image_create_private :: proc(renderer: ^Renderer, extent: vk.Extent3D, format: vk.Format,
    usage: vk.ImageUsageFlags, tiling: vk.ImageTiling, mem_usage: vma.MemoryUsage,
    mem_flags: vma.AllocationCreateFlags, use_mipmap: bool = false) -> Image {

    new_image := Image{
        layout          = .UNDEFINED,
        extent          = extent,
        format          = format,
        aspect_flags    = format == vk.Format.D32_SFLOAT ? { .DEPTH } : { .COLOR },
        usage_flags     = usage,
        tiling          = tiling,
        mem_flags       = mem_flags,
        mem_usage       = mem_usage,
        mip_levels      = use_mipmap ? u32(math.floor(math.log2(f32(math.max(extent.width, extent.height))))) + 1 : 1,
    }

    image_info := vk.ImageCreateInfo{
        sType       = .IMAGE_CREATE_INFO,
        imageType   = extent.depth > 1 ? .D3 : .D2,
        format      = format,
        extent      = extent,
        mipLevels   = new_image.mip_levels,
        arrayLayers = 1,
        samples     = { ._1 },
        tiling      = tiling,
        usage       = usage,
    }

    alloc_info := vma.AllocationCreateInfo{
        usage = mem_usage,
        flags = mem_flags
    }

    if vma.CreateImage(renderer.allocator, &image_info, &alloc_info, &new_image.handle, &new_image.allocation, nil) != .SUCCESS {
        log.panic("Failed to create allocated image!")
    }

    // Now create the image view
    subresource_range := vk.ImageSubresourceRange{
        aspectMask      = new_image.aspect_flags,
        baseMipLevel    = 0,
        levelCount      = new_image.mip_levels,
        layerCount      = 1,
        baseArrayLayer  = 0
    }

    image_view_info := vk.ImageViewCreateInfo{
        sType               = .IMAGE_VIEW_CREATE_INFO,
        image               = new_image.handle,
        viewType            = extent.depth > 1 ? .D3 : .D2,
        format              = format,
        subresourceRange    = subresource_range,
    }

    if vk.CreateImageView(renderer.logical_device, &image_view_info, nil, &new_image.view) != .SUCCESS {
        log.panic("Failed to create image view!")
    }

    return new_image
}

// Creates a device-only image
image_create_device :: proc(renderer: ^Renderer, extent: vk.Extent3D, format: vk.Format, usage: vk.ImageUsageFlags) -> Image {
    return image_create_private(renderer, extent, format, usage, .OPTIMAL, .AUTO_PREFER_DEVICE, {}, false)
}

// Creates an image that will be host-accessible
image_create_host :: proc(renderer: ^Renderer, extent: vk.Extent3D, format: vk.Format, usage: vk.ImageUsageFlags) -> Image {
    return image_create_private(renderer, extent, format, usage, .LINEAR, .AUTO_PREFER_HOST, { .HOST_ACCESS_RANDOM }, false)
}

// Creates a device-only image that will be used for texture purposes
image_create_texture :: proc(renderer: ^Renderer, extent: vk.Extent3D, sampler: vk.Sampler, format: vk.Format, usage: vk.ImageUsageFlags, use_mipmaps: bool = false) -> Image {
    new_texture := image_create_private(renderer, extent, format, usage, .OPTIMAL, .AUTO, {}, use_mipmaps)
    new_texture.sampler = sampler
    return new_texture
}

image_create_texture_from_data :: proc(renderer: ^Renderer, data: rawptr, extent: vk.Extent3D, sampler: vk.Sampler, format: vk.Format, usage: vk.ImageUsageFlags, use_mipmaps: bool = false) -> Image {
    new_texture := image_create_texture(renderer, extent, sampler, format, usage + { .TRANSFER_DST }, use_mipmaps)
    image_copy_data_to_image_now(renderer, &new_texture, data, 4) // bytes per pixel; the proc multiplies by the extent
    return new_texture
}

image_recreate :: proc(renderer: ^Renderer, image: ^Image, extent: vk.Extent3D) {
    use_mipmaps: bool = image.mip_levels > 1
    image_destroy(renderer, image)
    image^ = image_create_private(renderer, extent, image.format, image.usage_flags, image.tiling, image.mem_usage, image.mem_flags, use_mipmaps)
    image.layout = .UNDEFINED
}

image_destroy :: proc(renderer: ^Renderer, image: ^Image) {
    vk.DestroyImageView(renderer.logical_device, image.view, nil)
    vma.DestroyImage(renderer.allocator, image.handle, image.allocation)
}

image_transition :: proc(cmd: vk.CommandBuffer, image: ^Image, new_layout: vk.ImageLayout) {
    subresource_range := vk.ImageSubresourceRange{
        aspectMask      = image.aspect_flags,
        baseMipLevel    = 0,
        levelCount      = image.mip_levels,
        layerCount      = 1,
        baseArrayLayer  = 0,
    }

    image_barrier := vk.ImageMemoryBarrier2{
        sType               = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask        = { .ALL_COMMANDS },
        srcAccessMask       = { .MEMORY_WRITE },
        dstStageMask        = { .ALL_COMMANDS },
        dstAccessMask       = { .MEMORY_WRITE, .MEMORY_READ },
        oldLayout           = image.layout,
        newLayout           = new_layout,
        image               = image.handle,
        subresourceRange    = subresource_range,
    }

    dependency_info := vk.DependencyInfo{
        sType                   = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers    = &image_barrier,
    }

    vk.CmdPipelineBarrier2(cmd, &dependency_info)
    image.layout = new_layout
}

image_transition_now :: proc(renderer: ^Renderer, image: ^Image, new_layout: vk.ImageLayout) {
    CommandCtx :: struct{ image: ^Image, new_layout: vk.ImageLayout }
    copy_command_ctx := CommandCtx{
        image       = image,
        new_layout  = new_layout,
    }

    immediate_command_submit(renderer, &copy_command_ctx, proc(cmd: vk.CommandBuffer, user_data: rawptr) {
        ctx := (^CommandCtx)(user_data)
        image := ctx.image
        new_layout := ctx.new_layout
        image_transition(cmd, image, new_layout)
    })
}

image_copy :: proc(cmd: vk.CommandBuffer, src: Image, dst: Image) {
    image_copy_subimage(cmd, src, src.extent, dst, dst.extent)
}

// Copy image using immediate command buffer
image_copy_now :: proc(renderer: ^Renderer, src: Image, dst: Image) {
    CommandCtx :: struct{ src: Image, dst: Image }
    copy_command_ctx := CommandCtx{
        src = src,
        dst = dst,
    }

    immediate_command_submit(renderer, &copy_command_ctx, proc(cmd: vk.CommandBuffer, user_data: rawptr) {
        ctx := (^CommandCtx)(user_data)
        src := ctx.src
        dst := ctx.dst
        image_copy_subimage(cmd, src, src.extent, dst, dst.extent)
    })
}

image_copy_subimage :: proc(cmd: vk.CommandBuffer, src: Image, src_extent: vk.Extent3D,
    dst: Image, dst_extent: vk.Extent3D) {

    blit_region := vk.ImageBlit2{ sType = .IMAGE_BLIT_2 }

	blit_region.srcOffsets[1].x = i32(src_extent.width)
	blit_region.srcOffsets[1].y = i32(src_extent.height)
	blit_region.srcOffsets[1].z = i32(src_extent.depth)

	blit_region.dstOffsets[1].x = i32(dst_extent.width)
	blit_region.dstOffsets[1].y = i32(dst_extent.height)
	blit_region.dstOffsets[1].z = i32(dst_extent.depth)

	blit_region.srcSubresource.aspectMask = src.aspect_flags
	blit_region.srcSubresource.baseArrayLayer = 0
	blit_region.srcSubresource.layerCount = 1
	blit_region.srcSubresource.mipLevel = 0

	blit_region.dstSubresource.aspectMask = dst.aspect_flags
	blit_region.dstSubresource.baseArrayLayer = 0
	blit_region.dstSubresource.layerCount = 1
	blit_region.dstSubresource.mipLevel = 0

    blit_info := vk.BlitImageInfo2{
        sType           = .BLIT_IMAGE_INFO_2,
        srcImage        = src.handle,
        srcImageLayout  = src.layout,
        dstImage        = dst.handle,
        dstImageLayout  = dst.layout,
        regionCount     = 1,
        pRegions        = &blit_region,
        filter          = .LINEAR
    }

    vk.CmdBlitImage2(cmd, &blit_info)
}

image_copy_to_buffer_now :: proc(renderer: ^Renderer, image: ^Image, buffer: ^Buffer) {

    CommandCtx :: struct{ image: ^Image, capture_buffer: ^Buffer, }
    copy_command_ctx := CommandCtx{
        image = image,
        capture_buffer = buffer,
    }

    immediate_command_submit(renderer, &copy_command_ctx, proc(cmd: vk.CommandBuffer, user_data: rawptr) {
        ctx := (^CommandCtx)(user_data)
        before_layout := ctx.image.layout
        image_transition(cmd, ctx.image, .TRANSFER_SRC_OPTIMAL)

        copy_info := vk.BufferImageCopy{
            imageExtent = ctx.image.extent,
            imageSubresource = {
                aspectMask      = ctx.image.aspect_flags,
                mipLevel        = 0,
            },
        }

        vk.CmdCopyImageToBuffer(cmd, ctx.image.handle, ctx.image.layout, ctx.capture_buffer.handle, 1, &copy_info)
        image_transition(cmd, ctx.image, before_layout)
    })
}

image_copy_data_to_image_now :: proc(renderer: ^Renderer, image: ^Image, data: rawptr, pixel_bytes: u64) {
    data_size: u64 = u64(image.extent.width) * u64(image.extent.height) * u64(image.extent.depth) * pixel_bytes

    upload_buffer := buffer_create(renderer, data_size, 1, { .TRANSFER_SRC }, .CPU_TO_GPU)
    defer buffer_destroy(renderer, &upload_buffer)
    buffer_map(renderer, &upload_buffer)
    buffer_write_data(renderer, &upload_buffer, data)
    buffer_unmap(renderer, &upload_buffer)

    CommandCtx :: struct{ image: ^Image, upload_buffer: Buffer, }
    copy_command_ctx := CommandCtx{
        image = image,
        upload_buffer = upload_buffer,
    }

    immediate_command_submit(renderer, &copy_command_ctx, proc(cmd: vk.CommandBuffer, user_data: rawptr) {
        ctx := (^CommandCtx)(user_data)
        image_transition(cmd, ctx.image, .TRANSFER_DST_OPTIMAL)

        copy_info := vk.BufferImageCopy{
            imageExtent = ctx.image.extent,
            imageSubresource = {
                aspectMask      = ctx.image.aspect_flags,
                mipLevel        = 0,
                layerCount      = 1,
            },
        }

        vk.CmdCopyBufferToImage(cmd, ctx.upload_buffer.handle, ctx.image.handle, .TRANSFER_DST_OPTIMAL, 1, &copy_info)
        image_transition(cmd, ctx.image, .SHADER_READ_ONLY_OPTIMAL)
    })
}

image_get_size :: proc(image_extent: vk.Extent3D, n_channels: int = 4) -> u64 { // rgba -> 4 channels by default
    return u64(image_extent.height) * u64(image_extent.width) * u64(image_extent.depth) * u64(n_channels)
}

@(private)
color_attachment_info_struct :: proc(image: Image, clear_value: ^vk.ClearValue) -> vk.RenderingAttachmentInfoKHR {
    return vk.RenderingAttachmentInfoKHR{
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView = image.view,
        imageLayout = image.layout,
        loadOp = clear_value == nil ? .LOAD : .CLEAR,
        storeOp = .STORE,
        clearValue = clear_value == nil ? {} : clear_value^,
    }
}

@(private)
depth_attachment_info_struct :: proc(image: Image) -> vk.RenderingAttachmentInfoKHR {
    return vk.RenderingAttachmentInfoKHR{
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView = image.view,
        imageLayout = image.layout,
        loadOp = .CLEAR,
        storeOp = .STORE,
    }
}
