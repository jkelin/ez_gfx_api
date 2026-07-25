package ez_gfx

import sp "../vendor/odin-slang/slang"
import vma "../vendor/odin-vma"
import ga "./generational_arena"
import "base:runtime"
import "core:c"
import "core:mem"
import "core:fmt"
import "core:sync"
import "core:thread"
import vk "vendor:vulkan"






// Public Odin procedures, public type layouts, and C adapters live in this
// facade. All implementation modules are package-private through #+private.


@(private)
status_from_bool :: proc(ok: bool) -> Ez_Gfx_Status {
	if ok do return .Ok
	return .Native_Failure
}

@(private)
validate_context :: proc(ctx: ^Ez_Gfx_Ctx) -> Ez_Gfx_Status {
	if ctx == nil do return .Invalid_Context
	return .Ok
}

@(private)
validate_window :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if window == nil || window.native_window == nil {
		return .Invalid_Argument
	}
	if window.surface_platform != EZ_GFX_SURFACE_PLATFORM_GLFW &&
	   window.surface_platform != EZ_GFX_SURFACE_PLATFORM_WIN32 {
		return .Invalid_Argument
	}
	if window.surface_platform == EZ_GFX_SURFACE_PLATFORM_WIN32 && window.native_display == nil {
		return .Invalid_Argument
	}
	return validate_context(get_current_ctx())
}

@(private)
validate_window_surface_identity :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	if get_current_ctx().surface_platform != window.surface_platform {
		return .Invalid_Argument
	}
	return .Ok
}

@(private)
validate_shader :: proc(desc: Ez_Gfx_Shader_Desc, program: ^Ez_Gfx_Shader_Program) -> Ez_Gfx_Status {
	if program == nil || desc.path == nil do return .Invalid_Argument
	if desc.kind > Ez_Gfx_Shader_Kind.Compute do return .Invalid_Argument
	return validate_context(get_current_ctx())
}

@(private)
validate_active_render :: proc() -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	render := &get_current_ctx().render
	if !render.active || !render.ready do return .Not_Ready
	return .Ok
}

@(private)
validate_pipeline_common :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	bindings: []Ez_Gfx_Render_Binding,
	push_constant_data: rawptr,
	push_constant_size: u32,
) -> Ez_Gfx_Status {
	if shader == nil || len(bindings) > EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS {
		return .Invalid_Argument
	}
	if push_constant_size != shader.push_constant_size ||
	   push_constant_size > EZ_GFX_MAX_PUSH_CONSTANT_BYTES ||
	   (push_constant_size > 0 && push_constant_data == nil) {
		return .Invalid_Argument
	}
	for binding in bindings {
		if binding.name == nil do return .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return status
	if get_current_ctx().render.pipeline_count >= EZ_GFX_MAX_RENDER_PIPELINES {
		return .Not_Ready
	}
	return .Ok
}

// Runtime-sized push constants enter through this public boundary. Typed
// overloads and C adapters delegate here after marshalling their inputs.
@(private)
ez_gfx_render_add_vertex_pipeline_raw :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State,
	push_constant_data: rawptr,
	push_constant_size: u32,
) -> (
	descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	if status := validate_pipeline_common(shader, bindings, push_constant_data, push_constant_size); status != .Ok {
		return descriptor, status
	}
	if shader.desc.kind != .Graphics ||
	   !indirect.ok ||
	   indirect.buffer == nil ||
	   indirect.frame_id != get_current_ctx().render.frame_id {
		return descriptor, .Invalid_Argument
	}
	descriptor = render_add_vertex_pipeline_impl(
		shader,
		indirect,
		bindings,
		dynamic_state,
		push_constant_data,
		push_constant_size,
	)
	if !descriptor.ok do return descriptor, .Native_Failure
	return descriptor, .Ok
}

// Runtime-sized push constants enter through this public boundary. Typed
// overloads and C adapters delegate here after marshalling their inputs.
@(private)
ez_gfx_render_add_compute_pipeline_raw :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Render_Binding,
	push_constant_data: rawptr,
	push_constant_size: u32,
) -> (
	descriptor: Ez_Gfx_Compute_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	if dispatch_x == 0 || dispatch_y == 0 || dispatch_z == 0 {
		return descriptor, .Invalid_Argument
	}
	if status := validate_pipeline_common(shader, bindings, push_constant_data, push_constant_size); status != .Ok {
		return descriptor, status
	}
	if shader.desc.kind != .Compute do return descriptor, .Invalid_Argument
	descriptor = render_add_compute_pipeline_impl(
		shader,
		dispatch_x,
		dispatch_y,
		dispatch_z,
		bindings,
		push_constant_data,
		push_constant_size,
	)
	if !descriptor.ok do return descriptor, .Native_Failure
	return descriptor, .Ok
}


@(private)
validate_texture_load_arguments :: proc(
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> Ez_Gfx_Texture_Error {
	desc := texture_prepare_desc(desc)
	if len(regions) == 0 || len(regions) > 16 do return .Invalid_Arguments
	if desc.source_format > .KTX2 ||
	   desc.min_filter > .Linear ||
	   desc.mag_filter > .Linear ||
	   desc.address_mode_u > .Clamp_To_Edge ||
	   desc.address_mode_v > .Clamp_To_Edge ||
	   desc.address_mode_w > .Clamp_To_Edge {
		return .Invalid_Arguments
	}
	if (desc.source_format == .RGB || desc.source_format == .RGBA) &&
	   (desc.width == 0 || desc.height == 0) {
		return .Invalid_Arguments
	}
	for region in regions {
		if len(region.data) == 0 do return .Invalid_Arguments
	}
	return .None
}



@(private)
ez_gfx_ctx_create_instance :: proc(ctx: ^Ez_Gfx_Ctx, desc: Ez_Gfx_Ctx_Desc = {}) -> Ez_Gfx_Status {
	if status := validate_context(ctx); status != .Ok do return status
	if get_current_ctx() != ctx do return .Invalid_Context
	if desc.surface_platform != EZ_GFX_SURFACE_PLATFORM_GLFW &&
	   desc.surface_platform != EZ_GFX_SURFACE_PLATFORM_WIN32 {
		return .Invalid_Argument
	}
	return status_from_bool(ctx_create_instance(ctx, desc))
}


@(private)
ez_gfx_ctx_init_device :: proc(surface: vk.SurfaceKHR) -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	if surface == vk.SurfaceKHR(0) do return .Invalid_Argument
	return status_from_bool(ctx_init_device(surface))
}


@(private)
ez_gfx_ctx_wait_idle :: proc() -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	ctx_wait_idle()
	return .Ok
}


@(private)
ez_gfx_ctx_destroy :: proc() -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	ctx_destroy()
	return .Ok
}


@(private)
ez_gfx_window_create_surface :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if status := validate_window_surface_identity(window); status != .Ok do return status
	if window.framebuffer_width <= 0 || window.framebuffer_height <= 0 {
		return .Invalid_Argument
	}
	return status_from_bool(window_create_surface(window))
}

@(private)
ez_gfx_window_create_surface_u32 :: proc(
	window: ^Ez_Gfx_Window,
	width, height: u32,
) -> Ez_Gfx_Status {
	if status := validate_window_surface_identity(window); status != .Ok do return status
	if width == 0 || height == 0 ||
	   width > u32(max(c.int)) || height > u32(max(c.int)) {
		return .Invalid_Argument
	}
	window.framebuffer_width = c.int(width)
	window.framebuffer_height = c.int(height)
	return status_from_bool(window_create_surface(window))
}


@(private)
ez_gfx_window_recreate_swapchain :: proc(window: ^Ez_Gfx_Window, width, height: c.int) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	if width < 0 || height < 0 do return .Invalid_Argument
	if window.surface == vk.SurfaceKHR(0) do return .Not_Ready
	if width == 0 || height == 0 {
		if width != 0 || height != 0 do return .Invalid_Argument
		return status_from_bool(window_set_extent(window, 0, 0))
	}
	return status_from_bool(window_recreate_swapchain(window, width, height))
}

@(private)
ez_gfx_window_recreate_swapchain_u32 :: proc(
	window: ^Ez_Gfx_Window,
	width, height: u32,
) -> Ez_Gfx_Status {
	if width > u32(max(c.int)) || height > u32(max(c.int)) {
		return .Invalid_Argument
	}
	return ez_gfx_window_recreate_swapchain(window, c.int(width), c.int(height))
}


