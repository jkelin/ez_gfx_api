package ez_gfx

import "core:c"
import "core:fmt"
import "vendor:glfw"
import vk "vendor:vulkan"

MAX_WINDOWS :: 4

Ez_Gfx_Window :: struct {
	handle:              glfw.WindowHandle,
	surface:             vk.SurfaceKHR,
	framebuffer_resized: bool,
	swapchain:           Ez_Gfx_Swapchain,
}

ez_gfx_glfw_init :: proc() -> bool {
	glfw.SetErrorCallback(ez_gfx_glfw_error_callback)
	if !glfw.Init() {
		fmt.eprintln("failed to initialize GLFW")
		return false
	}
	if !glfw.VulkanSupported() {
		fmt.eprintln("GLFW reports that Vulkan is not supported")
		return false
	}
	return true
}

ez_gfx_glfw_terminate :: proc() {
	glfw.Terminate()
}

ez_gfx_glfw_error_callback :: proc "c" (code: c.int, description: cstring) {
	_ = code
	_ = description
}

ez_gfx_window_framebuffer_size_callback :: proc "c" (
	window: glfw.WindowHandle,
	width, height: c.int,
) {
	_ = width
	_ = height
	gfx_window := cast(^Ez_Gfx_Window)glfw.GetWindowUserPointer(window)
	if gfx_window != nil {
		gfx_window.framebuffer_resized = true
	}
}

// Creates a resizable GLFW window without a Vulkan surface; surface requires a Vulkan instance.
ez_gfx_window_create :: proc(
	window: ^Ez_Gfx_Window,
	title: cstring,
	width, height: c.int,
) -> bool {
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, true)
	window.handle = glfw.CreateWindow(width, height, title, nil, nil)
	if window.handle == nil {
		fmt.eprintln("failed to create GLFW window")
		return false
	}

	glfw.SetWindowUserPointer(window.handle, window)
	glfw.SetFramebufferSizeCallback(window.handle, ez_gfx_window_framebuffer_size_callback)
	glfw.SwapInterval(1)
	return true
}

ez_gfx_window_create_surface :: proc(window: ^Ez_Gfx_Window) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	if glfw.CreateWindowSurface(ctx.instance, window.handle, nil, &window.surface) != .SUCCESS {
		fmt.eprintln("failed to create Vulkan surface")
		return false
	}
	return true
}

// Waits for a non-zero framebuffer, then rebuilds the window swapchain.
ez_gfx_window_recreate_swapchain :: proc(window: ^Ez_Gfx_Window) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	width, height := ez_gfx_window_get_framebuffer_size(window)
	for width == 0 || height == 0 {
		glfw.WaitEvents()
		width, height = ez_gfx_window_get_framebuffer_size(window)
		if glfw.WindowShouldClose(window.handle) do return false
	}

	ez_gfx_render_target_manager_clear(&ctx.render_target_manager)
	return ez_gfx_swapchain_recreate(&window.swapchain, window.surface, width, height)
}

ez_gfx_window_get_framebuffer_size :: proc(window: ^Ez_Gfx_Window) -> (width, height: c.int) {
	return glfw.GetFramebufferSize(window.handle)
}

ez_gfx_window_should_close :: proc(window: ^Ez_Gfx_Window) -> b32 {
	return glfw.WindowShouldClose(window.handle)
}

ez_gfx_window_set_should_close :: proc(window: ^Ez_Gfx_Window, value: b32) {
	glfw.SetWindowShouldClose(window.handle, value)
}

ez_gfx_window_poll_events :: proc() {
	glfw.PollEvents()
}

ez_gfx_window_destroy :: proc(window: ^Ez_Gfx_Window) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return
	if ctx.device != nil {
		ez_gfx_swapchain_destroy(&window.swapchain)
	}
	if ctx.instance != nil && window.surface != vk.SurfaceKHR(0) {
		vk.DestroySurfaceKHR(ctx.instance, window.surface, nil)
		window.surface = vk.SurfaceKHR(0)
	}
	if window.handle != nil {
		glfw.DestroyWindow(window.handle)
		window.handle = nil
	}
}
