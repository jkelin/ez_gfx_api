#+test
#+private
package ez_gfx

import "core:c"
import "core:testing"
import vk "vendor:vulkan"
import win "core:sys/windows"
import "vendor:glfw"

@(test)
timeline_values_are_monotonic :: proc(t: ^testing.T) {
	ctx: Ez_Gfx_Ctx

	first := ez_gfx_ctx_next_timeline_value(&ctx)
	second := ez_gfx_ctx_next_timeline_value(&ctx)

	testing.expect_value(t, first, u64(1))
	testing.expect_value(t, second, u64(2))
}

@(test)
present_mode_selector_uses_requested_mode_when_supported :: proc(t: ^testing.T) {
	modes := [?]vk.PresentModeKHR{.FIFO, .MAILBOX}

	selected := ez_gfx_swapchain_choose_present_mode(modes[:], .MAILBOX)

	testing.expect_value(t, selected, vk.PresentModeKHR(.MAILBOX))
}

@(test)
present_mode_selector_falls_back_to_fifo_when_unsupported :: proc(t: ^testing.T) {
	modes := [?]vk.PresentModeKHR{.FIFO}

	selected := ez_gfx_swapchain_choose_present_mode(modes[:], .IMMEDIATE)

	testing.expect_value(t, selected, vk.PresentModeKHR(.FIFO))
}

@(test)
transfer_queue_selector_prefers_dedicated_transfer_family :: proc(t: ^testing.T) {
	queues := [?]vk.QueueFamilyProperties {
		{queueFlags = {.GRAPHICS, .TRANSFER}, queueCount = 1},
		{queueFlags = {.TRANSFER}, queueCount = 1},
	}

	selected := ez_gfx_ctx_choose_transfer_queue_family(queues[:], 0)

	testing.expect_value(t, selected, u32(1))
}

@(test)
transfer_queue_selector_falls_back_to_graphics_family :: proc(t: ^testing.T) {
	queues := [?]vk.QueueFamilyProperties {
		{queueFlags = {.GRAPHICS, .TRANSFER}, queueCount = 1},
	}

	selected := ez_gfx_ctx_choose_transfer_queue_family(queues[:], 0)

	testing.expect_value(t, selected, u32(0))
}

@(test)
texture_decode_worker_count_reserves_two_logical_cpus :: proc(t: ^testing.T) {
	testing.expect_value(t, ez_gfx_texture_decode_worker_count_from_logical(0), u32(1))
	testing.expect_value(t, ez_gfx_texture_decode_worker_count_from_logical(1), u32(1))
	testing.expect_value(t, ez_gfx_texture_decode_worker_count_from_logical(2), u32(1))
	testing.expect_value(t, ez_gfx_texture_decode_worker_count_from_logical(8), u32(6))
}

@(test)
explicit_texture_decode_worker_count_is_preserved :: proc(t: ^testing.T) {
	testing.expect_value(t, ez_gfx_ctx_resolve_texture_decode_worker_count(1), u32(1))
	testing.expect_value(t, ez_gfx_ctx_resolve_texture_decode_worker_count(7), u32(7))
}

@(test)
public_context_binding_survives_api_boundaries :: proc(t: ^testing.T) {
	first: Ez_Gfx_Ctx
	second: Ez_Gfx_Ctx
	info: Ez_Gfx_Ctx_Info
	previous_user_ptr := context.user_ptr
	defer {
		context.user_ptr = previous_user_ptr
	}
	first.swapchain_present_mode_count = 1
	second.swapchain_present_mode_count = 2

	context.user_ptr = &first
	testing.expect_value(t, ez_gfx_ctx_wait_idle(), Ez_Gfx_Status.Ok)
	testing.expect_value(t, ez_gfx_ctx_get_info(&info), Ez_Gfx_Status.Ok)
	testing.expect_value(t, info.swapchain_present_mode_count, u32(1))
	context.user_ptr = &second
	testing.expect_value(t, ez_gfx_ctx_get_info(&info), Ez_Gfx_Status.Ok)
	testing.expect_value(t, info.swapchain_present_mode_count, u32(2))
	context.user_ptr = nil
	testing.expect_value(t, ez_gfx_ctx_wait_idle(), Ez_Gfx_Status.Invalid_Context)
	context.user_ptr = &second
	testing.expect_value(t, ez_gfx_ctx_destroy(), Ez_Gfx_Status.Ok)
}

