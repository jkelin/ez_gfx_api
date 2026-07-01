package shared

import gfx "../../src"
import "core:math"
import "vendor:glfw"

Mat4 :: [4][4]f32
Vec3 :: [3]f32

Example_Input :: struct {
	previous_cursor_valid: bool,
	previous_cursor:       [2]f64,
	cursor_delta:          [2]f32,
	right_mouse_down:      bool,
}

Orbit_Camera :: struct {
	target:   Vec3,
	yaw:      f32,
	pitch:    f32,
	distance: f32,
}

example_input_begin_frame :: proc(input: ^Example_Input, window: ^gfx.Ez_Gfx_Window) {
	input.cursor_delta = {}

	x, y := glfw.GetCursorPos(window.handle)
	if input.previous_cursor_valid {
		input.cursor_delta = {
			f32(x - input.previous_cursor.x),
			f32(y - input.previous_cursor.y),
		}
	}
	input.previous_cursor = {x, y}
	input.previous_cursor_valid = true
	input.right_mouse_down = glfw.GetMouseButton(window.handle, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS

	if glfw.GetKey(window.handle, glfw.KEY_ESCAPE) == glfw.PRESS {
		gfx.ez_gfx_window_set_should_close(window, true)
	}
}

orbit_camera_default :: proc() -> Orbit_Camera {
	return Orbit_Camera {
		target   = {0, 0, 0},
		yaw      = math.to_radians_f32(35),
		pitch    = math.to_radians_f32(22),
		distance = 5.0,
	}
}

orbit_camera_update :: proc(camera: ^Orbit_Camera, input: ^Example_Input, delta_time: f32) {
	camera.yaw += delta_time * 0.35
	if input.right_mouse_down {
		mouse_sensitivity := math.to_radians_f32(0.18)
		camera.yaw += input.cursor_delta.x * mouse_sensitivity
		camera.pitch -= input.cursor_delta.y * mouse_sensitivity
	}
	camera.pitch = clamp_f32(
		camera.pitch,
		math.to_radians_f32(-80),
		math.to_radians_f32(80),
	)
	camera.distance = max_f32(camera.distance, 0.5)
}

orbit_camera_view :: proc(camera: ^Orbit_Camera) -> Mat4 {
	cos_pitch := f32(math.cos(f64(camera.pitch)))
	eye := Vec3 {
		camera.target.x + camera.distance * f32(math.sin(f64(camera.yaw))) * cos_pitch,
		camera.target.y + camera.distance * f32(math.sin(f64(camera.pitch))),
		camera.target.z + camera.distance * f32(math.cos(f64(camera.yaw))) * cos_pitch,
	}
	return look_at(eye, camera.target, {0, 1, 0})
}

window_aspect :: proc(window: ^gfx.Ez_Gfx_Window) -> f32 {
	width, height := gfx.ez_gfx_window_get_framebuffer_size(window)
	if width <= 0 do width = 1
	if height <= 0 do height = 1
	return f32(width) / f32(height)
}

perspective_vk :: proc(fovy_radians, aspect, near_z, far_z: f32) -> Mat4 {
	f := f32(1.0 / math.tan(f64(fovy_radians * 0.5)))
	result: Mat4
	result[0][0] = f / aspect
	// Vulkan's clip space has inverted Y compared to this camera convention.
	result[1][1] = -f
	result[2][2] = far_z / (near_z - far_z)
	result[2][3] = (far_z * near_z) / (near_z - far_z)
	result[3][2] = -1.0
	return result
}

mat4_identity :: proc() -> Mat4 {
	result: Mat4
	result[0][0] = 1
	result[1][1] = 1
	result[2][2] = 1
	result[3][3] = 1
	return result
}

mat4_mul :: proc(a, b: Mat4) -> Mat4 {
	result: Mat4
	for row in 0 ..< 4 {
		for col in 0 ..< 4 {
			sum: f32
			for k in 0 ..< 4 {
				sum += a[row][k] * b[k][col]
			}
			result[row][col] = sum
		}
	}
	return result
}

mat4_rotation_x :: proc(angle: f32) -> Mat4 {
	c := f32(math.cos(f64(angle)))
	s := f32(math.sin(f64(angle)))
	result := mat4_identity()
	result[1][1] = c
	result[1][2] = -s
	result[2][1] = s
	result[2][2] = c
	return result
}

mat4_rotation_y :: proc(angle: f32) -> Mat4 {
	c := f32(math.cos(f64(angle)))
	s := f32(math.sin(f64(angle)))
	result := mat4_identity()
	result[0][0] = c
	result[0][2] = s
	result[2][0] = -s
	result[2][2] = c
	return result
}

look_at :: proc(eye, target, up: Vec3) -> Mat4 {
	forward := vec3_normalize(target - eye)
	right := vec3_normalize(vec3_cross(forward, up))
	camera_up := vec3_cross(right, forward)

	result := mat4_identity()
	result[0][0] = right.x
	result[0][1] = right.y
	result[0][2] = right.z
	result[0][3] = -vec3_dot(right, eye)
	result[1][0] = camera_up.x
	result[1][1] = camera_up.y
	result[1][2] = camera_up.z
	result[1][3] = -vec3_dot(camera_up, eye)
	result[2][0] = -forward.x
	result[2][1] = -forward.y
	result[2][2] = -forward.z
	result[2][3] = vec3_dot(forward, eye)
	return result
}

vec3_dot :: proc(a, b: Vec3) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

vec3_cross :: proc(a, b: Vec3) -> Vec3 {
	return {
		a.y * b.z - a.z * b.y,
		a.z * b.x - a.x * b.z,
		a.x * b.y - a.y * b.x,
	}
}

vec3_normalize :: proc(v: Vec3) -> Vec3 {
	len_sq := vec3_dot(v, v)
	if len_sq <= 0 do return {}
	return v / f32(math.sqrt(f64(len_sq)))
}

clamp_f32 :: proc(value, min_value, max_value: f32) -> f32 {
	if value < min_value do return min_value
	if value > max_value do return max_value
	return value
}

max_f32 :: proc(a, b: f32) -> f32 {
	if a > b do return a
	return b
}
