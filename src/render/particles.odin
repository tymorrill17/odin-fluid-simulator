package render

import vk "vendor:vulkan"
import "core:math/linalg"

// Describes an instance of a particle for the renderer
ParticleInstance :: struct {
    position:   float3,
    size:       f32,
    color:      float4,
}

ParticleMotion :: struct {
    data:       rawptr,
    started:    bool,
    update:     proc(system: ^CPUParticleSystem, dt: f32),
    destroy:    proc(data: rawptr), // optional, for freeing motion-specific buffers
}

CPUParticleSystem :: struct {
    particles:                      []ParticleInstance,
    motion:                         ParticleMotion,
    particle_count:                 u32,
    max_particles:                  u32,
    particle_buffers:               []Buffer,           // Buffer containing particle instances
    particle_buffer_addrs:          []vk.DeviceAddress, // What we actually send to the GPU
    current_particle_buffer_addr:   vk.DeviceAddress,  // Always points to the current in-use particle buffer address
    mesh:                           ^MeshAsset,         // Geometry to use for the particles
    material:                       ^MaterialInstance,  // Material pipeline to use for the rendered particles
    transform:                      float4x4,
}

particle_system_get_render_object :: proc(system: ^CPUParticleSystem, out: ^[dynamic]RenderObject) {
    append(out, RenderObject{
        index_count             = system.mesh.surfaces[0].count,
        first_index             = system.mesh.surfaces[0].start_index,
        index_buffer            = system.mesh.mesh_buffers.index_buffer.handle,
        material                = system.material,
        transform               = system.transform,
        vertex_buffer_addr      = system.mesh.mesh_buffers.vertex_buffer_addr,
        instance_buffer_addr    = system.current_particle_buffer_addr,
        instance_count          = system.particle_count,
    })
}

particle_system_create :: proc(renderer: ^Renderer, max_particles: u32, origin: float3,
    particle_mesh: ^MeshAsset, material: ^MaterialInstance) -> CPUParticleSystem {

    system := CPUParticleSystem{
        max_particles   = max_particles,
        transform       = linalg.matrix4_translate_f32(origin),
        material        = material,
        mesh            = particle_mesh,
        particle_count  = 0, // for now
    }

    system.particles             = make([]ParticleInstance, max_particles)
    system.particle_buffers      = make([]Buffer, renderer.frames_in_flight)
    system.particle_buffer_addrs = make([]vk.DeviceAddress, renderer.frames_in_flight)

    for i in 0..<renderer.frames_in_flight {
        system.particle_buffers[i] = buffer_create(renderer, size_of(ParticleInstance), u64(max_particles), { .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS }, .CPU_TO_GPU)
        addr_info := vk.BufferDeviceAddressInfo{
            sType  = vk.StructureType.BUFFER_DEVICE_ADDRESS_INFO,
            buffer = system.particle_buffers[i].handle,
        }
        system.particle_buffer_addrs[i] = vk.GetBufferDeviceAddress(renderer.logical_device, &addr_info)
        buffer_map(renderer, &system.particle_buffers[i])
    }
    system.current_particle_buffer_addr = system.particle_buffer_addrs[renderer.frame_index]

    return system
}

particle_system_update :: proc(system: ^CPUParticleSystem, renderer: ^Renderer, dt: f32) {
    if system.motion.update != nil {
        system.motion.update(system, dt)
    }
    buffer_write_data(renderer, &system.particle_buffers[renderer.frame_index], raw_data(system.particles), size = u64(system.particle_count) * size_of(ParticleInstance))
    system.current_particle_buffer_addr = system.particle_buffer_addrs[renderer.frame_index]
}

particle_system_destroy :: proc(system: ^CPUParticleSystem, renderer: ^Renderer) {
    if system.motion.destroy != nil do system.motion.destroy(system.motion.data)
    for i in 0..<len(system.particle_buffers) {
        buffer_destroy(renderer, &system.particle_buffers[i])
    }
    delete(system.particles)
    delete(system.particle_buffers)
    delete(system.particle_buffer_addrs)
}
