package tests

import gfx "../src"
import "core:fmt"
import "core:testing"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 640
HEIGHT :: 480
TRIANGLE_FRAMES :: 2
TRIANGLE_SHADER_PATH :: cstring("examples/one_triangle/triangle.slang")
TRIANGLE_POSITION_HEAP :: "position"

TRIANGLE_INDICES :: [3]u32{0, 1, 2}
TRIANGLE_POSITIONS :: [3][4]f32 {
	{-0.5, -0.5, 0.0, 1.0},
	{0.5, -0.5, 0.0, 1.0},
	{0.0, 0.5, 0.0, 1.0},
}

Validation_Log :: struct {
	warnings: u32,
	errors:   u32,
}

Triangle_App :: struct {
	ctx:                gfx.Ez_Gfx_Ctx,
	window:             gfx.Ez_Gfx_Window,
	shader:             gfx.Ez_Gfx_Shader_Program,
	shader_loaded:      bool,
	triangle_index:     u32,
	triangle_index_len: u32,
	triangle_vertex:    u32,
	validation_log:     Validation_Log,
}

@(test)
triangle_renders_without_validation_errors :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "triangle test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	if !testing.expect(t, triangle_run_frames(&app), "triangle test failed during rendering") {
		return
	}

	gfx.ez_gfx_ctx_wait_idle()
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

@(test)
present_modes_can_be_queried_and_changed :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "present mode test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	info: gfx.Ez_Gfx_Ctx_Info
	if !testing.expect(
		t,
		gfx.ez_gfx_ctx_get_info(&info),
		"present mode test failed to query context info",
	) {
		return
	}
	if !testing.expect(
		t,
		info.swapchain_present_mode_count > 0,
		"present mode test found no surface modes",
	) {
		return
	}
	testing.expect_value(
		t,
		info.swapchain_present_mode_count,
		app.ctx.swapchain_present_mode_count,
	)

	requested := info.swapchain_present_modes[info.swapchain_present_mode_count - 1]
	testing.expect(
		t,
		gfx.ez_gfx_ctx_set_swapchain_present_mode(requested),
		"present mode test failed to accept a supported mode",
	)
	if !testing.expect(t, gfx.ez_gfx_window_recreate_swapchain(&app.window)) {
		return
	}

	testing.expect_value(t, app.ctx.swapchain_present_mode, requested)
	testing.expect_value(t, app.window.swapchain.present_mode, requested)
	gfx.ez_gfx_ctx_wait_idle()
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

@(test)
resize_after_screenshot_recreates_without_validation_errors :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "resize test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	if !testing.expect(t, triangle_draw_frame(&app), "resize test failed to draw initial frame") {
		return
	}

	pixels: []u8
	if !testing.expect(
		t,
		gfx.ez_gfx_screenshot_read_swapchain_bgra(&app.window.swapchain, &pixels),
		"resize test failed to read a swapchain screenshot",
	) {
		return
	}
	defer delete(pixels)

	app.window.framebuffer_resized = true
	if !testing.expect(t, triangle_draw_frame(&app), "resize test failed to draw resized frame") {
		return
	}

	gfx.ez_gfx_ctx_wait_idle()
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

validation_callback :: proc(
	ctx: ^gfx.Ez_Gfx_Ctx,
	message: gfx.Ez_Gfx_Validation_Message,
	user_data: rawptr,
) {
	_ = ctx
	log := cast(^Validation_Log)user_data
	if log == nil do return
	if .ERROR in message.severity {
		log.errors += 1
		fmt.eprintf("validation error: %v\n", message.message)
	} else if .WARNING in message.severity {
		log.warnings += 1
		fmt.eprintf("validation warning: %v\n", message.message)
	}
}

triangle_init_app :: proc(app: ^Triangle_App) -> bool {
	if !gfx.ez_gfx_glfw_init() do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	if !gfx.ez_gfx_window_create(
		&app.window,
		"ez_gfx_api triangle",
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
	return triangle_init_resources(app)
}

triangle_init_resources :: proc(app: ^Triangle_App) -> bool {
	if !gfx.ez_gfx_shader_compile(
		{
			path = TRIANGLE_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},
		&app.shader,
	) {
		return false
	}
	app.shader_loaded = true

	vertex_heap_names := [?]string{TRIANGLE_POSITION_HEAP}
	if !gfx.ez_gfx_vertex_manager_create(
		&app.ctx.vertex_manager,
		vertex_heap_names[:],
		vk.DeviceSize(size_of(TRIANGLE_POSITIONS[0])),
	) {
		return false
	}

	indices := TRIANGLE_INDICES
	index_start, index_ok := gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		indices[:],
	)
	if !index_ok do return false
	app.triangle_index = index_start
	app.triangle_index_len = u32(len(indices))

	positions := TRIANGLE_POSITIONS
	vertex_start, vertex_ok := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		TRIANGLE_POSITION_HEAP,
		positions[:],
	)
	if !vertex_ok do return false
	app.triangle_vertex = vertex_start
	return true
}

triangle_run_frames :: proc(app: ^Triangle_App) -> bool {
	frames_drawn := 0
	attempts := 0
	for frames_drawn < TRIANGLE_FRAMES && attempts < 60 {
		attempts += 1
		gfx.ez_gfx_window_poll_events()
		if gfx.ez_gfx_window_should_close(&app.window) do return false
		if triangle_draw_frame(app) {
			frames_drawn += 1
		}
	}
	return frames_drawn == TRIANGLE_FRAMES
}

triangle_draw_frame :: proc(app: ^Triangle_App) -> bool {
	if !gfx.ez_gfx_begin_render(&app.window) do return false

	pipeline := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shader,
		vk.DeviceSize(size_of(vk.DrawIndexedIndirectCommand)),
		1,
	)
	if !pipeline.ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	draw := vk.DrawIndexedIndirectCommand {
		indexCount    = app.triangle_index_len,
		instanceCount = 1,
		firstIndex    = app.triangle_index,
		vertexOffset  = i32(app.triangle_vertex),
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

triangle_cleanup :: proc(app: ^Triangle_App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	if app.shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.shader)
		app.shader_loaded = false
	}
	gfx.ez_gfx_window_destroy(&app.window)
	gfx.ez_gfx_ctx_destroy()
	gfx.ez_gfx_glfw_terminate()
}
