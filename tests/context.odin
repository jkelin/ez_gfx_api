#+private
package tests

import gfx "../src"
import "core:c"
import "core:testing"
import vk "vendor:vulkan"
import win "core:sys/windows"
import "vendor:glfw"

@(test)
timeline_values_are_monotonic :: proc(t: ^testing.T) {
	ctx: gfx.Ez_Gfx_Ctx

	first := gfx.ez_gfx_ctx_next_timeline_value(&ctx)
	second := gfx.ez_gfx_ctx_next_timeline_value(&ctx)

	testing.expect_value(t, first, u64(1))
	testing.expect_value(t, second, u64(2))
}

@(test)
present_mode_selector_uses_requested_mode_when_supported :: proc(t: ^testing.T) {
	modes := [?]vk.PresentModeKHR{.FIFO, .MAILBOX}

	selected := gfx.ez_gfx_swapchain_choose_present_mode(modes[:], .MAILBOX)

	testing.expect_value(t, selected, vk.PresentModeKHR(.MAILBOX))
}

@(test)
present_mode_selector_falls_back_to_fifo_when_unsupported :: proc(t: ^testing.T) {
	modes := [?]vk.PresentModeKHR{.FIFO}

	selected := gfx.ez_gfx_swapchain_choose_present_mode(modes[:], .IMMEDIATE)

	testing.expect_value(t, selected, vk.PresentModeKHR(.FIFO))
}

@(test)
transfer_queue_selector_prefers_dedicated_transfer_family :: proc(t: ^testing.T) {
	queues := [?]vk.QueueFamilyProperties {
		{queueFlags = {.GRAPHICS, .TRANSFER}, queueCount = 1},
		{queueFlags = {.TRANSFER}, queueCount = 1},
	}

	selected := gfx.ez_gfx_ctx_choose_transfer_queue_family(queues[:], 0)

	testing.expect_value(t, selected, u32(1))
}

@(test)
transfer_queue_selector_falls_back_to_graphics_family :: proc(t: ^testing.T) {
	queues := [?]vk.QueueFamilyProperties {
		{queueFlags = {.GRAPHICS, .TRANSFER}, queueCount = 1},
	}

	selected := gfx.ez_gfx_ctx_choose_transfer_queue_family(queues[:], 0)

	testing.expect_value(t, selected, u32(0))
}

@(test)
texture_decode_worker_count_reserves_two_logical_cpus :: proc(t: ^testing.T) {
	testing.expect_value(t, gfx.ez_gfx_texture_decode_worker_count_from_logical(0), u32(1))
	testing.expect_value(t, gfx.ez_gfx_texture_decode_worker_count_from_logical(1), u32(1))
	testing.expect_value(t, gfx.ez_gfx_texture_decode_worker_count_from_logical(2), u32(1))
	testing.expect_value(t, gfx.ez_gfx_texture_decode_worker_count_from_logical(8), u32(6))
}

@(test)
explicit_texture_decode_worker_count_is_preserved :: proc(t: ^testing.T) {
	testing.expect_value(t, gfx.ez_gfx_ctx_resolve_texture_decode_worker_count(1), u32(1))
	testing.expect_value(t, gfx.ez_gfx_ctx_resolve_texture_decode_worker_count(7), u32(7))
}

