#+private
package main

import gfx "../../src"
import shared "../shared"
import im "../../vendor/odin-imgui"
import ig_glfw "../../vendor/odin-imgui/imgui_impl_glfw"
import "core:fmt"
import "core:mem"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720
IMGUI_SHADER_PATH :: cstring("examples/4_imgui/imgui.slang")
IDENTITY_INDEX_COUNT :: 65536

ImGui_Push_Constants :: struct {
	display_size: [2]f32,
}

ImGui_Vertex :: struct {
	pos:   im.Vec2,
	uv:    im.Vec2,
	col:   u32,
	_pad0: u32,
	_pad1: u32,
	_pad2: u32,
}

ImGui_Draw_Command :: struct {
	clip_rect:   [4]f32,
	texture_id:  u32,
	idx_offset:  u32,
	vtx_offset:  u32,
	_pad:        u32,
}

App :: struct {
	ctx:                      gfx.Ez_Gfx_Context_Handle,
	windows:                  [shared.EXAMPLE_MAX_WINDOWS]shared.Example_Window,
	window_count:             int,
	shader:                   gfx.Ez_Gfx_Shader_Handle,
	shader_loaded:            bool,
	imgui_context:            ^im.Context,
	imgui_initialized:        bool,
	font_texture_id:          gfx.Ez_Gfx_Texture_Handle,
	font_texture_loaded:      bool,
	font_atlas_pixels:        []u8,
	identity_index_start:     u32,
	identity_index_loaded:    bool,
	glfw_callbacks_installed: bool,
}

main :: proc() {
	app := new(App)
	defer free(app)
	defer cleanup(app)
	init_app(app)
	run(app)
}

init_app :: proc(app: ^App) {
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

	assert(
		shared.example_window_create(main_window, app.ctx, "ez_gfx_api Dear ImGui", WIDTH, HEIGHT),
	)
	imgui_early_init(app, main_window)

	assert(gfx.ez_gfx_surface_init_device(app.ctx, main_window.surface) == .Ok)
	assert(gfx.ez_gfx_surface_resize(app.ctx, main_window.surface, u32(main_window.framebuffer_width), u32(main_window.framebuffer_height)) == .Ok)
	imgui_gpu_init(app)
}

imgui_early_init :: proc(app: ^App, window: ^shared.Example_Window) {
	im.CHECKVERSION()
	app.imgui_context = im.create_context()
	app.imgui_initialized = true

	io := im.get_io()
	io.ini_filename = nil
	io.backend_flags += {.Renderer_Has_Textures}
	assert(io.fonts != nil)
	assert(ig_glfw.init_for_other(shared.example_window_handle(window), false))
}

imgui_gpu_init :: proc(app: ^App) {
	shader_handle, shader_status := gfx.ez_gfx_shader_create(app.ctx, {
		path = IMGUI_SHADER_PATH,
		vertex_entry = gfx.EZ_GFX_DEFAULT_VERTEX_ENTRY,
		fragment_entry = gfx.EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
	})
	assert(shader_status == .Ok)
	app.shader = shader_handle
	app.shader_loaded = true

	index_heap_bytes := vk.DeviceSize(IDENTITY_INDEX_COUNT * size_of(u32)) + 4096
	gfx.ez_gfx_index_heap_create(app.ctx, index_heap_bytes, "imgui identity index heap")
	imgui_upload_identity_indices(app)
}

// Upload ImGui 1.92 texture requests through ez_gfx bindless textures.
imgui_update_textures :: proc(app: ^App, draw_data: ^im.Draw_Data) {
	if draw_data.textures == nil do return

	textures := mem.slice_ptr(draw_data.textures.data, int(draw_data.textures.size))
	for tex in textures {
		#partial switch tex.status {
		case .Want_Create, .Want_Updates:
			imgui_upload_texture(app, tex)
		case .Want_Destroy:
			if tex.unused_frames > 0 {
				gpu_id := u32(im.texture_data_get_tex_id(tex))
				if gpu_id != 0 && app.font_texture_loaded {
					_ = gfx.ez_gfx_texture_unload(app.ctx, app.font_texture_id)
				}
				im.texture_data_set_tex_id(tex, 0)
				im.texture_data_set_status(tex, .Destroyed)
				if gpu_id != 0 {
					app.font_texture_loaded = false
				}
			}
		}
	}
}

