package ez_gfx

import "core:fmt"
import vk "vendor:vulkan"

EZ_GFX_MAX_RENDER_TARGETS :: 16

Ez_Gfx_Render_Target_Texture :: struct {
	name:                [EZ_GFX_SHADER_TARGET_NAME_MAX]byte,
	name_len:            int,
	image:               vk.Image,
	memory:              vk.DeviceMemory,
	image_view:          vk.ImageView,
	sampler:             vk.Sampler,
	format:              vk.Format,
	extent:              vk.Extent2D,
	relative_scale:      f32,
	kind:                Ez_Gfx_Render_Target_Kind,
	layout:              vk.ImageLayout,
	initialized:         bool,
	load_on_frame_begin: bool,
	frame_clear_pending: bool,
	last_write_timeline: u64,
}

Ez_Gfx_Render_Target_Manager :: struct {
	targets: [EZ_GFX_MAX_RENDER_TARGETS]Ez_Gfx_Render_Target_Texture,
	count:   int,
	version: u64,
}

ez_gfx_render_target_manager_acquire_shader_targets :: proc(
	manager: ^Ez_Gfx_Render_Target_Manager,
	shader: ^Ez_Gfx_Shader_Program,
	swapchain_extent: vk.Extent2D,
) -> bool {
	for i in 0 ..< shader.target_declaration_count {
		declaration := &shader.target_declarations[i]
		_, ok := ez_gfx_render_target_manager_acquire(manager, declaration, swapchain_extent)
		if !ok do return false
	}
	return true
}

ez_gfx_render_target_manager_acquire :: proc(
	manager: ^Ez_Gfx_Render_Target_Manager,
	declaration: ^Ez_Gfx_Shader_Target_Declaration,
	swapchain_extent: vk.Extent2D,
) -> (
	target: ^Ez_Gfx_Render_Target_Texture,
	ok: bool,
) {
	extent := ez_gfx_render_target_scaled_extent(swapchain_extent, declaration.relative_scale)
	for i in 0 ..< manager.count {
		candidate := &manager.targets[i]
		if ez_gfx_shader_target_name_equals_bytes(
			   candidate.name[:],
			   candidate.name_len,
			   declaration.name[:],
			   declaration.name_len,
		   ) &&
		   candidate.format == declaration.format &&
		   candidate.kind == declaration.kind &&
		   candidate.relative_scale == declaration.relative_scale &&
		   candidate.extent.width == extent.width &&
		   candidate.extent.height == extent.height {
			if candidate.load_on_frame_begin != declaration.load_on_frame_begin {
				fmt.eprintln("render target LoadTarget declarations conflict")
				return nil, false
			}
			return candidate, true
		}
	}

	if manager.count >= EZ_GFX_MAX_RENDER_TARGETS {
		fmt.eprintln("too many render targets")
		return nil, false
	}

	slot := &manager.targets[manager.count]
	manager.count += 1
	if !ez_gfx_render_target_create(slot, declaration, extent) {
		manager.count -= 1
		slot^ = {}
		return nil, false
	}
	manager.version += 1
	return slot, true
}

ez_gfx_render_target_scaled_extent :: proc(
	swapchain_extent: vk.Extent2D,
	relative_scale: f32,
) -> vk.Extent2D {
	width := u32(f32(swapchain_extent.width) * relative_scale)
	height := u32(f32(swapchain_extent.height) * relative_scale)
	if width == 0 do width = 1
	if height == 0 do height = 1
	return vk.Extent2D{width = width, height = height}
}

