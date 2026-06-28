package main

import "core:c"
import "core:fmt"
import "core:math"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720
RUN_SECONDS :: 2.0
MAX_SWAPCHAIN_IMAGES :: 16
UINT64_MAX :: ~u64(0)

App :: struct {
	// TODO: Split window, device, and swapchain ownership into modules once this grows past a clear-pass sample.
	window:                  glfw.WindowHandle,
	framebuffer_resized:     bool,
	instance:                vk.Instance,
	surface:                 vk.SurfaceKHR,
	physical_device:         vk.PhysicalDevice,
	device:                  vk.Device,
	queue_family_index:      u32,
	graphics_queue:          vk.Queue,
	swapchain:               vk.SwapchainKHR,
	swapchain_format:        vk.Format,
	swapchain_extent:        vk.Extent2D,
	swapchain_images:        [MAX_SWAPCHAIN_IMAGES]vk.Image,
	swapchain_image_views:   [MAX_SWAPCHAIN_IMAGES]vk.ImageView,
	swapchain_image_layouts: [MAX_SWAPCHAIN_IMAGES]vk.ImageLayout,
	swapchain_image_count:   u32,
	command_pool:            vk.CommandPool,
	command_buffer:          vk.CommandBuffer,
	image_available:         vk.Semaphore,
	present_finished:        [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
	in_flight:               vk.Fence,
}

main :: proc() {
	app: App

	ok := init_app(&app)
	if !ok {
		cleanup(&app)
		return
	}

	run(&app)
	cleanup(&app)
}

glfw_error_callback :: proc "c" (code: c.int, description: cstring) {
	_ = code
	_ = description
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app != nil {
		app.framebuffer_resized = true
	}
}

vulkan_global_proc_loader :: proc(p: rawptr, name: cstring) {
	// GLFW owns platform loader lookup, so the sample does not link a Vulkan loader directly.
	(^rawptr)(p)^ = glfw.GetInstanceProcAddress(nil, name)
}

init_app :: proc(app: ^App) -> bool {
	if !init_glfw() do return false
	if !create_window(app) do return false
	if !init_vulkan(app) do return false
	return true
}

init_glfw :: proc() -> bool {
	glfw.SetErrorCallback(glfw_error_callback)
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

create_window :: proc(app: ^App) -> bool {
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, true)
	app.window = glfw.CreateWindow(WIDTH, HEIGHT, "ez_gfx_api Vulkan", nil, nil)
	if app.window == nil {
		fmt.eprintln("failed to create GLFW window")
		return false
	}

	glfw.SetWindowUserPointer(app.window, app)
	glfw.SetFramebufferSizeCallback(app.window, framebuffer_size_callback)
	return true
}

init_vulkan :: proc(app: ^App) -> bool {
	vk.load_proc_addresses_custom(vulkan_global_proc_loader)

	// TODO: Add validation layers and a debug messenger before growing this beyond boilerplate.
	if !create_instance(app) do return false
	vk.load_proc_addresses(app.instance)

	if glfw.CreateWindowSurface(app.instance, app.window, nil, &app.surface) != .SUCCESS {
		fmt.eprintln("failed to create Vulkan surface")
		return false
	}
	if !pick_physical_device(app) do return false
	if !create_device(app) do return false
	vk.load_proc_addresses(app.device)

	if !create_command_resources(app) do return false
	if !create_sync_objects(app) do return false
	if !recreate_swapchain(app) do return false

	return true
}

create_instance :: proc(app: ^App) -> bool {
	extensions := glfw.GetRequiredInstanceExtensions()
	if len(extensions) == 0 {
		fmt.eprintln("GLFW did not return Vulkan instance extensions")
		return false
	}

	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "ez_gfx_api",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "ez_gfx_api",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_3,
	}
	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}

	result := vk.CreateInstance(&create_info, nil, &app.instance)
	if result != .SUCCESS {
		fmt.eprintf("failed to create Vulkan instance: %v\n", result)
		return false
	}
	return true
}

pick_physical_device :: proc(app: ^App) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(app.instance, &count, nil)
	if count == 0 {
		fmt.eprintln("no Vulkan physical devices found")
		return false
	}
	if count > 16 do count = 16

	devices: [16]vk.PhysicalDevice
	vk.EnumeratePhysicalDevices(app.instance, &count, &devices[0])

	for device, i in devices[:count] {
		queue_index: u32
		if is_device_suitable(app, device, &queue_index) {
			app.physical_device = device
			app.queue_family_index = queue_index
			return true
		}
	}

	fmt.eprintln(
		"no suitable Vulkan device with graphics, presentation, and swapchain support found",
	)
	return false
}

