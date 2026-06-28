package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_RENDER_PIPELINES :: 16
UINT64_MAX :: ~u64(0)

Ez_Gfx_Render :: struct {
	ctx:            ^Ez_Gfx_Ctx,
	window:         ^Ez_Gfx_Window,
	image_index:    u32,
	pipelines:      [EZ_GFX_MAX_RENDER_PIPELINES]Ez_Gfx_Vertex_Pipeline_Descriptor,
	pipeline_count: int,
	active:         bool,
	ready:          bool,
}

@(thread_local)
ez_gfx_current_render: Ez_Gfx_Render

ez_gfx_begin_render :: proc(window: ^Ez_Gfx_Window) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false
	if ez_gfx_current_render.active {
		fmt.eprintln("ez_gfx_begin_render called while a render is already active")
		return false
	}

	render := &ez_gfx_current_render
	render^ = {}
	render.ctx = ctx
	render.window = window
	render.active = true

	swapchain := &window.swapchain
	if swapchain.image_count == 0 {
		_ = ez_gfx_window_recreate_swapchain(window)
		render.active = false
		return false
	}

	vk.WaitForFences(ctx.device, 1, &ctx.in_flight, true, UINT64_MAX)
	vk.ResetFences(ctx.device, 1, &ctx.image_acquired)

	acquire_result := vk.AcquireNextImageKHR(
		ctx.device,
		swapchain.handle,
		UINT64_MAX,
		vk.Semaphore(0),
		ctx.image_acquired,
		&render.image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		_ = ez_gfx_window_recreate_swapchain(window)
		render.active = false
		return false
	}
	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		fmt.eprintf("failed to acquire swapchain image: %v\n", acquire_result)
		ez_gfx_window_set_should_close(window, true)
		render.active = false
		return false
	}
	vk.WaitForFences(ctx.device, 1, &ctx.image_acquired, true, UINT64_MAX)

	vk.ResetFences(ctx.device, 1, &ctx.in_flight)
	vk.ResetCommandBuffer(ctx.command_buffer, {})
	if !ez_gfx_render_begin_commands(render) {
		render.active = false
		return false
	}
	render.ready = true
	return true
}

ez_gfx_render_add_vertex_pipeline :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect_stride: vk.DeviceSize,
	indirect_capacity: u32,
) -> Ez_Gfx_Vertex_Pipeline_Descriptor {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln("ez_gfx_render_add_vertex_pipeline called without an active render")
		return {}
	}
	if render.pipeline_count >= EZ_GFX_MAX_RENDER_PIPELINES {
		fmt.eprintln("too many vertex pipelines in one render")
		return {}
	}

	pipeline, pipeline_ok := ez_gfx_pipeline_manager_get(
		&render.ctx.pipeline_manager,
		shader,
		render.window.swapchain.format,
	)
	if !pipeline_ok do return {}
	if !ez_gfx_render_target_manager_acquire_shader_targets(
		&render.ctx.render_target_manager,
		shader,
		render.window.swapchain.extent,
	) {
		return {}
	}
	if !ez_gfx_pipeline_update_descriptors(render.ctx, pipeline, shader) {
		return {}
	}
	indirect, indirect_ok := ez_gfx_indirect_buffer_manager_acquire(
		&render.ctx.indirect_manager,
		indirect_stride,
		indirect_capacity,
	)
	if !indirect_ok do return {}

	descriptor := Ez_Gfx_Vertex_Pipeline_Descriptor {
		pipeline        = pipeline,
		indirect_buffer = indirect,
		indirect_stride = indirect_stride,
		indirect_count  = 0,
		ok              = true,
	}
	render.pipelines[render.pipeline_count] = descriptor
	render.pipeline_count += 1
	return descriptor
}

