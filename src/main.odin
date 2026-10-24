package main

import "thirdparty:imgui"
import vk "vendor:vulkan"
import "render"
import "core:log"
import "core:math"
import "core:path/filepath"
import "core:time"

APPLICATION_WIDTH  :: 1280
APPLICATION_HEIGHT :: 720

// Defaults used on first run, or after deleting the settings file in the cache dir
DEFAULT_PARTICLE_CONFIG :: FluidSimParticleConfig{
    spacing         = 0.05,
    radius          = 0.08,
    n_particles     = 15000,
    default_color   = { 1, 1, 1, 1 },
}

DEFAULT_PHYSICS_CONFIG :: FluidSimPhysicsConfig{
    gravity                     = 9.8,
    boundary_damping            = 0.95,
    density_smoothing_radius    = 0.35,
    pressure_constant           = 500,
    near_pressure_multiplier    = 2,
    viscosity                   = 5,
    rest_density                = 250,
    n_substeps                  = 3,
    time_step                   = 1.0 / 60.0,
    max_time_step               = .25,
    // interaction_strength        = 90,
    // interaction_radius          = 2,
}

DEFAULT_BOUNDARY_CONFIG :: BoundaryConfig{
    width   = 5.5,
    height  = 5,
    depth   = 5.5,
}

DEFAULT_CAMERA_CONFIG :: render.CameraConfig{
    near_plane  = 0.1,
    far_plane   = 10000,
    ortho_scale = 10,
    fov         = 70,
}

DEFAULT_CAMERA_CONTROL_CONFIG :: render.CameraControlConfig{
    move_speed          = 5,
    look_sensitivity    = 0.003,
}

requested_validation_layers : []cstring : {
    "VK_LAYER_KHRONOS_validation", // Standard validation layer preset
}

requested_device_extensions : []cstring : {
    "VK_KHR_swapchain", // Necessary extension to use swapchains
    "VK_GOOGLE_user_type",
    "VK_KHR_present_mode_fifo_latest_ready",
}

get_test_gltf_material :: proc(renderer: ^render.Renderer, descriptor_layout: vk.DescriptorSetLayout, descriptor: ^render.DescriptorSet) -> render.MaterialInstance {
    pipeline_cfg := render.pipeline_cfg_create()
    defer render.pipeline_cfg_destroy(&pipeline_cfg)

    shader := render.shader_module_create_from_file(renderer, "basic.slang.spv")
    defer render.shader_module_destroy(renderer, shader)

    render.pipeline_cfg_add_shader(&pipeline_cfg, shader, { .VERTEX }, "basic_vertex")
    render.pipeline_cfg_add_shader(&pipeline_cfg, shader, { .FRAGMENT }, "basic_frag")
    render.pipeline_cfg_set_input_topology(&pipeline_cfg, .TRIANGLE_LIST)
    render.pipeline_cfg_set_polygon_mode(&pipeline_cfg, .FILL)
    render.pipeline_cfg_set_cull_mode(&pipeline_cfg, {}, .CLOCKWISE)
    render.pipeline_cfg_set_multisampling(&pipeline_cfg, { ._1 })
    render.pipeline_cfg_set_blending(&pipeline_cfg, .NONE)
    render.pipeline_cfg_set_color_attachment_format(&pipeline_cfg, renderer.draw_image.format)
    render.pipeline_cfg_set_depth_attachment_format(&pipeline_cfg, renderer.depth_image.format)
    render.pipeline_cfg_set_depth_test(&pipeline_cfg, .GREATER_OR_EQUAL)
    render.pipeline_cfg_add_push_constant_range(&pipeline_cfg, { .VERTEX }, size_of(render.DrawPushConstants))
    render.pipeline_cfg_add_descriptor(&pipeline_cfg, renderer.scene_descriptor_layout)

    material: render.MaterialInstance
    material.pass_type = .opaque

    // Material descriptor set creation
    render.pipeline_cfg_add_descriptor(&pipeline_cfg, descriptor_layout)
    material.descriptor = descriptor

    material.pipeline = render.pipeline_cfg_build_pipeline(&pipeline_cfg, renderer)
    return material
}