is_device_suitable :: proc(app: ^App, device: vk.PhysicalDevice, queue_index: ^u32) -> bool {
	if !device_supports_extension(device, vk.KHR_SWAPCHAIN_EXTENSION_NAME) do return false

	queue_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_count, nil)
	if queue_count == 0 do return false
	if queue_count > 32 do queue_count = 32

	queues: [32]vk.QueueFamilyProperties
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_count, &queues[0])
	for queue, i in queues[:queue_count] {
		present_supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), app.surface, &present_supported)
		if .GRAPHICS in queue.queueFlags && present_supported {
			queue_index^ = u32(i)
			return true
		}
	}
	return false
}

device_supports_extension :: proc(device: vk.PhysicalDevice, extension_name: cstring) -> bool {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)
	if count == 0 do return false
	if count > 128 do count = 128

	properties: [128]vk.ExtensionProperties
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, &properties[0])
	for prop in properties[:count] {
		if cstring_equals_extension(prop.extensionName, extension_name) {
			return true
		}
	}
	return false
}

create_device :: proc(app: ^App) -> bool {
	priority: f32 = 1.0
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = app.queue_family_index,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}

	dynamic_rendering := vk.PhysicalDeviceDynamicRenderingFeatures {
		sType            = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
		dynamicRendering = true,
	}
	synchronization2 := vk.PhysicalDeviceSynchronization2Features {
		sType            = .PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
		pNext            = &dynamic_rendering,
		synchronization2 = true,
	}

	device_extensions := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &synchronization2,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = &device_extensions[0],
	}

	result := vk.CreateDevice(app.physical_device, &create_info, nil, &app.device)
	if result != .SUCCESS {
		fmt.eprintf("failed to create Vulkan device: %v\n", result)
		return false
	}

	vk.GetDeviceQueue(app.device, app.queue_family_index, 0, &app.graphics_queue)
	return true
}

create_command_resources :: proc(app: ^App) -> bool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = app.queue_family_index,
	}
	if vk.CreateCommandPool(app.device, &pool_info, nil, &app.command_pool) != .SUCCESS {
		fmt.eprintln("failed to create command pool")
		return false
	}

	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = app.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if vk.AllocateCommandBuffers(app.device, &alloc_info, &app.command_buffer) != .SUCCESS {
		fmt.eprintln("failed to allocate command buffer")
		return false
	}
	return true
}

create_sync_objects :: proc(app: ^App) -> bool {
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	if vk.CreateSemaphore(app.device, &semaphore_info, nil, &app.image_available) != .SUCCESS {
		fmt.eprintln("failed to create acquire semaphore")
		return false
	}
	if vk.CreateFence(app.device, &fence_info, nil, &app.in_flight) != .SUCCESS {
		fmt.eprintln("failed to create fence")
		return false
	}
	return true
}

run :: proc(app: ^App) {
	start_time := glfw.GetTime()
	for {
		glfw.PollEvents()

		if glfw.WindowShouldClose(app.window) || glfw.GetTime() - start_time >= RUN_SECONDS {
			glfw.SetWindowShouldClose(app.window, true)
			break
		}

		draw_frame(app)
	}

	// Stop GPU work before destroying swapchain and device-owned resources.
	vk.DeviceWaitIdle(app.device)
}