@(test)
forged_c_context_handles_are_rejected_without_dereference :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		ez_gfx_c_context_wait_idle(Ez_Gfx_Context_Handle(1)),
		Ez_Gfx_Status.Invalid_Context,
	)
	ez_gfx_c_context_destroy(Ez_Gfx_Context_Handle(1))
}

@(test)
c_context_final_argument_installs_odin_context :: proc(t: ^testing.T) {
	desc := Ez_Gfx_Context_Desc{
		enable_debug      = false,
		enable_validation = false,
		surface_platform  = EZ_GFX_SURFACE_PLATFORM_WIN32,
	}
	previous_user_ptr := context.user_ptr
	defer {
		context.user_ptr = previous_user_ptr
	}
	context_handle: Ez_Gfx_Context_Handle
	status := ez_gfx_c_context_create(&desc, &context_handle)
	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	if status != Ez_Gfx_Status.Ok do return
	context.user_ptr = nil
	testing.expect_value(
		t,
		ez_gfx_c_context_wait_idle(context_handle),
		Ez_Gfx_Status.Ok,
	)
	ez_gfx_c_context_destroy(context_handle)
	testing.expect_value(t, ez_gfx_ctx_wait_idle(), Ez_Gfx_Status.Invalid_Context)
}

@(test)
stale_c_context_handle_never_aliases_a_new_context :: proc(t: ^testing.T) {
	desc := Ez_Gfx_Context_Desc {
		enable_debug      = false,
		enable_validation = false,
		surface_platform  = EZ_GFX_SURFACE_PLATFORM_WIN32,
	}
	first_handle: Ez_Gfx_Context_Handle
	first_status := ez_gfx_c_context_create(&desc, &first_handle)
	testing.expect_value(t, first_status, Ez_Gfx_Status.Ok)
	if first_status != Ez_Gfx_Status.Ok do return
	ez_gfx_c_context_destroy(first_handle)

	second_handle: Ez_Gfx_Context_Handle
	second_status := ez_gfx_c_context_create(&desc, &second_handle)
	testing.expect_value(t, second_status, Ez_Gfx_Status.Ok)
	if second_status != Ez_Gfx_Status.Ok do return
	defer ez_gfx_c_context_destroy(second_handle)

	testing.expect(t, first_handle != second_handle, "opaque C context handles must not be recycled")
	testing.expect_value(
		t,
		ez_gfx_c_context_wait_idle(first_handle),
		Ez_Gfx_Status.Invalid_Context,
	)
}

@(test)
c_context_create_failure_clears_odin_context :: proc(t: ^testing.T) {
	previous_user_ptr := context.user_ptr
	defer {
		context.user_ptr = previous_user_ptr
	}
	context.user_ptr = nil
	desc := Ez_Gfx_Context_Desc{surface_platform = Ez_Gfx_Surface_Platform(99)}
	context_handle: Ez_Gfx_Context_Handle

	testing.expect_value(
		t,
		ez_gfx_c_context_create(&desc, &context_handle),
		Ez_Gfx_Status.Invalid_Argument,
	)
	testing.expect_value(t, context_handle, Ez_Gfx_Context_Handle(0))
	testing.expect_value(t, ez_gfx_ctx_wait_idle(), Ez_Gfx_Status.Invalid_Context)
}

