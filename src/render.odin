package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_RENDER_PIPELINES :: 16
UINT64_MAX :: ~u64(0)

Ez_Gfx_Render :: struct {
	ctx:            ^Ez_Gfx_Ctx,
	window:         ^Ez_Gfx_Window,
	frame:          ^Ez_Gfx_Frame_Slot,
	frame_slot:     u32,
	image_index:    u32,
	timeline_end:   u64,
	graph:          Ez_Gfx_Render_Graph,
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
	render.frame_slot = ctx.current_frame_slot
	render.frame = &ctx.frame_slots[render.frame_slot]
	ctx.current_frame_slot = (ctx.current_frame_slot + 1) % EZ_GFX_FRAMES_IN_FLIGHT
	render.active = true

	swapchain := &window.swapchain
	if swapchain.image_count == 0 {
		_ = ez_gfx_window_recreate_swapchain(window)
		render.active = false
		return false
	}

	if !ez_gfx_ctx_wait_timeline(ctx, render.frame.last_submitted_timeline) {
		render.active = false
		return false
	}
	ez_gfx_indirect_buffer_manager_release_completed(&ctx.indirect_manager)

	acquire_result := vk.AcquireNextImageKHR(
		ctx.device,
		swapchain.handle,
		UINT64_MAX,
		render.frame.image_available,
		vk.Fence(0),
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
	if !ez_gfx_ctx_wait_timeline(ctx, swapchain.last_write_timeline[render.image_index]) {
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

	if !ez_gfx_render_target_manager_acquire_shader_targets(
		&render.ctx.render_target_manager,
		shader,
		render.window.swapchain.extent,
	) {
		return {}
	}
	pipeline, pipeline_ok := ez_gfx_pipeline_manager_get(
		&render.ctx.pipeline_manager,
		shader,
		render.window.swapchain.format,
	)
	if !pipeline_ok do return {}
	if pipeline.descriptor_version != render.ctx.render_target_manager.version {
		if !ez_gfx_pipeline_update_descriptors(render.ctx, pipeline, shader) {
			return {}
		}
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
	if !ez_gfx_render_graph_add_vertex_pipeline(
		&render.graph,
		descriptor,
		shader,
		&render.ctx.render_target_manager,
	) {
		return {}
	}
	return descriptor
}

ez_gfx_finish_render :: proc() -> bool {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln("ez_gfx_finish_render called without an active render")
		return false
	}
	if !ez_gfx_render_graph_execute(render) {
		return false
	}

	ok := ez_gfx_render_submit_and_present(render)
	render^ = {}
	return ok
}

ez_gfx_render_submit_and_present :: proc(render: ^Ez_Gfx_Render) -> bool {
	window := render.window
	swapchain := &window.swapchain
	swapchain.last_write_timeline[render.image_index] = render.timeline_end

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &swapchain.present_ready[render.image_index],
		swapchainCount     = 1,
		pSwapchains        = &swapchain.handle,
		pImageIndices      = &render.image_index,
	}
	present_result := vk.QueuePresentKHR(render.ctx.graphics_queue, &present_info)
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

ez_gfx_image_layout_src_access :: proc(layout: vk.ImageLayout) -> vk.AccessFlags2 {
	#partial switch layout {
	case .UNDEFINED:
		return {}
	case .TRANSFER_DST_OPTIMAL:
		return {.TRANSFER_WRITE}
	case .COLOR_ATTACHMENT_OPTIMAL:
		return {.COLOR_ATTACHMENT_WRITE}
	case .DEPTH_ATTACHMENT_OPTIMAL:
		return {.DEPTH_STENCIL_ATTACHMENT_WRITE}
	case .SHADER_READ_ONLY_OPTIMAL, .DEPTH_READ_ONLY_OPTIMAL:
		return {.SHADER_SAMPLED_READ}
	case .GENERAL:
		return {.SHADER_SAMPLED_READ, .SHADER_STORAGE_WRITE}
	case .PRESENT_SRC_KHR:
		return {}
	}
	return {.MEMORY_WRITE}
}

ez_gfx_image_layout_src_stage :: proc(layout: vk.ImageLayout) -> vk.PipelineStageFlags2 {
	#partial switch layout {
	case .UNDEFINED:
		return {.TOP_OF_PIPE}
	case .TRANSFER_DST_OPTIMAL:
		return {.TRANSFER}
	case .COLOR_ATTACHMENT_OPTIMAL:
		return {.COLOR_ATTACHMENT_OUTPUT}
	case .DEPTH_ATTACHMENT_OPTIMAL:
		return {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
	case .SHADER_READ_ONLY_OPTIMAL, .DEPTH_READ_ONLY_OPTIMAL:
		return {.VERTEX_SHADER, .FRAGMENT_SHADER}
	case .GENERAL:
		return {.ALL_COMMANDS}
	case .PRESENT_SRC_KHR:
		return {.ALL_COMMANDS}
	}
	return {.ALL_COMMANDS}
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
