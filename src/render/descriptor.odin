package render

import vk "vendor:vulkan"
import "core:log"
import "core:mem/virtual"

MAX_SETS_PER_POOL :: 4096

PoolSizeRatio :: struct {
    type:  vk.DescriptorType,
    ratio: f32
}

DescriptorDynamicBinding :: struct {
    binding:    u32,
    alignment:  u64,
}

DescriptorSet :: struct {
    handle:             vk.DescriptorSet,
    dynamic_bindings:   [dynamic]DescriptorDynamicBinding,
}

// Descriptor Layout Builder

DescriptorLayoutBuilder :: struct {
    bindings:       [dynamic]vk.DescriptorSetLayoutBinding,
    built_layouts:  [dynamic]vk.DescriptorSetLayout,
}

descriptor_layout_builder_create :: proc() -> DescriptorLayoutBuilder {
    builder: DescriptorLayoutBuilder
    builder.bindings        = make([dynamic]vk.DescriptorSetLayoutBinding)
    builder.built_layouts   = make([dynamic]vk.DescriptorSetLayout)
    return builder
}

// Destroy DescriptorLayoutBuilder, freeing associated memory. NOTE: destroying the builder does not destroy
// the built layouts; you'll have to call that separately
descriptor_layout_builder_destroy :: proc(builder: ^DescriptorLayoutBuilder) {
    delete(builder.bindings)
    delete(builder.built_layouts)
    builder^ = {}
}

// Destroy all descriptor set layouts built by the builder.
descriptor_layout_builder_destroy_built_layouts :: proc(builder: ^DescriptorLayoutBuilder, renderer: ^Renderer) {
    for layout in builder.built_layouts {
        vk.DestroyDescriptorSetLayout(renderer.logical_device, layout, nil)
    }
    clear(&builder.built_layouts)
}

descriptor_layout_builder_add_binding :: proc(builder: ^DescriptorLayoutBuilder,
    binding: u32, descriptor_type: vk.DescriptorType, descriptor_count: uint, shader_stage: vk.ShaderStageFlags) {

    new_binding := vk.DescriptorSetLayoutBinding{
		binding         = binding,
		descriptorType  = descriptor_type,
		descriptorCount = u32(descriptor_count), // How many descriptors of the same type in this binding (used for bindless)
		stageFlags      = shader_stage
	}

    append(&builder.bindings, new_binding)
}

descriptor_layout_builder_build :: proc(builder: ^DescriptorLayoutBuilder, renderer: ^Renderer) -> vk.DescriptorSetLayout {
    set_layout: vk.DescriptorSetLayout

	descriptor_set_layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType           = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext           = nil,
		flags           = { },
		bindingCount    = cast(u32)len(builder.bindings),
		pBindings       = raw_data(builder.bindings[:]),
	};

    if vk.CreateDescriptorSetLayout(renderer.logical_device, &descriptor_set_layout_info, nil, &set_layout) != .SUCCESS {
        log.panic("Failed to create descriptor set layout!")
    }
    clear(&builder.bindings) // Clear bindings for next build
    append(&builder.built_layouts, set_layout) // Store the new layout in the destruction arena
    return set_layout
}

// Descriptor Allocator

// TODO: consider having a global descriptor pool and a per-frame one?
// Dynamic descriptor pool management structure
DescriptorAllocator :: struct {
    pool_size_ratios:   [dynamic]PoolSizeRatio,
    full_pools:         [dynamic]vk.DescriptorPool,
    open_pools:         [dynamic]vk.DescriptorPool,
    sets_per_pool:      uint,
    pool_flags:         vk.DescriptorPoolCreateFlags,
}

@(private)
descriptor_allocator_initialize :: proc(renderer: ^Renderer, initial_sets: uint, pool_size_ratios: []PoolSizeRatio, flags: vk.DescriptorPoolCreateFlags = {}) {
    renderer.descriptor_allocator.pool_size_ratios  = make([dynamic]PoolSizeRatio, len(pool_size_ratios))
    renderer.descriptor_allocator.full_pools        = make([dynamic]vk.DescriptorPool)
    renderer.descriptor_allocator.open_pools        = make([dynamic]vk.DescriptorPool)

    for ratio in pool_size_ratios {
        append(&renderer.descriptor_allocator.pool_size_ratios, ratio)
    }
    renderer.descriptor_allocator.pool_flags    = flags
    renderer.descriptor_allocator.sets_per_pool = uint(f32(initial_sets) * 1.5) // Next pool creation, allow for more sets

    descriptor_allocator_expand_open_pools(renderer, initial_sets, pool_size_ratios)
}

@(private)
descriptor_allocator_destroy :: proc(renderer: ^Renderer) {
    for pool in renderer.descriptor_allocator.open_pools {
        vk.DestroyDescriptorPool(renderer.logical_device, pool, nil)
    }
    delete(renderer.descriptor_allocator.open_pools)
    for pool in renderer.descriptor_allocator.full_pools {
        vk.DestroyDescriptorPool(renderer.logical_device, pool, nil)
    }
    delete(renderer.descriptor_allocator.full_pools)
    delete(renderer.descriptor_allocator.pool_size_ratios)
    renderer.descriptor_allocator = {}
}

