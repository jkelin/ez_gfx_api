#+private
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
	windows:            [shared.EXAMPLE_MAX_WINDOWS]gfx.Ez_Gfx_Window,
	window_count:       int,
	shader:             gfx.Ez_Gfx_Shader_Program,
	shader_loaded:      bool,
	triangle_index:     u32,
	triangle_index_len: u32,
	triangle_vertex:    u32,
}

main :: proc() {
	app := new(App)
	context.user_ptr = &app.ctx
	defer free(app)
	defer cleanup(app)
	init_app(app)
	run(app)
}

init_app :: proc(app: ^App) {
	fmt.println("checkpoint: glfw init")
	assert(shared.example_glfw_init())

	context.user_ptr = &app.ctx
	assert(gfx.ez_gfx_enable_all_decoders() == .Ok, "failed to enable image decoders")
	app.window_count = 1
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	assert(
		shared.example_window_create(main_window, "ez_gfx_api Vulkan", WIDTH, HEIGHT),
	)
	fmt.println("checkpoint: instance create")
	assert(gfx.ez_gfx_ctx_create_instance(&app.ctx, {
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	}) == .Ok)
	fmt.println("checkpoint: surface create")
	assert(gfx.ez_gfx_window_create_surface(main_window) == .Ok)
	fmt.println("checkpoint: device init")
	assert(gfx.ez_gfx_ctx_init_device(main_window.surface) == .Ok)
	fmt.println("checkpoint: swapchain recreate")
	assert(gfx.ez_gfx_window_recreate_swapchain(main_window, main_window.framebuffer_width, main_window.framebuffer_height) == .Ok)
	fmt.println("checkpoint: triangle data init")
	triangle_init(app)
	fmt.println("checkpoint: init done")
}

triangle_init :: proc(app: ^App) {
	assert(gfx.ez_gfx_shader_compile({
				path = TRIANGLE_SHADER_PATH,
				vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
				fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
			},
			&app.shader,) == .Ok)
	app.shader_loaded = true

	gfx.ez_gfx_vertex_manager_add_heap(
		&app.ctx.vertex_manager,
		TRIANGLE_POSITION_HEAP,
		gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES,
		vk.DeviceSize(size_of(TRIANGLE_POSITIONS[0])),
	)

	index_start, index_status := gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		TRIANGLE_INDICES[:],
	)
	assert(index_status == .Ok, "failed to upload triangle indices")
	app.triangle_index = index_start
	app.triangle_index_len = u32(len(TRIANGLE_INDICES))
	vertex_start, vertex_status := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		TRIANGLE_POSITION_HEAP,
		TRIANGLE_POSITIONS[:],
	)
	assert(vertex_status == .Ok, "failed to upload triangle vertices")
	app.triangle_vertex = vertex_start
}

run :: proc(app: ^App) {
	main_window := &app.windows[0]
	run_seconds := gfx.ez_gfx_config_run_seconds()
	max_frames := gfx.ez_gfx_config_max_frames()
	screenshot_enabled := gfx.ez_gfx_config_screenshot_enabled()
	start_time := glfw.GetTime()
	frame_count := 0

	for !shared.example_window_should_close(main_window) {
		shared.example_window_poll_events(main_window)
		if max_frames > 0 && frame_count >= max_frames do break
		if run_seconds > 0 && glfw.GetTime() - start_time >= run_seconds do break
		draw_frame(app, main_window)
		frame_count += 1
	}

	gfx.ez_gfx_ctx_wait_idle()
	glfw.PollEvents()

	if screenshot_enabled {
		assert(gfx.ez_gfx_screenshot_save_window(main_window, gfx.SCREENSHOT_PATH) == .Ok, "failed to save screenshot")
	}
}

draw_frame :: proc(app: ^App, window: ^gfx.Ez_Gfx_Window) {
	if gfx.ez_gfx_begin_render(window) != .Ok do return

	indirect, indirect_status := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		1,
		"triangle draw commands",
	)
	assert(indirect_status == .Ok, "failed to acquire triangle indirect buffer")

	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shader,
		indirect,
		nil,
	)
	assert(pipeline_status == .Ok, "failed to add triangle pipeline")

	draw := vk.DrawIndexedIndirectCommand {
		indexCount    = app.triangle_index_len,
		instanceCount = 1,
		firstIndex    = app.triangle_index,
		vertexOffset  = i32(app.triangle_vertex),
		firstInstance = 0,
	}
	assert(gfx.ez_gfx_indirect_buffer_write_draw(&indirect, 0, draw) == .Ok, "failed to write triangle draw")
	assert(gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, 1) == .Ok, "failed to set triangle draw count")

	assert(gfx.ez_gfx_finish_render() == .Ok, "failed to finish triangle render")
}

cleanup :: proc(app: ^App) {
	context.user_ptr = &app.ctx
	if app.shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.shader)
		app.shader_loaded = false
	}
	for i in 0 ..< app.window_count {
		shared.example_window_destroy(&app.windows[i])
	}
	app.window_count = 0
	gfx.ez_gfx_ctx_destroy()
	shared.example_glfw_terminate()
}
