#+private
package ez_gfx

import "core:c"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

EZ_GFX_INTERNAL_SCREENSHOT_PATH :: "screenshot.png"
SCREENSHOT_JPEG_QUALITY :: 90

// Saves the last presented swapchain image to a PNG or JPEG file for automated verification.
screenshot_save_window :: proc(window: ^Ez_Gfx_Window, path: string) -> bool {
	ctx := get_current_ctx()
	if ctx == nil do return false

	swapchain := &window.swapchain
	if !swapchain.has_presented_image {
		fmt.eprintln("screenshot skipped: no swapchain image has been presented")
		return false
	}

	width := int(swapchain.extent.width)
	height := int(swapchain.extent.height)
	if width <= 0 || height <= 0 {
		fmt.eprintln("screenshot skipped: invalid swapchain extent")
		return false
	}

	bgra: []u8
	if !screenshot_read_swapchain_bgra(swapchain, &bgra) {
		fmt.eprintln("failed to read swapchain image")
		return false
	}
	defer delete(bgra)

	ext := strings.to_lower(filepath.ext(path))
	switch ext {
	case ".png":
		return screenshot_write_png(path, width, height, bgra)
	case ".jpg", ".jpeg":
		return screenshot_write_jpg(path, width, height, bgra)
	case:
		fmt.eprintf("unsupported screenshot extension %q (use .png, .jpg, or .jpeg)\n", ext)
		return false
	}
}

screenshot_read_swapchain_bgra :: proc(
	swapchain: ^Ez_Gfx_Swapchain,
	pixels: ^[]u8,
) -> bool {
	if swapchain != nil && swapchain.presented_snapshot_valid {
		return screenshot_clone_pixels(swapchain.presented_snapshot_pixels, pixels)
	}

	ctx := get_current_ctx()
	if ctx == nil do return false

	width := int(swapchain.extent.width)
	height := int(swapchain.extent.height)
	row_stride := width * 4
	buffer_size := vk.DeviceSize(row_stride * height)

	command_buffer := ctx.frame_slots[0].command_buffers[EZ_GFX_MAX_RENDER_PIPELINES]

	staging, staging_ok := buffer_create(
		buffer_size,
		{.TRANSFER_DST},
		{.HOST_VISIBLE, .HOST_COHERENT},
		"ez_gfx screenshot staging buffer",
		0.3,
	)
	if !staging_ok do return false
	defer buffer_destroy(&staging)

	if !ctx_wait_timeline(ctx, ctx.frame_slots[0].last_submitted_timeline) {
		return false
	}

	acquire_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	image_available: vk.Semaphore
	if vk.CreateSemaphore(ctx.device, &acquire_info, nil, &image_available) != .SUCCESS {
		fmt.eprintln("failed to create screenshot acquire semaphore")
		return false
	}
	debug_set_object_name(
		ctx,
		.SEMAPHORE,
		debug_handle(image_available),
		"ez_gfx screenshot acquire semaphore",
	)
	defer vk.DestroySemaphore(ctx.device, image_available, nil)

	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		ctx.device,
		swapchain.handle,
		UINT64_MAX,
		image_available,
		vk.Fence(0),
		&image_index,
	)
	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		fmt.eprintf("failed to acquire swapchain image for screenshot: %v\n", acquire_result)
		return false
	}
	if !ctx_wait_timeline(ctx, swapchain.last_write_timeline[image_index]) {
		return false
	}
	image := swapchain.images[image_index]
	old_layout := swapchain.image_layouts[image_index]
	vk.ResetCommandBuffer(command_buffer, {})

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(command_buffer, &begin_info) != .SUCCESS {
		fmt.eprintln("failed to begin screenshot command buffer")
		return false
	}

	transition_image(
		command_buffer,
		image,
		old_layout,
		.TRANSFER_SRC_OPTIMAL,
		image_layout_src_access(old_layout),
		{.TRANSFER_READ},
		image_layout_src_stage(old_layout),
		{.TRANSFER},
	)

	region := vk.BufferImageCopy {
		bufferOffset = 0,
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = vk.ImageSubresourceLayers {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageOffset = {x = 0, y = 0, z = 0},
		imageExtent = {
			width = swapchain.extent.width,
			height = swapchain.extent.height,
			depth = 1,
		},
	}
	vk.CmdCopyImageToBuffer(
		command_buffer,
		image,
		.TRANSFER_SRC_OPTIMAL,
		staging.handle,
		1,
		&region,
	)

	transition_image(
		command_buffer,
		image,
		.TRANSFER_SRC_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.TRANSFER_READ},
		{},
		{.TRANSFER},
		{.BOTTOM_OF_PIPE},
	)
	swapchain.image_layouts[image_index] = .PRESENT_SRC_KHR

	if vk.EndCommandBuffer(command_buffer) != .SUCCESS {
		fmt.eprintln("failed to end screenshot command buffer")
		return false
	}

	signal_value := ctx_next_timeline_value(ctx)
	if !screenshot_submit_copy(ctx, command_buffer, image_available, signal_value) {
		fmt.eprintln("failed to submit screenshot copy")
		return false
	}
	if !ctx_wait_timeline(ctx, signal_value) {
		fmt.eprintln("failed to wait for screenshot copy")
		return false
	}
	swapchain.last_write_timeline[image_index] = signal_value

	present_info := vk.PresentInfoKHR {
		sType          = .PRESENT_INFO_KHR,
		swapchainCount = 1,
		pSwapchains    = &swapchain.handle,
		pImageIndices  = &image_index,
	}
	sync.mutex_lock(&ctx.queue_mutex)
	present_result := vk.QueuePresentKHR(ctx.graphics_queue, &present_info)
	sync.mutex_unlock(&ctx.queue_mutex)
	if present_result != .SUCCESS && present_result != .SUBOPTIMAL_KHR {
		fmt.eprintf("failed to present screenshot swapchain image: %v\n", present_result)
		return false
	}
	swapchain.last_presented_index = image_index
	swapchain.has_presented_image = true

	pixel_data, alloc_err := make([]u8, row_stride * height)
	if alloc_err != nil {
		fmt.eprintf("failed to allocate screenshot pixels: %v\n", alloc_err)
		return false
	}

	if !buffer_read_at(&staging, 0, pixel_data) {
		delete(pixel_data)
		fmt.eprintln("failed to map screenshot staging buffer")
		return false
	}

	pixels^ = pixel_data
	return true
}

