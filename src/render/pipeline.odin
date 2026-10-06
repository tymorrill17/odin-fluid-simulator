package render

import vk "vendor:vulkan"
import "core:log"

Pipeline :: struct {
    handle:                 vk.Pipeline,
    layout:                 vk.PipelineLayout,
    push_constant_stages:   vk.ShaderStageFlags,
    bind_point:             vk.PipelineBindPoint,
}

BlendingType :: enum {
    ADDITIVE,
    ALPHA,
    NONE,
}

PipelineConfig :: struct {
    shader_modules:                 [dynamic]vk.PipelineShaderStageCreateInfo,
    input_assembly:                 vk.PipelineInputAssemblyStateCreateInfo,
    rasterizer:                     vk.PipelineRasterizationStateCreateInfo,
    color_blend_attachment:         vk.PipelineColorBlendAttachmentState,
    multisampling:                  vk.PipelineMultisampleStateCreateInfo,
    depth_stencil:                  vk.PipelineDepthStencilStateCreateInfo,
    rendering_info:                 vk.PipelineRenderingCreateInfo,
    color_attachment_format:        vk.Format,
    descriptor_layouts:             [dynamic]vk.DescriptorSetLayout,
    push_constant_ranges:           [dynamic]vk.PushConstantRange,
    vertex_binding_descriptions:    [dynamic]vk.VertexInputBindingDescription,
    vertex_attribute_descriptions:  [dynamic]vk.VertexInputAttributeDescription,
}

pipeline_cfg_create :: proc() -> PipelineConfig {
    cfg: PipelineConfig
    cfg.shader_modules                  = make([dynamic]vk.PipelineShaderStageCreateInfo)
    cfg.descriptor_layouts              = make([dynamic]vk.DescriptorSetLayout)
    cfg.push_constant_ranges            = make([dynamic]vk.PushConstantRange)
    cfg.vertex_binding_descriptions     = make([dynamic]vk.VertexInputBindingDescription)
    cfg.vertex_attribute_descriptions   = make([dynamic]vk.VertexInputAttributeDescription)
    pipeline_cfg_clear(&cfg)
    return cfg
}

// Clean up the dynamic arrays in the PipelineConfig
pipeline_cfg_destroy :: proc(config: ^PipelineConfig) {
    delete(config.shader_modules)
    delete(config.descriptor_layouts)
    delete(config.push_constant_ranges)
    delete(config.vertex_binding_descriptions)
    delete(config.vertex_attribute_descriptions)
}

pipeline_cfg_clear :: proc(config: ^PipelineConfig) {
    clear(&config.shader_modules)
    config.input_assembly = { sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO }
    config.rasterizer = { sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO }
    config.color_blend_attachment = {}
    config.multisampling = { sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO }
    config.depth_stencil = { sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO }
    config.rendering_info = { sType = .PIPELINE_RENDERING_CREATE_INFO }
    config.color_attachment_format = vk.Format.UNDEFINED
    clear(&config.descriptor_layouts)
    clear(&config.push_constant_ranges)
    clear(&config.vertex_binding_descriptions)
    clear(&config.vertex_attribute_descriptions)
}

pipeline_cfg_add_shader :: proc(config: ^PipelineConfig, shader: vk.ShaderModule, shader_stage: vk.ShaderStageFlags, entry_point: cstring = "main") {
    shader_stage_info := vk.PipelineShaderStageCreateInfo{
        sType   = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage   = shader_stage,
        module  = shader,
        pName   = entry_point,
    }
    append(&config.shader_modules, shader_stage_info)
}

pipeline_cfg_set_input_topology :: proc(config: ^PipelineConfig, topology: vk.PrimitiveTopology) {
    config.input_assembly.topology = topology
    config.input_assembly.primitiveRestartEnable = false // not using for now
}

pipeline_cfg_set_polygon_mode :: proc(config: ^PipelineConfig, mode: vk.PolygonMode) {
    config.rasterizer.polygonMode = mode
    config.rasterizer.lineWidth = 1.0 // Defaulting to 1.0
}

