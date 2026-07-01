package ez_gfx

import sp "../vendor/odin-slang/slang"
import intrinsics "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "vendor:glfw"
import vk "vendor:vulkan"

EZ_GFX_FRAMES_IN_FLIGHT :: 2
EZ_GFX_FRAME_COMMAND_BUFFERS :: EZ_GFX_MAX_RENDER_PIPELINES + 1

Ez_Gfx_Frame_Slot :: struct {
	command_buffers:         [EZ_GFX_FRAME_COMMAND_BUFFERS]vk.CommandBuffer,
	image_available:         vk.Semaphore,
	last_submitted_timeline: u64,
}

Ez_Gfx_Validation_Message :: struct {
	severity:        vk.DebugUtilsMessageSeverityFlagsEXT,
	message_type:    vk.DebugUtilsMessageTypeFlagsEXT,
	message_id_name: cstring,
	message:         cstring,
}

Ez_Gfx_Validation_Callback :: #type proc(
	ctx: ^Ez_Gfx_Ctx,
	message: Ez_Gfx_Validation_Message,
	user_data: rawptr,
)

Ez_Gfx_Ctx_Desc :: struct {
	enable_validation:    bool,
	validation_callback:  Ez_Gfx_Validation_Callback,
	validation_user_data: rawptr,
	enable_debug:         bool,
}

Ez_Gfx_Validation_Counts :: struct {
	verbose: u32,
	info:    u32,
	warning: u32,
	error:   u32,
}