@(test)
public_context_binding_survives_api_boundaries :: proc(t: ^testing.T) {
	first: gfx.Ez_Gfx_Ctx
	second: gfx.Ez_Gfx_Ctx
	info: gfx.Ez_Gfx_Ctx_Info
	previous_user_ptr := context.user_ptr
	defer {
		context.user_ptr = previous_user_ptr
	}
	first.swapchain_present_mode_count = 1
	second.swapchain_present_mode_count = 2

	context.user_ptr = &first
	testing.expect_value(t, gfx.ez_gfx_ctx_wait_idle(), gfx.Ez_Gfx_Status.Ok)
	testing.expect_value(t, gfx.ez_gfx_ctx_get_info(&info), gfx.Ez_Gfx_Status.Ok)
	testing.expect_value(t, info.swapchain_present_mode_count, u32(1))
	context.user_ptr = &second
	testing.expect_value(t, gfx.ez_gfx_ctx_get_info(&info), gfx.Ez_Gfx_Status.Ok)
	testing.expect_value(t, info.swapchain_present_mode_count, u32(2))
	context.user_ptr = nil
	testing.expect_value(t, gfx.ez_gfx_ctx_wait_idle(), gfx.Ez_Gfx_Status.Invalid_Context)
	context.user_ptr = &second
	testing.expect_value(t, gfx.ez_gfx_ctx_destroy(), gfx.Ez_Gfx_Status.Ok)
}

@(test)
forged_c_context_handles_are_rejected_without_dereference :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		gfx.ez_gfx_c_context_wait_idle(1),
		gfx.EZ_GFX_C_RESULT_INVALID_CONTEXT,
	)
	gfx.ez_gfx_c_context_destroy(1)
}

@(test)
c_context_final_argument_installs_odin_context :: proc(t: ^testing.T) {
	desc := gfx.Ez_Gfx_C_Context_Desc{
		enable_debug      = 0,
		enable_validation = 0,
		surface_platform  = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	}
	previous_user_ptr := context.user_ptr
	defer {
		context.user_ptr = previous_user_ptr
	}
	context_handle: u64
	status := gfx.ez_gfx_c_context_create(&desc, &context_handle)
	testing.expect_value(t, status, gfx.EZ_GFX_C_RESULT_OK)
	if status != gfx.EZ_GFX_C_RESULT_OK do return
	context.user_ptr = nil
	testing.expect_value(
		t,
		gfx.ez_gfx_c_context_wait_idle(context_handle),
		gfx.EZ_GFX_C_RESULT_OK,
	)
	gfx.ez_gfx_c_context_destroy(context_handle)
	testing.expect_value(t, gfx.ez_gfx_ctx_wait_idle(), gfx.Ez_Gfx_Status.Invalid_Context)
}

@(test)
stale_c_context_handle_never_aliases_a_new_context :: proc(t: ^testing.T) {
	desc := gfx.Ez_Gfx_C_Context_Desc {
		enable_debug      = 0,
		enable_validation = 0,
		surface_platform  = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	}
	first_handle: u64
	first_status := gfx.ez_gfx_c_context_create(&desc, &first_handle)
	testing.expect_value(t, first_status, gfx.EZ_GFX_C_RESULT_OK)
	if first_status != gfx.EZ_GFX_C_RESULT_OK do return
	gfx.ez_gfx_c_context_destroy(first_handle)

	second_handle: u64
	second_status := gfx.ez_gfx_c_context_create(&desc, &second_handle)
	testing.expect_value(t, second_status, gfx.EZ_GFX_C_RESULT_OK)
	if second_status != gfx.EZ_GFX_C_RESULT_OK do return
	defer gfx.ez_gfx_c_context_destroy(second_handle)

	testing.expect(t, first_handle != second_handle, "opaque C context handles must not be recycled")
	testing.expect_value(
		t,
		gfx.ez_gfx_c_context_wait_idle(first_handle),
		gfx.EZ_GFX_C_RESULT_INVALID_CONTEXT,
	)
}

@(test)
c_context_create_failure_clears_odin_context :: proc(t: ^testing.T) {
	previous_user_ptr := context.user_ptr
	defer {
		context.user_ptr = previous_user_ptr
	}
	context.user_ptr = nil
	desc := gfx.Ez_Gfx_C_Context_Desc{surface_platform = 99}
	context_handle: u64

	testing.expect_value(
		t,
		gfx.ez_gfx_c_context_create(&desc, &context_handle),
		gfx.EZ_GFX_C_RESULT_INVALID_ARGUMENT,
	)
	testing.expect_value(t, context_handle, u64(0))
	testing.expect_value(t, gfx.ez_gfx_ctx_wait_idle(), gfx.Ez_Gfx_Status.Invalid_Context)
}

