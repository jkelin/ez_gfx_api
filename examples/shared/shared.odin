package shared

import gfx "../../src"
import "core:math"
import "core:strings"
import "core:math/linalg"
import win "core:sys/windows"
import "vendor:glfw"

Mat4 :: [4][4]f32
Vec3 :: linalg.Vector3f32
EXAMPLE_MAX_WINDOWS :: 1
EXAMPLE_RESIZE_DEBOUNCE_SECONDS :: 0.05

// glTF coordinates are in meters. Example 2's cube spans [-1, 1] per axis,
// which is treated as a 1 meter cube (2 world units across).
EXAMPLE_WORLD_UNITS_PER_METER :: 2.0

Orbit_Camera :: struct {
	target:                Vec3,
	yaw:                   f32,
	pitch:                 f32,
	distance:              f32,
	previous_cursor_valid: bool,
	previous_cursor:       [2]f64,
}

ORBIT_CAMERA_MIN_DISTANCE :: 0.1
ORBIT_CAMERA_MAX_DISTANCE :: 100.0

Orbit_Camera_Start :: struct {
	yaw:      f32,
	pitch:    f32,
	distance: f32,
}

orbit_camera_scroll_y: f64

example_glfw_init :: proc() -> bool {
	if !glfw.Init() do return false
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.VISIBLE, !gfx.ez_gfx_config_hidden_window())
	return true
}

example_glfw_terminate :: proc() {
	glfw.Terminate()
}

Example_Window :: struct {
	ctx:                gfx.Ez_Gfx_Context_Handle,
	surface:            gfx.Ez_Gfx_Surface_Handle,
	host_window:        glfw.WindowHandle,
	framebuffer_width:  int,
	framebuffer_height: int,
	framebuffer_resized: bool,
}

example_window_create :: proc(
	window: ^Example_Window,
	ctx: gfx.Ez_Gfx_Context_Handle,
	title: string,
	width, height: int,
) -> bool {
	if window == nil || ctx == 0 || width <= 0 || height <= 0 do return false
	title_c, title_err := strings.clone_to_cstring(title)
	if title_err != nil do return false
	defer delete(title_c)
	handle := glfw.CreateWindow(i32(width), i32(height), title_c, nil, nil)
	if handle == nil {
		return false
	}
	window.ctx = ctx
	window.host_window = handle
	desc: gfx.Ez_Gfx_Surface_Desc
	when ODIN_OS == .Windows {
		desc.window = rawptr(glfw.GetWin32Window(handle))
		desc.display = rawptr(win.GetModuleHandleW(nil))
		desc.platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32
	} else {
		desc.window = rawptr(handle)
		desc.display = nil
		desc.platform = gfx.EZ_GFX_SURFACE_PLATFORM_GLFW
	}
	width_px, height_px := glfw.GetFramebufferSize(handle)
	window.framebuffer_width = int(width_px)
	window.framebuffer_height = int(height_px)
	desc.width = u32(max(width_px, 0))
	desc.height = u32(max(height_px, 0))
	desc.cache_presented_snapshots = gfx.ez_gfx_config_screenshot_enabled()
	surface, status := gfx.ez_gfx_surface_create(ctx, desc)
	if status != .Ok {
		glfw.DestroyWindow(handle)
		window^ = {}
		return false
	}
	window.surface = surface
	return true
}

example_window_handle :: proc(window: ^Example_Window) -> glfw.WindowHandle {
	if window == nil do return nil
	return window.host_window
}

example_window_should_close :: proc(window: ^Example_Window) -> bool {
	handle := example_window_handle(window)
	if handle == nil do return true
	return glfw.WindowShouldClose(handle) != b32(false)
}

example_window_poll_events :: proc(window: ^Example_Window) {
	for {
		glfw.PollEvents()
		handle := example_window_handle(window)
		if handle == nil do return
		if glfw.WindowShouldClose(handle) != b32(false) do return

		width, height := glfw.GetFramebufferSize(handle)
		if width <= 0 || height <= 0 {
			window.framebuffer_width = int(width)
			window.framebuffer_height = int(height)
			window.framebuffer_resized = true
			glfw.WaitEvents()
			continue
		}

		if int(width) != window.framebuffer_width || int(height) != window.framebuffer_height {
			window.framebuffer_width = int(width)
			window.framebuffer_height = int(height)
			window.framebuffer_resized = true
			glfw.WaitEventsTimeout(EXAMPLE_RESIZE_DEBOUNCE_SECONDS)
			continue
		}

		if window.framebuffer_resized {
			_ = gfx.ez_gfx_surface_resize(window.ctx, window.surface, u32(width), u32(height))
			window.framebuffer_resized = false
		}
		return
	}
}

