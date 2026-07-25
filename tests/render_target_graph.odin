#+private
package tests

import shared "../examples/shared"
import gfx "../src"
import "core:testing"
import vk "vendor:vulkan"

GRAPH_SHADER_CAPACITY :: 4

Render_Target_Graph_App :: struct {
	ctx:                gfx.Ez_Gfx_Context_Handle,
	window:             shared.Example_Window,
	shaders:            [GRAPH_SHADER_CAPACITY]gfx.Ez_Gfx_Shader_Handle,
	shader_loaded:      [GRAPH_SHADER_CAPACITY]bool,
	shader_count:       int,
	triangle_index:     u32,
	triangle_index_len: u32,
	triangle_vertex:    u32,
	validation_log:     Validation_Log,
}

@(test)
render_target_fork_join_synchronizes_without_validation_errors :: proc(t: ^testing.T) {
	shader_paths := [?]cstring {
		"tests/rt_producer.slang",
		"tests/rt_fork_a.slang",
		"tests/rt_fork_b.slang",
		"tests/rt_join.slang",
	}
	app: Render_Target_Graph_App
		if !testing.expect(
		t,
		render_target_graph_init_app(&app, "ez_gfx_api fork join", shader_paths[:]),
	) {
		render_target_graph_cleanup(&app)
		return
	}
	defer render_target_graph_cleanup(&app)

	if !testing.expect(t, render_target_graph_run_frame(&app, 0, len(shader_paths))) {
		return
	}

	gfx.ez_gfx_context_wait_idle(app.ctx)
	testing.expect_value(t, app.validation_log.errors, u32(0))
}

@(test)
load_target_preserves_previous_frame_without_validation_errors :: proc(t: ^testing.T) {
	shader_paths := [?]cstring{"tests/rt_history_write.slang", "tests/rt_history_read.slang"}
	app: Render_Target_Graph_App
		if !testing.expect(
		t,
		render_target_graph_init_app(&app, "ez_gfx_api load target", shader_paths[:]),
	) {
		render_target_graph_cleanup(&app)
		return
	}
	defer render_target_graph_cleanup(&app)

	if !testing.expect(t, render_target_graph_run_frame(&app, 0, 1)) {
		return
	}
	if !testing.expect(t, render_target_graph_run_snapshot_frames(&app, 1, 1)) {
		return
	}

	gfx.ez_gfx_context_wait_idle(app.ctx)
	expect_window_snapshot(t, &app.window, "load_target_history")
	testing.expect_value(t, app.validation_log.errors, u32(0))
}

@(test)
managed_rwtexture_store_load_matches_snapshot :: proc(t: ^testing.T) {
	shader_paths := [?]cstring{"tests/rt_storage_write.slang", "tests/rt_storage_read.slang"}
	app: Render_Target_Graph_App
		if !testing.expect(
		t,
		render_target_graph_init_app(&app, "ez_gfx_api managed rwtexture", shader_paths[:]),
	) {
		render_target_graph_cleanup(&app)
		return
	}
	defer render_target_graph_cleanup(&app)

	if !testing.expect(t, render_target_graph_run_snapshot_frames(&app, 0, len(shader_paths))) {
		return
	}

	gfx.ez_gfx_context_wait_idle(app.ctx)
	expect_window_snapshot(t, &app.window, "managed_rwtexture_store_load")
	testing.expect_value(t, app.validation_log.errors, u32(0))
}

