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
	ctx:                gfx.Ez_Gfx_Context_Handle,
	windows:            [shared.EXAMPLE_MAX_WINDOWS]shared.Example_Window,
	window_count:       int,
	shader:             gfx.Ez_Gfx_Shader_Handle,
	shader_loaded:      bool,
	triangle_index:     u32,
	triangle_index_len: u32,
	triangle_vertex:    u32,
}

main :: proc() {
	app := new(App)
	defer free(app)
	defer cleanup(app)
	init_app(app)
	run(app)
}

init_app :: proc(app: ^App) {
	fmt.println("checkpoint: glfw init")
	assert(shared.example_glfw_init())

	fmt.println("checkpoint: instance create")
	ctx_handle, ctx_status := gfx.ez_gfx_context_create({
		enable_debug = true,
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	})
	assert(ctx_status == .Ok)
	app.ctx = ctx_handle

	assert(gfx.ez_gfx_enable_all_decoders_for_context(app.ctx) == .Ok, "failed to enable image decoders")
	app.window_count = 1
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	assert(
		shared.example_window_create(main_window, app.ctx, "ez_gfx_api Vulkan", WIDTH, HEIGHT),
	)
	fmt.println("checkpoint: device init")
	assert(gfx.ez_gfx_surface_init_device(app.ctx, main_window.surface) == .Ok)
	fmt.println("checkpoint: swapchain recreate")
	assert(gfx.ez_gfx_surface_resize(app.ctx, main_window.surface, u32(main_window.framebuffer_width), u32(main_window.framebuffer_height)) == .Ok)
	fmt.println("checkpoint: triangle data init")
	triangle_init(app)
	fmt.println("checkpoint: init done")
}

triangle_init :: proc(app: ^App) {
	shader_handle, shader_status := gfx.ez_gfx_shader_create(app.ctx, {
		path = TRIANGLE_SHADER_PATH,
		vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
		fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
	})
	assert(shader_status == .Ok)
	app.shader = shader_handle
	app.shader_loaded = true

	gfx.ez_gfx_vertex_heap_create(
		app.ctx,
		TRIANGLE_POSITION_HEAP,
		gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES,
		vk.DeviceSize(size_of(TRIANGLE_POSITIONS[0])),
	)

	index_start, index_status := gfx.ez_gfx_vertex_upload_indices(
		app.ctx,
		TRIANGLE_INDICES[:],
	)
	assert(index_status == .Ok, "failed to upload triangle indices")
	app.triangle_index = index_start
	app.triangle_index_len = u32(len(TRIANGLE_INDICES))
	vertex_start, vertex_status := gfx.ez_gfx_vertex_upload(
		app.ctx,
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

	gfx.ez_gfx_context_wait_idle(app.ctx)
	glfw.PollEvents()

	if screenshot_enabled {
		assert(gfx.ez_gfx_screenshot_save(app.ctx, main_window.surface, gfx.SCREENSHOT_PATH) == .Ok, "failed to save screenshot")
	}
}

draw_frame :: proc(app: ^App, window: ^shared.Example_Window) {
	if gfx.ez_gfx_begin_render_surface(app.ctx, window.surface) != .Ok do return

	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(
		app.ctx,
		1,
		"triangle draw commands",
	)
	assert(indirect_status == .Ok, "failed to acquire triangle indirect buffer")

	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(
		app.ctx,
		app.shader,
		indirect,
		nil,
	)
	assert(pipeline_status == .Ok, "failed to add triangle pipeline")

	draw := gfx.Ez_Gfx_Draw_Indexed_Command {
		index_count    = app.triangle_index_len,
		instance_count = 1,
		first_index    = app.triangle_index,
		vertex_offset  = i32(app.triangle_vertex),
		first_instance = 0,
	}
	assert(gfx.ez_gfx_indirect_write_draw(app.ctx, indirect, 0, draw) == .Ok, "failed to write triangle draw")
	assert(gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, 1) == .Ok, "failed to set triangle draw count")

	assert(gfx.ez_gfx_finish_render_context(app.ctx) == .Ok, "failed to finish triangle render")
}

cleanup :: proc(app: ^App) {
		if app.shader_loaded {
		gfx.ez_gfx_shader_release(app.ctx, app.shader)
		app.shader_loaded = false
	}
	for i in 0 ..< app.window_count {
		shared.example_window_destroy(&app.windows[i])
	}
	app.window_count = 0
	gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}
