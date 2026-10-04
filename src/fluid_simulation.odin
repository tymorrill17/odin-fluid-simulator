package main

import "render"
import "core:math"
import "core:slice"
import "core:thread"
import "base:runtime"
import "core:sync"
import "core:os"
import "core:math/linalg"
import "core:math/rand"

MAX_PARTICLES :: 5000000

FluidSimParticleConfig :: struct {
    spacing:        f32,
    radius:         f32,
    n_particles:    u32,
    default_color:  render.float4,
}

FluidSimPhysicsConfig :: struct {
    gravity:                    f32,
    boundary_damping:           f32,
    density_smoothing_radius:   f32,
    pressure_constant:          f32,
    near_pressure_multiplier:   f32,
    viscosity:                  f32,
    rest_density:               f32,
    n_substeps:                 u32,
    time_step:                  f32,
    max_time_step:              f32,
    // interaction_strength:       f32,
    // interaction_radius:         f32,
};

FluidSimAction :: enum {
    pushing,
    pulling,
}

FluidSimState :: struct($N: int) {
    system:                 ^render.CPUParticleSystem,
    particle_cfg:           ^FluidSimParticleConfig,
    physics_cfg:            ^FluidSimPhysicsConfig,
    bbox:                   ^BoundingBox(N),

    // input:                  ^render.InputManager,
    // Mouse interaction
    // interaction_pos:        [N]f32,
    // is_interacting:         bool,
    // interaction:            FluidSimAction,

    // Particle properties
    density:                []f32,
    near_density:           []f32,
    acceleration:           [][N]f32,
    velocity:               [][N]f32,
    position:               [][N]f32,
    color:                  []render.float4,

    // Pertaining to spatial hashing
    cell_particle_count:    []u32,
    cell_prefix_sum:        []u32,
    spatial_lookup:         []u32,
    sorted_particle_index:  []u32,

    hash_size:              u32, // Must be a power of 2
    hash_mask:              u32, // hash_size - 1

    // Extra needed quantities
    positions2:             [][N]f32,
    velocities2:            [][N]f32,
    l2:                     [][N]f32,

    particle_count:         u32,
    accumulated_time:       f32,
    n_steps_per_update:     int,

    // Multi-threading
    n_worker_threads:       int,
    worker_threads:         []^thread.Thread, // of size n_worker_threads - 1 since main thread is worker 0
    thread_barrier:         sync.Barrier,
    thread_start_semaphore: sync.Sema,
    thread_quit:            bool,
}

NeighborhoodIterator :: struct($N: int) {
    sim_state:              ^FluidSimState(N),
    position:               [N]f32,
    particle_positions:     [^][N]f32,
    grid_cell:              [N]i32,
    smoothing_radius_sq:    f32,
    offset_idx:             int,
    offset_count:           int,
    sorted_slot:            u32,
    sorted_slot_end:        u32,
}

BoundingBox :: struct($N: int) {
    min: [N]f32,
    max: [N]f32,
}

BoundingBox2D :: BoundingBox(2)
BoundingBox3D :: BoundingBox(3)

fluidsim_get_material :: proc(renderer: ^render.Renderer) -> render.MaterialInstance{

    pipeline_cfg := render.pipeline_cfg_create()
    defer render.pipeline_cfg_destroy(&pipeline_cfg)

    shader := render.shader_module_create_from_file(renderer, "particle.slang.spv")
    defer render.shader_module_destroy(renderer, shader)

    render.pipeline_cfg_add_shader(&pipeline_cfg, shader, { .VERTEX }, "billboard")
    render.pipeline_cfg_add_shader(&pipeline_cfg, shader, { .FRAGMENT }, "render_quad_as_circle")
    render.pipeline_cfg_set_input_topology(&pipeline_cfg, .TRIANGLE_LIST)
    render.pipeline_cfg_set_polygon_mode(&pipeline_cfg, .FILL)
    render.pipeline_cfg_set_cull_mode(&pipeline_cfg, {}, .CLOCKWISE)
    render.pipeline_cfg_set_multisampling(&pipeline_cfg, { ._1 })
    render.pipeline_cfg_set_blending(&pipeline_cfg, .NONE)
    render.pipeline_cfg_set_color_attachment_format(&pipeline_cfg, renderer.draw_image.format)
    render.pipeline_cfg_set_depth_attachment_format(&pipeline_cfg, renderer.depth_image.format)
    render.pipeline_cfg_set_depth_test(&pipeline_cfg, .GREATER_OR_EQUAL)
    render.pipeline_cfg_add_push_constant_range(&pipeline_cfg, { .VERTEX }, size_of(render.DrawPushConstants))

    for layout in renderer.scene_descriptor_layouts {
        render.pipeline_cfg_add_descriptor(&pipeline_cfg, layout)
    }

    material: render.MaterialInstance
    material.pass_type = .opaque

    // Material descriptor set creation

    // material_descriptor_layout: vk.DescriptorSetLayout
    // render.pipeline_cfg_add_descriptor(&pipeline_cfg, material_descriptor_layout)
    // material_descriptor: vk.DescriptorSet
    // material.descriptor = material_descriptor

    material.pipeline = render.pipeline_cfg_build_pipeline(&pipeline_cfg, renderer)
    return material
}

