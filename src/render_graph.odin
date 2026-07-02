package ez_gfx

import "core:fmt"
import "core:sync"
import vk "vendor:vulkan"

EZ_GFX_MAX_RENDER_GRAPH_ACCESSES ::
	EZ_GFX_MAX_SHADER_TARGET_USAGES +
	EZ_GFX_MAX_SHADER_TARGET_DECLARATIONS +
	EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS +
	1

Ez_Gfx_Render_Graph_Resource_Kind :: enum u8 {
	Managed,
	Swapchain,
	Structured_Buffer,
}

Ez_Gfx_Render_Graph_Node_Kind :: enum u8 {
	Graphics,
	Compute,
}

Ez_Gfx_Render_Graph_Access :: struct {
	name:                   [EZ_GFX_SHADER_TARGET_NAME_MAX]byte,
	name_len:               int,
	resource_kind:          Ez_Gfx_Render_Graph_Resource_Kind,
	target_kind:            Ez_Gfx_Render_Target_Kind,
	target:                 ^Ez_Gfx_Render_Target_Texture,
	structured_binding:        ^Ez_Gfx_Render_Structured_Binding,
	sampled_read:           bool,
	storage_read:           bool,
	storage_write:          bool,
	structured_read:           bool,
	structured_write:          bool,
	color_write:            bool,
	depth_write:            bool,
	color_attachment_index: u32,
}

Ez_Gfx_Render_Graph_Node :: struct {
	kind:            Ez_Gfx_Render_Graph_Node_Kind,
	descriptor:      Ez_Gfx_Vertex_Pipeline_Descriptor,
	compute:         Ez_Gfx_Compute_Pipeline_Descriptor,
	accesses:        [EZ_GFX_MAX_RENDER_GRAPH_ACCESSES]Ez_Gfx_Render_Graph_Access,
	access_count:    int,
	has_color_write: bool,
	has_depth_write: bool,
	timeline_value:  u64,
}

Ez_Gfx_Render_Graph :: struct {
	nodes:          [EZ_GFX_MAX_RENDER_PIPELINES]Ez_Gfx_Render_Graph_Node,
	node_count:     int,
	swapchain_used: bool,
}

ez_gfx_render_graph_add_vertex_pipeline :: proc(
	graph: ^Ez_Gfx_Render_Graph,
	descriptor: Ez_Gfx_Vertex_Pipeline_Descriptor,
	shader: ^Ez_Gfx_Shader_Program,
	target_manager: ^Ez_Gfx_Render_Target_Manager,
	render: ^Ez_Gfx_Render,
) -> bool {
	if graph.node_count >= EZ_GFX_MAX_RENDER_PIPELINES {
		fmt.eprintln("too many vertex pipelines in one render graph")
		return false
	}

	node := &graph.nodes[graph.node_count]
	node^ = {}
	node.kind = .Graphics
	node.descriptor = descriptor

	for i in 0 ..< shader.target_usage_count {
		usage := &shader.target_usages[i]
		if usage.core {
			if ez_gfx_shader_target_name_equals_cstring(
				usage.name[:],
				usage.name_len,
				"swapchain",
			) {
				if !ez_gfx_render_graph_node_add_swapchain_color_write(node, usage) {
					return false
				}
				continue
			}

			target := ez_gfx_render_target_manager_find(
				target_manager,
				usage.name[:],
				usage.name_len,
			)
			if target == nil {
				fmt.eprintln("ColorTarget was not acquired before graph construction")
				return false
			}
			if !ez_gfx_render_graph_node_add_managed_color_write(node, usage, target) {
				return false
			}
		} else {
			target := ez_gfx_render_target_manager_find(
				target_manager,
				usage.name[:],
				usage.name_len,
			)
			if target == nil {
				fmt.eprintln("DepthTarget was not acquired before graph construction")
				return false
			}
			if usage.access == .Read {
				declaration := ez_gfx_shader_find_target_declaration(
					shader,
					usage.name[:],
					usage.name_len,
				)
				if declaration == nil {
					fmt.eprintln("DepthTarget read is missing a target declaration")
					return false
				}
				if !ez_gfx_render_graph_node_add_managed_sampled_read(node, declaration, target) {
					return false
				}
			} else {
				if !ez_gfx_render_graph_node_add_managed_depth_write(node, usage, target) {
					return false
				}
			}
		}
	}

	for i in 0 ..< shader.target_declaration_count {
		declaration := &shader.target_declarations[i]
		if declaration.storage {
			target := ez_gfx_render_target_manager_find(
				target_manager,
				declaration.name[:],
				declaration.name_len,
			)
			if target == nil {
				fmt.eprintln("shader storage target declaration was not acquired before graph construction")
				return false
			}
			if !ez_gfx_render_graph_node_add_managed_storage_access(node, declaration, target) {
				return false
			}
			continue
		}
		if ez_gfx_render_graph_node_writes_name(node, declaration.name[:], declaration.name_len) {
			continue
		}

		target := ez_gfx_render_target_manager_find(
			target_manager,
			declaration.name[:],
			declaration.name_len,
		)
		if target == nil {
			fmt.eprintln("shader target declaration was not acquired before graph construction")
			return false
		}
		if !ez_gfx_render_graph_node_add_managed_sampled_read(node, declaration, target) {
			return false
		}
	}

	if !ez_gfx_render_graph_node_add_Structured_Buffers(node, shader, render) {
		return false
	}

	if !node.has_color_write {
		if !ez_gfx_render_graph_node_add_default_swapchain_write(node) {
			return false
		}
	}

	graph.node_count += 1
	return true
}

