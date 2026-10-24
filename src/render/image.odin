package render

import vk "vendor:vulkan"
import vma "../../thirdparty/vma"
import "core:math"
import "core:log"

Image :: struct {
    handle:         vk.Image,
    view:           vk.ImageView,
    allocation:     vma.Allocation, // if nil, then the image has or needs no allocation
    mem_properties: vk.MemoryPropertyFlags,

    layout:         vk.ImageLayout,
    extent:         vk.Extent3D,
    format:         vk.Format,
    aspect_flags:   vk.ImageAspectFlags,
    usage_flags:    vk.ImageUsageFlags, // only needed for images with an allocation
    mip_levels:     u32,
}

Texture :: struct {
    using image: Image,
    sampler: vk.Sampler
}

@(private="file")
format_aspect_flags :: proc(format: vk.Format) -> vk.ImageAspectFlags {
    #partial switch format {
    case .D16_UNORM, .X8_D24_UNORM_PACK32, .D32_SFLOAT:
        return { .DEPTH }
    case .D16_UNORM_S8_UINT, .D24_UNORM_S8_UINT, .D32_SFLOAT_S8_UINT:
        return { .DEPTH, .STENCIL }
    case .S8_UINT:
        return { .STENCIL }
    case:
        return { .COLOR }
    }
}

// Create an image using device-local memory.
// To move data in and out, use a CPU_WRITE/READ buffer. The image tiling will have to change.
image_create :: proc(renderer: ^Renderer, extent: vk.Extent3D, format: vk.Format,
    usage: vk.ImageUsageFlags, use_mipmaps: bool = false) -> Image {

    new_image := Image{
        layout          = .UNDEFINED,
        extent          = extent,
        format          = format,
        aspect_flags    = format_aspect_flags(format),
        usage_flags     = usage,
        mip_levels      = use_mipmaps ? u32(math.floor(math.log2(f32(math.max(extent.width, extent.height))))) + 1 : 1,
    }

    image_info := vk.ImageCreateInfo{
        sType       = .IMAGE_CREATE_INFO,
        imageType   = extent.depth > 1 ? .D3 : .D2,
        format      = format,
        extent      = extent,
        mipLevels   = new_image.mip_levels,
        arrayLayers = 1,
        samples     = { ._1 },
        tiling      = .OPTIMAL,
        usage       = usage,
    }

    alloc_info := vma.AllocationCreateInfo{ usage = .AUTO_PREFER_DEVICE }
    if (usage & { .COLOR_ATTACHMENT, .DEPTH_STENCIL_ATTACHMENT }) != {} {
        alloc_info.flags += { .DEDICATED_MEMORY } // render targets get their own allocation
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
    vma.GetAllocationMemoryProperties(renderer.allocator, new_image.allocation, &new_image.mem_properties)

    return new_image
}

// Creates a device-only image that will be used for texture purposes
texture_create :: proc(renderer: ^Renderer, extent: vk.Extent3D, sampler: vk.Sampler, format: vk.Format, usage: vk.ImageUsageFlags, use_mipmaps: bool = false) -> Texture {
    return Texture{
        image   = image_create(renderer, extent, format, usage, use_mipmaps),
        sampler = sampler,
    }
}

texture_create_from_data :: proc(renderer: ^Renderer, data: rawptr, extent: vk.Extent3D, sampler: vk.Sampler, format: vk.Format, usage: vk.ImageUsageFlags, use_mipmaps: bool = false) -> Texture {
    // TODO: generate mips. image_write_data only fills mip 0 for now
    assert(!use_mipmaps, "texture_create_from_data does not generate mipmaps yet")

    new_texture := texture_create(renderer, extent, sampler, format, usage + { .TRANSFER_DST }, use_mipmaps)
    image_write_data(renderer, &new_texture.image, data)
    return new_texture
}

texture_destroy :: proc(renderer: ^Renderer, texture: ^Texture) {
    image_destroy(renderer, &texture.image)
}

image_recreate :: proc(renderer: ^Renderer, image: ^Image, extent: vk.Extent3D) {
    use_mipmaps: bool = image.mip_levels > 1
    image_destroy(renderer, image)
    image^ = image_create(renderer, extent, image.format, image.usage_flags, use_mipmaps)
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

// Upload pixel data from mip 0 of the image to a buffer
image_copy_to_buffer_now :: proc(renderer: ^Renderer, image: ^Image, buffer: ^Buffer) {

    CommandCtx :: struct{ image: ^Image, buffer: ^Buffer, }
    copy_command_ctx := CommandCtx{
        image  = image,
        buffer = buffer,
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
                layerCount      = 1,
            },
        }

        vk.CmdCopyImageToBuffer(cmd, ctx.image.handle, ctx.image.layout, ctx.buffer.handle, 1, &copy_info)
        image_transition(cmd, ctx.image, before_layout)
    })
}

// Upload pixel data into mip 0 of the image via a staging buffer
// WARNING: Don't use this in the render loop, the immediate submit will slow things down.
//          Do it manually if you must copy device memory while recording a command buffer
image_write_data :: proc(renderer: ^Renderer, image: ^Image, data: rawptr) {
    data_size := image_get_size(image^)

    upload_buffer := buffer_create(renderer, data_size, 1, { .TRANSFER_SRC }, .CPU_WRITE)
    defer buffer_destroy(renderer, &upload_buffer)
    buffer_write_data(renderer, &upload_buffer, data, data_size)

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

// Size in bytes of mip 0 of the image when tightly packed in a buffer
image_get_size :: proc(image: Image) -> u64 {
    format_texel_bytes :: proc(format: vk.Format) -> u64 {
        #partial switch format {
        case .R8_UNORM, .R8_SNORM, .R8_UINT, .R8_SINT, .R8_SRGB, .S8_UINT:
            return 1
        case .R8G8_UNORM, .R8G8_SNORM, .R8G8_UINT, .R8G8_SINT, .R8G8_SRGB,
            .R16_UNORM, .R16_SNORM, .R16_UINT, .R16_SINT, .R16_SFLOAT, .D16_UNORM:
            return 2
        case .R8G8B8A8_UNORM, .R8G8B8A8_SNORM, .R8G8B8A8_UINT, .R8G8B8A8_SINT, .R8G8B8A8_SRGB,
            .B8G8R8A8_UNORM, .B8G8R8A8_SNORM, .B8G8R8A8_UINT, .B8G8R8A8_SINT, .B8G8R8A8_SRGB,
            .A2B10G10R10_UNORM_PACK32, .A2R10G10B10_UNORM_PACK32, .B10G11R11_UFLOAT_PACK32,
            .R16G16_UNORM, .R16G16_SFLOAT, .R32_UINT, .R32_SINT, .R32_SFLOAT,
            .D32_SFLOAT, .X8_D24_UNORM_PACK32:
            return 4
        case .R16G16B16A16_UNORM, .R16G16B16A16_SNORM, .R16G16B16A16_UINT, .R16G16B16A16_SINT, .R16G16B16A16_SFLOAT,
            .R32G32_UINT, .R32G32_SINT, .R32G32_SFLOAT:
            return 8
        case .R32G32B32_UINT, .R32G32B32_SINT, .R32G32B32_SFLOAT:
            return 12
        case .R32G32B32A32_UINT, .R32G32B32A32_SINT, .R32G32B32A32_SFLOAT:
            return 16
        case:
            log.panicf("format_texel_bytes: unsupported format %v", format)
        }
    }

    return u64(image.extent.width) * u64(image.extent.height) * u64(image.extent.depth) * format_texel_bytes(image.format)
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