@(private)
descriptor_allocator_reset_all :: proc(renderer: ^Renderer) {
    for pool in renderer.descriptor_allocator.open_pools {
        vk.ResetDescriptorPool(renderer.logical_device, pool, nil)
    }
    for pool in renderer.descriptor_allocator.full_pools {
        vk.ResetDescriptorPool(renderer.logical_device, pool, nil)
        append(&renderer.descriptor_allocator.open_pools, pool)
    }
    clear(&renderer.descriptor_allocator.full_pools)
}

@(private="file")
descriptor_allocator_expand_open_pools :: proc(renderer: ^Renderer, set_count: uint, pool_size_ratios: []PoolSizeRatio) {
    pool_sizes: []vk.DescriptorPoolSize = make([]vk.DescriptorPoolSize, len(pool_size_ratios))
    for ratio, i in pool_size_ratios {
        pool_sizes[i] = vk.DescriptorPoolSize{
            type            = ratio.type,
            descriptorCount = u32(ratio.ratio * f32(set_count)),
        }
    }

    pool_info := vk.DescriptorPoolCreateInfo{
        sType           = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
        flags           = renderer.descriptor_allocator.pool_flags,
        maxSets         = u32(set_count),
        poolSizeCount   = u32(len(pool_sizes)),
        pPoolSizes      = raw_data(pool_sizes)
    }

    pool: vk.DescriptorPool
    if vk.CreateDescriptorPool(renderer.logical_device, &pool_info, nil, &pool) != .SUCCESS {
        log.panic("Failed to expand descriptor allocator!")
    }

    append(&renderer.descriptor_allocator.open_pools, pool)
}

descriptor_set_create :: proc(renderer: ^Renderer, layouts: []vk.DescriptorSetLayout) -> DescriptorSet {
    get_open_pool :: proc(renderer: ^Renderer) -> vk.DescriptorPool {
        if len(renderer.descriptor_allocator.open_pools) == 0 { // There are no open pools, need to make one
            descriptor_allocator_expand_open_pools(renderer, renderer.descriptor_allocator.sets_per_pool, renderer.descriptor_allocator.pool_size_ratios[:])
            renderer.descriptor_allocator.sets_per_pool = uint(f32(renderer.descriptor_allocator.sets_per_pool) * 1.5)
            if renderer.descriptor_allocator.sets_per_pool > MAX_SETS_PER_POOL {
                renderer.descriptor_allocator.sets_per_pool = MAX_SETS_PER_POOL
            }
        }
        return renderer.descriptor_allocator.open_pools[len(renderer.descriptor_allocator.open_pools) - 1]
    }

    pool_to_use := get_open_pool(renderer)
    alloc_info := vk.DescriptorSetAllocateInfo{
        sType               = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool      = pool_to_use,
        descriptorSetCount  = u32(len(layouts)),
        pSetLayouts         = raw_data(layouts),
    }

    new_set: DescriptorSet
    new_set.dynamic_bindings = make([dynamic]DescriptorDynamicBinding)
    result: vk.Result
    if result = vk.AllocateDescriptorSets(renderer.logical_device, &alloc_info, &new_set.handle); result != .SUCCESS {
        if result == .ERROR_OUT_OF_POOL_MEMORY || result == .ERROR_FRAGMENTED_POOL {
            // Then try again with a new pool
            append(&renderer.descriptor_allocator.full_pools, pool_to_use)
            pop(&renderer.descriptor_allocator.open_pools)
            pool_to_use = get_open_pool(renderer)
            alloc_info.descriptorPool = pool_to_use
            result = vk.AllocateDescriptorSets(renderer.logical_device, &alloc_info, &new_set.handle)
        }
        if result != .SUCCESS {
            log.panic("Failed to allocate descriptor set!")
        }
    }

    return new_set
}

descriptor_set_destroy :: proc(set: ^DescriptorSet) {
    delete(set.dynamic_bindings)
    set^ = {}
}

descriptor_set_bind :: proc(cmd: vk.CommandBuffer, bind_point: vk.PipelineBindPoint,
    layout: vk.PipelineLayout, set: ^DescriptorSet, set_number: u32, offset: u32 = 0) {

    // TODO: use a memory arena to allocate this and speed things up. Same for below
    offsets := make([]u32, len(set.dynamic_bindings))
    defer delete(offsets)
    for binding, i in set.dynamic_bindings {
        offsets[i] = u32(u64(offset) * binding.alignment)
    }

    vk.CmdBindDescriptorSets(cmd, bind_point, layout, set_number,
        1, &set.handle, u32(len(offsets)), len(offsets) > 0 ? &offsets[0] : nil)
}

