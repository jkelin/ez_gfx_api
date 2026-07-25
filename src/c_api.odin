package ez_gfx

import "base:runtime"
import "core:c"
import "core:mem"
import vk "vendor:vulkan"

EZ_GFX_C_ABI_VERSION :: u32(4)
EZ_GFX_C_RESULT_OK :: i32(0)
EZ_GFX_C_RESULT_INVALID_ARGUMENT :: i32(1)
EZ_GFX_C_RESULT_INVALID_CONTEXT :: i32(2)
EZ_GFX_C_RESULT_NATIVE_FAILURE :: i32(3)
EZ_GFX_C_RESULT_NOT_READY :: i32(4)

EZ_GFX_C_MAX_BINDINGS :: EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS

// The exported procedures below deliberately use only fixed-width C values,
// pointers, and opaque heap handles. Odin slices and Vulkan handles never cross
// this boundary. Window resources are parent-owned; this layer owns only surfaces.

ez_gfx_c_context_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Context {
	if handle == 0 do return nil
	return cast(^Ez_Gfx_C_Context)(uintptr(handle))
}

ez_gfx_c_surface_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Surface {
	if handle == 0 do return nil
	return cast(^Ez_Gfx_C_Surface)(uintptr(handle))
}

ez_gfx_c_shader_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Shader {
	if handle == 0 do return nil
	return cast(^Ez_Gfx_C_Shader)(uintptr(handle))
}

ez_gfx_c_indirect_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Indirect {
	if handle == 0 do return nil
	return cast(^Ez_Gfx_C_Indirect)(uintptr(handle))
}

ez_gfx_c_structured_from_handle :: proc(handle: u64) -> ^Ez_Gfx_C_Structured {
	if handle == 0 do return nil
	return cast(^Ez_Gfx_C_Structured)(uintptr(handle))
}

ez_gfx_c_context_handle :: proc(ctx: ^Ez_Gfx_C_Context) -> u64 {
	if ctx == nil do return 0
	return u64(uintptr(ctx))
}

ez_gfx_c_surface_handle :: proc(surface: ^Ez_Gfx_C_Surface) -> u64 {
	if surface == nil do return 0
	return u64(uintptr(surface))
}

ez_gfx_c_shader_handle :: proc(shader: ^Ez_Gfx_C_Shader) -> u64 {
	if shader == nil do return 0
	return u64(uintptr(shader))
}

ez_gfx_c_indirect_handle :: proc(indirect: ^Ez_Gfx_C_Indirect) -> u64 {
	if indirect == nil do return 0
	return u64(uintptr(indirect))
}

ez_gfx_c_structured_handle :: proc(structured: ^Ez_Gfx_C_Structured) -> u64 {
	if structured == nil do return 0
	return u64(uintptr(structured))
}

ez_gfx_c_clone_cstring :: proc(value: cstring) -> []u8 {
	if value == nil do return nil
	source := ez_gfx_shader_cstring_to_string(value)
	bytes := make([]u8, len(source) + 1)
	if len(source) > 0 {
		mem.copy(raw_data(bytes), raw_data(source), len(source))
	}
	bytes[len(source)] = 0
	return bytes
}

ez_gfx_c_shader_string :: proc(bytes: []u8) -> cstring {
	if len(bytes) == 0 do return nil
	return cast(cstring)raw_data(bytes)
}

ez_gfx_c_shader_strings_destroy :: proc(shader: ^Ez_Gfx_C_Shader) {
	if shader == nil do return
	for bytes in shader.string_data {
		if raw_data(bytes) != nil {
			delete(bytes)
		}
	}
	shader.string_data = {}
}

ez_gfx_c_use_context :: proc(owner: ^Ez_Gfx_C_Context) -> bool {
	if owner == nil do return false
	ez_gfx_set_current_ctx(&owner.ctx)
	return true
}

ez_gfx_c_result :: proc(ok: bool) -> i32 {
	if ok do return EZ_GFX_C_RESULT_OK
	return EZ_GFX_C_RESULT_NATIVE_FAILURE
}

