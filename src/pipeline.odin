package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_PIPELINES :: 8
EZ_GFX_MAX_PIPELINE_DESCRIPTOR_BINDINGS ::
	EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS +
	EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS +
	EZ_GFX_MAX_SHADER_TARGET_DECLARATIONS

Ez_Gfx_Pipeline_Record :: struct {
	kind:                  Ez_Gfx_Shader_Kind,
	shader_identity:       u64,
	shader:                ^Ez_Gfx_Shader_Program,
	blend_mode:            Ez_Gfx_Blend_Mode,
	color_formats:         [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.Format,
	color_format_count:    int,
	depth_format:          vk.Format,
	has_depth:             bool,
	pipeline_layout:       vk.PipelineLayout,
	pipeline:              vk.Pipeline,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_pool:       vk.DescriptorPool,
	descriptor_sets:       [EZ_GFX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	descriptor_versions:   [EZ_GFX_FRAMES_IN_FLIGHT]u64,
	last_used:             u64,
}

Ez_Gfx_Pipeline_Manager :: struct {
	records: [EZ_GFX_MAX_PIPELINES]Ez_Gfx_Pipeline_Record,
	count:   int,
	clock:   u64,
}

Ez_Gfx_Compute_Pipeline_Descriptor :: struct {
	pipeline:           ^Ez_Gfx_Pipeline_Record,
	dispatch_x:         u32,
	dispatch_y:         u32,
	dispatch_z:         u32,
	push_constant_size: u32,
	push_constant_data: [EZ_GFX_MAX_PUSH_CONSTANT_BYTES]byte,
	ok:                 bool,
}

ez_gfx_pipeline_collect_color_formats :: proc(
	shader: ^Ez_Gfx_Shader_Program,
	swapchain_format: vk.Format,
) -> (
	formats: [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.Format,
	count: int,
	ok: bool,
) {
	for i in 0 ..< shader.target_usage_count {
		usage := &shader.target_usages[i]
		if !usage.core do continue
		if usage.color_attachment_index >= EZ_GFX_MAX_SHADER_TARGET_USAGES {
			fmt.eprintln("too many color target attachments")
			return formats, 0, false
		}

		index := int(usage.color_attachment_index)
		if ez_gfx_shader_target_name_equals_cstring(usage.name[:], usage.name_len, "swapchain") {
			formats[index] = swapchain_format
		} else {
			declaration := ez_gfx_shader_find_target_declaration(
				shader,
				usage.name[:],
				usage.name_len,
			)
			if declaration == nil || declaration.kind != .Color {
				fmt.eprintln("ColorTarget is missing a color target declaration")
				return formats, 0, false
			}
			formats[index] = declaration.format
		}
		if index + 1 > count do count = index + 1
	}
	if count == 0 {
		formats[0] = swapchain_format
		count = 1
	}
	return formats, count, true
}

ez_gfx_pipeline_collect_depth_format :: proc(
	shader: ^Ez_Gfx_Shader_Program,
) -> (
	format: vk.Format,
	has_depth: bool,
	ok: bool,
) {
	for i in 0 ..< shader.target_usage_count {
		usage := &shader.target_usages[i]
		if usage.core do continue
		if usage.access == .Read do continue
		declaration := ez_gfx_shader_find_target_declaration(shader, usage.name[:], usage.name_len)
		if declaration == nil || declaration.kind != .Depth {
			fmt.eprintln("DepthTarget is missing a depth target declaration")
			return format, false, false
		}
		if has_depth && format != declaration.format {
			fmt.eprintln("multiple depth target formats are not supported")
			return format, false, false
		}
		format = declaration.format
		has_depth = true
	}
	return format, has_depth, true
}

ez_gfx_pipeline_color_formats_equal :: proc(
	record: ^Ez_Gfx_Pipeline_Record,
	formats: [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.Format,
	count: int,
) -> bool {
	if record.color_format_count != count do return false
	for i in 0 ..< count {
		if record.color_formats[i] != formats[i] do return false
	}
	return true
}

ez_gfx_pipeline_depth_format_equal :: proc(
	record: ^Ez_Gfx_Pipeline_Record,
	format: vk.Format,
	has_depth: bool,
) -> bool {
	return record.has_depth == has_depth && record.depth_format == format
}

// TODO: Add topology and rasterization options to the cache key.
ez_gfx_pipeline_manager_get :: proc(
	manager: ^Ez_Gfx_Pipeline_Manager,
	shader: ^Ez_Gfx_Shader_Program,
	swapchain_format: vk.Format,
) -> (
	record: ^Ez_Gfx_Pipeline_Record,
	ok: bool,
) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return nil, false
	manager.clock += 1
	color_formats, color_format_count, formats_ok := ez_gfx_pipeline_collect_color_formats(
		shader,
		swapchain_format,
	)
	if !formats_ok do return nil, false
	depth_format, has_depth, depth_ok := ez_gfx_pipeline_collect_depth_format(shader)
	if !depth_ok do return nil, false

	for i in 0 ..< manager.count {
		candidate := &manager.records[i]
		if candidate.kind == .Graphics &&
		   candidate.shader_identity == shader.identity &&
		   candidate.blend_mode == shader.blend_mode &&
		   ez_gfx_pipeline_color_formats_equal(candidate, color_formats, color_format_count) &&
		   ez_gfx_pipeline_depth_format_equal(candidate, depth_format, has_depth) {
			candidate.last_used = manager.clock
			return candidate, true
		}
	}

	slot: ^Ez_Gfx_Pipeline_Record
	if manager.count < EZ_GFX_MAX_PIPELINES {
		slot = &manager.records[manager.count]
		manager.count += 1
	} else {
		oldest := 0
		for i in 1 ..< manager.count {
			if manager.records[i].last_used < manager.records[oldest].last_used {
				oldest = i
			}
		}
		slot = &manager.records[oldest]
		ez_gfx_pipeline_record_destroy(ctx, slot)
	}

	slot.kind = .Graphics
	slot.shader_identity = shader.identity
	slot.shader = shader
	slot.blend_mode = shader.blend_mode
	slot.color_formats = color_formats
	slot.color_format_count = color_format_count
	slot.depth_format = depth_format
	slot.has_depth = has_depth
	slot.last_used = manager.clock
	if !ez_gfx_pipeline_record_create(ctx, slot, shader) {
		ez_gfx_pipeline_record_destroy(ctx, slot)
		return nil, false
	}
	return slot, true
}

ez_gfx_compute_pipeline_manager_get :: proc(
	manager: ^Ez_Gfx_Pipeline_Manager,
	shader: ^Ez_Gfx_Shader_Program,
) -> (
	record: ^Ez_Gfx_Pipeline_Record,
	ok: bool,
) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return nil, false
	if shader.desc.kind != .Compute {
		fmt.eprintln("compute pipeline requires a compute shader")
		return nil, false
	}
	manager.clock += 1
	for i in 0 ..< manager.count {
		candidate := &manager.records[i]
		if candidate.kind == .Compute && candidate.shader_identity == shader.identity {
			candidate.last_used = manager.clock
			return candidate, true
		}
	}

	slot: ^Ez_Gfx_Pipeline_Record
	if manager.count < EZ_GFX_MAX_PIPELINES {
		slot = &manager.records[manager.count]
		manager.count += 1
	} else {
		oldest := 0
		for i in 1 ..< manager.count {
			if manager.records[i].last_used < manager.records[oldest].last_used {
				oldest = i
			}
		}
		slot = &manager.records[oldest]
		ez_gfx_pipeline_record_destroy(ctx, slot)
	}

	slot.kind = .Compute
	slot.shader_identity = shader.identity
	slot.shader = shader
	slot.last_used = manager.clock
	if !ez_gfx_compute_pipeline_record_create(ctx, slot, shader) {
		ez_gfx_pipeline_record_destroy(ctx, slot)
		return nil, false
	}
	return slot, true
}

ez_gfx_pipeline_record_create :: proc(
	ctx: ^Ez_Gfx_Ctx,
	record: ^Ez_Gfx_Pipeline_Record,
	shader: ^Ez_Gfx_Shader_Program,
) -> bool {
	if !ez_gfx_pipeline_create_descriptors(ctx, record, shader) do return false

	set_layouts := [?]vk.DescriptorSetLayout {
		record.descriptor_set_layout,
		ctx.texture_manager.descriptor_set_layout,
	}
	set_layout_count: u32 = 1
	if ctx.texture_manager.descriptor_set_layout != vk.DescriptorSetLayout(0) {
		set_layout_count = 2
	}

	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		offset     = 0,
		size       = shader.push_constant_size,
	}
	push_constant_range_count: u32
	push_constant_ranges: ^vk.PushConstantRange
	if shader.push_constant_size > 0 {
		push_constant_range_count = 1
		push_constant_ranges = &push_constant_range
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = set_layout_count,
		pSetLayouts            = &set_layouts[0],
		pushConstantRangeCount = push_constant_range_count,
		pPushConstantRanges    = push_constant_ranges,
	}
	if vk.CreatePipelineLayout(ctx.device, &layout_info, nil, &record.pipeline_layout) !=
	   .SUCCESS {
		fmt.eprintln("failed to create pipeline layout")
		return false
	}
	ez_gfx_debug_set_object_name(
		ctx,
		.PIPELINE_LAYOUT,
		ez_gfx_debug_handle(record.pipeline_layout),
		"ez_gfx pipeline layout",
	)

	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}

	stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = shader.module,
			pName = shader.desc.vertex_entry,
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = shader.module,
			pName = shader.desc.fragment_entry,
		},
	}

	rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = u32(record.color_format_count),
		pColorAttachmentFormats = &record.color_formats[0],
		depthAttachmentFormat   = record.depth_format,
		stencilAttachmentFormat = record.depth_format,
	}

	color_blend_attachments: [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.PipelineColorBlendAttachmentState
	for i in 0 ..< record.color_format_count {
		attachment := vk.PipelineColorBlendAttachmentState {
			colorWriteMask = {.R, .G, .B, .A},
			blendEnable    = false,
		}
		if record.blend_mode == .Alpha {
			attachment.blendEnable = true
			attachment.srcColorBlendFactor = .SRC_ALPHA
			attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
			attachment.colorBlendOp = .ADD
			attachment.srcAlphaBlendFactor = .ONE
			attachment.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA
			attachment.alphaBlendOp = .ADD
		}
		color_blend_attachments[i] = attachment
	}
	color_blend_state := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = u32(record.color_format_count),
		pAttachments    = &color_blend_attachments[0],
	}

	depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
		sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable       = b32(record.has_depth),
		depthWriteEnable      = b32(record.has_depth),
		depthCompareOp        = .LESS_OR_EQUAL,
		depthBoundsTestEnable = false,
		stencilTestEnable     = false,
		minDepthBounds        = 0.0,
		maxDepthBounds        = 1.0,
	}
	depth_stencil_state_ptr: ^vk.PipelineDepthStencilStateCreateInfo
	if record.has_depth {
		depth_stencil_state_ptr = &depth_stencil_state
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_info,
		stageCount          = 2,
		pStages             = &stages[0],
		pVertexInputState   = &{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO},
		pInputAssemblyState = &{
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		},
		pViewportState      = &{
			sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount = 1,
		},
		pRasterizationState = &{
			sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			lineWidth = 1.0,
		},
		pMultisampleState   = &{
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
		},
		pColorBlendState    = &color_blend_state,
		pDepthStencilState  = depth_stencil_state_ptr,
		pDynamicState       = &dynamic_state,
		layout              = record.pipeline_layout,
	}

	if vk.CreateGraphicsPipelines(ctx.device, 0, 1, &pipeline_info, nil, &record.pipeline) !=
	   .SUCCESS {
		fmt.eprintln("failed to create graphics pipeline")
		return false
	}
	ez_gfx_debug_set_object_name(
		ctx,
		.PIPELINE,
		ez_gfx_debug_handle(record.pipeline),
		"ez_gfx graphics pipeline",
	)

	return true
}