ez_gfx_render_graph_add_compute_pipeline :: proc(
	graph: ^Ez_Gfx_Render_Graph,
	descriptor: Ez_Gfx_Compute_Pipeline_Descriptor,
	shader: ^Ez_Gfx_Shader_Program,
	render: ^Ez_Gfx_Render,
) -> bool {
	if graph.node_count >= EZ_GFX_MAX_RENDER_PIPELINES {
		fmt.eprintln("too many pipelines in one render graph")
		return false
	}

	node := &graph.nodes[graph.node_count]
	node^ = {}
	node.kind = .Compute
	node.compute = descriptor
	if !ez_gfx_render_graph_node_add_Structured_Buffers(node, shader, render) {
		return false
	}
	graph.node_count += 1
	return true
}

ez_gfx_render_graph_node_add_Structured_Buffers :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
	shader: ^Ez_Gfx_Shader_Program,
	render: ^Ez_Gfx_Render,
) -> bool {
	for i in 0 ..< shader.structured_buffer_binding_count {
		binding_info := &shader.structured_buffer_bindings[i]
		render_binding := ez_gfx_render_find_structured_binding(
			render,
			binding_info.name[:],
			binding_info.name_len,
		)
		if render_binding == nil {
			fmt.eprintln("shader structured buffer was not added to the render")
			return false
		}

		access, ok := ez_gfx_render_graph_node_next_access(node)
		if !ok do return false
		access.name = binding_info.name
		access.name_len = binding_info.name_len
		access.resource_kind = .Structured_Buffer
		access.structured_binding = render_binding
		access.structured_read = binding_info.access == .Read || binding_info.access == .Read_Write
		access.structured_write = binding_info.access == .Write || binding_info.access == .Read_Write
	}
	return true
}

ez_gfx_render_graph_node_add_swapchain_color_write :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
	usage: ^Ez_Gfx_Shader_Target_Usage,
) -> bool {
	access, ok := ez_gfx_render_graph_node_next_access(node)
	if !ok do return false
	access.name = usage.name
	access.name_len = usage.name_len
	access.resource_kind = .Swapchain
	access.target_kind = .Color
	access.color_write = true
	access.color_attachment_index = usage.color_attachment_index
	node.has_color_write = true
	return true
}

ez_gfx_render_graph_node_add_default_swapchain_write :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
) -> bool {
	access, ok := ez_gfx_render_graph_node_next_access(node)
	if !ok do return false
	if !ez_gfx_copy_shader_target_name_cstring(access.name[:], &access.name_len, "swapchain") {
		return false
	}
	access.resource_kind = .Swapchain
	access.target_kind = .Color
	access.color_write = true
	access.color_attachment_index = 0
	node.has_color_write = true
	return true
}

ez_gfx_render_graph_node_add_managed_color_write :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
	usage: ^Ez_Gfx_Shader_Target_Usage,
	target: ^Ez_Gfx_Render_Target_Texture,
) -> bool {
	access, ok := ez_gfx_render_graph_node_next_access(node)
	if !ok do return false
	access.name = usage.name
	access.name_len = usage.name_len
	access.resource_kind = .Managed
	access.target_kind = .Color
	access.target = target
	access.color_write = true
	access.color_attachment_index = usage.color_attachment_index
	node.has_color_write = true
	return true
}

ez_gfx_render_graph_node_add_managed_depth_write :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
	usage: ^Ez_Gfx_Shader_Target_Usage,
	target: ^Ez_Gfx_Render_Target_Texture,
) -> bool {
	access, ok := ez_gfx_render_graph_node_next_access(node)
	if !ok do return false
	access.name = usage.name
	access.name_len = usage.name_len
	access.resource_kind = .Managed
	access.target_kind = .Depth
	access.target = target
	access.depth_write = true
	node.has_depth_write = true
	return true
}