fluidsim_state_create :: proc(system: ^render.CPUParticleSystem, particle_cfg: ^FluidSimParticleConfig, physics_cfg: ^FluidSimPhysicsConfig,
    bounds: ^BoundingBox($N)) -> render.ParticleMotion {

    state := new(FluidSimState(N))
    state.system                = system
    state.particle_cfg          = particle_cfg
    state.physics_cfg           = physics_cfg
    state.color                 = make([]render.float4, system.max_particles)
    state.position              = make([][N]f32, system.max_particles)
    state.velocity              = make([][N]f32, system.max_particles)
    state.acceleration          = make([][N]f32, system.max_particles)
    state.density               = make([]f32, system.max_particles)
    state.near_density          = make([]f32, system.max_particles)
    state.spatial_lookup        = make([]u32, system.max_particles)
    state.sorted_particle_index = make([]u32, system.max_particles)

    max_hash := get_hash_size(system.max_particles)
    state.cell_particle_count   = make([]u32, max_hash)
    state.cell_prefix_sum       = make([]u32, max_hash + 1)
    state.particle_count        = system.particle_count
    state.bbox                  = bounds
    state.accumulated_time      = 0

    state.positions2            = make([][N]f32, system.max_particles)
    state.velocities2           = make([][N]f32, system.max_particles)
    state.l2                    = make([][N]f32, system.max_particles)

    state.n_worker_threads = max(1, os.get_processor_core_count())
    sync.barrier_init(&state.thread_barrier, state.n_worker_threads)
    sync.atomic_store(&state.thread_quit, false) // thread_quit should only be stored and loaded via atomic operations
    worker_proc: thread.Thread_Proc
    when N == 2 {
        worker_proc = fluidsim_worker_proc_2d
    } else when N == 3 {
        worker_proc = fluidsim_worker_proc_3d
    }

    // Initialize the worker threads
    state.worker_threads = make([]^thread.Thread, state.n_worker_threads - 1)
    for &t, i in state.worker_threads {
        t = thread.create(worker_proc)

        t.data = state
        t.user_index = i + 1 // main thread is 0

        // each thread will get its own new context
        t.init_context = runtime.default_context()
        thread.start(t) // Start the thread, which will immediately begin waiting for an update step
    }

    when N == 2 {
        return render.ParticleMotion{ data = state, started = false, update = fluidsim_update_particles_2d, destroy = fluidsim_state_destroy_2d }
    } else when N == 3 {
        return render.ParticleMotion{ data = state, started = false, update = fluidsim_update_particles_3d, destroy = fluidsim_state_destroy_3d }
    } else {
        #panic("FluidSimState only supports N == 2 or N == 3")
    }
}

@(private="file")
fluidsim_state_destroy_2d :: proc(data: rawptr) {
    fluidsim_state_destroy(2, data)
}
@(private="file")
fluidsim_state_destroy_3d :: proc(data: rawptr) {
    fluidsim_state_destroy(3, data)
}

@(private="file")
fluidsim_state_destroy :: proc($N: int, data: rawptr) {
    state := cast(^FluidSimState(N))data

    sync.atomic_store(&state.thread_quit, true)
    if len(state.worker_threads) > 0 { // Make sure all the threads wake to know they have to quit
        sync.sema_post(&state.thread_start_semaphore, len(state.worker_threads))
    }

    thread.join_multiple(..state.worker_threads)
    for &t in state.worker_threads {
        thread.destroy(t)
    }
    delete(state.worker_threads)

    delete(state.color)
    delete(state.position)
    delete(state.velocity)
    delete(state.acceleration)
    delete(state.density)
    delete(state.near_density)
    delete(state.cell_particle_count)
    delete(state.cell_prefix_sum)
    delete(state.spatial_lookup)
    delete(state.sorted_particle_index)

    delete(state.positions2)
    delete(state.velocities2)
    delete(state.l2)

    free(state)
}

