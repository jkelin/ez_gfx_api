package ez_gfx

import ga "./generational_arena"
import "base:runtime"
import "core:c"
import "core:mem"
import vk "vendor:vulkan"

Ez_Gfx_C_Context_Desc :: struct {
	enable_debug:      i32,
	enable_validation: i32,
	surface_platform:  u32,
}

Ez_Gfx_C_Surface_Desc :: struct {
	window:  rawptr,
	display: rawptr,
	platform: u32,
	width:   u32,
	height:  u32,
}

Ez_Gfx_C_Shader_Desc :: struct {
	path:           cstring,
	vertex_entry:   cstring,
	fragment_entry: cstring,
	compute_entry:  cstring,
	kind:           u32,
}

Ez_Gfx_C_Texture_Desc :: struct {
	source_format:      u32,
	destination_format: u32,
	width:              u32,
	height:             u32,
	mip_count:          u32,
	generate_mips:      i32,
	min_filter:         u32,
	mag_filter:         u32,
	max_anisotropy:     f32,
	address_mode_u:     u32,
	address_mode_v:     u32,
	address_mode_w:     u32,
	debug_label:        cstring,
}

Ez_Gfx_C_Binding :: struct {
	name:       cstring,
	structured: u64,
	indirect:   u64,
}

Ez_Gfx_C_Dynamic_State :: struct {
	cull_mode:      u32,
	front_face:     u32,
	primitive_type: u32,
	blend_mode:     u32,
}

Ez_Gfx_C_Draw_Indexed_Command :: struct {
	index_count:    u32,
	instance_count: u32,
	first_index:    u32,
	vertex_offset:  i32,
	first_instance: u32,
}

EZ_GFX_C_ABI_VERSION :: u32(7)
EZ_GFX_C_RESULT_OK :: i32(0)
EZ_GFX_C_RESULT_INVALID_ARGUMENT :: i32(1)
EZ_GFX_C_RESULT_INVALID_CONTEXT :: i32(2)
EZ_GFX_C_RESULT_NATIVE_FAILURE :: i32(3)
EZ_GFX_C_RESULT_NOT_READY :: i32(4)

@(private)
EZ_GFX_C_MAX_BINDINGS :: EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS

@(private)
c_status :: proc(status: Ez_Gfx_Status) -> i32 {
	switch status {
	case .Ok:
		return EZ_GFX_C_RESULT_OK
	case .Invalid_Argument:
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	case .Invalid_Context:
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	case .Native_Failure:
		return EZ_GFX_C_RESULT_NATIVE_FAILURE
	case .Not_Ready:
		return EZ_GFX_C_RESULT_NOT_READY
	}
	return EZ_GFX_C_RESULT_NATIVE_FAILURE
}

@(private)
c_context_for_handle :: proc "c" (context_handle: u64) -> (odin_context: runtime.Context, ctx: ^Ez_Gfx_Ctx, status: i32) {
	odin_context = runtime.default_context()
	context = odin_context
	resolved_ctx, odin_status := resolve_context(Ez_Gfx_Context_Handle(context_handle))
	if odin_status != .Ok do return odin_context, nil, c_status(odin_status)
	odin_context.user_ptr = resolved_ctx
	return odin_context, resolved_ctx, EZ_GFX_C_RESULT_OK
}

@(private)
c_build_dynamic_state :: proc(state: ^Ez_Gfx_C_Dynamic_State) -> (render_state: Ez_Gfx_Render_Dynamic_State, ok: bool) {
	if state == nil do return render_state, true
	if state.cull_mode > 3 || state.front_face > 1 do return render_state, false
	if state.primitive_type >= u32(len(Ez_Gfx_Primitive_Type)) || state.blend_mode > u32(Ez_Gfx_Blend_Mode.Alpha) do return render_state, false
	switch state.cull_mode {
	case 0:
		render_state.cull_mode = {}
	case 1:
		render_state.cull_mode = {.FRONT}
	case 2:
		render_state.cull_mode = {.BACK}
	case 3:
		render_state.cull_mode = {.FRONT, .BACK}
	}
	if state.front_face == 0 {
		render_state.front_face = .COUNTER_CLOCKWISE
	} else {
		render_state.front_face = .CLOCKWISE
	}
	render_state.primitive_type = Ez_Gfx_Primitive_Type(state.primitive_type)
	render_state.blend_mode = Ez_Gfx_Blend_Mode(state.blend_mode)
	return render_state, true
}

