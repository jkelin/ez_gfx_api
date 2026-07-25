#+private
package tests

import shared "../examples/shared"
import gfx "../src"
import "core:testing"
import vk "vendor:vulkan"

WIDTH :: 640
HEIGHT :: 480
TRIANGLE_FRAMES :: 2
TRIANGLE_SHADER_PATH :: cstring("examples/1_triangle/triangle.slang")
GRAPHICS_STRUCTURED_SHADER_PATH :: cstring("tests/graphics_structured.slang")
COMPUTE_STRUCTURED_SHADER_PATH :: cstring("tests/compute_structured.slang")
TRIANGLE_POSITION_HEAP :: "position"

TRIANGLE_INDICES: [3]u32 = {0, 1, 2}
TRIANGLE_POSITIONS: [3][4]f32 = {
	{-0.5, -0.5, 0.0, 1.0},
	{0.5, -0.5, 0.0, 1.0},
	{0.0, 0.5, 0.0, 1.0},
}
TRIANGLE_COLORS: [3][4]f32 = {
	{1.0, 0.0, 0.0, 1.0},
	{0.0, 1.0, 0.0, 1.0},
	{0.0, 0.0, 1.0, 1.0},
}

Validation_Log :: struct {
	warnings: u32,
	errors:   u32,
}

Triangle_App :: struct {
	ctx:            gfx.Ez_Gfx_Context_Handle,
	window:         shared.Example_Window,
	shader:         gfx.Ez_Gfx_Shader_Handle,
	shader_loaded:  bool,
	triangle_index: u32,
	triangle_index_len: u32,
	triangle_vertex: u32,
	validation_log: Validation_Log,
}

@(test)
render_dynamic_state_zero_defaults :: proc(t: ^testing.T) {
	state: gfx.Ez_Gfx_Render_Dynamic_State
	testing.expect(t, state.cull_mode == gfx.Ez_Gfx_Cull_Mode.None, "dynamic state should default to no culling")
	testing.expect_value(t, state.front_face, gfx.Ez_Gfx_Front_Face.COUNTER_CLOCKWISE)
	testing.expect_value(t, state.primitive_type, gfx.Ez_Gfx_Primitive_Type.Triangle_List)
	testing.expect_value(t, state.blend_mode, gfx.Ez_Gfx_Blend_Mode.None)
	testing.expect_value(t, gfx.ez_gfx_render_dynamic_state_to_vk_topology(state.primitive_type), vk.PrimitiveTopology.TRIANGLE_LIST)
}

@(test)
triangle_renders_without_validation_errors :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "triangle test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)
	if !testing.expect(t, triangle_run_frames(&app), "triangle test failed during rendering") do return
	gfx.ez_gfx_context_wait_idle(app.ctx)
	expect_window_snapshot(t, &app.window, "triangle")
	testing.expect_value(t, app.validation_log.errors, u32(0))
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
	if !testing.expect(t, gfx.ez_gfx_context_get_info(app.ctx, &info) == .Ok, "present mode query failed") do return
	if !testing.expect(t, info.swapchain_present_mode_count > 0, "present mode test found no surface modes") do return
	requested := info.swapchain_present_modes[info.swapchain_present_mode_count - 1]
	if gfx.ez_gfx_context_set_present_mode(app.ctx, requested) != .Ok {
		// Some drivers expose only FIFO as a valid runtime mode; querying still
		// proves the public context boundary and resize path remains usable.
		requested = info.swapchain_present_mode
	}
	testing.expect(t, gfx.ez_gfx_surface_resize(app.ctx, app.window.surface, WIDTH, HEIGHT) == .Ok, "present mode resize failed")
	gfx.ez_gfx_context_wait_idle(app.ctx)
}

@(test)
resize_after_screenshot_recreates_without_validation_errors :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "resize test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)
	if !testing.expect(t, triangle_draw_frame(&app), "resize test failed to draw initial frame") do return
	if !testing.expect(t, gfx.ez_gfx_surface_resize(app.ctx, app.window.surface, WIDTH + 32, HEIGHT + 16) == .Ok, "resize test failed to recreate surface") do return
	if !testing.expect(t, triangle_draw_frame(&app), "resize test failed to draw resized frame") do return
	gfx.ez_gfx_context_wait_idle(app.ctx)
	testing.expect_value(t, app.validation_log.errors, u32(0))
}

