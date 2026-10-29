package render

import vk "vendor:vulkan"
import "vendor:cgltf"
import "core:log"
import "core:strings"
import "core:math/linalg"

ASSET_DIR :: #config(ASSET_DIR, ".")

RenderObject :: struct {
    index_count:            u32,
    first_index:            u32,
    index_buffer:           vk.Buffer, // index buffer for the mesh
    material:               ^MaterialInstance,
    transform:              float4x4,
    vertex_buffer_addr:     vk.DeviceAddress,
    instance_buffer_addr:   vk.DeviceAddress,  // If we are rendering multiple instances of this object, store the positions here
    instance_count:         u32,               // How many instances are we rendering?
}

MaterialPass :: enum {
    opaque,
    transparent,
}

MaterialInstance :: struct {
    pipeline:   Pipeline,
    descriptor: ^DescriptorSet,
    pass_type:  MaterialPass
}

MaterialMetallicRoughnessGLTF :: struct {
    opaque_pipeline:        Pipeline,
    transparent_pipeline:   Pipeline,
    set_layout:             vk.DescriptorSetLayout,
    set:                    DescriptorSet,

    constants: struct {
        color_factors:          float4,
        metal_rough_factors:    float4,
        extra_padding:          [14]float4,
    },

    resources: struct {
        color_texture:           Texture,
        metal_rough_texture:     Texture,
        constants_buffer:        Buffer,
    },
}

GeometricSurface :: struct {
    start_index:    u32,
    count:          u32,
    material:       ^MaterialInstance
}

MeshBuffers :: struct {
    vertex_buffer:      Buffer,
    index_buffer:       Buffer,
    vertex_buffer_addr: vk.DeviceAddress
}

MeshAsset :: struct {
    name:           string,
    surfaces:       []GeometricSurface,
    mesh_buffers:   MeshBuffers,
}

MeshVertex :: struct {
    position:   float3,
    uv_x:       f32,
    normal:     float3,
    uv_y:       f32,
    color:      float4,
};

SceneGraph :: struct {
    root:  ^SceneGraphNode,
    depth: int, // Depth of the graph (really a tree)
}

SceneGraphNode :: struct {
    parent:            ^SceneGraphNode,
    children:          []^SceneGraphNode,
    local_transform:   float4x4,
    world_transform:   float4x4,
    get_render_object: proc(^SceneGraphNode, ^[dynamic]RenderObject, float4x4),
}

MeshNode :: struct {
    using node: SceneGraphNode,
    mesh:       ^MeshAsset,
}

