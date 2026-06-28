package ez_gfx

import sp "../vendor/odin-slang/slang"
import "core:c"
import "core:fmt"
import "vendor:glfw"
import vk "vendor:vulkan"

Ez_Gfx_Ctx :: struct {
	instance:           vk.Instance,
	physical_device:    vk.PhysicalDevice,
	device:             vk.Device,
	queue_family_index: u32,
	graphics_queue:     vk.Queue,
	command_pool:       vk.CommandPool,
	command_buffer:     vk.CommandBuffer,
	image_available:    vk.Semaphore,
	in_flight:          vk.Fence,
	slang_session:      ^sp.IGlobalSession,
	vertex_manager:     Ez_Gfx_Vertex_Manager,
	pipeline_manager:   Ez_Gfx_Pipeline_Manager,
	indirect_manager:   Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager,
}

@(thread_local)
ez_gfx_current_ctx: ^Ez_Gfx_Ctx

ez_gfx_set_current_ctx :: proc(ctx: ^Ez_Gfx_Ctx) {
	ez_gfx_current_ctx = ctx
}

ez_gfx_get_current_ctx :: proc() -> ^Ez_Gfx_Ctx {
	if ez_gfx_current_ctx == nil {
		fmt.eprintln("ez_gfx: no current context set")
	}
	return ez_gfx_current_ctx
}

vulkan_global_proc_loader :: proc(p: rawptr, name: cstring) {
	// GLFW owns platform loader lookup, so the sample does not link a Vulkan loader directly.
	(^rawptr)(p)^ = glfw.GetInstanceProcAddress(nil, name)
}

// Creates the Vulkan instance; call before creating any window surface.
ez_gfx_ctx_create_instance :: proc(ctx: ^Ez_Gfx_Ctx) -> bool {
	ez_gfx_set_current_ctx(ctx)
	vk.load_proc_addresses_custom(vulkan_global_proc_loader)

	// TODO: Add validation layers and a debug messenger before growing this beyond boilerplate.
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

	result := vk.CreateInstance(&create_info, nil, &ctx.instance)
	if result != .SUCCESS {
		fmt.eprintf("failed to create Vulkan instance: %v\n", result)
		return false
	}

	vk.load_proc_addresses(ctx.instance)
	return true
}

// Selects a present-capable device and creates command/sync resources; requires a valid surface.
ez_gfx_ctx_init_device :: proc(surface: vk.SurfaceKHR) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	if !ez_gfx_ctx_pick_physical_device(ctx, surface) do return false
	if !ez_gfx_ctx_create_device(ctx) do return false
	vk.load_proc_addresses(ctx.device)

	if !ez_gfx_ctx_create_command_resources(ctx) do return false
	if !ez_gfx_ctx_create_sync_objects(ctx) do return false
	return true
}

ez_gfx_ctx_wait_idle :: proc() {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return
	if ctx.device != nil {
		vk.DeviceWaitIdle(ctx.device)
	}
}

ez_gfx_ctx_destroy :: proc() {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return
	if ctx.device != nil {
		vk.DeviceWaitIdle(ctx.device)
		ez_gfx_vertex_manager_destroy(&ctx.vertex_manager)
		ez_gfx_pipeline_manager_destroy(&ctx.pipeline_manager)
		ez_gfx_indirect_buffer_manager_destroy(&ctx.indirect_manager)
		if ctx.image_available != vk.Semaphore(0) {
			vk.DestroySemaphore(ctx.device, ctx.image_available, nil)
			ctx.image_available = vk.Semaphore(0)
		}
		if ctx.in_flight != vk.Fence(0) {
			vk.DestroyFence(ctx.device, ctx.in_flight, nil)
			ctx.in_flight = vk.Fence(0)
		}
		if ctx.command_pool != vk.CommandPool(0) {
			vk.DestroyCommandPool(ctx.device, ctx.command_pool, nil)
			ctx.command_pool = vk.CommandPool(0)
		}
		vk.DestroyDevice(ctx.device, nil)
		ctx.device = nil
	}
	ez_gfx_shader_destroy_session(ctx)
	if ctx.instance != nil {
		vk.DestroyInstance(ctx.instance, nil)
		ctx.instance = nil
	}
	if ez_gfx_current_ctx == ctx {
		ez_gfx_current_ctx = nil
	}
}

ez_gfx_ctx_pick_physical_device :: proc(ctx: ^Ez_Gfx_Ctx, surface: vk.SurfaceKHR) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(ctx.instance, &count, nil)
	if count == 0 {
		fmt.eprintln("no Vulkan physical devices found")
		return false
	}
	if count > 16 do count = 16

	devices: [16]vk.PhysicalDevice
	vk.EnumeratePhysicalDevices(ctx.instance, &count, &devices[0])

	for device in devices[:count] {
		queue_index: u32
		if ez_gfx_ctx_is_device_suitable(device, surface, &queue_index) {
			ctx.physical_device = device
			ctx.queue_family_index = queue_index
			return true
		}
	}

	fmt.eprintln(
		"no suitable Vulkan device with graphics, presentation, and swapchain support found",
	)
	return false
}