example_window_destroy :: proc(window: ^Example_Window) {
	if window == nil do return
	handle := example_window_handle(window)
	if window.ctx != 0 && window.surface != 0 {
		_ = gfx.ez_gfx_surface_destroy(window.ctx, window.surface)
	}
	if handle != nil {
		glfw.DestroyWindow(handle)
	}
	window^ = {}
}

example_window_set_should_close :: proc(window: ^Example_Window, value: bool) {
	handle := example_window_handle(window)
	if handle != nil {
		glfw.SetWindowShouldClose(handle, b32(value))
	}
}

example_window_get_framebuffer_size :: proc(window: ^Example_Window) -> (int, int) {
	handle := example_window_handle(window)
	if handle == nil do return 0, 0
	width, height := glfw.GetFramebufferSize(handle)
	return int(width), int(height)
}

example_window_install_scroll_callback :: proc(window: ^Example_Window) {
	handle := example_window_handle(window)
	if handle != nil {
		glfw.SetScrollCallback(handle, orbit_camera_scroll_callback)
	}
}

example_window_cursor_pos :: proc(window: ^Example_Window) -> (f64, f64) {
	handle := example_window_handle(window)
	if handle == nil do return 0, 0
	return glfw.GetCursorPos(handle)
}

example_window_left_button_pressed :: proc(window: ^Example_Window) -> bool {
	handle := example_window_handle(window)
	return handle != nil && glfw.GetMouseButton(handle, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
}

example_handle_window_input :: proc(window: ^Example_Window) {
	handle := example_window_handle(window)
	if handle != nil && glfw.GetKey(handle, glfw.KEY_ESCAPE) == glfw.PRESS {
		example_window_set_should_close(window, true)
	}
}

orbit_camera_install_callbacks :: proc(window: ^Example_Window) {
	example_window_install_scroll_callback(window)
}

orbit_camera_default :: proc() -> Orbit_Camera {
	return Orbit_Camera {
		target   = {0, 0, 0},
		yaw      = math.to_radians_f32(35),
		pitch    = math.to_radians_f32(22),
		distance = 5.0,
	}
}

orbit_camera_default_start :: proc() -> Orbit_Camera_Start {
	return Orbit_Camera_Start {
		yaw      = math.to_radians_f32(35),
		pitch    = math.to_radians_f32(22),
		distance = 5.0,
	}
}

orbit_camera_apply_start :: proc(camera: ^Orbit_Camera, center: Vec3, start: Orbit_Camera_Start) {
	camera.target = center
	camera.yaw = start.yaw
	camera.pitch = start.pitch
	camera.distance = start.distance
	camera.previous_cursor_valid = false
}

orbit_camera_update :: proc(
	camera: ^Orbit_Camera,
	window: ^Example_Window,
	center: Vec3,
	start: Orbit_Camera_Start,
	delta_time: f32,
) {
	_ = delta_time
	camera.target = center

	if !camera.previous_cursor_valid {
		camera.yaw = start.yaw
		camera.pitch = start.pitch
		camera.distance = start.distance
	}

	x, y := example_window_cursor_pos(window)
	cursor_delta: [2]f32
	if camera.previous_cursor_valid {
		cursor_delta = {
			f32(x - camera.previous_cursor.x),
			f32(y - camera.previous_cursor.y),
		}
	}
	camera.previous_cursor = {x, y}
	camera.previous_cursor_valid = true

	if example_window_left_button_pressed(window) {
		mouse_sensitivity := math.to_radians_f32(0.18)
		camera.yaw -= cursor_delta.x * mouse_sensitivity
		camera.pitch += cursor_delta.y * mouse_sensitivity
	}

	if orbit_camera_scroll_y != 0 {
		zoom_factor := f32(math.pow(0.85, orbit_camera_scroll_y))
		camera.distance *= zoom_factor
		orbit_camera_scroll_y = 0
	}

	camera.pitch = clamp_f32(
		camera.pitch,
		math.to_radians_f32(-80),
		math.to_radians_f32(80),
	)
	camera.distance = clamp_f32(
		camera.distance,
		ORBIT_CAMERA_MIN_DISTANCE,
		ORBIT_CAMERA_MAX_DISTANCE,
	)
}

orbit_camera_scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	_ = window
	_ = xoffset
	orbit_camera_scroll_y += yoffset
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

window_aspect :: proc(window: ^Example_Window) -> f32 {
	width, height := example_window_get_framebuffer_size(window)
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
