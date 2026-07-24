package ez_gfx

import "core:fmt"
import "core:mem"
import "core:sync"
import vk "vendor:vulkan"

EZ_GFX_MAX_RENDER_PIPELINES :: 16
UINT64_MAX :: ~u64(0)

Ez_Gfx_Render :: struct {
	ctx:                          ^Ez_Gfx_Ctx,
	window:                       ^Ez_Gfx_Window,
	frame:                        ^Ez_Gfx_Frame_Slot,
	frame_slot:                   u32,
	image_index:                  u32,
	timeline_end:                 u64,
	frame_id:                     u64,
	texture_upload_wait_timeline: u64,
	vertex_upload_wait_timeline:  u64,
	graph:                        Ez_Gfx_Render_Graph,
	pipeline_count:               int,
	active:                       bool,
	ready:                        bool,
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
	ctx.render_frame_counter += 1
	render.frame_id = ctx.render_frame_counter
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
	render.texture_upload_wait_timeline = ez_gfx_texture_manager_latest_scheduled_timeline(
		&ctx.texture_manager,
	)
	if !ez_gfx_texture_manager_wait_submitted_timeline(
		&ctx.texture_manager,
		render.texture_upload_wait_timeline,
	) {
		render.active = false
		return false
	}
	render.vertex_upload_wait_timeline = ez_gfx_vertex_manager_latest_scheduled_timeline(
		&ctx.vertex_manager,
	)
	if !ez_gfx_vertex_manager_wait_submitted_timeline(
		&ctx.vertex_manager,
		render.vertex_upload_wait_timeline,
	) {
		render.active = false
		return false
	}
	ez_gfx_texture_manager_collect_destroyed(&ctx.texture_manager, ctx)
	ez_gfx_vertex_manager_collect_completed(&ctx.vertex_manager)
	ez_gfx_indirect_buffer_manager_release_completed(&ctx.indirect_manager)
	ez_gfx_structured_buffer_manager_release_completed(&ctx.structured_buffer_manager)

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

ez_gfx_render_add_vertex_pipeline :: proc {
	ez_gfx_render_add_vertex_pipeline_without_push_constants,
	ez_gfx_render_add_vertex_pipeline_with_dynamic_state_without_push_constants,
	ez_gfx_render_add_vertex_pipeline_with_dynamic_state_and_push_constants,
}

ez_gfx_render_add_compute_pipeline :: proc {
	ez_gfx_render_add_compute_pipeline_without_push_constants,
	ez_gfx_render_add_compute_pipeline_with_push_constants,
}

ez_gfx_render_acquire_indirect_buffer :: proc(
	$T: typeid,
	element_count: u32,
	debug_name: cstring,
) -> Ez_Gfx_Indirect_Buffer_Handle {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln("ez_gfx_render_acquire_indirect_buffer called without an active render")
		return {}
	}
	if element_count == 0 {
		fmt.eprintln("indirect buffer element count must be greater than zero")
		return {}
	}
	_ = debug_name
	indirect_stride := vk.DeviceSize(size_of(T))
	indirect, indirect_ok := ez_gfx_indirect_buffer_manager_acquire(
		&render.ctx.indirect_manager,
		indirect_stride,
		element_count,
	)
	if !indirect_ok do return {}
	return Ez_Gfx_Indirect_Buffer_Handle {
		buffer   = indirect,
		stride   = indirect_stride,
		capacity = element_count,
		frame_id = render.frame_id,
		ok       = true,
	}
}

ez_gfx_render_add_vertex_pipeline_without_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
) -> Ez_Gfx_Vertex_Pipeline_Descriptor {
	return ez_gfx_render_add_vertex_pipeline_impl(
		shader,
		indirect,
		bindings,
		{},
		nil,
		0,
	)
}
ez_gfx_render_add_vertex_pipeline_with_dynamic_state_without_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State,
) -> Ez_Gfx_Vertex_Pipeline_Descriptor {
	return ez_gfx_render_add_vertex_pipeline_impl(
		shader,
		indirect,
		bindings,
		dynamic_state,
		nil,
		0,
	)
}