ez_gfx_render_graph_node_add_managed_sampled_read :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
	declaration: ^Ez_Gfx_Shader_Target_Declaration,
	target: ^Ez_Gfx_Render_Target_Texture,
) -> bool {
	access, ok := ez_gfx_render_graph_node_next_access(node)
	if !ok do return false
	access.name = declaration.name
	access.name_len = declaration.name_len
	access.resource_kind = .Managed
	access.target_kind = declaration.kind
	access.target = target
	access.sampled_read = true
	return true
}

ez_gfx_render_graph_node_add_managed_storage_access :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
	declaration: ^Ez_Gfx_Shader_Target_Declaration,
	target: ^Ez_Gfx_Render_Target_Texture,
) -> bool {
	access, ok := ez_gfx_render_graph_node_next_access(node)
	if !ok do return false
	access.name = declaration.name
	access.name_len = declaration.name_len
	access.resource_kind = .Managed
	access.target_kind = declaration.kind
	access.target = target
	access.storage_read = true
	access.storage_write = true
	return true
}

ez_gfx_render_graph_node_next_access :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
) -> (
	access: ^Ez_Gfx_Render_Graph_Access,
	ok: bool,
) {
	if node.access_count >= EZ_GFX_MAX_RENDER_GRAPH_ACCESSES {
		fmt.eprintln("too many render graph resource accesses")
		return nil, false
	}
	access = &node.accesses[node.access_count]
	node.access_count += 1
	return access, true
}

ez_gfx_render_graph_node_writes_name :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
	name: []byte,
	name_len: int,
) -> bool {
	for i in 0 ..< node.access_count {
		access := &node.accesses[i]
		if !(access.color_write || access.depth_write) do continue
		if access.resource_kind != .Managed do continue
		if ez_gfx_shader_target_name_equals_bytes(
			access.name[:],
			access.name_len,
			name,
			name_len,
		) {
			return true
		}
	}
	return false
}

ez_gfx_render_graph_execute :: proc(render: ^Ez_Gfx_Render) -> bool {
	graph := &render.graph
	if graph.node_count == 0 {
		return ez_gfx_render_graph_execute_empty_present(render)
	}

	first_swapchain_write := ez_gfx_render_graph_first_swapchain_write_index(graph)
	for i in 0 ..< graph.node_count {
		node := &graph.nodes[i]
		command_buffer := render.frame.command_buffers[i]
		if !ez_gfx_render_graph_begin_commands(command_buffer) {
			return false
		}
		if i == 0 {
			ez_gfx_texture_manager_record_graphics_handoffs(
				&render.ctx.texture_manager,
				render.ctx,
				command_buffer,
				render.texture_upload_wait_timeline,
			)
			ez_gfx_vertex_manager_record_graphics_handoffs(
				&render.ctx.vertex_manager,
				render.ctx,
				command_buffer,
				render.vertex_upload_wait_timeline,
			)
			if !ez_gfx_render_target_manager_clear_frame_targets(
				&render.ctx.render_target_manager,
				render.ctx,
				command_buffer,
			) {
				return false
			}
		}
		if !ez_gfx_render_graph_prepare_sampled_reads(render, node, command_buffer) {
			return false
		}
		if !ez_gfx_render_graph_prepare_storage_accesses(render, node, command_buffer) {
			return false
		}
		ez_gfx_render_graph_prepare_Structured_Buffers(node, command_buffer)
		ez_gfx_render_graph_prepare_indirect_buffer(node, command_buffer)
		if !ez_gfx_render_graph_execute_node(render, node, command_buffer) {
			return false
		}
		ez_gfx_render_graph_transition_future_reads(render, i, command_buffer)
		if i == graph.node_count - 1 {
			if !ez_gfx_render_graph_transition_present(render, command_buffer) {
				return false
			}
		}
		if vk.EndCommandBuffer(command_buffer) != .SUCCESS {
			fmt.eprintln("failed to end graph node command buffer")
			return false
		}

		signal_value := ez_gfx_ctx_next_timeline_value(render.ctx)
		wait_value := ez_gfx_render_graph_node_wait_value(node)
		if i == 0 && render.texture_upload_wait_timeline > wait_value {
			wait_value = render.texture_upload_wait_timeline
		}
		if i == 0 && render.vertex_upload_wait_timeline > wait_value {
			wait_value = render.vertex_upload_wait_timeline
		}
		if !ez_gfx_render_graph_submit_command(
			render,
			command_buffer,
			wait_value,
			signal_value,
			i == first_swapchain_write,
			i == graph.node_count - 1,
		) {
			return false
		}
		node.timeline_value = signal_value
		if i == 0 {
			ez_gfx_render_target_manager_mark_frame_clears_submitted(
				&render.ctx.render_target_manager,
				signal_value,
			)
		}
		if node.kind == .Graphics {
			ez_gfx_indirect_buffer_mark_submitted(node.descriptor.indirect_buffer, signal_value)
		}
		ez_gfx_render_graph_mark_node_writes_submitted(render, node, signal_value)
	}

	last_signal_value := graph.nodes[graph.node_count - 1].timeline_value
	render.timeline_end = last_signal_value
	render.frame.last_submitted_timeline = last_signal_value
	return true
}