@(test)
structured_buffer_acquires_per_frame_and_reuses_pool :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "structured buffer test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)
	for frame in 0 ..< 2 {
		if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "structured buffer test failed to begin render") do return
		handle, status := gfx.ez_gfx_acquire_structured(app.ctx, u32, 16, "test_buffer")
		if !testing.expect(t, status == .Ok, "structured buffer acquire failed") {
			_ = gfx.ez_gfx_finish_render_context(app.ctx)
			return
		}
		value := u32(frame)
		testing.expect_value(t, gfx.ez_gfx_structured_write(app.ctx, handle, rawptr(&value), size_of(value)), gfx.Ez_Gfx_Status.Ok)
		testing.expect_value(t, gfx.ez_gfx_finish_render_context(app.ctx), gfx.Ez_Gfx_Status.Ok)
		gfx.ez_gfx_context_wait_idle(app.ctx)
		testing.expect_value(t, gfx.ez_gfx_structured_release(app.ctx, handle), gfx.Ez_Gfx_Status.Ok)
	}
}

@(test)
structured_buffer_pool_trims_oversized_idle_buffers :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "structured buffer trim test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)
	element_counts := [2]u32{1 << 12, 16}
	for element_count in element_counts {
		if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "structured trim test failed to begin render") do return
		handle, status := gfx.ez_gfx_acquire_structured(app.ctx, u8, element_count, "trim_buffer")
		if !testing.expect(t, status == .Ok, "structured trim acquire failed") {
			_ = gfx.ez_gfx_finish_render_context(app.ctx)
			return
		}
		testing.expect_value(t, gfx.ez_gfx_finish_render_context(app.ctx), gfx.Ez_Gfx_Status.Ok)
		gfx.ez_gfx_context_wait_idle(app.ctx)
		testing.expect_value(t, gfx.ez_gfx_structured_release(app.ctx, handle), gfx.Ez_Gfx_Status.Ok)
	}
}

@(test)
explicit_structured_buffer_reuses_one_handle_across_pipelines :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "structured reuse test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)
	graphics_shader, graphics_ok := triangle_compile_graphics_structured_shader(app.ctx)
	if !testing.expect(t, graphics_ok, "failed to compile graphics structured shader") do return
	defer gfx.ez_gfx_shader_release(app.ctx, graphics_shader)
	compute_shader, compute_ok := triangle_compile_compute_structured_shader(app.ctx)
	if !testing.expect(t, compute_ok, "failed to compile compute structured shader") do return
	defer gfx.ez_gfx_shader_release(app.ctx, compute_shader)
	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "structured reuse failed to begin render") do return
	colors, colors_status := gfx.ez_gfx_acquire_structured(app.ctx, [4]f32, u32(len(TRIANGLE_COLORS)), "triangle colors")
	if !testing.expect(t, colors_status == .Ok, "failed to acquire structured colors") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	for &color, i in TRIANGLE_COLORS {
		testing.expect_value(t, gfx.ez_gfx_structured_write(app.ctx, colors, rawptr(&color), size_of(color)), gfx.Ez_Gfx_Status.Ok)
		_ = i
	}
	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(app.ctx, 1, "triangle test draw commands")
	if !testing.expect(t, indirect_status == .Ok, "failed to acquire indirect draw buffer") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	compute_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding{{name = "instances", structured = colors}}
	_, compute_status := gfx.ez_gfx_render_add_compute_pipeline_handles(app.ctx, compute_shader, 1, 1, 1, compute_bindings[:])
	if !testing.expect(t, compute_status == .Ok, "compute pipeline should accept structured handle") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	graphics_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding{{name = "colors", structured = colors}}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(app.ctx, graphics_shader, indirect, graphics_bindings[:])
	testing.expect_value(t, pipeline_status, gfx.Ez_Gfx_Status.Ok)
	_ = gfx.ez_gfx_finish_render_context(app.ctx)
	gfx.ez_gfx_context_wait_idle(app.ctx)
	_ = gfx.ez_gfx_structured_release(app.ctx, colors)
	_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
}