@(test)
forged_c_resource_handles_are_rejected_with_live_context :: proc(t: ^testing.T) {
	desc := gfx.Ez_Gfx_C_Context_Desc {
		enable_debug      = 0,
		enable_validation = 0,
		surface_platform  = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	}
	context_handle: u64
	status := gfx.ez_gfx_c_context_create(&desc, &context_handle)
	testing.expect_value(t, status, gfx.EZ_GFX_C_RESULT_OK)
	if status != gfx.EZ_GFX_C_RESULT_OK do return

	width, height: u32
	testing.expect_value(
		t,
		gfx.ez_gfx_c_surface_get_extent(1, &width, &height, context_handle),
		gfx.EZ_GFX_C_RESULT_INVALID_CONTEXT,
	)
	gfx.ez_gfx_c_surface_destroy(1, context_handle)
	gfx.ez_gfx_c_shader_destroy(1, context_handle)
	gfx.ez_gfx_c_indirect_release(1, context_handle)
	gfx.ez_gfx_c_structured_release(1, context_handle)
	gfx.ez_gfx_c_context_destroy(context_handle)
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

		context_desc := gfx.Ez_Gfx_C_Context_Desc {
			enable_debug      = 0,
			enable_validation = 0,
			surface_platform  = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
		}
		first_context, second_context: u64
		first_status := gfx.ez_gfx_c_context_create(&context_desc, &first_context)
		testing.expect_value(t, first_status, gfx.EZ_GFX_C_RESULT_OK)
		if first_status != gfx.EZ_GFX_C_RESULT_OK do return
		defer gfx.ez_gfx_c_context_destroy(first_context)
		second_status := gfx.ez_gfx_c_context_create(&context_desc, &second_context)
		testing.expect_value(t, second_status, gfx.EZ_GFX_C_RESULT_OK)
		if second_status != gfx.EZ_GFX_C_RESULT_OK do return
		defer gfx.ez_gfx_c_context_destroy(second_context)

		surface_desc := gfx.Ez_Gfx_C_Surface_Desc {
			window   = rawptr(glfw.GetWin32Window(host_window)),
			display  = rawptr(win.GetModuleHandleW(nil)),
			platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
			width    = 1,
			height   = 1,
		}
		surface_handle: u64
		surface_status := gfx.ez_gfx_c_surface_create(&surface_desc, &surface_handle, first_context)
		testing.expect_value(t, surface_status, gfx.EZ_GFX_C_RESULT_OK)
		if surface_status != gfx.EZ_GFX_C_RESULT_OK do return
		defer gfx.ez_gfx_c_surface_destroy(surface_handle, first_context)

		width, height: u32
		testing.expect_value(
			t,
			gfx.ez_gfx_c_surface_get_extent(surface_handle, &width, &height, second_context),
			gfx.EZ_GFX_C_RESULT_INVALID_CONTEXT,
		)
	} else {
		testing.expect(t, true)
	}
}

@(test)
c_surface_rejects_extent_that_would_wrap_signed_odin_dimension :: proc(t: ^testing.T) {
	context_desc := gfx.Ez_Gfx_C_Context_Desc {
		enable_debug      = 0,
		enable_validation = 0,
		surface_platform  = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
	}
	context_handle: u64
	status := gfx.ez_gfx_c_context_create(&context_desc, &context_handle)
	testing.expect_value(t, status, gfx.EZ_GFX_C_RESULT_OK)
	if status != gfx.EZ_GFX_C_RESULT_OK do return
	defer gfx.ez_gfx_c_context_destroy(context_handle)

	surface_desc := gfx.Ez_Gfx_C_Surface_Desc {
		platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
		width = u32(max(c.int)) + 1,
		height = 1,
	}
	surface_handle: u64
	testing.expect_value(
		t,
		gfx.ez_gfx_c_surface_create(&surface_desc, &surface_handle, context_handle),
		gfx.EZ_GFX_C_RESULT_INVALID_ARGUMENT,
	)
	testing.expect_value(t, surface_handle, u64(0))
}