ez_gfx_render_graph_prepare_storage_accesses :: proc(
	render: ^Ez_Gfx_Render,
	node: ^Ez_Gfx_Render_Graph_Node,
	command_buffer: vk.CommandBuffer,
) -> bool {
	_ = render
	for i in 0 ..< node.access_count {
		access := &node.accesses[i]
		if !(access.storage_read || access.storage_write) do continue
		if access.target == nil {
			fmt.eprintln("render graph storage access is missing a target")
			return false
		}
		ez_gfx_render_target_transition_for_storage_access(access.target, command_buffer)
	}
	return true
}

ez_gfx_render_graph_prepare_sampled_reads :: proc(
	render: ^Ez_Gfx_Render,
	node: ^Ez_Gfx_Render_Graph_Node,
	command_buffer: vk.CommandBuffer,
) -> bool {
	for i in 0 ..< node.access_count {
		access := &node.accesses[i]
		if !access.sampled_read do continue
		if access.target == nil {
			fmt.eprintln("render graph sampled read is missing a target")
			return false
		}
		ez_gfx_render_target_transition_for_sampled_read(access.target, command_buffer)
	}
	return true
}

ez_gfx_render_graph_prepare_Structured_Buffers :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
	command_buffer: vk.CommandBuffer,
) {
	barriers: [EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS]vk.BufferMemoryBarrier2
	barrier_count := 0
	for i in 0 ..< node.access_count {
		access := &node.accesses[i]
		if access.resource_kind != .Structured_Buffer || access.structured_binding == nil do continue
		if access.structured_binding.buffer == nil do continue

		dst_access: vk.AccessFlags2
		if access.structured_read do dst_access |= {.SHADER_STORAGE_READ}
		if access.structured_write do dst_access |= {.SHADER_STORAGE_WRITE}
		if dst_access == {} do continue

		barriers[barrier_count] = vk.BufferMemoryBarrier2 {
			sType               = .BUFFER_MEMORY_BARRIER_2,
			srcStageMask        = {.HOST, .COMPUTE_SHADER, .VERTEX_SHADER, .FRAGMENT_SHADER, .DRAW_INDIRECT},
			srcAccessMask       = {.HOST_WRITE, .SHADER_STORAGE_WRITE, .SHADER_STORAGE_READ, .INDIRECT_COMMAND_READ},
			dstStageMask        = ez_gfx_render_graph_node_shader_stage(node),
			dstAccessMask       = dst_access,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			buffer              = access.structured_binding.buffer.handle,
			offset              = access.structured_binding.offset,
			size                = access.structured_binding.size,
		}
		barrier_count += 1
	}
	if barrier_count == 0 do return

	dependency := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = u32(barrier_count),
		pBufferMemoryBarriers    = &barriers[0],
	}
	vk.CmdPipelineBarrier2(command_buffer, &dependency)
}

ez_gfx_render_graph_prepare_indirect_buffer :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
	command_buffer: vk.CommandBuffer,
) {
	if node.kind != .Graphics || node.descriptor.indirect_buffer == nil do return

	barrier := vk.BufferMemoryBarrier2 {
		sType               = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask        = {.COMPUTE_SHADER, .TRANSFER, .HOST},
		srcAccessMask       = {.SHADER_STORAGE_WRITE, .TRANSFER_WRITE, .HOST_WRITE},
		dstStageMask        = {.DRAW_INDIRECT},
		dstAccessMask       = {.INDIRECT_COMMAND_READ},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = node.descriptor.indirect_buffer.buffer.handle,
		offset              = 0,
		size                = node.descriptor.indirect_buffer.buffer.size,
	}
	dependency := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(command_buffer, &dependency)
}

ez_gfx_render_graph_node_shader_stage :: proc(
	node: ^Ez_Gfx_Render_Graph_Node,
) -> vk.PipelineStageFlags2 {
	if node.kind == .Compute do return {.COMPUTE_SHADER}
	return {.VERTEX_SHADER, .FRAGMENT_SHADER, .DRAW_INDIRECT}
}