ez_gfx_render_target_create :: proc(
	target: ^Ez_Gfx_Render_Target_Texture,
	declaration: ^Ez_Gfx_Shader_Target_Declaration,
	extent: vk.Extent2D,
) -> bool {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return false

	target^ = {}
	target.name = declaration.name
	target.name_len = declaration.name_len
	target.format = declaration.format
	target.extent = extent
	target.relative_scale = declaration.relative_scale
	target.kind = declaration.kind
	target.layout = .UNDEFINED
	target.load_on_frame_begin = declaration.load_on_frame_begin

	usage := ez_gfx_render_target_image_usage(declaration.kind)
	create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = declaration.format,
		extent = vk.Extent3D{width = extent.width, height = extent.height, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = usage,
		sharingMode = .EXCLUSIVE,
	}
	if vk.CreateImage(ctx.device, &create_info, nil, &target.image) != .SUCCESS {
		fmt.eprintln("failed to create render target image")
		return false
	}
	ez_gfx_debug_set_named_object(
		ctx,
		.IMAGE,
		ez_gfx_debug_handle(target.image),
		"ez_gfx render target image",
		target.name[:],
		target.name_len,
	)

	mem_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(ctx.device, target.image, &mem_requirements)
	priority_info := vk.MemoryPriorityAllocateInfoEXT {
		sType    = .MEMORY_PRIORITY_ALLOCATE_INFO_EXT,
		priority = 0.8,
	}
	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = ctx.memory_priority_enabled ? &priority_info : nil,
		allocationSize  = mem_requirements.size,
		memoryTypeIndex = ez_gfx_find_memory_type(
			ctx.physical_device,
			mem_requirements.memoryTypeBits,
			{.DEVICE_LOCAL},
		),
	}
	if vk.AllocateMemory(ctx.device, &alloc_info, nil, &target.memory) != .SUCCESS {
		fmt.eprintln("failed to allocate render target memory")
		ez_gfx_render_target_destroy(target)
		return false
	}
	ez_gfx_debug_set_named_object(
		ctx,
		.DEVICE_MEMORY,
		ez_gfx_debug_handle(target.memory),
		"ez_gfx render target memory",
		target.name[:],
		target.name_len,
	)
	if vk.BindImageMemory(ctx.device, target.image, target.memory, 0) != .SUCCESS {
		fmt.eprintln("failed to bind render target memory")
		ez_gfx_render_target_destroy(target)
		return false
	}

	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = target.image,
		viewType = .D2,
		format = target.format,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = ez_gfx_render_target_aspect(target.kind),
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	if vk.CreateImageView(ctx.device, &view_info, nil, &target.image_view) != .SUCCESS {
		fmt.eprintln("failed to create render target image view")
		ez_gfx_render_target_destroy(target)
		return false
	}
	ez_gfx_debug_set_named_object(
		ctx,
		.IMAGE_VIEW,
		ez_gfx_debug_handle(target.image_view),
		"ez_gfx render target view",
		target.name[:],
		target.name_len,
	)

	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .NEAREST,
		minFilter    = .NEAREST,
		mipmapMode   = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod       = 1,
	}
	if vk.CreateSampler(ctx.device, &sampler_info, nil, &target.sampler) != .SUCCESS {
		fmt.eprintln("failed to create render target sampler")
		ez_gfx_render_target_destroy(target)
		return false
	}
	ez_gfx_debug_set_named_object(
		ctx,
		.SAMPLER,
		ez_gfx_debug_handle(target.sampler),
		"ez_gfx render target sampler",
		target.name[:],
		target.name_len,
	)

	return true
}

ez_gfx_render_target_image_usage :: proc(kind: Ez_Gfx_Render_Target_Kind) -> vk.ImageUsageFlags {
	if kind == .Depth {
		return {.SAMPLED, .DEPTH_STENCIL_ATTACHMENT, .TRANSFER_DST}
	}
	return {.SAMPLED, .STORAGE, .COLOR_ATTACHMENT, .TRANSFER_DST}
}

ez_gfx_render_target_aspect :: proc(kind: Ez_Gfx_Render_Target_Kind) -> vk.ImageAspectFlags {
	if kind == .Depth do return {.DEPTH}
	return {.COLOR}
}

ez_gfx_render_target_descriptor_layout :: proc(kind: Ez_Gfx_Render_Target_Kind) -> vk.ImageLayout {
	if kind == .Depth do return .DEPTH_READ_ONLY_OPTIMAL
	return .SHADER_READ_ONLY_OPTIMAL
}