@(private)
c_copy_bindings :: proc(source: [^]Ez_Gfx_C_Binding, count: u32, ctx: ^Ez_Gfx_Ctx, destination: ^[EZ_GFX_C_MAX_BINDINGS]Ez_Gfx_Render_Binding) -> bool {
	if count > EZ_GFX_C_MAX_BINDINGS do return false
	if count > 0 && source == nil do return false
	for i in 0 ..< int(count) {
		c_binding := source[i]
		binding := &destination[i]
		binding^ = {}
		if c_binding.name == nil do return false
		binding.name = c_binding.name
		if c_binding.structured != 0 {
			structured, status := resolve_structured(ctx, Ez_Gfx_Structured_Handle(c_binding.structured))
			if status != .Ok || structured == nil || !structured.ok do return false
			binding.structured = structured^
		}
		if c_binding.indirect != 0 {
			indirect, status := resolve_indirect(ctx, Ez_Gfx_Indirect_Handle(c_binding.indirect))
			if status != .Ok || indirect == nil || !indirect.ok do return false
			binding.indirect = indirect^
		}
	}
	return true
}

@(private)
c_clone_cstring :: proc(value: cstring) -> []u8 {
	if value == nil do return nil
	source := shader_cstring_to_string(value)
	bytes := make([]u8, len(source) + 1)
	if len(source) > 0 do mem.copy(raw_data(bytes), raw_data(source), len(source))
	bytes[len(source)] = 0
	return bytes
}

@(private)
c_shader_string :: proc(bytes: []u8) -> cstring {
	if len(bytes) == 0 do return nil
	return cast(cstring)raw_data(bytes)
}

@(link_name="ez_gfx_c_abi_version")
@(export)
ez_gfx_c_abi_version :: proc "c" () -> u32 {
	return EZ_GFX_C_ABI_VERSION
}

@(link_name="ez_gfx_c_context_create")
@(export)
ez_gfx_c_context_create :: proc "c" (desc: ^Ez_Gfx_C_Context_Desc, out_context: ^u64) -> i32 {
	context = runtime.default_context()
	if out_context == nil || desc == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_context^ = 0
	odin_desc := Ez_Gfx_Ctx_Desc{
		enable_debug = desc.enable_debug != 0,
		enable_validation = desc.enable_validation != 0,
		surface_platform = desc.surface_platform,
	}
	handle, status := ez_gfx_context_create(odin_desc)
	if status != .Ok do return c_status(status)
	out_context^ = u64(handle)
	return EZ_GFX_C_RESULT_OK
}

@(link_name="ez_gfx_c_context_wait_idle")
@(export)
ez_gfx_c_context_wait_idle :: proc "c" (context_handle: u64) -> i32 {
	context = runtime.default_context()
	return c_status(ez_gfx_context_wait_idle(Ez_Gfx_Context_Handle(context_handle)))
}

@(link_name="ez_gfx_c_context_destroy")
@(export)
ez_gfx_c_context_destroy :: proc "c" (context_handle: u64) {
	context = runtime.default_context()
	_ = ez_gfx_imgui_destroy(Ez_Gfx_Context_Handle(context_handle))
	_ = ez_gfx_context_destroy(Ez_Gfx_Context_Handle(context_handle))
}

@(link_name="ez_gfx_c_surface_create")
@(export)
ez_gfx_c_surface_create :: proc "c" (desc: ^Ez_Gfx_C_Surface_Desc, out_surface: ^u64, context_handle: u64) -> i32 {
	context = runtime.default_context()
	if out_surface == nil || desc == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_surface^ = 0
	surface_desc := Ez_Gfx_Surface_Desc{
		native_window = desc.window,
		native_display = desc.display,
		platform = desc.platform,
		width = desc.width,
		height = desc.height,
	}
	handle, status := ez_gfx_surface_create(Ez_Gfx_Context_Handle(context_handle), surface_desc)
	if status != .Ok do return c_status(status)
	out_surface^ = u64(handle)
	return EZ_GFX_C_RESULT_OK
}