get_sky_material :: proc(renderer: ^render.Renderer, descriptor_layout: vk.DescriptorSetLayout, descriptor_set: ^render.DescriptorSet) -> render.MaterialInstance {
    pipeline_cfg := render.pipeline_cfg_create()
    defer render.pipeline_cfg_destroy(&pipeline_cfg)

    sky_shader := render.shader_module_create_from_file(renderer, "sky.slang.spv")
    defer render.shader_module_destroy(renderer, sky_shader)
    fullscreen_shader := render.shader_module_create_from_file(renderer, "fullscreen_triangle.slang.spv")
    defer render.shader_module_destroy(renderer, fullscreen_shader)

    render.pipeline_cfg_add_shader(&pipeline_cfg, fullscreen_shader, { .VERTEX }, "fullscreen_triangle")
    render.pipeline_cfg_add_shader(&pipeline_cfg, sky_shader, { .FRAGMENT }, "sky_gradient")
    render.pipeline_cfg_set_input_topology(&pipeline_cfg, .TRIANGLE_LIST)
    render.pipeline_cfg_set_polygon_mode(&pipeline_cfg, .FILL)
    render.pipeline_cfg_set_cull_mode(&pipeline_cfg, {}, .CLOCKWISE)
    render.pipeline_cfg_set_multisampling(&pipeline_cfg, { ._1 })
    render.pipeline_cfg_set_blending(&pipeline_cfg, .NONE)
    render.pipeline_cfg_set_color_attachment_format(&pipeline_cfg, renderer.draw_image.format)
    render.pipeline_cfg_set_depth_attachment_format(&pipeline_cfg, renderer.depth_image.format)
    render.pipeline_cfg_set_depth_test(&pipeline_cfg, .NEVER)
    render.pipeline_cfg_add_descriptor(&pipeline_cfg, descriptor_layout)

    material: render.MaterialInstance
    material.pass_type = .opaque
    material.descriptor = descriptor_set

    material.pipeline = render.pipeline_cfg_build_pipeline(&pipeline_cfg, renderer)
    return material
}

