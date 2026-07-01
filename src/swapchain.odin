package ez_gfx

import "core:c"
import "core:fmt"
import "core:math"
import vk "vendor:vulkan"

MAX_SWAPCHAIN_IMAGES :: 16

Ez_Gfx_Swapchain :: struct {
	handle:               vk.SwapchainKHR,
	format:               vk.Format,
	extent:               vk.Extent2D,
	present_mode:         vk.PresentModeKHR,
	images:               [MAX_SWAPCHAIN_IMAGES]vk.Image,
	image_views:          [MAX_SWAPCHAIN_IMAGES]vk.ImageView,
	image_layouts:        [MAX_SWAPCHAIN_IMAGES]vk.ImageLayout,
	last_write_timeline:  [MAX_SWAPCHAIN_IMAGES]u64,
	present_ready:        [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
	image_count:          u32,
	last_presented_index: u32,
	has_presented_image:  bool,
}

ez_gfx_swapchain_recreate :: proc(
	swapchain: ^Ez_Gfx_Swapchain,
	surface: vk.SurfaceKHR,
	width, height: c.int,
) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	old_handle := swapchain.handle
	if old_handle != vk.SwapchainKHR(0) {
		ez_gfx_swapchain_destroy_image_resources(swapchain)
	}

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, surface, &capabilities)

	format := ez_gfx_swapchain_choose_surface_format(ctx.physical_device, surface)
	extent := ez_gfx_swapchain_choose_extent(capabilities, width, height)
	present_mode := ctx.swapchain_present_mode
	image_count := capabilities.minImageCount + 1
	if ez_gfx_swapchain_present_mode_is_shared(present_mode) {
		image_count = 1
	}
	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = surface,
		minImageCount    = image_count,
		imageFormat      = format.format,
		imageColorSpace  = format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_SRC},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = present_mode,
		clipped          = true,
		oldSwapchain     = old_handle,
	}

	new_handle: vk.SwapchainKHR
	result := vk.CreateSwapchainKHR(ctx.device, &create_info, nil, &new_handle)
	if result != .SUCCESS {
		fmt.eprintf("failed to create swapchain: %v\n", result)
		return false
	}
	if old_handle != vk.SwapchainKHR(0) {
		vk.DestroySwapchainKHR(ctx.device, old_handle, nil)
	}
	swapchain.handle = new_handle
	ez_gfx_debug_set_object_name(
		ctx,
		.SWAPCHAIN_KHR,
		ez_gfx_debug_handle(swapchain.handle),
		"ez_gfx swapchain",
	)

	swapchain.format = format.format
	swapchain.extent = extent
	swapchain.present_mode = present_mode

	count: u32
	vk.GetSwapchainImagesKHR(ctx.device, swapchain.handle, &count, nil)
	if count > MAX_SWAPCHAIN_IMAGES {
		fmt.eprintf(
			"swapchain returned %d images; this boilerplate stores up to %d\n",
			count,
			MAX_SWAPCHAIN_IMAGES,
		)
		return false
	}
	swapchain.image_count = count
	vk.GetSwapchainImagesKHR(
		ctx.device,
		swapchain.handle,
		&swapchain.image_count,
		&swapchain.images[0],
	)
	for i in 0 ..< swapchain.image_count {
		swapchain.image_layouts[i] = .UNDEFINED
		swapchain.last_write_timeline[i] = 0
		ez_gfx_debug_set_indexed_name(
			ctx,
			.IMAGE,
			ez_gfx_debug_handle(swapchain.images[i]),
			"ez_gfx swapchain image",
			int(i),
		)
	}

	return(
		ez_gfx_swapchain_create_image_views(swapchain) &&
		ez_gfx_swapchain_create_present_semaphores(swapchain) \
	)
}

ez_gfx_swapchain_destroy :: proc(swapchain: ^Ez_Gfx_Swapchain) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return
	ez_gfx_swapchain_destroy_image_resources(swapchain)

	if swapchain.handle != vk.SwapchainKHR(0) {
		vk.DestroySwapchainKHR(ctx.device, swapchain.handle, nil)
	}
	swapchain.handle = vk.SwapchainKHR(0)
}

