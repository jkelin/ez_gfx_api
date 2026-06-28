package main

import "core:fmt"
import vk "vendor:vulkan"

// Builds an empty pipeline layout and a dynamic-rendering graphics pipeline for the triangle shader.
ez_gfx_pipeline_create_triangle :: proc(
	ctx: ^Ez_Gfx_Ctx,
	shader_module: vk.ShaderModule,
	color_format: vk.Format,
) -> bool {
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
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
			module = shader_module,
			pName = SLANG_VERTEX_ENTRY,
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = shader_module,
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