imgui_upload_texture :: proc(app: ^App, tex: ^im.Texture_Data) {
	byte_count := int(im.texture_data_get_size_in_bytes(tex))
	pixels := im.texture_data_get_pixels(tex)
	assert(pixels != nil && byte_count > 0)

	if len(app.font_atlas_pixels) != byte_count {
		if len(app.font_atlas_pixels) > 0 {
			delete(app.font_atlas_pixels)
		}
		app.font_atlas_pixels = make([]u8, byte_count)
	}
	mem.copy(raw_data(app.font_atlas_pixels), pixels, byte_count)

	existing_id := u32(im.texture_data_get_tex_id(tex))
	if existing_id != 0 && app.font_texture_loaded {
		_ = gfx.ez_gfx_texture_unload(app.ctx, app.font_texture_id)
		app.font_texture_loaded = false
	}

	texture_handle, texture_err := gfx.ez_gfx_texture_load(
		app.ctx,
		[]gfx.Ez_Gfx_Texture_Memory_Region{{data = app.font_atlas_pixels}},
		{
			source_format = .RGBA,
			destination_format = .R8G8B8A8_UNORM,
			width = u32(tex.width),
			height = u32(tex.height),
			generate_mips = false,
			min_filter = .Linear,
			mag_filter = .Linear,
			address_mode_u = .Clamp_To_Edge,
			address_mode_v = .Clamp_To_Edge,
			debug_label = "imgui font atlas",
		},
	)
	assert(texture_err == .None, "failed to schedule imgui texture upload")
	texture_id, binding_err := gfx.ez_gfx_texture_binding_index(app.ctx, texture_handle)
	assert(binding_err == .None, "failed to resolve imgui texture binding")
	im.texture_data_set_tex_id(tex, im.Texture_ID(texture_id))
	im.texture_data_set_status(tex, .OK)
	app.font_texture_id = texture_handle
	app.font_texture_loaded = true
}