@(private)
ez_gfx_window_get_framebuffer_size :: proc(window: ^Ez_Gfx_Window) -> (width, height: c.int, status: Ez_Gfx_Status) {
	if status := validate_window(window); status != .Ok do return 0, 0, status
	width, height = window_get_framebuffer_size(window)
	if width <= 0 || height <= 0 do return width, height, .Not_Ready
	return width, height, .Ok
}

@(private)
ez_gfx_window_resize_pending :: proc(window: ^Ez_Gfx_Window) -> (pending: bool, status: Ez_Gfx_Status) {
	if status := validate_window(window); status != .Ok do return false, status
	return window_resize_pending(window), .Ok
}


@(private)
ez_gfx_window_set_snapshot_cache :: proc(window: ^Ez_Gfx_Window, enabled: bool) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	window.cache_presented_snapshots = enabled
	return .Ok
}

@(private)
ez_gfx_window_set_snapshot_cache_i32 :: proc(window: ^Ez_Gfx_Window, enabled: i32) -> Ez_Gfx_Status {
	if enabled != 0 && enabled != 1 do return .Invalid_Argument
	return ez_gfx_window_set_snapshot_cache(window, enabled != 0)
}


@(private)
ez_gfx_window_destroy :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	window_destroy(window)
	return .Ok
}


@(private)
ez_gfx_shader_compile :: proc(desc: Ez_Gfx_Shader_Desc, program: ^Ez_Gfx_Shader_Program) -> Ez_Gfx_Status {
	if status := validate_shader(desc, program); status != .Ok do return status
	return status_from_bool(shader_compile(desc, program))
}


@(private)
ez_gfx_shader_destroy :: proc(program: ^Ez_Gfx_Shader_Program) -> Ez_Gfx_Status {
	if program == nil do return .Invalid_Argument
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	shader_destroy(program)
	return .Ok
}


ez_gfx_enable_all_decoders :: proc() -> Ez_Gfx_Status {
	return status_from_bool(enable_all_decoders())
}


@(private)
ez_gfx_vertex_manager_begin :: proc(manager: ^Ez_Gfx_Vertex_Manager) -> Ez_Gfx_Status {
	if manager == nil do return .Invalid_Argument
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	vertex_manager_begin(manager)
	return .Ok
}


ez_gfx_gpu_heap_create :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	capacity: vk.DeviceSize,
	stride: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	debug_name: cstring = nil,
) -> Ez_Gfx_Status {
	if heap == nil || capacity == 0 || stride == 0 ||
	   capacity > vk.DeviceSize(max(int)) || stride > vk.DeviceSize(max(int)) {
		return .Invalid_Argument
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	gpu_heap_create(heap, capacity, stride, usage, debug_name)
	return .Ok
}


ez_gfx_vertex_manager_add_heap :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	name: string,
	capacity: vk.DeviceSize,
	stride: vk.DeviceSize,
) -> Ez_Gfx_Status {
	if manager == nil || len(name) == 0 || capacity == 0 || stride == 0 ||
	   capacity > vk.DeviceSize(max(int)) || stride > vk.DeviceSize(max(int)) {
		return .Invalid_Argument
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	if manager.vertex_heap_count >= EZ_GFX_MAX_VERTEX_HEAPS do return .Invalid_Argument
	vertex_manager_add_heap(manager, name, capacity, stride)
	return .Ok
}

@(private)
validate_vertex_upload :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap: ^Ez_Gfx_Gpu_Heap,
	element_count: u32,
	element_size, source_stride: vk.DeviceSize,
) -> Ez_Gfx_Status {
	if manager == nil || heap == nil || element_count == 0 || element_size == 0 ||
	   u64(element_count) > u64(max(int)) ||
	   element_size > vk.DeviceSize(max(int)) ||
	   heap.stride > vk.DeviceSize(max(int)) {
		return .Invalid_Argument
	}
	if manager.worker == nil || heap.stride == 0 do return .Not_Ready
	actual_source_stride := source_stride
	if actual_source_stride == 0 do actual_source_stride = element_size
	if actual_source_stride > vk.DeviceSize(max(int)) ||
	   element_size > heap.stride || actual_source_stride < element_size {
		return .Invalid_Argument
	}
	count := int(element_count)
	element_size_int := int(element_size)
	if u64(element_count) > u64(max(vk.DeviceSize)) / u64(heap.stride) ||
	   u64(element_count) > u64(max(int)) / u64(heap.stride) {
		return .Invalid_Argument
	}
	if count > 1 {
		max_offset := max(int) - element_size_int
		if int(heap.stride) > max_offset / (count - 1) ||
		   int(actual_source_stride) > max_offset / (count - 1) {
			return .Invalid_Argument
		}
	}
	return .Ok
}


ez_gfx_vertex_manager_upload_indices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	indices: []u32,
	source_stride: vk.DeviceSize = 0,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	if manager == nil || len(indices) == 0 || u64(len(indices)) > u64(max(u32)) {
		return 0, .Invalid_Argument
	}
	if status := validate_vertex_upload(
		manager,
		&manager.index_heap,
		u32(len(indices)),
		vk.DeviceSize(size_of(u32)),
		source_stride,
	); status != .Ok {
		return 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return 0, status
	allocation, ok := vertex_manager_alloc_indices(manager, indices, source_stride)
	if !ok do return 0, .Native_Failure
	return allocation.start_index, .Ok
}

ez_gfx_vertex_manager_upload_indices_raw :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	data: rawptr,
	count: u32,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	if data == nil || count == 0 {
		return 0, .Invalid_Argument
	}
	indices_ptr := cast([^]u32)data
	indices := indices_ptr[:count]
	return ez_gfx_vertex_manager_upload_indices(manager, indices)
}


ez_gfx_vertex_manager_upload_vertices :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	vertices: []$T,
	source_stride: vk.DeviceSize = 0,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	if manager == nil || len(heap_name) == 0 || len(vertices) == 0 ||
	   u64(len(vertices)) > u64(max(u32)) {
		return 0, .Invalid_Argument
	}
	heap := vertex_manager_find_heap(manager, heap_name)
	if heap == nil do return 0, .Invalid_Argument
	if status := validate_vertex_upload(
		manager,
		heap,
		u32(len(vertices)),
		vk.DeviceSize(size_of(T)),
		source_stride,
	); status != .Ok {
		return 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return 0, status
	allocation, ok := vertex_manager_alloc_vertices(manager, heap_name, vertices, source_stride)
	if !ok do return 0, .Native_Failure
	return allocation.start_index, .Ok
}