@(private="file")
fluidsim_set_init_particle_positions :: proc(system: ^render.CPUParticleSystem, sim_state: ^FluidSimState($N), particle_cfg: FluidSimParticleConfig) {
    spacing := particle_cfg.radius + particle_cfg.spacing

    // Arrange particles in a cube centered at origin
    grid_size := int(math.ceil(math.pow(f32(system.particle_count), 1.0 / f32(N))))
    for grid_size > 1 && int(math.pow(f32(grid_size - 1), f32(N))) >= int(system.particle_count) do grid_size -= 1 // Guard against float rounding up

    offset: [N]f32
    for d in 0..<N do offset[d] = f32(-(grid_size - 1)) * 0.5 * spacing

    for i in 0..<system.particle_count {
        pos: [N]f32
        rem := int(i)
        for d in 0..<N {
            pos[d] = f32(rem % grid_size) * spacing + offset[d]
            rem /= grid_size
        }

        sim_state.position[i]       = pos
        sim_state.acceleration[i]   = 0
        sim_state.velocity[i]       = 0
        sim_state.color[i]          = particle_cfg.default_color
        system.particles[i].size    = particle_cfg.radius
    }
}

@(private="file")
fluidsim_update_particles_2d :: proc(system: ^render.CPUParticleSystem, dt: f32) {
    fluidsim_update_particles(2, system, dt)
}
@(private="file")
fluidsim_update_particles_3d :: proc(system: ^render.CPUParticleSystem, dt: f32) {
    fluidsim_update_particles(3, system, dt)
}

@(private="file")
fluidsim_update_particles :: proc($N: int, system: ^render.CPUParticleSystem, dt: f32) {
    sim_state := cast(^FluidSimState(N))system.motion.data

    // Update the changes from the input
    // fluidsim_update_mouse_input(sim_state)

    // Update the particle system with the new config info if it has changed while the program is running
    system.particle_count    = sim_state.particle_cfg.n_particles
    sim_state.particle_count = sim_state.particle_cfg.n_particles
    sim_state.hash_size      = get_hash_size(sim_state.particle_count)
    sim_state.hash_mask      = sim_state.hash_size - 1
    if sim_state.particle_cfg.radius != system.particles[0].size {
        for i in 0..<system.particle_count {
            system.particles[i].size = sim_state.particle_cfg.radius
        }
    }

    PARALLEL_THRESHOLD :: 100

    if !system.motion.started {
        sim_state.accumulated_time = 0
        fluidsim_set_init_particle_positions(system, sim_state, sim_state.particle_cfg^)
    } else {
        sim_state.accumulated_time += math.min(dt, sim_state.physics_cfg.max_time_step)
        sim_state.n_steps_per_update = 0
        for sim_state.accumulated_time >= sim_state.physics_cfg.time_step {
            sim_state.accumulated_time -= sim_state.physics_cfg.time_step
            sim_state.n_steps_per_update += 1
        }

        if sim_state.particle_count < PARALLEL_THRESHOLD {
            fluidsim_run_update_step_sequential(N, sim_state)
        } else {
            sync.sema_post(&sim_state.thread_start_semaphore, sim_state.n_worker_threads - 1) // Increment the semaphore by the number of worker threads minus the main thread to wake the workers
            fluidsim_run_update_step_parallel2(N, sim_state, 0)
        }
    }

    for i in 0..<system.particle_count {
        when N == 2 {
            system.particles[i].position = { sim_state.position[i][0], sim_state.position[i][1], 0 }
        } else when N == 3 {
            system.particles[i].position = sim_state.position[i]
        }
        system.particles[i].color = sim_state.color[i]
    }
}

@(private="file")
fluidsim_worker_proc_2d :: proc(t: ^thread.Thread) {
    fluidsim_worker_proc(2, t)
}

@(private="file")
fluidsim_worker_proc_3d :: proc(t: ^thread.Thread) {
    fluidsim_worker_proc(3, t)
}

// The worker thread proc. It waits on the start semaphore after
@(private="file")
fluidsim_worker_proc :: proc($N: int, t: ^thread.Thread) {
    sim_state := cast(^FluidSimState(N))t.data
    for {
        sync.sema_wait(&sim_state.thread_start_semaphore)
        if sync.atomic_load(&sim_state.thread_quit) do break
        fluidsim_run_update_step_parallel2(N, sim_state, t.user_index)
    }
}

