#+private
package ez_gfx

import "base:runtime"
import "core:mem"
import im "../vendor/odin-imgui"
import vk "vendor:vulkan"

// C ABI ImGui push-constant layout.
Ez_Gfx_C_ImGui_Push_Constants :: struct {
	display_size: [2]f32,
}

// C ABI ImGui vertex layout.
Ez_Gfx_C_ImGui_Vertex :: struct {
	pos:   im.Vec2,
	uv:    im.Vec2,
	col:   u32,
	_pad0: u32,
	_pad1: u32,
	_pad2: u32,
}

// C ABI ImGui indirect command layout.
Ez_Gfx_C_ImGui_Draw_Command :: struct {
	clip_rect:  [4]f32,
	texture_id: u64,
	idx_offset: u32,
	vtx_offset: u32,
}

@(private)
IMGUI_C_SHADER_PATH :: cstring("examples/4_imgui/imgui.slang")
@(private)
IMGUI_C_IDENTITY_INDEX_COUNT :: 65536

@(private)
c_imgui_context :: proc(ctx: ^Ez_Gfx_Ctx) -> ^im.Context {
	if ctx == nil || ctx.imgui_context == nil do return nil
	return cast(^im.Context)ctx.imgui_context
}

@(private)
c_imgui_init :: proc(context_handle: Ez_Gfx_Context_Handle, ctx: ^Ez_Gfx_Ctx) -> bool {
	if ctx == nil do return false
	if ctx.imgui_context != nil {
		im.set_current_context(c_imgui_context(ctx))
		return true
	}
	imgui_ctx := im.create_context()
	if imgui_ctx == nil do return false
	ctx.imgui_context = imgui_ctx
	im.set_current_context(imgui_ctx)
	im.CHECKVERSION()
	io := im.get_io()
	io.ini_filename = nil
	io.backend_flags += {.Renderer_Has_Textures}
	io.display_framebuffer_scale = {1, 1}
	io.delta_time = 1.0 / 60.0
	shader_handle, shader_status := ez_gfx_shader_create(context_handle, {
		path = IMGUI_C_SHADER_PATH,
		vertex_entry = EZ_GFX_INTERNAL_DEFAULT_VERTEX_ENTRY,
		fragment_entry = EZ_GFX_INTERNAL_DEFAULT_FRAGMENT_ENTRY,
	})
	if shader_status != .Ok {
		im.destroy_context(imgui_ctx)
		ctx.imgui_context = nil
		return false
	}
	ctx.imgui_shader = shader_handle
	ctx.imgui_shader_loaded = true
	indices := make([]u32, IMGUI_C_IDENTITY_INDEX_COUNT)
	defer delete(indices)
	for index in 0 ..< IMGUI_C_IDENTITY_INDEX_COUNT do indices[index] = u32(index)
	allocation, ok := vertex_manager_schedule_upload(&ctx.vertex_manager, .Indices, "", &ctx.vertex_manager.index_heap, raw_data(indices), IMGUI_C_IDENTITY_INDEX_COUNT, vk.DeviceSize(size_of(u32)))
	if !ok {
		_ = ez_gfx_shader_release(context_handle, ctx.imgui_shader)
		ctx.imgui_shader_loaded = false
		im.destroy_context(imgui_ctx)
		ctx.imgui_context = nil
		return false
	}
	ctx.imgui_identity_index_start = allocation.start_index
	ctx.imgui_identity_index_loaded = true
	return true
}

