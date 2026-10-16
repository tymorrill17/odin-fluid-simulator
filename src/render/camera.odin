package render

import "core:math"
import "core:math/linalg"

CameraControlConfig :: struct {
    move_speed:         f32,
    look_sensitivity:   f32, // radians per pixel
}

CameraConfig :: struct{
    near_plane:     f32,
    far_plane:      f32,
    ortho_scale:    f32,
    fov:            f32,
};

CameraData :: struct {
    viewproj:   float4x4,
    view:       float4x4,
    proj:       float4x4,
};

CameraController :: struct {
    position:         float3, // position of camera
    forward:          float3, // Where camera is pointing
    pitch:            f32,    // up/down, 0 is eye level
    orbit_distance:   f32,
    move_speed:       f32,
    look_sensitivity: f32,
}

g_world_up :: float3{ 0, 1, 0 }

projection_set_orthographic :: proc(left, right, bottom, top, near, far: f32) -> float4x4 {
    proj: float4x4 = 1 // identity
    proj[0, 0] = 2 / (right - left)
    proj[0, 3] = -(right + left) / (right - left)
    proj[1, 1] = 2 / (bottom - top)
    proj[1, 3] = -(bottom + top) / (bottom - top)
    proj[2, 2] = 1 / (far - near)
    proj[2, 3] = far / (far - near)
    return proj
}

projection_set_perspective :: proc(vertical_fov, aspect_ratio, near, far: f32) -> float4x4 {

    fov_radians := vertical_fov * math.PI / 180
    focal_length := 1 / math.tan(fov_radians * 0.5)
    a := near / (far - near)

    proj: float4x4 = 0 // NOT identity
    proj[0, 0] = focal_length / aspect_ratio
    proj[1, 1] = -focal_length
    proj[2, 2] = a
    proj[3, 2] = -1
    proj[2, 3] = a * far
    return proj
}

view_set_direction :: proc(position, direction, up: float3) -> float4x4 {
    forward := linalg.normalize0(direction)
    right   := linalg.normalize0(linalg.cross(forward, up))
    rel_up  := linalg.cross(right, forward)

    view: float4x4 = 1 // identity
    view[0, 0] = right.x
    view[0, 1] = right.y
    view[0, 2] = right.z
    view[1, 0] = rel_up.x
    view[1, 1] = rel_up.y
    view[1, 2] = rel_up.z
    view[2, 0] = -forward.x
    view[2, 1] = -forward.y
    view[2, 2] = -forward.z

    translate_vec := float4{ -position.x, -position.y, -position.z, 0 }
    translated := view * translate_vec
    for i in 0..<4 {
        view[i, 3] += translated[i]
    }
    return view
}

view_set_target :: proc(position, target, up: float3) -> float4x4 {
   return view_set_direction(position, target - position, up);
}

camera_controller_create :: proc() -> CameraController {
    return CameraController{
        position         = 0,
        forward          = { 0, 0, -1 },
        pitch            = 0,
        move_speed       = 0,
        look_sensitivity = 0,
    }
}

// Rotate the camera orientation about the world's up vector by radians
camera_controller_rotate_yaw :: proc(controller: ^CameraController, angle_radians: f32) {
    controller.forward = linalg.normalize(linalg.matrix3_rotate_f32(angle_radians, g_world_up) * controller.forward)
}

camera_controller_rotate_pitch :: proc(controller: ^CameraController, angle_radians: f32) {
    right := linalg.normalize0(linalg.cross(controller.forward, g_world_up))
    max_pitch := f32(math.to_radians(89.0))
    final_pitch := linalg.clamp(controller.pitch + angle_radians, -max_pitch, max_pitch)
    actual_angle_to_rotate := final_pitch - controller.pitch
    controller.pitch = final_pitch
    controller.forward = linalg.normalize(linalg.matrix3_rotate_f32(actual_angle_to_rotate, right) * controller.forward)
}

camera_controller_orbit :: proc(controller: ^CameraController, yaw_radians, pitch_radians: f32) {
    orbit_center := controller.position + controller.forward * controller.orbit_distance
    vector_to_rotate := controller.position - orbit_center

    right := linalg.normalize(linalg.cross(controller.forward, g_world_up))
    up := linalg.cross(right, controller.forward)
    new_position := linalg.matrix3_rotate_f32(yaw_radians, up) * vector_to_rotate
    new_position = linalg.matrix3_rotate_f32(pitch_radians, right) * new_position

    controller.position = orbit_center + new_position
    controller.forward = linalg.normalize(-new_position)
}
