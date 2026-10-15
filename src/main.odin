package main

import "thirdparty:imgui"
import vk "vendor:vulkan"
import "render"
import "core:log"
import "core:path/filepath"

APPLICATION_WIDTH  :: 1280
APPLICATION_HEIGHT :: 720

requested_validation_layers : []cstring : {
    "VK_LAYER_KHRONOS_validation", // Standard validation layer preset
}

requested_device_extensions : []cstring : {
    "VK_KHR_swapchain", // Necessary extension to use swapchains
    "VK_GOOGLE_user_type",
    "VK_KHR_present_mode_fifo_latest_ready",
}

get_test_gltf_material :: proc(renderer: ^render.Renderer) -> render.MaterialInstance {
    pipeline_cfg := render.pipeline_cfg_create()
    defer render.pipeline_cfg_destroy(&pipeline_cfg)

    shader := render.shader_module_create_from_file(renderer, "test_gltf.slang.spv")
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

get_gradient_compute_pipeline :: proc(renderer: ^render.Renderer, background_texture_layout: vk.DescriptorSetLayout,
    background_texture_descriptor: ^render.DescriptorSet) -> render.ComputeResources {

    pipeline_cfg := render.pipeline_cfg_create()
    defer render.pipeline_cfg_destroy(&pipeline_cfg)

    shader := render.shader_module_create_from_file(renderer, "gradient.slang.spv")
    defer render.shader_module_destroy(renderer, shader)

    render.pipeline_cfg_add_shader(&pipeline_cfg, shader, { .COMPUTE }, "gradient")
    render.pipeline_cfg_add_descriptor(&pipeline_cfg, background_texture_layout)

    pipeline := render.pipeline_cfg_build_compute_pipeline(&pipeline_cfg, renderer)
    return render.compute_resources_create(pipeline, { background_texture_descriptor })
}

GradientData :: struct {
    resources: ^render.ComputeResources,
    background_texture: ^render.Image,
}

gradient_dispatch :: proc(cmd: vk.CommandBuffer, renderer: ^render.Renderer, data: rawptr) {
    gradient_data := (^GradientData)(data)
    render.compute_resource_bind(cmd, gradient_data.resources, renderer.frame_index)
    extent := gradient_data.background_texture.extent
    // TODO: Should I hard-code the number of threads here?
    vk.CmdDispatch(cmd, (extent.width + 15) / 16, (extent.height + 15) / 16, 1)

    // Copy the result into the draw image
    render.image_transition(cmd, gradient_data.background_texture, .TRANSFER_SRC_OPTIMAL)
    render.image_transition(cmd, &renderer.draw_image, .TRANSFER_DST_OPTIMAL)
    render.image_copy(cmd, gradient_data.background_texture^, renderer.draw_image)

    // Restore the layouts the rest of the frame expects
    render.image_transition(cmd, &renderer.draw_image, .GENERAL)
    render.image_transition(cmd, gradient_data.background_texture, .GENERAL)
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
    global_uniform_buffer := render.buffer_create(&r, size_of(render.CameraData), u64(r.frames_in_flight), { .UNIFORM_BUFFER }, .CPU_TO_GPU)
    defer render.buffer_destroy(&r, &global_uniform_buffer)
    render.buffer_map(&r, &global_uniform_buffer)
    camera_data := render.CameraData{
        viewproj = (1), // initialize to identity matrix
        view     = (1),
        proj     = (1),
    }

    layout_builder := render.descriptor_layout_builder_create()
    defer render.descriptor_layout_builder_destroy(&layout_builder)
    defer render.descriptor_layout_builder_destroy_built_layouts(&layout_builder, &r)
    descriptor_writer := render.descriptor_writer_create()
    defer render.descriptor_writer_destroy(&descriptor_writer)

    // Build the descriptor layout for the global scene descriptors (like camera data, etc)
    render.descriptor_layout_builder_add_binding(&layout_builder, 0, .UNIFORM_BUFFER_DYNAMIC, 1, { .VERTEX })
    global_scene_layout := render.descriptor_layout_builder_build(&layout_builder, &r)
    append(&r.scene_descriptor_layouts, global_scene_layout)
    camera_descriptor := render.descriptor_set_create(&r, { global_scene_layout })
    append(&r.scene_descriptors, &camera_descriptor)

    // Point the global descriptors to their buffers in the Renderer class
    render.descriptor_writer_add_buffers(&descriptor_writer, r.scene_descriptors[0], 0, { global_uniform_buffer }, .UNIFORM_BUFFER_DYNAMIC)
    render.descriptor_writer_update_sets(&descriptor_writer, &r)

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
    monkey_material := get_test_gltf_material(&r)
    defer render.pipeline_destroy(&r, &monkey_material.pipeline)

    particle_config := FluidSimParticleConfig{
        spacing         = 0.05,
        radius          = 0.08,
        n_particles     = 15000,
        default_color   = { 1, 1, 1, 1 },
    }

    physics_config := FluidSimPhysicsConfig{
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

    camera_config := render.CameraConfig{
        near_plane  = 0.1,
        far_plane   = 10000,
        ortho_scale = 10,
        fov         = 70,
    };

    camera_controller := render.camera_controller_create()
    camera_controller.position = {0, 0, 7}
    camera_controller.move_speed = 5
    camera_controller.look_sensitivity = 0.003 // radians per pixel
    camera_controller.orbit_distance = 7

    boundary_width: f32 = 5.5
    boundary_height: f32 = 5
    boundary_depth: f32 = 5.5
    half_width := boundary_width * 0.5
    half_height := boundary_height * 0.5
    half_depth := boundary_depth * 0.5

    bounding_box := BoundingBox3D{
        min = { -half_width, -half_height, -half_depth },
        max = {  half_width,  half_height,  half_depth },
    }

    fluidsim_particle_system := render.particle_system_create(&r, MAX_PARTICLES, (0), particle_mesh, &fluid_material)
    // Dimension of the particle motion is inferred from bounding box dimension
    fluidsim_particle_system.motion = fluidsim_state_create(&fluidsim_particle_system, &particle_config, &physics_config, &bounding_box)
    defer render.particle_system_destroy(&fluidsim_particle_system, &r)

    // Create the background texture that the gradient compute shader will write to
    background_texture := render.image_create_texture(&r, r.draw_image.extent, .R16G16B16A16_SFLOAT, { .TRANSFER_SRC, .COLOR_ATTACHMENT, .STORAGE})
    defer render.image_destroy(&r, &background_texture)
    render.image_transition_now(&r, &background_texture, .GENERAL)
    render.descriptor_layout_builder_add_binding(&layout_builder, 0, .STORAGE_IMAGE, 1, { .COMPUTE })
    background_texture_desc_layout := render.descriptor_layout_builder_build(&layout_builder, &r)
    background_texture_set := render.descriptor_set_create(&r, { background_texture_desc_layout })
    defer render.descriptor_set_destroy(&background_texture_set)
    render.descriptor_writer_add_images(&descriptor_writer, background_texture_set.handle, 0, { background_texture }, .STORAGE_IMAGE)
    render.descriptor_writer_update_sets(&descriptor_writer, &r)

    gradient_resources := get_gradient_compute_pipeline(&r, background_texture_desc_layout, &background_texture_set)
    gradient_data := GradientData{
        resources = &gradient_resources,
        background_texture = &background_texture,
    }
    defer render.compute_resources_destroy(&r, &gradient_resources)
    r.clear_draw_image = false

    monkey_pos := render.float3{ 0, 10, 7}

    recording_timer := render.timer_create()

    for !render.window_should_close(&r) {
        clear(&r.renderables) // TODO: As I think about this more, potentially clean this up
        clear(&r.compute_passes)

        render.start_frame(&r)
        process_renderer_inputs(&r.input_manager, &r)
        process_fluid_sim_inputs(&r.input_manager, &fluidsim_particle_system)
        process_camera_inputs(&r.input_manager, &camera_controller)

		imgui.Begin("Camera Config");
        imgui.DragFloat("Far Plane", &camera_config.far_plane, 1);
        imgui.DragFloat("Near Plane", &camera_config.near_plane, 0.001);
        imgui.DragFloat("Orthographic Scale", &camera_config.ortho_scale, 0.1);
        imgui.DragFloat("FOV", &camera_config.fov, 1);
        imgui.DragFloat("Move Speed", &camera_controller.move_speed, 0.1);
        imgui.DragFloat("Look Sensitivity", &camera_controller.look_sensitivity, 0.0001);
		imgui.End();

		imgui.Begin("Particle Config");
        imgui.DragFloat("Spacing", &particle_config.spacing, 0.01);
        imgui.DragFloat("Radius", &particle_config.radius, .01);
        imgui.DragScalar("Number of Particles", .U32, rawptr(&particle_config.n_particles), 1);
        imgui.ColorPicker4("Default Color", &particle_config.default_color)
		imgui.End();

		imgui.Begin("Physics Config");
        imgui.DragFloat("Gravity", &physics_config.gravity, 0.01);
        imgui.DragFloat("Boundary Damping Factor", &physics_config.boundary_damping, 0.01);
        imgui.DragFloat("Smoothing Radius", &physics_config.density_smoothing_radius, 0.01, v_min = 0.1);
        imgui.DragFloat("Pressure Constant", &physics_config.pressure_constant, 0.01);
        imgui.DragFloat("Near Pressure Multiplier", &physics_config.near_pressure_multiplier, 0.01);
        imgui.DragFloat("Viscosity", &physics_config.viscosity, 0.01);
        imgui.DragFloat("Rest Density", &physics_config.rest_density, 0.01);
        imgui.DragFloat("Time Step", &physics_config.time_step, .0166, v_min = 0);
        // imgui.DragFloat("Interaction Strength", &physics_config.interaction_strength, 0.1);
        // imgui.DragFloat("Interaction Radius", &physics_config.interaction_radius, 0.01, v_min = 0);
        {
            min: u32 = 1
            imgui.DragScalar("Substeps", .U32, rawptr(&physics_config.n_substeps), 1, &min);
        }
		imgui.End();

        imgui.Begin("Boundary")
        imgui.DragFloat("Width", &boundary_width, 0.2)
        imgui.DragFloat("Height", &boundary_height, 0.2)
        imgui.DragFloat("Depth", &boundary_depth, 0.2)
        bounding_box.max.x = boundary_width * 0.5
        bounding_box.max.y = boundary_height * 0.5
        bounding_box.max.z = boundary_depth * 0.5
        bounding_box.min.x = -bounding_box.max.x
        bounding_box.min.y = -bounding_box.max.y
        bounding_box.min.z = -bounding_box.max.z
        imgui.End();

		imgui.Begin("Controls");
        if imgui.Button("Start") {
            fluidsim_particle_system.motion.started = true
        }
        if imgui.Button("Reset") {
            fluidsim_particle_system.motion.started = false
        }
		imgui.End();

		imgui.Begin("Metrics");
        imgui.Text("FPS: %f", r.timer.fps)
        imgui.Text("Frame Time: %f", r.timer.avg_frame_time)
		imgui.End();

        imgui.Begin("Screen Capture")
        if imgui.Button(r.capturing_primed ? "Stand Down" : "Prime") do r.capturing_primed = r.capturing_primed ? false : true
        if imgui.Button("Take Screenshot") do render.capture_request_screenshot(&r)
        if !r.recorder.recording {
            imgui.InputScalar("Framerate", .S32, &r.recorder.framerate)
            if imgui.Button("Start Recording") do render.capture_start_recording(&r)
            render.timer_update(&recording_timer)
        } else {
            if imgui.Button("Stop Recording") do render.capture_end_recording(&r)
            imgui.Text("Elapsed Time: %f", render.timer_time_since_last_tick(recording_timer))
        }
        imgui.DragInt("Quality", &render.g_ffmpeg_quality, 0, 100, 1)
        imgui.End()

        aspect_ratio := r.window.aspect_ratio
        up := render.float3{ 0, 1, 0 }
        camera_data.proj = render.projection_set_perspective(camera_config.fov, aspect_ratio, camera_config.near_plane, camera_config.far_plane)
        camera_data.view = render.view_set_direction(camera_controller.position, camera_controller.forward, render.g_world_up)
        camera_data.viewproj = camera_data.proj * camera_data.view
        render.buffer_write_data_at_index(&r, &global_uniform_buffer, rawptr(&camera_data), r.frame_index) // Update at the right index for this frame

        // Update fluidsim particles.
        render.particle_system_update(&fluidsim_particle_system, &r, r.frame_time)

        append(&r.compute_passes, render.ComputePass{ data = &gradient_data, dispatch = gradient_dispatch })

        // Get the renderables
        render.particle_system_get_render_object(&fluidsim_particle_system, &r.renderables)
        for mesh in monkey_mesh {
            render.mesh_get_render_objects_single_instance(mesh, &r.renderables, &monkey_material, monkey_pos)
        }

        render.draw(&r)
    }

    render.wait_idle(&r)
}
