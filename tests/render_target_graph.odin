package tests

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
		render_target_graph_init_app(&app, cstring("ez_gfx_api fork join"), shader_paths[:]),
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
		render_target_graph_init_app(&app, cstring("ez_gfx_api load target"), shader_paths[:]),
	) {
		render_target_graph_cleanup(&app)
		return
	}
	defer render_target_graph_cleanup(&app)

	if !testing.expect(t, render_target_graph_run_frame(&app, 0, 1)) {
		return
	}
	if !testing.expect(t, render_target_graph_run_frame(&app, 1, 1)) {
		return
	}

	gfx.ez_gfx_ctx_wait_idle()
	testing.expect_value(t, app.validation_log.errors, u32(0))
	testing.expect_value(t, app.ctx.validation_counts.error, u32(0))
}

render_target_graph_init_app :: proc(
	app: ^Render_Target_Graph_App,
	title: cstring,
	shader_paths: []cstring,
) -> bool {
	if len(shader_paths) > GRAPH_SHADER_CAPACITY {
		return false
	}
	if !gfx.ez_gfx_glfw_init() do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	if !gfx.ez_gfx_window_create(&app.window, title, WIDTH, HEIGHT, hidden = true) {
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

render_target_graph_run_frame :: proc(
	app: ^Render_Target_Graph_App,
	shader_start: int,
	shader_count: int,
) -> bool {
	attempts := 0
	for attempts < 60 {
		attempts += 1
		gfx.ez_gfx_window_poll_events()
		if gfx.ez_gfx_window_should_close(&app.window) do return false
		if render_target_graph_draw_frame(app, shader_start, shader_count) {
			return true
		}
	}
	return false
}

render_target_graph_draw_frame :: proc(
	app: ^Render_Target_Graph_App,
	shader_start: int,
	shader_count: int,
) -> bool {
	if !gfx.ez_gfx_begin_render(&app.window) do return false

	for shader_index in shader_start ..< shader_start + shader_count {
		pipeline := gfx.ez_gfx_render_add_vertex_pipeline(
			&app.shaders[shader_index],
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
	}

	return gfx.ez_gfx_finish_render()
}

render_target_graph_cleanup :: proc(app: ^Render_Target_Graph_App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	for i in 0 ..< app.shader_count {
		if app.shader_loaded[i] {
			gfx.ez_gfx_shader_destroy(&app.shaders[i])
			app.shader_loaded[i] = false
		}
	}
	gfx.ez_gfx_window_destroy(&app.window)
	gfx.ez_gfx_ctx_destroy()
	gfx.ez_gfx_glfw_terminate()
}