// Slightly worse stability, but better performance than the other version.
@(private="file")
fluidsim_run_update_step_parallel2 :: proc($N: int, sim_state: ^FluidSimState(N), worker_index: int) {
    first, last := get_worker_index_range(sim_state.particle_count, worker_index, sim_state.n_worker_threads)

    sub_dt := sim_state.physics_cfg.time_step / f32(sim_state.physics_cfg.n_substeps)
    for _ in 0..<sim_state.n_steps_per_update {
        for _ in 0..<sim_state.physics_cfg.n_substeps {

            // Compute acceleration due to gravity to make a prediction of the positions
            // TODO: Here is where I will probably compute viscosity to use for the prediction?
            gravity_dir: [N]f32
            gravity_dir.y = -1
            gravity_acceleration := gravity_dir * sim_state.physics_cfg.gravity
            for i in first..<last {
                sim_state.velocities2[i] = sim_state.velocity[i] + sub_dt * gravity_acceleration
                sim_state.positions2[i]  = sim_state.position[i] + sub_dt * sim_state.velocities2[i]
            }
            sync.barrier_wait(&sim_state.thread_barrier)

            // update spatial lookup table using predicted positions
            if worker_index == 0 do update_spatial_lookup(sim_state.positions2, sim_state)
            sync.barrier_wait(&sim_state.thread_barrier)

            // calculate particle densities using predicted positions
            for i in first..<last do sim_state.density[i], sim_state.near_density[i] = calculate_densities(i, sim_state.positions2, sim_state)
            sync.barrier_wait(&sim_state.thread_barrier)

            // get the actual acceleration and integrate the velocity
            // Integrate position and resolve boundary collisions
            for i in first..<last {
                sim_state.acceleration[i] = calculate_acceleration(i, sim_state.positions2, sim_state.velocities2, sim_state)
                sim_state.velocity[i] += sub_dt * sim_state.acceleration[i]
                sim_state.position[i] += sub_dt * sim_state.velocity[i]
            }
            resolve_boundary_collisions(sim_state, first, last)
            sync.barrier_wait(&sim_state.thread_barrier)
        }
    }
}

@(private="file")
fluidsim_run_update_step_parallel :: proc($N: int, sim_state: ^FluidSimState(N), worker_index: int) {
    first, last := get_worker_index_range(sim_state.particle_count, worker_index, sim_state.n_worker_threads)

    sub_dt := sim_state.physics_cfg.time_step / f32(sim_state.physics_cfg.n_substeps)
    half_dt := sub_dt * 0.5
    for _ in 0..<sim_state.n_steps_per_update {
        for _ in 0..<sim_state.physics_cfg.n_substeps {

            // update spatial lookup table
            if worker_index == 0 do update_spatial_lookup(sim_state.position, sim_state)
            sync.barrier_wait(&sim_state.thread_barrier)

            // calculate particle densities
            for i in first..<last do sim_state.density[i], sim_state.near_density[i] = calculate_densities(i, sim_state.position, sim_state)
            sync.barrier_wait(&sim_state.thread_barrier)

            // get acceleration & integrate k2 and l2
            for i in first..<last {
                sim_state.acceleration[i] = calculate_acceleration(i, sim_state.position, sim_state.velocity, sim_state)
                sim_state.velocities2[i]  = sim_state.velocity[i] + sub_dt * sim_state.acceleration[i]
                sim_state.positions2[i]   = sim_state.position[i] + sub_dt * sim_state.velocities2[i]
            }
            sync.barrier_wait(&sim_state.thread_barrier)

            // update spatial lookup for 2nd particles array (should this happen?)
            if worker_index == 0 do update_spatial_lookup(sim_state.positions2, sim_state)
            sync.barrier_wait(&sim_state.thread_barrier)

            // calculate particle densities for 2nd particles array
            for i in first..<last do sim_state.density[i], sim_state.near_density[i] = calculate_densities(i, sim_state.positions2, sim_state)
            sync.barrier_wait(&sim_state.thread_barrier)

            // get acceleration (for 2nd particles array
            // combine both particles array to get the next pos and vel
            for i in first..<last {
                sim_state.l2[i] = calculate_acceleration(i, sim_state.positions2, sim_state.velocities2, sim_state)
                sim_state.velocity[i] += half_dt * (sim_state.acceleration[i] + sim_state.l2[i])
                sim_state.position[i] += half_dt * (sim_state.velocity[i] + sim_state.velocities2[i])
            }
            // resolve boundary collisions
            resolve_boundary_collisions(sim_state, first, last)
            sync.barrier_wait(&sim_state.thread_barrier)
        }
    }
}

@(private="file")
fluidsim_run_update_step_sequential :: proc($N: int, sim_state: ^FluidSimState(N)) {
    sub_dt := sim_state.physics_cfg.time_step / f32(sim_state.physics_cfg.n_substeps)
    half_dt := sub_dt * 0.5
    for _ in 0..<sim_state.n_steps_per_update {
        for _ in 0..<sim_state.physics_cfg.n_substeps {
            // update spatial lookup table
            update_spatial_lookup(sim_state.position, sim_state)

            // calculate particle densities
            calculate_all_densities(sim_state.position, sim_state)

            // get acceleration
            calculate_all_accelerations(sim_state.position, sim_state.velocity, sim_state)

            // find k2 and l2
            for i in 0..<sim_state.particle_count {
                sim_state.velocities2[i] = sim_state.velocity[i] + sub_dt * sim_state.acceleration[i]
                sim_state.positions2[i] = sim_state.position[i] + sub_dt * sim_state.velocities2[i]
            }

            // update spatial lookup for 2nd particles array (should this happen?)
            update_spatial_lookup(sim_state.positions2, sim_state)

            // calculate particle densities for 2nd particles array
            calculate_all_densities(sim_state.positions2, sim_state)

            // get acceleration (for 2nd particles array
            calculate_all_accelerations_to_array(sim_state.positions2, sim_state.velocities2, sim_state, sim_state.l2)

            // combine both particles array to get the next pos and vel
            for i in 0..<sim_state.particle_count {
                sim_state.position[i] += half_dt * (sim_state.velocity[i] + sim_state.velocities2[i])
                sim_state.velocity[i] += half_dt * (sim_state.acceleration[i] + sim_state.l2[i])
            }

            // resolve boundary collisions
            resolve_boundary_collisions(sim_state, 0, sim_state.particle_count)
        }
    }
}