ez_gfx_compute_pipeline_record_create :: proc(
	ctx: ^Ez_Gfx_Ctx,
	record: ^Ez_Gfx_Pipeline_Record,
	shader: ^Ez_Gfx_Shader_Program,
) -> bool {
	if !ez_gfx_pipeline_create_descriptors(ctx, record, shader) do return false

	set_layout_count: u32
	set_layouts := [?]vk.DescriptorSetLayout{record.descriptor_set_layout}
	if record.descriptor_set_layout != vk.DescriptorSetLayout(0) {
		set_layout_count = 1
	}

	push_constant_range := vk.PushConstantRange {
		stageFlags = {.COMPUTE},
		offset     = 0,
		size       = shader.push_constant_size,
	}
	push_constant_range_count: u32
	push_constant_ranges: ^vk.PushConstantRange
	if shader.push_constant_size > 0 {
		push_constant_range_count = 1
		push_constant_ranges = &push_constant_range
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = set_layout_count,
		pSetLayouts            = &set_layouts[0],
		pushConstantRangeCount = push_constant_range_count,
		pPushConstantRanges    = push_constant_ranges,
	}
	if vk.CreatePipelineLayout(ctx.device, &layout_info, nil, &record.pipeline_layout) !=
	   .SUCCESS {
		fmt.eprintln("failed to create compute pipeline layout")
		return false
	}

	stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = shader.module,
		pName  = shader.desc.compute_entry,
	}
	pipeline_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		stage  = stage,
		layout = record.pipeline_layout,
	}
	if vk.CreateComputePipelines(ctx.device, 0, 1, &pipeline_info, nil, &record.pipeline) !=
	   .SUCCESS {
		fmt.eprintln("failed to create compute pipeline")
		return false
	}
	ez_gfx_debug_set_object_name(
		ctx,
		.PIPELINE,
		ez_gfx_debug_handle(record.pipeline),
		"ez_gfx compute pipeline",
	)
	return true
}