ez_gfx_vertex_manager_upload_raw :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	heap_name: string,
	data: rawptr,
	element_count: u32,
	element_size: vk.DeviceSize,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	if manager == nil || len(heap_name) == 0 || data == nil || element_count == 0 || element_size == 0 {
		return 0, .Invalid_Argument
	}
	heap := vertex_manager_find_heap(manager, heap_name)
	if heap == nil do return 0, .Invalid_Argument
	if status := validate_vertex_upload(manager, heap, element_count, element_size, 0); status != .Ok {
		return 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return 0, status
	allocation, ok := vertex_manager_schedule_upload(
		manager,
		.Vertices,
		heap_name,
		heap,
		data,
		element_count,
		element_size,
	)
	if !ok do return 0, .Native_Failure
	return allocation.start_index, .Ok
}
ez_gfx_load_texture :: proc(
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> (texture_id: Ez_Gfx_Texture_ID, status: Ez_Gfx_Texture_Error) {
	if status := validate_texture_load_arguments(regions, desc); status != .None {
		return 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return 0, .Invalid_Context
	return load_texture(regions, desc)
}


@(private)
texture_load_desc_from_c :: proc(desc: ^Ez_Gfx_C_Texture_Desc) -> Ez_Gfx_Load_Texture_Desc {
	return Ez_Gfx_Load_Texture_Desc {
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
		debug_label        = shader_cstring_to_string(desc.debug_label),
	}
}

ez_gfx_texture_load_bytes :: proc(
	data: rawptr,
	data_size: u64,
	desc: ^Ez_Gfx_C_Texture_Desc,
) -> (
	owned_data: []u8,
	texture_id: Ez_Gfx_Texture_ID,
	status: Ez_Gfx_Texture_Error,
) {
	if data == nil || data_size == 0 || data_size > u64(max(int)) ||
	   desc == nil || desc.destination_format != 0 {
		return nil, 0, .Invalid_Arguments
	}
	odin_desc := texture_load_desc_from_c(desc)
	source_data := cast([^]u8)data
	source_regions := [1]Ez_Gfx_Texture_Memory_Region{{data = source_data[:int(data_size)]}}
	if status := validate_texture_load_arguments(source_regions[:], odin_desc); status != .None {
		return nil, 0, status
	}
	if status := validate_context(get_current_ctx()); status != .Ok {
		return nil, 0, .Invalid_Context
	}
	// C input may expire after the adapter returns, so copy only validated bytes.
	owned_data = make([]u8, int(data_size))
	mem.copy(raw_data(owned_data), data, int(data_size))
	regions := [1]Ez_Gfx_Texture_Memory_Region{{data = owned_data}}
	texture_id, status = load_texture(regions[:], odin_desc)
	if status != .None {
		delete(owned_data)
		return nil, 0, status
	}
	return owned_data, texture_id, .None
}

ez_gfx_unload_texture :: proc(texture_id: Ez_Gfx_Texture_ID) -> Ez_Gfx_Texture_Error {
	if status := validate_context(get_current_ctx()); status != .Ok do return .Invalid_Context
	return unload_texture(texture_id)
}


@(private)
ez_gfx_begin_render :: proc(window: ^Ez_Gfx_Window) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	if window.framebuffer_width <= 0 || window.framebuffer_height <= 0 do return .Not_Ready
	if get_current_ctx().render.active do return .Not_Ready
	return status_from_bool(begin_render(window))
}


ez_gfx_finish_render :: proc() -> Ez_Gfx_Status {
	if status := validate_active_render(); status != .Ok do return status
	return status_from_bool(finish_render())
}


ez_gfx_indirect_buffer_set_draw_count :: proc(handle: ^Ez_Gfx_Indirect_Buffer_Handle, count: u32) -> Ez_Gfx_Status {
	if handle == nil || !handle.ok || handle.buffer == nil || count > handle.capacity {
		return .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return status
	if handle.frame_id != get_current_ctx().render.frame_id do return .Invalid_Argument
	return status_from_bool(indirect_buffer_set_draw_count(handle, count))
}


ez_gfx_indirect_buffer_write_draw :: proc(
	handle: ^Ez_Gfx_Indirect_Buffer_Handle,
	index: u32,
	command: vk.DrawIndexedIndirectCommand,
) -> Ez_Gfx_Status {
	if handle == nil || !handle.ok || handle.buffer == nil || index >= handle.capacity {
		return .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return status
	if handle.frame_id != get_current_ctx().render.frame_id do return .Invalid_Argument
	return status_from_bool(indirect_buffer_write_draw(handle, index, command))
}



// C and other untyped hosts use this byte-sized boundary. It owns validation
// before invoking the internal typed structured-buffer allocator.
ez_gfx_render_acquire_structured_buffer_bytes :: proc(
	element_size, element_count: u32,
	debug_name: cstring,
) -> (
	handle: Ez_Gfx_Structured_Buffer_Handle,
	status: Ez_Gfx_Status,
) {
	if element_size == 0 || element_count == 0 || debug_name == nil {
		return handle, .Invalid_Argument
	}
	byte_count := u64(element_size) * u64(element_count)
	if byte_count > u64(max(u32)) do return handle, .Invalid_Argument
	if status := validate_active_render(); status != .Ok do return handle, status
	view := render_acquire_structured_buffer(u8, u32(byte_count), debug_name)
	if !view.handle.ok do return handle, .Native_Failure
	return view.handle, .Ok
}

ez_gfx_structured_buffer_write :: proc(
	handle: ^Ez_Gfx_Structured_Buffer_Handle,
	data: rawptr,
	data_size: u64,
) -> Ez_Gfx_Status {
	if handle == nil || !handle.ok || data_size > u64(handle.size) || data_size > u64(max(int)) {
		return .Invalid_Argument
	}
	if data_size > 0 && data == nil do return .Invalid_Argument
	if status := validate_active_render(); status != .Ok do return status
	if handle.frame_id != get_current_ctx().render.frame_id do return .Invalid_Argument
	if data_size > 0 {
		mem.copy(handle.cpu_ptr, data, int(data_size))
	}
	return .Ok
}




@(private)
ez_gfx_screenshot_save_window :: proc(window: ^Ez_Gfx_Window, path: string) -> Ez_Gfx_Status {
	if status := validate_window(window); status != .Ok do return status
	if len(path) == 0 do return .Invalid_Argument
	return status_from_bool(screenshot_save_window(window, path))
}

// Typed render entry points keep validation and status mapping at the public
// Odin boundary; internal render procedures only receive validated inputs.
ez_gfx_render_acquire_indirect_buffer :: proc(
	$T: typeid,
	element_count: u32,
	debug_name: cstring,
) -> (
	handle: Ez_Gfx_Indirect_Buffer_Handle,
	status: Ez_Gfx_Status,
) {
	indirect_stride := vk.DeviceSize(size_of(T))
	if element_count == 0 || debug_name == nil ||
	   indirect_stride < vk.DeviceSize(size_of(vk.DrawIndexedIndirectCommand)) ||
	   indirect_stride % 4 != 0 {
		return handle, .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return handle, status
	handle = render_acquire_indirect_buffer(T, element_count, debug_name)
	if !handle.ok do return handle, .Native_Failure
	return handle, .Ok
}

ez_gfx_render_acquire_structured_buffer :: proc(
	$T: typeid,
	element_count: u32,
	debug_name: cstring,
) -> (
	view: Ez_Gfx_Structured_Buffer_View(T),
	status: Ez_Gfx_Status,
) {
	element_size := u64(size_of(T))
	if element_count == 0 || element_size == 0 || debug_name == nil ||
	   element_size > u64(max(vk.DeviceSize)) / u64(element_count) {
		return view, .Invalid_Argument
	}
	if status := validate_active_render(); status != .Ok do return view, status
	view = render_acquire_structured_buffer(T, element_count, debug_name)
	if !view.handle.ok do return view, .Native_Failure
	return view, .Ok
}

@(private)
ez_gfx_render_add_compute_pipeline :: proc {
	ez_gfx_render_add_compute_pipeline_without_push_constants,
	ez_gfx_render_add_compute_pipeline_with_push_constants,
}

@(private)
ez_gfx_render_add_compute_pipeline_without_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Render_Binding,
) -> (
	descriptor: Ez_Gfx_Compute_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	return ez_gfx_render_add_compute_pipeline_raw(shader, dispatch_x, dispatch_y, dispatch_z, bindings, nil, 0)
}

@(private)
ez_gfx_render_add_compute_pipeline_with_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Render_Binding,
	push_constants: $T,
) -> (
	descriptor: Ez_Gfx_Compute_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	data := push_constants
	return ez_gfx_render_add_compute_pipeline_raw(
		shader,
		dispatch_x,
		dispatch_y,
		dispatch_z,
		bindings,
		rawptr(&data),
		u32(size_of(T)),
	)
}

@(private)
ez_gfx_render_add_vertex_pipeline :: proc {
	ez_gfx_render_add_vertex_pipeline_without_push_constants,
	ez_gfx_render_add_vertex_pipeline_with_dynamic_state_without_push_constants,
	ez_gfx_render_add_vertex_pipeline_with_dynamic_state_and_push_constants,
}

@(private)
ez_gfx_render_add_vertex_pipeline_without_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
) -> (
	descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	return ez_gfx_render_add_vertex_pipeline_raw(shader, indirect, bindings, {}, nil, 0)
}

@(private)
ez_gfx_render_add_vertex_pipeline_with_dynamic_state_without_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State,
) -> (
	descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	return ez_gfx_render_add_vertex_pipeline_raw(shader, indirect, bindings, dynamic_state, nil, 0)
}

@(private)
ez_gfx_render_add_vertex_pipeline_with_dynamic_state_and_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State,
	push_constants: $T,
) -> (
	descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor,
	status: Ez_Gfx_Status,
) {
	data := push_constants
	return ez_gfx_render_add_vertex_pipeline_raw(
		shader,
		indirect,
		bindings,
		dynamic_state,
		rawptr(&data),
		u32(size_of(T)),
	)
}

// Configuration helpers are pure reads and do not need a status result.
ez_gfx_config_hidden_window :: proc() -> bool { return config_hidden_window() }
ez_gfx_config_max_frames :: proc() -> int { return config_max_frames() }
ez_gfx_config_run_seconds :: proc() -> f64 { return config_run_seconds() }
ez_gfx_config_screenshot_enabled :: proc() -> bool { return config_screenshot_enabled() }