ez_gfx_render_graph_node_wait_value :: proc(node: ^Ez_Gfx_Render_Graph_Node) -> u64 {
	wait_value: u64
	for i in 0 ..< node.access_count {
		access := &node.accesses[i]
		if access.resource_kind == .Managed && access.target != nil && access.target.last_write_timeline > wait_value {
			wait_value = access.target.last_write_timeline
		}
		if access.resource_kind == .Structured_Buffer && access.structured_binding != nil {
			if access.structured_binding.structured_buffer != nil &&
			   access.structured_binding.structured_buffer.last_write_timeline > wait_value {
				wait_value = access.structured_binding.structured_buffer.last_write_timeline
			}
			if access.structured_binding.indirect_buffer != nil &&
			   access.structured_binding.indirect_buffer.last_used_timeline > wait_value {
				wait_value = access.structured_binding.indirect_buffer.last_used_timeline
			}
		}
	}
	return wait_value
}

ez_gfx_render_graph_transition_future_reads :: proc(
	render: ^Ez_Gfx_Render,
	node_index: int,
	command_buffer: vk.CommandBuffer,
) {
	node := &render.graph.nodes[node_index]
	for i in 0 ..< node.access_count {
		access := &node.accesses[i]
		if access.resource_kind != .Managed || access.target == nil do continue
		if !(access.color_write || access.depth_write || access.storage_write) do continue
		if ez_gfx_render_graph_has_future_sampled_read(
			&render.graph,
			node_index + 1,
			access.target,
		) {
			ez_gfx_render_target_transition_for_sampled_read(access.target, command_buffer)
		}
	}
}

ez_gfx_render_graph_has_future_sampled_read :: proc(
	graph: ^Ez_Gfx_Render_Graph,
	start_index: int,
	target: ^Ez_Gfx_Render_Target_Texture,
) -> bool {
	for node_index in start_index ..< graph.node_count {
		node := &graph.nodes[node_index]
		for access_index in 0 ..< node.access_count {
			access := &node.accesses[access_index]
			if !access.sampled_read do continue
			if access.resource_kind == .Managed && access.target == target {
				return true
			}
		}
	}
	return false
}

ez_gfx_render_graph_first_swapchain_write_index :: proc(graph: ^Ez_Gfx_Render_Graph) -> int {
	for node_index in 0 ..< graph.node_count {
		node := &graph.nodes[node_index]
		for access_index in 0 ..< node.access_count {
			access := &node.accesses[access_index]
			if access.resource_kind == .Swapchain && access.color_write {
				return node_index
			}
		}
	}
	return 0
}

ez_gfx_render_graph_execute_node :: proc(
	render: ^Ez_Gfx_Render,
	node: ^Ez_Gfx_Render_Graph_Node,
	command_buffer: vk.CommandBuffer,
) -> bool {
	ctx := render.ctx
	if node.kind == .Compute {
		return ez_gfx_render_graph_execute_compute_node(render, node, command_buffer)
	}

	vk.CmdBindIndexBuffer(command_buffer, ctx.vertex_manager.index_heap.buffer.handle, 0, .UINT32)

	if !ez_gfx_render_graph_begin_node_rendering(render, node, command_buffer) {
		return false
	}

	descriptor := &node.descriptor
	if descriptor.ok {
		vk.CmdBindPipeline(command_buffer, .GRAPHICS, descriptor.pipeline.pipeline)
		descriptor_set := descriptor.pipeline.descriptor_sets[render.frame_slot]
		if descriptor_set != vk.DescriptorSet(0) {
			vk.CmdBindDescriptorSets(
				command_buffer,
				.GRAPHICS,
				descriptor.pipeline.pipeline_layout,
				0,
				1,
				&descriptor_set,
				0,
				nil,
			)
		}
		if ctx.texture_manager.descriptor_set != vk.DescriptorSet(0) {
			vk.CmdBindDescriptorSets(
				command_buffer,
				.GRAPHICS,
				descriptor.pipeline.pipeline_layout,
				1,
				1,
				&ctx.texture_manager.descriptor_set,
				0,
				nil,
			)
		}
		if descriptor.push_constant_size > 0 {
			vk.CmdPushConstants(
				command_buffer,
				descriptor.pipeline.pipeline_layout,
				{.VERTEX, .FRAGMENT},
				0,
				descriptor.push_constant_size,
				&descriptor.push_constant_data[0],
			)
		}
		vk.CmdDrawIndexedIndirectCount(
			command_buffer,
			descriptor.indirect_buffer.buffer.handle,
			descriptor.indirect_buffer.draw_offset,
			descriptor.indirect_buffer.buffer.handle,
			0,
			descriptor.indirect_buffer.capacity,
			u32(descriptor.indirect_stride),
		)
	}

	vk.CmdEndRendering(command_buffer)
	return true
}

