#+private
package main

import gfx "../../src"
import shared "../shared"
import "core:fmt"
import "core:math"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720
CUBE_SHADER_PATH :: cstring("examples/2_textured_cube/cube.slang")
TEXTURE_BYTES :: #load("ez_graphics_api_texture.png")
CUBE_POSITION_HEAP :: "position"

Cube_Push_Constants :: struct {
	mvp:        shared.Mat4,
	texture_id: u32,
	_padding:   [3]u32,
}

CUBE_INDICES: [36]u32 = {
	0, 1, 2, 2, 3, 0,
	4, 5, 6, 6, 7, 4,
	8, 9, 10, 10, 11, 8,
	12, 13, 14, 14, 15, 12,
	16, 17, 18, 18, 19, 16,
	20, 21, 22, 22, 23, 20,
}

CUBE_POSITIONS: [24][4]f32 = {
	{-1, -1, 1, 1}, {1, -1, 1, 1}, {1, 1, 1, 1}, {-1, 1, 1, 1},
	{1, -1, -1, 1}, {-1, -1, -1, 1}, {-1, 1, -1, 1}, {1, 1, -1, 1},
	{-1, -1, -1, 1}, {-1, -1, 1, 1}, {-1, 1, 1, 1}, {-1, 1, -1, 1},
	{1, -1, 1, 1}, {1, -1, -1, 1}, {1, 1, -1, 1}, {1, 1, 1, 1},
	{-1, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, -1, 1}, {-1, 1, -1, 1},
	{-1, -1, -1, 1}, {1, -1, -1, 1}, {1, -1, 1, 1}, {-1, -1, 1, 1},
}

App :: struct {
	ctx:               gfx.Ez_Gfx_Ctx,
	windows:           [shared.EXAMPLE_MAX_WINDOWS]gfx.Ez_Gfx_Window,
	window_count:      int,
	shader:            gfx.Ez_Gfx_Shader_Program,
	shader_loaded:     bool,
	texture_id:        gfx.Ez_Gfx_Texture_ID,
	texture_scheduled: bool,
	cube_index:        u32,
	cube_index_len:    u32,
	cube_vertex:       u32,
	camera:            shared.Orbit_Camera,
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
	app.camera = shared.orbit_camera_default()
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	assert(shared.example_window_create(main_window, "ez_gfx_api cube", WIDTH, HEIGHT))
	shared.orbit_camera_install_callbacks(main_window)
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
	fmt.println("checkpoint: cube data init")
	cube_init(app)
	fmt.println("checkpoint: init done")
}

cube_init :: proc(app: ^App) {
	assert(gfx.ez_gfx_shader_compile({
				path = CUBE_SHADER_PATH,
				vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
				fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
			},
			&app.shader,) == .Ok)
	app.shader_loaded = true

	gfx.ez_gfx_vertex_manager_add_heap(
		&app.ctx.vertex_manager,
		CUBE_POSITION_HEAP,
		gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES,
		vk.DeviceSize(size_of(CUBE_POSITIONS[0])),
	)

	index_start, index_status := gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		CUBE_INDICES[:],
	)
	assert(index_status == .Ok, "failed to upload cube indices")
	app.cube_index = index_start
	app.cube_index_len = u32(len(CUBE_INDICES))
	vertex_start, vertex_status := gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		CUBE_POSITION_HEAP,
		CUBE_POSITIONS[:],
	)
	assert(vertex_status == .Ok, "failed to upload cube vertices")
	app.cube_vertex = vertex_start

	cube_load_texture(app)
}

cube_load_texture :: proc(app: ^App) {
	region := gfx.Ez_Gfx_Texture_Memory_Region{data = TEXTURE_BYTES}
	texture_id, texture_err := gfx.ez_gfx_load_texture(
		[]gfx.Ez_Gfx_Texture_Memory_Region{region},
		{
			source_format = .PNG,
			destination_format = .R8G8B8A8_UNORM,
			generate_mips = true,
			min_filter = .Linear,
			mag_filter = .Linear,
			debug_label = "example cube texture",
		},
	)
	assert(texture_err == .None, "failed to schedule cube texture load")
	app.texture_id = texture_id
	app.texture_scheduled = true
}

run :: proc(app: ^App) {
	main_window := &app.windows[0]
	run_seconds := gfx.ez_gfx_config_run_seconds()
	max_frames := gfx.ez_gfx_config_max_frames()
	screenshot_enabled := gfx.ez_gfx_config_screenshot_enabled()
	start_time := glfw.GetTime()
	previous_time := start_time
	frame_count := 0

	for !shared.example_window_should_close(main_window) {
		shared.example_window_poll_events(main_window)
		shared.example_handle_window_input(main_window)

		now := glfw.GetTime()
		delta_time := f32(now - previous_time)
		previous_time = now
		shared.orbit_camera_update(
			&app.camera,
			main_window,
			{0, 0, 0},
			shared.orbit_camera_default_start(),
			delta_time,
		)
		if max_frames > 0 && frame_count >= max_frames do break
		if run_seconds > 0 && now - start_time >= run_seconds do break
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

	model := shared.mat4_identity()
	view := shared.orbit_camera_view(&app.camera)
	projection := shared.perspective_vk(
		math.to_radians_f32(60),
		shared.window_aspect(window),
		0.1,
		100.0,
	)
	push_constants := Cube_Push_Constants {
		mvp = shared.mat4_mul(projection, shared.mat4_mul(view, model)),
		texture_id = u32(app.texture_id),
	}

	indirect, indirect_status := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		1,
		"cube draw commands",
	)
	assert(indirect_status == .Ok, "failed to acquire cube indirect buffer")

	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shader,
		indirect,
		nil,
		{},
		push_constants,
	)
	assert(pipeline_status == .Ok, "failed to add cube pipeline")

	draw := vk.DrawIndexedIndirectCommand {
		indexCount    = app.cube_index_len,
		instanceCount = 1,
		firstIndex    = app.cube_index,
		vertexOffset  = i32(app.cube_vertex),
		firstInstance = 0,
	}
	assert(gfx.ez_gfx_indirect_buffer_write_draw(&indirect, 0, draw) == .Ok, "failed to write cube draw")
	assert(gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, 1) == .Ok, "failed to set cube draw count")

	assert(gfx.ez_gfx_finish_render() == .Ok, "failed to finish cube render")
}

cleanup :: proc(app: ^App) {
	context.user_ptr = &app.ctx
	if app.shader_loaded {
		gfx.ez_gfx_shader_destroy(&app.shader)
		app.shader_loaded = false
	}
	if app.texture_scheduled {
		_ = gfx.ez_gfx_unload_texture(app.texture_id)
		app.texture_scheduled = false
	}
	for i in 0 ..< app.window_count {
		shared.example_window_destroy(&app.windows[i])
	}
	app.window_count = 0
	gfx.ez_gfx_ctx_destroy()
	shared.example_glfw_terminate()
}