Ez_Gfx_Ctx :: struct {
	instance:                             vk.Instance,
	debug_messenger:                      vk.DebugUtilsMessengerEXT,
	physical_device:                      vk.PhysicalDevice,
	device:                               vk.Device,
	queue_family_index:                   u32,
	graphics_queue:                       vk.Queue,
	command_pool:                         vk.CommandPool,
	frame_slots:                          [EZ_GFX_FRAMES_IN_FLIGHT]Ez_Gfx_Frame_Slot,
	current_frame_slot:                   u32,
	timeline_semaphore:                   vk.Semaphore,
	timeline_counter:                     u64,
	slang_session:                        ^sp.IGlobalSession,
	vertex_manager:                       Ez_Gfx_Vertex_Manager,
	pipeline_manager:                     Ez_Gfx_Pipeline_Manager,
	indirect_manager:                     Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager,
	render_target_manager:                Ez_Gfx_Render_Target_Manager,
	enable_validation:                    bool,
	enable_debug:                         bool,
	debug_utils_enabled:                  bool,
	memory_priority_enabled:              bool,
	pageable_device_local_memory_enabled: bool,
	validation_callback:                  Ez_Gfx_Validation_Callback,
	validation_user_data:                 rawptr,
	validation_counts:                    Ez_Gfx_Validation_Counts,
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
ez_gfx_ctx_create_instance :: proc(ctx: ^Ez_Gfx_Ctx, desc: Ez_Gfx_Ctx_Desc = {}) -> bool {
	ez_gfx_set_current_ctx(ctx)
	vk.load_proc_addresses_custom(vulkan_global_proc_loader)

	ctx.enable_validation = desc.enable_validation
	ctx.enable_debug = desc.enable_debug
	ctx.validation_callback = desc.validation_callback
	ctx.validation_user_data = desc.validation_user_data
	ctx.validation_counts = {}
	ctx.debug_utils_enabled = desc.enable_validation || desc.enable_debug

	glfw_extensions := glfw.GetRequiredInstanceExtensions()
	if len(glfw_extensions) == 0 {
		fmt.eprintln("GLFW did not return Vulkan instance extensions")
		return false
	}

	if ctx.enable_validation &&
	   !ez_gfx_ctx_instance_layer_available("VK_LAYER_KHRONOS_validation") {
		fmt.eprintln("Vulkan validation requested but VK_LAYER_KHRONOS_validation is unavailable")
		return false
	}
	if ctx.enable_validation &&
	   !ez_gfx_ctx_instance_layer_available("VK_LAYER_KHRONOS_synchronization2") {
		fmt.eprintln(
			"Vulkan validation requested but VK_LAYER_KHRONOS_synchronization2 is unavailable",
		)
		return false
	}
	if ctx.debug_utils_enabled &&
	   !ez_gfx_ctx_instance_extension_available(vk.EXT_DEBUG_UTILS_EXTENSION_NAME) {
		fmt.eprintln("Vulkan debug utils requested but VK_EXT_debug_utils is unavailable")
		return false
	}

	extensions: [dynamic]cstring
	defer delete(extensions)
	for ext in glfw_extensions {
		append(&extensions, ext)
	}
	if ctx.debug_utils_enabled {
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}

	layer_names := [?]cstring{"VK_LAYER_KHRONOS_validation", "VK_LAYER_KHRONOS_synchronization2"}
	layer_count: u32
	layer_names_ptr: ^cstring
	if ctx.enable_validation {
		layer_count = u32(len(layer_names))
		layer_names_ptr = &layer_names[0]
	}

	debug_create_info := ez_gfx_ctx_debug_messenger_create_info(ctx)
	create_info_next: rawptr
	if ctx.debug_utils_enabled {
		create_info_next = &debug_create_info
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
		pNext                   = create_info_next,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		enabledLayerCount       = layer_count,
		ppEnabledLayerNames     = layer_names_ptr,
	}

	result := vk.CreateInstance(&create_info, nil, &ctx.instance)
	if result != .SUCCESS {
		fmt.eprintf("failed to create Vulkan instance: %v\n", result)
		return false
	}

	vk.load_proc_addresses(ctx.instance)
	if ctx.debug_utils_enabled {
		if vk.CreateDebugUtilsMessengerEXT(
			   ctx.instance,
			   &debug_create_info,
			   nil,
			   &ctx.debug_messenger,
		   ) !=
		   .SUCCESS {
			fmt.eprintln("failed to create Vulkan debug messenger")
			vk.DestroyInstance(ctx.instance, nil)
			ctx.instance = nil
			return false
		}
	}
	return true
}

// Selects a present-capable device and creates command/sync resources; requires a valid surface.
ez_gfx_ctx_init_device :: proc(surface: vk.SurfaceKHR) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	if !ez_gfx_ctx_pick_physical_device(ctx, surface) do return false
	ez_gfx_ctx_enable_optional_device_features(ctx)
	if !ez_gfx_ctx_create_device(ctx) do return false
	vk.load_proc_addresses(ctx.device)

	ez_gfx_ctx_name_device_objects(ctx)
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
		ez_gfx_render_target_manager_destroy(&ctx.render_target_manager)
		ez_gfx_ctx_destroy_sync_objects(ctx)
		if ctx.command_pool != vk.CommandPool(0) {
			vk.DestroyCommandPool(ctx.device, ctx.command_pool, nil)
			ctx.command_pool = vk.CommandPool(0)
		}
		vk.DestroyDevice(ctx.device, nil)
		ctx.device = nil
	}
	ez_gfx_shader_destroy_session(ctx)
	if ctx.instance != nil {
		if ctx.debug_messenger != vk.DebugUtilsMessengerEXT(0) {
			vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.debug_messenger, nil)
			ctx.debug_messenger = vk.DebugUtilsMessengerEXT(0)
		}
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

	properties, alloc_err := make([]vk.ExtensionProperties, int(count))
	if alloc_err != nil {
		fmt.eprintf("failed to allocate device extension list: %v\n", alloc_err)
		return false
	}
	defer delete(properties)
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(properties))
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
		sType                        = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext                        = &vulkan13_features,
		drawIndirectCount            = true,
		storageBuffer8BitAccess      = true,
		scalarBlockLayout            = true,
		timelineSemaphore            = true,
		bufferDeviceAddress          = true,
		vulkanMemoryModel            = true,
		vulkanMemoryModelDeviceScope = true,
	}
	vulkan11_features := vk.PhysicalDeviceVulkan11Features {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext                = &vulkan12_features,
		shaderDrawParameters = true,
	}
	pageable_features := vk.PhysicalDevicePageableDeviceLocalMemoryFeaturesEXT {
		sType                     = .PHYSICAL_DEVICE_PAGEABLE_DEVICE_LOCAL_MEMORY_FEATURES_EXT,
		pNext                     = &vulkan11_features,
		pageableDeviceLocalMemory = b32(ctx.pageable_device_local_memory_enabled),
	}
	memory_priority_features := vk.PhysicalDeviceMemoryPriorityFeaturesEXT {
		sType          = .PHYSICAL_DEVICE_MEMORY_PRIORITY_FEATURES_EXT,
		pNext          = ctx.pageable_device_local_memory_enabled ? &pageable_features : &vulkan11_features,
		memoryPriority = b32(ctx.memory_priority_enabled),
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = ctx.memory_priority_enabled ? &memory_priority_features : &vulkan11_features,
		features = {
			multiDrawIndirect = true,
			shaderInt64 = true,
			vertexPipelineStoresAndAtomics = true,
			fragmentStoresAndAtomics = true,
		},
	}

	device_extensions: [dynamic]cstring
	defer delete(device_extensions)
	append(&device_extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	if ctx.memory_priority_enabled {
		append(&device_extensions, vk.EXT_MEMORY_PRIORITY_EXTENSION_NAME)
	}
	if ctx.pageable_device_local_memory_enabled {
		append(&device_extensions, vk.EXT_PAGEABLE_DEVICE_LOCAL_MEMORY_EXTENSION_NAME)
	}
	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
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
	pageable_features := vk.PhysicalDevicePageableDeviceLocalMemoryFeaturesEXT {
		sType = .PHYSICAL_DEVICE_PAGEABLE_DEVICE_LOCAL_MEMORY_FEATURES_EXT,
	}
	memory_priority_features := vk.PhysicalDeviceMemoryPriorityFeaturesEXT {
		sType = .PHYSICAL_DEVICE_MEMORY_PRIORITY_FEATURES_EXT,
	}
	pageable_extension_supported := ez_gfx_ctx_device_supports_extension(
		device,
		vk.EXT_PAGEABLE_DEVICE_LOCAL_MEMORY_EXTENSION_NAME,
	)
	memory_priority_extension_supported := ez_gfx_ctx_device_supports_extension(
		device,
		vk.EXT_MEMORY_PRIORITY_EXTENSION_NAME,
	)
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
	if pageable_extension_supported {
		pageable_features.pNext = &vulkan11_features
	}
	if memory_priority_extension_supported {
		memory_priority_features.pNext =
			pageable_extension_supported ? &pageable_features : &vulkan11_features
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = memory_priority_extension_supported ? &memory_priority_features : &vulkan11_features,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features)

	if !features.features.multiDrawIndirect ||
	   !features.features.shaderInt64 ||
	   !features.features.vertexPipelineStoresAndAtomics ||
	   !features.features.fragmentStoresAndAtomics ||
	   !vulkan12_features.drawIndirectCount ||
	   !vulkan12_features.storageBuffer8BitAccess ||
	   !vulkan12_features.scalarBlockLayout ||
	   !vulkan12_features.timelineSemaphore ||
	   !vulkan12_features.bufferDeviceAddress ||
	   !vulkan12_features.vulkanMemoryModel ||
	   !vulkan12_features.vulkanMemoryModelDeviceScope ||
	   !vulkan13_features.dynamicRendering ||
	   !vulkan13_features.synchronization2 ||
	   !vulkan11_features.shaderDrawParameters {
		fmt.eprintln("Vulkan device is missing required EasyGraphics rendering features")
		return false
	}
	return true
}