// Focused public helpers used by tests and by host integrations that need
// deterministic queries without taking ownership of internal managers.
@(private)
ez_gfx_ctx_next_timeline_value :: proc(ctx: ^Ez_Gfx_Ctx) -> u64 {
	if ctx == nil do return 0
	return ctx_next_timeline_value(ctx)
}

@(private)
ez_gfx_ctx_get_info :: proc(info: ^Ez_Gfx_Ctx_Info) -> Ez_Gfx_Status {
	if info == nil do return .Invalid_Argument
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	return status_from_bool(ctx_get_info(info))
}

ez_gfx_ctx_set_swapchain_present_mode :: proc(mode: vk.PresentModeKHR) -> Ez_Gfx_Status {
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	return status_from_bool(ctx_set_swapchain_present_mode(mode))
}

ez_gfx_ctx_choose_transfer_queue_family :: proc(
	queues: []vk.QueueFamilyProperties,
	graphics_queue_index: u32,
) -> u32 {
	return ctx_choose_transfer_queue_family(queues, graphics_queue_index)
}

ez_gfx_swapchain_choose_present_mode :: proc(
	available_present_modes: []vk.PresentModeKHR,
	requested: vk.PresentModeKHR,
) -> vk.PresentModeKHR {
	return swapchain_choose_present_mode(available_present_modes, requested)
}

ez_gfx_texture_decode_worker_count_from_logical :: proc(logical_cpu_count: int) -> u32 {
	return texture_decode_worker_count_from_logical(logical_cpu_count)
}

ez_gfx_ctx_resolve_texture_decode_worker_count :: proc(requested: u32) -> u32 {
	return ctx_resolve_texture_decode_worker_count(requested)
}

ez_gfx_vertex_manager_create :: proc(
	manager: ^Ez_Gfx_Vertex_Manager,
	vertex_heap_names: []string,
	vertex_stride: vk.DeviceSize,
) -> Ez_Gfx_Status {
	if manager == nil || len(vertex_heap_names) == 0 || vertex_stride == 0 {
		return .Invalid_Argument
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	if manager.vertex_heap_count < 0 ||
	   manager.vertex_heap_count > EZ_GFX_MAX_VERTEX_HEAPS ||
	   len(vertex_heap_names) > EZ_GFX_MAX_VERTEX_HEAPS - manager.vertex_heap_count {
		return .Invalid_Argument
	}
	vertex_manager_create(manager, vertex_heap_names, vertex_stride)
	return .Ok
}

@(private)
ez_gfx_shader_reflect :: proc(
	desc: Ez_Gfx_Shader_Desc,
	program: ^Ez_Gfx_Shader_Program,
) -> Ez_Gfx_Status {
	if status := validate_shader(desc, program); status != .Ok do return status
	return status_from_bool(shader_reflect(desc, program))
}

ez_gfx_render_target_describe :: proc(
	width: u32,
	height: u32,
	debug_label: cstring,
) -> (
	id: Ez_Gfx_Render_Target_Id,
	status: Ez_Gfx_Status,
) {
	if width == 0 || height == 0 || debug_label == nil ||
	   cstring_len(debug_label) >= EZ_GFX_SHADER_TARGET_NAME_MAX {
		return id, .Invalid_Argument
	}
	if status := validate_context(get_current_ctx()); status != .Ok do return id, status
	id = render_target_describe(width, height, debug_label)
	if !id.ok do return id, .Native_Failure
	return id, .Ok
}

ez_gfx_render_target_describe_handle :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	width: u32,
	height: u32,
	debug_label: cstring,
) -> (
	handle: Ez_Gfx_Render_Target_Handle,
	status: Ez_Gfx_Status,
) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	id, describe_status := ez_gfx_render_target_describe(width, height, debug_label)
	if describe_status != .Ok do return 0, describe_status
	local, err := ga.insert(&ctx.render_target_arena, id)
	if err != .None do return 0, arena_status(err)
	packed, pack_status := pack_child_handle(ctx, .Render_Target, local)
	if pack_status != .Ok {
		_ = ga.remove(&ctx.render_target_arena, local)
		return 0, pack_status
	}
	return Ez_Gfx_Render_Target_Handle(packed), .Ok
}

ez_gfx_screenshot_read_swapchain_bgra :: proc(
	swapchain: ^Ez_Gfx_Swapchain,
	pixels: ^[]u8,
) -> Ez_Gfx_Status {
	if swapchain == nil || pixels == nil do return .Invalid_Argument
	if status := validate_context(get_current_ctx()); status != .Ok do return status
	if swapchain.extent.width == 0 || swapchain.extent.height == 0 do return .Not_Ready
	return status_from_bool(screenshot_read_swapchain_bgra(swapchain, pixels))
}

ez_gfx_register_image_decoder :: proc(
	format: Ez_Gfx_Source_Texture_Format,
	callback: Ez_Gfx_Image_Decoder_Callback,
) -> Ez_Gfx_Status {
	if format > .KTX2 do return .Invalid_Argument
	return status_from_bool(register_image_decoder(format, callback))
}

ez_gfx_enable_bmp_decoder :: proc() -> Ez_Gfx_Status {
	return status_from_bool(enable_bmp_decoder())
}

ez_gfx_enable_png_decoder :: proc() -> Ez_Gfx_Status {
	return status_from_bool(enable_png_decoder())
}

ez_gfx_enable_ktx2_decoder :: proc() -> Ez_Gfx_Status {
	return status_from_bool(enable_ktx2_decoder())
}

ez_gfx_texture_manager_load :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> (texture_id: Ez_Gfx_Texture_ID, error: Ez_Gfx_Texture_Error) {
	if manager == nil || ctx == nil do return 0, .Invalid_Context
	if status := validate_texture_load_arguments(regions, desc); status != .None {
		return 0, status
	}
	return texture_manager_load(manager, ctx, regions, desc)
}

ez_gfx_texture_decode_upload_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job {
	return texture_decode_upload_job(job)
}

ez_gfx_texture_decode_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
	out_pixels: ^[]u8,
	out_width: ^u32,
	out_height: ^u32,
) -> Ez_Gfx_Texture_Error {
	return texture_decode_job(job, out_pixels, out_width, out_height)
}

ez_gfx_texture_upload_job_destroy :: proc(job: ^Ez_Gfx_Texture_Upload_Job) {
	texture_upload_job_destroy(job)
}

ez_gfx_texture_staging_size :: proc(job: ^Ez_Gfx_Texture_Upload_Job) -> vk.DeviceSize {
	if job == nil do return 0
	return texture_staging_size(job)
}

ez_gfx_texture_full_mip_count :: proc(width, height: u32) -> u32 {
	return texture_full_mip_count(width, height)
}

ez_gfx_texture_manager_alloc_slot :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
) -> (slot: ^Ez_Gfx_Texture_Record, slot_index: u32) {
	if manager == nil do return nil, 0
	return texture_manager_alloc_slot(manager)
}

ez_gfx_texture_manager_find_locked :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	id: Ez_Gfx_Texture_ID,
) -> ^Ez_Gfx_Texture_Record {
	if manager == nil do return nil
	return texture_manager_find_locked(manager, id)
}

@(private)
validate_gpu_heap_range :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	byte_size: vk.DeviceSize,
) -> Ez_Gfx_Status {
	if heap == nil || heap.stride == 0 ||
	   byte_size > max(vk.DeviceSize) - (heap.stride - 1) {
		return .Invalid_Argument
	}
	return .Ok
}

ez_gfx_gpu_heap_allocate_range :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	byte_size: vk.DeviceSize,
) -> (offset: vk.DeviceSize, status: Ez_Gfx_Status) {
	if status := validate_gpu_heap_range(heap, byte_size); status != .Ok do return 0, status
	ok: bool
	offset, ok = gpu_heap_allocate_range(heap, byte_size)
	if !ok do return 0, .Native_Failure
	return offset, .Ok
}

