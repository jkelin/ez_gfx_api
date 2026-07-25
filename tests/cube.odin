#+private
package tests

import shared "../examples/shared"
import gfx "../src"
import "core:math"
import "core:testing"
import vk "vendor:vulkan"

CUBE_TEST_FRAMES :: 2
CUBE_TEST_SHADER_PATH :: cstring("examples/2_textured_cube/cube.slang")
CUBE_TEST_POSITION_HEAP :: "position"
CUBE_TEST_COLOR_HEAP :: "color"
CUBE_TEST_TEXTURE_BYTES: [4]u8 = {255, 255, 255, 255}

Cube_Test_Push_Constants :: struct {
	mvp:        shared.Mat4,
	texture_id: u32,
	_padding:   [3]u32,
}

Cube_Test_Bad_Push_Constants :: struct {
	value: [4]f32,
}

CUBE_TEST_INDICES: [36]u32 = {
	0, 1, 2, 2, 3, 0,
	4, 5, 6, 6, 7, 4,
	8, 9, 10, 10, 11, 8,
	12, 13, 14, 14, 15, 12,
	16, 17, 18, 18, 19, 16,
	20, 21, 22, 22, 23, 20,
}

CUBE_TEST_POSITIONS: [24][4]f32 = {
	{-1, -1, 1, 1}, {1, -1, 1, 1}, {1, 1, 1, 1}, {-1, 1, 1, 1},
	{1, -1, -1, 1}, {-1, -1, -1, 1}, {-1, 1, -1, 1}, {1, 1, -1, 1},
	{-1, -1, -1, 1}, {-1, -1, 1, 1}, {-1, 1, 1, 1}, {-1, 1, -1, 1},
	{1, -1, 1, 1}, {1, -1, -1, 1}, {1, 1, -1, 1}, {1, 1, 1, 1},
	{-1, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, -1, 1}, {-1, 1, -1, 1},
	{-1, -1, -1, 1}, {1, -1, -1, 1}, {1, -1, 1, 1}, {-1, -1, 1, 1},
}

CUBE_TEST_COLORS: [24][4]f32 = {
	{1, 0, 0, 1}, {1, 0, 0, 1}, {1, 0, 0, 1}, {1, 0, 0, 1},
	{0, 1, 0, 1}, {0, 1, 0, 1}, {0, 1, 0, 1}, {0, 1, 0, 1},
	{0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1}, {0, 0, 1, 1},
	{1, 1, 0, 1}, {1, 1, 0, 1}, {1, 1, 0, 1}, {1, 1, 0, 1},
	{1, 0, 1, 1}, {1, 0, 1, 1}, {1, 0, 1, 1}, {1, 0, 1, 1},
	{0, 1, 1, 1}, {0, 1, 1, 1}, {0, 1, 1, 1}, {0, 1, 1, 1},
}

Cube_Test_App :: struct {
	ctx:            gfx.Ez_Gfx_Context_Handle,
	window:         shared.Example_Window,
	shader:         gfx.Ez_Gfx_Shader_Handle,
	shader_loaded:  bool,
	texture_id:     gfx.Ez_Gfx_Texture_Handle,
	texture_scheduled: bool,
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

	info: gfx.Ez_Gfx_Ctx_Info
	testing.expect_value(t, gfx.ez_gfx_context_get_info(app.ctx, &info), gfx.Ez_Gfx_Status.Ok)
}

@(test)
cube_renders_without_validation_errors :: proc(t: ^testing.T) {
	app: Cube_Test_App
		if !testing.expect(t, cube_test_init_app(&app), "cube render test failed during init") {
		cube_test_cleanup(&app)
		return
	}
	defer cube_test_cleanup(&app)
	cube_test_reset_validation_counts(&app)

	frames_drawn := 0
	attempts := 0
	// Keep the screenshot frame count deterministic while covering the default three-image swapchain.
	target_frames := max(CUBE_TEST_FRAMES, 4)
	for frames_drawn < target_frames && attempts < 60 {
		attempts += 1
		shared.example_window_poll_events(&app.window)
		if shared.example_window_should_close(&app.window) do return
		if cube_test_draw_frame(&app, f32(frames_drawn) * 0.25) {
			frames_drawn += 1
		}
	}
	if !testing.expect_value(t, frames_drawn, target_frames) {
		return
	}

	gfx.ez_gfx_context_wait_idle(app.ctx)
	expect_window_snapshot(t, &app.window, "cube")
	testing.expect_value(t, app.validation_log.warnings, u32(0))
	testing.expect_value(t, app.validation_log.errors, u32(0))
	cube_test_expect_no_validation_errors(t, &app)
}

@(test)
cube_push_constant_size_mismatch_fails_cleanly :: proc(t: ^testing.T) {
	app: Cube_Test_App
		if !testing.expect(t, cube_test_init_app(&app), "cube mismatch test failed during init") {
		cube_test_cleanup(&app)
		return
	}
	defer cube_test_cleanup(&app)

	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "cube mismatch test failed to begin render") {
		return
	}
	cube_test_reset_validation_counts(&app)
	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(
		app.ctx,
		1,
		"cube mismatch draw commands",
	)
	if !testing.expect_value(t, indirect_status, gfx.Ez_Gfx_Status.Ok) {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(
		app.ctx,
		app.shader,
		indirect,
		nil,
		{},
		rawptr(&Cube_Test_Bad_Push_Constants{}),
		u32(size_of(Cube_Test_Bad_Push_Constants)),
	)
	testing.expect_value(t, pipeline_status, gfx.Ez_Gfx_Status.Invalid_Argument)
	_ = gfx.ez_gfx_finish_render_context(app.ctx)

	gfx.ez_gfx_context_wait_idle(app.ctx)
	testing.expect_value(t, app.validation_log.warnings, u32(0))
	testing.expect_value(t, app.validation_log.errors, u32(0))
	cube_test_expect_no_validation_errors(t, &app)
}