ez_gfx_ctx_enable_optional_device_features :: proc(ctx: ^Ez_Gfx_Ctx) {
	ctx.memory_priority_enabled = false
	ctx.pageable_device_local_memory_enabled = false

	if !ez_gfx_ctx_device_supports_extension(
		ctx.physical_device,
		vk.EXT_MEMORY_PRIORITY_EXTENSION_NAME,
	) {
		return
	}

	pageable_extension_supported := ez_gfx_ctx_device_supports_extension(
		ctx.physical_device,
		vk.EXT_PAGEABLE_DEVICE_LOCAL_MEMORY_EXTENSION_NAME,
	)
	pageable_features := vk.PhysicalDevicePageableDeviceLocalMemoryFeaturesEXT {
		sType = .PHYSICAL_DEVICE_PAGEABLE_DEVICE_LOCAL_MEMORY_FEATURES_EXT,
	}
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
	if pageable_extension_supported {
		pageable_features.pNext = &vulkan11_features
	}
	memory_priority_features := vk.PhysicalDeviceMemoryPriorityFeaturesEXT {
		sType = .PHYSICAL_DEVICE_MEMORY_PRIORITY_FEATURES_EXT,
		pNext = pageable_extension_supported ? &pageable_features : &vulkan11_features,
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &memory_priority_features,
	}
	vk.GetPhysicalDeviceFeatures2(ctx.physical_device, &features)

	ctx.memory_priority_enabled = bool(memory_priority_features.memoryPriority)
	ctx.pageable_device_local_memory_enabled =
		ctx.memory_priority_enabled &&
		pageable_extension_supported &&
		bool(pageable_features.pageableDeviceLocalMemory)
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
	ez_gfx_debug_set_object_name(
		ctx,
		.COMMAND_POOL,
		ez_gfx_debug_handle(ctx.command_pool),
		"ez_gfx command pool",
	)

	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = ctx.command_pool,
		level              = .PRIMARY,
		commandBufferCount = EZ_GFX_FRAME_COMMAND_BUFFERS,
	}
	for i in 0 ..< EZ_GFX_FRAMES_IN_FLIGHT {
		if vk.AllocateCommandBuffers(
			   ctx.device,
			   &alloc_info,
			   &ctx.frame_slots[i].command_buffers[0],
		   ) !=
		   .SUCCESS {
			fmt.eprintln("failed to allocate frame command buffers")
			return false
		}
		for command_buffer, command_index in ctx.frame_slots[i].command_buffers {
			ez_gfx_debug_set_indexed_name(
				ctx,
				.COMMAND_BUFFER,
				ez_gfx_debug_handle(command_buffer),
				"ez_gfx frame command buffer",
				int(i) * EZ_GFX_FRAME_COMMAND_BUFFERS + command_index,
			)
		}
	}
	return true
}