ez_gfx_render_target_transition_for_access :: proc(
	target: ^Ez_Gfx_Render_Target_Texture,
	access: Ez_Gfx_Target_Access,
	command_buffer: vk.CommandBuffer,
) {
	new_layout := ez_gfx_render_target_descriptor_layout(target.kind)
	src_access := vk.AccessFlags2{}
	src_stage := vk.PipelineStageFlags2{.ALL_COMMANDS}
	dst_access := vk.AccessFlags2{.SHADER_SAMPLED_READ}
	dst_stage := vk.PipelineStageFlags2{.VERTEX_SHADER, .FRAGMENT_SHADER}
	if target.layout == .TRANSFER_DST_OPTIMAL {
		src_access = {.TRANSFER_WRITE}
		src_stage = {.TRANSFER}
	}
	if access == .Write || access == .Read_Write {
		new_layout = .GENERAL
		dst_access = {.SHADER_SAMPLED_READ, .SHADER_STORAGE_WRITE}
		dst_stage = {.ALL_COMMANDS}
	}
	if target.layout == new_layout do return

	ez_gfx_transition_image_with_aspect(
		command_buffer,
		target.image,
		target.layout,
		new_layout,
		src_access,
		dst_access,
		src_stage,
		dst_stage,
		ez_gfx_render_target_aspect(target.kind),
	)
	target.layout = new_layout
	if access == .Write || access == .Read_Write {
		target.initialized = true
	}
}

ez_gfx_render_target_transition_for_sampled_read :: proc(
	target: ^Ez_Gfx_Render_Target_Texture,
	command_buffer: vk.CommandBuffer,
) {
	new_layout := ez_gfx_render_target_descriptor_layout(target.kind)
	ez_gfx_render_target_transition(
		target,
		command_buffer,
		new_layout,
		{.SHADER_SAMPLED_READ},
		{.VERTEX_SHADER, .FRAGMENT_SHADER},
	)
}