@(test)
described_render_target_binds_explicit_id_per_pipeline :: proc(t: ^testing.T) {
	shader_paths := [?]cstring{"tests/rt_producer.slang", "tests/rt_fork_a.slang"}
	app: Render_Target_Graph_App
		if !testing.expect(
		t,
		render_target_graph_init_app(&app, "ez_gfx_api explicit target", shader_paths[:]),
	) {
		render_target_graph_cleanup(&app)
		return
	}
	defer render_target_graph_cleanup(&app)

	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "explicit target test failed to begin render") {
		return
	}
	explicit_width := u32(WIDTH / 2)
	explicit_height := u32(HEIGHT / 2)
	source_handle, source_status := gfx.ez_gfx_render_target_describe_handle(
		app.ctx,
		explicit_width,
		explicit_height,
		"explicit source target",
	)
	if !testing.expect(t, source_status == .Ok, "render target describe failed") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	source_bindings := [?]gfx.Ez_Gfx_Public_Render_Binding{{name = "source", render_target = source_handle}}
	if !testing.expect(t, render_target_graph_add_pipeline(&app, 0, source_bindings[:]), "explicit target producer failed") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	if !testing.expect(t, render_target_graph_add_pipeline(&app, 1, source_bindings[:]), "explicit target consumer failed") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	if !testing.expect(t, gfx.ez_gfx_finish_render_context(app.ctx) == .Ok, "explicit target render failed to submit") {
		return
	}
	gfx.ez_gfx_context_wait_idle(app.ctx)
	testing.expect_value(t, app.validation_log.errors, u32(0))
}

@(test)
render_target_describe_requires_context :: proc(t: ^testing.T) {
	_, status := gfx.ez_gfx_render_target_describe_handle(0, 64, 64, "offscreen")
	testing.expect_value(t, status, gfx.Ez_Gfx_Status.Invalid_Context)
}

@(test)
render_target_describe_rejects_zero_size :: proc(t: ^testing.T) {
	app: Render_Target_Graph_App
		if !testing.expect(
		t,
		render_target_describe_init_ctx(&app),
		"zero-size describe test failed during init",
	) {
		render_target_describe_cleanup(&app)
		return
	}
	defer render_target_describe_cleanup(&app)

	_, zero_width_status := gfx.ez_gfx_render_target_describe_handle(app.ctx, 0, 64, "offscreen")
	_, zero_height_status := gfx.ez_gfx_render_target_describe_handle(app.ctx, 64, 0, "offscreen")
	testing.expect_value(t, zero_width_status, gfx.Ez_Gfx_Status.Invalid_Argument)
	testing.expect_value(t, zero_height_status, gfx.Ez_Gfx_Status.Invalid_Argument)
}

@(test)
render_target_describe_reuses_id_for_same_label_and_size :: proc(t: ^testing.T) {
	app: Render_Target_Graph_App
		if !testing.expect(
		t,
		render_target_describe_init_ctx(&app),
		"reuse describe test failed during init",
	) {
		render_target_describe_cleanup(&app)
		return
	}
	defer render_target_describe_cleanup(&app)

	first, first_status := gfx.ez_gfx_render_target_describe_handle(app.ctx, 320, 240, "shared offscreen")
	second, second_status := gfx.ez_gfx_render_target_describe_handle(app.ctx, 320, 240, "shared offscreen")
	if !testing.expect(t, first_status == .Ok && second_status == .Ok, "describe should succeed for valid labels") {
		return
	}
	testing.expect(t, first != 0 && second != 0, "public render-target handles must be nonzero")
}

@(test)
render_target_describe_bumps_generation_when_size_changes :: proc(t: ^testing.T) {
	app: Render_Target_Graph_App
		if !testing.expect(
		t,
		render_target_describe_init_ctx(&app),
		"resize describe test failed during init",
	) {
		render_target_describe_cleanup(&app)
		return
	}
	defer render_target_describe_cleanup(&app)

	first, first_status := gfx.ez_gfx_render_target_describe_handle(app.ctx, 320, 240, "resizable offscreen")
	if !testing.expect(t, first_status == .Ok, "initial describe failed") do return
	resized, resized_status := gfx.ez_gfx_render_target_describe_handle(app.ctx, 640, 480, "resizable offscreen")
	if !testing.expect(t, resized_status == .Ok, "resized describe failed") do return
	testing.expect(t, resized != first, "each public render-target allocation must have a distinct identity")
}