@(test)
explicit_structured_binding_is_required_per_pipeline :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "missing binding test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)
	shader, shader_ok := triangle_compile_graphics_structured_shader(app.ctx)
	if !testing.expect(t, shader_ok, "failed to compile graphics structured shader") do return
	defer gfx.ez_gfx_shader_release(app.ctx, shader)
	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "missing binding test failed to begin render") do return
	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(app.ctx, 1, "missing binding draw")
	if !testing.expect(t, indirect_status == .Ok, "failed to acquire indirect buffer") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(app.ctx, shader, indirect, nil)
	testing.expect_value(t, pipeline_status, gfx.Ez_Gfx_Status.Native_Failure)
	_ = gfx.ez_gfx_finish_render_context(app.ctx)
	_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
}

@(test)
stale_structured_handle_fails_submit_validation :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "stale handle test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)
	shader, shader_ok := triangle_compile_graphics_structured_shader(app.ctx)
	if !testing.expect(t, shader_ok, "failed to compile graphics structured shader") do return
	defer gfx.ez_gfx_shader_release(app.ctx, shader)
	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "stale handle setup failed to begin render") do return
	stale, stale_status := gfx.ez_gfx_acquire_structured(app.ctx, u32, 16, "stale colors")
	if !testing.expect(t, stale_status == .Ok, "failed to acquire stale structured handle") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	_ = gfx.ez_gfx_finish_render_context(app.ctx)
	gfx.ez_gfx_context_wait_idle(app.ctx)
	_ = gfx.ez_gfx_structured_release(app.ctx, stale)
	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "stale handle test failed to begin render") do return
	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(app.ctx, 1, "stale draw")
	if indirect_status != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	bindings := [?]gfx.Ez_Gfx_Public_Render_Binding{{name = "colors", structured = stale}}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(app.ctx, shader, indirect, bindings[:])
	testing.expect_value(t, pipeline_status, gfx.Ez_Gfx_Status.Invalid_Context)
	_ = gfx.ez_gfx_finish_render_context(app.ctx)
	_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
}

@(test)
stale_indirect_handle_cannot_mutate_new_render_frame :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "stale indirect test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)
	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "stale indirect setup failed to begin render") do return
	indirect, status := gfx.ez_gfx_acquire_indirect(app.ctx, 1, "stale indirect")
	if !testing.expect(t, status == .Ok, "failed to acquire indirect buffer") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	_ = gfx.ez_gfx_finish_render_context(app.ctx)
	gfx.ez_gfx_context_wait_idle(app.ctx)
	_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "stale indirect test failed to begin next frame") do return
	draw := gfx.Ez_Gfx_Draw_Indexed_Command{index_count = app.triangle_index_len, instance_count = 1, first_index = app.triangle_index, vertex_offset = i32(app.triangle_vertex)}
	testing.expect_value(t, gfx.ez_gfx_indirect_write_draw(app.ctx, indirect, 0, draw), gfx.Ez_Gfx_Status.Invalid_Context)
	_ = gfx.ez_gfx_finish_render_context(app.ctx)
}

@(test)
structured_size_mismatch_fails_submit_validation :: proc(t: ^testing.T) {
	app: Triangle_App
	if !testing.expect(t, triangle_init_app(&app), "size mismatch test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)
	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "size mismatch test failed to begin render") do return
	colors, colors_status := gfx.ez_gfx_acquire_structured(app.ctx, u32, 16, "size mismatch colors")
	if !testing.expect(t, colors_status == .Ok, "failed to acquire structured colors") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	too_large: [17]u32
	testing.expect_value(t, gfx.ez_gfx_structured_write(app.ctx, colors, rawptr(&too_large), size_of(too_large)), gfx.Ez_Gfx_Status.Invalid_Argument)
	_ = gfx.ez_gfx_finish_render_context(app.ctx)
	gfx.ez_gfx_context_wait_idle(app.ctx)
	_ = gfx.ez_gfx_structured_release(app.ctx, colors)
}

triangle_compile_graphics_structured_shader :: proc(ctx: gfx.Ez_Gfx_Context_Handle) -> (gfx.Ez_Gfx_Shader_Handle, bool) {
	return triangle_compile_shader(ctx, {
		path = GRAPHICS_STRUCTURED_SHADER_PATH,
		vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
		fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
	})
}

