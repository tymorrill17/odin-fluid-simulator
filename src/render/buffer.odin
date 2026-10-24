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

    properties:     vk.MemoryPropertyFlags
}

buffer_create :: proc(renderer: ^Renderer, instance_bytes: u64, instance_count: u64,
    usage: vk.BufferUsageFlags, memory_usage: vma.MemoryUsage) -> Buffer {

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

    alloc_info := vma.AllocationCreateInfo{
        flags = { .MAPPED },
        usage = memory_usage,
    }

    alloc_result: vma.AllocationInfo
    if vma.CreateBuffer(renderer.allocator, &buffer_info, &alloc_info, &new_buffer.handle, &new_buffer.allocation, &alloc_result) != .SUCCESS {
        log.panic("Failed to create buffer!")
    }
    new_buffer.data_ptr = alloc_result.pMappedData // This is nil if the buffer is device-only
    vma.GetAllocationMemoryProperties(renderer.allocator, new_buffer.allocation, &new_buffer.properties)
    // log.debug("memory_usage: ", memory_usage, ", properties: ", new_buffer.properties)

    return new_buffer
}

buffer_destroy :: proc(renderer: ^Renderer, buffer: ^Buffer) {
    vma.DestroyBuffer(renderer.allocator, buffer.handle, buffer.allocation)
}

buffer_map :: proc(renderer: ^Renderer, buffer: ^Buffer) {
    if vma.MapMemory(renderer.allocator, buffer.allocation, &buffer.data_ptr) != .SUCCESS {
        log.panic("Failed to map memory to buffer!")
    }
}

buffer_unmap :: proc(renderer: ^Renderer, buffer: ^Buffer) {
    vma.UnmapMemory(renderer.allocator, buffer.allocation)
}

buffer_write_data :: proc(renderer: ^Renderer, buffer: ^Buffer,
    data: rawptr, size: u64 = vk.WHOLE_SIZE, offset: u64 = 0) {

    if size == vk.WHOLE_SIZE {
        mem.copy_non_overlapping(buffer.data_ptr, data, int(buffer.total_bytes))
    } else {
        offset_data := ([^]u8)(buffer.data_ptr)
        mem.copy_non_overlapping(&offset_data[offset], data, int(size))
    }
}

buffer_write_data_at_index :: proc(renderer: ^Renderer, buffer: ^Buffer,
    data: rawptr, index: u32) {

    buffer_write_data(renderer, buffer, data, buffer.instance_bytes, u64(index) * buffer.alignment)
}