@(test)
render_target_describe_stale_id_fails_pipeline_bind :: proc(t: ^testing.T) {
	shader_paths := [?]cstring{"tests/rt_producer.slang"}
	app: Render_Target_Graph_App
		if !testing.expect(
		t,
		render_target_graph_init_app(&app, "ez_gfx_api stale target id", shader_paths[:]),
	) {
		render_target_graph_cleanup(&app)
		return
	}
	defer render_target_graph_cleanup(&app)

	stale_id, stale_status := gfx.ez_gfx_render_target_describe_handle(app.ctx, 320, 240, "stale source target")
	if !testing.expect(t, stale_status == .Ok, "initial describe failed") do return
	if !testing.expect(t, gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) == .Ok, "stale id test failed to begin render") {
		return
	}
	_, resize_status := gfx.ez_gfx_render_target_describe_handle(app.ctx, 640, 480, "stale source target")
	if !testing.expect(t, resize_status == .Ok, "render target resize describe failed") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	bindings := [?]gfx.Ez_Gfx_Public_Render_Binding{{name = "source", render_target = stale_id}}
	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(app.ctx, 1, "stale id draw")
	if !testing.expect(t, indirect_status == .Ok, "stale id indirect acquisition failed") {
		_ = gfx.ez_gfx_finish_render_context(app.ctx)
		return
	}
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(app.ctx, app.shaders[0], indirect, bindings[:])
	testing.expect_value(t, pipeline_status, gfx.Ez_Gfx_Status.Native_Failure)
	_ = gfx.ez_gfx_finish_render_context(app.ctx)
	_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
	gfx.ez_gfx_context_wait_idle(app.ctx)
}

render_target_describe_init_ctx :: proc(app: ^Render_Target_Graph_App) -> bool {
	if !shared.example_glfw_init() do return false
	ctx, ctx_status := gfx.ez_gfx_context_create({
		enable_validation = true,
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	})
	if ctx_status != .Ok do return false
	app.ctx = ctx
	if !shared.example_window_create(&app.window, app.ctx, "ez_gfx_api render target describe", WIDTH, HEIGHT) do return false
	if gfx.ez_gfx_surface_init_device(app.ctx, app.window.surface) != .Ok do return false
	return gfx.ez_gfx_surface_resize(app.ctx, app.window.surface, u32(WIDTH), u32(HEIGHT)) == .Ok
}

render_target_describe_cleanup :: proc(app: ^Render_Target_Graph_App) {
	shared.example_window_destroy(&app.window)
	if app.ctx != 0 do _ = gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}

render_target_graph_init_app :: proc(
	app: ^Render_Target_Graph_App,
	title: string,
	shader_paths: []cstring,
) -> bool {
	if len(shader_paths) > GRAPH_SHADER_CAPACITY do return false
	if !shared.example_glfw_init() do return false
	ctx, ctx_status := gfx.ez_gfx_context_create({
		enable_validation = true,
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	})
	if ctx_status != .Ok do return false
	app.ctx = ctx
	if !shared.example_window_create(&app.window, app.ctx, title, WIDTH, HEIGHT) do return false
	if gfx.ez_gfx_surface_init_device(app.ctx, app.window.surface) != .Ok do return false
	if gfx.ez_gfx_surface_resize(app.ctx, app.window.surface, u32(app.window.framebuffer_width), u32(app.window.framebuffer_height)) != .Ok do return false
	if !render_target_graph_init_shaders(app, shader_paths) do return false
	return render_target_graph_init_vertices(app)
}

render_target_graph_init_shaders :: proc(
	app: ^Render_Target_Graph_App,
	shader_paths: []cstring,
) -> bool {
	for path, i in shader_paths {
		shader, shader_status := gfx.ez_gfx_shader_create(app.ctx, {
			path = path,
			vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
			fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
		})
		if shader_status != .Ok do return false
		app.shaders[i] = shader
		app.shader_loaded[i] = true
		app.shader_count += 1
	}
	return true
}