draw_frame :: proc(app: ^App) {
	if app.swapchain_image_count == 0 {
		recreate_swapchain(app)
		return
	}

	vk.WaitForFences(app.device, 1, &app.in_flight, true, UINT64_MAX)

	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		app.device,
		app.swapchain,
		UINT64_MAX,
		app.image_available,
		vk.Fence(0),
		&image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		recreate_swapchain(app)
		return
	}
	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		fmt.eprintf("failed to acquire swapchain image: %v\n", acquire_result)
		glfw.SetWindowShouldClose(app.window, true)
		return
	}

	vk.ResetFences(app.device, 1, &app.in_flight)
	vk.ResetCommandBuffer(app.command_buffer, {})
	record_clear_commands(app, image_index)

	wait_stage := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = app.image_available,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	command_submit := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = app.command_buffer,
	}
	signal_stage := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = app.present_finished[image_index],
		stageMask = {.ALL_COMMANDS},
	}
	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &wait_stage,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &command_submit,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal_stage,
	}

	if vk.QueueSubmit2(app.graphics_queue, 1, &submit_info, app.in_flight) != .SUCCESS {
		fmt.eprintln("failed to submit frame")
		glfw.SetWindowShouldClose(app.window, true)
		return
	}

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &app.present_finished[image_index],
		swapchainCount     = 1,
		pSwapchains        = &app.swapchain,
		pImageIndices      = &image_index,
	}
	present_result := vk.QueuePresentKHR(app.graphics_queue, &present_info)
	if present_result == .ERROR_OUT_OF_DATE_KHR ||
	   present_result == .SUBOPTIMAL_KHR ||
	   app.framebuffer_resized {
		app.framebuffer_resized = false
		recreate_swapchain(app)
	} else if present_result != .SUCCESS {
		fmt.eprintf("failed to present swapchain image: %v\n", present_result)
		glfw.SetWindowShouldClose(app.window, true)
	}
}

record_clear_commands :: proc(app: ^App, image_index: u32) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(app.command_buffer, &begin_info)

	old_layout := app.swapchain_image_layouts[image_index]
	transition_image(
		app.command_buffer,
		app.swapchain_images[image_index],
		old_layout,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
	)

	time := glfw.GetTime()
	// Best-practices validation warns on unlimited clear-color values, so keep the sine clear on registered grays.
	gray: f32 = 0.0
	if math.sin(time) > 0 {
		gray = 1.0
	}
	clear_value := vk.ClearValue {
		color = vk.ClearColorValue{float32 = {gray, gray, gray, 1.0}},
	}
	color_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = app.swapchain_image_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = clear_value,
	}
	render_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = vk.Rect2D{extent = app.swapchain_extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
	}

	vk.CmdBeginRendering(app.command_buffer, &render_info)
	vk.CmdEndRendering(app.command_buffer)

	transition_image(
		app.command_buffer,
		app.swapchain_images[image_index],
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_WRITE},
		{},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.ALL_COMMANDS},
	)

	vk.EndCommandBuffer(app.command_buffer)
	app.swapchain_image_layouts[image_index] = .PRESENT_SRC_KHR
}

transition_image :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_access, dst_access: vk.AccessFlags2,
	src_stage, dst_stage: vk.PipelineStageFlags2,
) {
	// Dynamic rendering keeps render passes out of the sample, so layouts are explicit here.
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage,
		srcAccessMask = src_access,
		dstStageMask = dst_stage,
		dstAccessMask = dst_access,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	dependency := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(command_buffer, &dependency)
}

recreate_swapchain :: proc(app: ^App) -> bool {
	width, height := glfw.GetFramebufferSize(app.window)
	for width == 0 || height == 0 {
		glfw.WaitEvents()
		width, height = glfw.GetFramebufferSize(app.window)
		if glfw.WindowShouldClose(app.window) do return false
	}

	vk.DeviceWaitIdle(app.device)
	destroy_swapchain(app)

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(app.physical_device, app.surface, &capabilities)

	format := choose_surface_format(app.physical_device, app.surface)
	extent := choose_extent(capabilities, width, height)
	image_count := capabilities.minImageCount + 1
	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = app.surface,
		minImageCount    = image_count,
		imageFormat      = format.format,
		imageColorSpace  = format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = .FIFO,
		clipped          = true,
	}

	result := vk.CreateSwapchainKHR(app.device, &create_info, nil, &app.swapchain)
	if result != .SUCCESS {
		fmt.eprintf("failed to create swapchain: %v\n", result)
		return false
	}

	app.swapchain_format = format.format
	app.swapchain_extent = extent

	count: u32
	vk.GetSwapchainImagesKHR(app.device, app.swapchain, &count, nil)
	if count > MAX_SWAPCHAIN_IMAGES {
		fmt.eprintf(
			"swapchain returned %d images; this boilerplate stores up to %d\n",
			count,
			MAX_SWAPCHAIN_IMAGES,
		)
		return false
	}
	app.swapchain_image_count = count
	vk.GetSwapchainImagesKHR(
		app.device,
		app.swapchain,
		&app.swapchain_image_count,
		&app.swapchain_images[0],
	)
	for i in 0 ..< app.swapchain_image_count {
		app.swapchain_image_layouts[i] = .UNDEFINED
	}

	return create_swapchain_image_views(app) && create_present_semaphores(app)
}

