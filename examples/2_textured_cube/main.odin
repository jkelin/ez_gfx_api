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
	ctx:               gfx.Ez_Gfx_Context_Handle,
	windows:           [shared.EXAMPLE_MAX_WINDOWS]shared.Example_Window,
	window_count:      int,
	shader:            gfx.Ez_Gfx_Shader_Handle,
	shader_loaded:     bool,
	texture:           gfx.Ez_Gfx_Texture_Handle,
	texture_id:        u32,
	texture_scheduled: bool,
	cube_index:        u32,
	cube_index_len:    u32,
	cube_vertex:       u32,
	camera:            shared.Orbit_Camera,
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
	app.camera = shared.orbit_camera_default()
	main_window := &app.windows[0]

	fmt.println("checkpoint: window create")
	assert(shared.example_window_create(main_window, app.ctx, "ez_gfx_api cube", WIDTH, HEIGHT))
	shared.orbit_camera_install_callbacks(main_window)
	fmt.println("checkpoint: device init")
	assert(gfx.ez_gfx_surface_init_device(app.ctx, main_window.surface) == .Ok)
	fmt.println("checkpoint: swapchain recreate")
	assert(gfx.ez_gfx_surface_resize(app.ctx, main_window.surface, u32(main_window.framebuffer_width), u32(main_window.framebuffer_height)) == .Ok)
	fmt.println("checkpoint: cube data init")
	cube_init(app)
	fmt.println("checkpoint: init done")
}

cube_init :: proc(app: ^App) {
	shader_handle, shader_status := gfx.ez_gfx_shader_create(app.ctx, {
		path = CUBE_SHADER_PATH,
		vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
		fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
	})
	assert(shader_status == .Ok)
	app.shader = shader_handle
	app.shader_loaded = true

	gfx.ez_gfx_vertex_heap_create(
		app.ctx,
		CUBE_POSITION_HEAP,
		gfx.EZ_GFX_DEFAULT_VERTEX_HEAP_BYTES,
		vk.DeviceSize(size_of(CUBE_POSITIONS[0])),
	)

	index_start, index_status := gfx.ez_gfx_vertex_upload_indices(
		app.ctx,
		CUBE_INDICES[:],
	)
	assert(index_status == .Ok, "failed to upload cube indices")
	app.cube_index = index_start
	app.cube_index_len = u32(len(CUBE_INDICES))
	vertex_start, vertex_status := gfx.ez_gfx_vertex_upload(
		app.ctx,
		CUBE_POSITION_HEAP,
		CUBE_POSITIONS[:],
	)
	assert(vertex_status == .Ok, "failed to upload cube vertices")
	app.cube_vertex = vertex_start

	cube_load_texture(app)
}

cube_load_texture :: proc(app: ^App) {
	region := gfx.Ez_Gfx_Texture_Memory_Region{data = TEXTURE_BYTES}
	texture, texture_err := gfx.ez_gfx_texture_load(
		app.ctx,
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
	app.texture = texture
	texture_id, binding_err := gfx.ez_gfx_texture_binding_index(app.ctx, texture)
	assert(binding_err == .None, "failed to resolve cube texture binding")
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

	gfx.ez_gfx_context_wait_idle(app.ctx)
	glfw.PollEvents()

	if screenshot_enabled {
		assert(gfx.ez_gfx_screenshot_save(app.ctx, main_window.surface, gfx.SCREENSHOT_PATH) == .Ok, "failed to save screenshot")
	}
}

draw_frame :: proc(app: ^App, window: ^shared.Example_Window) {
	if gfx.ez_gfx_begin_render_surface(app.ctx, window.surface) != .Ok do return

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
		texture_id = app.texture_id,
	}

	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(
		app.ctx,
		1,
		"cube draw commands",
	)
	assert(indirect_status == .Ok, "failed to acquire cube indirect buffer")

	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(
		app.ctx,
		app.shader,
		indirect,
		nil,
		{},
		rawptr(&push_constants),
		u32(size_of(Cube_Push_Constants)),
	)
	assert(pipeline_status == .Ok, "failed to add cube pipeline")

	draw := vk.DrawIndexedIndirectCommand {
		indexCount    = app.cube_index_len,
		instanceCount = 1,
		firstIndex    = app.cube_index,
		vertexOffset  = i32(app.cube_vertex),
		firstInstance = 0,
	}
	assert(gfx.ez_gfx_indirect_write_draw(app.ctx, indirect, 0, draw) == .Ok, "failed to write cube draw")
	assert(gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, 1) == .Ok, "failed to set cube draw count")

	assert(gfx.ez_gfx_finish_render_context(app.ctx) == .Ok, "failed to finish cube render")
}

cleanup :: proc(app: ^App) {
		if app.shader_loaded {
		gfx.ez_gfx_shader_release(app.ctx, app.shader)
		app.shader_loaded = false
	}
	if app.texture_scheduled {
		_ = gfx.ez_gfx_texture_unload(app.ctx, app.texture)
		app.texture_scheduled = false
	}
	for i in 0 ..< app.window_count {
		shared.example_window_destroy(&app.windows[i])
	}
	app.window_count = 0
	gfx.ez_gfx_context_destroy(app.ctx)
	shared.example_glfw_terminate()
}