// Find the particle index range for the given thread. It is distributed in chunks the size of the cache line
@(private="file")
get_worker_index_range :: proc(particle_count: u32, worker_index, n_worker_threads: int) -> (low, high: u32) {
    WORKER_THREAD_CHUNK_ALIGN :: 64 / size_of(f32) // 64 byte cache line alignment

    n_chunks_total      := (particle_count + WORKER_THREAD_CHUNK_ALIGN - 1) / WORKER_THREAD_CHUNK_ALIGN
    n_chunks_per_thread := n_chunks_total / u32(n_worker_threads)
    n_chunks_leftover   := n_chunks_total % u32(n_worker_threads)
    worker_index        := u32(worker_index)

    low  = n_chunks_per_thread * worker_index + min(worker_index, n_chunks_leftover)
    high = low + n_chunks_per_thread + (worker_index < n_chunks_leftover ? 1 : 0)

    // Clamp the bounds to the number of particles so we don't go out of bounds
    low  = min(low  * WORKER_THREAD_CHUNK_ALIGN, particle_count)
    high = min(high * WORKER_THREAD_CHUNK_ALIGN, particle_count)
    return low, high
}

// Capture the input state for the current frame so each physics step sees the same input
// @(private="file")
// fluidsim_update_mouse_input :: proc(sim_state: ^FluidSimState($N)) {
//     input := sim_state.input
//     if input == nil do return
//
//     sim_state.is_interacting = false
//     if input.mouse_states[.left].down {
//         sim_state.is_interacting    = true
//         sim_state.interaction       = .pushing
//     } else if input.mouse_states[.right].down {
//         sim_state.is_interacting    = true
//         sim_state.interaction       = .pulling
//     }
//
//     world := input.mouse_position // TODO: convert to actual coords
//     when N == 2 {
//         sim_state.interaction_pos = { world.x, world.y }
//     } else when N == 3 {
//         sim_state.interaction_pos = { world.x, world.y, 0 }
//     }
// }

@(private="file")
get_grid_cell :: proc(position: [$N]f32, cell_size: f32) -> [N]i32 {
    cell: [N]i32
    for d in 0..<N do cell[d] = i32(math.floor(position[d] / cell_size))
    return cell
}

@(private="file")
GRID_HASH_PRIMES := [3]u32{ 73856093, 19349663, 83492791 }

@(private="file")
hash_grid_cell :: proc(grid_cell: [$N]i32, hash_mask: u32) -> u32 {
    hash: u32 = 0
    for i in 0..<N do hash += u32(grid_cell[i]) * GRID_HASH_PRIMES[i]
    return hash & hash_mask
}

HASH_PARTICLES_PER_BUCKET :: 4
MIN_HASH_SIZE :: 64

@(private="file")
get_next_power_of_2 :: proc(n: u32) -> u32 {
    if n == 0 do return 1
    n := n - 1
    n |= n >> 1
    n |= n >> 2
    n |= n >> 4
    n |= n >> 8
    n |= n >> 16
    return n + 1
}

@(private="file")
get_hash_size :: proc(particle_count: u32) -> u32 {
    n := particle_count / HASH_PARTICLES_PER_BUCKET
    if n < MIN_HASH_SIZE do n = MIN_HASH_SIZE
    return get_next_power_of_2(n)
}