@(link_name="ez_gfx_c_context_init_device")
@(export)
ez_gfx_c_context_init_device :: proc "c" (surface_handle: u64, context_handle: u64) -> i32 {
	context = runtime.default_context()
	return c_status(ez_gfx_surface_init_device(Ez_Gfx_Context_Handle(context_handle), Ez_Gfx_Surface_Handle(surface_handle)))
}

@(link_name="ez_gfx_c_surface_resize")
@(export)
ez_gfx_c_surface_resize :: proc "c" (surface_handle: u64, width, height: u32, context_handle: u64) -> i32 {
	context = runtime.default_context()
	return c_status(ez_gfx_surface_resize(Ez_Gfx_Context_Handle(context_handle), Ez_Gfx_Surface_Handle(surface_handle), width, height))
}

@(link_name="ez_gfx_c_surface_get_extent")
@(export)
ez_gfx_c_surface_get_extent :: proc "c" (surface_handle: u64, out_width, out_height: ^u32, context_handle: u64) -> i32 {
	context = runtime.default_context()
	if out_width == nil || out_height == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_width^ = 0
	out_height^ = 0
	width, height, status := ez_gfx_surface_get_extent(Ez_Gfx_Context_Handle(context_handle), Ez_Gfx_Surface_Handle(surface_handle))
	out_width^ = width
	out_height^ = height
	return c_status(status)
}

@(link_name="ez_gfx_c_surface_resize_pending")
@(export)
ez_gfx_c_surface_resize_pending :: proc "c" (surface_handle: u64, out_pending: ^i32, context_handle: u64) -> i32 {
	context = runtime.default_context()
	if out_pending == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_pending^ = 0
	pending, status := ez_gfx_surface_resize_pending(Ez_Gfx_Context_Handle(context_handle), Ez_Gfx_Surface_Handle(surface_handle))
	out_pending^ = i32(pending)
	return c_status(status)
}

@(link_name="ez_gfx_c_surface_set_snapshot_cache")
@(export)
ez_gfx_c_surface_set_snapshot_cache :: proc "c" (surface_handle: u64, enabled: i32, context_handle: u64) -> i32 {
	context = runtime.default_context()
	if enabled != 0 && enabled != 1 do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	return c_status(ez_gfx_surface_set_snapshot_cache(Ez_Gfx_Context_Handle(context_handle), Ez_Gfx_Surface_Handle(surface_handle), enabled != 0))
}

@(link_name="ez_gfx_c_surface_destroy")
@(export)
ez_gfx_c_surface_destroy :: proc "c" (surface_handle: u64, context_handle: u64) {
	context = runtime.default_context()
	_ = ez_gfx_surface_destroy(Ez_Gfx_Context_Handle(context_handle), Ez_Gfx_Surface_Handle(surface_handle))
}

@(link_name="ez_gfx_c_shader_compile")
@(export)
ez_gfx_c_shader_compile :: proc "c" (desc: ^Ez_Gfx_C_Shader_Desc, out_shader: ^u64, context_handle: u64) -> i32 {
	c_context, ctx, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return context_status
	if out_shader == nil || desc == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_shader^ = 0
	if desc.kind > u32(Ez_Gfx_Shader_Kind.Compute) do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	context = c_context
	strings := [4][]u8{c_clone_cstring(desc.path), c_clone_cstring(desc.vertex_entry), c_clone_cstring(desc.fragment_entry), c_clone_cstring(desc.compute_entry)}
	odin_desc := Ez_Gfx_Shader_Desc{path = c_shader_string(strings[0]), vertex_entry = c_shader_string(strings[1]), fragment_entry = c_shader_string(strings[2]), compute_entry = c_shader_string(strings[3]), kind = Ez_Gfx_Shader_Kind(desc.kind)}
	handle, status := ez_gfx_shader_create(Ez_Gfx_Context_Handle(context_handle), odin_desc)
	if status != .Ok {
		for bytes in strings do if raw_data(bytes) != nil do delete(bytes)
		return c_status(status)
	}
	for bytes in strings do if raw_data(bytes) != nil do append(&ctx.c_texture_data, bytes)
	out_shader^ = u64(handle)
	return EZ_GFX_C_RESULT_OK
}