imgui_upload_identity_indices :: proc(app: ^App) {
	indices := make([]u32, IDENTITY_INDEX_COUNT)
	defer delete(indices)
	for i in 0 ..< IDENTITY_INDEX_COUNT {
		indices[i] = u32(i)
	}
	index_start, upload_status := gfx.ez_gfx_vertex_upload_indices(
		app.ctx,
		indices,
	)
	assert(upload_status == .Ok, "failed to upload ImGui identity indices")
	app.identity_index_start = index_start
	app.identity_index_loaded = true
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
		shared.example_handle_window_input(main_window)
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

imgui_cmd_list_at :: proc(draw_data: ^im.Draw_Data, index: int) -> ^im.Draw_List {
	cmd_lists := mem.slice_ptr(cast([^]^im.Draw_List)draw_data.cmd_lists.data, int(draw_data.cmd_lists_count))
	return cmd_lists[index]
}

draw_frame :: proc(app: ^App, window: ^shared.Example_Window) {
	if !app.glfw_callbacks_installed {
		ig_glfw.install_callbacks(shared.example_window_handle(window))
		app.glfw_callbacks_installed = true
	}
	ig_glfw.new_frame()
	im.new_frame()
	im.show_demo_window(nil)
	im.render()

	draw_data := im.get_draw_data()
	if draw_data == nil || !draw_data.valid {
		if gfx.ez_gfx_begin_render_surface(app.ctx, window.surface) != .Ok do return
		assert(gfx.ez_gfx_finish_render_context(app.ctx) == .Ok, "failed to finish ImGui render")
		return
	}

	imgui_update_textures(app, draw_data)

	if draw_data.cmd_lists_count == 0 {
		if gfx.ez_gfx_begin_render_surface(app.ctx, window.surface) != .Ok do return
		assert(gfx.ez_gfx_finish_render_context(app.ctx) == .Ok, "failed to finish ImGui render")
		return
	}

	total_vtx := int(draw_data.total_vtx_count)
	total_idx := int(draw_data.total_idx_count)
	total_cmds: int
	for list_index in 0 ..< int(draw_data.cmd_lists_count) {
		cmd_list := imgui_cmd_list_at(draw_data, list_index)
		cmds := mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size))
		for cmd in cmds {
			if cmd.user_callback == nil {
				total_cmds += 1
			}
		}
	}
	if total_cmds == 0 {
		if gfx.ez_gfx_begin_render_surface(app.ctx, window.surface) != .Ok do return
		assert(gfx.ez_gfx_finish_render_context(app.ctx) == .Ok, "failed to finish ImGui render")
		return
	}

	vertices := make([]ImGui_Vertex, total_vtx)
	indices := make([]u32, total_idx)
	commands := make([]ImGui_Draw_Command, total_cmds)
	defer delete(vertices)
	defer delete(indices)
	defer delete(commands)

	display_pos := draw_data.display_pos
	framebuffer_scale := draw_data.framebuffer_scale
	vtx_offset := 0
	idx_offset := 0
	cmd_offset := 0

	for list_index in 0 ..< int(draw_data.cmd_lists_count) {
		cmd_list := imgui_cmd_list_at(draw_data, list_index)
		vtx := mem.slice_ptr(cmd_list.vtx_buffer.data, int(cmd_list.vtx_buffer.size))
		for vert_index in 0 ..< len(vtx) {
			src := vtx[vert_index]
			dst := &vertices[vtx_offset + vert_index]
			dst.pos = {
				(src.pos.x - display_pos.x) * framebuffer_scale.x,
				(src.pos.y - display_pos.y) * framebuffer_scale.y,
			}
			dst.uv = src.uv
			dst.col = src.col
			dst._pad0 = 0
			dst._pad1 = 0
			dst._pad2 = 0
		}
		idx := mem.slice_ptr(cmd_list.idx_buffer.data, int(cmd_list.idx_buffer.size))
		for idx_index in 0 ..< len(idx) {
			indices[idx_offset + idx_index] = u32(idx[idx_index])
		}
		cmds := mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size))
		for cmd_index in 0 ..< len(cmds) {
			src := &cmds[cmd_index]
			if src.user_callback != nil do continue
			dst := &commands[cmd_offset]
			clip := src.clip_rect
			dst.clip_rect = {
				(clip.x - display_pos.x) * framebuffer_scale.x,
				(clip.y - display_pos.y) * framebuffer_scale.y,
				(clip.z - display_pos.x) * framebuffer_scale.x,
				(clip.w - display_pos.y) * framebuffer_scale.y,
			}
			dst.texture_id = u32(im.draw_cmd_get_tex_id(src))
			dst.idx_offset = u32(idx_offset) + src.idx_offset
			dst.vtx_offset = u32(vtx_offset) + src.vtx_offset
			cmd_offset += 1
		}
		vtx_offset += len(vtx)
		idx_offset += len(idx)
	}

	if gfx.ez_gfx_begin_render_surface(app.ctx, window.surface) != .Ok do return

	vertex_buffer, vertex_buffer_status := gfx.ez_gfx_acquire_structured(
		app.ctx,
		ImGui_Vertex,
		u32(total_vtx),
		"imgui vertices",
	)
	index_buffer, index_buffer_status := gfx.ez_gfx_acquire_structured(app.ctx, u32, u32(total_idx), "imgui indices")
	command_buffer, command_buffer_status := gfx.ez_gfx_acquire_structured(
		app.ctx,
		ImGui_Draw_Command,
		u32(total_cmds),
		"imgui draw commands",
	)
	assert(
		vertex_buffer_status == .Ok &&
			index_buffer_status == .Ok &&
			command_buffer_status == .Ok,
		"failed to acquire ImGui buffers",
	)

	assert(gfx.ez_gfx_structured_write(app.ctx, vertex_buffer, raw_data(vertices), u64(len(vertices) * size_of(ImGui_Vertex))) == .Ok)
	assert(gfx.ez_gfx_structured_write(app.ctx, index_buffer, raw_data(indices), u64(len(indices) * size_of(u32))) == .Ok)
	assert(gfx.ez_gfx_structured_write(app.ctx, command_buffer, raw_data(commands), u64(len(commands) * size_of(ImGui_Draw_Command))) == .Ok)

	indirect, indirect_status := gfx.ez_gfx_acquire_indirect(
		app.ctx,
		u32(total_cmds),
		"imgui indirect draws",
	)
	assert(indirect_status == .Ok, "failed to acquire ImGui indirect buffer")

	bindings := [3]gfx.Ez_Gfx_Public_Render_Binding {
		{name = "imgui_vertices", structured = vertex_buffer},
		{name = "imgui_indices", structured = index_buffer},
		{name = "imgui_commands", structured = command_buffer},
	}

	framebuffer_size := [2]f32 {
		draw_data.display_size.x * draw_data.framebuffer_scale.x,
		draw_data.display_size.y * draw_data.framebuffer_scale.y,
	}
	push := ImGui_Push_Constants{display_size = framebuffer_size}

	_, pipeline_status := gfx.ez_gfx_render_add_vertex_pipeline_handles(
		app.ctx,
		app.shader,
		indirect,
		bindings[:],
		{blend_mode = .Alpha},
		rawptr(&push),
		u32(size_of(ImGui_Push_Constants)),
	)
	assert(pipeline_status == .Ok, "failed to add ImGui pipeline")

	active_cmd := 0
	for list_index in 0 ..< int(draw_data.cmd_lists_count) {
		cmd_list := imgui_cmd_list_at(draw_data, list_index)
		cmds := mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size))
		for cmd_index in 0 ..< len(cmds) {
			src := &cmds[cmd_index]
			if src.user_callback != nil do continue
			draw := gfx.Ez_Gfx_Draw_Indexed_Command {
				index_count    = src.elem_count,
				instance_count = 1,
				first_index    = app.identity_index_start,
				vertex_offset  = 0,
				first_instance = u32(active_cmd),
			}
			assert(gfx.ez_gfx_indirect_write_draw(app.ctx, indirect, u32(active_cmd), draw) == .Ok, "failed to write ImGui draw")
			active_cmd += 1
		}
	}
	assert(gfx.ez_gfx_indirect_set_draw_count(app.ctx, indirect, u32(active_cmd)) == .Ok, "failed to set ImGui draw count")

	assert(gfx.ez_gfx_finish_render_context(app.ctx) == .Ok, "failed to finish ImGui render")
}

cleanup :: proc(app: ^App) {
	if app.imgui_initialized {
		ig_glfw.shutdown()
		im.destroy_context(app.imgui_context)
		app.imgui_initialized = false
	}
	if app.font_texture_loaded {
		_ = gfx.ez_gfx_texture_unload(app.ctx, app.font_texture_id)
		app.font_texture_loaded = false
	}
	if len(app.font_atlas_pixels) > 0 {
		delete(app.font_atlas_pixels)
	}
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