ez_gfx_pipeline_create_descriptors :: proc(
	ctx: ^Ez_Gfx_Ctx,
	record: ^Ez_Gfx_Pipeline_Record,
	shader: ^Ez_Gfx_Shader_Program,
) -> bool {
	binding_count :=
		shader.vertex_heap_binding_count +
		shader.structured_buffer_binding_count +
		shader.target_declaration_count
	layout_bindings: [EZ_GFX_MAX_PIPELINE_DESCRIPTOR_BINDINGS]vk.DescriptorSetLayoutBinding
	binding_index := 0

	for i in 0 ..< shader.vertex_heap_binding_count {
		binding_info := &shader.vertex_heap_bindings[i]
		if binding_info.set != 0 {
			fmt.eprintln("only descriptor set 0 is supported for vertex heaps")
			return false
		}

		layout_bindings[binding_index] = vk.DescriptorSetLayoutBinding {
			binding         = binding_info.binding,
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags      = {.VERTEX},
		}
		binding_index += 1
	}

	for i in 0 ..< shader.structured_buffer_binding_count {
		buffer_info := &shader.structured_buffer_bindings[i]
		if buffer_info.set != 0 {
			fmt.eprintln("only descriptor set 0 is supported for structured buffers")
			return false
		}

		layout_bindings[binding_index] = vk.DescriptorSetLayoutBinding {
			binding         = buffer_info.binding,
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags      = buffer_info.stages,
		}
		binding_index += 1
	}

	for i in 0 ..< shader.target_declaration_count {
		target_info := &shader.target_declarations[i]
		if target_info.set != 0 {
			fmt.eprintln("only descriptor set 0 is supported for render targets")
			return false
		}

		layout_bindings[binding_index] = vk.DescriptorSetLayoutBinding {
			binding         = target_info.binding,
			descriptorType  = ez_gfx_pipeline_target_descriptor_type(target_info),
			descriptorCount = 1,
			stageFlags      = {.VERTEX, .FRAGMENT},
		}
		binding_index += 1
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(binding_count),
		pBindings    = &layout_bindings[0],
	}
	if vk.CreateDescriptorSetLayout(
		   ctx.device,
		   &layout_info,
		   nil,
		   &record.descriptor_set_layout,
	   ) !=
	   .SUCCESS {
		fmt.eprintln("failed to create descriptor set layout")
		return false
	}
	ez_gfx_debug_set_object_name(
		ctx,
		.DESCRIPTOR_SET_LAYOUT,
		ez_gfx_debug_handle(record.descriptor_set_layout),
		"ez_gfx descriptor set layout",
	)
	if binding_count == 0 {
		return true
	}

	pool_sizes: [3]vk.DescriptorPoolSize
	pool_size_count := 0
	structured_descriptor_count := shader.vertex_heap_binding_count + shader.structured_buffer_binding_count
	if structured_descriptor_count > 0 {
		pool_sizes[pool_size_count] = vk.DescriptorPoolSize {
			type            = .STORAGE_BUFFER,
			descriptorCount = u32(structured_descriptor_count * EZ_GFX_FRAMES_IN_FLIGHT),
		}
		pool_size_count += 1
	}
	if shader.target_declaration_count > 0 {
		pool_sizes[pool_size_count] = vk.DescriptorPoolSize {
			type            = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = u32(shader.target_declaration_count * EZ_GFX_FRAMES_IN_FLIGHT),
		}
		pool_size_count += 1
		pool_sizes[pool_size_count] = vk.DescriptorPoolSize {
			type            = .STORAGE_IMAGE,
			descriptorCount = u32(shader.target_declaration_count),
		}
		pool_size_count += 1
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = EZ_GFX_FRAMES_IN_FLIGHT,
		poolSizeCount = u32(pool_size_count),
		pPoolSizes    = &pool_sizes[0],
	}
	if vk.CreateDescriptorPool(ctx.device, &pool_info, nil, &record.descriptor_pool) != .SUCCESS {
		fmt.eprintln("failed to create descriptor pool")
		return false
	}
	ez_gfx_debug_set_object_name(
		ctx,
		.DESCRIPTOR_POOL,
		ez_gfx_debug_handle(record.descriptor_pool),
		"ez_gfx descriptor pool",
	)

	set_layouts: [EZ_GFX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout
	for i in 0 ..< EZ_GFX_FRAMES_IN_FLIGHT {
		set_layouts[i] = record.descriptor_set_layout
	}
	allocate_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = record.descriptor_pool,
		descriptorSetCount = EZ_GFX_FRAMES_IN_FLIGHT,
		pSetLayouts        = &set_layouts[0],
	}
	if vk.AllocateDescriptorSets(ctx.device, &allocate_info, &record.descriptor_sets[0]) != .SUCCESS {
		fmt.eprintln("failed to allocate descriptor set")
		return false
	}
	for i in 0 ..< EZ_GFX_FRAMES_IN_FLIGHT {
		ez_gfx_debug_set_object_name(
			ctx,
			.DESCRIPTOR_SET,
			ez_gfx_debug_handle(record.descriptor_sets[i]),
			"ez_gfx descriptor set",
		)
	}

	return true
}