main :: proc() {

    // Initialize logger to output to console
    logger := log.create_console_logger()
    context.logger = logger

    renderer_config := render.RendererConfig{
        app_name                        = "Renderer",
        extent                          = {APPLICATION_WIDTH, APPLICATION_HEIGHT},
        use_discrete_GPU                = true,
        validation_layers               = requested_validation_layers,
        device_extensions               = requested_device_extensions,
        initial_descriptor_set_count    = 10,
    }

    r: render.Renderer
    render.renderer_initialize(&r, renderer_config)
    defer render.renderer_shutdown(&r)

    // Create an instance of the global uniform buffer for each frame in flight
    global_scene_buffer := render.buffer_create(&r, size_of(render.SceneData), u64(r.frames_in_flight), { .UNIFORM_BUFFER }, .CPU_TO_GPU)
    defer render.buffer_destroy(&r, &global_scene_buffer)
    global_scene_data := render.SceneData{
        viewproj = (1), // initialize to identity matrix
        view     = (1),
        proj     = (1),
    }

    // Point the global descriptors to their buffers in the Renderer class
    // TODO: make this an engine function i think?
    render.descriptor_writer_add_buffers(&r.descriptor_writer, &r.scene_descriptor, 0, { global_scene_buffer }, .UNIFORM_BUFFER_DYNAMIC)
    render.descriptor_writer_update_sets(&r.descriptor_writer, &r)

    // Create meshes
    particle_mesh := render.mesh_create_rectangle(&r, 1, 1)
    defer render.mesh_destroy(&r, particle_mesh)
    fluid_material := fluidsim_get_material(&r)
    defer render.pipeline_destroy(&r, &fluid_material.pipeline)

    // Load the example gltf files
    monkey_filepath, _ := filepath.join({render.ASSET_DIR, "monkey.glb"}, context.allocator)
    defer delete(monkey_filepath)
    monkey_mesh := render.mesh_load_gltf(&r, monkey_filepath)
    defer {
        for mesh in monkey_mesh {
            render.mesh_destroy(&r, mesh)
        }
        delete(monkey_mesh)
    }

    particle_config       := DEFAULT_PARTICLE_CONFIG
    physics_config        := DEFAULT_PHYSICS_CONFIG
    boundary_config       := DEFAULT_BOUNDARY_CONFIG
    camera_config         := DEFAULT_CAMERA_CONFIG
    camera_control_config := DEFAULT_CAMERA_CONTROL_CONFIG

    config_sections := []render.ConfigSection{
        render.config_section("particle",        &particle_config),
        render.config_section("physics",         &physics_config),
        render.config_section("boundary",        &boundary_config),
        render.config_section("camera",          &camera_config),
        render.config_section("camera_controls", &camera_control_config),
    }
    render.config_load(config_sections)
    defer render.config_save(config_sections)
    last_config_save := time.tick_now()

    camera_controller := render.camera_controller_create()
    camera_controller.position = {0, 0, 7}
    camera_controller.move_speed = camera_control_config.move_speed
    camera_controller.look_sensitivity = camera_control_config.look_sensitivity
    camera_controller.orbit_distance = 7

    bounding_box: BoundingBox3D
    bounding_box.max = { boundary_config.width, boundary_config.height, boundary_config.depth } * 0.5
    bounding_box.min = -bounding_box.max

    fluidsim_particle_system := render.particle_system_create(&r, MAX_PARTICLES, (0), particle_mesh, &fluid_material)
    // Dimension of the particle motion is inferred from bounding box dimension
    fluidsim_particle_system.motion = fluidsim_state_create(&fluidsim_particle_system, &particle_config, &physics_config, &bounding_box)
    defer render.particle_system_destroy(&fluidsim_particle_system, &r)

    r.background_type = .FragmentShader
    r.background_material = get_sky_material(&r, r.scene_descriptor_layout, &r.scene_descriptor)
    defer render.pipeline_destroy(&r, &r.background_material.pipeline) // TODO: make this more opaque to application, destroy from within renderer_destroy

    // Create custom test textures and their samplers
    pack_unorm4x8 :: proc(v: [4]f32) -> u32 {
        result: u32
        for i in 0..<4 {
            result |= u32(math.round(clamp(v[i], 0, 1) * 255)) << (u32(i) * 8)
        }
        return result
    }

    white   := pack_unorm4x8({ 1, 1, 1, 1 })
    grey    := pack_unorm4x8({ 0.66, 0.66, 0.66, 0.66 })
    black   := pack_unorm4x8({ 0, 0, 0, 0 })
    magenta := pack_unorm4x8({ 1, 0, 1, 1 })

    error_pixels: [16 * 16]u32 // for 16x16 checkerboard texture
    for x in 0..<16 {
        for y in 0..<16 {
            error_pixels[y*16 + x] = ((x % 2) ~ (y % 2)) != 0 ? magenta : black
        }
    }

    // Create the sampler
    // TODO: sampler cache
    sampler_nearest, sampler_linear: vk.Sampler

    sampler_info := vk.SamplerCreateInfo{ sType = vk.StructureType.SAMPLER_CREATE_INFO, }
    sampler_info.magFilter = .NEAREST
    sampler_info.minFilter = .NEAREST
    vk.CreateSampler(r.logical_device, &sampler_info, nil, &sampler_nearest)
    sampler_info.magFilter = .LINEAR
    sampler_info.minFilter = .LINEAR
    vk.CreateSampler(r.logical_device, &sampler_info, nil, &sampler_linear)
    defer {
        vk.DestroySampler(r.logical_device, sampler_nearest, nil)
        vk.DestroySampler(r.logical_device, sampler_linear, nil)
    }

    white_texture := render.texture_create_from_data(&r, &white, vk.Extent3D{ 1, 1, 1 }, sampler_nearest, .R8G8B8A8_UNORM, { .SAMPLED })
    black_texture := render.texture_create_from_data(&r, &black, vk.Extent3D{ 1, 1, 1 }, sampler_nearest, .R8G8B8A8_UNORM, { .SAMPLED })
    grey_texture  := render.texture_create_from_data(&r, &grey,  vk.Extent3D{ 1, 1, 1 }, sampler_nearest, .R8G8B8A8_UNORM, { .SAMPLED })
    error_texture := render.texture_create_from_data(&r, &error_pixels, vk.Extent3D{ 16, 16, 1 }, sampler_nearest, .R8G8B8A8_UNORM, { .SAMPLED })
    defer {
        render.texture_destroy(&r, &white_texture)
        render.texture_destroy(&r, &black_texture)
        render.texture_destroy(&r, &grey_texture)
        render.texture_destroy(&r, &error_texture)
    }

    render.descriptor_layout_builder_add_binding(&r.descriptor_layout_builder, 0, .COMBINED_IMAGE_SAMPLER, 1, { .FRAGMENT })
    texture_descriptor_layout := render.descriptor_layout_builder_build(&r.descriptor_layout_builder, &r)
    texture_descriptor := render.descriptor_set_create(&r, texture_descriptor_layout)
    render.descriptor_writer_add_textures(&r.descriptor_writer, &texture_descriptor, 0, { error_texture }, .COMBINED_IMAGE_SAMPLER)
    render.descriptor_writer_update_sets(&r.descriptor_writer, &r)

    monkey_material := get_test_gltf_material(&r, texture_descriptor_layout, &texture_descriptor)
    defer render.pipeline_destroy(&r, &monkey_material.pipeline)
    monkey_pos := render.float3{ 0, 10, 7}

    recording_timer := render.timer_create()
    for !render.window_should_close(&r) {
        clear(&r.renderables) // TODO: As I think about this more, potentially clean this up
        clear(&r.compute_passes)

        render.start_frame(&r)
        process_renderer_inputs(&r.input_manager, &r)
        process_fluid_sim_inputs(&r.input_manager, &fluidsim_particle_system)
        process_camera_inputs(&r.input_manager, &camera_controller)

        imgui.SetNextWindowPos({ 10, 10 }, .FirstUseEver)
        imgui.SetNextWindowSize({ 380, 700 }, .FirstUseEver)
        if imgui.Begin("Fluid Simulator") {
            imgui.Text("FPS: %f", r.timer.fps)
            imgui.Text("Frame Time: %f", r.timer.avg_frame_time)
            if imgui.Button("Start") do fluidsim_particle_system.motion.started = true
            imgui.SameLine()
            if imgui.Button("Reset") do fluidsim_particle_system.motion.started = false

            if imgui.CollapsingHeader("Physics") {
                imgui.DragFloat("Gravity", &physics_config.gravity, 0.01);
                imgui.DragFloat("Boundary Damping Factor", &physics_config.boundary_damping, 0.01);
                imgui.DragFloat("Smoothing Radius", &physics_config.density_smoothing_radius, 0.01, v_min = 0.1);
                imgui.DragFloat("Pressure Constant", &physics_config.pressure_constant, 0.01);
                imgui.DragFloat("Near Pressure Multiplier", &physics_config.near_pressure_multiplier, 0.01);
                imgui.DragFloat("Viscosity", &physics_config.viscosity, 0.01);
                imgui.DragFloat("Rest Density", &physics_config.rest_density, 0.01);
                imgui.DragFloat("Time Step", &physics_config.time_step, .0166, v_min = 0);
                min: u32 = 1
                imgui.DragScalar("Substeps", .U32, rawptr(&physics_config.n_substeps), 1, &min);
            }

            if imgui.CollapsingHeader("Particles") {
                imgui.DragFloat("Spacing", &particle_config.spacing, 0.01);
                imgui.DragFloat("Radius", &particle_config.radius, .01);
                imgui.DragScalar("Number of Particles", .U32, rawptr(&particle_config.n_particles), 1);
                imgui.ColorPicker4("Default Color", &particle_config.default_color)
            }

            if imgui.CollapsingHeader("Boundary") {
                imgui.DragFloat("Width", &boundary_config.width, 0.2)
                imgui.DragFloat("Height", &boundary_config.height, 0.2)
                imgui.DragFloat("Depth", &boundary_config.depth, 0.2)
            }

            if imgui.CollapsingHeader("Camera") {
                imgui.DragFloat("Far Plane", &camera_config.far_plane, 1);
                imgui.DragFloat("Near Plane", &camera_config.near_plane, 0.001);
                imgui.DragFloat("Orthographic Scale", &camera_config.ortho_scale, 0.1);
                imgui.DragFloat("FOV", &camera_config.fov, 1);
                imgui.DragFloat("Move Speed", &camera_control_config.move_speed, 0.1);
                imgui.DragFloat("Look Sensitivity", &camera_control_config.look_sensitivity, 0.0001);
            }

            if imgui.CollapsingHeader("Screen Capture") {
                if imgui.Button(r.capturing_primed ? "Stand Down" : "Prime") do r.capturing_primed = !r.capturing_primed
                imgui.SameLine()
                if imgui.Button("Take Screenshot") do render.capture_request_screenshot(&r)
                if !r.recorder.recording {
                    imgui.InputScalar("Framerate", .S32, &r.recorder.framerate)
                    if imgui.Button("Start Recording") do render.capture_start_recording(&r)
                } else {
                    if imgui.Button("Stop Recording") do render.capture_end_recording(&r)
                    imgui.Text("Elapsed Time: %f", render.timer_time_since_last_tick(recording_timer))
                }
                imgui.DragInt("Quality", &render.g_ffmpeg_quality, 0, 100, 1)
            }
        }
        imgui.End()

        // Kept outside the UI so they run even when a section is collapsed
        if !r.recorder.recording do render.timer_update(&recording_timer)
        bounding_box.max = { boundary_config.width, boundary_config.height, boundary_config.depth } * 0.5
        bounding_box.min = -bounding_box.max
        camera_controller.move_speed = camera_control_config.move_speed
        camera_controller.look_sensitivity = camera_control_config.look_sensitivity

        // Auto-save settings
        if time.tick_since(last_config_save) > time.Second {
            render.config_save(config_sections)
            last_config_save = time.tick_now()
        }

        aspect_ratio := r.window.aspect_ratio
        up := render.float3{ 0, 1, 0 }
        global_scene_data.proj = render.projection_set_perspective(camera_config.fov, aspect_ratio, camera_config.near_plane, camera_config.far_plane)
        global_scene_data.view = render.view_set_direction(camera_controller.position, camera_controller.forward, render.g_world_up)
        global_scene_data.viewproj = global_scene_data.proj * global_scene_data.view
        render.buffer_write_data_at_index(&r, &global_scene_buffer, rawptr(&global_scene_data), r.frame_index) // Update at the right index for this frame

        // Update fluidsim particles.
        render.particle_system_update(&fluidsim_particle_system, &r, r.frame_time)

        // Get the renderables
        render.particle_system_get_render_object(&fluidsim_particle_system, &r.renderables)
        for mesh in monkey_mesh {
            render.mesh_get_render_objects_single_instance(mesh, &r.renderables, &monkey_material, monkey_pos)
        }

        render.draw(&r)
    }

    render.wait_idle(&r)
}