ez_gfx_gpu_heap_reserve_allocation :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	byte_size: vk.DeviceSize,
	element_count: u32,
) -> (
	allocation: Ez_Gfx_Vertex_Allocation,
	offset: vk.DeviceSize,
	status: Ez_Gfx_Status,
) {
	if status := validate_gpu_heap_range(heap, byte_size); status != .Ok {
		return {}, 0, status
	}
	if element_count == 0 {
		if byte_size != 0 do return {}, 0, .Invalid_Argument
	} else {
		if vk.DeviceSize(element_count) > max(vk.DeviceSize) / heap.stride ||
		   byte_size != vk.DeviceSize(element_count) * heap.stride {
			return {}, 0, .Invalid_Argument
		}
	}
	ok: bool
	allocation, offset, ok = gpu_heap_reserve_allocation(heap, byte_size, element_count)
	if !ok do return {}, 0, .Native_Failure
	return allocation, offset, .Ok
}

ez_gfx_gpu_heap_free_allocation :: proc(
	heap: ^Ez_Gfx_Gpu_Heap,
	allocation: Ez_Gfx_Vertex_Allocation,
) -> Ez_Gfx_Status {
	if heap == nil || heap.stride == 0 do return .Invalid_Argument
	if allocation.count > 0 {
		start := vk.DeviceSize(allocation.start_index)
		count := vk.DeviceSize(allocation.count)
		if start > max(vk.DeviceSize) / heap.stride ||
		   count > max(vk.DeviceSize) / heap.stride {
			return .Invalid_Argument
		}
		offset := start * heap.stride
		size := count * heap.stride
		if offset > max(vk.DeviceSize) - size || offset + size > heap.high_water {
			return .Invalid_Argument
		}
	}
	if !gpu_heap_free_allocation(heap, allocation) do return .Native_Failure
	return .Ok
}

ez_gfx_vertex_copy_strided :: proc "contextless" (
	dst: rawptr,
	dst_stride: int,
	src: rawptr,
	src_stride: int,
	element_size: int,
	element_count: int,
) -> Ez_Gfx_Status {
	if element_size <= 0 || element_count < 0 ||
	   dst_stride < element_size || src_stride < element_size {
		return .Invalid_Argument
	}
	// A zero-element transfer is a valid no-op and intentionally permits nil
	// pointers because neither pointer is dereferenced.
	if element_count == 0 do return .Ok
	if dst == nil || src == nil ||
	   element_size > max(int) / element_count ||
	   (element_count > 1 &&
		(dst_stride > (max(int) - element_size) / (element_count - 1) ||
		 src_stride > (max(int) - element_size) / (element_count - 1))) {
		return .Invalid_Argument
	}
	vertex_copy_strided(dst, dst_stride, src, src_stride, element_size, element_count)
	return .Ok
}

ez_gfx_render_dynamic_state_to_vk_topology :: proc(
	primitive_type: Ez_Gfx_Primitive_Type,
) -> vk.PrimitiveTopology {
	return render_dynamic_state_to_vk_topology(primitive_type)
}

ez_gfx_copy_shader_target_name_cstring :: proc(
	dst: []byte,
	dst_len: ^int,
	name: cstring,
) -> Ez_Gfx_Status {
	if dst_len == nil || name == nil || len(dst) < EZ_GFX_SHADER_TARGET_NAME_MAX {
		return .Invalid_Argument
	}
	name_len := 0
	name_bytes := cast([^]byte)name
	for name_len < EZ_GFX_SHADER_TARGET_NAME_MAX && name_bytes[name_len] != 0 {
		name_len += 1
	}
	if name_len == EZ_GFX_SHADER_TARGET_NAME_MAX do return .Invalid_Argument
	if !copy_shader_target_name(dst, dst_len, name, name_len) do return .Native_Failure
	return .Ok
}

ez_gfx_shader_target_name_equals_cstring :: proc(
	name: []byte,
	name_len: int,
	other: cstring,
) -> bool {
	return shader_target_name_equals_cstring(name, name_len, other)
}

@(private)
ez_gfx_shader_validate_unique_target_declarations :: proc(
	program: ^Ez_Gfx_Shader_Program,
) -> Ez_Gfx_Status {
	if program == nil do return .Invalid_Argument
	if !shader_validate_unique_target_declarations(program) do return .Native_Failure
	return .Ok
}

ez_gfx_screenshot_bgra_to_rgba :: proc(
	bgra: []u8,
	width, height: int,
) -> (rgba: []u8, status: Ez_Gfx_Status) {
	if width <= 0 || height <= 0 ||
	   width > max(int) / height ||
	   width * height > max(int) / 4 ||
	   len(bgra) != width * height * 4 {
		return nil, .Invalid_Argument
	}
	ok: bool
	rgba, ok = screenshot_bgra_to_rgba(bgra, width, height)
	if !ok do return nil, .Native_Failure
	return rgba, .Ok
}

ez_gfx_screenshot_write_png :: proc(
	path: string,
	width, height: int,
	bgra: []u8,
) -> Ez_Gfx_Status {
	if len(path) == 0 || width <= 0 || height <= 0 ||
	   width > int(max(c.int)) / 4 ||
	   height > int(max(c.int)) ||
	   width > max(int) / height ||
	   width * height > max(int) / 4 ||
	   len(bgra) != width * height * 4 {
		return .Invalid_Argument
	}
	if !screenshot_write_png(path, width, height, bgra) do return .Native_Failure
	return .Ok
}

@(private)
context_arena: ga.Arena(Ez_Gfx_Ctx)
@(private)
context_arena_ready: bool
@(private)
context_arena_mutex: sync.Mutex

@(private)
arena_status :: proc(err: ga.Error) -> Ez_Gfx_Status {
	switch err {
	case .None:
		return .Ok
	case .Invalid_Handle:
		return .Invalid_Context
	case .Out_Of_Memory, .Generation_Exhausted, .Capacity_Exhausted:
		return .Native_Failure
	}
	return .Native_Failure
}

@(private)
ensure_context_arena :: proc() -> bool {
	if context_arena_ready do return true
	sync.mutex_lock(&context_arena_mutex)
	defer sync.mutex_unlock(&context_arena_mutex)
	if context_arena_ready do return true
	if ga.init(&context_arena, runtime.default_context().allocator) != .None do return false
	context_arena_ready = true
	return true
}

@(private)
ctx_child_arenas_init :: proc(ctx: ^Ez_Gfx_Ctx) -> bool {
	if ga.init(&ctx.handle_identity_arena) != .None do return false
	if ga.init(&ctx.surface_arena) != .None do return false
	if ga.init(&ctx.shader_arena) != .None do return false
	if ga.init(&ctx.indirect_arena) != .None do return false
	if ga.init(&ctx.structured_arena) != .None do return false
	if ga.init(&ctx.render_target_arena) != .None do return false
	if ga.init(&ctx.texture_arena) != .None do return false
	return true
}

@(private)
ctx_child_arenas_destroy :: proc(ctx: ^Ez_Gfx_Ctx) {
	ga.destroy(&ctx.handle_identity_arena)
	ga.destroy(&ctx.surface_arena)
	ga.destroy(&ctx.shader_arena)
	ga.destroy(&ctx.indirect_arena)
	ga.destroy(&ctx.structured_arena)
	ga.destroy(&ctx.render_target_arena)
	ga.destroy(&ctx.texture_arena)
}

@(private)
resolve_context :: proc(handle: Ez_Gfx_Context_Handle) -> (^Ez_Gfx_Ctx, Ez_Gfx_Status) {
	if !ensure_context_arena() do return nil, .Native_Failure
	parts, ok := handle_unpack(u64(handle))
	if !ok || !parts.is_context do return nil, .Invalid_Context
	ctx, err := ga.get(&context_arena, handle_context_local(parts))
	if err != .None do return nil, arena_status(err)
	return ctx, .Ok
}

@(private)
with_context :: proc(handle: Ez_Gfx_Context_Handle) -> (^Ez_Gfx_Ctx, rawptr, Ez_Gfx_Status) {
	ctx, status := resolve_context(handle)
	if status != .Ok do return nil, nil, status
	previous := context.user_ptr
	context.user_ptr = ctx
	return ctx, previous, .Ok
}

@(private)
pack_child_handle :: proc(ctx: ^Ez_Gfx_Ctx, kind: Ez_Gfx_Handle_Resource_Kind, typed_local: ga.Handle) -> (u64, Ez_Gfx_Status) {
	identity_local, err := ga.insert(&ctx.handle_identity_arena, Ez_Gfx_Handle_Identity{kind = kind, local = typed_local})
	if err != .None do return 0, arena_status(err)
	value, ok := handle_pack_child(ctx.local_handle, identity_local)
	if !ok {
		_ = ga.remove(&ctx.handle_identity_arena, identity_local)
		return 0, .Native_Failure
	}
	return value, .Ok
}

