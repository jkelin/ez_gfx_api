package main

import gfx "../../src"
import "core:fmt"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720
TRIANGLE_SHADER_PATH :: cstring("examples/one_triangle/triangle.slang")
TRIANGLE_POSITION_HEAP :: "position"

TRIANGLE_INDICES :: [3]u32{0, 1, 2}
TRIANGLE_POSITIONS :: [3][4]f32 {
	{-0.5, -0.5, 0.0, 1.0},
	{0.5, -0.5, 0.0, 1.0},
	{0.0, 0.5, 0.0, 1.0},
}

App :: struct {
	ctx:                gfx.Ez_Gfx_Ctx,
	windows:            [gfx.MAX_WINDOWS]gfx.Ez_Gfx_Window,
	window_count:       int,
	shader:             gfx.Ez_Gfx_Shader_Program,
	shader_loaded:      bool,
	triangle_index:     u32,
	triangle_index_len: u32,
	triangle_vertex:    u32,
}

main :: proc() {
	app: App

	ok := init_app(&app)
	if !ok {
		cleanup(&app)
		return
	}

	run(&app)
	cleanup(&app)
}

init_app :: proc(app: ^App) -> bool {
	fmt.println("checkpoint: glfw init")
	if !gfx.ez_gfx_glfw_init() do return false

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	app.window_count = 1
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	if !gfx.ez_gfx_window_create(main_window, "ez_gfx_api Vulkan", WIDTH, HEIGHT) do return false
	fmt.println("checkpoint: instance create")
	if !gfx.ez_gfx_ctx_create_instance(&app.ctx, {enable_debug = true}) do return false
	fmt.println("checkpoint: surface create")
	if !gfx.ez_gfx_window_create_surface(main_window) do return false
	fmt.println("checkpoint: device init")
	if !gfx.ez_gfx_ctx_init_device(main_window.surface) do return false
	fmt.println("checkpoint: swapchain recreate")
	if !gfx.ez_gfx_window_recreate_swapchain(main_window) do return false
	fmt.println("checkpoint: triangle data init")
	if !triangle_init(app) do return false

	fmt.println("checkpoint: init done")
	return true
}

triangle_init :: proc(app: ^App) -> bool {
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

run :: proc(app: ^App) {
	main_window := &app.windows[0]
	run_seconds := gfx.ez_gfx_config_run_seconds()
	screenshot_enabled := gfx.ez_gfx_config_screenshot_enabled()
	start_time := glfw.GetTime()

	for !gfx.ez_gfx_window_should_close(main_window) {
		gfx.ez_gfx_window_poll_events()
		if run_seconds > 0 && glfw.GetTime() - start_time >= run_seconds do break
		draw_frame(app, main_window)
	}

	gfx.ez_gfx_ctx_wait_idle()
	glfw.PollEvents()

	if screenshot_enabled {
		if !gfx.ez_gfx_screenshot_save_window(main_window, gfx.SCREENSHOT_PATH) {
			fmt.eprintln("failed to save screenshot")
		}
	}
}

draw_frame :: proc(app: ^App, window: ^gfx.Ez_Gfx_Window) {
	if !gfx.ez_gfx_begin_render(window) do return

	pipeline := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shader,
		vk.DeviceSize(size_of(vk.DrawIndexedIndirectCommand)),
		1,
	)
	if !pipeline.ok {
		_ = gfx.ez_gfx_finish_render()
		return
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
		return
	}
	if !gfx.ez_gfx_vertex_pipeline_set_draw_count(&pipeline, 1) {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	_ = gfx.ez_gfx_finish_render()
}

cleanup :: proc(app: ^App) {
	gfx.ez_gfx_set_current_ctx(&app.ctx)
	if app.shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.shader)
		app.shader_loaded = false
	}
	for i in 0 ..< app.window_count {
		gfx.ez_gfx_window_destroy(&app.windows[i])
	}
	app.window_count = 0
	gfx.ez_gfx_ctx_destroy()
	gfx.ez_gfx_glfw_terminate()
}