ez_gfx_swapchain_destroy_image_resources :: proc(swapchain: ^Ez_Gfx_Swapchain) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return
	for i in 0 ..< swapchain.image_count {
		if swapchain.image_views[i] != vk.ImageView(0) {
			vk.DestroyImageView(ctx.device, swapchain.image_views[i], nil)
		}
		if swapchain.present_ready[i] != vk.Semaphore(0) {
			vk.DestroySemaphore(ctx.device, swapchain.present_ready[i], nil)
		}
		swapchain.image_views[i] = vk.ImageView(0)
		swapchain.present_ready[i] = vk.Semaphore(0)
		swapchain.images[i] = vk.Image(0)
		swapchain.image_layouts[i] = .UNDEFINED
		swapchain.last_write_timeline[i] = 0
	}
	swapchain.image_count = 0
	swapchain.last_presented_index = 0
	swapchain.has_presented_image = false
}

ez_gfx_swapchain_choose_surface_format :: proc(
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

ez_gfx_swapchain_present_mode_supported :: proc(
	available_present_modes: []vk.PresentModeKHR,
	mode: vk.PresentModeKHR,
) -> bool {
	if !ez_gfx_swapchain_present_mode_usable(mode) do return false
	for present_mode in available_present_modes {
		if present_mode == mode do return true
	}
	return false
}

ez_gfx_swapchain_present_mode_usable :: proc(mode: vk.PresentModeKHR) -> bool {
	switch mode {
	case .IMMEDIATE,
	     .MAILBOX,
	     .FIFO,
	     .FIFO_RELAXED,
	     .SHARED_DEMAND_REFRESH,
	     .SHARED_CONTINUOUS_REFRESH,
	     .FIFO_LATEST_READY_EXT:
		return true
	}
	return false
}

ez_gfx_swapchain_present_mode_is_shared :: proc(mode: vk.PresentModeKHR) -> bool {
	return mode == .SHARED_DEMAND_REFRESH || mode == .SHARED_CONTINUOUS_REFRESH
}

ez_gfx_swapchain_choose_present_mode :: proc(
	available_present_modes: []vk.PresentModeKHR,
	requested: vk.PresentModeKHR,
) -> vk.PresentModeKHR {
	if ez_gfx_swapchain_present_mode_supported(available_present_modes, requested) {
		return requested
	}
	// FIFO is guaranteed by Vulkan and is the stable fallback for user requests.
	return .FIFO
}

ez_gfx_swapchain_choose_extent :: proc(
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

ez_gfx_swapchain_create_image_views :: proc(swapchain: ^Ez_Gfx_Swapchain) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	for image, i in swapchain.images[:swapchain.image_count] {
		create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = swapchain.format,
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
		if vk.CreateImageView(ctx.device, &create_info, nil, &swapchain.image_views[i]) !=
		   .SUCCESS {
			fmt.eprintln("failed to create swapchain image view")
			return false
		}
		ez_gfx_debug_set_indexed_name(
			ctx,
			.IMAGE_VIEW,
			ez_gfx_debug_handle(swapchain.image_views[i]),
			"ez_gfx swapchain image view",
			int(i),
		)
	}
	return true
}

ez_gfx_swapchain_create_present_semaphores :: proc(swapchain: ^Ez_Gfx_Swapchain) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false

	info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for i in 0 ..< swapchain.image_count {
		if vk.CreateSemaphore(ctx.device, &info, nil, &swapchain.present_ready[i]) != .SUCCESS {
			fmt.eprintln("failed to create swapchain present semaphore")
			return false
		}
		ez_gfx_debug_set_indexed_name(
			ctx,
			.SEMAPHORE,
			ez_gfx_debug_handle(swapchain.present_ready[i]),
			"ez_gfx present ready semaphore",
			int(i),
		)
	}
	return true
}