pipeline_cfg_set_cull_mode :: proc(config: ^PipelineConfig, mode: vk.CullModeFlags, front_face: vk.FrontFace) {
    config.rasterizer.cullMode = mode
    config.rasterizer.frontFace = front_face
}

pipeline_cfg_set_multisampling :: proc(config: ^PipelineConfig, sample_count: vk.SampleCountFlags) {
    config.multisampling.sampleShadingEnable = false
    config.multisampling.rasterizationSamples = sample_count
    config.multisampling.minSampleShading = 1.0
    config.multisampling.pSampleMask = nil
    config.multisampling.alphaToCoverageEnable = false
    config.multisampling.alphaToOneEnable = false
}

pipeline_cfg_set_blending :: proc(config: ^PipelineConfig, blending_type: BlendingType) {
    config.color_blend_attachment.colorWriteMask = { .R, .G, .B, .A }
    switch blending_type {
    case .NONE:
        config.color_blend_attachment.blendEnable = false
    case .ADDITIVE:
        config.color_blend_attachment.blendEnable = true
        config.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
        config.color_blend_attachment.dstColorBlendFactor = .ONE
        config.color_blend_attachment.colorBlendOp = .ADD
        config.color_blend_attachment.srcAlphaBlendFactor = .ONE
        config.color_blend_attachment.dstColorBlendFactor = .SRC_ALPHA
        config.color_blend_attachment.alphaBlendOp = .ADD
    case .ALPHA:
        config.color_blend_attachment.blendEnable = true
        config.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
        config.color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
        config.color_blend_attachment.colorBlendOp = .ADD
        config.color_blend_attachment.srcAlphaBlendFactor = .ONE
        config.color_blend_attachment.dstColorBlendFactor = .ZERO
        config.color_blend_attachment.alphaBlendOp = .ADD
    }
}

pipeline_cfg_set_color_attachment_format :: proc(config: ^PipelineConfig, format: vk.Format) {
    config.color_attachment_format = format
    config.rendering_info.colorAttachmentCount = 1
    config.rendering_info.pColorAttachmentFormats = &config.color_attachment_format
}

pipeline_cfg_set_depth_attachment_format :: proc(config: ^PipelineConfig, format: vk.Format) {
    config.rendering_info.depthAttachmentFormat = format
}

pipeline_cfg_set_depth_test :: proc(config: ^PipelineConfig, compare_op: vk.CompareOp = vk.CompareOp.NEVER) {
    config.depth_stencil.depthTestEnable = compare_op == .NEVER ? false : true
    config.depth_stencil.depthWriteEnable = compare_op == .NEVER ? false : true
    config.depth_stencil.depthCompareOp = compare_op
    config.depth_stencil.depthBoundsTestEnable = false
    config.depth_stencil.minDepthBounds = 0
    config.depth_stencil.maxDepthBounds = 1
    config.depth_stencil.stencilTestEnable = false
    config.depth_stencil.front = {}
    config.depth_stencil.back = {}
}

pipeline_cfg_add_descriptor :: proc(config: ^PipelineConfig, descriptor_layout: vk.DescriptorSetLayout) {
    append(&config.descriptor_layouts, descriptor_layout)
}

pipeline_cfg_add_vertex_binding_desc :: proc(config: ^PipelineConfig, binding_desc: vk.VertexInputBindingDescription) {
    append(&config.vertex_binding_descriptions, binding_desc)
}

pipeline_cfg_add_vertex_attribute_desc :: proc(config: ^PipelineConfig, attribute_desc: vk.VertexInputAttributeDescription) {
    append(&config.vertex_attribute_descriptions, attribute_desc)
}

pipeline_cfg_add_push_constant_range :: proc(config: ^PipelineConfig, shader_stages: vk.ShaderStageFlags, size: u32, offset: u32 = 0) {
    append(&config.push_constant_ranges, vk.PushConstantRange{
        stageFlags  = shader_stages,
        offset      = offset,
        size        = size,
    })
}