material_metallic_roughness_create :: proc(renderer: ^Renderer, color_texture: Texture, metal_rough_texture: Texture) -> MaterialMetallicRoughnessGLTF {

    material_metallic_roughness_build_pipelines :: proc(renderer: ^Renderer, material: ^MaterialMetallicRoughnessGLTF) {
        pipeline_cfg := pipeline_cfg_create()
        defer pipeline_cfg_destroy(&pipeline_cfg)

        shader := shader_module_create_from_file(renderer, "gltf_metallic_roughness.slang.spv")
        defer shader_module_destroy(renderer, shader)

        pipeline_cfg_add_shader(&pipeline_cfg, shader, { .VERTEX }, "vertex_main")
        pipeline_cfg_add_shader(&pipeline_cfg, shader, { .FRAGMENT }, "fragment_main")
        pipeline_cfg_add_push_constant_range(&pipeline_cfg, { .VERTEX, }, size_of(DrawPushConstants))

        pipeline_cfg_add_descriptor(&pipeline_cfg, renderer.scene_descriptor_layout)
        pipeline_cfg_add_descriptor(&pipeline_cfg, material.set_layout)

        pipeline_cfg_set_input_topology(&pipeline_cfg, .TRIANGLE_LIST)
        pipeline_cfg_set_polygon_mode(&pipeline_cfg, .FILL)
        pipeline_cfg_set_cull_mode(&pipeline_cfg, {}, .COUNTER_CLOCKWISE)
        pipeline_cfg_set_multisampling(&pipeline_cfg, { ._1 })
        pipeline_cfg_set_blending(&pipeline_cfg, .NONE)
        pipeline_cfg_set_depth_test(&pipeline_cfg, .GREATER_OR_EQUAL)
        pipeline_cfg_set_color_attachment_format(&pipeline_cfg, renderer.draw_image.format)
        pipeline_cfg_set_depth_attachment_format(&pipeline_cfg, renderer.depth_image.format)
        material.opaque_pipeline = pipeline_cfg_build_pipeline(&pipeline_cfg, renderer)

        pipeline_cfg_set_blending(&pipeline_cfg, .ADDITIVE)
        pipeline_cfg_set_depth_test(&pipeline_cfg, .NEVER)
        material.transparent_pipeline = pipeline_cfg_build_pipeline(&pipeline_cfg, renderer)
    }

    material: MaterialMetallicRoughnessGLTF
    material.resources.color_texture = color_texture
    material.resources.metal_rough_texture = metal_rough_texture

    material.constants.color_factors = { 1, 1, 1, 1 }
    material.constants.metal_rough_factors = { 1, 0.5, 0, 0 }
    material.resources.constants_buffer = buffer_create(renderer, size_of(material.constants), 1, { .UNIFORM_BUFFER, .TRANSFER_DST }, .GPU_ONLY_ACCESS)
    buffer_write_data(renderer, &material.resources.constants_buffer, &material.constants, size_of(material.constants))

    descriptor_layout_builder_add_binding(&renderer.descriptor_layout_builder, 0, .UNIFORM_BUFFER, 1, { .VERTEX, .FRAGMENT })
    descriptor_layout_builder_add_binding(&renderer.descriptor_layout_builder, 1, .COMBINED_IMAGE_SAMPLER, 1, { .VERTEX, .FRAGMENT })
    descriptor_layout_builder_add_binding(&renderer.descriptor_layout_builder, 2, .COMBINED_IMAGE_SAMPLER, 1, { .VERTEX, .FRAGMENT })
    material.set_layout = descriptor_layout_builder_build(&renderer.descriptor_layout_builder, renderer)
    material.set = descriptor_set_create(renderer, material.set_layout)

    descriptor_writer_add_buffers(&renderer.descriptor_writer, &material.set, 0,
        { material.resources.constants_buffer }, .UNIFORM_BUFFER)
    descriptor_writer_add_textures(&renderer.descriptor_writer, &material.set, 1,
        { material.resources.color_texture }, .COMBINED_IMAGE_SAMPLER)
    descriptor_writer_add_textures(&renderer.descriptor_writer, &material.set, 2,
        { material.resources.metal_rough_texture }, .COMBINED_IMAGE_SAMPLER)
    descriptor_writer_update_sets(&renderer.descriptor_writer, renderer)

    material_metallic_roughness_build_pipelines(renderer, &material)

    return material
}

// Textures are owned by the caller and the set layout is owned by the descriptor layout cache, so neither is destroyed here.
material_metallic_roughness_destroy :: proc(material: ^MaterialMetallicRoughnessGLTF, renderer: ^Renderer) {
    pipeline_destroy(renderer, &material.opaque_pipeline)
    pipeline_destroy(renderer, &material.transparent_pipeline)
    buffer_destroy(renderer, &material.resources.constants_buffer)
    descriptor_set_destroy(&material.set)
    material^ = {}
}

