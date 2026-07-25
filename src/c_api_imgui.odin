package ez_gfx

import "base:runtime"
import "core:mem"
import im "../vendor/odin-imgui"
import vk "vendor:vulkan"

IMGUI_C_SHADER_PATH :: cstring("examples/4_imgui/imgui.slang")
IMGUI_C_IDENTITY_INDEX_COUNT :: 65536

Ez_Gfx_C_ImGui_Push_Constants :: struct {
	display_size: [2]f32,
}

Ez_Gfx_C_ImGui_Vertex :: struct {
	pos:   im.Vec2,
	uv:    im.Vec2,
	col:   u32,
	_pad0: u32,
	_pad1: u32,
	_pad2: u32,
}

Ez_Gfx_C_ImGui_Draw_Command :: struct {
	clip_rect:  [4]f32,
	texture_id: u32,
	idx_offset: u32,
	vtx_offset: u32,
	_pad:       u32,
}

@(private)
ez_gfx_c_imgui_context :: proc(owner: ^Ez_Gfx_C_Context) -> ^im.Context {
	if owner == nil || owner.imgui_context == nil do return nil
	return cast(^im.Context)owner.imgui_context
}

@(private)
ez_gfx_c_imgui_init :: proc(owner: ^Ez_Gfx_C_Context) -> bool {
	if owner == nil do return false
	if owner.imgui_context != nil {
		im.set_current_context(ez_gfx_c_imgui_context(owner))
		return true
	}

	imgui_context := im.create_context()
	if imgui_context == nil do return false
	owner.imgui_context = imgui_context
	im.set_current_context(imgui_context)
	im.CHECKVERSION()

	io := im.get_io()
	io.ini_filename = nil
	io.backend_flags += {.Renderer_Has_Textures}
	io.display_framebuffer_scale = {1, 1}
	io.delta_time = 1.0 / 60.0

	if !ez_gfx_shader_compile({
		path = IMGUI_C_SHADER_PATH,
		vertex_entry = EZ_GFX_DEFAULT_VERTEX_ENTRY,
		fragment_entry = EZ_GFX_DEFAULT_FRAGMENT_ENTRY,
	}, &owner.imgui_shader) {
		im.destroy_context(imgui_context)
		owner.imgui_context = nil
		return false
	}
	owner.imgui_shader_loaded = true

	indices := make([]u32, IMGUI_C_IDENTITY_INDEX_COUNT)
	defer delete(indices)
	for index in 0 ..< IMGUI_C_IDENTITY_INDEX_COUNT {
		indices[index] = u32(index)
	}
	allocation, ok := ez_gfx_vertex_manager_schedule_upload(
		&owner.ctx.vertex_manager,
		.Indices,
		"",
		&owner.ctx.vertex_manager.index_heap,
		raw_data(indices),
		IMGUI_C_IDENTITY_INDEX_COUNT,
		vk.DeviceSize(size_of(u32)),
	)
	if !ok {
		ez_gfx_shader_destroy(&owner.imgui_shader)
		owner.imgui_shader_loaded = false
		im.destroy_context(imgui_context)
		owner.imgui_context = nil
		return false
	}
	owner.imgui_identity_index_start = allocation.start_index
	owner.imgui_identity_index_loaded = true
	return true
}

@(private)
ez_gfx_c_imgui_upload_textures :: proc(
	owner: ^Ez_Gfx_C_Context,
	draw_data: ^im.Draw_Data,
) -> bool {
	if owner == nil || draw_data == nil || draw_data.textures == nil do return true

	textures := draw_data.textures^
	for texture in mem.slice_ptr(textures.data, int(textures.size)) {
		if texture == nil do continue
		#partial switch texture.status {
		case .Want_Create, .Want_Updates:
			byte_count := int(im.texture_data_get_size_in_bytes(texture))
			pixels := im.texture_data_get_pixels(texture)
			if pixels == nil || byte_count <= 0 do return false

			if owner.imgui_font_texture_loaded {
				ez_gfx_ctx_wait_idle()
				_ = ez_gfx_unload_texture(owner.imgui_font_texture_id)
				owner.imgui_font_texture_loaded = false
			}

			pixel_data := make([]u8, byte_count)
			mem.copy(raw_data(pixel_data), pixels, byte_count)
			// The texture manager's decode workers borrow this memory until their
			// completion callback. Keep every upload alive until context teardown.
			append(&owner.imgui_texture_data, pixel_data)
			owner.imgui_font_atlas_pixels = pixel_data

			regions := [1]Ez_Gfx_Texture_Memory_Region{{data = pixel_data}}
			texture_desc := Ez_Gfx_Load_Texture_Desc {
				source_format      = .RGBA,
				destination_format = .R8G8B8A8_UNORM,
				width              = u32(texture.width),
				height             = u32(texture.height),
				generate_mips      = false,
				min_filter         = .Linear,
				mag_filter         = .Linear,
				address_mode_u     = .Clamp_To_Edge,
				address_mode_v     = .Clamp_To_Edge,
				address_mode_w     = .Clamp_To_Edge,
				debug_label        = "imgui font atlas",
			}
			texture_id, texture_error := ez_gfx_load_texture(regions[:], texture_desc)
			if texture_error != .None do return false
			owner.imgui_font_texture_id = texture_id
			owner.imgui_font_texture_loaded = true
			im.texture_data_set_tex_id(texture, im.Texture_ID(texture_id))
			im.texture_data_set_status(texture, .OK)
		case .Want_Destroy:
			texture_id := Ez_Gfx_Texture_ID(im.texture_data_get_tex_id(texture))
			if texture_id == owner.imgui_font_texture_id && owner.imgui_font_texture_loaded {
				ez_gfx_ctx_wait_idle()
				_ = ez_gfx_unload_texture(texture_id)
				owner.imgui_font_texture_loaded = false
			}
			im.texture_data_set_status(texture, .Destroyed)
		}
	}
	return true
}

