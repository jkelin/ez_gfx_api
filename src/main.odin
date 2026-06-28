package main

import "core:c"
import "core:fmt"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 1280
HEIGHT :: 720
UINT64_MAX :: ~u64(0)

TRIANGLE_INDICES :: [3]u32{0, 1, 2}

App :: struct {
	ctx:          Ez_Gfx_Ctx,
	windows:      [MAX_WINDOWS]Ez_Gfx_Window,
	window_count: int,
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

init_app :: proc(app: ^App) -> bool {
	if !ez_gfx_glfw_init() do return false

	app.window_count = 1
	main_window := &app.windows[0]
	if !ez_gfx_window_create(main_window, "ez_gfx_api Vulkan", WIDTH, HEIGHT) do return false
	if !ez_gfx_ctx_create_instance(&app.ctx) do return false
	if !ez_gfx_window_create_surface(main_window, &app.ctx) do return false
	if !ez_gfx_ctx_init_device(&app.ctx, main_window.surface) do return false
	if !ez_gfx_window_recreate_swapchain(main_window, &app.ctx) do return false
	if !ez_gfx_triangle_init(&app.ctx, &main_window.swapchain) do return false

	return true
}

// Compiles the Slang shader, creates the graphics pipeline, and uploads the index buffer.
ez_gfx_triangle_init :: proc(ctx: ^Ez_Gfx_Ctx, swapchain: ^Ez_Gfx_Swapchain) -> bool {
	if !ez_gfx_shader_init_session(ctx) do return false

	shader_module, shader_ok := ez_gfx_shader_compile_triangle(ctx)
	if !shader_ok do return false
	defer vk.DestroyShaderModule(ctx.device, shader_module, nil)

	if !ez_gfx_pipeline_create_triangle(ctx, shader_module, swapchain.format) do return false

	index_size := vk.DeviceSize(size_of(TRIANGLE_INDICES))
	index_buffer, index_ok := ez_gfx_buffer_create(
		ctx,
		index_size,
		{.INDEX_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	if !index_ok do return false
	ctx.index_buffer = index_buffer

	indices := TRIANGLE_INDICES
	if !ez_gfx_buffer_write(&ctx.index_buffer, ctx, indices[:]) do return false

	return true
}

run :: proc(app: ^App) {
	main_window := &app.windows[0]
	run_seconds := ez_gfx_config_run_seconds()
	screenshot_enabled := ez_gfx_config_screenshot_enabled()
	start_time := glfw.GetTime()

	for !ez_gfx_window_should_close(main_window) {
		ez_gfx_window_poll_events()
		if glfw.GetTime() - start_time >= run_seconds do break
		draw_frame(app, main_window)
	}

	ez_gfx_ctx_wait_idle(&app.ctx)
	if app.ctx.in_flight != vk.Fence(0) {
		vk.WaitForFences(app.ctx.device, 1, &app.ctx.in_flight, true, UINT64_MAX)
	}
	glfw.PollEvents()

	if screenshot_enabled {
		if !ez_gfx_screenshot_save_window(main_window, SCREENSHOT_PATH) {
			fmt.eprintln("failed to save screenshot")
		}
	}
}

draw_frame :: proc(app: ^App, window: ^Ez_Gfx_Window) {
	ctx := &app.ctx
	swapchain := &window.swapchain

	if swapchain.image_count == 0 {
		ez_gfx_window_recreate_swapchain(window, ctx)
		return
	}

	vk.WaitForFences(ctx.device, 1, &ctx.in_flight, true, UINT64_MAX)

	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		ctx.device,
		swapchain.handle,
		UINT64_MAX,
		ctx.image_available,
		vk.Fence(0),
		&image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		ez_gfx_window_recreate_swapchain(window, ctx)
		return
	}
	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		fmt.eprintf("failed to acquire swapchain image: %v\n", acquire_result)
		ez_gfx_window_set_should_close(window, true)
		return
	}

	vk.ResetFences(ctx.device, 1, &ctx.in_flight)
	vk.ResetCommandBuffer(ctx.command_buffer, {})
	record_frame_commands(ctx, swapchain, image_index)

	wait_stage := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = ctx.image_available,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	command_submit := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = ctx.command_buffer,
	}
	signal_stage := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = swapchain.present_finished[image_index],
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

	if vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, ctx.in_flight) != .SUCCESS {
		fmt.eprintln("failed to submit frame")
		ez_gfx_window_set_should_close(window, true)
		return
	}

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &swapchain.present_finished[image_index],
		swapchainCount     = 1,
		pSwapchains        = &swapchain.handle,
		pImageIndices      = &image_index,
	}
	present_result := vk.QueuePresentKHR(ctx.graphics_queue, &present_info)
	if present_result == .ERROR_OUT_OF_DATE_KHR ||
	   present_result == .SUBOPTIMAL_KHR ||
	   window.framebuffer_resized {
		window.framebuffer_resized = false
		ez_gfx_window_recreate_swapchain(window, ctx)
	} else if present_result != .SUCCESS {
		fmt.eprintf("failed to present swapchain image: %v\n", present_result)
		ez_gfx_window_set_should_close(window, true)
	}
}

record_frame_commands :: proc(ctx: ^Ez_Gfx_Ctx, swapchain: ^Ez_Gfx_Swapchain, image_index: u32) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(ctx.command_buffer, &begin_info)

	old_layout := swapchain.image_layouts[image_index]
	transition_image(
		ctx.command_buffer,
		swapchain.images[image_index],
		old_layout,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
	)

	clear_value := vk.ClearValue {
		color = vk.ClearColorValue{float32 = {0.1, 0.1, 0.1, 1.0}},
	}
	color_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = swapchain.image_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = clear_value,
	}
	render_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = vk.Rect2D{extent = swapchain.extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
	}

	vk.CmdBeginRendering(ctx.command_buffer, &render_info)

	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(swapchain.extent.width),
		height   = f32(swapchain.extent.height),
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(ctx.command_buffer, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {x = 0, y = 0},
		extent = swapchain.extent,
	}
	vk.CmdSetScissor(ctx.command_buffer, 0, 1, &scissor)

	vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, ctx.pipeline)
	vk.CmdBindIndexBuffer(ctx.command_buffer, ctx.index_buffer.handle, 0, .UINT32)
	vk.CmdDrawIndexed(ctx.command_buffer, 3, 1, 0, 0, 0)

	vk.CmdEndRendering(ctx.command_buffer)

	transition_image(
		ctx.command_buffer,
		swapchain.images[image_index],
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_WRITE},
		{},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.ALL_COMMANDS},
	)

	vk.EndCommandBuffer(ctx.command_buffer)
	swapchain.image_layouts[image_index] = .PRESENT_SRC_KHR
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

cleanup :: proc(app: ^App) {
	for i in 0 ..< app.window_count {
		ez_gfx_window_destroy(&app.windows[i], &app.ctx)
	}
	app.window_count = 0

	ez_gfx_ctx_destroy(&app.ctx)
	ez_gfx_glfw_terminate()
}