ez_gfx_finish_render :: proc() -> bool {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln("ez_gfx_finish_render called without an active render")
		return false
	}

	ctx := render.ctx
	window := render.window
	swapchain := &window.swapchain

	for i in 0 ..< render.pipeline_count {
		descriptor := &render.pipelines[i]
		if !descriptor.ok || descriptor.pipeline.shader == nil do continue
		if !ez_gfx_render_target_manager_transition_shader_targets(
			&ctx.render_target_manager,
			descriptor.pipeline.shader,
			ctx.command_buffer,
		) {
			return false
		}
	}

	if !ez_gfx_render_begin_dynamic_rendering(render) {
		return false
	}

	vk.CmdBindIndexBuffer(
		ctx.command_buffer,
		ctx.vertex_manager.index_heap.buffer.handle,
		0,
		.UINT32,
	)

	for i in 0 ..< render.pipeline_count {
		descriptor := &render.pipelines[i]
		if !descriptor.ok do continue
		vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, descriptor.pipeline.pipeline)
		if descriptor.pipeline.descriptor_set != vk.DescriptorSet(0) {
			vk.CmdBindDescriptorSets(
				ctx.command_buffer,
				.GRAPHICS,
				descriptor.pipeline.pipeline_layout,
				0,
				1,
				&descriptor.pipeline.descriptor_set,
				0,
				nil,
			)
		}
		vk.CmdDrawIndexedIndirectCount(
			ctx.command_buffer,
			descriptor.indirect_buffer.buffer.handle,
			descriptor.indirect_stride,
			descriptor.indirect_buffer.buffer.handle,
			0,
			descriptor.indirect_buffer.capacity,
			u32(descriptor.indirect_stride),
		)
	}

	vk.CmdEndRendering(ctx.command_buffer)
	ez_gfx_transition_image(
		ctx.command_buffer,
		swapchain.images[render.image_index],
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_WRITE},
		{},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.ALL_COMMANDS},
	)
	vk.EndCommandBuffer(ctx.command_buffer)
	swapchain.image_layouts[render.image_index] = .PRESENT_SRC_KHR

	ok := ez_gfx_render_submit_and_present(render)
	ez_gfx_indirect_buffer_manager_release_frame(&ctx.indirect_manager)
	render^ = {}
	return ok
}

ez_gfx_render_begin_commands :: proc(render: ^Ez_Gfx_Render) -> bool {
	ctx := render.ctx

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(ctx.command_buffer, &begin_info) != .SUCCESS {
		fmt.eprintln("failed to begin command buffer")
		return false
	}
	return true
}