ez_gfx_pipeline_update_descriptors :: proc(
	ctx: ^Ez_Gfx_Ctx,
	record: ^Ez_Gfx_Pipeline_Record,
	shader: ^Ez_Gfx_Shader_Program,
	frame_slot: u32,
	node: ^Ez_Gfx_Render_Graph_Node,
) -> bool {
	frame_index := int(frame_slot)
	version := ez_gfx_pipeline_descriptor_version(ctx, shader, node)
	if record.descriptor_sets[frame_index] == vk.DescriptorSet(0) {
		record.descriptor_versions[frame_index] = version
		return true
	}

	buffer_infos: [EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS + EZ_GFX_MAX_SHADER_STRUCTURED_BUFFER_BINDINGS]vk.DescriptorBufferInfo
	image_infos: [EZ_GFX_MAX_SHADER_TARGET_DECLARATIONS]vk.DescriptorImageInfo
	writes: [EZ_GFX_MAX_PIPELINE_DESCRIPTOR_BINDINGS]vk.WriteDescriptorSet
	write_count := 0

	for i in 0 ..< shader.vertex_heap_binding_count {
		binding_info := &shader.vertex_heap_bindings[i]
		heap := ez_gfx_vertex_manager_find_heap_by_stored_name(
			&ctx.vertex_manager,
			binding_info.name[:],
			binding_info.name_len,
		)
		if heap == nil {
			fmt.eprintln("shader references a missing vertex heap")
			return false
		}

		buffer_infos[i] = vk.DescriptorBufferInfo {
			buffer = heap.buffer.handle,
			offset = 0,
			range  = heap.capacity,
		}
		writes[write_count] = vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = record.descriptor_sets[frame_index],
			dstBinding      = binding_info.binding,
			descriptorCount = 1,
			descriptorType  = .STORAGE_BUFFER,
			pBufferInfo     = &buffer_infos[i],
		}
		write_count += 1
	}

	structured_info_base := shader.vertex_heap_binding_count
	for i in 0 ..< shader.structured_buffer_binding_count {
		binding_info := &shader.structured_buffer_bindings[i]
		node_binding := ez_gfx_render_graph_find_buffer_binding(
			node,
			binding_info.name[:],
			binding_info.name_len,
		)
		if node_binding == nil || node_binding.buffer == nil {
			fmt.eprintln("shader references a missing render structured buffer")
			return false
		}

		info_index := structured_info_base + i
		buffer_infos[info_index] = vk.DescriptorBufferInfo {
			buffer = node_binding.buffer.handle,
			offset = node_binding.offset,
			range  = node_binding.size,
		}
		writes[write_count] = vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = record.descriptor_sets[frame_index],
			dstBinding      = binding_info.binding,
			descriptorCount = 1,
			descriptorType  = .STORAGE_BUFFER,
			pBufferInfo     = &buffer_infos[info_index],
		}
		write_count += 1
	}

	for i in 0 ..< shader.target_declaration_count {
		target_info := &shader.target_declarations[i]
		target := ez_gfx_render_graph_find_node_target(
			node,
			target_info.name[:],
			target_info.name_len,
		)
		if target == nil {
			continue
		}

		image_infos[i] = vk.DescriptorImageInfo {
			sampler     = target.sampler,
			imageView   = target.image_view,
			imageLayout = ez_gfx_pipeline_target_descriptor_layout(target_info),
		}
		writes[write_count] = vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = record.descriptor_sets[frame_index],
			dstBinding      = target_info.binding,
			descriptorCount = 1,
			descriptorType  = ez_gfx_pipeline_target_descriptor_type(target_info),
			pImageInfo      = &image_infos[i],
		}
		write_count += 1
	}

	if write_count > 0 {
		vk.UpdateDescriptorSets(ctx.device, u32(write_count), &writes[0], 0, nil)
	}
	record.descriptor_versions[frame_index] = version
	return true
}

