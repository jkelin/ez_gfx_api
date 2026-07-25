#+private
package tests

import shared "../examples/shared"
import gfx "../src"
import intrinsics "base:intrinsics"
import "core:fmt"
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
	ctx:                     gfx.Ez_Gfx_Ctx,
	window:                  gfx.Ez_Gfx_Window,
	shader:                  gfx.Ez_Gfx_Shader_Program,
	shader_loaded:           bool,
	triangle_index:          u32,
	triangle_index_len:      u32,
	triangle_vertex:         u32,
	validation_log:          Validation_Log,
	vertex_upload_callbacks: u64,
	vertex_upload_errors:    u64,
}

@(test)
render_dynamic_state_zero_defaults :: proc(t: ^testing.T) {
	state: gfx.Ez_Gfx_Render_Dynamic_State
	testing.expect(t, state.cull_mode == vk.CullModeFlags{}, "dynamic state should default to no culling")
	testing.expect_value(t, state.front_face, vk.FrontFace.COUNTER_CLOCKWISE)
	testing.expect_value(t, state.primitive_type, gfx.Ez_Gfx_Primitive_Type.Triangle_List)
	testing.expect_value(t, state.blend_mode, gfx.Ez_Gfx_Blend_Mode.None)
	testing.expect_value(
		t,
		gfx.ez_gfx_render_dynamic_state_to_vk_topology(state.primitive_type),
		vk.PrimitiveTopology.TRIANGLE_LIST,
	)
}