screenshot_submit_copy :: proc(
	ctx: ^Ez_Gfx_Ctx,
	command_buffer: vk.CommandBuffer,
	image_available: vk.Semaphore,
	signal_value: u64,
) -> bool {
	command_submit := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = command_buffer,
	}
	wait_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = image_available,
		stageMask = {.ALL_COMMANDS},
	}
	signal_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = ctx.timeline_semaphore,
		value     = signal_value,
		stageMask = {.ALL_COMMANDS},
	}
	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &wait_info,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &command_submit,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal_info,
	}
	sync.mutex_lock(&ctx.queue_mutex)
	result := vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, vk.Fence(0))
	sync.mutex_unlock(&ctx.queue_mutex)
	return result == .SUCCESS
}

screenshot_write_png :: proc(path: string, width, height: int, bgra: []u8) -> bool {
	rgba, conv_ok := screenshot_bgra_to_rgba(bgra, width, height)
	if !conv_ok do return false
	defer delete(rgba)

	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	row_stride := width * 4
	if stbi.write_png(path_c, c.int(width), c.int(height), 4, raw_data(rgba), c.int(row_stride)) ==
	   0 {
		fmt.eprintf("failed to write PNG screenshot to %v\n", path)
		return false
	}

	fmt.printf("saved screenshot to %v\n", path)
	return true
}

screenshot_write_jpg :: proc(path: string, width, height: int, bgra: []u8) -> bool {
	rgb, conv_ok := screenshot_bgra_to_rgb(bgra, width, height)
	if !conv_ok do return false
	defer delete(rgb)

	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	if stbi.write_jpg(
		   path_c,
		   c.int(width),
		   c.int(height),
		   3,
		   raw_data(rgb),
		   c.int(SCREENSHOT_JPEG_QUALITY),
	   ) ==
	   0 {
		fmt.eprintf("failed to write JPEG screenshot to %v\n", path)
		return false
	}

	fmt.printf("saved screenshot to %v\n", path)
	return true
}

screenshot_bgra_to_rgba :: proc(bgra: []u8, width, height: int) -> (rgba: []u8, ok: bool) {
	pixel_count := width * height
	out, alloc_err := make([]u8, pixel_count * 4)
	if alloc_err != nil {
		fmt.eprintf("failed to allocate RGBA conversion buffer: %v\n", alloc_err)
		return rgba, false
	}

	for i in 0 ..< pixel_count {
		src := i * 4
		dst := src
		out[dst + 0] = bgra[src + 2]
		out[dst + 1] = bgra[src + 1]
		out[dst + 2] = bgra[src + 0]
		out[dst + 3] = bgra[src + 3]
	}
	return out, true
}

screenshot_bgra_to_rgb :: proc(bgra: []u8, width, height: int) -> (rgb: []u8, ok: bool) {
	pixel_count := width * height
	out, alloc_err := make([]u8, pixel_count * 3)
	if alloc_err != nil {
		fmt.eprintf("failed to allocate RGB conversion buffer: %v\n", alloc_err)
		return rgb, false
	}

	for i in 0 ..< pixel_count {
		src := i * 4
		dst := i * 3
		out[dst + 0] = bgra[src + 2]
		out[dst + 1] = bgra[src + 1]
		out[dst + 2] = bgra[src + 0]
	}
	return out, true
}