cube_test_init_app :: proc(app: ^Cube_Test_App) -> bool {
	if !shared.example_glfw_init() do return false

		app.camera = shared.orbit_camera_default()
	ctx, ctx_status := gfx.ez_gfx_context_create({
		enable_validation = true,
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	})
	if ctx_status != .Ok do return false
	app.ctx = ctx
	if !shared.example_window_create(&app.window, app.ctx, "ez_gfx_api cube test", WIDTH, HEIGHT) do return false
	if gfx.ez_gfx_surface_init_device(app.ctx, app.window.surface) != .Ok do return false
	if gfx.ez_gfx_surface_resize(app.ctx, app.window.surface, u32(app.window.framebuffer_width), u32(app.window.framebuffer_height)) != .Ok do return false
	return cube_test_init_resources(app)
}

cube_test_init_resources :: proc(app: ^Cube_Test_App) -> bool {
	shader_handle, shader_status := gfx.ez_gfx_shader_create(app.ctx, {
			path = CUBE_TEST_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},)
	if shader_status != .Ok {
		return false
	}
	app.shader = shader_handle
	app.shader_loaded = true

	if gfx.ez_gfx_vertex_heap_create(app.ctx, CUBE_TEST_POSITION_HEAP, gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES, vk.DeviceSize(size_of(CUBE_TEST_POSITIONS[0]))) != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, CUBE_TEST_COLOR_HEAP, gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES, vk.DeviceSize(size_of(CUBE_TEST_COLORS[0]))) != .Ok do return false
	if gfx.ez_gfx_index_heap_create(app.ctx, vk.DeviceSize(size_of(CUBE_TEST_INDICES) + 4096), "cube test index heap") != .Ok {
		return false
	}

	index_start, index_status := gfx.ez_gfx_vertex_upload_indices(app.ctx, CUBE_TEST_INDICES[:])
	if index_status != .Ok do return false
	app.cube_index = index_start
	app.cube_index_len = u32(len(CUBE_TEST_INDICES))
	vertex_start, vertex_status := gfx.ez_gfx_vertex_upload(app.ctx, CUBE_TEST_POSITION_HEAP, CUBE_TEST_POSITIONS[:])
	if vertex_status != .Ok do return false
	app.cube_vertex = vertex_start

	_, color_status := gfx.ez_gfx_vertex_upload(app.ctx, CUBE_TEST_COLOR_HEAP, CUBE_TEST_COLORS[:])
	if color_status != .Ok do return false

	region := gfx.Ez_Gfx_Texture_Memory_Region{data = CUBE_TEST_TEXTURE_BYTES[:]}
	texture_id, texture_err := gfx.ez_gfx_texture_load(app.ctx, 
		[]gfx.Ez_Gfx_Texture_Memory_Region{region},
		{
			source_format = .RGBA,
			destination_format = .R8G8B8A8_UNORM,
			width = 1,
			height = 1,
			mip_count = 1,
			debug_label = "cube test texture",
		},
	)
	if texture_err != .None do return false
	app.texture_id = texture_id
	app.texture_scheduled = true
	return true
}

cube_test_draw_frame :: proc(app: ^Cube_Test_App, time_seconds: f32) -> bool {
	if gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) != .Ok do return false

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
		texture_id = cube_test_texture_binding(app),
	}

	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(
		app.ctx,
		1,
		"cube test draw commands",
	)
	if indirect_status != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}

	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(
		app.ctx,
		app.shader,
		indirect,
		nil,
		{},
		rawptr(&push_constants),
		u32(size_of(Cube_Test_Push_Constants)),
	)
	if pipeline_status != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}

	draw := gfx.Ez_Gfx_Draw_Indexed_Command {
		index_count    = app.cube_index_len,
		instance_count = 1,
		first_index    = app.cube_index,
		vertex_offset  = i32(app.cube_vertex),
		first_instance = 0,
	}
	if gfx.ez_gfx_indirect_write_draw(app.ctx, indirect, 0, draw) != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}
	if gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, 1) != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}

	return gfx.ez_gfx_finish_render_context(app.ctx) == .Ok
}

cube_test_texture_binding :: proc(app: ^Cube_Test_App) -> u32 {
	binding, err := gfx.ez_gfx_texture_binding_index(app.ctx, app.texture_id)
	if err != .None do return 0
	return binding
}

cube_test_expect_no_validation_errors :: proc(t: ^testing.T, app: ^Cube_Test_App) {
	info: gfx.Ez_Gfx_Ctx_Info
	if testing.expect_value(t, gfx.ez_gfx_context_get_info(app.ctx, &info), gfx.Ez_Gfx_Status.Ok) {
		testing.expect_value(t, info.validation_counts.error, u32(0))
	}
}


cube_test_cleanup :: proc(app: ^Cube_Test_App) {
		if app.shader_loaded {
		gfx.ez_gfx_shader_release(app.ctx, app.shader)
		app.shader_loaded = false
	}
	if app.texture_scheduled {
		_ = gfx.ez_gfx_texture_unload(app.ctx, app.texture_id)
		app.texture_scheduled = false
	}
	shared.example_window_destroy(&app.window)
	gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}

cube_test_reset_validation_counts :: proc(app: ^Cube_Test_App) {
	app.validation_log = {}
	
}
