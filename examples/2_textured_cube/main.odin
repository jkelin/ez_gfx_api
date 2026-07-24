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
	windows:           [gfx.MAX_WINDOWS]gfx.Ez_Gfx_Window,
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
	app.camera = shared.orbit_camera_default()
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	assert(gfx.ez_gfx_window_create(main_window, "ez_gfx_api cube", WIDTH, HEIGHT))
	shared.orbit_camera_install_callbacks(main_window)
	fmt.println("checkpoint: instance create")
	assert(gfx.ez_gfx_ctx_create_instance(&app.ctx, {enable_debug = true}))
	fmt.println("checkpoint: surface create")
	assert(gfx.ez_gfx_window_create_surface(main_window))
	fmt.println("checkpoint: device init")
	assert(gfx.ez_gfx_ctx_init_device(main_window.surface))
	fmt.println("checkpoint: swapchain recreate")
	assert(gfx.ez_gfx_window_recreate_swapchain(main_window))
	fmt.println("checkpoint: cube data init")
	cube_init(app)
	fmt.println("checkpoint: init done")
}

cube_init :: proc(app: ^App) {
	assert(
		gfx.ez_gfx_shader_compile(
			{
				path = CUBE_SHADER_PATH,
				vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
				fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
			},
			&app.shader,
		),
	)
	app.shader_loaded = true

	vertex_heap_names := [?]string{CUBE_POSITION_HEAP}
	gfx.ez_gfx_vertex_manager_create(
		&app.ctx.vertex_manager,
		vertex_heap_names[:],
		vk.DeviceSize(size_of(CUBE_POSITIONS[0])),
	)

	app.cube_index = gfx.ez_gfx_vertex_manager_upload_indices(
		&app.ctx.vertex_manager,
		CUBE_INDICES[:],
	)
	app.cube_index_len = u32(len(CUBE_INDICES))
	app.cube_vertex = gfx.ez_gfx_vertex_manager_upload_vertices(
		&app.ctx.vertex_manager,
		CUBE_POSITION_HEAP,
		CUBE_POSITIONS[:],
	)

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
	screenshot_enabled := gfx.ez_gfx_config_screenshot_enabled()
	start_time := glfw.GetTime()
	previous_time := start_time

	for !gfx.ez_gfx_window_should_close(main_window) {
		gfx.ez_gfx_window_poll_events()
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

		if run_seconds > 0 && now - start_time >= run_seconds do break
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

	indirect := gfx.ez_gfx_render_acquire_indirect_buffer(
		vk.DrawIndexedIndirectCommand,
		1,
		"cube draw commands",
	)
	if !indirect.ok {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	pipeline := gfx.ez_gfx_render_add_vertex_pipeline(
		&app.shader,
		indirect,
		nil,
		push_constants,
	)
	if !pipeline.ok {
		_ = gfx.ez_gfx_finish_render()
		return
	}

	draw := vk.DrawIndexedIndirectCommand {
		indexCount    = app.cube_index_len,
		instanceCount = 1,
		firstIndex    = app.cube_index,
		vertexOffset  = i32(app.cube_vertex),
		firstInstance = 0,
	}
	if !gfx.ez_gfx_indirect_buffer_write_draw(&indirect, 0, draw) {
		_ = gfx.ez_gfx_finish_render()
		return
	}
	if !gfx.ez_gfx_indirect_buffer_set_draw_count(&indirect, 1) {
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
	if app.texture_scheduled {
		_ = gfx.ez_gfx_unload_texture(app.texture_id)
		app.texture_scheduled = false
	}
	for i in 0 ..< app.window_count {
		gfx.ez_gfx_window_destroy(&app.windows[i])
	}
	app.window_count = 0
	gfx.ez_gfx_ctx_destroy()
	gfx.ez_gfx_glfw_terminate()
}
