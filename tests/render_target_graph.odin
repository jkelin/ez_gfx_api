package tests

import shared "../examples/shared"
import gfx "../src"
import "core:testing"
import vk "vendor:vulkan"

GRAPH_SHADER_CAPACITY :: 4

Render_Target_Graph_App :: struct {
	ctx:                gfx.Ez_Gfx_Ctx,
	window:             gfx.Ez_Gfx_Window,
	shaders:            [GRAPH_SHADER_CAPACITY]gfx.Ez_Gfx_Shader_Program,
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

	gfx.ez_gfx_ctx_wait_idle()
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
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

	gfx.ez_gfx_ctx_wait_idle()
	expect_window_snapshot(t, &app.window, "load_target_history")
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
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

	gfx.ez_gfx_ctx_wait_idle()
	expect_window_snapshot(t, &app.window, "managed_rwtexture_store_load")
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
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

	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window), "explicit target test failed to begin render") {
		return
	}
	explicit_width := u32(WIDTH / 2)
	explicit_height := u32(HEIGHT / 2)
	source_id := gfx.ez_gfx_render_target_describe(
		explicit_width,
		explicit_height,
		"explicit source target",
	)
	if !testing.expect(t, source_id.ok, "render target describe failed") {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	source_bindings := [?]gfx.Ez_Gfx_Render_Binding{{name = "source", render_target = source_id}}
	if !testing.expect(
		t,
		render_target_graph_add_pipeline(&app, 0, source_bindings[:]),
		"explicit target producer failed",
	) {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	if !testing.expect(
		t,
		render_target_graph_add_pipeline(&app, 1, source_bindings[:]),
		"explicit target consumer failed",
	) {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	if !testing.expect(t, gfx.ez_gfx_finish_render(), "explicit target render failed to submit") {
		return
	}
	gfx.ez_gfx_ctx_wait_idle()

	target := app.ctx.render_target_manager.targets[source_id.index]
	testing.expect_value(t, target.extent.width, explicit_width)
	testing.expect_value(t, target.extent.height, explicit_height)
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

@(test)
render_target_describe_requires_context :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!gfx.ez_gfx_render_target_describe(64, 64, "offscreen").ok,
		"describe should require a current context",
	)
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

	testing.expect(t, !gfx.ez_gfx_render_target_describe(0, 64, "offscreen").ok)
	testing.expect(t, !gfx.ez_gfx_render_target_describe(64, 0, "offscreen").ok)
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

	first := gfx.ez_gfx_render_target_describe(320, 240, "shared offscreen")
	second := gfx.ez_gfx_render_target_describe(320, 240, "shared offscreen")
	if !testing.expect(t, first.ok && second.ok, "describe should succeed for valid labels") {
		return
	}
	testing.expect_value(t, second.index, first.index)
	testing.expect_value(t, second.generation, first.generation)
	testing.expect_value(t, app.ctx.render_target_manager.count, 1)
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

	first := gfx.ez_gfx_render_target_describe(320, 240, "resizable offscreen")
	if !testing.expect(t, first.ok, "initial describe failed") do return
	resized := gfx.ez_gfx_render_target_describe(640, 480, "resizable offscreen")
	if !testing.expect(t, resized.ok, "resized describe failed") do return

	testing.expect_value(t, resized.index, first.index)
	testing.expect(t, resized.generation > first.generation, "size change should bump generation")
	target := app.ctx.render_target_manager.targets[resized.index]
	testing.expect_value(t, target.extent.width, u32(640))
	testing.expect_value(t, target.extent.height, u32(480))
	testing.expect(t, !target.has_image, "resized describe should defer image creation until bind")
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

	stale_id := gfx.ez_gfx_render_target_describe(320, 240, "stale source target")
	if !testing.expect(t, stale_id.ok, "initial describe failed") do return
	if !testing.expect(t, gfx.ez_gfx_begin_render(&app.window), "stale id test failed to begin render") {
		return
	}
	_ = gfx.ez_gfx_render_target_describe(640, 480, "stale source target")
	bindings := [?]gfx.Ez_Gfx_Render_Binding{{name = "source", render_target = stale_id}}
	pipeline := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shaders[0],
		gfx.ez_gfx_render_acquire_indirect_buffer(vk.DrawIndexedIndirectCommand, 1, "stale id draw"),
		bindings[:],
	)
	testing.expect(t, !pipeline.ok, "stale render target id should fail pipeline bind")
	_ = gfx.ez_gfx_finish_render()
	gfx.ez_gfx_ctx_wait_idle()
}