ez_gfx_render_graph_execute_compute_node :: proc(
	render: ^Ez_Gfx_Render,
	node: ^Ez_Gfx_Render_Graph_Node,
	command_buffer: vk.CommandBuffer,
) -> bool {
	_ = render
	descriptor := &node.compute
	if !descriptor.ok do return true

	vk.CmdBindPipeline(command_buffer, .COMPUTE, descriptor.pipeline.pipeline)
	descriptor_set := descriptor.pipeline.descriptor_sets[render.frame_slot]
	if descriptor_set != vk.DescriptorSet(0) {
		vk.CmdBindDescriptorSets(
			command_buffer,
			.COMPUTE,
			descriptor.pipeline.pipeline_layout,
			0,
			1,
			&descriptor_set,
			0,
			nil,
		)
	}
	if descriptor.push_constant_size > 0 {
		vk.CmdPushConstants(
			command_buffer,
			descriptor.pipeline.pipeline_layout,
			{.COMPUTE},
			0,
			descriptor.push_constant_size,
			&descriptor.push_constant_data[0],
		)
	}
	vk.CmdDispatch(command_buffer, descriptor.dispatch_x, descriptor.dispatch_y, descriptor.dispatch_z)
	return true
}

ez_gfx_render_graph_begin_node_rendering :: proc(
	render: ^Ez_Gfx_Render,
	node: ^Ez_Gfx_Render_Graph_Node,
	command_buffer: vk.CommandBuffer,
) -> bool {
	swapchain := &render.window.swapchain

	color_attachments: [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.RenderingAttachmentInfo
	color_clear_values: [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.ClearValue
	color_attachment_count := 0
	depth_attachment: vk.RenderingAttachmentInfo
	has_depth_attachment := false

	for i in 0 ..< node.access_count {
		access := &node.accesses[i]
		if access.color_write {
			index := int(access.color_attachment_index)
			if index >= len(color_attachments) {
				fmt.eprintln("too many color target attachments")
				return false
			}
			if !ez_gfx_render_graph_prepare_color_attachment(
				render,
				command_buffer,
				access,
				&color_attachments[index],
				&color_clear_values[index],
			) {
				return false
			}
			if index + 1 > color_attachment_count do color_attachment_count = index + 1
		}
		if access.depth_write {
			if has_depth_attachment {
				fmt.eprintln("only one depth target is supported per render graph node")
				return false
			}
			if !ez_gfx_render_graph_prepare_depth_attachment(
				render,
				command_buffer,
				access,
				&depth_attachment,
			) {
				return false
			}
			has_depth_attachment = true
		}
	}

	color_attachments_ptr: ^vk.RenderingAttachmentInfo
	if color_attachment_count > 0 {
		color_attachments_ptr = &color_attachments[0]
	}
	depth_attachment_ptr: ^vk.RenderingAttachmentInfo
	stencil_attachment_ptr: ^vk.RenderingAttachmentInfo
	if has_depth_attachment {
		depth_attachment_ptr = &depth_attachment
		stencil_attachment_ptr = &depth_attachment
	}

	render_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = vk.Rect2D{extent = swapchain.extent},
		layerCount = 1,
		colorAttachmentCount = u32(color_attachment_count),
		pColorAttachments = color_attachments_ptr,
		pDepthAttachment = depth_attachment_ptr,
		pStencilAttachment = stencil_attachment_ptr,
	}
	vk.CmdBeginRendering(command_buffer, &render_info)
	ez_gfx_render_graph_set_viewport_and_scissor(render, command_buffer)
	return true
}

ez_gfx_render_graph_prepare_color_attachment :: proc(
	render: ^Ez_Gfx_Render,
	command_buffer: vk.CommandBuffer,
	access: ^Ez_Gfx_Render_Graph_Access,
	attachment: ^vk.RenderingAttachmentInfo,
	clear_value: ^vk.ClearValue,
) -> bool {
	swapchain := &render.window.swapchain

	if access.resource_kind == .Swapchain {
		old_layout := swapchain.image_layouts[render.image_index]
		if old_layout != .COLOR_ATTACHMENT_OPTIMAL {
			ez_gfx_transition_image(
				command_buffer,
				swapchain.images[render.image_index],
				old_layout,
				.COLOR_ATTACHMENT_OPTIMAL,
				ez_gfx_image_layout_src_access(old_layout),
				{.COLOR_ATTACHMENT_WRITE},
				ez_gfx_image_layout_src_stage(old_layout),
				{.COLOR_ATTACHMENT_OUTPUT},
			)
			swapchain.image_layouts[render.image_index] = .COLOR_ATTACHMENT_OPTIMAL
		}

		clear_value^ = vk.ClearValue {
			color = vk.ClearColorValue{float32 = {0.1, 0.1, 0.1, 1.0}},
		}
		attachment^ = vk.RenderingAttachmentInfo {
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = swapchain.image_views[render.image_index],
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp      = ez_gfx_render_graph_load_op(render.graph.swapchain_used),
			storeOp     = .STORE,
			clearValue  = clear_value^,
		}
		render.graph.swapchain_used = true
		return true
	}

	if access.target == nil {
		fmt.eprintln("managed color attachment is missing a target")
		return false
	}
	ez_gfx_render_target_transition_for_color_attachment(access.target, command_buffer)
	clear_value^ = vk.ClearValue {
		color = vk.ClearColorValue{float32 = {0, 0, 0, 0}},
	}
	attachment^ = vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = ez_gfx_render_target_attachment_view(access.target),
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = ez_gfx_render_graph_load_op(access.target.initialized),
		storeOp     = .STORE,
		clearValue  = clear_value^,
	}
	return true
}