@(private)
c_imgui_upload_textures :: proc(context_handle: Ez_Gfx_Context_Handle, ctx: ^Ez_Gfx_Ctx, draw_data: ^im.Draw_Data) -> bool {
	if ctx == nil || draw_data == nil || draw_data.textures == nil do return true
	textures := draw_data.textures^
	for texture in mem.slice_ptr(textures.data, int(textures.size)) {
		if texture == nil do continue
		#partial switch texture.status {
		case .Want_Create, .Want_Updates:
			byte_count := int(im.texture_data_get_size_in_bytes(texture))
			pixels := im.texture_data_get_pixels(texture)
			if pixels == nil || byte_count <= 0 do return false
			if ctx.imgui_font_texture_loaded {
				ctx_wait_idle()
				_ = ez_gfx_texture_unload(context_handle, ctx.imgui_font_texture)
				ctx.imgui_font_texture_loaded = false
			}
			pixel_data := make([]u8, byte_count)
			mem.copy(raw_data(pixel_data), pixels, byte_count)
			append(&ctx.imgui_texture_data, pixel_data)
			ctx.imgui_font_atlas_pixels = pixel_data
			regions := [1]Ez_Gfx_Texture_Memory_Region{{data = pixel_data}}
			texture_desc := Ez_Gfx_Load_Texture_Desc{
				source_format = .RGBA,
				destination_format = .R8G8B8A8_UNORM,
				width = u32(texture.width),
				height = u32(texture.height),
				generate_mips = false,
				min_filter = .Linear,
				mag_filter = .Linear,
				address_mode_u = .Clamp_To_Edge,
				address_mode_v = .Clamp_To_Edge,
				address_mode_w = .Clamp_To_Edge,
				debug_label = "imgui font atlas",
			}
			texture_handle, texture_error := ez_gfx_texture_load(context_handle, regions[:], texture_desc)
			if texture_error != .None do return false
			binding_index, binding_error := ez_gfx_texture_binding_index(context_handle, texture_handle)
			if binding_error != .None {
				_ = ez_gfx_texture_unload(context_handle, texture_handle)
				return false
			}
			ctx.imgui_font_texture = texture_handle
			ctx.imgui_font_texture_loaded = true
			im.texture_data_set_tex_id(texture, im.Texture_ID(binding_index))
			im.texture_data_set_status(texture, .OK)
		case .Want_Destroy:
			if ctx.imgui_font_texture_loaded {
				ctx_wait_idle()
				_ = ez_gfx_texture_unload(context_handle, ctx.imgui_font_texture)
				ctx.imgui_font_texture = 0
				ctx.imgui_font_texture_loaded = false
			}
			im.texture_data_set_status(texture, .Destroyed)
		}
	}
	return true
}

@(private)
c_imgui_destroy :: proc(context_handle: Ez_Gfx_Context_Handle, ctx: ^Ez_Gfx_Ctx) {
	if ctx == nil do return
	if ctx.imgui_context != nil do im.set_current_context(c_imgui_context(ctx))
	if ctx.imgui_font_texture_loaded {
		ctx_wait_idle()
		_ = ez_gfx_texture_unload(context_handle, ctx.imgui_font_texture)
		ctx.imgui_font_texture_loaded = false
	}
	if ctx.imgui_shader_loaded {
		ctx_wait_idle()
		_ = ez_gfx_shader_release(context_handle, ctx.imgui_shader)
		ctx.imgui_shader_loaded = false
	}
	if ctx.imgui_context != nil {
		im.destroy_context(c_imgui_context(ctx))
		ctx.imgui_context = nil
	}
	ctx.imgui_font_texture = 0
	ctx.imgui_font_atlas_pixels = nil
	ctx.imgui_identity_index_start = 0
	ctx.imgui_identity_index_loaded = false
}

imgui_destroy :: proc(context_handle: Ez_Gfx_Context_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	c_imgui_destroy(context_handle, ctx)
	return .Ok
}

