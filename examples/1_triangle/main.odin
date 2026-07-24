package main

import gfx "../../src"
import shared "../shared"
import "core:fmt"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720
TRIANGLE_SHADER_PATH :: cstring("examples/1_triangle/triangle.slang")
TRIANGLE_POSITION_HEAP :: "position"

TRIANGLE_INDICES: [3]u32 = {0, 1, 2}
TRIANGLE_POSITIONS: [3][4]f32 = {
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
	defer cleanup(&app)
	init_app(&app)
	run(&app)
}

init_app :: proc(app: ^App) {
	fmt.println("checkpoint: glfw init")
	assert(gfx.ez_gfx_glfw_init())

	gfx.ez_gfx_set_current_ctx(&app.ctx)
	assert(gfx.ez_gfx_enable_all_decoders(), "failed to enable image decoders")
	app.window_count = 1
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	assert(
		gfx.ez_gfx_window_create(main_window, "ez_gfx_api Vulkan", WIDTH, HEIGHT),
	)
	fmt.println("checkpoint: instance create")
	assert(gfx.ez_gfx_ctx_create_instance(&app.ctx, {enable_debug = true}))
	fmt.println("checkpoint: surface create")
	assert(gfx.ez_gfx_window_create_surface(main_window))
	fmt.println("checkpoint: device init")
	assert(gfx.ez_gfx_ctx_init_device(main_window.surface))
	fmt.println("checkpoint: swapchain recreate")
	assert(gfx.ez_gfx_window_recreate_swapchain(main_window))
	fmt.println("checkpoint: triangle data init")
	triangle_init(app)
	fmt.println("checkpoint: init done")
}

triangle_init :: proc(app: ^App) {
	assert(
		gfx.ez_gfx_shader_compile(
			{
				path = TRIANGLE_SHADER_PATH,
				vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
				fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
			},
			&app.shader,
		),
	)
	app.shader_loaded = true

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
		assert(
			gfx.ez_gfx_screenshot_save_window(main_window, gfx.SCREENSHOT_PATH),
			"failed to save screenshot",
		)
	}
}

draw_frame :: proc(app: ^App, window: ^gfx.Ez_Gfx_Window) {
	if !gfx.ez_gfx_begin_render(window) do return

	indirect := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		1,
		"triangle draw commands",
	)
	assert(indirect.ok, "failed to acquire triangle indirect buffer")

	pipeline := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shader,
		indirect,
		nil,
	)
	assert(pipeline.ok, "failed to add triangle pipeline")

	draw := vk.DrawIndexedIndirectCommand {
		indexCount    = app.triangle_index_len,
		instanceCount = 1,
		firstIndex    = app.triangle_index,
		vertexOffset  = i32(app.triangle_vertex),
		firstInstance = 0,
	}
	assert(
		gfx.ez_gfx_indirect_buffer_write_draw(&indirect, 0, draw),
		"failed to write triangle draw",
	)
	assert(
		gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, 1),
		"failed to set triangle draw count",
	)

	assert(gfx.ez_gfx_finish_render(), "failed to finish triangle render")
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
