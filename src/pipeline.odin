package main

import "core:fmt"
import vk "vendor:vulkan"

// Builds an empty pipeline layout and a dynamic-rendering graphics pipeline for the triangle shader.
ez_gfx_pipeline_create_triangle :: proc(
	ctx: ^Ez_Gfx_Ctx,
	shader: ^Ez_Gfx_Shader_Program,
	color_format: vk.Format,
) -> bool {
	if !ez_gfx_pipeline_create_vertex_heap_descriptors(ctx, shader) {
		return false
	}

	set_layout_count: u32
	set_layouts := [?]vk.DescriptorSetLayout{ctx.descriptor_set_layout}
	if ctx.descriptor_set_layout != vk.DescriptorSetLayout(0) {
		set_layout_count = 1
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = set_layout_count,
		pSetLayouts    = &set_layouts[0],
	}
	if vk.CreatePipelineLayout(ctx.device, &layout_info, nil, &ctx.pipeline_layout) != .SUCCESS {
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
			pName = SLANG_VERTEX_ENTRY,
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = shader.module,
			pName = SLANG_FRAGMENT_ENTRY,
		},
	}

	color_attachment_format := color_format
	rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_attachment_format,
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
		layout              = ctx.pipeline_layout,
	}

	if vk.CreateGraphicsPipelines(ctx.device, 0, 1, &pipeline_info, nil, &ctx.pipeline) !=
	   .SUCCESS {
		fmt.eprintln("failed to create graphics pipeline")
		ez_gfx_pipeline_destroy(ctx)
		return false
	}

	return true
}

ez_gfx_pipeline_create_vertex_heap_descriptors :: proc(
	ctx: ^Ez_Gfx_Ctx,
	shader: ^Ez_Gfx_Shader_Program,
) -> bool {
	if shader.vertex_heap_binding_count == 0 {
		return true
	}

	layout_bindings: [EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS]vk.DescriptorSetLayoutBinding
	buffer_infos: [EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS]vk.DescriptorBufferInfo
	writes: [EZ_GFX_MAX_SHADER_VERTEX_HEAP_BINDINGS]vk.WriteDescriptorSet

	for i in 0 ..< shader.vertex_heap_binding_count {
		binding_info := &shader.vertex_heap_bindings[i]
		if binding_info.set != 0 {
			fmt.eprintln("only descriptor set 0 is supported for vertex heaps")
			return false
		}

		heap := ez_gfx_vertex_manager_find_heap_by_stored_name(
			&ctx.vertex_manager,
			binding_info.name[:],
			binding_info.name_len,
		)
		if heap == nil {
			fmt.eprintln("shader references a missing vertex heap")
			return false
		}

		layout_bindings[i] = vk.DescriptorSetLayoutBinding {
			binding         = binding_info.binding,
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags      = {.VERTEX},
		}
		buffer_infos[i] = vk.DescriptorBufferInfo {
			buffer = heap.buffer.handle,
			offset = 0,
			range  = heap.capacity,
		}
		writes[i] = vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstBinding      = binding_info.binding,
			descriptorCount = 1,
			descriptorType  = .STORAGE_BUFFER,
			pBufferInfo     = &buffer_infos[i],
		}
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(shader.vertex_heap_binding_count),
		pBindings    = &layout_bindings[0],
	}
	if vk.CreateDescriptorSetLayout(ctx.device, &layout_info, nil, &ctx.descriptor_set_layout) !=
	   .SUCCESS {
		fmt.eprintln("failed to create descriptor set layout")
		return false
	}

	pool_size := vk.DescriptorPoolSize {
		type            = .STORAGE_BUFFER,
		descriptorCount = u32(shader.vertex_heap_binding_count),
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	if vk.CreateDescriptorPool(ctx.device, &pool_info, nil, &ctx.descriptor_pool) != .SUCCESS {
		fmt.eprintln("failed to create descriptor pool")
		return false
	}

	allocate_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = ctx.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &ctx.descriptor_set_layout,
	}
	if vk.AllocateDescriptorSets(ctx.device, &allocate_info, &ctx.descriptor_set) != .SUCCESS {
		fmt.eprintln("failed to allocate descriptor set")
		return false
	}

	for i in 0 ..< shader.vertex_heap_binding_count {
		writes[i].dstSet = ctx.descriptor_set
	}
	vk.UpdateDescriptorSets(ctx.device, u32(shader.vertex_heap_binding_count), &writes[0], 0, nil)
	return true
}

ez_gfx_pipeline_destroy :: proc(ctx: ^Ez_Gfx_Ctx) {
	if ctx.device == nil do return
	if ctx.pipeline != vk.Pipeline(0) {
		vk.DestroyPipeline(ctx.device, ctx.pipeline, nil)
		ctx.pipeline = vk.Pipeline(0)
	}
	if ctx.pipeline_layout != vk.PipelineLayout(0) {
		vk.DestroyPipelineLayout(ctx.device, ctx.pipeline_layout, nil)
		ctx.pipeline_layout = vk.PipelineLayout(0)
	}
}
