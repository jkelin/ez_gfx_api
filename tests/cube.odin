package tests

import shared "../examples/shared"
import gfx "../src"
import "core:math"
import "core:testing"
import "vendor:glfw"
import vk "vendor:vulkan"

CUBE_TEST_FRAMES :: 2
CUBE_TEST_SHADER_PATH :: cstring("examples/2_textured_cube/cube.slang")
CUBE_TEST_POSITION_HEAP :: "position"
CUBE_TEST_COLOR_HEAP :: "color"

Cube_Test_Push_Constants :: struct {
	mvp: shared.Mat4,
}

Cube_Test_Bad_Push_Constants :: struct {
	value: [4]f32,
}

CUBE_TEST_INDICES :: [36]u32 {
	0, 1, 2, 2, 3, 0,
	4, 5, 6, 6, 7, 4,
	8, 9, 10, 10, 11, 8,
	12, 13, 14, 14, 15, 12,
	16, 17, 18, 18, 19, 16,
	20, 21, 22, 22, 23, 20,
}

CUBE_TEST_POSITIONS :: [24][4]f32 {
	{-1, -1, 1, 1}, {1, -1, 1, 1}, {1, 1, 1, 1}, {-1, 1, 1, 1},
	{1, -1, -1, 1}, {-1, -1, -1, 1}, {-1, 1, -1, 1}, {1, 1, -1, 1},
	{-1, -1, -1, 1}, {-1, -1, 1, 1}, {-1, 1, 1, 1}, {-1, 1, -1, 1},
	{1, -1, 1, 1}, {1, -1, -1, 1}, {1, 1, -1, 1}, {1, 1, 1, 1},
	{-1, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, -1, 1}, {-1, 1, -1, 1},
	{-1, -1, -1, 1}, {1, -1, -1, 1}, {1, -1, 1, 1}, {-1, -1, 1, 1},
}

CUBE_TEST_COLORS :: [24][4]f32 {
	{1, 0, 0, 1}, {1, 0, 0, 1}, {1, 0, 0, 1}, {1, 0, 0, 1},
	{0, 1, 0, 1}, {0, 1, 0, 1}, {0, 1, 0, 1}, {0, 1, 0, 1},
	{0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1},
	{1, 1, 0, 1}, {1, 1, 0, 1}, {1, 1, 0, 1}, {1, 1, 0, 1},
	{1, 0, 1, 1}, {1, 0, 1, 1}, {1, 0, 1, 1}, {1, 0, 1, 1},
	{0, 1, 1, 1}, {0, 1, 1, 1}, {0, 1, 1, 1}, {0, 1, 1, 1},
}

Cube_Test_App :: struct {
	ctx:            gfx.Ez_Gfx_Ctx,
	window:         gfx.Ez_Gfx_Window,
	shader:         gfx.Ez_Gfx_Shader_Program,
	shader_loaded:  bool,
	cube_index:     u32,
	cube_index_len: u32,
	cube_vertex:    u32,
	camera:         shared.Orbit_Camera,
	validation_log: Validation_Log,
}

@(test)
cube_shader_reflects_push_constant_size :: proc(t: ^testing.T) {
	app: Cube_Test_App
	if !testing.expect(t, cube_test_init_app(&app), "cube reflection test failed during init") {
		cube_test_cleanup(&app)
		return
	}
	defer cube_test_cleanup(&app)

	testing.expect_value(t, app.shader.push_constant_size, u32(size_of(Cube_Test_Push_Constants)))
}

@(test)
cube_renders_without_validation_errors :: proc(t: ^testing.T) {
	app: Cube_Test_App
	if !testing.expect(t, cube_test_init_app(&app), "cube render test failed during init") {
		cube_test_cleanup(&app)
		return
	}
	defer cube_test_cleanup(&app)

	frames_drawn := 0
	attempts := 0
	for frames_drawn < CUBE_TEST_FRAMES && attempts < 60 {
		attempts += 1
		gfx.ez_gfx_window_poll_events()
		if gfx.ez_gfx_window_should_close(&app.window) do return
		if cube_test_draw_frame(&app, f32(frames_drawn) * 0.25) {
			frames_drawn += 1
		}
	}
	if !testing.expect_value(t, frames_drawn, CUBE_TEST_FRAMES) {
		return
	}

	gfx.ez_gfx_ctx_wait_idle()
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

@(test)
cube_push_constant_size_mismatch_fails_cleanly :: proc(t: ^testing.T) {
	app: Cube_Test_App
	if !testing.expect(t, cube_test_init_app(&app), "cube mismatch test failed during init") {
		cube_test_cleanup(&app)
		return
	}
	defer cube_test_cleanup(&app)

	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window), "cube mismatch test failed to begin render") {
		return
	}
	pipeline := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shader,
		vk.DeviceSize(size_of(vk.DrawIndexedIndirectCommand)),
		1,
		Cube_Test_Bad_Push_Constants{},
	)
	testing.expect(t, !pipeline.ok, "push constant size mismatch unexpectedly succeeded")
	_ = gfx.ez_gfx_finish_render()

	gfx.ez_gfx_ctx_wait_idle()
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