render_target_describe_init_ctx :: proc(app: ^Render_Target_Graph_App) -> bool {
	if !shared.example_glfw_init() do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	if !shared.example_window_create(&app.window,
		"ez_gfx_api render target describe",
		WIDTH,
		HEIGHT) {
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
	return gfx.ez_gfx_ctx_init_device(app.window.surface)
}

render_target_describe_cleanup :: proc(app: ^Render_Target_Graph_App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	shared.example_window_destroy(&app.window)
	gfx.ez_gfx_ctx_destroy()
	shared.example_glfw_terminate()
}

render_target_graph_init_app :: proc(
	app: ^Render_Target_Graph_App,
	title: string,
	shader_paths: []cstring,
) -> bool {
	if len(shader_paths) > GRAPH_SHADER_CAPACITY {
		return false
	}
	if !shared.example_glfw_init() do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	if !shared.example_window_create(&app.window, title, WIDTH, HEIGHT) {
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
	if !gfx.ez_gfx_window_recreate_swapchain(&app.window, app.window.framebuffer_width, app.window.framebuffer_height) do return false
	if !render_target_graph_init_shaders(app, shader_paths) do return false
	return render_target_graph_init_vertices(app)
}

render_target_graph_init_shaders :: proc(
	app: ^Render_Target_Graph_App,
	shader_paths: []cstring,
) -> bool {
	for path, i in shader_paths {
		if !gfx.ez_gfx_shader_compile(
			{
				path = path,
				vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
				fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
			},
			&app.shaders[i],
		) {
			return false
		}
		app.shader_loaded[i] = true
		app.shader_count += 1
	}
	return true
}

render_target_graph_init_vertices :: proc(app: ^Render_Target_Graph_App) -> bool {
	vertex_heap_names := [?]string{TRIANGLE_POSITION_HEAP}
	gfx.ez_gfx_vertex_manager_create(
		&app.ctx.vertex_manager,
		vertex_heap_names[:],
		vk.DeviceSize(size_of(TRIANGLE_POSITIONS[0])),
	)

	app.triangle_index = gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		TRIANGLE_INDICES[:],
	)
	app.triangle_index_len = u32(len(TRIANGLE_INDICES))
	app.triangle_vertex = gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		TRIANGLE_POSITION_HEAP,
		TRIANGLE_POSITIONS[:],
	)
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
		if render_target_graph_draw_frame(app, shader_start, shader_count) {
			return true
		}
	}
	return false
}

render_target_graph_run_snapshot_frames :: proc(
	app: ^Render_Target_Graph_App,
	shader_start: int,
	shader_count: int,
) -> bool {
	frames_drawn := 0
	target_frames := max(1, int(app.window.swapchain.image_count) + 1)
	for frames_drawn < target_frames {
		if !render_target_graph_run_frame(app, shader_start, shader_count) {
			return false
		}
		frames_drawn += 1
	}
	return true
}

render_target_graph_draw_frame :: proc(
	app: ^Render_Target_Graph_App,
	shader_start: int,
	shader_count: int,
) -> bool {
	if !gfx.ez_gfx_begin_render(&app.window) do return false

	for shader_index in shader_start ..< shader_start + shader_count {
		if !render_target_graph_add_pipeline(app, shader_index, nil) {
			_ = gfx.ez_gfx_finish_render()
			return false
		}
	}

	return gfx.ez_gfx_finish_render()
}

render_target_graph_add_pipeline :: proc(
	app: ^Render_Target_Graph_App,
	shader_index: int,
	bindings: []gfx.Ez_Gfx_Render_Binding,
) -> bool {
	indirect := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		1,
		"render target graph draw commands",
	)
	if !indirect.ok do return false

	pipeline := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shaders[shader_index],
		indirect,
		bindings,
	)
	if !pipeline.ok do return false

	draw := vk.DrawIndexedIndirectCommand {
		indexCount    = app.triangle_index_len,
		instanceCount = 1,
		firstIndex    = app.triangle_index,
		vertexOffset  = i32(app.triangle_vertex),
		firstInstance = 0,
	}
	if !gfx.ez_gfx_indirect_buffer_write_draw(&indirect, 0, draw) {
		return false
	}
	if !gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, 1) {
		return false
	}
	return true
}

render_target_graph_cleanup :: proc(app: ^Render_Target_Graph_App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	for i in 0 ..< app.shader_count {
		if app.shader_loaded[i] {
			gfx.ez_gfx_shader_destroy(&app.shaders[i])
			app.shader_loaded[i] = false
		}
	}
	shared.example_window_destroy(&app.window)
	gfx.ez_gfx_ctx_destroy()
	shared.example_glfw_terminate()
}