ez_gfx_render_graph_prepare_depth_attachment :: proc(
	render: ^Ez_Gfx_Render,
	command_buffer: vk.CommandBuffer,
	access: ^Ez_Gfx_Render_Graph_Access,
	attachment: ^vk.RenderingAttachmentInfo,
) -> bool {
	if access.target == nil {
		fmt.eprintln("managed depth attachment is missing a target")
		return false
	}
	ez_gfx_render_target_transition_for_depth_attachment(access.target, command_buffer)
	attachment^ = vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = ez_gfx_render_target_attachment_view(access.target),
		imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		loadOp = ez_gfx_render_graph_load_op(access.target.initialized),
		storeOp = .STORE,
		clearValue = vk.ClearValue{depthStencil = {depth = 1.0, stencil = 0}},
	}
	return true
}

ez_gfx_render_graph_load_op :: proc(initialized: bool) -> vk.AttachmentLoadOp {
	if initialized do return .LOAD
	return .CLEAR
}

ez_gfx_render_graph_mark_node_writes_initialized :: proc(
	render: ^Ez_Gfx_Render,
	node: ^Ez_Gfx_Render_Graph_Node,
) {
	swapchain := &render.window.swapchain
	for i in 0 ..< node.access_count {
		access := &node.accesses[i]
		if access.color_write && access.resource_kind == .Swapchain {
			swapchain.image_layouts[render.image_index] = .COLOR_ATTACHMENT_OPTIMAL
		}
		if access.resource_kind == .Managed && (access.color_write || access.depth_write) {
			access.target.initialized = true
		}
		if access.resource_kind == .Managed && access.storage_write {
			access.target.initialized = true
		}
	}
}

ez_gfx_render_graph_mark_node_writes_submitted :: proc(
	render: ^Ez_Gfx_Render,
	node: ^Ez_Gfx_Render_Graph_Node,
	timeline_value: u64,
) {
	swapchain := &render.window.swapchain
	for i in 0 ..< node.access_count {
		access := &node.accesses[i]
		if access.color_write && access.resource_kind == .Swapchain {
			swapchain.last_write_timeline[render.image_index] = timeline_value
		}
		if access.resource_kind == .Managed && (access.color_write || access.depth_write || access.storage_write) {
			access.target.initialized = true
			access.target.last_write_timeline = timeline_value
		}
		if access.resource_kind == .Structured_Buffer && access.structured_write && access.structured_binding != nil {
			if access.structured_binding.structured_buffer != nil {
				access.structured_binding.structured_buffer.last_write_timeline = timeline_value
			}
			if access.structured_binding.indirect_buffer != nil {
				access.structured_binding.indirect_buffer.last_used_timeline = timeline_value
			}
		}
	}
}