// Discretize space into an infinite grid. Populate the lookup table and sort it based on its hash value.
@(private="file")
update_spatial_lookup :: proc(positions: [][$N]f32, sim_state: ^FluidSimState(N)) {
    count               := sim_state.particle_count
    hash_size           := sim_state.hash_size
    cell_size           := sim_state.physics_cfg.density_smoothing_radius
    spatial_lookup      := sim_state.spatial_lookup[:count]
    sorted_indices      := sim_state.sorted_particle_index[:count]
    cell_prefix_sum     := sim_state.cell_prefix_sum[:hash_size + 1]
    cell_particle_count := sim_state.cell_particle_count[:hash_size]

    // Capture the grid hash for each particle, keep a histogram of the grid hashes
    slice.zero(cell_particle_count)
    for i in 0..<count {
        grid_cell_hash := hash_grid_cell(get_grid_cell(positions[i], cell_size), sim_state.hash_mask)
        // Each particle has a spatial lookup value in the form of a hash of the grid cell index.
        // The particles will be sorted based on their grid_cell_hash so that particles in the same
        // cell are adjacent in the array.
        spatial_lookup[i] = grid_cell_hash
        cell_particle_count[grid_cell_hash] += 1
    }

    // This is the main counting sort mechanism. Each cell_prefix_sum bucket will contain the location in the sorted array
    // of the last instance of the current bucket index
    running_total: u32 = 0
    for k in 0..<hash_size {
        cell_prefix_sum[k] = running_total
        running_total += cell_particle_count[k]
        cell_particle_count[k] = cell_prefix_sum[k]
    }
    cell_prefix_sum[hash_size] = running_total // Should be entire particle count

    // Fill the sorted array
    for i in 0..<count {
        sorted_slot := cell_particle_count[spatial_lookup[i]]
        cell_particle_count[spatial_lookup[i]] += 1
        sorted_indices[sorted_slot] = i
    }
}

// Density and near density (Clavet et al. 2005) share one neighbor walk
@(private="file")
calculate_densities :: proc(particle_idx: u32, particle_positions: [][$N]f32, sim_state: ^FluidSimState(N)) -> (density, near_density: f32) {
    radius := sim_state.physics_cfg.density_smoothing_radius
    iter := neighborhood_iterator_make(sim_state, particle_positions[particle_idx], raw_data(particle_positions))
    for dist, _, ok := neighborhood_iterator_next(&iter); ok; dist, _, ok = neighborhood_iterator_next(&iter) {
        dist_sq := linalg.dot(dist, dist)
        when N == 2 {
            density      += kernel_density_2D(dist_sq, radius)
            near_density += kernel_near_density_2D(dist_sq, radius)
        } else when N == 3 {
            density      += kernel_density_3D(dist_sq, radius)
            near_density += kernel_near_density_3D(dist_sq, radius)
        }
    }
    assert(density != 0)
    return density, near_density
}

@(private="file")
calculate_all_densities :: proc(particle_positions: [][$N]f32, sim_state: ^FluidSimState(N)) {
    for i in 0..<sim_state.particle_count {
        sim_state.density[i], sim_state.near_density[i] = calculate_densities(i, particle_positions, sim_state)
    }
}

// @(private="file")
// calculate_interaction_force  :: proc(particle_idx: u32, particle_positions, particle_velocities: [][$N]f32, sim_state: ^FluidSimState(N)) -> [N]f32 {
//     interaction_acceleration: [N]f32 = 0
//     if sim_state.is_interacting {
//         // RMB pulls the particles in, LMB button pushes them away
//         interaction_strength := sim_state.interaction == .pulling ? sim_state.physics_cfg.interaction_strength : -sim_state.physics_cfg.interaction_strength
//         interaction_radius   := sim_state.physics_cfg.interaction_radius
//
//         // Hand is interacting, so find the vector from the hand to the particle and find its squared distance
//         particle_to_hand := sim_state.interaction_pos - particle_positions[particle_idx]
//         sqr_dst          := linalg.dot(particle_to_hand, particle_to_hand)
//
//         // If particle is in hand radius, change acceleration on particle
//         if sqr_dst > 0 && sqr_dst < interaction_radius * interaction_radius {
//             dst             := math.sqrt(sqr_dst)
//             center_factor   := 1 - dst / interaction_radius
//             direction       := particle_to_hand / dst // normalize
//             interaction_acceleration += (direction * interaction_strength - particle_velocities[particle_idx]) * center_factor
//         }
//     }
//     return interaction_acceleration
// }

@(private="file")
calculate_acceleration :: proc(particle_idx: u32, particle_positions, particle_velocities: [][$N]f32, sim_state: ^FluidSimState(N)) -> [N]f32 {

    // Apply interaction force from the mouse
    // interaction_acceleration := calculate_interaction_force(particle_idx, particle_positions, particle_velocities, sim_state)

    // Get the pressure force and convert it to acceleration by dividing density
    pressure_acceleration  := calculate_pressure_force(particle_idx, particle_positions, sim_state.density, sim_state) / sim_state.density[particle_idx]
    viscosity_acceleration := calculate_viscosity_force(particle_idx, particle_positions, particle_velocities, sim_state.density, sim_state) / sim_state.density[particle_idx]

    gravity_dir: [N]f32
    gravity_dir.y = -1
    gravity_acceleration := gravity_dir * sim_state.physics_cfg.gravity

    // return interaction_acceleration + pressure_acceleration + viscosity_acceleration + gravity_acceleration
    return pressure_acceleration + viscosity_acceleration + gravity_acceleration
}