// Send vertex and index data to the GPU by creating buffers and writing to them. Returns the created buffers.
@(private)
mesh_upload_to_GPU :: proc(renderer: ^Renderer, vertices: []MeshVertex, indices: []u32) -> MeshBuffers {
    vertex_buffer_size := u64(len(vertices) * size_of(MeshVertex))
    index_buffer_size := u64(len(indices) * size_of(u32))

    mesh: MeshBuffers
    mesh.vertex_buffer = buffer_create(renderer, vertex_buffer_size, 1, { .VERTEX_BUFFER, .TRANSFER_DST, .SHADER_DEVICE_ADDRESS }, .GPU_ONLY_ACCESS)
    addr_info := vk.BufferDeviceAddressInfo{
        sType = vk.StructureType.BUFFER_DEVICE_ADDRESS_INFO,
        buffer = mesh.vertex_buffer.handle
    }
    mesh.vertex_buffer_addr = vk.GetBufferDeviceAddress(renderer.logical_device, &addr_info)
    mesh.index_buffer = buffer_create(renderer, index_buffer_size, 1, { .INDEX_BUFFER, .TRANSFER_DST }, .GPU_ONLY_ACCESS)

    staging_buffer := buffer_create(renderer, vertex_buffer_size + index_buffer_size, 1, { .TRANSFER_SRC }, .CPU_WRITE)
    defer buffer_destroy(renderer, &staging_buffer)
    buffer_write_data(renderer, &staging_buffer, raw_data(vertices), vertex_buffer_size)
    buffer_write_data(renderer, &staging_buffer, raw_data(indices), index_buffer_size, vertex_buffer_size)

    UploadData :: struct {
        staging_buffer:     Buffer,
        vertex_buffer:      Buffer,
        index_buffer:       Buffer,
        vertex_buffer_size: u64,
        index_buffer_size:  u64,
    }

    upload_data := UploadData{
        staging_buffer      = staging_buffer,
        vertex_buffer       = mesh.vertex_buffer,
        index_buffer        = mesh.index_buffer,
        vertex_buffer_size  = vertex_buffer_size,
        index_buffer_size   = index_buffer_size
    }

    immediate_command_submit(renderer, &upload_data, proc(cmd: vk.CommandBuffer, user_data: rawptr) {
        data := (^UploadData)(user_data)

        vertex_copy := vk.BufferCopy{
            srcOffset = 0,
            dstOffset = 0,
            size      = vk.DeviceSize(data.vertex_buffer_size),
        }
        vk.CmdCopyBuffer(cmd, data.staging_buffer.handle, data.vertex_buffer.handle, 1, &vertex_copy)

        index_copy := vk.BufferCopy{
            srcOffset = vk.DeviceSize(data.vertex_buffer_size),
            dstOffset = 0,
            size      = vk.DeviceSize(data.index_buffer_size),
        }
        vk.CmdCopyBuffer(cmd, data.staging_buffer.handle, data.index_buffer.handle, 1, &index_copy)
    })

    return mesh
}

@(private)
mesh_buffers_destroy :: proc(renderer: ^Renderer, buffers: ^MeshBuffers) {
    buffer_destroy(renderer, &buffers.vertex_buffer)
    buffer_destroy(renderer, &buffers.index_buffer)
}

// Primitives

mesh_create_rectangle :: proc(renderer: ^Renderer, width, height: f32) -> ^MeshAsset {
    half_x_len := width / 2
    half_y_len := height / 2
    vertices := []MeshVertex{
        { position = {-half_x_len, -half_y_len, 0}, uv_x = 0, normal = {0, 0, 1}, uv_y = 0, color = {1, 1, 1, 1} }, // bottom-left
        { position = { half_x_len, -half_y_len, 0}, uv_x = 1, normal = {0, 0, 1}, uv_y = 0, color = {1, 1, 1, 1} }, // bottom-right
        { position = { half_x_len,  half_y_len, 0}, uv_x = 1, normal = {0, 0, 1}, uv_y = 1, color = {1, 1, 1, 1} }, // top-right
        { position = {-half_x_len,  half_y_len, 0}, uv_x = 0, normal = {0, 0, 1}, uv_y = 1, color = {1, 1, 1, 1} }, // top-left
    }
    indices := []u32{
        0, 1, 2,
        2, 3, 0,
    }

    mesh := new(MeshAsset)
    mesh.mesh_buffers = mesh_upload_to_GPU(renderer, vertices, indices)
    mesh.surfaces = make([]GeometricSurface, 1)
    mesh.surfaces[0] = { start_index = 0, count = u32(len(indices)) }

    return mesh
}
mesh_destroy :: proc(renderer: ^Renderer, mesh: ^MeshAsset) {
    mesh_buffers_destroy(renderer, &mesh.mesh_buffers)
    delete(mesh.surfaces)
    free(mesh)
}