ez_gfx_render_add_vertex_pipeline_with_dynamic_state_and_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State,
	push_constants: $T,
) -> Ez_Gfx_Vertex_Pipeline_Descriptor {
	data := push_constants
	return ez_gfx_render_add_vertex_pipeline_impl(
		shader,
		indirect,
		bindings,
		dynamic_state,
		rawptr(&data),
		u32(size_of(T)),
	)
}

ez_gfx_render_add_vertex_pipeline_impl :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	indirect: Ez_Gfx_Indirect_Buffer_Handle,
	bindings: []Ez_Gfx_Render_Binding,
	dynamic_state: Ez_Gfx_Render_Dynamic_State,
	push_constant_data: rawptr,
	push_constant_size: u32,
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
	if shader.push_constant_size != push_constant_size {
		fmt.eprintf(
			"push constant size mismatch: shader expects %v bytes, caller passed %v bytes\n",
			shader.push_constant_size,
			push_constant_size,
		)
		return {}
	}
	if push_constant_size > EZ_GFX_MAX_PUSH_CONSTANT_BYTES {
		fmt.eprintln("push constant data exceeds ez_gfx limit")
		return {}
	}
	if !indirect.ok || indirect.buffer == nil || indirect.frame_id != render.frame_id {
		fmt.eprintln("vertex pipeline indirect buffer must be acquired in the current render")
		return {}
	}

	if !ez_gfx_render_target_manager_acquire_shader_targets_for_bindings(
		&render.ctx.render_target_manager,
		shader,
		render.window.swapchain.extent,
		bindings,
	) {
		return {}
	}
	blend_mode := shader.blend_mode
	if dynamic_state.blend_mode != .None {
		// The zero-value blend mode preserves shader metadata; callers can override it explicitly.
		blend_mode = dynamic_state.blend_mode
	}
	pipeline, pipeline_ok := ez_gfx_pipeline_manager_get(
		&render.ctx.pipeline_manager,
		shader,
		render.window.swapchain.format,
		blend_mode,
	)
	if !pipeline_ok do return {}

	descriptor_set_index := int(render.frame_slot) * EZ_GFX_MAX_RENDER_PIPELINES + render.pipeline_count
	descriptor := Ez_Gfx_Vertex_Pipeline_Descriptor {
		pipeline           = pipeline,
		descriptor_set_index = descriptor_set_index,
		dynamic_state      = dynamic_state,
		indirect_buffer    = indirect.buffer,
		indirect_stride    = indirect.stride,
		indirect_count     = 0,
		push_constant_size = push_constant_size,
		ok                 = true,
	}
	if push_constant_size > 0 {
		// Push constants are copied here so callers can pass frame-local structs safely.
		mem.copy(&descriptor.push_constant_data[0], push_constant_data, int(push_constant_size))
	}
	if !ez_gfx_render_graph_add_vertex_pipeline(
		&render.graph,
		descriptor,
		shader,
		&render.ctx.render_target_manager,
		render,
		bindings,
	) {
		return {}
	}
	node := &render.graph.nodes[render.graph.node_count - 1]
	version := ez_gfx_pipeline_descriptor_version(render.ctx, shader, node)
	if pipeline.descriptor_versions[descriptor.descriptor_set_index] != version {
		if !ez_gfx_pipeline_update_descriptors(
			render.ctx,
			pipeline,
			shader,
			descriptor.descriptor_set_index,
			node,
		) {
			render.graph.node_count -= 1
			return {}
		}
	}
	render.pipeline_count += 1
	return descriptor
}

ez_gfx_render_add_compute_pipeline_without_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Render_Binding,
) -> Ez_Gfx_Compute_Pipeline_Descriptor {
	return ez_gfx_render_add_compute_pipeline_impl(
		shader,
		dispatch_x,
		dispatch_y,
		dispatch_z,
		bindings,
		nil,
		0,
	)
}

ez_gfx_render_add_compute_pipeline_with_push_constants :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Render_Binding,
	push_constants: $T,
) -> Ez_Gfx_Compute_Pipeline_Descriptor {
	data := push_constants
	return ez_gfx_render_add_compute_pipeline_impl(
		shader,
		dispatch_x,
		dispatch_y,
		dispatch_z,
		bindings,
		rawptr(&data),
		u32(size_of(T)),
	)
}