@(test)
triangle_renders_without_validation_errors :: proc(t: ^testing.T) {
	app: Triangle_App
	context.user_ptr = &app.ctx
	if !testing.expect(t, triangle_init_app(&app), "triangle test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	if !testing.expect(t, triangle_run_frames(&app), "triangle test failed during rendering") {
		return
	}

	gfx.ez_gfx_ctx_wait_idle()
	expect_window_snapshot(t, &app.window, "triangle")
	callbacks := intrinsics.atomic_load_explicit(&app.vertex_upload_callbacks, .Seq_Cst)
	callback_errors := intrinsics.atomic_load_explicit(&app.vertex_upload_errors, .Seq_Cst)
	testing.expect(t, callbacks >= 2, "expected index and vertex upload callbacks")
	testing.expect_value(t, callback_errors, u64(0))
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

@(test)
present_modes_can_be_queried_and_changed :: proc(t: ^testing.T) {
	app: Triangle_App
	context.user_ptr = &app.ctx
	if !testing.expect(t, triangle_init_app(&app), "present mode test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	info: gfx.Ez_Gfx_Ctx_Info
	if !testing.expect(
		t,
		gfx.ez_gfx_ctx_get_info(&info) == .Ok,
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
		gfx.ez_gfx_ctx_set_swapchain_present_mode(requested) == .Ok,
		"present mode test failed to accept a supported mode",
	)
	if !testing.expect(t, gfx.ez_gfx_window_recreate_swapchain(&app.window, app.window.framebuffer_width, app.window.framebuffer_height) == .Ok) {
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
	context.user_ptr = &app.ctx
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
		gfx.ez_gfx_screenshot_read_swapchain_bgra(&app.window.swapchain, &pixels) == .Ok,
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

@(test)
structured_buffer_acquires_per_frame_and_reuses_pool :: proc(t: ^testing.T) {
	app: Triangle_App
	context.user_ptr = &app.ctx
	if !testing.expect(t, triangle_init_app(&app), "structured buffer test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	_, inactive_status := gfx.ez_gfx_render_acquire_structured_buffer(u32, 16, "test_buffer")
	testing.expect_value(t, inactive_status, gfx.Ez_Gfx_Status.Not_Ready)

	for frame in 0 ..< 2 {
		if !testing.expect(
			t,
			gfx.ez_gfx_begin_render(&app.window) == .Ok,
			"structured buffer test failed to begin render",
		) {
			return
		}
		handle, handle_status := gfx.ez_gfx_render_acquire_structured_buffer(u32, 16, "test_buffer")
		if !testing.expect(t, handle_status == .Ok, "structured buffer acquire failed") {
			_ = gfx.ez_gfx_finish_render()
			return
		}
		handle.elements[0] = u32(frame)
		testing.expect(
			t,
			gfx.ez_gfx_finish_render() == .Ok,
			"structured buffer test failed to finish render",
		)
		gfx.ez_gfx_ctx_wait_idle()
	}

	testing.expect_value(t, app.ctx.structured_buffer_manager.count, 1)
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

@(test)
structured_buffer_pool_trims_oversized_idle_buffers :: proc(t: ^testing.T) {
	app: Triangle_App
	context.user_ptr = &app.ctx
	if !testing.expect(
		t,
		triangle_init_app(&app),
		"structured buffer trim test failed during init",
	) {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	large_element_count := u32(1 << 20)
	small_element_count := u32(16)

	if !testing.expect(
		t,
		gfx.ez_gfx_begin_render(&app.window) == .Ok,
		"structured buffer trim test failed to begin large-buffer render",
	) {
		return
	}
	large_handle, large_status := gfx.ez_gfx_render_acquire_structured_buffer(u8, large_element_count, "large_buffer")
	if !testing.expect(t, large_status == .Ok, "structured buffer trim test failed to acquire large buffer") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	if !testing.expect(
		t,
		gfx.ez_gfx_finish_render() == .Ok,
		"structured buffer trim test failed to finish large-buffer render",
	) {
		return
	}
	gfx.ez_gfx_ctx_wait_idle()
	testing.expect_value(t, app.ctx.structured_buffer_manager.count, 1)

	for frame in 0 ..< 2 {
		if !testing.expect(
			t,
			gfx.ez_gfx_begin_render(&app.window) == .Ok,
			"structured buffer trim test failed to begin small-buffer render",
		) {
			return
		}
		small_handle, small_status := gfx.ez_gfx_render_acquire_structured_buffer(u32, small_element_count, "small_buffer")
		if !testing.expect(
			t,
			small_status == .Ok,
			"structured buffer trim test failed to acquire small buffer",
		) {
			_ = gfx.ez_gfx_finish_render()
			return
		}
		small_handle.elements[0] = u32(frame)
		if !testing.expect(
			t,
			gfx.ez_gfx_finish_render() == .Ok,
			"structured buffer trim test failed to finish small-buffer render",
		) {
			return
		}
		gfx.ez_gfx_ctx_wait_idle()
	}

	testing.expect_value(t, app.ctx.structured_buffer_manager.count, 1)
	if app.ctx.structured_buffer_manager.count == 1 {
		testing.expect_value(t, app.ctx.structured_buffer_manager.buffers[0].capacity, vk.DeviceSize(small_element_count * size_of(u32)))
	}
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

@(test)
explicit_structured_buffer_reuses_one_handle_across_pipelines :: proc(t: ^testing.T) {
	app: Triangle_App
	context.user_ptr = &app.ctx
	if !testing.expect(t, triangle_init_app(&app), "structured reuse test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	graphics_shader, graphics_ok := triangle_compile_graphics_structured_shader()
	if !testing.expect(t, graphics_ok, "failed to compile graphics structured shader") do return
	defer gfx.ez_gfx_shader_destroy(&graphics_shader)
	compute_shader, compute_ok := triangle_compile_compute_structured_shader()
	if !testing.expect(t, compute_ok, "failed to compile compute structured shader") do return
	defer gfx.ez_gfx_shader_destroy(&compute_shader)

	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window) == .Ok, "structured reuse test failed to begin render") {
		return
	}
	colors, colors_status := gfx.ez_gfx_render_acquire_structured_buffer([4]f32, u32(len(TRIANGLE_COLORS)), "triangle colors")
	if !testing.expect(t, colors_status == .Ok, "failed to acquire structured colors") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	for color, i in TRIANGLE_COLORS {
		colors.elements[i] = color
	}

	indirect := triangle_acquire_and_fill_indirect(&app)
	if !testing.expect(t, indirect.ok, "failed to acquire indirect draw buffer") {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	compute_bindings := [?]gfx.Ez_Gfx_Render_Binding{{name = "instances", structured = colors.handle}}
	_, compute_status := gfx.ez_gfx_render_add_compute_pipeline(&compute_shader, 1, 1, 1, compute_bindings[:])
	if !testing.expect(t, compute_status == .Ok, "compute pipeline should accept reused structured handle") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	graphics_bindings := [?]gfx.Ez_Gfx_Render_Binding{{name = "colors", structured = colors.handle}}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline(&graphics_shader, indirect, graphics_bindings[:])
	if !testing.expect(t, pipeline_status == .Ok, "graphics pipeline should accept reused structured handle") {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	testing.expect(t, gfx.ez_gfx_finish_render() == .Ok, "structured reuse render should submit")
	gfx.ez_gfx_ctx_wait_idle()
	testing.expect_value(t, app.ctx.structured_buffer_manager.count, 1)
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

@(test)
explicit_structured_binding_is_required_per_pipeline :: proc(t: ^testing.T) {
	app: Triangle_App
	context.user_ptr = &app.ctx
	if !testing.expect(t, triangle_init_app(&app), "missing binding test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	shader, shader_ok := triangle_compile_graphics_structured_shader()
	if !testing.expect(t, shader_ok, "failed to compile graphics structured shader") do return
	defer gfx.ez_gfx_shader_destroy(&shader)

	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window) == .Ok, "missing binding test failed to begin render") {
		return
	}
	indirect := triangle_acquire_and_fill_indirect(&app)
	if !testing.expect(t, indirect.ok, "failed to acquire indirect draw buffer") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline(&shader, indirect, nil)
	testing.expect_value(t, pipeline_status, gfx.Ez_Gfx_Status.Native_Failure)
	_ = gfx.ez_gfx_finish_render()
}

@(test)
stale_structured_handle_fails_submit_validation :: proc(t: ^testing.T) {
	app: Triangle_App
	context.user_ptr = &app.ctx
	if !testing.expect(t, triangle_init_app(&app), "stale handle test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	shader, shader_ok := triangle_compile_graphics_structured_shader()
	if !testing.expect(t, shader_ok, "failed to compile graphics structured shader") do return
	defer gfx.ez_gfx_shader_destroy(&shader)

	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window) == .Ok, "stale handle setup failed to begin render") {
		return
	}
	stale, stale_status := gfx.ez_gfx_render_acquire_structured_buffer(u32, 16, "stale colors")
	if !testing.expect(t, stale_status == .Ok, "failed to acquire stale structured handle") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	if !testing.expect(t, gfx.ez_gfx_finish_render() == .Ok, "stale handle setup failed to finish") {
		return
	}
	gfx.ez_gfx_ctx_wait_idle()

	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window) == .Ok, "stale handle test failed to begin render") {
		return
	}
	indirect := triangle_acquire_and_fill_indirect(&app)
	bindings := [?]gfx.Ez_Gfx_Render_Binding{{name = "colors", structured = stale.handle}}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline(&shader, indirect, bindings[:])
	if !testing.expect(t, pipeline_status == .Ok, "stale handle should be caught at submit validation") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	testing.expect(t, gfx.ez_gfx_finish_render() != .Ok, "stale structured handle unexpectedly submitted")
}

@(test)
stale_indirect_handle_cannot_mutate_new_render_frame :: proc(t: ^testing.T) {
	app: Triangle_App
	context.user_ptr = &app.ctx
	if !testing.expect(t, triangle_init_app(&app), "stale indirect test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window) == .Ok, "stale indirect setup failed to begin render") {
		return
	}
	indirect := triangle_acquire_and_fill_indirect(&app)
	if !testing.expect(t, indirect.ok, "failed to acquire initial indirect buffer") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	structured, structured_status := gfx.ez_gfx_render_acquire_structured_buffer(u32, 1, "stale structured")
	if !testing.expect(t, structured_status == .Ok, "failed to acquire initial structured buffer") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	structured.elements[0] = 1
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline(&app.shader, indirect, nil)
	if !testing.expect(t, pipeline_status == .Ok, "failed to add initial indirect pipeline") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	if !testing.expect(t, gfx.ez_gfx_finish_render() == .Ok, "stale indirect setup failed to finish") {
		return
	}
	gfx.ez_gfx_ctx_wait_idle()

	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window) == .Ok, "stale indirect test failed to begin next frame") {
		return
	}
	defer gfx.ez_gfx_finish_render()
	draw := vk.DrawIndexedIndirectCommand{
		indexCount = app.triangle_index_len,
		instanceCount = 1,
		firstIndex = app.triangle_index,
		vertexOffset = i32(app.triangle_vertex),
		firstInstance = 0,
	}
	testing.expect_value(
		t,
		gfx.ez_gfx_indirect_buffer_write_draw(&indirect, 0, draw),
		gfx.Ez_Gfx_Status.Invalid_Argument,
	)
	testing.expect_value(
		t,
		gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, 1),
		gfx.Ez_Gfx_Status.Invalid_Argument,
	)
	stale_value := u32(1)
	testing.expect_value(
		t,
		gfx.ez_gfx_structured_buffer_write(
			&structured.handle,
			rawptr(&stale_value),
			u64(size_of(u32)),
		),
		gfx.Ez_Gfx_Status.Invalid_Argument,
	)
}

@(test)
structured_size_mismatch_fails_submit_validation :: proc(t: ^testing.T) {
	app: Triangle_App
	context.user_ptr = &app.ctx
	if !testing.expect(t, triangle_init_app(&app), "size mismatch test failed during init") {
		triangle_cleanup(&app)
		return
	}
	defer triangle_cleanup(&app)

	shader, shader_ok := triangle_compile_graphics_structured_shader()
	if !testing.expect(t, shader_ok, "failed to compile graphics structured shader") do return
	defer gfx.ez_gfx_shader_destroy(&shader)

	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window) == .Ok, "size mismatch test failed to begin render") {
		return
	}
	colors, colors_status := gfx.ez_gfx_render_acquire_structured_buffer(u32, 16, "size mismatch colors")
	if !testing.expect(t, colors_status == .Ok, "failed to acquire structured colors") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	indirect := triangle_acquire_and_fill_indirect(&app)
	bindings := [?]gfx.Ez_Gfx_Render_Binding{{name = "colors", structured = colors.handle}}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline(&shader, indirect, bindings[:])
	if !testing.expect(t, pipeline_status == .Ok, "size mismatch pipeline failed before validation") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	colors.handle.buffer.size = 32
	testing.expect(t, gfx.ez_gfx_finish_render() != .Ok, "structured size mismatch unexpectedly submitted")
	colors.handle.buffer.size = colors.handle.size
}

triangle_compile_graphics_structured_shader :: proc() -> (
	shader: gfx.Ez_Gfx_Shader_Program,
	ok: bool,
) {
	ok = gfx.ez_gfx_shader_compile(
		{
			path = GRAPHICS_STRUCTURED_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},
		&shader,
	) == .Ok
	return shader, ok
}

triangle_compile_compute_structured_shader :: proc() -> (
	shader: gfx.Ez_Gfx_Shader_Program,
	ok: bool,
) {
	ok = gfx.ez_gfx_shader_compile(
		{
			path = COMPUTE_STRUCTURED_SHADER_PATH,
			compute_entry = gfx.EZ_GFX_DEFAULT_COMPUTE_ENTRY,
			kind = .Compute,
		},
		&shader,
	) == .Ok
	return shader, ok
}

triangle_acquire_and_fill_indirect :: proc(
	app: ^Triangle_App,
) -> gfx.Ez_Gfx_Indirect_Buffer_Handle {
	indirect, status := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		1,
		"triangle test draw commands",
	)
	if status != .Ok {
		indirect.ok = false
		return indirect
	}
	draw := vk.DrawIndexedIndirectCommand {
		indexCount    = app.triangle_index_len,
		instanceCount = 1,
		firstIndex    = app.triangle_index,
		vertexOffset  = i32(app.triangle_vertex),
		firstInstance = 0,
	}
	if gfx.ez_gfx_indirect_buffer_write_draw(&indirect, 0, draw) != .Ok {
		indirect.ok = false
		return indirect
	}
	if gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, 1) != .Ok {
		indirect.ok = false
	}
	return indirect
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