@(link_name="ez_gfx_c_shader_destroy")
@(export)
ez_gfx_c_shader_destroy :: proc "c" (shader_handle: u64, context_handle: u64) {
	context = runtime.default_context()
	_ = ez_gfx_shader_release(Ez_Gfx_Context_Handle(context_handle), Ez_Gfx_Shader_Handle(shader_handle))
}

@(link_name="ez_gfx_c_vertex_heap_create")
@(export)
ez_gfx_c_vertex_heap_create :: proc "c" (name: cstring, capacity, stride: u64, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	return c_status(ez_gfx_vertex_manager_add_heap(&ctx.vertex_manager, shader_cstring_to_string(name), vk.DeviceSize(capacity), vk.DeviceSize(stride)))
}

@(link_name="ez_gfx_c_index_heap_create")
@(export)
ez_gfx_c_index_heap_create :: proc "c" (capacity: u64, debug_name: cstring, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	return c_status(ez_gfx_gpu_heap_create(&ctx.vertex_manager.index_heap, vk.DeviceSize(capacity), vk.DeviceSize(size_of(u32)), {.INDEX_BUFFER}, debug_name))
}

@(link_name="ez_gfx_c_vertex_upload_indices")
@(export)
ez_gfx_c_vertex_upload_indices :: proc "c" (data: rawptr, count: u32, out_start_index: ^u32, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	if out_start_index == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_start_index^ = 0
	context = c_context
	start_index, odin_status := ez_gfx_vertex_manager_upload_indices_raw(&ctx.vertex_manager, data, count)
	out_start_index^ = start_index
	return c_status(odin_status)
}

@(link_name="ez_gfx_c_vertex_upload")
@(export)
ez_gfx_c_vertex_upload :: proc "c" (heap_name: cstring, data: rawptr, element_count: u32, element_size: u64, out_start_index: ^u32, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	if out_start_index == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_start_index^ = 0
	context = c_context
	start_index, odin_status := ez_gfx_vertex_manager_upload_raw(&ctx.vertex_manager, shader_cstring_to_string(heap_name), data, element_count, vk.DeviceSize(element_size))
	out_start_index^ = start_index
	return c_status(odin_status)
}

@(link_name="ez_gfx_c_enable_all_decoders")
@(export)
ez_gfx_c_enable_all_decoders :: proc "c" (context_handle: u64) -> i32 {
	c_context, _, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	return c_status(ez_gfx_enable_all_decoders())
}

@(link_name="ez_gfx_c_texture_load")
@(export)
ez_gfx_c_texture_load :: proc "c" (data: rawptr, data_size: u64, desc: ^Ez_Gfx_C_Texture_Desc, out_texture: ^u64, context_handle: u64) -> i32 {
	c_context, ctx, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return i32(Ez_Gfx_Texture_Error.Invalid_Context)
	if out_texture == nil do return i32(Ez_Gfx_Texture_Error.Invalid_Arguments)
	out_texture^ = 0
	if data == nil || data_size == 0 || data_size > u64(max(int)) || desc == nil || desc.destination_format != 0 do return i32(Ez_Gfx_Texture_Error.Invalid_Arguments)
	context = c_context
	owned_data := make([]u8, int(data_size))
	mem.copy(raw_data(owned_data), data, int(data_size))
	regions := [1]Ez_Gfx_Texture_Memory_Region{{data = owned_data}}
	handle, err := ez_gfx_texture_load(Ez_Gfx_Context_Handle(context_handle), regions[:], texture_load_desc_from_c(desc))
	if err != .None {
		delete(owned_data)
		return i32(err)
	}
	append(&ctx.c_texture_data, owned_data)
	out_texture^ = u64(handle)
	return i32(err)
}

@(link_name="ez_gfx_c_texture_binding_index")
@(export)
ez_gfx_c_texture_binding_index :: proc "c" (texture_handle: u64, out_binding_index: ^u32, context_handle: u64) -> i32 {
	c_context, _, context_status := c_context_for_handle(context_handle)
	if context_status != EZ_GFX_C_RESULT_OK do return i32(Ez_Gfx_Texture_Error.Invalid_Context)
	if out_binding_index == nil do return i32(Ez_Gfx_Texture_Error.Invalid_Arguments)
	out_binding_index^ = 0
	context = c_context
	binding_index, err := ez_gfx_texture_binding_index(
		Ez_Gfx_Context_Handle(context_handle),
		Ez_Gfx_Texture_Handle(texture_handle),
	)
	if err != .None do return i32(err)
	out_binding_index^ = binding_index
	return i32(err)
}