cube_test_init_app :: proc(app: ^Cube_Test_App) -> bool {
	if !gfx.ez_gfx_glfw_init() do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	app.camera = shared.orbit_camera_default()
	if !gfx.ez_gfx_window_create(
		&app.window,
		"ez_gfx_api cube test",
		WIDTH,
		HEIGHT,
		hidden = true,
	) {
		return false
	}
	if !gfx.ez_gfx_ctx_create_instance(
		&app.ctx,
		{
			enable_validation = true,
			validation_callback = validation_callback,
			validation_user_data = &app.validation_log,
			enable_debug = true,
		},
	) {
		return false
	}
	if !gfx.ez_gfx_window_create_surface(&app.window) do return false
	if !gfx.ez_gfx_ctx_init_device(app.window.surface) do return false
	if !gfx.ez_gfx_window_recreate_swapchain(&app.window) do return false
	return cube_test_init_resources(app)
}

cube_test_init_resources :: proc(app: ^Cube_Test_App) -> bool {
	if !gfx.ez_gfx_shader_compile(
		{
			path = CUBE_TEST_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},
		&app.shader,
	) {
		return false
	}
	app.shader_loaded = true

	vertex_heap_names := [?]string{CUBE_TEST_POSITION_HEAP, CUBE_TEST_COLOR_HEAP}
	if !gfx.ez_gfx_vertex_manager_create(
		&app.ctx.vertex_manager,
		vertex_heap_names[:],
		vk.DeviceSize(size_of(CUBE_TEST_POSITIONS[0])),
	) {
		return false
	}

	indices := CUBE_TEST_INDICES
	index_start, index_ok := gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		indices[:],
	)
	if !index_ok do return false
	app.cube_index = index_start
	app.cube_index_len = u32(len(indices))

	positions := CUBE_TEST_POSITIONS
	vertex_start, vertex_ok := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		CUBE_TEST_POSITION_HEAP,
		positions[:],
	)
	if !vertex_ok do return false
	app.cube_vertex = vertex_start

	colors := CUBE_TEST_COLORS
	_, color_ok := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		CUBE_TEST_COLOR_HEAP,
		colors[:],
	)
	return color_ok
}

cube_test_draw_frame :: proc(app: ^Cube_Test_App, time_seconds: f32) -> bool {
	if !gfx.ez_gfx_begin_render(&app.window) do return false

	model := shared.mat4_mul(
		shared.mat4_rotation_y(time_seconds),
		shared.mat4_rotation_x(time_seconds * 0.65),
	)
	view := shared.orbit_camera_view(&app.camera)
	projection := shared.perspective_vk(
		math.to_radians_f32(60),
		shared.window_aspect(&app.window),
		0.1,
		100.0,
	)
	push_constants := Cube_Test_Push_Constants {
		mvp = shared.mat4_mul(projection, shared.mat4_mul(view, model)),
	}

	pipeline := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shader,
		vk.DeviceSize(size_of(vk.DrawIndexedIndirectCommand)),
		1,
		push_constants,
	)
	if !pipeline.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	draw := vk.DrawIndexedIndirectCommand {
		indexCount    = app.cube_index_len,
		instanceCount = 1,
		firstIndex    = app.cube_index,
		vertexOffset  = i32(app.cube_vertex),
		firstInstance = 0,
	}
	if !gfx.ez_gfx_vertex_pipeline_write_draw(&pipeline, 0, draw) {
		_ = gfx.ez_gfx_finish_render()
		return false
	}
	if !gfx.ez_gfx_vertex_pipeline_set_draw_count(&pipeline, 1) {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	return gfx.ez_gfx_finish_render()
}

cube_test_cleanup :: proc(app: ^Cube_Test_App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	if app.shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.shader)
		app.shader_loaded = false
	}
	gfx.ez_gfx_window_destroy(&app.window)
	gfx.ez_gfx_ctx_destroy()
	gfx.ez_gfx_glfw_terminate()
}
