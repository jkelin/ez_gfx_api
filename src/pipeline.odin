package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_PIPELINES :: 8
EZ_GFX_MAX_PIPELINE_DESCRIPTOR_BINDINGS ::
	EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS + EZ_GFX_MAX_SHADER_TARGET_DECLARATIONS

Ez_Gfx_Pipeline_Record :: struct {
	shader_identity:       u64,
	shader:                ^Ez_Gfx_Shader_Program,
	color_formats:         [EZ_GFX_MAX_SHADER_TARGET_USAGES]vk.Format,
	color_format_count:    int,
	pipeline_layout:       vk.PipelineLayout,
	pipeline:              vk.Pipeline,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_pool:       vk.DescriptorPool,
	descriptor_set:        vk.DescriptorSet,
	last_used:             u64,
}

Ez_Gfx_Pipeline_Manager :: struct {
	records: [EZ_GFX_MAX_PIPELINES]Ez_Gfx_Pipeline_Record,
	count:   int,
	clock:   u64,
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

// TODO: Add topology, blend, depth, and rasterization options to the cache key.
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

	for i in 0 ..< manager.count {
		candidate := &manager.records[i]
		if candidate.shader_identity == shader.identity &&
		   ez_gfx_pipeline_color_formats_equal(candidate, color_formats, color_format_count) {
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

	slot.shader_identity = shader.identity
	slot.shader = shader
	slot.color_formats = color_formats
	slot.color_format_count = color_format_count
	slot.last_used = manager.clock
	if !ez_gfx_pipeline_record_create(ctx, slot, shader) {
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

	set_layout_count: u32
	set_layouts := [?]vk.DescriptorSetLayout{record.descriptor_set_layout}
	if record.descriptor_set_layout != vk.DescriptorSetLayout(0) {
		set_layout_count = 1
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = set_layout_count,
		pSetLayouts    = &set_layouts[0],
	}
	if vk.CreatePipelineLayout(ctx.device, &layout_info, nil, &record.pipeline_layout) !=
	   .SUCCESS {
		fmt.eprintln("failed to create pipeline layout")
		return false
	}

	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}

	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
		blendEnable    = false,
	}
	color_blend_state := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
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
		pDynamicState       = &dynamic_state,
		layout              = record.pipeline_layout,
	}

	if vk.CreateGraphicsPipelines(ctx.device, 0, 1, &pipeline_info, nil, &record.pipeline) !=
	   .SUCCESS {
		fmt.eprintln("failed to create graphics pipeline")
		return false
	}

	return true
}

ez_gfx_pipeline_create_descriptors :: proc(
	ctx: ^Ez_Gfx_Ctx,
	record: ^Ez_Gfx_Pipeline_Record,
	shader: ^Ez_Gfx_Shader_Program,
) -> bool {
	binding_count := shader.vertex_heap_binding_count + shader.target_declaration_count
	if binding_count == 0 {
		return true
	}

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

	for i in 0 ..< shader.target_declaration_count {
		target_info := &shader.target_declarations[i]
		if target_info.set != 0 {
			fmt.eprintln("only descriptor set 0 is supported for render targets")
			return false
		}

		layout_bindings[binding_index] = vk.DescriptorSetLayoutBinding {
			binding         = target_info.binding,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
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

	pool_sizes: [2]vk.DescriptorPoolSize
	pool_size_count := 0
	if shader.vertex_heap_binding_count > 0 {
		pool_sizes[pool_size_count] = vk.DescriptorPoolSize {
			type            = .STORAGE_BUFFER,
			descriptorCount = u32(shader.vertex_heap_binding_count),
		}
		pool_size_count += 1
	}
	if shader.target_declaration_count > 0 {
		pool_sizes[pool_size_count] = vk.DescriptorPoolSize {
			type            = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = u32(shader.target_declaration_count),
		}
		pool_size_count += 1
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = u32(pool_size_count),
		pPoolSizes    = &pool_sizes[0],
	}
	if vk.CreateDescriptorPool(ctx.device, &pool_info, nil, &record.descriptor_pool) != .SUCCESS {
		fmt.eprintln("failed to create descriptor pool")
		return false
	}

	allocate_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = record.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &record.descriptor_set_layout,
	}
	if vk.AllocateDescriptorSets(ctx.device, &allocate_info, &record.descriptor_set) != .SUCCESS {
		fmt.eprintln("failed to allocate descriptor set")
		return false
	}

	return ez_gfx_pipeline_update_descriptors(ctx, record, shader)
}

ez_gfx_pipeline_update_descriptors :: proc(
	ctx: ^Ez_Gfx_Ctx,
	record: ^Ez_Gfx_Pipeline_Record,
	shader: ^Ez_Gfx_Shader_Program,
) -> bool {
	if record.descriptor_set == vk.DescriptorSet(0) do return true

	buffer_infos: [EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS]vk.DescriptorBufferInfo
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
			dstSet          = record.descriptor_set,
			dstBinding      = binding_info.binding,
			descriptorCount = 1,
			descriptorType  = .STORAGE_BUFFER,
			pBufferInfo     = &buffer_infos[i],
		}
		write_count += 1
	}

	for i in 0 ..< shader.target_declaration_count {
		target_info := &shader.target_declarations[i]
		target := ez_gfx_render_target_manager_find(
			&ctx.render_target_manager,
			target_info.name[:],
			target_info.name_len,
		)
		if target == nil {
			continue
		}

		image_infos[i] = vk.DescriptorImageInfo {
			sampler     = target.sampler,
			imageView   = target.image_view,
			imageLayout = ez_gfx_render_target_descriptor_layout(target.kind),
		}
		writes[write_count] = vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = record.descriptor_set,
			dstBinding      = target_info.binding,
			descriptorCount = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			pImageInfo      = &image_infos[i],
		}
		write_count += 1
	}

	if write_count > 0 {
		vk.UpdateDescriptorSets(ctx.device, u32(write_count), &writes[0], 0, nil)
	}
	return true
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
	record.descriptor_set = vk.DescriptorSet(0)
	record.shader_identity = 0
	record.shader = nil
	record.color_formats = {}
	record.color_format_count = 0
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