@(private="file")
calculate_all_accelerations :: proc(particle_positions, particle_velocities: [][$N]f32, sim_state: ^FluidSimState(N)) {
    for i in 0..<sim_state.particle_count {
        sim_state.acceleration[i] = calculate_acceleration(i, particle_positions, particle_velocities, sim_state)
    }
}
@(private="file")
calculate_all_accelerations_to_array :: proc(particle_positions, particle_velocities: [][$N]f32, sim_state: ^FluidSimState(N), out_accel: [][N]f32) {
    for i in 0..<sim_state.particle_count {
        out_accel[i] = calculate_acceleration(i, particle_positions, particle_velocities, sim_state)
    }
}

@(private="file")
get_pressure :: proc(density: f32, physics_cfg: ^FluidSimPhysicsConfig) -> f32 {
    return (density - physics_cfg.rest_density) * physics_cfg.pressure_constant
}

@(private="file")
get_shared_pressure :: proc(density, other_density: f32, physics_cfg: ^FluidSimPhysicsConfig) -> f32 {
    pressure := get_pressure(density, physics_cfg)
    other_pressure := get_pressure(other_density, physics_cfg)
    return (pressure + other_pressure) * 0.5
}

@(private="file")
get_shared_near_pressure :: proc(density, other_density: f32, physics_cfg: ^FluidSimPhysicsConfig) -> f32 {
    pressure := density * physics_cfg.near_pressure_multiplier
    other_pressure := other_density * physics_cfg.near_pressure_multiplier
    return (pressure + other_pressure) * 0.5
}

@(private="file")
get_random_dir :: proc($N: int) -> [N]f32 {
    dir: [N]f32
    length_sq: f32
    for {
        for d in 0..<N do dir[d] = f32(rand.norm_float64())
        length_sq = linalg.dot(dir, dir)
        if length_sq > 0 do break
    }
    return dir / math.sqrt(length_sq)
}

@(private="file")
get_shared_viscosity :: proc(velocity, other_velocity: [$N]f32, physics_cfg: ^FluidSimPhysicsConfig) -> [N]f32 {
    return physics_cfg.viscosity * (other_velocity - velocity)
}

@(private="file")
calculate_viscosity_force :: proc(particle_idx: u32, particle_positions: [][$N]f32, particle_velocities: [][N]f32, densities: []f32, sim_state: ^FluidSimState(N)) -> [N]f32 {
    force: [N]f32 = 0
    iter := neighborhood_iterator_make(sim_state, particle_positions[particle_idx], raw_data(particle_positions))
    for dist, index, ok := neighborhood_iterator_next(&iter); ok; dist, index, ok = neighborhood_iterator_next(&iter) {
        if (index == particle_idx) do continue // Particle does not contribute to its own pressure force
        dist_sq := linalg.dot(dist, dist)

        viscosity := get_shared_viscosity(particle_velocities[particle_idx], particle_velocities[index], sim_state.physics_cfg)
        when N == 2 {
            force += viscosity * kernel_viscosity_laplacian_2D(dist_sq, sim_state.physics_cfg.density_smoothing_radius) / densities[index]
        } else when N == 3 {
            force += viscosity * kernel_viscosity_laplacian_3D(dist_sq, sim_state.physics_cfg.density_smoothing_radius) / densities[index]
        }
    }
    return force
}

@(private="file")
calculate_pressure_force :: proc(particle_idx: u32, particle_positions: [][$N]f32, densities: []f32, sim_state: ^FluidSimState(N)) -> [N]f32 {
    force: [N]f32 = 0
    iter := neighborhood_iterator_make(sim_state, particle_positions[particle_idx], raw_data(particle_positions))
    for dist, index, ok := neighborhood_iterator_next(&iter); ok; dist, index, ok = neighborhood_iterator_next(&iter) {
        if (index == particle_idx) do continue // Particle does not contribute to its own pressure force
        dist_sq := linalg.dot(dist, dist)
        dir := dist_sq == 0 ? get_random_dir(N) : dist / linalg.length(dist) // If particles occupy the same location, select a random force direction

        pressure := get_shared_pressure(densities[particle_idx], densities[index], sim_state.physics_cfg)
        near_pressure := get_shared_near_pressure(sim_state.near_density[particle_idx], sim_state.near_density[index], sim_state.physics_cfg)
        when N == 2 {
            force += pressure * dir * kernel_pressure_derivative_2D(dist_sq, sim_state.physics_cfg.density_smoothing_radius) / densities[index]
            force += near_pressure * dir * kernel_near_pressure_derivative_2D(dist_sq, sim_state.physics_cfg.density_smoothing_radius) / densities[index]
        } else when N == 3 {
            force += pressure * dir * kernel_pressure_derivative_3D(dist_sq, sim_state.physics_cfg.density_smoothing_radius) / densities[index]
            force += near_pressure * dir * kernel_near_pressure_derivative_3D(dist_sq, sim_state.physics_cfg.density_smoothing_radius) / densities[index]
        }
    }
    return force
}

