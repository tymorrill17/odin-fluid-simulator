package render

import vk "vendor:vulkan"
import "vendor:cgltf"
import "core:log"
import "core:strings"

MaterialPass :: enum {
    opaque,
    transparent,
}

MaterialInstance :: struct {
    pipeline:   Pipeline,
    descriptor: ^DescriptorSet,
    pass_type:  MaterialPass
}

RenderObject :: struct {
    index_count:            u32,
    first_index:            u32,
    index_buffer:           vk.Buffer, // index buffer for the mesh
    material:               ^MaterialInstance,
    transform:              ^float4x4,
    vertex_buffer_addr:     vk.DeviceAddress,
    instance_buffer_addr:   ^vk.DeviceAddress, // If we are rendering multiple instances of this object, store the positions here
    instance_count:         ^u32,              // How many instances are we rendering?
}

MeshBuffers :: struct {
    vertex_buffer:      Buffer,
    index_buffer:       Buffer,
    vertex_buffer_addr: vk.DeviceAddress
}

GeometricSurface :: struct {
    start_index:    u32,
    count:          u32,
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

// Send vertex and index data to the GPU by creating buffers and writing to them. Returns the created buffers.
@(private)
mesh_upload_to_GPU :: proc(renderer: ^Renderer, vertices: []MeshVertex, indices: []u32) -> MeshBuffers {
    vertex_buffer_size := u64(len(vertices) * size_of(MeshVertex))
    index_buffer_size := u64(len(indices) * size_of(u32))

    mesh: MeshBuffers
    mesh.vertex_buffer = buffer_create(renderer, vertex_buffer_size, 1, { .VERTEX_BUFFER, .TRANSFER_DST, .SHADER_DEVICE_ADDRESS }, .GPU_ONLY)
    addr_info := vk.BufferDeviceAddressInfo{
        sType = vk.StructureType.BUFFER_DEVICE_ADDRESS_INFO,
        buffer = mesh.vertex_buffer.handle
    }
    mesh.vertex_buffer_addr = vk.GetBufferDeviceAddress(renderer.logical_device, &addr_info)
    mesh.index_buffer = buffer_create(renderer, index_buffer_size, 1, { .INDEX_BUFFER, .TRANSFER_DST }, .GPU_ONLY)

    staging_buffer := buffer_create(renderer, vertex_buffer_size + index_buffer_size, 1, { .TRANSFER_SRC }, .CPU_ONLY)
    defer buffer_destroy(renderer, &staging_buffer)
    buffer_map(renderer, &staging_buffer)
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

            first_vertex := len(vertices)
            reserve(&indices, uint(len(indices)) + primitive.indices.count)
            for i in 0..<primitive.indices.count {
                append(&indices, u32(cgltf.accessor_read_index(primitive.indices, i)))
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
                    normal_accessor = attribute.data
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
            for i in 0..<normal_accessor.count {
                if !cgltf.accessor_read_float(normal_accessor, i, &vertices[i].normal[0], 3) do log.panic("Failed to read vertex normal")
            }

            // Load texture coords
            if uv_accessor != nil {
                for i in 0..<uv_accessor.count {
                    uv: float2
                    if !cgltf.accessor_read_float(uv_accessor, i, &uv[0], 2) do log.panic("Failed to read vertex uv")
                    vertices[i].uv_x = uv.x
                    vertices[i].uv_y = uv.y
                }
            }

            // Load colors
            if color_accessor != nil {
                for i in 0..<color_accessor.count {
                    if !cgltf.accessor_read_float(uv_accessor, i, &vertices[i].color[0], 4) do log.panic("Failed to read vertex color")
                }
            }

            new_mesh.surfaces[p] = new_surface
        }

        new_mesh.mesh_buffers = mesh_upload_to_GPU(renderer, vertices[:], indices[:])
        meshes[m] = new_mesh
    }

    cgltf.free(data);
    return meshes
}
