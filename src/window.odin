package ez_gfx

import "core:c"
import "core:fmt"
import "vendor:glfw"
import vk "vendor:vulkan"

// Surface platforms are selected by the parent application before instance creation.
EZ_GFX_SURFACE_PLATFORM_WIN32 :: u32(0)
EZ_GFX_SURFACE_PLATFORM_GLFW  :: u32(1)

// Ez_Gfx_Window is retained as the internal render-surface name for the native
// renderer. It never creates, destroys, polls, queries, or owns the parent window.
Ez_Gfx_Window :: struct {
	native_window:          rawptr,
	host_window:            rawptr,
	native_display:         rawptr,
	surface_platform:       u32,
	surface:                vk.SurfaceKHR,
	framebuffer_resized:    bool,	
	cache_presented_snapshots: bool,
	framebuffer_width:      c.int,
	framebuffer_height:     c.int,
	swapchain:              Ez_Gfx_Swapchain,
}

// Consumes an externally owned native window handle and creates only the Vulkan surface.
ez_gfx_window_create_surface :: proc(window: ^Ez_Gfx_Window) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil || window == nil || window.native_window == nil do return false

	result: vk.Result
	switch window.surface_platform {
	case EZ_GFX_SURFACE_PLATFORM_GLFW:
		result = glfw.CreateWindowSurface(
			ctx.instance,
			cast(glfw.WindowHandle)window.native_window,
			nil,
			&window.surface,
		)
	case EZ_GFX_SURFACE_PLATFORM_WIN32:
		when ODIN_OS == .Windows {
			create_info := vk.Win32SurfaceCreateInfoKHR {
				sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
				hinstance = vk.HINSTANCE(window.native_display),
				hwnd      = vk.HWND(window.native_window),
			}
			result = vk.CreateWin32SurfaceKHR(ctx.instance, &create_info, nil, &window.surface)
		} else {
			return false
		}
	case:
		return false
	}
	if result != .SUCCESS {
		fmt.eprintln("failed to create Vulkan surface")
		return false
	}
	ez_gfx_debug_set_object_name(
		ctx,
		.SURFACE_KHR,
		ez_gfx_debug_handle(window.surface),
		"ez_gfx parent-owned surface",
	)
	return true
}

// Recreates the swapchain using dimensions observed by the parent application.
// This function deliberately never queries or waits on a windowing library.
ez_gfx_window_recreate_swapchain :: proc(window: ^Ez_Gfx_Window, width, height: c.int) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil || window == nil || width <= 0 || height <= 0 do return false
	if window.surface == vk.SurfaceKHR(0) do return false

	vk.DeviceWaitIdle(ctx.device)
	ez_gfx_render_target_manager_clear(&ctx.render_target_manager)
	if !ez_gfx_swapchain_recreate(&window.swapchain, window.surface, width, height) {
		// Preserve the pending state so the parent can retry after a transient
		// surface change instead of rendering against an empty swapchain.
		window.framebuffer_resized = true
		return false
	}
	window.framebuffer_width = width
	window.framebuffer_height = height
	window.framebuffer_resized = false
	return true
}

// Updates the cached extent without touching the parent window. A zero-by-zero
// extent represents a minimized surface and is safe to report to the renderer.
ez_gfx_window_set_extent :: proc(window: ^Ez_Gfx_Window, width, height: c.int) -> bool {
	if window == nil || width < 0 || height < 0 do return false
	if (width == 0) != (height == 0) do return false
	window.framebuffer_width = width
	window.framebuffer_height = height
	window.framebuffer_resized = true
	return true
}

ez_gfx_window_get_framebuffer_size :: proc(window: ^Ez_Gfx_Window) -> (width, height: c.int) {
	if window == nil do return 0, 0
	return window.framebuffer_width, window.framebuffer_height
}

// Reports a present/acquire resize condition without querying the parent window.
ez_gfx_window_resize_pending :: proc(window: ^Ez_Gfx_Window) -> bool {
	return window != nil && window.framebuffer_resized
}

// Destroys only Vulkan resources. The parent window remains owned by the caller.
ez_gfx_window_destroy :: proc(window: ^Ez_Gfx_Window) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil || window == nil do return
	ez_gfx_swapchain_destroy_snapshot_cache(&window.swapchain)
	if ctx.device != nil {
		// Parent teardown may happen before context teardown; wait before
		// destroying present semaphores that a queue submission can still use.
		vk.DeviceWaitIdle(ctx.device)
		ez_gfx_swapchain_destroy(&window.swapchain)
	}
	if ctx.instance != nil && window.surface != vk.SurfaceKHR(0) {
		vk.DestroySurfaceKHR(ctx.instance, window.surface, nil)
		window.surface = vk.SurfaceKHR(0)
	}
	window.native_window = nil
	window.native_display = nil
}