imgui_render_demo :: proc(context_handle: Ez_Gfx_Context_Handle, surface_handle: Ez_Gfx_Surface_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	surface, surface_status := resolve_surface(ctx, surface_handle)
	if surface_status != .Ok do return surface_status
	if !c_imgui_init(context_handle, ctx) do return .Native_Failure
	width, height := window_get_framebuffer_size(surface)
	if width <= 0 || height <= 0 do return .Not_Ready
	im.set_current_context(c_imgui_context(ctx))
	io := im.get_io()
	io.display_size = {f32(width), f32(height)}
	im.new_frame()
	im.show_demo_window(nil)
	im.render()
	draw_data := im.get_draw_data()
	if draw_data == nil || !draw_data.valid do return .Native_Failure
	if !c_imgui_upload_textures(context_handle, ctx, draw_data) do return .Native_Failure
	if draw_data.cmd_lists_count <= 0 || draw_data.total_vtx_count <= 0 || draw_data.total_idx_count <= 0 {
		if begin_status := api_begin_render(surface); begin_status != .Ok do return begin_status
		return api_finish_render()
	}
	total_vtx := int(draw_data.total_vtx_count)
	total_idx := int(draw_data.total_idx_count)
	total_cmds := 0
	cmd_lists := mem.slice_ptr(draw_data.cmd_lists.data, int(draw_data.cmd_lists_count))
	for cmd_list in cmd_lists {
		if cmd_list == nil do continue
		for cmd in mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size)) do if cmd.user_callback == nil do total_cmds += 1
	}
	if total_cmds == 0 do return .Native_Failure
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
			destination.pos = {(source.pos.x - display_pos.x) * framebuffer_scale.x, (source.pos.y - display_pos.y) * framebuffer_scale.y}
			destination.uv = source.uv
			destination.col = source.col
		}
		idx := mem.slice_ptr(cmd_list.idx_buffer.data, int(cmd_list.idx_buffer.size))
		for index_index in 0 ..< len(idx) do indices[idx_offset + index_index] = u32(idx[index_index])
		cmds := mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size))
		for source_index in 0 ..< len(cmds) {
			source := &cmds[source_index]
			if source.user_callback != nil do continue
			destination := &commands[cmd_offset]
			clip := source.clip_rect
			destination.clip_rect = {(clip.x - display_pos.x) * framebuffer_scale.x, (clip.y - display_pos.y) * framebuffer_scale.y, (clip.z - display_pos.x) * framebuffer_scale.x, (clip.w - display_pos.y) * framebuffer_scale.y}
			destination.texture_id = u64(im.draw_cmd_get_tex_id(source))
			destination.idx_offset = u32(idx_offset) + source.idx_offset
			destination.vtx_offset = u32(vtx_offset) + source.vtx_offset
			cmd_offset += 1
		}
		vtx_offset += len(vtx)
		idx_offset += len(idx)
	}
	if begin_status := api_begin_render(surface); begin_status != .Ok do return begin_status
	vertex_buffer, vertex_status := api_render_acquire_structured_buffer(Ez_Gfx_C_ImGui_Vertex, u32(total_vtx), "imgui vertices")
	if vertex_status != .Ok { get_current_ctx().render = {}; return vertex_status }
	index_buffer, index_status := api_render_acquire_structured_buffer(u32, u32(total_idx), "imgui indices")
	if index_status != .Ok { get_current_ctx().render = {}; return index_status }
	command_buffer, command_status := api_render_acquire_structured_buffer(Ez_Gfx_C_ImGui_Draw_Command, u32(total_cmds), "imgui draw commands")
	if command_status != .Ok { get_current_ctx().render = {}; return command_status }
	mem.copy(vertex_buffer.elements, raw_data(vertices), len(vertices) * size_of(Ez_Gfx_C_ImGui_Vertex))
	mem.copy(index_buffer.elements, raw_data(indices), len(indices) * size_of(u32))
	mem.copy(command_buffer.elements, raw_data(commands), len(commands) * size_of(Ez_Gfx_C_ImGui_Draw_Command))
	indirect, indirect_status := api_render_acquire_indirect_buffer(vk.DrawIndexedIndirectCommand, u32(total_cmds), "imgui indirect draws")
	if indirect_status != .Ok { get_current_ctx().render = {}; return indirect_status }
	bindings := [3]Ez_Gfx_Render_Binding{{name = "imgui_vertices", structured = vertex_buffer.handle}, {name = "imgui_indices", structured = index_buffer.handle}, {name = "imgui_commands", structured = command_buffer.handle}}
	push := Ez_Gfx_C_ImGui_Push_Constants{display_size = {draw_data.display_size.x * draw_data.framebuffer_scale.x, draw_data.display_size.y * draw_data.framebuffer_scale.y}}
	shader, shader_status := resolve_shader(ctx, ctx.imgui_shader)
	if shader_status != .Ok { get_current_ctx().render = {}; return shader_status }
	_, pipeline_status := api_render_add_vertex_pipeline_raw(shader, indirect, bindings[:], {blend_mode = .Alpha}, &push, u32(size_of(Ez_Gfx_C_ImGui_Push_Constants)))
	if pipeline_status != .Ok { get_current_ctx().render = {}; return pipeline_status }
	active_command := 0
	for cmd_list in cmd_lists {
		if cmd_list == nil do continue
		cmds := mem.slice_ptr(cmd_list.cmd_buffer.data, int(cmd_list.cmd_buffer.size))
		for source_index in 0 ..< len(cmds) {
			source := &cmds[source_index]
			if source.user_callback != nil do continue
			draw := vk.DrawIndexedIndirectCommand{indexCount = source.elem_count, instanceCount = 1, firstIndex = ctx.imgui_identity_index_start, vertexOffset = 0, firstInstance = u32(active_command)}
			if draw_status := api_indirect_buffer_write_draw(&indirect, u32(active_command), draw); draw_status != .Ok { get_current_ctx().render = {}; return draw_status }
			active_command += 1
		}
	}
	if count_status := api_indirect_buffer_set_draw_count(&indirect, u32(active_command)); count_status != .Ok { get_current_ctx().render = {}; return count_status }
	return api_finish_render()
}