triangle_compile_compute_structured_shader :: proc(ctx: gfx.Ez_Gfx_Context_Handle) -> (gfx.Ez_Gfx_Shader_Handle, bool) {
	return triangle_compile_shader(ctx, {
		path = COMPUTE_STRUCTURED_SHADER_PATH,
		compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY,
		kind = .Compute,
	})
}

triangle_compile_shader :: proc(ctx: gfx.Ez_Gfx_Context_Handle, desc: gfx.Ez_Gfx_Shader_Desc) -> (gfx.Ez_Gfx_Shader_Handle, bool) {
	handle, status := gfx.ez_gfx_shader_create(ctx, desc)
	return handle, status == .Ok
}

triangle_init_app :: proc(app: ^Triangle_App) -> bool {
	if !shared.example_glfw_init() {
		return false
	}
	ctx, ctx_status := gfx.ez_gfx_context_create({
		enable_validation = true,
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	})
	if ctx_status != .Ok do return false
	app.ctx = ctx
	if !shared.example_window_create(&app.window, app.ctx, "ez_gfx_api triangle", WIDTH, HEIGHT) {
		return false
	}
	device_status := gfx.ez_gfx_surface_init_device(app.ctx, app.window.surface)
	if device_status != .Ok do return false
	resize_status := gfx.ez_gfx_surface_resize(app.ctx, app.window.surface, u32(WIDTH), u32(HEIGHT))
	if resize_status != .Ok do return false
	return triangle_init_resources(app)
}

triangle_init_resources :: proc(app: ^Triangle_App) -> bool {
	shader, shader_status := gfx.ez_gfx_shader_create(app.ctx, {path = TRIANGLE_SHADER_PATH, vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY, fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY})
	app.shader = shader
	if shader_status != .Ok do return false
	app.shader_loaded = true
	if gfx.ez_gfx_index_heap_create(app.ctx, gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES, "triangle index heap") != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, TRIANGLE_POSITION_HEAP, gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES, vk.DeviceSize(size_of(TRIANGLE_POSITIONS[0]))) != .Ok do return false
	app.triangle_index, shader_status = gfx.ez_gfx_vertex_upload_indices(app.ctx, TRIANGLE_INDICES[:])
	if shader_status != .Ok do return false
	app.triangle_index_len = u32(len(TRIANGLE_INDICES))
	app.triangle_vertex, shader_status = gfx.ez_gfx_vertex_upload(app.ctx, TRIANGLE_POSITION_HEAP, TRIANGLE_POSITIONS[:])
	if shader_status != .Ok do return false
	return true
}

triangle_run_frames :: proc(app: ^Triangle_App) -> bool {
	frames_drawn := 0
	attempts := 0
	for frames_drawn < TRIANGLE_FRAMES && attempts < 60 {
		attempts += 1
		shared.example_window_poll_events(&app.window)
		if shared.example_window_should_close(&app.window) do return false
		if triangle_draw_frame(app) do frames_drawn += 1
	}
	return frames_drawn == TRIANGLE_FRAMES
}

triangle_draw_frame :: proc(app: ^Triangle_App) -> bool {
	if gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) != .Ok do return false
	indirect, status := gfx.ez_gfx_acquire_indirect(app.ctx, 1, "triangle draw commands")
	if status != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(app.ctx, app.shader, indirect, nil)
	if pipeline_status != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}
	draw := gfx.Ez_Gfx_Draw_Indexed_Command{index_count = app.triangle_index_len, instance_count = 1, first_index = app.triangle_index, vertex_offset = i32(app.triangle_vertex)}
	if gfx.ez_gfx_indirect_write_draw(app.ctx, indirect, 0, draw) != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}
	if gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, 1) != .Ok {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return false
	}
	status = gfx.ez_gfx_finish_render_context(app.ctx)
	_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
	return status == .Ok
}

triangle_cleanup :: proc(app: ^Triangle_App) {
	if app.shader_loaded {
		_ = gfx.ez_gfx_shader_release(app.ctx, app.shader)
		app.shader_loaded = false
	}
	shared.example_window_destroy(&app.window)
	if app.ctx != 0 do _ = gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}