vertex_upload_callback :: proc(
	ctx: ^gfx.Ez_Gfx_Ctx,
	kind: gfx.Ez_Gfx_Vertex_Upload_Kind,
	heap_name: string,
	allocation: gfx.Ez_Gfx_Vertex_Allocation,
	err: gfx.Ez_Gfx_Vertex_Upload_Error,
	user_data: rawptr,
) {
	_ = ctx
	_ = kind
	_ = heap_name
	_ = allocation
	app := cast(^Triangle_App)user_data
	if app == nil do return
	intrinsics.atomic_add_explicit(&app.vertex_upload_callbacks, u64(1), .Seq_Cst)
	if err != .None {
		intrinsics.atomic_add_explicit(&app.vertex_upload_errors, u64(1), .Seq_Cst)
	}
}

triangle_init_app :: proc(app: ^Triangle_App) -> bool {
	if !shared.example_glfw_init() do return false

	context.user_ptr = &app.ctx
	if !shared.example_window_create(&app.window,
		"ez_gfx_api triangle",
		WIDTH,
		HEIGHT) {
		return false
	}
	if gfx.ez_gfx_ctx_create_instance(&app.ctx,
		{
			enable_validation = true,
			validation_callback = validation_callback,
			validation_user_data = &app.validation_log,
			vertex_uploaded_callback = vertex_upload_callback,
			vertex_uploaded_user_data = app,
			enable_debug = true,
		},) != .Ok {
		return false
	}
	if gfx.ez_gfx_window_create_surface(&app.window) != .Ok do return false
	if gfx.ez_gfx_ctx_init_device(app.window.surface) != .Ok do return false
	if gfx.ez_gfx_window_recreate_swapchain(&app.window, app.window.framebuffer_width, app.window.framebuffer_height) != .Ok do return false
	return triangle_init_resources(app)
}