ez_gfx_ctx_is_device_suitable :: proc(
	device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	queue_index: ^u32,
) -> bool {
	if !ez_gfx_ctx_device_supports_extension(device, vk.KHR_SWAPCHAIN_EXTENSION_NAME) {
		return false
	}
	if !ez_gfx_ctx_device_supports_required_features(device) {
		return false
	}

	queue_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_count, nil)
	if queue_count == 0 do return false
	if queue_count > 32 do queue_count = 32

	queues: [32]vk.QueueFamilyProperties
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_count, &queues[0])
	for queue, i in queues[:queue_count] {
		present_supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), surface, &present_supported)
		if .GRAPHICS in queue.queueFlags && present_supported {
			queue_index^ = u32(i)
			return true
		}
	}
	return false
}

ez_gfx_ctx_device_supports_extension :: proc(
	device: vk.PhysicalDevice,
	extension_name: cstring,
) -> bool {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)
	if count == 0 do return false
	if count > 128 do count = 128

	properties: [128]vk.ExtensionProperties
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, &properties[0])
	for prop in properties[:count] {
		if ez_gfx_ctx_cstring_equals_extension(prop.extensionName, extension_name) {
			return true
		}
	}
	return false
}

ez_gfx_ctx_create_device :: proc(ctx: ^Ez_Gfx_Ctx) -> bool {
	priority: f32 = 1.0
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = ctx.queue_family_index,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}

	vulkan13_features := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		dynamicRendering = true,
		synchronization2 = true,
	}
	vulkan12_features := vk.PhysicalDeviceVulkan12Features {
		sType             = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext             = &vulkan13_features,
		drawIndirectCount = true,
	}
	vulkan11_features := vk.PhysicalDeviceVulkan11Features {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext                = &vulkan12_features,
		shaderDrawParameters = true,
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &vulkan11_features,
		features = {multiDrawIndirect = true},
	}

	device_extensions := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = &device_extensions[0],
	}

	result := vk.CreateDevice(ctx.physical_device, &create_info, nil, &ctx.device)
	if result != .SUCCESS {
		fmt.eprintf("failed to create Vulkan device: %v\n", result)
		return false
	}

	vk.GetDeviceQueue(ctx.device, ctx.queue_family_index, 0, &ctx.graphics_queue)
	return true
}

ez_gfx_ctx_device_supports_required_features :: proc(device: vk.PhysicalDevice) -> bool {
	vulkan13_features := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	}
	vulkan12_features := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &vulkan13_features,
	}
	vulkan11_features := vk.PhysicalDeviceVulkan11Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext = &vulkan12_features,
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &vulkan11_features,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features)

	if !features.features.multiDrawIndirect ||
	   !vulkan12_features.drawIndirectCount ||
	   !vulkan13_features.dynamicRendering ||
	   !vulkan13_features.synchronization2 ||
	   !vulkan11_features.shaderDrawParameters {
		fmt.eprintln("Vulkan device is missing required EasyGraphics rendering features")
		return false
	}
	return true
}

ez_gfx_ctx_create_command_resources :: proc(ctx: ^Ez_Gfx_Ctx) -> bool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = ctx.queue_family_index,
	}
	if vk.CreateCommandPool(ctx.device, &pool_info, nil, &ctx.command_pool) != .SUCCESS {
		fmt.eprintln("failed to create command pool")
		return false
	}

	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = ctx.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if vk.AllocateCommandBuffers(ctx.device, &alloc_info, &ctx.command_buffer) != .SUCCESS {
		fmt.eprintln("failed to allocate command buffer")
		return false
	}
	return true
}

ez_gfx_ctx_create_sync_objects :: proc(ctx: ^Ez_Gfx_Ctx) -> bool {
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	if vk.CreateSemaphore(ctx.device, &semaphore_info, nil, &ctx.image_available) != .SUCCESS {
		fmt.eprintln("failed to create acquire semaphore")
		return false
	}
	if vk.CreateFence(ctx.device, &fence_info, nil, &ctx.in_flight) != .SUCCESS {
		fmt.eprintln("failed to create fence")
		return false
	}
	return true
}

ez_gfx_ctx_cstring_equals_extension :: proc(
	a: [vk.MAX_EXTENSION_NAME_SIZE]byte,
	b: cstring,
) -> bool {
	b_bytes := cast([^]byte)b
	for value, i in a {
		if value != b_bytes[i] do return false
		if value == 0 do return true
	}
	return false
}