ez_gfx_ctx_create_sync_objects :: proc(ctx: ^Ez_Gfx_Ctx) -> bool {
	binary_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	timeline_type := vk.SemaphoreTypeCreateInfo {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
		initialValue  = 0,
	}
	timeline_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &timeline_type,
	}
	if vk.CreateSemaphore(ctx.device, &timeline_info, nil, &ctx.timeline_semaphore) != .SUCCESS {
		fmt.eprintln("failed to create timeline semaphore")
		return false
	}
	ez_gfx_debug_set_object_name(
		ctx,
		.SEMAPHORE,
		ez_gfx_debug_handle(ctx.timeline_semaphore),
		"ez_gfx timeline semaphore",
	)

	for i in 0 ..< EZ_GFX_FRAMES_IN_FLIGHT {
		slot := &ctx.frame_slots[i]
		if vk.CreateSemaphore(ctx.device, &binary_info, nil, &slot.image_available) != .SUCCESS {
			fmt.eprintln("failed to create frame acquire semaphore")
			return false
		}
		ez_gfx_debug_set_indexed_name(
			ctx,
			.SEMAPHORE,
			ez_gfx_debug_handle(slot.image_available),
			"ez_gfx image available semaphore",
			int(i),
		)
	}
	return true
}

ez_gfx_ctx_destroy_sync_objects :: proc(ctx: ^Ez_Gfx_Ctx) {
	for i in 0 ..< EZ_GFX_FRAMES_IN_FLIGHT {
		slot := &ctx.frame_slots[i]
		if slot.image_available != vk.Semaphore(0) {
			vk.DestroySemaphore(ctx.device, slot.image_available, nil)
			slot.image_available = vk.Semaphore(0)
		}
		slot.last_submitted_timeline = 0
	}
	if ctx.timeline_semaphore != vk.Semaphore(0) {
		vk.DestroySemaphore(ctx.device, ctx.timeline_semaphore, nil)
		ctx.timeline_semaphore = vk.Semaphore(0)
	}
	ctx.timeline_counter = 0
}