@(private)
resolve_child_identity :: proc(ctx: ^Ez_Gfx_Ctx, packed: u64, expected_kind: Ez_Gfx_Handle_Resource_Kind) -> (identity_local, typed_local: ga.Handle, status: Ez_Gfx_Status) {
	parts, ok := handle_unpack(packed)
	if !ok || parts.is_context || handle_context_local(parts) != ctx.local_handle do return {}, {}, .Invalid_Context
	identity_local = handle_child_local(parts)
	identity, err := ga.get(&ctx.handle_identity_arena, identity_local)
	if err != .None do return {}, {}, .Invalid_Context
	if identity.kind != expected_kind do return {}, {}, .Invalid_Context
	return identity_local, identity.local, .Ok
}

@(private)
remove_child_identity :: proc(ctx: ^Ez_Gfx_Ctx, packed: u64, expected_kind: Ez_Gfx_Handle_Resource_Kind) -> (typed_local: ga.Handle, status: Ez_Gfx_Status) {
	identity_local, local, identity_status := resolve_child_identity(ctx, packed, expected_kind)
	if identity_status != .Ok do return {}, identity_status
	_ = ga.remove(&ctx.handle_identity_arena, identity_local)
	return local, .Ok
}

@(private)
resolve_surface :: proc(ctx: ^Ez_Gfx_Ctx, handle: Ez_Gfx_Surface_Handle) -> (^Ez_Gfx_Window, Ez_Gfx_Status) {
	_, local, status := resolve_child_identity(ctx, u64(handle), .Surface)
	if status != .Ok do return nil, status
	window, err := ga.get(&ctx.surface_arena, local)
	if err != .None do return nil, .Invalid_Context
	return window, .Ok
}

@(private)
resolve_shader :: proc(ctx: ^Ez_Gfx_Ctx, handle: Ez_Gfx_Shader_Handle) -> (^Ez_Gfx_Shader_Program, Ez_Gfx_Status) {
	_, local, status := resolve_child_identity(ctx, u64(handle), .Shader)
	if status != .Ok do return nil, status
	shader, err := ga.get(&ctx.shader_arena, local)
	if err != .None do return nil, .Invalid_Context
	return shader, .Ok
}

@(private)
resolve_indirect :: proc(ctx: ^Ez_Gfx_Ctx, handle: Ez_Gfx_Indirect_Handle) -> (^Ez_Gfx_Indirect_Buffer_Handle, Ez_Gfx_Status) {
	_, local, status := resolve_child_identity(ctx, u64(handle), .Indirect)
	if status != .Ok do return nil, status
	indirect, err := ga.get(&ctx.indirect_arena, local)
	if err != .None do return nil, .Invalid_Context
	return indirect, .Ok
}

@(private)
resolve_structured :: proc(ctx: ^Ez_Gfx_Ctx, handle: Ez_Gfx_Structured_Handle) -> (^Ez_Gfx_Structured_Buffer_Handle, Ez_Gfx_Status) {
	_, local, status := resolve_child_identity(ctx, u64(handle), .Structured)
	if status != .Ok do return nil, status
	structured, err := ga.get(&ctx.structured_arena, local)
	if err != .None do return nil, .Invalid_Context
	return structured, .Ok
}

@(private)
resolve_texture :: proc(ctx: ^Ez_Gfx_Ctx, handle: Ez_Gfx_Texture_Handle) -> (Ez_Gfx_Texture_ID, ga.Handle, Ez_Gfx_Texture_Error) {
	_, local, status := resolve_child_identity(ctx, u64(handle), .Texture)
	if status != .Ok do return 0, {}, .Invalid_Context
	texture, err := ga.get(&ctx.texture_arena, local)
	if err != .None do return 0, {}, .Not_Found
	return texture^, local, .None
}

ez_gfx_context_create :: proc(desc: Ez_Gfx_Ctx_Desc = {}) -> (handle: Ez_Gfx_Context_Handle, status: Ez_Gfx_Status) {
	if !ensure_context_arena() do return 0, .Native_Failure
	if desc.surface_platform != EZ_GFX_SURFACE_PLATFORM_GLFW && desc.surface_platform != EZ_GFX_SURFACE_PLATFORM_WIN32 {
		return 0, .Invalid_Argument
	}
	local, err := ga.insert(&context_arena, Ez_Gfx_Ctx{})
	if err != .None do return 0, arena_status(err)
	ctx, get_err := ga.get(&context_arena, local)
	if get_err != .None do return 0, arena_status(get_err)
	ctx.local_handle = local
	if !ctx_child_arenas_init(ctx) {
		_ = ga.remove(&context_arena, local)
		return 0, .Native_Failure
	}
	packed, pack_ok := handle_pack_context(local)
	if !pack_ok {
		ctx_child_arenas_destroy(ctx)
		_ = ga.remove(&context_arena, local)
		return 0, .Native_Failure
	}
	previous := context.user_ptr
	context.user_ptr = ctx
	status = ez_gfx_ctx_create_instance(ctx, desc)
	context.user_ptr = previous
	if status != .Ok {
		ctx_child_arenas_destroy(ctx)
		_ = ga.remove(&context_arena, local)
		return 0, status
	}
	return packed, .Ok
}

ez_gfx_context_wait_idle :: proc(handle: Ez_Gfx_Context_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	_ = ctx
	return ez_gfx_ctx_wait_idle()
}

ez_gfx_context_destroy :: proc(handle: Ez_Gfx_Context_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	for {
		if ga.count(&ctx.surface_arena) == 0 do break
		removed := false
		for slot, index in ctx.surface_arena.slots {
			if slot.occupied {
				local := ga.Handle{slot = u32(index), generation = slot.generation}
				if window, err := ga.get(&ctx.surface_arena, local); err == .None {
					window_destroy(window)
				}
				_ = ga.remove(&ctx.surface_arena, local)
				removed = true
				break
			}
		}
		if !removed do break
	}
	for {
		if ga.count(&ctx.shader_arena) == 0 do break
		removed := false
		for slot, index in ctx.shader_arena.slots {
			if slot.occupied {
				local := ga.Handle{slot = u32(index), generation = slot.generation}
				if shader, err := ga.get(&ctx.shader_arena, local); err == .None {
					shader_destroy(shader)
				}
				_ = ga.remove(&ctx.shader_arena, local)
				removed = true
				break
			}
		}
		if !removed do break
	}
	_ = ez_gfx_ctx_destroy()
	for bytes in ctx.c_texture_data do delete(bytes)
	if raw_data(ctx.c_texture_data) != nil do delete(ctx.c_texture_data)
	for bytes in ctx.imgui_texture_data do delete(bytes)
	if raw_data(ctx.imgui_texture_data) != nil do delete(ctx.imgui_texture_data)
	local := ctx.local_handle
	handle_identity_arena := ctx.handle_identity_arena
	surface_arena := ctx.surface_arena
	shader_arena := ctx.shader_arena
	indirect_arena := ctx.indirect_arena
	structured_arena := ctx.structured_arena
	render_target_arena := ctx.render_target_arena
	texture_arena := ctx.texture_arena
	_ = ga.remove(&context_arena, local)
	ga.clear(&handle_identity_arena)
	ga.destroy(&handle_identity_arena)
	ga.destroy(&surface_arena)
	ga.destroy(&shader_arena)
	ga.destroy(&indirect_arena)
	ga.destroy(&structured_arena)
	ga.destroy(&render_target_arena)
	ga.destroy(&texture_arena)
	return .Ok
}

ez_gfx_surface_create :: proc(context_handle: Ez_Gfx_Context_Handle, desc: Ez_Gfx_Surface_Desc) -> (handle: Ez_Gfx_Surface_Handle, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	window := Ez_Gfx_Window {
		native_window = desc.native_window,
		native_display = desc.native_display,
		surface_platform = desc.platform,
		cache_presented_snapshots = desc.cache_presented_snapshots,
		framebuffer_width = c.int(desc.width),
		framebuffer_height = c.int(desc.height),
	}
	local, err := ga.insert(&ctx.surface_arena, window)
	if err != .None do return 0, arena_status(err)
	window_ptr, get_err := ga.get(&ctx.surface_arena, local)
	if get_err != .None {
		_ = ga.remove(&ctx.surface_arena, local)
		return 0, arena_status(get_err)
	}
	status = ez_gfx_window_create_surface(window_ptr)
	if status != .Ok {
		_ = ga.remove(&ctx.surface_arena, local)
		return 0, status
	}
	packed, pack_status := pack_child_handle(ctx, .Surface, local)
	if pack_status != .Ok {
		window_destroy(window_ptr)
		_ = ga.remove(&ctx.surface_arena, local)
		return 0, pack_status
	}
	return Ez_Gfx_Surface_Handle(packed), .Ok
}