mesh_load_gltf :: proc(renderer: ^Renderer, filename: string) -> []^MeshAsset {
    c_filename := strings.clone_to_cstring(filename)
    defer delete(c_filename)

    options: cgltf.options = {}
    data, result := cgltf.parse_file(options, c_filename);
    if (result != .success) {
        log.panicf("Failed to load GLTF file %s!", filename)
    }
    defer cgltf.free(data);

    if cgltf.load_buffers(options, data, c_filename) != .success {
        log.panicf("Failed to load GLTF buffers from %s!", filename)
    }

    meshes := make([]^MeshAsset, len(data.meshes))

    indices := make([dynamic]u32)
    vertices := make([dynamic]MeshVertex)
    defer delete(indices)
    defer delete(vertices)

    for mesh, m in data.meshes {
        new_mesh := new(MeshAsset)
        new_mesh.name = string(mesh.name)
        new_mesh.surfaces = make([]GeometricSurface, len(mesh.primitives))

        clear(&indices)
        clear(&vertices)

        // Load the primitive's indices
        for primitive, p in mesh.primitives {
            new_surface: GeometricSurface
            new_surface.start_index = u32(len(indices))
            new_surface.count = u32(primitive.indices.count)

            first_vertex := uint(len(vertices))
            reserve(&indices, uint(len(indices)) + primitive.indices.count)
            for i in 0..<primitive.indices.count {
                append(&indices, u32(cgltf.accessor_read_index(primitive.indices, i)) + u32(first_vertex))
            }

            // Find the accessors for the other quantities
            vertexpos_accessor: ^cgltf.accessor = nil
            normal_accessor:    ^cgltf.accessor = nil
            uv_accessor:        ^cgltf.accessor = nil
            color_accessor:     ^cgltf.accessor = nil
            for attribute, i in primitive.attributes {
                #partial switch attribute.type {
                case .position:
                   vertexpos_accessor = attribute.data
                case .normal:
                    if attribute.index == 0 do normal_accessor = attribute.data
                case .texcoord:
                    // There may be multiple sets of uv
                    if attribute.index == 0 do uv_accessor = attribute.data
                case .color:
                    // There may be multiple sets of color
                    if attribute.index == 0 do color_accessor = attribute.data
                }
            }

            // Load vertices
            reserve(&vertices, uint(len(vertices) + vertexpos_accessor.count))
            for i in 0..<vertexpos_accessor.count {
                vertex := MeshVertex{
                    position = 0,
                    normal = { 1, 0, 0},
                    color = 1,
                    uv_x = 0,
                    uv_y = 0,
                }
                if !cgltf.accessor_read_float(vertexpos_accessor, i, &vertex.position[0], 3) do log.panic("Failed to read vertex pos")
                append(&vertices, vertex)
            }

            // Load normals
            if normal_accessor != nil {
                for i in 0..<normal_accessor.count {
                    if !cgltf.accessor_read_float(normal_accessor, i, &vertices[i + first_vertex].normal[0], 3) do log.panic("Failed to read vertex normal")
                }
            }

            // Load texture coords
            if uv_accessor != nil {
                for i in 0..<uv_accessor.count {
                    uv: float2
                    if !cgltf.accessor_read_float(uv_accessor, i, &uv[0], 2) do log.panic("Failed to read vertex uv")
                    vertices[i + first_vertex].uv_x = uv.x
                    vertices[i + first_vertex].uv_y = uv.y
                }
            }

            // Load colors
            if color_accessor != nil {
                for i in 0..<color_accessor.count {
                    if !cgltf.accessor_read_float(color_accessor, i, &vertices[i + first_vertex].color[0], 4) do log.panic("Failed to read vertex color")
                }
            }

            new_mesh.surfaces[p] = new_surface
        }

        new_mesh.mesh_buffers = mesh_upload_to_GPU(renderer, vertices[:], indices[:])
        meshes[m] = new_mesh
    }

    return meshes
}

// Converts MeshAsset to a RenderObject
mesh_asset_get_render_object :: proc(node: ^SceneGraphNode, render_object_list: ^[dynamic]RenderObject, transform: float4x4) {
    node := (^MeshNode)(node)
    mesh := node.mesh
    for surface in mesh.surfaces {
        append(render_object_list, RenderObject{
            index_count = surface.count,
            first_index = surface.start_index,
            index_buffer = mesh.mesh_buffers.index_buffer.handle,
            material = surface.material,
            transform = transform,
            vertex_buffer_addr = mesh.mesh_buffers.vertex_buffer_addr,
            instance_count = 1,
            instance_buffer_addr = 0,
        })
    }
}

scene_graph_get_render_objects :: proc(graph: ^SceneGraph, render_object_list: ^[dynamic]RenderObject) {
    if graph == nil do return
    // Traverse the scene graph, building render objects and adding them to the list
    stack := make([]^SceneGraphNode, graph.depth)
    defer delete(stack)
    count: int = 1
    node: ^SceneGraphNode
    stack[0] = graph.root
    for count > 0 {
        // Pop the first node
        count -= 1
        node = stack[count]

        // Add it to the render_object_list
        node.get_render_object(node, render_object_list, node.world_transform)

        // Push each child on to the stack in reverse order so they get popped in a consistent ordering
        #reverse for child in node.children {
            stack[count] = child
            count += 1
        }
    }

}

scene_graph_create :: proc() -> SceneGraph {
    return SceneGraph{
        root = nil,
        depth = 0,
    }
}