descriptor_sets_bind :: proc(cmd: vk.CommandBuffer, bind_point: vk.PipelineBindPoint,
    layout: vk.PipelineLayout, first_set_number: u32, sets: []^DescriptorSet, offset: u32) {

    handles := make([]vk.DescriptorSet, len(sets))
    defer delete(handles)
    for set, i in sets {
        handles[i] = set.handle
    }

    offsets := make([dynamic]u32)
    defer delete(offsets)
    reserve(&offsets, len(sets))
    for set in sets {
        for binding in set.dynamic_bindings {
            append(&offsets, u32(u64(offset) * binding.alignment))
        }
    }

    vk.CmdBindDescriptorSets(cmd, bind_point, layout, first_set_number,
        u32(len(sets)), &handles[0], u32(len(offsets)), len(offsets) > 0 ? &offsets[0] : nil)
}

// Descriptor Writer

DescriptorWriter :: struct {
    writes: [dynamic]vk.WriteDescriptorSet,
    arena:  virtual.Arena,
}

descriptor_writer_create :: proc() -> DescriptorWriter {
    writer: DescriptorWriter
    writer.writes = make([dynamic]vk.WriteDescriptorSet)
    err := virtual.arena_init_growing(&writer.arena)
    assert(err == nil)
    return writer
}

descriptor_writer_destroy :: proc(writer: ^DescriptorWriter) {
    delete(writer.writes)
    virtual.arena_destroy(&writer.arena)
    writer^ = {}
}

descriptor_writer_add_images :: proc(writer: ^DescriptorWriter, set: ^DescriptorSet, binding: uint, images: []Image, type: vk.DescriptorType) {
    writer_allocator := virtual.arena_allocator(&writer.arena)
    image_infos := make([]vk.DescriptorImageInfo, len(images), writer_allocator)
    for image, i in images {
        image_infos[i] = vk.DescriptorImageInfo{
            imageView   = image.view,
            imageLayout = image.layout,
        }
    }

    write := vk.WriteDescriptorSet{
        sType           = vk.StructureType.WRITE_DESCRIPTOR_SET,
        dstSet          = set.handle,
        dstBinding      = u32(binding),
        dstArrayElement = 0,
        descriptorCount = u32(len(images)),
        descriptorType  = type,
        pImageInfo      = raw_data(image_infos),
    }

    append(&writer.writes, write)
}

descriptor_writer_add_textures :: proc(writer: ^DescriptorWriter, set: ^DescriptorSet, binding: uint, textures: []Texture, type: vk.DescriptorType) {
    writer_allocator := virtual.arena_allocator(&writer.arena)
    image_infos := make([]vk.DescriptorImageInfo, len(textures), writer_allocator)
    for texture, i in textures {
        image_infos[i] = vk.DescriptorImageInfo{
            imageView   = texture.view,
            imageLayout = texture.layout,
            sampler     = texture.sampler,
        }
    }

    write := vk.WriteDescriptorSet{
        sType           = vk.StructureType.WRITE_DESCRIPTOR_SET,
        dstSet          = set.handle,
        dstBinding      = u32(binding),
        dstArrayElement = 0,
        descriptorCount = u32(len(textures)),
        descriptorType  = type,
        pImageInfo      = raw_data(image_infos),
    }

    append(&writer.writes, write)
}

descriptor_writer_add_buffers :: proc(writer: ^DescriptorWriter, set: ^DescriptorSet, binding: uint, buffers: []Buffer, type: vk.DescriptorType) {
    is_dynamic := type == .UNIFORM_BUFFER_DYNAMIC || type == .STORAGE_BUFFER_DYNAMIC
    writer_allocator := virtual.arena_allocator(&writer.arena)
    buffer_infos := make([]vk.DescriptorBufferInfo, len(buffers), writer_allocator)
    for buffer, i in buffers {
        buffer_infos[i] = vk.DescriptorBufferInfo{
            buffer = buffer.handle,
            offset = 0,
            range  = vk.DeviceSize(buffer.instance_bytes), // For dynamic buffers, we just want to write the size of one instance
        }
        // Dynamic Buffers must have offset info and they must be in order of binding
        if is_dynamic {
            entry := DescriptorDynamicBinding{
                binding = u32(binding),
                alignment = buffer.alignment
            }
            index: int
            for dyn_bind, j in set.dynamic_bindings {
                if dyn_bind.binding > entry.binding {
                    index = j; break
                }
                index = j + 1
            }
            inject_at(&set.dynamic_bindings, index, entry)
        }
    }

    write := vk.WriteDescriptorSet{
        sType           = vk.StructureType.WRITE_DESCRIPTOR_SET,
        dstSet          = set.handle,
        dstBinding      = u32(binding),
        dstArrayElement = 0,
        descriptorCount = u32(len(buffers)),
        descriptorType  = type,
        pBufferInfo     = raw_data(buffer_infos),
    }

    append(&writer.writes, write)
}

descriptor_writer_update_sets :: proc(writer: ^DescriptorWriter, renderer: ^Renderer) {
    vk.UpdateDescriptorSets(renderer.logical_device, u32(len(writer.writes)), raw_data(writer.writes), 0, nil)
    virtual.arena_free_all(&writer.arena)
    clear(&writer.writes)
}