@(test)
forged_c_resource_handles_are_rejected_with_live_context :: proc(t: ^testing.T) {
	desc := Ez_Gfx_Context_Desc {
		enable_debug      = false,
		enable_validation = false,
		surface_platform  = EZ_GFX_SURFACE_PLATFORM_WIN32,
	}
	context_handle: Ez_Gfx_Context_Handle
	status := ez_gfx_c_context_create(&desc, &context_handle)
	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	if status != Ez_Gfx_Status.Ok do return

	width, height: u32
	testing.expect_value(
		t,
		ez_gfx_c_surface_get_extent(1, &width, &height, context_handle),
		Ez_Gfx_Status.Invalid_Context,
	)
	ez_gfx_c_surface_destroy(1, context_handle)
	ez_gfx_c_shader_destroy(1, context_handle)
	ez_gfx_c_indirect_release(1, context_handle)
	ez_gfx_c_structured_release(1, context_handle)
	ez_gfx_c_context_destroy(context_handle)
}

@(test)
c_surface_rejects_live_surface_from_another_context :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		previous_user_ptr := context.user_ptr
		defer {
			context.user_ptr = previous_user_ptr
		}
		if !glfw.Init() {
			testing.expect(t, false, "GLFW must initialize to create the caller-owned test window")
			return
		}
		defer glfw.Terminate()
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		glfw.WindowHint(glfw.VISIBLE, false)
		host_window := glfw.CreateWindow(1, 1, cstring("ez-gfx C ownership"), nil, nil)
		if !testing.expect(t, host_window != nil, "GLFW must create the caller-owned test window") do return
		defer glfw.DestroyWindow(host_window)

		context_desc := Ez_Gfx_Context_Desc {
			enable_debug      = false,
			enable_validation = false,
			surface_platform  = EZ_GFX_SURFACE_PLATFORM_WIN32,
		}
		first_context, second_context: Ez_Gfx_Context_Handle
		first_status := ez_gfx_c_context_create(&context_desc, &first_context)
		testing.expect_value(t, first_status, Ez_Gfx_Status.Ok)
		if first_status != Ez_Gfx_Status.Ok do return
		defer ez_gfx_c_context_destroy(first_context)
		second_status := ez_gfx_c_context_create(&context_desc, &second_context)
		testing.expect_value(t, second_status, Ez_Gfx_Status.Ok)
		if second_status != Ez_Gfx_Status.Ok do return
		defer ez_gfx_c_context_destroy(second_context)

		surface_desc := Ez_Gfx_Surface_Desc {
			window   = rawptr(glfw.GetWin32Window(host_window)),
			display  = rawptr(win.GetModuleHandleW(nil)),
			platform = EZ_GFX_SURFACE_PLATFORM_WIN32,
			width    = 1,
			height   = 1,
		}
		surface_handle: Ez_Gfx_Surface_Handle
		surface_status := ez_gfx_c_surface_create(&surface_desc, &surface_handle, first_context)
		testing.expect_value(t, surface_status, Ez_Gfx_Status.Ok)
		if surface_status != Ez_Gfx_Status.Ok do return
		defer ez_gfx_c_surface_destroy(surface_handle, first_context)

		width, height: u32
		testing.expect_value(
			t,
			ez_gfx_c_surface_get_extent(surface_handle, &width, &height, second_context),
			Ez_Gfx_Status.Invalid_Context,
		)
	} else {
		testing.expect(t, true)
	}
}

@(test)
c_surface_rejects_extent_that_would_wrap_signed_odin_dimension :: proc(t: ^testing.T) {
	context_desc := Ez_Gfx_Context_Desc {
		enable_debug      = false,
		enable_validation = false,
		surface_platform  = EZ_GFX_SURFACE_PLATFORM_WIN32,
	}
	context_handle: Ez_Gfx_Context_Handle
	status := ez_gfx_c_context_create(&context_desc, &context_handle)
	testing.expect_value(t, status, Ez_Gfx_Status.Ok)
	if status != Ez_Gfx_Status.Ok do return
	defer ez_gfx_c_context_destroy(context_handle)

	surface_desc := Ez_Gfx_Surface_Desc {
		platform = EZ_GFX_SURFACE_PLATFORM_WIN32,
		width = u32(max(c.int)) + 1,
		height = 1,
	}
	surface_handle: Ez_Gfx_Surface_Handle
	testing.expect_value(
		t,
		ez_gfx_c_surface_create(&surface_desc, &surface_handle, context_handle),
		Ez_Gfx_Status.Invalid_Argument,
	)
	testing.expect_value(t, surface_handle, Ez_Gfx_Surface_Handle(0))
}

