package render

import "vendor:glfw"
import "core:math/linalg"
import "thirdparty:imgui"

MouseKey :: enum i32 {
    left   = glfw.MOUSE_BUTTON_LEFT,
    right  = glfw.MOUSE_BUTTON_RIGHT,
    middle = glfw.MOUSE_BUTTON_MIDDLE,
}

Key :: enum i32 {
    tilde   = glfw.KEY_GRAVE_ACCENT,
    space   = glfw.KEY_SPACE,
    lshift  = glfw.KEY_LEFT_SHIFT,
    f12     = glfw.KEY_F12,
    q       = glfw.KEY_Q,
    w       = glfw.KEY_W,
    e       = glfw.KEY_E,
    r       = glfw.KEY_R,
    a       = glfw.KEY_A,
    s       = glfw.KEY_S,
    d       = glfw.KEY_D,
}

KeyState :: struct {
    down:       bool, // Held down
    pressed:    bool, // Pressed this frame
    released:   bool, // Release this frame
}

InputManager :: struct {
    window:             ^Window,
    mouse_position:     float2, // Mouse position in window coordinates. Origin at top left
    mouse_delta:        float2, // Change in window coordinates since the last frame
    mouse_ndc:          float2, // Cursor position in clip space: [-1, 1]
    mouse_captured:     bool,
    mouse_states:       [MouseKey]KeyState,

    key_states:         #sparse[Key]KeyState,
    keys_captured:      bool,
    delta_time:         f32,
}

input_manager_create :: proc(window: ^Window) -> InputManager {
    return InputManager{
        window         = window,
        mouse_position = 0,
        mouse_delta    = 0,
        mouse_ndc      = 0,
        mouse_captured = false,
        delta_time     = 0,
    }
}

// Called at the beginning of every frame, after events have been polled
input_update :: proc(input: ^InputManager, renderer: ^Renderer) {
    window := renderer.window

    input.delta_time = renderer.timer.frame_time
    // Get the mouse updates
    x, y := glfw.GetCursorPos(window.glfw_window)
    position := float2{ f32(x), f32(y) }
    input.mouse_delta    = position - input.mouse_position
    input.mouse_position = position
    input.mouse_ndc = {
        2 * (position.x / f32(window.resolution.x)) - 1,
        2 * (position.y / f32(window.resolution.y)) - 1,
    }
    // TODO: potentially include mouse leaving the window or leaving focus here
    input.mouse_captured = !imgui.GetIO().WantCaptureMouse
    input.keys_captured  = !imgui.GetIO().WantCaptureKeyboard

    // Get all button states
    for key in MouseKey {
        down := glfw.GetMouseButton(window.glfw_window, i32(key)) == glfw.PRESS
        input.mouse_states[key].pressed  = down && !input.mouse_states[key].down
        input.mouse_states[key].released = !down && input.mouse_states[key].down
        input.mouse_states[key].down     = down
    }

    for key in Key {
        down := glfw.GetKey(window.glfw_window, i32(key)) == glfw.PRESS
        input.key_states[key].pressed  = down && !input.key_states[key].down
        input.key_states[key].released = !down && input.key_states[key].down
        input.key_states[key].down     = down
    }
}

// Project the cursor into world space using the inverse viewproj matrix
// mouse_world_position :: proc(input: ^InputManager, inv_viewproj: float4x4, ndc_depth: f32 = 0) -> float3 {
//     clip  := float4{ input.mouse_ndc.x, input.mouse_ndc.y, ndc_depth, 1 }
//     world := inv_viewproj * clip
//     if world.w != 0 do world /= world.w
//     return world.xyz
// }
//
// mouse_world_position_from_viewproj :: proc(input: ^InputManager, viewproj: float4x4, ndc_depth: f32 = 0) -> float3 {
//     return mouse_world_position(input, linalg.inverse(viewproj), ndc_depth)
// }