ez_gfx_ctx_next_timeline_value :: proc(ctx: ^Ez_Gfx_Ctx) -> u64 {
	previous := intrinsics.atomic_add_explicit(&ctx.timeline_counter, u64(1), .Seq_Cst)
	return previous + 1
}

ez_gfx_ctx_wait_timeline :: proc(ctx: ^Ez_Gfx_Ctx, value: u64) -> bool {
	if value == 0 do return true
	wait_value := value
	wait_info := vk.SemaphoreWaitInfo {
		sType          = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &ctx.timeline_semaphore,
		pValues        = &wait_value,
	}
	if vk.WaitSemaphores(ctx.device, &wait_info, UINT64_MAX) != .SUCCESS {
		fmt.eprintln("failed to wait for timeline semaphore")
		return false
	}
	return true
}

ez_gfx_ctx_current_frame_slot :: proc(ctx: ^Ez_Gfx_Ctx) -> ^Ez_Gfx_Frame_Slot {
	return &ctx.frame_slots[ctx.current_frame_slot]
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

ez_gfx_ctx_instance_layer_available :: proc(layer_name: cstring) -> bool {
	count: u32
	if vk.EnumerateInstanceLayerProperties(&count, nil) != .SUCCESS {
		return false
	}
	if count == 0 do return false
	if count > 128 do count = 128

	properties: [128]vk.LayerProperties
	if vk.EnumerateInstanceLayerProperties(&count, &properties[0]) != .SUCCESS {
		return false
	}
	for prop in properties[:count] {
		if ez_gfx_ctx_cstring_equals_extension(prop.layerName, layer_name) {
			return true
		}
	}
	return false
}

ez_gfx_ctx_instance_extension_available :: proc(extension_name: cstring) -> bool {
	count: u32
	if vk.EnumerateInstanceExtensionProperties(nil, &count, nil) != .SUCCESS {
		return false
	}
	if count == 0 do return false
	if count > 128 do count = 128

	properties: [128]vk.ExtensionProperties
	if vk.EnumerateInstanceExtensionProperties(nil, &count, &properties[0]) != .SUCCESS {
		return false
	}
	for prop in properties[:count] {
		if ez_gfx_ctx_cstring_equals_extension(prop.extensionName, extension_name) {
			return true
		}
	}
	return false
}

ez_gfx_ctx_debug_messenger_create_info :: proc(
	ctx: ^Ez_Gfx_Ctx,
) -> vk.DebugUtilsMessengerCreateInfoEXT {
	return vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = ez_gfx_vulkan_debug_callback,
		pUserData = ctx,
	}
}

ez_gfx_vulkan_debug_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	ctx := cast(^Ez_Gfx_Ctx)user_data
	if ctx == nil {
		return false
	}

	if .ERROR in message_severity {
		ctx.validation_counts.error += 1
	} else if .WARNING in message_severity {
		ctx.validation_counts.warning += 1
	} else if .INFO in message_severity {
		ctx.validation_counts.info += 1
	} else if .VERBOSE in message_severity {
		ctx.validation_counts.verbose += 1
	}

	if ctx.validation_callback != nil && callback_data != nil {
		ctx.validation_callback(
			ctx,
			{
				severity = message_severity,
				message_type = message_types,
				message_id_name = callback_data.pMessageIdName,
				message = callback_data.pMessage,
			},
			ctx.validation_user_data,
		)
	}
	return false
}