@(test)
public_unsigned_surface_extent_validates_before_mutating_window :: proc(t: ^testing.T) {
	ctx: Ez_Gfx_Ctx
	ctx.surface_platform = u32(EZ_GFX_SURFACE_PLATFORM_WIN32)
	marker: u8
	window := Ez_Gfx_Window {
		native_window = rawptr(&marker),
		native_display = rawptr(&marker),
		surface_platform = u32(EZ_GFX_SURFACE_PLATFORM_WIN32),
		framebuffer_width = 7,
		framebuffer_height = 9,
	}
	previous_user_ptr := context.user_ptr
	defer {
		context.user_ptr = previous_user_ptr
	}
	context.user_ptr = &ctx
	status := ez_gfx_window_create_surface_u32(&window, u32(max(c.int)) + 1, 1)

	testing.expect_value(t, status, Ez_Gfx_Status.Invalid_Argument)
	testing.expect_value(t, window.framebuffer_width, c.int(7))
	testing.expect_value(t, window.framebuffer_height, c.int(9))
}

@(test)
public_texture_argument_validation_precedes_context_lookup :: proc(t: ^testing.T) {
	pixels := [?]u8{255, 255, 255, 255}
	texture_id, status := ez_gfx_load_texture(
		{{data = pixels[:]}},
		{
			source_format = Ez_Gfx_Source_Texture_Format(255),
			width         = 1,
			height        = 1,
		},
	)
	testing.expect_value(t, texture_id, Ez_Gfx_Texture_ID(0))
	testing.expect_value(t, status, Ez_Gfx_Texture_Error.Invalid_Arguments)
}

@(test)
vertex_upload_rejects_sizes_that_cannot_fit_internal_pointer_arithmetic :: proc(t: ^testing.T) {
	manager: Ez_Gfx_Vertex_Manager
	heap_name := "vertices"
	manager.vertex_heap_count = 1
	manager.vertex_heaps[0].name_len = len(heap_name)
	for character, index in heap_name {
		manager.vertex_heaps[0].name[index] = byte(character)
	}
	byte: u8
	_, status := ez_gfx_vertex_manager_upload_raw(
		&manager,
		"vertices",
		&byte,
		1,
		vk.DeviceSize(max(int)) + 1,
	)
	testing.expect_value(t, status, Ez_Gfx_Status.Invalid_Argument)
}

@(test)
public_raw_index_upload_validates_before_context_lookup :: proc(t: ^testing.T) {
	index: u32
	_, status := ez_gfx_vertex_manager_upload_indices_raw(nil, &index, 0)

	testing.expect_value(t, status, Ez_Gfx_Status.Invalid_Argument)
}

@(test)
texture_load_bytes_rejects_invalid_input_before_copy_or_context_lookup :: proc(t: ^testing.T) {
	texture_handle, status := ez_gfx_texture_load_bytes(0, nil, 1, nil)

	testing.expect_value(t, texture_handle, Ez_Gfx_Texture_Handle(0))
	testing.expect_value(t, status, Ez_Gfx_Texture_Error.Invalid_Arguments)
}

@(test)
texture_load_bytes_rejects_invalid_descriptor_before_copy_or_context_lookup :: proc(t: ^testing.T) {
	pixels := [?]u8{255, 255, 255, 255}
	desc := Ez_Gfx_Load_Texture_Desc{destination_format = Ez_Gfx_Texture_Destination_Format(1)}
	texture_handle, status := ez_gfx_texture_load_bytes(
		0,
		&pixels[0],
		u64(len(pixels)),
		&desc,
	)

	testing.expect_value(t, texture_handle, Ez_Gfx_Texture_Handle(0))
	testing.expect_value(t, status, Ez_Gfx_Texture_Error.Invalid_Arguments)
}