ez_gfx_pipeline_target_descriptor_type :: proc(
	target_info: ^Ez_Gfx_Shader_Target_Declaration,
) -> vk.DescriptorType {
	if target_info.storage do return .STORAGE_IMAGE
	return .COMBINED_IMAGE_SAMPLER
}

ez_gfx_pipeline_target_descriptor_layout :: proc(
	target_info: ^Ez_Gfx_Shader_Target_Declaration,
) -> vk.ImageLayout {
	if target_info.storage do return .GENERAL
	return ez_gfx_render_target_descriptor_layout(target_info.kind)
}

ez_gfx_pipeline_descriptor_version :: proc(
	ctx: ^Ez_Gfx_Ctx,
	shader: ^Ez_Gfx_Shader_Program,
	node: ^Ez_Gfx_Render_Graph_Node,
) -> u64 {
	version := ctx.render_target_manager.version
	if shader.structured_buffer_binding_count > 0 {
		version = version * 16777619 + ctx.structured_buffer_manager.version
		for i in 0 ..< shader.structured_buffer_binding_count {
			binding_info := &shader.structured_buffer_bindings[i]
			node_binding := ez_gfx_render_graph_find_buffer_binding(
				node,
				binding_info.name[:],
				binding_info.name_len,
			)
			version = ez_gfx_pipeline_hash_bytes(version, binding_info.name[:], binding_info.name_len)
			version = ez_gfx_pipeline_hash_u64(version, u64(binding_info.binding))
			version = ez_gfx_pipeline_hash_u64(version, u64(binding_info.access))
			if node_binding != nil && node_binding.buffer != nil {
				version = ez_gfx_pipeline_hash_u64(version, u64(uintptr(node_binding.buffer.handle)))
				version = ez_gfx_pipeline_hash_u64(version, u64(node_binding.offset))
				version = ez_gfx_pipeline_hash_u64(version, u64(node_binding.size))
			}
		}
	}
	if shader.target_declaration_count > 0 {
		for i in 0 ..< shader.target_declaration_count {
			declaration := &shader.target_declarations[i]
			target := ez_gfx_render_graph_find_node_target(node, declaration.name[:], declaration.name_len)
			if target == nil do continue
			version = ez_gfx_pipeline_hash_bytes(version, declaration.name[:], declaration.name_len)
			version = ez_gfx_pipeline_hash_u64(version, u64(uintptr(target.image_view)))
			version = ez_gfx_pipeline_hash_u64(version, u64(target.generation))
		}
	}
	return version
}

