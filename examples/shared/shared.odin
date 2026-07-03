package shared

import gfx "../../src"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"

Mat4 :: [4][4]f32
Vec3 :: linalg.Vector3f32

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
	return mat4_from_linalg(linalg.matrix4_look_at(eye, camera.target, Vec3{0, 1, 0}))
}

window_aspect :: proc(window: ^gfx.Ez_Gfx_Window) -> f32 {
	width, height := gfx.ez_gfx_window_get_framebuffer_size(window)
	if width <= 0 do width = 1
	if height <= 0 do height = 1
	return f32(width) / f32(height)
}

perspective_vk :: proc(fovy_radians, aspect, near_z, far_z: f32) -> Mat4 {
	result := linalg.matrix4_perspective(fovy_radians, aspect, near_z, far_z)
	// Vulkan's clip space has inverted Y compared to the linalg camera convention.
	result[1, 1] = -result[1, 1]
	return mat4_from_linalg(result)
}

mat4_identity :: proc() -> Mat4 {
	return mat4_from_linalg(linalg.MATRIX4F32_IDENTITY)
}

mat4_mul :: proc(a, b: Mat4) -> Mat4 {
	return mat4_from_linalg(linalg.mul(mat4_to_linalg(a), mat4_to_linalg(b)))
}

mat4_rotation_x :: proc(angle: f32) -> Mat4 {
	return mat4_from_linalg(linalg.matrix4_rotate(angle, Vec3{1, 0, 0}))
}

mat4_rotation_y :: proc(angle: f32) -> Mat4 {
	return mat4_from_linalg(linalg.matrix4_rotate(angle, Vec3{0, 1, 0}))
}

look_at :: proc(eye, target, up: Vec3) -> Mat4 {
	return mat4_from_linalg(linalg.matrix4_look_at(eye, target, up))
}

mat4_from_linalg :: proc(m: linalg.Matrix4f32) -> Mat4 {
	result: Mat4
	for row in 0 ..< 4 {
		for col in 0 ..< 4 {
			result[row][col] = m[row, col]
		}
	}
	return result
}

mat4_to_linalg :: proc(m: Mat4) -> linalg.Matrix4f32 {
	result: linalg.Matrix4f32
	for row in 0 ..< 4 {
		for col in 0 ..< 4 {
			result[row, col] = m[row][col]
		}
	}
	return result
}

mat4_transform_point :: proc(m: Mat4, p: [4]f32) -> [4]f32 {
	return {
		m[0][0] * p.x + m[0][1] * p.y + m[0][2] * p.z + m[0][3] * p.w,
		m[1][0] * p.x + m[1][1] * p.y + m[1][2] * p.z + m[1][3] * p.w,
		m[2][0] * p.x + m[2][1] * p.y + m[2][2] * p.z + m[2][3] * p.w,
		m[3][0] * p.x + m[3][1] * p.y + m[3][2] * p.z + m[3][3] * p.w,
	}
}

mat4_transform_direction :: proc(m: Mat4, d: [4]f32) -> [4]f32 {
	transformed := Vec3 {
		m[0][0] * d.x + m[0][1] * d.y + m[0][2] * d.z,
		m[1][0] * d.x + m[1][1] * d.y + m[1][2] * d.z,
		m[2][0] * d.x + m[2][1] * d.y + m[2][2] * d.z,
	}
	normalized := vec3_normalize(transformed)
	return {normalized.x, normalized.y, normalized.z, 0.0}
}

vec3_dot :: proc(a, b: Vec3) -> f32 {
	return linalg.dot(a, b)
}

vec3_cross :: proc(a, b: Vec3) -> Vec3 {
	return linalg.cross(a, b)
}

vec3_normalize :: proc(v: Vec3) -> Vec3 {
	return linalg.normalize0(v)
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
