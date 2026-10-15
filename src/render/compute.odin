package render

import vk "vendor:vulkan"

ComputeResources :: struct {
    pipeline:    Pipeline,
    descriptors: [dynamic]^DescriptorSet,
}

ComputePass :: struct {
    data:     rawptr,
    dispatch: proc(cmd: vk.CommandBuffer, renderer: ^Renderer, data: rawptr),
}

compute_resource_bind :: proc(cmd: vk.CommandBuffer, resources: ^ComputeResources, frame_index: u32) {
    vk.CmdBindPipeline(cmd, resources.pipeline.bind_point, resources.pipeline.handle)
    if (len(resources.descriptors) > 0) {
        descriptor_set_bind(cmd, resources.pipeline.bind_point, resources.pipeline.layout,
            0, resources.descriptors[:], frame_index)
    }
}

compute_resources_create :: proc(pipeline: Pipeline, descriptors: []^DescriptorSet) -> ComputeResources {
    resources := ComputeResources{ pipeline = pipeline }
    resources.descriptors = make([dynamic]^DescriptorSet)
    append(&resources.descriptors, ..descriptors)
    return resources
}

compute_resources_destroy :: proc(renderer: ^Renderer, resources: ^ComputeResources) {
    pipeline_destroy(renderer, &resources.pipeline)
    delete(resources.descriptors)
    resources^ = {}
}

compute_execution_barrier :: proc(cmd: vk.CommandBuffer,
    src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2) {

    barrier := vk.MemoryBarrier2{
        sType           = .MEMORY_BARRIER_2,
        srcStageMask    = src_stage,
        srcAccessMask   = src_access,
        dstStageMask    = dst_stage,
        dstAccessMask   = dst_access,
    }

    dependency_info := vk.DependencyInfo{
        sType               = .DEPENDENCY_INFO,
        memoryBarrierCount  = 1,
        pMemoryBarriers     = &barrier,
    }

    vk.CmdPipelineBarrier2(cmd, &dependency_info)
}