ez_gfx_render_begin_dynamic_rendering :: proc(render: ^Ez_Gfx_Render) -> bool {
	ctx := render.ctx
	swapchain := &render.window.swapchain

	color_attachments: [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.RenderingAttachmentInfo
	clear_values: [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.ClearValue
	color_attachment_count := 0
	if !ez_gfx_render_collect_color_attachments(
		render,
		color_attachments[:],
		clear_values[:],
		&color_attachment_count,
	) {
		return false
	}

	render_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = vk.Rect2D{extent = swapchain.extent},
		layerCount = 1,
		colorAttachmentCount = u32(color_attachment_count),
		pColorAttachments = &color_attachments[0],
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
	return true
}

ez_gfx_render_collect_color_attachments :: proc(
	render: ^Ez_Gfx_Render,
	color_attachments: []vk.RenderingAttachmentInfo,
	clear_values: []vk.ClearValue,
	color_attachment_count: ^int,
) -> bool {
	ctx := render.ctx
	swapchain := &render.window.swapchain
	color_attachment_count^ = 0

	for pipeline_index in 0 ..< render.pipeline_count {
		descriptor := &render.pipelines[pipeline_index]
		if !descriptor.ok || descriptor.pipeline.shader == nil do continue

		shader := descriptor.pipeline.shader
		for i in 0 ..< shader.target_usage_count {
			usage := &shader.target_usages[i]
			if !usage.core do continue
			index := int(usage.color_attachment_index)
			if index >= len(color_attachments) {
				fmt.eprintln("too many color target attachments")
				return false
			}

			if ez_gfx_shader_target_name_equals_cstring(
				usage.name[:],
				usage.name_len,
				"swapchain",
			) {
				ez_gfx_transition_image(
					ctx.command_buffer,
					swapchain.images[render.image_index],
					.UNDEFINED,
					.COLOR_ATTACHMENT_OPTIMAL,
					{},
					{.COLOR_ATTACHMENT_WRITE},
					{.COLOR_ATTACHMENT_OUTPUT},
					{.COLOR_ATTACHMENT_OUTPUT},
				)
				clear_values[index] = vk.ClearValue {
					color = vk.ClearColorValue{float32 = {0.1, 0.1, 0.1, 1.0}},
				}
				color_attachments[index] = vk.RenderingAttachmentInfo {
					sType       = .RENDERING_ATTACHMENT_INFO,
					imageView   = swapchain.image_views[render.image_index],
					imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
					loadOp      = .CLEAR,
					storeOp     = .STORE,
					clearValue  = clear_values[index],
				}
			} else {
				target := ez_gfx_render_target_manager_find(
					&ctx.render_target_manager,
					usage.name[:],
					usage.name_len,
				)
				if target == nil {
					fmt.eprintln("ColorTarget was not acquired before rendering")
					return false
				}
				ez_gfx_render_target_transition_for_color_attachment(target, ctx.command_buffer)
				clear_values[index] = vk.ClearValue {
					color = vk.ClearColorValue{float32 = {0, 0, 0, 0}},
				}
				color_attachments[index] = vk.RenderingAttachmentInfo {
					sType       = .RENDERING_ATTACHMENT_INFO,
					imageView   = target.image_view,
					imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
					loadOp      = .CLEAR,
					storeOp     = .STORE,
					clearValue  = clear_values[index],
				}
			}
			if index + 1 > color_attachment_count^ do color_attachment_count^ = index + 1
		}
	}

	if color_attachment_count^ == 0 {
		ez_gfx_transition_image(
			ctx.command_buffer,
			swapchain.images[render.image_index],
			.UNDEFINED,
			.COLOR_ATTACHMENT_OPTIMAL,
			{},
			{.COLOR_ATTACHMENT_WRITE},
			{.COLOR_ATTACHMENT_OUTPUT},
			{.COLOR_ATTACHMENT_OUTPUT},
		)
		clear_values[0] = vk.ClearValue {
			color = vk.ClearColorValue{float32 = {0.1, 0.1, 0.1, 1.0}},
		}
		color_attachments[0] = vk.RenderingAttachmentInfo {
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = swapchain.image_views[render.image_index],
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp      = .CLEAR,
			storeOp     = .STORE,
			clearValue  = clear_values[0],
		}
		color_attachment_count^ = 1
	}
	return true
}

ez_gfx_render_submit_and_present :: proc(render: ^Ez_Gfx_Render) -> bool {
	ctx := render.ctx
	window := render.window
	swapchain := &window.swapchain

	command_submit := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = ctx.command_buffer,
	}
	signal_stage := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = swapchain.present_finished[render.image_index],
		stageMask = {.ALL_COMMANDS},
	}
	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 0,
		pWaitSemaphoreInfos      = nil,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &command_submit,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal_stage,
	}

	if vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, ctx.in_flight) != .SUCCESS {
		fmt.eprintln("failed to submit frame")
		ez_gfx_window_set_should_close(window, true)
		return false
	}

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &swapchain.present_finished[render.image_index],
		swapchainCount     = 1,
		pSwapchains        = &swapchain.handle,
		pImageIndices      = &render.image_index,
	}
	present_result := vk.QueuePresentKHR(ctx.graphics_queue, &present_info)
	if present_result == .ERROR_OUT_OF_DATE_KHR ||
	   present_result == .SUBOPTIMAL_KHR ||
	   window.framebuffer_resized {
		window.framebuffer_resized = false
		_ = ez_gfx_window_recreate_swapchain(window)
	} else if present_result != .SUCCESS {
		fmt.eprintf("failed to present swapchain image: %v\n", present_result)
		ez_gfx_window_set_should_close(window, true)
		return false
	} else {
		// The current renderer is single-buffered; wait for presentation before the next
		// acquire so swapchain layout transitions do not race the presentation engine.
		vk.QueueWaitIdle(ctx.graphics_queue)
		swapchain.last_presented_index = render.image_index
		swapchain.has_presented_image = true
	}
	return true
}

ez_gfx_transition_image :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_access, dst_access: vk.AccessFlags2,
	src_stage, dst_stage: vk.PipelineStageFlags2,
) {
	ez_gfx_transition_image_with_aspect(
		command_buffer,
		image,
		old_layout,
		new_layout,
		src_access,
		dst_access,
		src_stage,
		dst_stage,
		{.COLOR},
	)
}

ez_gfx_transition_image_with_aspect :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_access, dst_access: vk.AccessFlags2,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	aspect: vk.ImageAspectFlags,
) {
	// Dynamic rendering keeps render passes out of examples, so layouts are explicit here.
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
			aspectMask = aspect,
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
