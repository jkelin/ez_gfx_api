package main

import "core:c"
import "core:fmt"
import "core:math"
import vk "vendor:vulkan"

MAX_SWAPCHAIN_IMAGES :: 16

Ez_Gfx_Swapchain :: struct {
	handle:               vk.SwapchainKHR,
	format:               vk.Format,
	extent:               vk.Extent2D,
	images:               [MAX_SWAPCHAIN_IMAGES]vk.Image,
	image_views:          [MAX_SWAPCHAIN_IMAGES]vk.ImageView,
	image_layouts:        [MAX_SWAPCHAIN_IMAGES]vk.ImageLayout,
	image_count:          u32,
	present_finished:     [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
}

ez_gfx_swapchain_recreate :: proc(
	ctx: ^Ez_Gfx_Ctx,
	swapchain: ^Ez_Gfx_Swapchain,
	surface: vk.SurfaceKHR,
	width, height: c.int,
) -> bool {
	vk.DeviceWaitIdle(ctx.device)
	ez_gfx_swapchain_destroy(ctx, swapchain)

	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, surface, &capabilities)

	format := ez_gfx_swapchain_choose_surface_format(ctx.physical_device, surface)
	extent := ez_gfx_swapchain_choose_extent(capabilities, width, height)
	image_count := capabilities.minImageCount + 1
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
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = .FIFO,
		clipped          = true,
	}

	result := vk.CreateSwapchainKHR(ctx.device, &create_info, nil, &swapchain.handle)
	if result != .SUCCESS {
		fmt.eprintf("failed to create swapchain: %v\n", result)
		return false
	}

	swapchain.format = format.format
	swapchain.extent = extent

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
	}

	return(
		ez_gfx_swapchain_create_image_views(ctx, swapchain) &&
		ez_gfx_swapchain_create_present_semaphores(ctx, swapchain)
	)
}

ez_gfx_swapchain_destroy :: proc(ctx: ^Ez_Gfx_Ctx, swapchain: ^Ez_Gfx_Swapchain) {
	for i in 0 ..< swapchain.image_count {
		if swapchain.present_finished[i] != vk.Semaphore(0) {
			vk.DestroySemaphore(ctx.device, swapchain.present_finished[i], nil)
		}
		if swapchain.image_views[i] != vk.ImageView(0) {
			vk.DestroyImageView(ctx.device, swapchain.image_views[i], nil)
		}
		swapchain.present_finished[i] = vk.Semaphore(0)
		swapchain.image_views[i] = vk.ImageView(0)
		swapchain.images[i] = vk.Image(0)
		swapchain.image_layouts[i] = .UNDEFINED
	}
	swapchain.image_count = 0

	if swapchain.handle != vk.SwapchainKHR(0) {
		vk.DestroySwapchainKHR(ctx.device, swapchain.handle, nil)
	}
	swapchain.handle = vk.SwapchainKHR(0)
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

ez_gfx_swapchain_create_image_views :: proc(
	ctx: ^Ez_Gfx_Ctx,
	swapchain: ^Ez_Gfx_Swapchain,
) -> bool {
	for image, i in swapchain.images[:swapchain.image_count] {
		create_info := vk.ImageViewCreateInfo {
			sType  = .IMAGE_VIEW_CREATE_INFO,
			image  = image,
			viewType = .D2,
			format = swapchain.format,
			components = vk.ComponentMapping {
				r = .IDENTITY,
				g = .IDENTITY,
				b = .IDENTITY,
				a = .IDENTITY,
			},
			subresourceRange = vk.ImageSubresourceRange {
				aspectMask     = {.COLOR},
				baseMipLevel   = 0,
				levelCount     = 1,
				baseArrayLayer = 0,
				layerCount     = 1,
			},
		}
		if vk.CreateImageView(ctx.device, &create_info, nil, &swapchain.image_views[i]) !=
		   .SUCCESS {
			fmt.eprintln("failed to create swapchain image view")
			return false
		}
	}
	return true
}

ez_gfx_swapchain_create_present_semaphores :: proc(
	ctx: ^Ez_Gfx_Ctx,
	swapchain: ^Ez_Gfx_Swapchain,
) -> bool {
	info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for i in 0 ..< swapchain.image_count {
		if vk.CreateSemaphore(ctx.device, &info, nil, &swapchain.present_finished[i]) !=
		   .SUCCESS {
			fmt.eprintln("failed to create present semaphore")
			return false
		}
	}
	return true
}