ez_gfx_render_graph_set_viewport_and_scissor :: proc(
	render: ^Ez_Gfx_Render,
	command_buffer: vk.CommandBuffer,
) {
	extent := render.window.swapchain.extent
	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(extent.width),
		height   = f32(extent.height),
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {x = 0, y = 0},
		extent = extent,
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

ez_gfx_render_graph_execute_empty_present :: proc(render: ^Ez_Gfx_Render) -> bool {
	command_buffer := render.frame.command_buffers[0]
	clear_access := Ez_Gfx_Render_Graph_Access {
		resource_kind          = .Swapchain,
		target_kind            = .Color,
		color_write            = true,
		color_attachment_index = 0,
	}
	node := Ez_Gfx_Render_Graph_Node {
		access_count    = 1,
		has_color_write = true,
	}
	node.accesses[0] = clear_access
	if !ez_gfx_render_graph_begin_commands(command_buffer) {
		return false
	}
	ez_gfx_texture_manager_record_graphics_handoffs(
		&render.ctx.texture_manager,
		render.ctx,
		command_buffer,
		render.texture_upload_wait_timeline,
	)
	ez_gfx_vertex_manager_record_graphics_handoffs(
		&render.ctx.vertex_manager,
		render.ctx,
		command_buffer,
		render.vertex_upload_wait_timeline,
	)
	if !ez_gfx_render_graph_begin_node_rendering(render, &node, command_buffer) {
		return false
	}
	vk.CmdEndRendering(command_buffer)
	if !ez_gfx_render_graph_transition_present(render, command_buffer) {
		return false
	}
	if vk.EndCommandBuffer(command_buffer) != .SUCCESS {
		fmt.eprintln("failed to end empty present command buffer")
		return false
	}

	signal_value := ez_gfx_ctx_next_timeline_value(render.ctx)
	wait_value := render.texture_upload_wait_timeline
	if render.vertex_upload_wait_timeline > wait_value {
		wait_value = render.vertex_upload_wait_timeline
	}
	if !ez_gfx_render_graph_submit_command(render, command_buffer, wait_value, signal_value, true, true) {
		return false
	}
	ez_gfx_render_graph_mark_node_writes_submitted(render, &node, signal_value)
	render.timeline_end = signal_value
	render.frame.last_submitted_timeline = signal_value
	return true
}

ez_gfx_render_graph_transition_present :: proc(
	render: ^Ez_Gfx_Render,
	command_buffer: vk.CommandBuffer,
) -> bool {
	swapchain := &render.window.swapchain
	old_layout := swapchain.image_layouts[render.image_index]
	if old_layout != .PRESENT_SRC_KHR {
		ez_gfx_transition_image(
			command_buffer,
			swapchain.images[render.image_index],
			old_layout,
			.PRESENT_SRC_KHR,
			ez_gfx_image_layout_src_access(old_layout),
			{},
			ez_gfx_image_layout_src_stage(old_layout),
			{.ALL_COMMANDS},
		)
		swapchain.image_layouts[render.image_index] = .PRESENT_SRC_KHR
	}
	return true
}

ez_gfx_render_graph_begin_commands :: proc(command_buffer: vk.CommandBuffer) -> bool {
	vk.ResetCommandBuffer(command_buffer, {})
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(command_buffer, &begin_info) != .SUCCESS {
		fmt.eprintln("failed to begin graph command buffer")
		return false
	}
	return true
}

ez_gfx_render_graph_submit_command :: proc(
	render: ^Ez_Gfx_Render,
	command_buffer: vk.CommandBuffer,
	wait_timeline_value: u64,
	signal_timeline_value: u64,
	wait_acquire: bool,
	signal_present: bool,
) -> bool {
	ctx := render.ctx
	wait_infos: [2]vk.SemaphoreSubmitInfo
	wait_count: int
	if wait_acquire {
		wait_infos[wait_count] = vk.SemaphoreSubmitInfo {
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = render.frame.image_available,
			stageMask = {.ALL_COMMANDS},
		}
		wait_count += 1
	}
	if wait_timeline_value > 0 {
		wait_infos[wait_count] = vk.SemaphoreSubmitInfo {
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = ctx.timeline_semaphore,
			value     = wait_timeline_value,
			stageMask = {.ALL_COMMANDS},
		}
		wait_count += 1
	}

	signal_infos: [2]vk.SemaphoreSubmitInfo
	signal_count := 0
	signal_infos[signal_count] = vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = ctx.timeline_semaphore,
		value     = signal_timeline_value,
		stageMask = {.ALL_COMMANDS},
	}
	signal_count += 1
	if signal_present {
		signal_infos[signal_count] = vk.SemaphoreSubmitInfo {
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = render.window.swapchain.present_ready[render.image_index],
			stageMask = {.ALL_COMMANDS},
		}
		signal_count += 1
	}

	command_submit := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = command_buffer,
	}
	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = u32(wait_count),
		pWaitSemaphoreInfos      = wait_count > 0 ? &wait_infos[0] : nil,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &command_submit,
		signalSemaphoreInfoCount = u32(signal_count),
		pSignalSemaphoreInfos    = &signal_infos[0],
	}
	sync.mutex_lock(&ctx.queue_mutex)
	result := vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, vk.Fence(0))
	sync.mutex_unlock(&ctx.queue_mutex)
	if result != .SUCCESS {
		fmt.eprintln("failed to submit render graph node")
		ez_gfx_window_set_should_close(render.window, true)
		return false
	}
	return true
}