@(link_name="ez_gfx_c_texture_unload")
@(export)
ez_gfx_c_texture_unload :: proc "c" (texture_handle: u64, context_handle: u64) -> i32 {
	context = runtime.default_context()
	return i32(ez_gfx_texture_unload(Ez_Gfx_Context_Handle(context_handle), Ez_Gfx_Texture_Handle(texture_handle)))
}

@(link_name="ez_gfx_c_begin_render")
@(export)
ez_gfx_c_begin_render :: proc "c" (surface_handle: u64, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	surface, surface_status := resolve_surface(ctx, Ez_Gfx_Surface_Handle(surface_handle))
	if surface_status != .Ok do return c_status(surface_status)
	return c_status(ez_gfx_begin_render(surface))
}

@(link_name="ez_gfx_c_acquire_indirect")
@(export)
ez_gfx_c_acquire_indirect :: proc "c" (capacity: u32, debug_name: cstring, out_indirect: ^u64, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	if out_indirect == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_indirect^ = 0
	context = c_context
	internal, odin_status := ez_gfx_render_acquire_indirect_buffer(vk.DrawIndexedIndirectCommand, capacity, debug_name)
	if odin_status != .Ok do return c_status(odin_status)
	local, err := ga.insert(&ctx.indirect_arena, internal)
	if err != .None do return EZ_GFX_C_RESULT_NATIVE_FAILURE
	packed, pack_status := pack_child_handle(ctx, .Indirect, local)
	if pack_status != .Ok { _ = ga.remove(&ctx.indirect_arena, local); return c_status(pack_status) }
	out_indirect^ = packed
	return EZ_GFX_C_RESULT_OK
}

@(link_name="ez_gfx_c_indirect_write_draw")
@(export)
ez_gfx_c_indirect_write_draw :: proc "c" (indirect_handle: u64, index: u32, command: ^Ez_Gfx_C_Draw_Indexed_Command, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	if command == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	context = c_context
	indirect, indirect_status := resolve_indirect(ctx, Ez_Gfx_Indirect_Handle(indirect_handle))
	if indirect_status != .Ok do return c_status(indirect_status)
	odin_command := vk.DrawIndexedIndirectCommand{indexCount = command.index_count, instanceCount = command.instance_count, firstIndex = command.first_index, vertexOffset = command.vertex_offset, firstInstance = command.first_instance}
	return c_status(ez_gfx_indirect_buffer_write_draw(indirect, index, odin_command))
}

@(link_name="ez_gfx_c_indirect_set_draw_count")
@(export)
ez_gfx_c_indirect_set_draw_count :: proc "c" (indirect_handle: u64, count: u32, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	indirect, indirect_status := resolve_indirect(ctx, Ez_Gfx_Indirect_Handle(indirect_handle))
	if indirect_status != .Ok do return c_status(indirect_status)
	return c_status(ez_gfx_indirect_buffer_set_draw_count(indirect, count))
}

@(link_name="ez_gfx_c_indirect_release")
@(export)
ez_gfx_c_indirect_release :: proc "c" (indirect_handle: u64, context_handle: u64) {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return
	context = c_context
	local, identity_status := remove_child_identity(ctx, indirect_handle, .Indirect)
	if identity_status != .Ok do return
	_ = ga.remove(&ctx.indirect_arena, local)
}

@(link_name="ez_gfx_c_structured_acquire")
@(export)
ez_gfx_c_structured_acquire :: proc "c" (element_size, element_count: u32, debug_name: cstring, out_structured: ^u64, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	if out_structured == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	out_structured^ = 0
	context = c_context
	internal, odin_status := ez_gfx_render_acquire_structured_buffer_bytes(element_size, element_count, debug_name)
	if odin_status != .Ok do return c_status(odin_status)
	local, err := ga.insert(&ctx.structured_arena, internal)
	if err != .None do return EZ_GFX_C_RESULT_NATIVE_FAILURE
	packed, pack_status := pack_child_handle(ctx, .Structured, local)
	if pack_status != .Ok { _ = ga.remove(&ctx.structured_arena, local); return c_status(pack_status) }
	out_structured^ = packed
	return EZ_GFX_C_RESULT_OK
}