triangle_init_resources :: proc(app: ^Triangle_App) -> bool {
	if gfx.ez_gfx_shader_compile({
			path = TRIANGLE_SHADER_PATH,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		},
		&app.shader,) != .Ok {
		return false
	}
	app.shader_loaded = true

	vertex_heap_names := [?]string{TRIANGLE_POSITION_HEAP}
	if gfx.ez_gfx_vertex_manager_create(
		&app.ctx.vertex_manager,
		vertex_heap_names[:],
		vk.DeviceSize(size_of(TRIANGLE_POSITIONS[0])),
	) != .Ok {
		return false
	}

	index_start, index_status := gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		TRIANGLE_INDICES[:],
	)
	if index_status != .Ok do return false
	app.triangle_index = index_start
	app.triangle_index_len = u32(len(TRIANGLE_INDICES))
	vertex_start, vertex_status := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		TRIANGLE_POSITION_HEAP,
		TRIANGLE_POSITIONS[:],
	)
	if vertex_status != .Ok do return false
	app.triangle_vertex = vertex_start
	return true
}

triangle_run_frames :: proc(app: ^Triangle_App) -> bool {
	frames_drawn := 0
	attempts := 0
	target_frames := max(TRIANGLE_FRAMES, int(app.window.swapchain.image_count) + 1)
	for frames_drawn < target_frames && attempts < 60 {
		attempts += 1
		shared.example_window_poll_events(&app.window)
		if shared.example_window_should_close(&app.window) do return false
		if triangle_draw_frame(app) {
			frames_drawn += 1
		}
	}
	return frames_drawn == target_frames
}

triangle_draw_frame :: proc(app: ^Triangle_App) -> bool {
	if gfx.ez_gfx_begin_render(&app.window) != .Ok do return false

	indirect, indirect_status := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		1,
		"triangle draw commands",
	)
	if indirect_status != .Ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shader,
		indirect,
		nil,
	)
	if pipeline_status != .Ok {
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
	if gfx.ez_gfx_indirect_buffer_write_draw(&indirect, 0, draw) != .Ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}
	if gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, 1) != .Ok {
		_ = gfx.ez_gfx_finish_render()
		return false
	}

	return gfx.ez_gfx_finish_render() == .Ok
}

triangle_cleanup :: proc(app: ^Triangle_App) {
	context.user_ptr = &app.ctx
	if app.shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.shader)
		app.shader_loaded = false
	}
	shared.example_window_destroy(&app.window)
	gfx.ez_gfx_ctx_destroy()
	shared.example_glfw_terminate()
}