// Releases ImGui GPU objects before the owning Vulkan context is destroyed.
// Pixel buffers intentionally remain owned by Ez_Gfx_C_Context until after the
// texture workers have shut down in ez_gfx_c_context_destroy.
ez_gfx_c_imgui_destroy :: proc(owner: ^Ez_Gfx_C_Context) {
	if owner == nil do return
	if owner.imgui_context != nil {
		im.set_current_context(ez_gfx_c_imgui_context(owner))
	}
	if owner.imgui_font_texture_loaded {
		ez_gfx_ctx_wait_idle()
		_ = ez_gfx_unload_texture(owner.imgui_font_texture_id)
		owner.imgui_font_texture_loaded = false
	}
	if owner.imgui_shader_loaded {
		ez_gfx_ctx_wait_idle()
		ez_gfx_shader_destroy(&owner.imgui_shader)
		owner.imgui_shader_loaded = false
	}
	if owner.imgui_context != nil {
		im.destroy_context(ez_gfx_c_imgui_context(owner))
		owner.imgui_context = nil
	}
	owner.imgui_font_texture_id = 0
	owner.imgui_font_atlas_pixels = nil
	owner.imgui_identity_index_start = 0
	owner.imgui_identity_index_loaded = false
}

@(export)
ez_gfx_c_imgui_render_demo :: proc "c" (surface_handle: u64) -> i32 {
	context = runtime.default_context()
	surface := ez_gfx_c_surface_from_handle(surface_handle)
	if surface == nil || surface.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	owner := surface.owner
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if !ez_gfx_c_imgui_init(owner) do return EZ_GFX_C_RESULT_NATIVE_FAILURE

	width, height := ez_gfx_window_get_framebuffer_size(&surface.surface)
	if width <= 0 || height <= 0 do return EZ_GFX_C_RESULT_NOT_READY
	im.set_current_context(ez_gfx_c_imgui_context(owner))
	io := im.get_io()
	io.display_size = {f32(width), f32(height)}

	im.new_frame()
	im.show_demo_window(nil)
	im.render()
	draw_data := im.get_draw_data()
	if draw_data == nil || !draw_data.valid do return EZ_GFX_C_RESULT_NATIVE_FAILURE
	if !ez_gfx_c_imgui_upload_textures(owner, draw_data) {
		return EZ_GFX_C_RESULT_NATIVE_FAILURE
	}

	if draw_data.cmd_lists_count <= 0 || draw_data.total_vtx_count <= 0 || draw_data.total_idx_count <= 0 {
		if !ez_gfx_begin_render(&surface.surface) do return EZ_GFX_C_RESULT_NOT_READY
		return ez_gfx_c_result(ez_gfx_finish_render())
	}

	total_vtx := int(draw_data.total_vtx_count)
	total_idx := int(draw_data.total_idx_count)
	total_cmds := 0
	cmd_lists := mem.slice_ptr(draw_data.cmd_lists.data, int(draw_data.cmd_lists_count))
	for cmd_list in cmd_lists {
		if cmd_list == nil do continue
		for cmd in mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size)) {
			if cmd.user_callback == nil do total_cmds += 1
		}
	}
	if total_cmds == 0 do return EZ_GFX_C_RESULT_NATIVE_FAILURE

	vertices := make([]Ez_Gfx_C_ImGui_Vertex, total_vtx)
	indices := make([]u32, total_idx)
	commands := make([]Ez_Gfx_C_ImGui_Draw_Command, total_cmds)
	defer delete(vertices)
	defer delete(indices)
	defer delete(commands)

	display_pos := draw_data.display_pos
	framebuffer_scale := draw_data.framebuffer_scale
	vtx_offset := 0
	idx_offset := 0
	cmd_offset := 0
	for cmd_list in cmd_lists {
		if cmd_list == nil do continue
		vtx := mem.slice_ptr(cmd_list.vtx_buffer.data, int(cmd_list.vtx_buffer.size))
		for vertex_index in 0 ..< len(vtx) {
			source := vtx[vertex_index]
			destination := &vertices[vtx_offset + vertex_index]
			destination.pos = {
				(source.pos.x - display_pos.x) * framebuffer_scale.x,
				(source.pos.y - display_pos.y) * framebuffer_scale.y,
			}
			destination.uv = source.uv
			destination.col = source.col
		}

		idx := mem.slice_ptr(cmd_list.idx_buffer.data, int(cmd_list.idx_buffer.size))
		for index_index in 0 ..< len(idx) {
			indices[idx_offset + index_index] = u32(idx[index_index])
		}

		cmds := mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size))
		for source_index in 0 ..< len(cmds) {
			source := &cmds[source_index]
			if source.user_callback != nil do continue
			destination := &commands[cmd_offset]
			clip := source.clip_rect
			destination.clip_rect = {
				(clip.x - display_pos.x) * framebuffer_scale.x,
				(clip.y - display_pos.y) * framebuffer_scale.y,
				(clip.z - display_pos.x) * framebuffer_scale.x,
				(clip.w - display_pos.y) * framebuffer_scale.y,
			}
			destination.texture_id = u32(im.draw_cmd_get_tex_id(source))
			destination.idx_offset = u32(idx_offset) + source.idx_offset
			destination.vtx_offset = u32(vtx_offset) + source.vtx_offset
			cmd_offset += 1
		}
		vtx_offset += len(vtx)
		idx_offset += len(idx)
	}

	if !ez_gfx_begin_render(&surface.surface) do return EZ_GFX_C_RESULT_NOT_READY
	vertex_buffer := ez_gfx_render_acquire_structured_buffer(Ez_Gfx_C_ImGui_Vertex, u32(total_vtx), "imgui vertices")
	index_buffer := ez_gfx_render_acquire_structured_buffer(u32, u32(total_idx), "imgui indices")
	command_buffer := ez_gfx_render_acquire_structured_buffer(Ez_Gfx_C_ImGui_Draw_Command, u32(total_cmds), "imgui draw commands")
	if !vertex_buffer.handle.ok || !index_buffer.handle.ok || !command_buffer.handle.ok {
		ez_gfx_current_render = {}
		return EZ_GFX_C_RESULT_NOT_READY
	}
	mem.copy(vertex_buffer.elements, raw_data(vertices), len(vertices) * size_of(Ez_Gfx_C_ImGui_Vertex))
	mem.copy(index_buffer.elements, raw_data(indices), len(indices) * size_of(u32))
	mem.copy(command_buffer.elements, raw_data(commands), len(commands) * size_of(Ez_Gfx_C_ImGui_Draw_Command))

	indirect := ez_gfx_render_acquire_indirect_buffer(vk.DrawIndexedIndirectCommand, u32(total_cmds), "imgui indirect draws")
	if !indirect.ok {
		ez_gfx_current_render = {}
		return EZ_GFX_C_RESULT_NOT_READY
	}
	bindings := [3]Ez_Gfx_Render_Binding {
		{name = "imgui_vertices", structured = vertex_buffer.handle},
		{name = "imgui_indices", structured = index_buffer.handle},
		{name = "imgui_commands", structured = command_buffer.handle},
	}
	push := Ez_Gfx_C_ImGui_Push_Constants{display_size = {
		draw_data.display_size.x * draw_data.framebuffer_scale.x,
		draw_data.display_size.y * draw_data.framebuffer_scale.y,
	}}
	pipeline := ez_gfx_render_add_vertex_pipeline_impl(
		&owner.imgui_shader,
		indirect,
		bindings[:],
		{blend_mode = .Alpha},
		&push,
		u32(size_of(push)),
	)
	if !pipeline.ok {
		ez_gfx_current_render = {}
		return EZ_GFX_C_RESULT_NATIVE_FAILURE
	}

	active_command := 0
	for cmd_list in cmd_lists {
		if cmd_list == nil do continue
		cmds := mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size))
		for source_index in 0 ..< len(cmds) {
			source := &cmds[source_index]
			if source.user_callback != nil do continue
			draw := vk.DrawIndexedIndirectCommand {
				indexCount = source.elem_count,
				instanceCount = 1,
				firstIndex = owner.imgui_identity_index_start,
				vertexOffset = 0,
				firstInstance = u32(active_command),
			}
			if !ez_gfx_indirect_buffer_write_draw(&indirect, u32(active_command), draw) {
				ez_gfx_current_render = {}
				return EZ_GFX_C_RESULT_NATIVE_FAILURE
			}
			active_command += 1
		}
	}
	if !ez_gfx_indirect_buffer_set_draw_count(&indirect, u32(active_command)) {
		ez_gfx_current_render = {}
		return EZ_GFX_C_RESULT_NATIVE_FAILURE
	}
	return ez_gfx_c_result(ez_gfx_finish_render())
}