@(link_name="ez_gfx_c_structured_write")
@(export)
ez_gfx_c_structured_write :: proc "c" (structured_handle: u64, data: rawptr, data_size: u64, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	structured, structured_status := resolve_structured(ctx, Ez_Gfx_Structured_Handle(structured_handle))
	if structured_status != .Ok do return c_status(structured_status)
	return c_status(ez_gfx_structured_buffer_write(structured, data, data_size))
}

@(link_name="ez_gfx_c_structured_release")
@(export)
ez_gfx_c_structured_release :: proc "c" (structured_handle: u64, context_handle: u64) {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return
	context = c_context
	local, identity_status := remove_child_identity(ctx, structured_handle, .Structured)
	if identity_status != .Ok do return
	_ = ga.remove(&ctx.structured_arena, local)
}

@(link_name="ez_gfx_c_render_add_vertex_pipeline")
@(export)
ez_gfx_c_render_add_vertex_pipeline :: proc "c" (shader_handle, indirect_handle: u64, bindings: [^]Ez_Gfx_C_Binding, binding_count: u32, dynamic_state: ^Ez_Gfx_C_Dynamic_State, push_constants: rawptr, push_constant_size: u32, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	shader, shader_status := resolve_shader(ctx, Ez_Gfx_Shader_Handle(shader_handle))
	indirect, indirect_status := resolve_indirect(ctx, Ez_Gfx_Indirect_Handle(indirect_handle))
	if shader_status != .Ok do return c_status(shader_status)
	if indirect_status != .Ok do return c_status(indirect_status)
	odin_bindings: [EZ_GFX_C_MAX_BINDINGS]Ez_Gfx_Render_Binding
	if !c_copy_bindings(bindings, binding_count, ctx, &odin_bindings) do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	odin_dynamic, dynamic_ok := c_build_dynamic_state(dynamic_state)
	if !dynamic_ok do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	_, odin_status := ez_gfx_render_add_vertex_pipeline_raw(shader, indirect^, odin_bindings[:int(binding_count)], odin_dynamic, push_constants, push_constant_size)
	return c_status(odin_status)
}

@(link_name="ez_gfx_c_render_add_compute_pipeline")
@(export)
ez_gfx_c_render_add_compute_pipeline :: proc "c" (shader_handle: u64, dispatch_x, dispatch_y, dispatch_z: u32, bindings: [^]Ez_Gfx_C_Binding, binding_count: u32, push_constants: rawptr, push_constant_size: u32, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	shader, shader_status := resolve_shader(ctx, Ez_Gfx_Shader_Handle(shader_handle))
	if shader_status != .Ok do return c_status(shader_status)
	odin_bindings: [EZ_GFX_C_MAX_BINDINGS]Ez_Gfx_Render_Binding
	if !c_copy_bindings(bindings, binding_count, ctx, &odin_bindings) do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	_, odin_status := ez_gfx_render_add_compute_pipeline_raw(shader, dispatch_x, dispatch_y, dispatch_z, odin_bindings[:int(binding_count)], push_constants, push_constant_size)
	return c_status(odin_status)
}

@(link_name="ez_gfx_c_finish_render")
@(export)
ez_gfx_c_finish_render :: proc "c" (context_handle: u64) -> i32 {
	c_context, _, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	return c_status(ez_gfx_finish_render())
}

@(link_name="ez_gfx_c_screenshot_save")
@(export)
ez_gfx_c_screenshot_save :: proc "c" (surface_handle: u64, path: cstring, context_handle: u64) -> i32 {
	c_context, ctx, status := c_context_for_handle(context_handle)
	if status != EZ_GFX_C_RESULT_OK do return status
	context = c_context
	surface, surface_status := resolve_surface(ctx, Ez_Gfx_Surface_Handle(surface_handle))
	if surface_status != .Ok do return c_status(surface_status)
	return c_status(ez_gfx_screenshot_save_window(surface, shader_cstring_to_string(path)))
}