@(private="file")
resolve_boundary_collisions :: proc(sim_state: ^FluidSimState($N), first_index, last_index: u32) {
    for i in first_index..<last_index {
        for dim in 0..<N {
            if sim_state.position[i][dim] > (sim_state.bbox.max[dim] - sim_state.particle_cfg.radius) {
                sim_state.position[i][dim] = sim_state.bbox.max[dim] - sim_state.particle_cfg.radius
                sim_state.velocity[i][dim] = -sim_state.velocity[i][dim] * sim_state.physics_cfg.boundary_damping
            } else if sim_state.position[i][dim] < (sim_state.bbox.min[dim] + sim_state.particle_cfg.radius) {
                sim_state.position[i][dim] = sim_state.bbox.min[dim] + sim_state.particle_cfg.radius
                sim_state.velocity[i][dim] = -sim_state.velocity[i][dim] * sim_state.physics_cfg.boundary_damping
            }
        }
    }
}

@(private="file")
neighborhood_iterator_make :: proc(sim_state: ^FluidSimState($N), position: [N]f32, particle_positions: [^][N]f32) -> NeighborhoodIterator(N) {
    radius := sim_state.physics_cfg.density_smoothing_radius

    // 3 choices for neighboring cells to visit per axis: -1, 0, or 1
    offset_count := 1
    for _ in 0..<N do offset_count *= 3

    return NeighborhoodIterator(N){
        sim_state           = sim_state,
        position            = position,
        particle_positions  = particle_positions,
        grid_cell           = get_grid_cell(position, radius),
        smoothing_radius_sq = radius * radius,
        offset_idx          = -1,
        offset_count        = offset_count,
        sorted_slot         = 0,
        sorted_slot_end     = 0,
    }
}

@(private="file")
neighborhood_iterator_next :: proc(it: ^NeighborhoodIterator($N)) -> (dist: [N]f32, particle_index: u32, ok: bool) {
    sim_state := it.sim_state

    for {
        // Find the next neighbor grid cell
        if it.sorted_slot >= it.sorted_slot_end {
            it.offset_idx += 1
            if it.offset_idx >= it.offset_count do return {}, 0, false

            // Convert offset_idx to the offset index vector
            offset: [N]i32
            rem := it.offset_idx
            for i in 0..<N {
                offset[i] = i32(rem % 3) - 1
                rem /= 3
            }

            key := hash_grid_cell(it.grid_cell + offset, sim_state.hash_mask) // Store the grid key for the offset cell
            it.sorted_slot      = sim_state.cell_prefix_sum[key]
            it.sorted_slot_end  = sim_state.cell_prefix_sum[key + 1]
            continue
        }

        // Set the return value for the particle index of the current particle being iterated over
        particle_index = sim_state.sorted_particle_index[it.sorted_slot]
        it.sorted_slot += 1

        dist = it.particle_positions[particle_index] - it.position
        square_dst := linalg.dot(dist, dist) // To avoid sqrt
        if square_dst <= it.smoothing_radius_sq {
            return dist, particle_index, true
        }
    }
}

// kernel_spikey_pow2_2D
kernel_density_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return 6 / (math.PI * math.pow(radius, 4)) * math.pow(radius - r, 2)
}

// kernel_spikey_pow2_3D
kernel_density_3D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return 15 / (2 * math.PI * math.pow(radius, 5)) * math.pow(radius - r, 2)
}

// kernel_spikey_pow3_2D
kernel_near_density_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return 10 / (math.PI * math.pow(radius, 5)) * math.pow(radius - r, 3)
}

// kernel_spikey_pow3_3D
kernel_near_density_3D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return 15 / (math.PI * math.pow(radius, 6)) * math.pow(radius - r, 3)
}

// kernel_spikey_pow2_derivative_2D
kernel_pressure_derivative_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return -12 / (math.PI * math.pow(radius, 4)) * (radius - r)
}

// kernel_spikey_pow2_derivative_3D
kernel_pressure_derivative_3D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return -15 / (math.PI * math.pow(radius, 5)) * (radius - r)
}

// kernel_spikey_pow3_derivative_2D
kernel_near_pressure_derivative_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return -30 / (math.PI * math.pow(radius, 5)) * math.pow(radius - r, 2)
}

// kernel_spikey_pow3_derivative_3D
kernel_near_pressure_derivative_3D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return -45 / (math.PI * math.pow(radius, 6)) * math.pow(radius - r, 2)
}

kernel_viscosity_laplacian_2D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return 40 / (math.PI * math.pow(radius, 5)) * (radius - r)
}

kernel_viscosity_laplacian_3D :: proc(dist_sq: f32, radius: f32) -> f32 {
    r := math.sqrt(dist_sq)
    if r > radius do return 0
    return 45 / (math.PI * math.pow(radius, 6)) * (radius - r)
}