ez_gfx_surface_destroy :: proc(context_handle: Ez_Gfx_Context_Handle, surface_handle: Ez_Gfx_Surface_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	local, identity_status := remove_child_identity(ctx, u64(surface_handle), .Surface)
	if identity_status != .Ok do return identity_status
	window, err := ga.get(&ctx.surface_arena, local)
	if err != .None do return .Invalid_Context
	status = ez_gfx_window_destroy(window)
	_ = ga.remove(&ctx.surface_arena, local)
	return status
}

ez_gfx_surface_init_device :: proc(context_handle: Ez_Gfx_Context_Handle, surface_handle: Ez_Gfx_Surface_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	window, surface_status := resolve_surface(ctx, surface_handle)
	if surface_status != .Ok do return surface_status
	return ez_gfx_ctx_init_device(window.surface)
}

ez_gfx_surface_resize :: proc(context_handle: Ez_Gfx_Context_Handle, surface_handle: Ez_Gfx_Surface_Handle, width, height: u32) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	window, surface_status := resolve_surface(ctx, surface_handle)
	if surface_status != .Ok do return surface_status
	return ez_gfx_window_recreate_swapchain_u32(window, width, height)
}

ez_gfx_surface_get_extent :: proc(context_handle: Ez_Gfx_Context_Handle, surface_handle: Ez_Gfx_Surface_Handle) -> (width, height: u32, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	window, surface_status := resolve_surface(ctx, surface_handle)
	if surface_status != .Ok do return 0, 0, surface_status
	w, h, size_status := ez_gfx_window_get_framebuffer_size(window)
	return u32(max(w, 0)), u32(max(h, 0)), size_status
}

ez_gfx_surface_resize_pending :: proc(context_handle: Ez_Gfx_Context_Handle, surface_handle: Ez_Gfx_Surface_Handle) -> (bool, Ez_Gfx_Status) {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return false, status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	window, surface_status := resolve_surface(ctx, surface_handle)
	if surface_status != .Ok do return false, surface_status
	return ez_gfx_window_resize_pending(window)
}

ez_gfx_surface_set_snapshot_cache :: proc(context_handle: Ez_Gfx_Context_Handle, surface_handle: Ez_Gfx_Surface_Handle, enabled: bool) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	window, surface_status := resolve_surface(ctx, surface_handle)
	if surface_status != .Ok do return surface_status
	return ez_gfx_window_set_snapshot_cache(window, enabled)
}

ez_gfx_shader_create :: proc(context_handle: Ez_Gfx_Context_Handle, desc: Ez_Gfx_Shader_Desc) -> (handle: Ez_Gfx_Shader_Handle, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	local, err := ga.insert(&ctx.shader_arena, Ez_Gfx_Shader_Program{})
	if err != .None do return 0, arena_status(err)
	shader, get_err := ga.get(&ctx.shader_arena, local)
	if get_err != .None {
		_ = ga.remove(&ctx.shader_arena, local)
		return 0, arena_status(get_err)
	}
	status = ez_gfx_shader_compile(desc, shader)
	if status != .Ok {
		_ = ga.remove(&ctx.shader_arena, local)
		return 0, status
	}
	packed, pack_status := pack_child_handle(ctx, .Shader, local)
	if pack_status != .Ok {
		_ = ez_gfx_shader_destroy(shader)
		_ = ga.remove(&ctx.shader_arena, local)
		return 0, pack_status
	}
	return Ez_Gfx_Shader_Handle(packed), .Ok
}

ez_gfx_shader_release :: proc(context_handle: Ez_Gfx_Context_Handle, shader_handle: Ez_Gfx_Shader_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	local, identity_status := remove_child_identity(ctx, u64(shader_handle), .Shader)
	if identity_status != .Ok do return identity_status
	shader, err := ga.get(&ctx.shader_arena, local)
	if err != .None do return .Invalid_Context
	status = ez_gfx_shader_destroy(shader)
	_ = ga.remove(&ctx.shader_arena, local)
	return status
}

ez_gfx_texture_load :: proc(context_handle: Ez_Gfx_Context_Handle, regions: []Ez_Gfx_Texture_Memory_Region, desc: Ez_Gfx_Load_Texture_Desc) -> (handle: Ez_Gfx_Texture_Handle, status: Ez_Gfx_Texture_Error) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, .Invalid_Context
	context.user_ptr = ctx
	defer context.user_ptr = previous
	texture_id, texture_status := ez_gfx_load_texture(regions, desc)
	if texture_status != .None do return 0, texture_status
	local, err := ga.insert(&ctx.texture_arena, texture_id)
	if err != .None {
		_ = unload_texture(texture_id)
		return 0, .Out_Of_Memory
	}
	packed, pack_status := pack_child_handle(ctx, .Texture, local)
	if pack_status != .Ok {
		_ = ga.remove(&ctx.texture_arena, local)
		_ = unload_texture(texture_id)
		return 0, .Out_Of_Texture_Handles
	}
	return Ez_Gfx_Texture_Handle(packed), .None
}


ez_gfx_texture_binding_index :: proc(context_handle: Ez_Gfx_Context_Handle, texture_handle: Ez_Gfx_Texture_Handle) -> (u32, Ez_Gfx_Texture_Error) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, .Invalid_Context
	context.user_ptr = ctx
	defer context.user_ptr = previous
	texture_id, _, err := resolve_texture(ctx, texture_handle)
	if err != .None do return 0, err
	return u32(texture_id), .None
}
ez_gfx_texture_unload :: proc(context_handle: Ez_Gfx_Context_Handle, texture_handle: Ez_Gfx_Texture_Handle) -> Ez_Gfx_Texture_Error {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return .Invalid_Context
	context.user_ptr = ctx
	defer context.user_ptr = previous
	texture_id, local, err := resolve_texture(ctx, texture_handle)
	if err != .None do return err
	_, identity_status := remove_child_identity(ctx, u64(texture_handle), .Texture)
	if identity_status != .Ok do return .Not_Found
	remove_err := ga.remove(&ctx.texture_arena, local)
	if remove_err != .None do return .Not_Found
	return unload_texture(texture_id)
}

@(private)
resolve_public_bindings :: proc(
	ctx: ^Ez_Gfx_Ctx,
	bindings: []Ez_Gfx_Public_Render_Binding,
	out: ^[EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS]Ez_Gfx_Render_Binding,
) -> Ez_Gfx_Status {
	if len(bindings) > EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS do return .Invalid_Argument
	if len(bindings) > 0 && out == nil do return .Invalid_Argument
	for i in 0 ..< len(bindings) {
		binding := &out[i]
		public := bindings[i]
		binding^ = {}
		if public.name == nil do return .Invalid_Argument
		binding.name = public.name
		if public.structured != 0 {
			structured, status := resolve_structured(ctx, public.structured)
			if status != .Ok || structured == nil || !structured.ok do return .Invalid_Context
			binding.structured = structured^
		}
		if public.indirect != 0 {
			indirect, status := resolve_indirect(ctx, public.indirect)
			if status != .Ok || indirect == nil || !indirect.ok do return .Invalid_Context
			binding.indirect = indirect^
		}
		if public.render_target != 0 {
			_, local, identity_status := resolve_child_identity(ctx, u64(public.render_target), .Render_Target)
			if identity_status != .Ok do return identity_status
			id, err := ga.get(&ctx.render_target_arena, local)
			if err != .None || id == nil || !id.ok do return .Invalid_Context
			binding.render_target = id^
		}
	}
	return .Ok
}

ez_gfx_enable_all_decoders_for_context :: proc(context_handle: Ez_Gfx_Context_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	return ez_gfx_enable_all_decoders()
}

ez_gfx_context_get_info :: proc(context_handle: Ez_Gfx_Context_Handle, info: ^Ez_Gfx_Ctx_Info) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	return ez_gfx_ctx_get_info(info)
}

ez_gfx_context_set_present_mode :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	mode: vk.PresentModeKHR,
) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	return ez_gfx_ctx_set_swapchain_present_mode(mode)
}