ez_gfx_debug_set_object_name :: proc(
	ctx: ^Ez_Gfx_Ctx,
	object_type: vk.ObjectType,
	object_handle: u64,
	name: cstring,
) {
	if ctx == nil ||
	   !ctx.enable_debug ||
	   !ctx.debug_utils_enabled ||
	   ctx.device == nil ||
	   name == nil {
		return
	}
	if vk.SetDebugUtilsObjectNameEXT == nil {
		return
	}

	name_info := vk.DebugUtilsObjectNameInfoEXT {
		sType        = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
		objectType   = object_type,
		objectHandle = object_handle,
		pObjectName  = name,
	}
	_ = vk.SetDebugUtilsObjectNameEXT(ctx.device, &name_info)
}

ez_gfx_debug_set_indexed_name :: proc(
	ctx: ^Ez_Gfx_Ctx,
	object_type: vk.ObjectType,
	object_handle: u64,
	prefix: string,
	index: int,
) {
	name: [96]byte
	name_len := ez_gfx_debug_write_name_prefix(name[:], prefix)
	name_len = ez_gfx_debug_append_u64(name[:], name_len, u64(index))
	if name_len >= len(name) do return
	name[name_len] = 0
	ez_gfx_debug_set_object_name(ctx, object_type, object_handle, cstring(&name[0]))
}

ez_gfx_debug_set_named_object :: proc(
	ctx: ^Ez_Gfx_Ctx,
	object_type: vk.ObjectType,
	object_handle: u64,
	prefix: string,
	name_bytes: []byte,
	name_len: int,
) {
	name: [128]byte
	offset := ez_gfx_debug_write_name_prefix(name[:], prefix)
	for i in 0 ..< name_len {
		if offset + i >= len(name) - 1 do return
		name[offset + i] = name_bytes[i]
	}
	offset += name_len
	name[offset] = 0
	ez_gfx_debug_set_object_name(ctx, object_type, object_handle, cstring(&name[0]))
}

ez_gfx_debug_write_name_prefix :: proc(dst: []byte, prefix: string) -> int {
	offset := 0
	for i in 0 ..< len(prefix) {
		if offset >= len(dst) - 1 do return offset
		dst[offset] = prefix[i]
		offset += 1
	}
	if offset < len(dst) - 1 {
		dst[offset] = ' '
		offset += 1
	}
	return offset
}

ez_gfx_debug_append_u64 :: proc(dst: []byte, offset: int, value: u64) -> int {
	offset := offset
	digits: [20]byte
	count := 0
	value := value
	if value == 0 {
		digits[count] = '0'
		count += 1
	} else {
		for value > 0 {
			digits[count] = byte('0' + value % 10)
			count += 1
			value /= 10
		}
	}
	for i := count - 1; i >= 0; i -= 1 {
		if offset >= len(dst) - 1 do return offset
		dst[offset] = digits[i]
		offset += 1
	}
	return offset
}

ez_gfx_ctx_name_device_objects :: proc(ctx: ^Ez_Gfx_Ctx) {
	ez_gfx_debug_set_object_name(
		ctx,
		.INSTANCE,
		ez_gfx_debug_handle(ctx.instance),
		"ez_gfx instance",
	)
	ez_gfx_debug_set_object_name(
		ctx,
		.PHYSICAL_DEVICE,
		ez_gfx_debug_handle(ctx.physical_device),
		"ez_gfx physical device",
	)
	ez_gfx_debug_set_object_name(ctx, .DEVICE, ez_gfx_debug_handle(ctx.device), "ez_gfx device")
	ez_gfx_debug_set_object_name(
		ctx,
		.QUEUE,
		ez_gfx_debug_handle(ctx.graphics_queue),
		"ez_gfx graphics queue",
	)
}

ez_gfx_debug_handle :: proc(handle: $T) -> u64 {
	when T ==
		vk.Instance || T == vk.PhysicalDevice || T == vk.Device || T == vk.Queue || T == vk.CommandBuffer {
		return u64(uintptr(handle))
	} else {
		return u64(handle)
	}
}