ez_gfx_c_valid_source_format :: proc(value: u32) -> bool {
	return value <= u32(Ez_Gfx_Source_Texture_Format.KTX2)
}

ez_gfx_c_valid_filter :: proc(value: u32) -> bool {
	return value <= u32(Ez_Gfx_Texture_Filter.Linear)
}

ez_gfx_c_valid_address_mode :: proc(value: u32) -> bool {
	return value <= u32(Ez_Gfx_Texture_Address_Mode.Clamp_To_Edge)
}

ez_gfx_c_build_dynamic_state :: proc(
	state: ^Ez_Gfx_C_Dynamic_State,
) -> (
	render_state: Ez_Gfx_Render_Dynamic_State,
	ok: bool,
) {
	if state == nil do return render_state, true
	if state.cull_mode > 3 || state.front_face > 1 {
		return render_state, false
	}
	if state.primitive_type >= u32(len(Ez_Gfx_Primitive_Type)) || state.blend_mode > u32(Ez_Gfx_Blend_Mode.Alpha) {
		return render_state, false
	}
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

ez_gfx_c_copy_bindings :: proc(
	source: [^]Ez_Gfx_C_Binding,
	count: u32,
	owner: ^Ez_Gfx_C_Context,
	destination: ^[EZ_GFX_C_MAX_BINDINGS]Ez_Gfx_Render_Binding,
) -> bool {
	if count > EZ_GFX_C_MAX_BINDINGS do return false
	if count > 0 && source == nil do return false
	for i in 0 ..< int(count) {
		c_binding := source[i]
		binding := &destination[i]
		binding^ = {}
		if c_binding.name == nil do return false
		binding.name = c_binding.name
		if c_binding.structured != 0 {
			structured := ez_gfx_c_structured_from_handle(c_binding.structured)
			if structured == nil || structured.owner != owner || !structured.handle.ok do return false
			binding.structured = structured.handle
		}
		if c_binding.indirect != 0 {
			indirect := ez_gfx_c_indirect_from_handle(c_binding.indirect)
			if indirect == nil || indirect.owner != owner || !indirect.handle.ok do return false
			binding.indirect = indirect.handle
		}
	}
	return true
}

ez_gfx_c_texture_desc :: proc(desc: ^Ez_Gfx_C_Texture_Desc) -> (
	result: Ez_Gfx_Load_Texture_Desc,
	ok: bool,
) {
	if desc == nil do return result, false
	if !ez_gfx_c_valid_source_format(desc.source_format) || desc.destination_format != 0 {
		return result, false
	}
	if !ez_gfx_c_valid_filter(desc.min_filter) || !ez_gfx_c_valid_filter(desc.mag_filter) {
		return result, false
	}
	if !ez_gfx_c_valid_address_mode(desc.address_mode_u) ||
	   !ez_gfx_c_valid_address_mode(desc.address_mode_v) ||
	   !ez_gfx_c_valid_address_mode(desc.address_mode_w) {
		return result, false
	}
	result = Ez_Gfx_Load_Texture_Desc {
		source_format      = Ez_Gfx_Source_Texture_Format(desc.source_format),
		destination_format = .R8G8B8A8_UNORM,
		width              = desc.width,
		height             = desc.height,
		mip_count          = desc.mip_count,
		generate_mips      = desc.generate_mips != 0,
		min_filter         = Ez_Gfx_Texture_Filter(desc.min_filter),
		mag_filter         = Ez_Gfx_Texture_Filter(desc.mag_filter),
		max_anisotropy     = desc.max_anisotropy,
		address_mode_u     = Ez_Gfx_Texture_Address_Mode(desc.address_mode_u),
		address_mode_v     = Ez_Gfx_Texture_Address_Mode(desc.address_mode_v),
		address_mode_w     = Ez_Gfx_Texture_Address_Mode(desc.address_mode_w),
		debug_label        = ez_gfx_shader_cstring_to_string(desc.debug_label),
	}
	return result, true
}

@(export)
ez_gfx_c_abi_version :: proc "c" () -> u32 {
	context = runtime.default_context()
	return EZ_GFX_C_ABI_VERSION
}

@(export)
ez_gfx_c_context_create :: proc "c" (
	desc: ^Ez_Gfx_C_Context_Desc,
	out_context: ^u64,
) -> i32 {
	context = runtime.default_context()
	if desc == nil || out_context == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if desc.surface_platform != EZ_GFX_SURFACE_PLATFORM_WIN32 {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	owner := new(Ez_Gfx_C_Context)
	odin_desc := Ez_Gfx_Ctx_Desc {
		enable_debug      = desc.enable_debug != 0,
		enable_validation = desc.enable_validation != 0,
		surface_platform  = desc.surface_platform,
	}
	if !ez_gfx_ctx_create_instance(&owner.ctx, odin_desc) {
		free(owner)
		return EZ_GFX_C_RESULT_NATIVE_FAILURE
	}
	out_context^ = ez_gfx_c_context_handle(owner)
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_context_set_current :: proc "c" (context_handle: u64) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_context_wait_idle :: proc "c" (context_handle: u64) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	ez_gfx_ctx_wait_idle()
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_context_destroy :: proc "c" (context_handle: u64) {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return
	if ez_gfx_c_use_context(owner) {
		ez_gfx_c_imgui_destroy(owner)
		ez_gfx_ctx_destroy()
	}
	for bytes in owner.texture_data {
		delete(bytes)
	}
	if raw_data(owner.texture_data) != nil {
		delete(owner.texture_data)
	}
	for bytes in owner.imgui_texture_data {
		delete(bytes)
	}
	if raw_data(owner.imgui_texture_data) != nil {
		delete(owner.imgui_texture_data)
	}
	free(owner)
}

@(export)
ez_gfx_c_surface_create :: proc "c" (
	context_handle: u64,
	desc: ^Ez_Gfx_C_Surface_Desc,
	out_surface: ^u64,
) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if desc == nil || out_surface == nil || desc.window == nil || desc.width == 0 || desc.height == 0 {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	if desc.platform != owner.ctx.surface_platform || desc.platform != EZ_GFX_SURFACE_PLATFORM_WIN32 {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	if desc.display == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	surface := new(Ez_Gfx_C_Surface)
	surface.owner = owner
	surface.surface = Ez_Gfx_Window {
		native_window = desc.window,
		native_display = desc.display,
		surface_platform = desc.platform,
		cache_presented_snapshots = false,
		framebuffer_width = c.int(desc.width),
		framebuffer_height = c.int(desc.height),
	}
	if !ez_gfx_window_create_surface(&surface.surface) {
		free(surface)
		return EZ_GFX_C_RESULT_NATIVE_FAILURE
	}
	out_surface^ = ez_gfx_c_surface_handle(surface)
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_context_init_device :: proc "c" (context_handle: u64, surface_handle: u64) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	surface := ez_gfx_c_surface_from_handle(surface_handle)
	if owner == nil || surface == nil || surface.owner != owner {
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	}
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	return ez_gfx_c_result(ez_gfx_ctx_init_device(surface.surface.surface))
}

@(export)
ez_gfx_c_surface_resize :: proc "c" (surface_handle: u64, width, height: u32) -> i32 {
	context = runtime.default_context()
	surface := ez_gfx_c_surface_from_handle(surface_handle)
	if surface == nil || surface.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if !ez_gfx_c_use_context(surface.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if width == 0 || height == 0 {
		if width != height do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
		return ez_gfx_c_result(ez_gfx_window_set_extent(&surface.surface, 0, 0))
	}
	return ez_gfx_c_result(ez_gfx_window_recreate_swapchain(&surface.surface, c.int(width), c.int(height)))
}

@(export)
ez_gfx_c_surface_get_extent :: proc "c" (
	surface_handle: u64,
	out_width: ^u32,
	out_height: ^u32,
) -> i32 {
	context = runtime.default_context()
	surface := ez_gfx_c_surface_from_handle(surface_handle)
	if surface == nil || surface.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if out_width == nil || out_height == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(surface.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	width, height := ez_gfx_window_get_framebuffer_size(&surface.surface)
	if width <= 0 || height <= 0 do return EZ_GFX_C_RESULT_NOT_READY
	out_width^ = u32(width)
	out_height^ = u32(height)
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_surface_resize_pending :: proc "c" (
	surface_handle: u64,
	out_pending: ^i32,
) -> i32 {
	context = runtime.default_context()
	surface := ez_gfx_c_surface_from_handle(surface_handle)
	if surface == nil || surface.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if out_pending == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(surface.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	out_pending^ = 0
	if ez_gfx_window_resize_pending(&surface.surface) {
		out_pending^ = 1
	}
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_surface_set_snapshot_cache :: proc "c" (
	surface_handle: u64,
	enabled: i32,
) -> i32 {
	context = runtime.default_context()
	surface := ez_gfx_c_surface_from_handle(surface_handle)
	if surface == nil || surface.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if enabled != 0 && enabled != 1 do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(surface.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	surface.surface.cache_presented_snapshots = enabled != 0
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_surface_destroy :: proc "c" (surface_handle: u64) {
	context = runtime.default_context()
	surface := ez_gfx_c_surface_from_handle(surface_handle)
	if surface == nil do return
	if surface.owner != nil && ez_gfx_c_use_context(surface.owner) {
		ez_gfx_window_destroy(&surface.surface)
	}
	free(surface)
}

@(export)
ez_gfx_c_shader_compile :: proc "c" (
	context_handle: u64,
	desc: ^Ez_Gfx_C_Shader_Desc,
	out_shader: ^u64,
) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if desc == nil || out_shader == nil || desc.path == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if desc.kind > u32(Ez_Gfx_Shader_Kind.Compute) do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	shader := new(Ez_Gfx_C_Shader)
	shader.owner = owner
	shader.string_data[0] = ez_gfx_c_clone_cstring(desc.path)
	shader.string_data[1] = ez_gfx_c_clone_cstring(desc.vertex_entry)
	shader.string_data[2] = ez_gfx_c_clone_cstring(desc.fragment_entry)
	shader.string_data[3] = ez_gfx_c_clone_cstring(desc.compute_entry)
	odin_desc := Ez_Gfx_Shader_Desc {
		path           = ez_gfx_c_shader_string(shader.string_data[0]),
		vertex_entry   = ez_gfx_c_shader_string(shader.string_data[1]),
		fragment_entry = ez_gfx_c_shader_string(shader.string_data[2]),
		compute_entry  = ez_gfx_c_shader_string(shader.string_data[3]),
		kind           = Ez_Gfx_Shader_Kind(desc.kind),
	}
	if !ez_gfx_shader_compile(odin_desc, &shader.shader) {
		ez_gfx_shader_destroy(&shader.shader)
		ez_gfx_c_shader_strings_destroy(shader)
		free(shader)
		return EZ_GFX_C_RESULT_NATIVE_FAILURE
	}
	out_shader^ = ez_gfx_c_shader_handle(shader)
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_shader_destroy :: proc "c" (shader_handle: u64) {
	context = runtime.default_context()
	shader := ez_gfx_c_shader_from_handle(shader_handle)
	if shader == nil do return
	if shader.owner != nil && ez_gfx_c_use_context(shader.owner) {
		ez_gfx_shader_destroy(&shader.shader)
	}
	ez_gfx_c_shader_strings_destroy(shader)
	free(shader)
}

@(export)
ez_gfx_c_vertex_heap_create :: proc "c" (
	context_handle: u64,
	name: cstring,
	capacity: u64,
	stride: u64,
) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if name == nil || capacity == 0 || stride == 0 do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	ez_gfx_vertex_manager_add_heap(
		&owner.ctx.vertex_manager,
		ez_gfx_shader_cstring_to_string(name),
		vk.DeviceSize(capacity),
		vk.DeviceSize(stride),
	)
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_index_heap_create :: proc "c" (
	context_handle: u64,
	capacity: u64,
	debug_name: cstring,
) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if capacity == 0 || debug_name == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	ez_gfx_gpu_heap_destroy(&owner.ctx.vertex_manager.index_heap)
	ez_gfx_gpu_heap_create(
		&owner.ctx.vertex_manager.index_heap,
		vk.DeviceSize(capacity),
		vk.DeviceSize(size_of(u32)),
		{.INDEX_BUFFER},
		debug_name,
	)
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_vertex_upload_indices :: proc "c" (
	context_handle: u64,
	data: rawptr,
	count: u32,
	out_start_index: ^u32,
) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if data == nil || count == 0 || out_start_index == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	allocation, ok := ez_gfx_vertex_manager_schedule_upload(
		&owner.ctx.vertex_manager,
		.Indices,
		"",
		&owner.ctx.vertex_manager.index_heap,
		data,
		count,
		vk.DeviceSize(size_of(u32)),
	)
	if !ok do return EZ_GFX_C_RESULT_NATIVE_FAILURE
	out_start_index^ = allocation.start_index
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_vertex_upload :: proc "c" (
	context_handle: u64,
	heap_name: cstring,
	data: rawptr,
	element_count: u32,
	element_size: u64,
	out_start_index: ^u32,
) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if heap_name == nil || data == nil || element_count == 0 || element_size == 0 || out_start_index == nil {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	heap := ez_gfx_vertex_manager_find_heap(
		&owner.ctx.vertex_manager,
		ez_gfx_shader_cstring_to_string(heap_name),
	)
	if heap == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	allocation, ok := ez_gfx_vertex_manager_schedule_upload(
		&owner.ctx.vertex_manager,
		.Vertices,
		ez_gfx_shader_cstring_to_string(heap_name),
		heap,
		data,
		element_count,
		vk.DeviceSize(element_size),
	)
	if !ok do return EZ_GFX_C_RESULT_NATIVE_FAILURE
	out_start_index^ = allocation.start_index
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_enable_all_decoders :: proc "c" (context_handle: u64) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	return ez_gfx_c_result(ez_gfx_enable_all_decoders())
}

@(export)
ez_gfx_c_texture_load :: proc "c" (
	context_handle: u64,
	data: rawptr,
	data_size: u64,
	desc: ^Ez_Gfx_C_Texture_Desc,
	out_texture_id: ^u32,
) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return i32(Ez_Gfx_Texture_Error.Invalid_Context)
	if data == nil || data_size == 0 || desc == nil || out_texture_id == nil || data_size > u64(max(int)) {
		return i32(Ez_Gfx_Texture_Error.Invalid_Arguments)
	}
	if !ez_gfx_c_use_context(owner) do return i32(Ez_Gfx_Texture_Error.Invalid_Context)
	odin_desc, desc_ok := ez_gfx_c_texture_desc(desc)
	if !desc_ok do return i32(Ez_Gfx_Texture_Error.Invalid_Arguments)
	owned_bytes := make([]u8, int(data_size))
	mem.copy(raw_data(owned_bytes), data, int(data_size))
	regions := [1]Ez_Gfx_Texture_Memory_Region{{data = owned_bytes}}
	texture_id, err := ez_gfx_load_texture(regions[:], odin_desc)
	if err == .None {
		append(&owner.texture_data, owned_bytes)
	} else {
		delete(owned_bytes)
	}
	out_texture_id^ = u32(texture_id)
	return i32(err)
}

@(export)
ez_gfx_c_texture_unload :: proc "c" (context_handle: u64, texture_id: u32) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return i32(Ez_Gfx_Texture_Error.Invalid_Context)
	if !ez_gfx_c_use_context(owner) do return i32(Ez_Gfx_Texture_Error.Invalid_Context)
	return i32(ez_gfx_unload_texture(Ez_Gfx_Texture_ID(texture_id)))
}

@(export)
ez_gfx_c_begin_render :: proc "c" (surface_handle: u64) -> i32 {
	context = runtime.default_context()
	surface := ez_gfx_c_surface_from_handle(surface_handle)
	if surface == nil || surface.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if !ez_gfx_c_use_context(surface.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	return ez_gfx_c_result(ez_gfx_begin_render(&surface.surface))
}

@(export)
ez_gfx_c_acquire_indirect :: proc "c" (
	context_handle: u64,
	capacity: u32,
	debug_name: cstring,
	out_indirect: ^u64,
) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if capacity == 0 || debug_name == nil || out_indirect == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	handle := ez_gfx_render_acquire_indirect_buffer(vk.DrawIndexedIndirectCommand, capacity, debug_name)
	if !handle.ok do return EZ_GFX_C_RESULT_NOT_READY
	indirect := new(Ez_Gfx_C_Indirect)
	indirect.owner = owner
	indirect.handle = handle
	out_indirect^ = ez_gfx_c_indirect_handle(indirect)
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_indirect_write_draw :: proc "c" (
	indirect_handle: u64,
	index: u32,
	command: ^Ez_Gfx_C_Draw_Indexed_Command,
) -> i32 {
	context = runtime.default_context()
	indirect := ez_gfx_c_indirect_from_handle(indirect_handle)
	if indirect == nil || indirect.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if command == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(indirect.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	odin_command := vk.DrawIndexedIndirectCommand {
		indexCount    = command.index_count,
		instanceCount = command.instance_count,
		firstIndex    = command.first_index,
		vertexOffset  = command.vertex_offset,
		firstInstance = command.first_instance,
	}
	return ez_gfx_c_result(ez_gfx_indirect_buffer_write_draw(&indirect.handle, index, odin_command))
}

@(export)
ez_gfx_c_indirect_set_draw_count :: proc "c" (indirect_handle: u64, count: u32) -> i32 {
	context = runtime.default_context()
	indirect := ez_gfx_c_indirect_from_handle(indirect_handle)
	if indirect == nil || indirect.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if !ez_gfx_c_use_context(indirect.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	return ez_gfx_c_result(ez_gfx_indirect_buffer_set_draw_count(&indirect.handle, count))
}

@(export)
ez_gfx_c_indirect_release :: proc "c" (indirect_handle: u64) {
	context = runtime.default_context()
	indirect := ez_gfx_c_indirect_from_handle(indirect_handle)
	if indirect != nil do free(indirect)
}

@(export)
ez_gfx_c_structured_acquire :: proc "c" (
	context_handle: u64,
	element_size: u32,
	element_count: u32,
	debug_name: cstring,
	out_structured: ^u64,
) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if element_size == 0 || element_count == 0 || debug_name == nil || out_structured == nil {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	byte_count := u64(element_size) * u64(element_count)
	if byte_count > u64(max(u32)) do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	view := ez_gfx_render_acquire_structured_buffer(u8, u32(byte_count), debug_name)
	if !view.handle.ok do return EZ_GFX_C_RESULT_NOT_READY
	structured := new(Ez_Gfx_C_Structured)
	structured.owner = owner
	structured.handle = view.handle
	out_structured^ = ez_gfx_c_structured_handle(structured)
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_structured_write :: proc "c" (
	structured_handle: u64,
	data: rawptr,
	data_size: u64,
) -> i32 {
	context = runtime.default_context()
	structured := ez_gfx_c_structured_from_handle(structured_handle)
	if structured == nil || structured.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if data == nil || data_size > u64(structured.handle.size) || data_size > u64(max(int)) {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	if !ez_gfx_c_use_context(structured.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	mem.copy(structured.handle.cpu_ptr, data, int(data_size))
	return EZ_GFX_C_RESULT_OK
}

@(export)
ez_gfx_c_structured_release :: proc "c" (structured_handle: u64) {
	context = runtime.default_context()
	structured := ez_gfx_c_structured_from_handle(structured_handle)
	if structured != nil do free(structured)
}

@(export)
ez_gfx_c_render_add_vertex_pipeline :: proc "c" (
	shader_handle: u64,
	indirect_handle: u64,
	bindings: [^]Ez_Gfx_C_Binding,
	binding_count: u32,
	dynamic_state: ^Ez_Gfx_C_Dynamic_State,
	push_constants: rawptr,
	push_constant_size: u32,
) -> i32 {
	context = runtime.default_context()
	shader := ez_gfx_c_shader_from_handle(shader_handle)
	indirect := ez_gfx_c_indirect_from_handle(indirect_handle)
	if shader == nil || shader.owner == nil || indirect == nil || indirect.owner != shader.owner {
		return EZ_GFX_C_RESULT_INVALID_CONTEXT
	}
	if push_constant_size > EZ_GFX_MAX_PUSH_CONSTANT_BYTES || (push_constant_size > 0 && push_constants == nil) {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	if !ez_gfx_c_use_context(shader.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	odin_bindings: [EZ_GFX_C_MAX_BINDINGS]Ez_Gfx_Render_Binding
	if !ez_gfx_c_copy_bindings(bindings, binding_count, shader.owner, &odin_bindings) {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	odin_dynamic, dynamic_ok := ez_gfx_c_build_dynamic_state(dynamic_state)
	if !dynamic_ok do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	pipeline := ez_gfx_render_add_vertex_pipeline_impl(
		&shader.shader,
		indirect.handle,
		odin_bindings[:int(binding_count)],
		odin_dynamic,
		push_constants,
		push_constant_size,
	)
	return ez_gfx_c_result(pipeline.ok)
}

@(export)
ez_gfx_c_render_add_compute_pipeline :: proc "c" (
	shader_handle: u64,
	dispatch_x: u32,
	dispatch_y: u32,
	dispatch_z: u32,
	bindings: [^]Ez_Gfx_C_Binding,
	binding_count: u32,
	push_constants: rawptr,
	push_constant_size: u32,
) -> i32 {
	context = runtime.default_context()
	shader := ez_gfx_c_shader_from_handle(shader_handle)
	if shader == nil || shader.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if dispatch_x == 0 || dispatch_y == 0 || dispatch_z == 0 || push_constant_size > EZ_GFX_MAX_PUSH_CONSTANT_BYTES || (push_constant_size > 0 && push_constants == nil) {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	if !ez_gfx_c_use_context(shader.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	odin_bindings: [EZ_GFX_C_MAX_BINDINGS]Ez_Gfx_Render_Binding
	if !ez_gfx_c_copy_bindings(bindings, binding_count, shader.owner, &odin_bindings) {
		return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	}
	pipeline := ez_gfx_render_add_compute_pipeline_impl(
		&shader.shader,
		dispatch_x,
		dispatch_y,
		dispatch_z,
		odin_bindings[:int(binding_count)],
		push_constants,
		push_constant_size,
	)
	return ez_gfx_c_result(pipeline.ok)
}

@(export)
ez_gfx_c_finish_render :: proc "c" (context_handle: u64) -> i32 {
	context = runtime.default_context()
	owner := ez_gfx_c_context_from_handle(context_handle)
	if owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if !ez_gfx_c_use_context(owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	return ez_gfx_c_result(ez_gfx_finish_render())
}

@(export)
ez_gfx_c_screenshot_save :: proc "c" (surface_handle: u64, path: cstring) -> i32 {
	context = runtime.default_context()
	surface := ez_gfx_c_surface_from_handle(surface_handle)
	if surface == nil || surface.owner == nil do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	if path == nil do return EZ_GFX_C_RESULT_INVALID_ARGUMENT
	if !ez_gfx_c_use_context(surface.owner) do return EZ_GFX_C_RESULT_INVALID_CONTEXT
	return ez_gfx_c_result(ez_gfx_screenshot_save_window(&surface.surface, ez_gfx_shader_cstring_to_string(path)))
}