ez_gfx_pipeline_hash_u64 :: proc(hash: u64, value: u64) -> u64 {
	result := hash
	for shift: uint = 0; shift < 64; shift += 8 {
		result = (result ~ ((value >> shift) & 0xff)) * 1099511628211
	}
	return result
}

ez_gfx_pipeline_hash_bytes :: proc(hash: u64, bytes: []byte, byte_count: int) -> u64 {
	result := hash
	for i in 0 ..< byte_count {
		result = (result ~ u64(bytes[i])) * 1099511628211
	}
	return result
}

ez_gfx_pipeline_record_destroy :: proc(ctx: ^Ez_Gfx_Ctx, record: ^Ez_Gfx_Pipeline_Record) {
	if ctx.device == nil do return
	if record.pipeline != vk.Pipeline(0) {
		vk.DestroyPipeline(ctx.device, record.pipeline, nil)
		record.pipeline = vk.Pipeline(0)
	}
	if record.pipeline_layout != vk.PipelineLayout(0) {
		vk.DestroyPipelineLayout(ctx.device, record.pipeline_layout, nil)
		record.pipeline_layout = vk.PipelineLayout(0)
	}
	if record.descriptor_pool != vk.DescriptorPool(0) {
		vk.DestroyDescriptorPool(ctx.device, record.descriptor_pool, nil)
		record.descriptor_pool = vk.DescriptorPool(0)
	}
	if record.descriptor_set_layout != vk.DescriptorSetLayout(0) {
		vk.DestroyDescriptorSetLayout(ctx.device, record.descriptor_set_layout, nil)
		record.descriptor_set_layout = vk.DescriptorSetLayout(0)
	}
	record.descriptor_sets = {}
	record.descriptor_versions = {}
	record.kind = .Graphics
	record.shader_identity = 0
	record.shader = nil
	record.color_formats = {}
	record.color_format_count = 0
	record.depth_format = {}
	record.has_depth = false
	record.last_used = 0
}

ez_gfx_pipeline_manager_destroy :: proc(manager: ^Ez_Gfx_Pipeline_Manager) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return
	for i in 0 ..< manager.count {
		ez_gfx_pipeline_record_destroy(ctx, &manager.records[i])
	}
	manager.count = 0
	manager.clock = 0
}
