package main

import "render"
import "core:math/linalg"

process_renderer_inputs :: proc(input: ^render.InputManager, renderer: ^render.Renderer) {
    if input.key_states[.tilde].pressed {
        renderer.draw_gui = renderer.draw_gui ? false : true
    }
    if input.key_states[.f12].pressed {
        render.capture_request_screenshot(renderer)
    }
    if input.key_states[.r].pressed {
        if !renderer.recorder.recording {
            render.capture_start_recording(renderer)
        } else {
            render.capture_end_recording(renderer)
        }
    }
}

process_camera_inputs :: proc(input: ^render.InputManager, camera_controller: ^render.CameraController) {

    // WASD movement
    move_direction: render.float3 = 0
    right := linalg.normalize(linalg.cross(camera_controller.forward, render.g_world_up))
    up := linalg.cross(right, camera_controller.forward)
    if input.key_states[.w].down {
        move_direction += camera_controller.forward
    }
    if input.key_states[.s].down {
        move_direction -= camera_controller.forward
    }
    if input.key_states[.d].down {
        move_direction += right
    }
    if input.key_states[.a].down {
        move_direction -= right
    }
    if input.key_states[.e].down {
        move_direction += up
    }
    if input.key_states[.q].down {
        move_direction -= up
    }
    move_dir_length := linalg.length(move_direction)
    if linalg.length2(move_direction) > 0 {
        camera_controller.position += move_direction / move_dir_length * camera_controller.move_speed * input.delta_time
    }

    look_pressed  := input.mouse_states[.left].pressed  || input.mouse_states[.right].pressed
    look_released := input.mouse_states[.left].released || input.mouse_states[.right].released
    if look_pressed {
        render.set_cursor_locked(input.window, true)
    } else if look_released {
        render.set_cursor_locked(input.window, false)
    }
    if input.mouse_states[.left].down {
        render.camera_controller_rotate_pitch(camera_controller, -input.mouse_delta.y * camera_controller.look_sensitivity)
        render.camera_controller_rotate_yaw(camera_controller, -input.mouse_delta.x * camera_controller.look_sensitivity)
    } else if input.mouse_states[.right].down {
        render.camera_controller_orbit(camera_controller, -input.mouse_delta.x * camera_controller.look_sensitivity, -input.mouse_delta.y * camera_controller.look_sensitivity)
    }
}

process_fluid_sim_inputs :: proc(input: ^render.InputManager, fluidsim_particle_system: ^render.CPUParticleSystem) {
    if input.key_states[.space].pressed {
        fluidsim_particle_system.motion.started = fluidsim_particle_system.motion.started ? false : true
    }
}