@(test)
public_unsigned_surface_extent_validates_before_mutating_window :: proc(t: ^testing.T) {
	ctx: gfx.Ez_Gfx_Ctx
	ctx.surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32
	marker: u8
	window := gfx.Ez_Gfx_Window {
		native_window = rawptr(&marker),
		native_display = rawptr(&marker),
		surface_platform = gfx.EZ_GFX_SURFACE_PLATFORM_WIN32,
		framebuffer_width = 7,
		framebuffer_height = 9,
	}
	previous_user_ptr := context.user_ptr
	defer {
		context.user_ptr = previous_user_ptr
	}
	context.user_ptr = &ctx
	status := gfx.ez_gfx_window_create_surface_u32(&window, u32(max(c.int)) + 1, 1)

	testing.expect_value(t, status, gfx.Ez_Gfx_Status.Invalid_Argument)
	testing.expect_value(t, window.framebuffer_width, c.int(7))
	testing.expect_value(t, window.framebuffer_height, c.int(9))
}

@(test)
public_texture_argument_validation_precedes_context_lookup :: proc(t: ^testing.T) {
	pixels := [?]u8{255, 255, 255, 255}
	texture_id, status := gfx.ez_gfx_load_texture(
		{{data = pixels[:]}},
		{
			source_format = gfx.Ez_Gfx_Source_Texture_Format(255),
			width         = 1,
			height        = 1,
		},
	)
	testing.expect_value(t, texture_id, gfx.Ez_Gfx_Texture_ID(0))
	testing.expect_value(t, status, gfx.Ez_Gfx_Texture_Error.Invalid_Arguments)
}

@(test)
vertex_upload_rejects_sizes_that_cannot_fit_internal_pointer_arithmetic :: proc(t: ^testing.T) {
	manager: gfx.Ez_Gfx_Vertex_Manager
	heap_name := "vertices"
	manager.vertex_heap_count = 1
	manager.vertex_heaps[0].name_len = len(heap_name)
	for character, index in heap_name {
		manager.vertex_heaps[0].name[index] = byte(character)
	}
	byte: u8
	_, status := gfx.ez_gfx_vertex_manager_upload_raw(
		&manager,
		"vertices",
		&byte,
		1,
		vk.DeviceSize(max(int)) + 1,
	)
	testing.expect_value(t, status, gfx.Ez_Gfx_Status.Invalid_Argument)
}

@(test)
public_raw_index_upload_validates_before_context_lookup :: proc(t: ^testing.T) {
	index: u32
	_, status := gfx.ez_gfx_vertex_manager_upload_indices_raw(nil, &index, 0)

	testing.expect_value(t, status, gfx.Ez_Gfx_Status.Invalid_Argument)
}

@(test)
public_texture_bytes_validation_precedes_copy_and_context_lookup :: proc(t: ^testing.T) {
	_, texture_id, status := gfx.ez_gfx_texture_load_bytes(nil, 1, nil)

	testing.expect_value(t, texture_id, gfx.Ez_Gfx_Texture_ID(0))
	testing.expect_value(t, status, gfx.Ez_Gfx_Texture_Error.Invalid_Arguments)
}

@(test)
public_texture_bytes_invalid_c_descriptor_precedes_copy_and_context_lookup :: proc(t: ^testing.T) {
	pixels := [?]u8{255, 255, 255, 255}
	desc := gfx.Ez_Gfx_C_Texture_Desc{destination_format = 1}
	_, texture_id, status := gfx.ez_gfx_texture_load_bytes(
		&pixels[0],
		u64(len(pixels)),
		&desc,
	)

	testing.expect_value(t, texture_id, gfx.Ez_Gfx_Texture_ID(0))
	testing.expect_value(t, status, gfx.Ez_Gfx_Texture_Error.Invalid_Arguments)
}