pipeline_cfg_build_pipeline :: proc(config: ^PipelineConfig, renderer: ^Renderer) -> Pipeline {
    vertex_input_state := vk.PipelineVertexInputStateCreateInfo{
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount   = u32(len(config.vertex_binding_descriptions)),
        pVertexBindingDescriptions      = raw_data(config.vertex_binding_descriptions),
        vertexAttributeDescriptionCount = u32(len(config.vertex_attribute_descriptions)),
        pVertexAttributeDescriptions    = raw_data(config.vertex_attribute_descriptions),
    }

    viewport_state := vk.PipelineViewportStateCreateInfo{
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount   = 1,
        scissorCount    = 1,
    }

    // Set up dummy color blending until we use transparent objects
    color_blending_state := vk.PipelineColorBlendStateCreateInfo{
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        logicOpEnable   = false,
        logicOp         = vk.LogicOp.COPY,
        attachmentCount = 1,
        pAttachments    = &config.color_blend_attachment,
    }

    states: []vk.DynamicState = { vk.DynamicState.VIEWPORT, vk.DynamicState.SCISSOR }
    dynamic_state := vk.PipelineDynamicStateCreateInfo{
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount   = u32(len(states)),
        pDynamicStates      = raw_data(states),
    }

    pipeline_layout := pipeline_layout_create(renderer, config.descriptor_layouts[:], config.push_constant_ranges[:])

    pipeline_info := vk.GraphicsPipelineCreateInfo{
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext               = &config.rendering_info,
        stageCount          = u32(len(config.shader_modules)),
        pStages             = raw_data(config.shader_modules),
        pVertexInputState   = &vertex_input_state,
        pInputAssemblyState = &config.input_assembly,
        pViewportState      = &viewport_state,
        pRasterizationState = &config.rasterizer,
        pMultisampleState   = &config.multisampling,
        pDepthStencilState  = &config.depth_stencil,
        pColorBlendState    = &color_blending_state,
        pDynamicState       = &dynamic_state,
        layout              = pipeline_layout,
        renderPass          = NULL_HANDLE
    }

    pipeline_handle: vk.Pipeline
    if vk.CreateGraphicsPipelines(renderer.logical_device, NULL_HANDLE, 1, &pipeline_info, nil, &pipeline_handle) != .SUCCESS {
        log.panic("Failed to create pipeline!")
    }

    new_pipeline := Pipeline{
        handle      = pipeline_handle,
        layout      = pipeline_layout,
        bind_point  = .GRAPHICS
    }

    for range in config.push_constant_ranges {
        new_pipeline.push_constant_stages += range.stageFlags
    }

    return new_pipeline
}

pipeline_destroy :: proc(renderer: ^Renderer, pipeline: ^Pipeline) {
    vk.DestroyPipeline(renderer.logical_device, pipeline.handle, nil)
    vk.DestroyPipelineLayout(renderer.logical_device, pipeline.layout, nil)
    pipeline^ = {}
}

@(private="file")
pipeline_layout_create :: proc(renderer: ^Renderer, descriptor_layouts: []vk.DescriptorSetLayout,
    push_constant_ranges: []vk.PushConstantRange) -> vk.PipelineLayout {
    pipeline_layout_info := vk.PipelineLayoutCreateInfo{
        sType                   = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount          = u32(len(descriptor_layouts)),
        pSetLayouts             = raw_data(descriptor_layouts),
        pushConstantRangeCount  = u32(len(push_constant_ranges)),
        pPushConstantRanges     = raw_data(push_constant_ranges),
    }

    pipeline_layout: vk.PipelineLayout
    if vk.CreatePipelineLayout(renderer.logical_device, &pipeline_layout_info, nil, &pipeline_layout) != .SUCCESS {
        log.panic("Failed to create pipeline layout!")
    }

    return pipeline_layout
}