ez_gfx_vertex_heap_create :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	name: string,
	capacity, stride: vk.DeviceSize,
) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	return ez_gfx_vertex_manager_add_heap(&ctx.vertex_manager, name, capacity, stride)
}

ez_gfx_index_heap_create :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	capacity: vk.DeviceSize,
	debug_name: cstring = nil,
) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	return ez_gfx_gpu_heap_create(&ctx.vertex_manager.index_heap, capacity, vk.DeviceSize(size_of(u32)), {.INDEX_BUFFER}, debug_name)
}

ez_gfx_vertex_upload_indices :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	indices: []u32,
	source_stride: vk.DeviceSize = 0,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	return ez_gfx_vertex_manager_upload_indices(&ctx.vertex_manager, indices, source_stride)
}

ez_gfx_vertex_upload :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	heap_name: string,
	vertices: []$T,
	source_stride: vk.DeviceSize = 0,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	return ez_gfx_vertex_manager_upload_vertices(&ctx.vertex_manager, heap_name, vertices, source_stride)
}

ez_gfx_vertex_upload_raw :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	heap_name: string,
	data: rawptr,
	element_count: u32,
	element_size: vk.DeviceSize,
) -> (start_index: u32, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	return ez_gfx_vertex_manager_upload_raw(&ctx.vertex_manager, heap_name, data, element_count, element_size)
}

ez_gfx_begin_render_surface :: proc(context_handle: Ez_Gfx_Context_Handle, surface_handle: Ez_Gfx_Surface_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	surface, surface_status := resolve_surface(ctx, surface_handle)
	if surface_status != .Ok do return surface_status
	return ez_gfx_begin_render(surface)
}

ez_gfx_finish_render_context :: proc(context_handle: Ez_Gfx_Context_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	return ez_gfx_finish_render()
}

ez_gfx_acquire_indirect :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	capacity: u32,
	debug_name: cstring,
) -> (handle: Ez_Gfx_Indirect_Handle, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	internal, acquire_status := ez_gfx_render_acquire_indirect_buffer(vk.DrawIndexedIndirectCommand, capacity, debug_name)
	if acquire_status != .Ok do return 0, acquire_status
	local, err := ga.insert(&ctx.indirect_arena, internal)
	if err != .None do return 0, arena_status(err)
	packed, pack_status := pack_child_handle(ctx, .Indirect, local)
	if pack_status != .Ok {
		_ = ga.remove(&ctx.indirect_arena, local)
		return 0, pack_status
	}
	return Ez_Gfx_Indirect_Handle(packed), .Ok
}

ez_gfx_indirect_write_draw :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	indirect_handle: Ez_Gfx_Indirect_Handle,
	index: u32,
	command: vk.DrawIndexedIndirectCommand,
) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	indirect, indirect_status := resolve_indirect(ctx, indirect_handle)
	if indirect_status != .Ok do return indirect_status
	return ez_gfx_indirect_buffer_write_draw(indirect, index, command)
}

ez_gfx_indirect_set_draw_count :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	indirect_handle: Ez_Gfx_Indirect_Handle,
	count: u32,
) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	indirect, indirect_status := resolve_indirect(ctx, indirect_handle)
	if indirect_status != .Ok do return indirect_status
	return ez_gfx_indirect_buffer_set_draw_count(indirect, count)
}

ez_gfx_indirect_release :: proc(context_handle: Ez_Gfx_Context_Handle, indirect_handle: Ez_Gfx_Indirect_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	local, identity_status := remove_child_identity(ctx, u64(indirect_handle), .Indirect)
	if identity_status != .Ok do return identity_status
	_ = ga.remove(&ctx.indirect_arena, local)
	return .Ok
}

ez_gfx_acquire_structured :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	$T: typeid,
	element_count: u32,
	debug_name: cstring,
) -> (handle: Ez_Gfx_Structured_Handle, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	view, acquire_status := ez_gfx_render_acquire_structured_buffer(T, element_count, debug_name)
	if acquire_status != .Ok do return 0, acquire_status
	local, err := ga.insert(&ctx.structured_arena, view.handle)
	if err != .None do return 0, arena_status(err)
	packed, pack_status := pack_child_handle(ctx, .Structured, local)
	if pack_status != .Ok {
		_ = ga.remove(&ctx.structured_arena, local)
		return 0, pack_status
	}
	return Ez_Gfx_Structured_Handle(packed), .Ok
}

ez_gfx_acquire_structured_bytes :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	element_size, element_count: u32,
	debug_name: cstring,
) -> (handle: Ez_Gfx_Structured_Handle, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return 0, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	internal, acquire_status := ez_gfx_render_acquire_structured_buffer_bytes(element_size, element_count, debug_name)
	if acquire_status != .Ok do return 0, acquire_status
	local, err := ga.insert(&ctx.structured_arena, internal)
	if err != .None do return 0, arena_status(err)
	packed, pack_status := pack_child_handle(ctx, .Structured, local)
	if pack_status != .Ok {
		_ = ga.remove(&ctx.structured_arena, local)
		return 0, pack_status
	}
	return Ez_Gfx_Structured_Handle(packed), .Ok
}

ez_gfx_structured_write :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	structured_handle: Ez_Gfx_Structured_Handle,
	data: rawptr,
	data_size: u64,
) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	structured, structured_status := resolve_structured(ctx, structured_handle)
	if structured_status != .Ok do return structured_status
	return ez_gfx_structured_buffer_write(structured, data, data_size)
}

ez_gfx_structured_release :: proc(context_handle: Ez_Gfx_Context_Handle, structured_handle: Ez_Gfx_Structured_Handle) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	local, identity_status := remove_child_identity(ctx, u64(structured_handle), .Structured)
	if identity_status != .Ok do return identity_status
	_ = ga.remove(&ctx.structured_arena, local)
	return .Ok
}

ez_gfx_render_add_vertex_pipeline_handles :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	shader_handle: Ez_Gfx_Shader_Handle,
	indirect_handle: Ez_Gfx_Indirect_Handle,
	bindings: []Ez_Gfx_Public_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State = {},
	push_constant_data: rawptr = nil,
	push_constant_size: u32 = 0,
) -> (descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return descriptor, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	shader, shader_status := resolve_shader(ctx, shader_handle)
	if shader_status != .Ok do return descriptor, shader_status
	indirect, indirect_status := resolve_indirect(ctx, indirect_handle)
	if indirect_status != .Ok do return descriptor, indirect_status
	odin_bindings: [EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS]Ez_Gfx_Render_Binding
	if binding_status := resolve_public_bindings(ctx, bindings, &odin_bindings); binding_status != .Ok {
		return descriptor, binding_status
	}
	return ez_gfx_render_add_vertex_pipeline_raw(shader, indirect^, odin_bindings[:len(bindings)], dynamic_state, push_constant_data, push_constant_size)
}

ez_gfx_render_add_compute_pipeline_handles :: proc(
	context_handle: Ez_Gfx_Context_Handle,
	shader_handle: Ez_Gfx_Shader_Handle,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Public_Render_Binding,
	push_constant_data: rawptr = nil,
	push_constant_size: u32 = 0,
) -> (descriptor: Ez_Gfx_Compute_Pipeline_Descriptor, status: Ez_Gfx_Status) {
	ctx, previous, ctx_status := with_context(context_handle)
	if ctx_status != .Ok do return descriptor, ctx_status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	shader, shader_status := resolve_shader(ctx, shader_handle)
	if shader_status != .Ok do return descriptor, shader_status
	odin_bindings: [EZ_GFX_MAX_RENDER_STRUCTURED_BINDINGS]Ez_Gfx_Render_Binding
	if binding_status := resolve_public_bindings(ctx, bindings, &odin_bindings); binding_status != .Ok {
		return descriptor, binding_status
	}
	return ez_gfx_render_add_compute_pipeline_raw(shader, dispatch_x, dispatch_y, dispatch_z, odin_bindings[:len(bindings)], push_constant_data, push_constant_size)
}

ez_gfx_screenshot_save :: proc(context_handle: Ez_Gfx_Context_Handle, surface_handle: Ez_Gfx_Surface_Handle, path: string) -> Ez_Gfx_Status {
	ctx, previous, status := with_context(context_handle)
	if status != .Ok do return status
	context.user_ptr = ctx
	defer context.user_ptr = previous
	surface, surface_status := resolve_surface(ctx, surface_handle)
	if surface_status != .Ok do return surface_status
	return ez_gfx_screenshot_save_window(surface, path)
}