choose_surface_format :: proc(
	device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> vk.SurfaceFormatKHR {
	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, nil)
	if count > 32 do count = 32

	formats: [32]vk.SurfaceFormatKHR
	vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, &formats[0])
	for format in formats[:count] {
		if format.format == .B8G8R8A8_UNORM && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}
	return formats[0]
}

choose_extent :: proc(
	capabilities: vk.SurfaceCapabilitiesKHR,
	width, height: c.int,
) -> vk.Extent2D {
	if capabilities.currentExtent.width != ~u32(0) {
		return capabilities.currentExtent
	}
	return vk.Extent2D {
		width = math.clamp(
			u32(width),
			capabilities.minImageExtent.width,
			capabilities.maxImageExtent.width,
		),
		height = math.clamp(
			u32(height),
			capabilities.minImageExtent.height,
			capabilities.maxImageExtent.height,
		),
	}
}

create_swapchain_image_views :: proc(app: ^App) -> bool {
	for image, i in app.swapchain_images[:app.swapchain_image_count] {
		create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = app.swapchain_format,
			components = vk.ComponentMapping {
				r = .IDENTITY,
				g = .IDENTITY,
				b = .IDENTITY,
				a = .IDENTITY,
			},
			subresourceRange = vk.ImageSubresourceRange {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		if vk.CreateImageView(app.device, &create_info, nil, &app.swapchain_image_views[i]) !=
		   .SUCCESS {
			fmt.eprintln("failed to create swapchain image view")
			return false
		}
	}
	return true
}

create_present_semaphores :: proc(app: ^App) -> bool {
	info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for i in 0 ..< app.swapchain_image_count {
		if vk.CreateSemaphore(app.device, &info, nil, &app.present_finished[i]) != .SUCCESS {
			fmt.eprintln("failed to create present semaphore")
			return false
		}
	}
	return true
}

destroy_swapchain :: proc(app: ^App) {
	for i in 0 ..< app.swapchain_image_count {
		if app.present_finished[i] != vk.Semaphore(0) {
			vk.DestroySemaphore(app.device, app.present_finished[i], nil)
		}
		if app.swapchain_image_views[i] != vk.ImageView(0) {
			vk.DestroyImageView(app.device, app.swapchain_image_views[i], nil)
		}
		app.present_finished[i] = vk.Semaphore(0)
		app.swapchain_image_views[i] = vk.ImageView(0)
		app.swapchain_images[i] = vk.Image(0)
		app.swapchain_image_layouts[i] = .UNDEFINED
	}
	app.swapchain_image_count = 0

	if app.swapchain != vk.SwapchainKHR(0) {
		vk.DestroySwapchainKHR(app.device, app.swapchain, nil)
	}
	app.swapchain = vk.SwapchainKHR(0)
}

cleanup :: proc(app: ^App) {
	if app.device != nil {
		vk.DeviceWaitIdle(app.device)
		destroy_swapchain(app)
		if app.image_available != vk.Semaphore(0) {
			vk.DestroySemaphore(app.device, app.image_available, nil)
			app.image_available = vk.Semaphore(0)
		}
		if app.in_flight != vk.Fence(0) {
			vk.DestroyFence(app.device, app.in_flight, nil)
			app.in_flight = vk.Fence(0)
		}
		if app.command_pool != vk.CommandPool(0) {
			vk.DestroyCommandPool(app.device, app.command_pool, nil)
			app.command_pool = vk.CommandPool(0)
		}
		vk.DestroyDevice(app.device, nil)
		app.device = nil
	}
	if app.instance != nil {
		if app.surface != vk.SurfaceKHR(0) {
			vk.DestroySurfaceKHR(app.instance, app.surface, nil)
			app.surface = vk.SurfaceKHR(0)
		}
		vk.DestroyInstance(app.instance, nil)
		app.instance = nil
	}
	if app.window != nil {
		glfw.DestroyWindow(app.window)
		app.window = nil
	}
	glfw.Terminate()
}

cstring_equals_extension :: proc(a: [vk.MAX_EXTENSION_NAME_SIZE]byte, b: cstring) -> bool {
	b_bytes := cast([^]byte)b
	for value, i in a {
		if value != b_bytes[i] do return false
		if value == 0 do return true
	}
	return false
}