ez_gfx_render_add_compute_pipeline_impl :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	dispatch_x, dispatch_y, dispatch_z: u32,
	bindings: []Ez_Gfx_Render_Binding,
	push_constant_data: rawptr,
	push_constant_size: u32,
) -> Ez_Gfx_Compute_Pipeline_Descriptor {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln("ez_gfx_render_add_compute_pipeline called without an active render")
		return {}
	}
	if render.pipeline_count >= EZ_GFX_MAX_RENDER_PIPELINES {
		fmt.eprintln("too many pipelines in one render")
		return {}
	}
	if shader.push_constant_size != push_constant_size {
		fmt.eprintf(
			"push constant size mismatch: shader expects %v bytes, caller passed %v bytes\n",
			shader.push_constant_size,
			push_constant_size,
		)
		return {}
	}
	if push_constant_size > EZ_GFX_MAX_PUSH_CONSTANT_BYTES {
		fmt.eprintln("push constant data exceeds ez_gfx limit")
		return {}
	}
	if !ez_gfx_render_target_manager_acquire_shader_targets_for_bindings(
		&render.ctx.render_target_manager,
		shader,
		render.window.swapchain.extent,
		bindings,
	) {
		return {}
	}

	pipeline, pipeline_ok := ez_gfx_compute_pipeline_manager_get(
		&render.ctx.pipeline_manager,
		shader,
	)
	if !pipeline_ok do return {}

	descriptor_set_index := int(render.frame_slot) * EZ_GFX_MAX_RENDER_PIPELINES + render.pipeline_count
	descriptor := Ez_Gfx_Compute_Pipeline_Descriptor {
		pipeline           = pipeline,
		descriptor_set_index = descriptor_set_index,
		dispatch_x         = dispatch_x,
		dispatch_y         = dispatch_y,
		dispatch_z         = dispatch_z,
		push_constant_size = push_constant_size,
		ok                 = true,
	}
	if push_constant_size > 0 {
		mem.copy(&descriptor.push_constant_data[0], push_constant_data, int(push_constant_size))
	}
	if !ez_gfx_render_graph_add_compute_pipeline(&render.graph, descriptor, shader, render, bindings) {
		return {}
	}
	node := &render.graph.nodes[render.graph.node_count - 1]
	version := ez_gfx_pipeline_descriptor_version(render.ctx, shader, node)
	if pipeline.descriptor_versions[descriptor.descriptor_set_index] != version {
		if !ez_gfx_pipeline_update_descriptors(
			render.ctx,
			pipeline,
			shader,
			descriptor.descriptor_set_index,
			node,
		) {
			render.graph.node_count -= 1
			return {}
		}
	}
	render.pipeline_count += 1
	return descriptor
}

ez_gfx_finish_render :: proc() -> bool {
	render := &ez_gfx_current_render
	if !render.active || !render.ready {
		fmt.eprintln("ez_gfx_finish_render called without an active render")
		return false
	}
	if !ez_gfx_render_graph_validate(render) {
		render^ = {}
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

	if window.cache_presented_snapshots {
		if !ez_gfx_ctx_wait_timeline(render.ctx, render.timeline_end) {
			return false
		}
		if !ez_gfx_swapchain_cache_presented_snapshot(swapchain, render.image_index) {
			return false
		}
	}

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &swapchain.present_ready[render.image_index],
		swapchainCount     = 1,
		pSwapchains        = &swapchain.handle,
		pImageIndices      = &render.image_index,
	}
	sync.mutex_lock(&render.ctx.queue_mutex)
	present_result := vk.QueuePresentKHR(render.ctx.graphics_queue, &present_info)
	sync.mutex_unlock(&render.ctx.queue_mutex)
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
	case .DEPTH_ATTACHMENT_OPTIMAL, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL:
		return {.DEPTH_STENCIL_ATTACHMENT_WRITE}
	case .SHADER_READ_ONLY_OPTIMAL, .DEPTH_READ_ONLY_OPTIMAL, .DEPTH_STENCIL_READ_ONLY_OPTIMAL:
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
	case .DEPTH_ATTACHMENT_OPTIMAL, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL:
		return {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
	case .SHADER_READ_ONLY_OPTIMAL, .DEPTH_READ_ONLY_OPTIMAL, .DEPTH_STENCIL_READ_ONLY_OPTIMAL:
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