render_target_graph_init_vertices :: proc(app: ^Render_Target_Graph_App) -> bool {
	if gfx.ez_gfx_index_heap_create(app.ctx, gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES, "render target index heap") != .Ok do return false
	if gfx.ez_gfx_vertex_heap_create(app.ctx, TRIANGLE_POSITION_HEAP, gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES, vk.DeviceSize(size_of(TRIANGLE_POSITIONS[0]))) != .Ok do return false
	index_start, index_status := gfx.ez_gfx_vertex_upload_indices(app.ctx, TRIANGLE_INDICES[:])
	app.triangle_index = index_start
	if index_status != .Ok do return false
	app.triangle_index_len = u32(len(TRIANGLE_INDICES))
	vertex_start, vertex_status := gfx.ez_gfx_vertex_upload(app.ctx, TRIANGLE_POSITION_HEAP, TRIANGLE_POSITIONS[:])
	app.triangle_vertex = vertex_start
	if vertex_status != .Ok do return false
	return true
}

render_target_graph_run_frame :: proc(
	app: ^Render_Target_Graph_App,
	shader_start: int,
	shader_count: int,
) -> bool {
	attempts := 0
	for attempts < 60 {
		attempts += 1
		shared.example_window_poll_events(&app.window)
		if shared.example_window_should_close(&app.window) do return false
		if render_target_graph_draw_frame(app, shader_start, shader_count) do return true
	}
	return false
}

render_target_graph_run_snapshot_frames :: proc(
	app: ^Render_Target_Graph_App,
	shader_start: int,
	shader_count: int,
) -> bool {
	frames_drawn := 0
	for frames_drawn < 2 {
		if !render_target_graph_run_frame(app, shader_start, shader_count) do return false
		frames_drawn += 1
	}
	return true
}

render_target_graph_draw_frame :: proc(
	app: ^Render_Target_Graph_App,
	shader_start: int,
	shader_count: int,
) -> bool {
	if gfx.ez_gfx_begin_render_surface(app.ctx, app.window.surface) != .Ok do return false
	for shader_index in shader_start ..< shader_start + shader_count {
		if !render_target_graph_add_pipeline(app, shader_index, nil) {
			_ = gfx.ez_gfx_finish_render_context(app.ctx)
			return false
		}
	}
	return gfx.ez_gfx_finish_render_context(app.ctx) == .Ok
}

render_target_graph_add_pipeline :: proc(
	app: ^Render_Target_Graph_App,
	shader_index: int,
	bindings: []gfx.Ez_Gfx_Public_Render_Binding,
) -> bool {
	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(app.ctx, 1, "render target graph draw commands")
	if indirect_status != .Ok do return false
	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(app.ctx, app.shaders[shader_index], indirect, bindings)
	if pipeline_status != .Ok {
		_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
		return false
	}
	draw := gfx.Ez_Gfx_Draw_Indexed_Command{index_count = app.triangle_index_len, instance_count = 1, first_index = app.triangle_index, vertex_offset = i32(app.triangle_vertex)}
	if gfx.ez_gfx_indirect_write_draw(app.ctx, indirect, 0, draw) != .Ok {
		_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
		return false
	}
	if gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, 1) != .Ok {
		_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
		return false
	}
	_ = gfx.ez_gfx_indirect_release(app.ctx, indirect)
	return true
}

render_target_graph_cleanup :: proc(app: ^Render_Target_Graph_App) {
		for i in 0 ..< app.shader_count {
		if app.shader_loaded[i] {
			gfx.ez_gfx_shader_release(app.ctx, app.shaders[i])
			app.shader_loaded[i] = false
		}
	}
	shared.example_window_destroy(&app.window)
	gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}