screenshot_clone_pixels :: proc(source: []u8, pixels: ^[]u8) -> bool {
	if len(source) == 0 do return false
	cloned, alloc_err := make([]u8, len(source))
	if alloc_err != nil {
		fmt.eprintf("failed to allocate screenshot pixel clone: %v\n", alloc_err)
		return false
	}
	copy(cloned, source)
	pixels^ = cloned
	return true
}

// Copies the rendered swapchain image to CPU memory before present so hidden test windows
// can read back the exact frame that was just rendered.
swapchain_cache_presented_snapshot :: proc(
	swapchain: ^Ez_Gfx_Swapchain,
	image_index: u32,
) -> bool {
	ctx := get_current_ctx()
	if ctx == nil || swapchain == nil do return false

	width := int(swapchain.extent.width)
	height := int(swapchain.extent.height)
	if width <= 0 || height <= 0 do return false
	if image_index >= swapchain.image_count do return false

	row_stride := width * 4
	byte_count := row_stride * height
	buffer_size := vk.DeviceSize(byte_count)

	command_buffer := ctx.frame_slots[0].command_buffers[EZ_GFX_MAX_RENDER_PIPELINES]
	staging, staging_ok := buffer_create(
		buffer_size,
		{.TRANSFER_DST},
		{.HOST_VISIBLE, .HOST_COHERENT},
		"ez_gfx snapshot staging buffer",
		0.3,
	)
	if !staging_ok do return false
	defer buffer_destroy(&staging)

	image := swapchain.images[image_index]
	old_layout := swapchain.image_layouts[image_index]
	vk.ResetCommandBuffer(command_buffer, {})

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(command_buffer, &begin_info) != .SUCCESS {
		fmt.eprintln("failed to begin snapshot cache command buffer")
		return false
	}

	transition_image(
		command_buffer,
		image,
		old_layout,
		.TRANSFER_SRC_OPTIMAL,
		image_layout_src_access(old_layout),
		{.TRANSFER_READ},
		image_layout_src_stage(old_layout),
		{.TRANSFER},
	)

	region := vk.BufferImageCopy {
		bufferOffset = 0,
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = vk.ImageSubresourceLayers {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageOffset = {x = 0, y = 0, z = 0},
		imageExtent = {
			width = swapchain.extent.width,
			height = swapchain.extent.height,
			depth = 1,
		},
	}
	vk.CmdCopyImageToBuffer(
		command_buffer,
		image,
		.TRANSFER_SRC_OPTIMAL,
		staging.handle,
		1,
		&region,
	)

	transition_image(
		command_buffer,
		image,
		.TRANSFER_SRC_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.TRANSFER_READ},
		{},
		{.TRANSFER},
		{.BOTTOM_OF_PIPE},
	)
	swapchain.image_layouts[image_index] = .PRESENT_SRC_KHR

	if vk.EndCommandBuffer(command_buffer) != .SUCCESS {
		fmt.eprintln("failed to end snapshot cache command buffer")
		return false
	}

	signal_value := ctx_next_timeline_value(ctx)
	if !screenshot_submit_copy_no_wait(ctx, command_buffer, signal_value) {
		fmt.eprintln("failed to submit snapshot cache copy")
		return false
	}
	if !ctx_wait_timeline(ctx, signal_value) {
		fmt.eprintln("failed to wait for snapshot cache copy")
		return false
	}
	swapchain.last_write_timeline[image_index] = signal_value

	if len(swapchain.presented_snapshot_pixels) != byte_count {
		delete(swapchain.presented_snapshot_pixels)
		pixels, alloc_err := make([]u8, byte_count)
		if alloc_err != nil {
			fmt.eprintf("failed to allocate cached snapshot pixels: %v\n", alloc_err)
			return false
		}
		swapchain.presented_snapshot_pixels = pixels
	}
	if !buffer_read_at(&staging, 0, swapchain.presented_snapshot_pixels) {
		fmt.eprintln("failed to read cached snapshot staging buffer")
		return false
	}
	swapchain.presented_snapshot_valid = true
	return true
}

screenshot_submit_copy_no_wait :: proc(
	ctx: ^Ez_Gfx_Ctx,
	command_buffer: vk.CommandBuffer,
	signal_value: u64,
) -> bool {
	command_submit := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = command_buffer,
	}
	signal_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = ctx.timeline_semaphore,
		value     = signal_value,
		stageMask = {.ALL_COMMANDS},
	}
	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &command_submit,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal_info,
	}
	sync.mutex_lock(&ctx.queue_mutex)
	result := vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, vk.Fence(0))
	sync.mutex_unlock(&ctx.queue_mutex)
	return result == .SUCCESS
}
