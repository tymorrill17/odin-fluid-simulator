package render

import vk "vendor:vulkan"
import vma "../../thirdparty/vma"
import "core:log"
import "core:mem"

Buffer :: struct {
    handle:         vk.Buffer,
    allocation:     vma.Allocation,
    data_ptr:       rawptr,

    total_bytes:    u64, // How many bytes IN TOTAL (including all instances)
    instance_bytes: u64, // How many bytes one instance uses
    instance_count: u64, // How many instances
    alignment:      u64, // device-specific data alignment

    mem_properties: vk.MemoryPropertyFlags,
    access:         BufferAccess,
}

BufferAccess :: enum {
    GPU_ONLY_ACCESS,    // Device-local
    CPU_WRITE,          // CPU writes sequentially. use for per-frame UBOs/SSBOs, etc
    CPU_READ,
    CPU_WRITE_IF_FAST,  // Device-local preferred, host-visible if device allows
}

@(private="file")
buffer_access_to_vma_flags :: proc(access: BufferAccess) -> (vma.MemoryUsage, vma.AllocationCreateFlags) {
    switch access {
    case .GPU_ONLY_ACCESS:
        return .AUTO_PREFER_DEVICE, {}
    case .CPU_WRITE:
        return .AUTO, { .HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED }
    case .CPU_READ:
        return .AUTO, { .HOST_ACCESS_RANDOM, .MAPPED }
    case .CPU_WRITE_IF_FAST:
        return .AUTO, { .HOST_ACCESS_SEQUENTIAL_WRITE, .HOST_ACCESS_ALLOW_TRANSFER_INSTEAD, .MAPPED }
    case:
        log.panic("Unknown access flag!")
    }
}

buffer_create :: proc(renderer: ^Renderer, instance_bytes: u64, instance_count: u64,
    usage: vk.BufferUsageFlags, access_flag: BufferAccess) -> Buffer {

    find_alignment :: proc(instance_bytes: u64, min_offset_alignment: u64) -> u64 {
        if min_offset_alignment > 0 {
            return (instance_bytes + min_offset_alignment - 1) & ~(min_offset_alignment - 1)
        }
        return instance_bytes
    }

    min_offset_alignment: u64
    if .UNIFORM_BUFFER in usage {
        min_offset_alignment = u64(renderer.physical_device_properties.limits.minUniformBufferOffsetAlignment)
    } else if .STORAGE_BUFFER in usage {
        min_offset_alignment = u64(renderer.physical_device_properties.limits.minStorageBufferOffsetAlignment)
    } else if (vk.BufferUsageFlags{ .UNIFORM_TEXEL_BUFFER, .STORAGE_TEXEL_BUFFER } & usage) != {} {
        // if there is a texel buffer, use the texel alignment
        min_offset_alignment = u64(renderer.physical_device_properties.limits.minTexelBufferOffsetAlignment)
    } else {
        min_offset_alignment = 1
    }

    alignment_bytes := find_alignment(instance_bytes, min_offset_alignment)

    new_buffer := Buffer{
        instance_bytes = instance_bytes,
        instance_count = instance_count,
        total_bytes = alignment_bytes * instance_count,
        alignment = alignment_bytes
    }

    buffer_info := vk.BufferCreateInfo{
        sType   = .BUFFER_CREATE_INFO,
        size    = vk.DeviceSize(new_buffer.total_bytes),
        usage   = usage
    }
    mem_usage, mem_flags := buffer_access_to_vma_flags(access_flag)
    alloc_info := vma.AllocationCreateInfo{
        flags = mem_flags,
        usage = mem_usage,
    }

    alloc_result: vma.AllocationInfo
    if vma.CreateBuffer(renderer.allocator, &buffer_info, &alloc_info, &new_buffer.handle, &new_buffer.allocation, &alloc_result) != .SUCCESS {
        log.panic("Failed to create buffer!")
    }
    new_buffer.data_ptr = alloc_result.pMappedData // This is nil if the buffer is device-only
    new_buffer.access = access_flag
    vma.GetAllocationMemoryProperties(renderer.allocator, new_buffer.allocation, &new_buffer.mem_properties)

    return new_buffer
}

buffer_destroy :: proc(renderer: ^Renderer, buffer: ^Buffer) {
    vma.DestroyBuffer(renderer.allocator, buffer.handle, buffer.allocation)
}

// Copy data into buffer memory, wherever it may be
// WARNING: If your buffer is device-only, don't use this in the render loop. The immediate submit will slow things down.
//          Do it manually if you must copy device memory while recording a command buffer
buffer_write_data :: proc(renderer: ^Renderer, buffer: ^Buffer,
    data: rawptr, size: u64, offset: u64 = 0) {

    assert(offset + size <= buffer.total_bytes) // Make sure we aren't overflowing

    // If he buffer is mapped, we have host-visible data. Copy it directly
    if buffer.data_ptr != nil {
        mem.copy_non_overlapping(rawptr(uintptr(buffer.data_ptr) + uintptr(offset)), data, int(size))

        // If memory is not host-coherent, we need to flush what we uploaded from the CPU
        if .HOST_COHERENT not_in buffer.mem_properties {
            vma.FlushAllocation(renderer.allocator, buffer.allocation, vk.DeviceSize(offset), vk.DeviceSize(size))
        }
        return
    }

    // Otherwise, we need a staging buffer
    staging_buffer := buffer_create(renderer, size, 1, { .TRANSFER_SRC }, .CPU_WRITE)
    defer buffer_destroy(renderer, &staging_buffer)
    buffer_write_data(renderer, &staging_buffer, data, size)

    CopyCtx :: struct { src, dst: vk.Buffer, region: vk.BufferCopy }
    ctx := CopyCtx{
        src    = staging_buffer.handle,
        dst    = buffer.handle,
        region = { srcOffset = 0, dstOffset = vk.DeviceSize(offset), size = vk.DeviceSize(size) },
    }

    immediate_command_submit(renderer, &ctx, proc(cmd: vk.CommandBuffer, user_data: rawptr) {
        ctx := (^CopyCtx)(user_data)
        vk.CmdCopyBuffer(cmd, ctx.src, ctx.dst, 1, &ctx.region)
    })
}

buffer_write_data_at_index :: proc(renderer: ^Renderer, buffer: ^Buffer,
    data: rawptr, index: u32) {

    buffer_write_data(renderer, buffer, data, buffer.instance_bytes, u64(index) * buffer.alignment)
}