ez_gfx_render_target_transition_for_color_attachment :: proc(
	target: ^Ez_Gfx_Render_Target_Texture,
	command_buffer: vk.CommandBuffer,
) {
	ez_gfx_render_target_transition(
		target,
		command_buffer,
		.COLOR_ATTACHMENT_OPTIMAL,
		{.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
	)
}

ez_gfx_render_target_transition_for_depth_attachment :: proc(
	target: ^Ez_Gfx_Render_Target_Texture,
	command_buffer: vk.CommandBuffer,
) {
	ez_gfx_render_target_transition(
		target,
		command_buffer,
		.DEPTH_ATTACHMENT_OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
	)
}

ez_gfx_render_target_transition :: proc(
	target: ^Ez_Gfx_Render_Target_Texture,
	command_buffer: vk.CommandBuffer,
	new_layout: vk.ImageLayout,
	dst_access: vk.AccessFlags2,
	dst_stage: vk.PipelineStageFlags2,
) {
	if target.layout == new_layout do return
	ez_gfx_transition_image_with_aspect(
		command_buffer,
		target.image,
		target.layout,
		new_layout,
		ez_gfx_image_layout_src_access(target.layout),
		dst_access,
		ez_gfx_image_layout_src_stage(target.layout),
		dst_stage,
		ez_gfx_render_target_aspect(target.kind),
	)
	target.layout = new_layout
}

ez_gfx_render_target_clear_initial :: proc(
	target: ^Ez_Gfx_Render_Target_Texture,
	command_buffer: vk.CommandBuffer,
) {
	// Frame-start clears give non-load targets deterministic contents before graph use.
	ez_gfx_transition_image_with_aspect(
		command_buffer,
		target.image,
		target.layout,
		.TRANSFER_DST_OPTIMAL,
		ez_gfx_image_layout_src_access(target.layout),
		{.TRANSFER_WRITE},
		ez_gfx_image_layout_src_stage(target.layout),
		{.TRANSFER},
		ez_gfx_render_target_aspect(target.kind),
	)

	range_info := vk.ImageSubresourceRange {
		aspectMask     = ez_gfx_render_target_aspect(target.kind),
		baseMipLevel   = 0,
		levelCount     = 1,
		baseArrayLayer = 0,
		layerCount     = 1,
	}
	if target.kind == .Depth {
		clear_value := vk.ClearDepthStencilValue {
			depth   = 1.0,
			stencil = 0,
		}
		vk.CmdClearDepthStencilImage(
			command_buffer,
			target.image,
			.TRANSFER_DST_OPTIMAL,
			&clear_value,
			1,
			&range_info,
		)
	} else {
		clear_value := vk.ClearColorValue {
			float32 = {0, 0, 0, 0},
		}
		vk.CmdClearColorImage(
			command_buffer,
			target.image,
			.TRANSFER_DST_OPTIMAL,
			&clear_value,
			1,
			&range_info,
		)
	}
	target.layout = .TRANSFER_DST_OPTIMAL
	target.initialized = true
}

ez_gfx_render_target_manager_find :: proc(
	manager: ^Ez_Gfx_Render_Target_Manager,
	name: []byte,
	name_len: int,
) -> ^Ez_Gfx_Render_Target_Texture {
	for i in 0 ..< manager.count {
		target := &manager.targets[i]
		if ez_gfx_shader_target_name_equals_bytes(
			target.name[:],
			target.name_len,
			name,
			name_len,
		) {
			return target
		}
	}
	return nil
}

ez_gfx_render_target_manager_clear_frame_targets :: proc(
	manager: ^Ez_Gfx_Render_Target_Manager,
	ctx: ^Ez_Gfx_Ctx,
	command_buffer: vk.CommandBuffer,
) -> bool {
	for i in 0 ..< manager.count {
		target := &manager.targets[i]
		if target.load_on_frame_begin && target.initialized {
			target.frame_clear_pending = false
			continue
		}
		if !ez_gfx_ctx_wait_timeline(ctx, target.last_write_timeline) {
			return false
		}
		ez_gfx_render_target_clear_initial(target, command_buffer)
		target.frame_clear_pending = true
	}
	return true
}

ez_gfx_render_target_manager_mark_frame_clears_submitted :: proc(
	manager: ^Ez_Gfx_Render_Target_Manager,
	timeline_value: u64,
) {
	for i in 0 ..< manager.count {
		target := &manager.targets[i]
		if !target.frame_clear_pending do continue
		target.last_write_timeline = timeline_value
		target.frame_clear_pending = false
	}
}

ez_gfx_render_target_manager_transition_shader_targets :: proc(
	manager: ^Ez_Gfx_Render_Target_Manager,
	shader: ^Ez_Gfx_Shader_Program,
	command_buffer: vk.CommandBuffer,
) -> bool {
	for i in 0 ..< shader.target_usage_count {
		usage := &shader.target_usages[i]
		if ez_gfx_shader_target_name_equals_cstring(usage.name[:], usage.name_len, "swapchain") {
			continue
		}
		target := ez_gfx_render_target_manager_find(manager, usage.name[:], usage.name_len)
		if target == nil {
			fmt.eprintln("shader target was not acquired before rendering")
			return false
		}
		ez_gfx_render_target_transition_for_access(target, usage.access, command_buffer)
	}
	return true
}

ez_gfx_render_target_destroy :: proc(target: ^Ez_Gfx_Render_Target_Texture) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil || ctx.device == nil do return
	if target.sampler != vk.Sampler(0) {
		vk.DestroySampler(ctx.device, target.sampler, nil)
	}
	if target.image_view != vk.ImageView(0) {
		vk.DestroyImageView(ctx.device, target.image_view, nil)
	}
	if target.image != vk.Image(0) {
		vk.DestroyImage(ctx.device, target.image, nil)
	}
	if target.memory != vk.DeviceMemory(0) {
		vk.FreeMemory(ctx.device, target.memory, nil)
	}
	target^ = {}
}

ez_gfx_render_target_manager_clear :: proc(manager: ^Ez_Gfx_Render_Target_Manager) {
	for i in 0 ..< manager.count {
		ez_gfx_render_target_destroy(&manager.targets[i])
	}
	manager.count = 0
	manager.version += 1
}

ez_gfx_render_target_manager_destroy :: proc(manager: ^Ez_Gfx_Render_Target_Manager) {
	ez_gfx_render_target_manager_clear(manager)
}
