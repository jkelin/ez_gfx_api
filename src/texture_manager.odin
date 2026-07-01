package ez_gfx

import vma "../vendor/odin-vma"
import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:fmt"
import image "core:image"
import bmp "core:image/bmp"
import jpeg "core:image/jpeg"
import png "core:image/png"
import tga "core:image/tga"
import "core:mem"
import "core:sync"
import "core:thread"
import vk "vendor:vulkan"

EZ_GFX_MAX_TEXTURES :: 1024
EZ_GFX_TEXTURE_DEBUG_LABEL_MAX :: 64

Ez_Gfx_Texture_ID :: distinct u32

Ez_Gfx_Source_Texture_Format :: enum u8 {
	RGB,
	RGBA,
	BMP,
	JPEG,
	PNG,
	TGA,
}

Ez_Gfx_Texture_Error :: enum u8 {
	None,
	Invalid_Context,
	Invalid_Arguments,
	Unsupported_Format,
	Out_Of_Texture_Handles,
	Out_Of_Memory,
	Decode_Failed,
	Vulkan_Failed,
	Worker_Unavailable,
	Not_Found,
}

Ez_Gfx_Texture_Memory_Region :: struct {
	data: []u8,
}

Ez_Gfx_Texture_Filter :: enum u8 {
	Nearest,
	Linear,
}

Ez_Gfx_Texture_Address_Mode :: enum u8 {
	Repeat,
	Clamp_To_Edge,
}

Ez_Gfx_Load_Texture_Desc :: struct {
	source_format:      Ez_Gfx_Source_Texture_Format,
	destination_format: vk.Format,
	width:              u32,
	height:             u32,
	mip_count:          u32,
	generate_mips:      bool,
	min_filter:         Ez_Gfx_Texture_Filter,
	mag_filter:         Ez_Gfx_Texture_Filter,
	address_mode_u:     Ez_Gfx_Texture_Address_Mode,
	address_mode_v:     Ez_Gfx_Texture_Address_Mode,
	address_mode_w:     Ez_Gfx_Texture_Address_Mode,
	debug_label:        string,
}

Ez_Gfx_Texture_Loaded_Callback :: #type proc(
	ctx: ^Ez_Gfx_Ctx,
	texture_id: Ez_Gfx_Texture_ID,
	err: Ez_Gfx_Texture_Error,
	user_data: rawptr,
)

Ez_Gfx_Texture_State :: enum u8 {
	Empty,
	Queued,
	Loading,
	Ready,
	Failed,
	Unloading,
}

Ez_Gfx_Texture_Record :: struct {
	id:                 Ez_Gfx_Texture_ID,
	state:              Ez_Gfx_Texture_State,
	image:              vk.Image,
	allocation:         vma.Allocation,
	allocation_info:    vma.Allocation_Info,
	image_view:         vk.ImageView,
	sampler:            vk.Sampler,
	format:             vk.Format,
	width:              u32,
	height:             u32,
	mip_count:          u32,
	layout:             vk.ImageLayout,
	last_write_timeline: u64,
	last_use_timeline:   u64,
	error:              Ez_Gfx_Texture_Error,
	debug_label:        [EZ_GFX_TEXTURE_DEBUG_LABEL_MAX]byte,
	debug_label_len:    int,
}

Ez_Gfx_Texture_Load_Job :: struct {
	id:      Ez_Gfx_Texture_ID,
	regions: [dynamic]Ez_Gfx_Texture_Memory_Region,
	desc:    Ez_Gfx_Load_Texture_Desc,
}

Ez_Gfx_Texture_Destroy_Job :: struct {
	record:          Ez_Gfx_Texture_Record,
	retire_timeline: u64,
}

Ez_Gfx_Texture_Manager :: struct {
	textures:                         [EZ_GFX_MAX_TEXTURES]Ez_Gfx_Texture_Record,
	descriptor_set_layout:            vk.DescriptorSetLayout,
	descriptor_pool:                  vk.DescriptorPool,
	descriptor_set:                   vk.DescriptorSet,
	upload_command_pool:              vk.CommandPool,
	upload_command_buffer:            vk.CommandBuffer,
	worker:                           ^thread.Thread,
	mutex:                            sync.Mutex,
	cond:                             sync.Cond,
	jobs:                             [dynamic]Ez_Gfx_Texture_Load_Job,
	pending_destroys:                 [dynamic]Ez_Gfx_Texture_Destroy_Job,
	shutdown:                         bool,
	latest_scheduled_texture_timeline: u64,
	latest_submitted_texture_timeline: u64,
	latest_completed_texture_timeline: u64,
}

// Schedules an asynchronous texture load. On success, the returned texture ID is the
// bindless descriptor array index; ID 0 is a valid texture. The caller must keep every
// memory region valid until the texture_loaded callback fires, including failure callbacks.
ez_gfx_load_texture :: proc(
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> (
	texture_id: Ez_Gfx_Texture_ID,
	err: Ez_Gfx_Texture_Error,
) {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return 0, .Invalid_Context
	return ez_gfx_texture_manager_load(&ctx.texture_manager, ctx, regions, desc)
}

ez_gfx_unload_texture :: proc(texture_id: Ez_Gfx_Texture_ID) -> Ez_Gfx_Texture_Error {
	ctx := ez_gfx_get_current_ctx()
	if ctx == nil do return .Invalid_Context
	return ez_gfx_texture_manager_unload(&ctx.texture_manager, ctx, texture_id)
}

ez_gfx_texture_manager_create :: proc(manager: ^Ez_Gfx_Texture_Manager, ctx: ^Ez_Gfx_Ctx) -> bool {
	manager^ = {}
	manager.jobs = make([dynamic]Ez_Gfx_Texture_Load_Job)
	manager.pending_destroys = make([dynamic]Ez_Gfx_Texture_Destroy_Job)

	if !ez_gfx_texture_manager_create_descriptors(manager, ctx) {
		ez_gfx_texture_manager_destroy(manager, ctx)
		return false
	}
	if !ez_gfx_texture_manager_create_upload_commands(manager, ctx) {
		ez_gfx_texture_manager_destroy(manager, ctx)
		return false
	}

	manager.worker = thread.create(ez_gfx_texture_upload_thread)
	if manager.worker == nil {
		fmt.eprintln("failed to create texture upload thread")
		ez_gfx_texture_manager_destroy(manager, ctx)
		return false
	}
	manager.worker.data = manager
	thread.start(manager.worker)
	return true
}

ez_gfx_texture_manager_destroy :: proc(manager: ^Ez_Gfx_Texture_Manager, ctx: ^Ez_Gfx_Ctx) {
	if manager.worker != nil {
		sync.mutex_lock(&manager.mutex)
		manager.shutdown = true
		sync.mutex_unlock(&manager.mutex)
		sync.cond_broadcast(&manager.cond)
		thread.join(manager.worker)
		thread.destroy(manager.worker)
		manager.worker = nil
	}

	for i in 0 ..< len(manager.jobs) {
		ez_gfx_texture_load_job_destroy(&manager.jobs[i])
	}
	if raw_data(manager.jobs) != nil do delete(manager.jobs)
	for i in 0 ..< len(manager.pending_destroys) {
		ez_gfx_texture_record_destroy(ctx, &manager.pending_destroys[i].record)
	}
	if raw_data(manager.pending_destroys) != nil do delete(manager.pending_destroys)

	for i in 0 ..< len(manager.textures) {
		ez_gfx_texture_record_destroy(ctx, &manager.textures[i])
	}
	if ctx != nil && ctx.device != nil {
		if manager.upload_command_pool != vk.CommandPool(0) {
			vk.DestroyCommandPool(ctx.device, manager.upload_command_pool, nil)
		}
		if manager.descriptor_pool != vk.DescriptorPool(0) {
			vk.DestroyDescriptorPool(ctx.device, manager.descriptor_pool, nil)
		}
		if manager.descriptor_set_layout != vk.DescriptorSetLayout(0) {
			vk.DestroyDescriptorSetLayout(ctx.device, manager.descriptor_set_layout, nil)
		}
	}
	manager^ = {}
}

ez_gfx_texture_manager_load :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> (
	texture_id: Ez_Gfx_Texture_ID,
	err: Ez_Gfx_Texture_Error,
) {
	if ctx == nil || manager == nil do return 0, .Invalid_Context
	if manager.worker == nil do return 0, .Worker_Unavailable
	if len(regions) == 0 || len(regions) > 16 do return 0, .Invalid_Arguments
	for region in regions {
		if len(region.data) == 0 do return 0, .Invalid_Arguments
	}

	desc := ez_gfx_texture_prepare_desc(desc)
	if desc.destination_format == vk.Format(0) do return 0, .Invalid_Arguments
	if desc.mip_count == 0 do return 0, .Invalid_Arguments
	if (desc.source_format == .RGB || desc.source_format == .RGBA) &&
	   (desc.width == 0 || desc.height == 0) {
		return 0, .Invalid_Arguments
	}

	sync.mutex_lock(&manager.mutex)
	defer sync.mutex_unlock(&manager.mutex)

	slot, slot_index := ez_gfx_texture_manager_alloc_slot(manager)
	if slot == nil do return 0, .Out_Of_Texture_Handles

	texture_id = Ez_Gfx_Texture_ID(slot_index)
	slot^ = {}
	slot.id = texture_id
	slot.state = .Queued
	slot.format = desc.destination_format
	slot.width = desc.width
	slot.height = desc.height
	slot.mip_count = desc.mip_count
	slot.layout = .UNDEFINED
	slot.last_write_timeline = ez_gfx_ctx_next_timeline_value(ctx)
	ez_gfx_texture_copy_debug_label(slot, desc.debug_label)
	intrinsics.atomic_store_explicit(
		&manager.latest_scheduled_texture_timeline,
		slot.last_write_timeline,
		.Seq_Cst,
	)

	job := Ez_Gfx_Texture_Load_Job{id = texture_id, desc = desc}
	job.regions = make([dynamic]Ez_Gfx_Texture_Memory_Region)
	for region in regions {
		append(&job.regions, region)
	}
	append(&manager.jobs, job)
	sync.cond_signal(&manager.cond)
	return texture_id, .None
}

ez_gfx_texture_manager_unload :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	texture_id: Ez_Gfx_Texture_ID,
) -> Ez_Gfx_Texture_Error {
	if ctx == nil || manager == nil do return .Invalid_Context

	sync.mutex_lock(&manager.mutex)
	defer sync.mutex_unlock(&manager.mutex)

	record := ez_gfx_texture_manager_find_locked(manager, texture_id)
	if record == nil do return .Not_Found
	if record.state == .Queued || record.state == .Loading {
		record.state = .Unloading
		return .None
	}
	retire_timeline := max(record.last_write_timeline, record.last_use_timeline)
	append(&manager.pending_destroys, Ez_Gfx_Texture_Destroy_Job {
		record = record^,
		retire_timeline = retire_timeline,
	})
	record^ = {}
	return .None
}

ez_gfx_texture_manager_latest_scheduled_timeline :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
) -> u64 {
	if manager == nil do return 0
	return intrinsics.atomic_load_explicit(&manager.latest_scheduled_texture_timeline, .Seq_Cst)
}

ez_gfx_texture_manager_wait_submitted_timeline :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	target_timeline: u64,
) -> bool {
	if manager == nil || target_timeline == 0 do return true
	sync.mutex_lock(&manager.mutex)
	defer sync.mutex_unlock(&manager.mutex)

	for !manager.shutdown &&
	    intrinsics.atomic_load_explicit(&manager.latest_submitted_texture_timeline, .Seq_Cst) <
	    target_timeline {
		sync.cond_wait(&manager.cond, &manager.mutex)
	}
	return intrinsics.atomic_load_explicit(&manager.latest_submitted_texture_timeline, .Seq_Cst) >=
	       target_timeline
}

ez_gfx_texture_manager_mark_submitted :: proc(manager: ^Ez_Gfx_Texture_Manager, timeline: u64) {
	if manager == nil || timeline == 0 do return
	sync.mutex_lock(&manager.mutex)
	if timeline > manager.latest_submitted_texture_timeline {
		intrinsics.atomic_store_explicit(
			&manager.latest_submitted_texture_timeline,
			timeline,
			.Seq_Cst,
		)
	}
	sync.mutex_unlock(&manager.mutex)
	sync.cond_broadcast(&manager.cond)
}

ez_gfx_texture_manager_create_descriptors :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
) -> bool {
	binding_flags := [?]vk.DescriptorBindingFlags{{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND}}
	layout_binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = EZ_GFX_MAX_TEXTURES,
		stageFlags      = {.VERTEX, .FRAGMENT},
	}
	binding_flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = 1,
		pBindingFlags = &binding_flags[0],
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &binding_flags_info,
		flags        = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = 1,
		pBindings    = &layout_binding,
	}
	if vk.CreateDescriptorSetLayout(ctx.device, &layout_info, nil, &manager.descriptor_set_layout) !=
	   .SUCCESS {
		fmt.eprintln("failed to create texture descriptor set layout")
		return false
	}
	ez_gfx_debug_set_object_name(
		ctx,
		.DESCRIPTOR_SET_LAYOUT,
		ez_gfx_debug_handle(manager.descriptor_set_layout),
		"ez_gfx bindless texture descriptor layout",
	)

	pool_size := vk.DescriptorPoolSize {
		type            = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = EZ_GFX_MAX_TEXTURES,
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	if vk.CreateDescriptorPool(ctx.device, &pool_info, nil, &manager.descriptor_pool) != .SUCCESS {
		fmt.eprintln("failed to create texture descriptor pool")
		return false
	}

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = manager.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &manager.descriptor_set_layout,
	}
	if vk.AllocateDescriptorSets(ctx.device, &alloc_info, &manager.descriptor_set) != .SUCCESS {
		fmt.eprintln("failed to allocate texture descriptor set")
		return false
	}
	ez_gfx_debug_set_object_name(
		ctx,
		.DESCRIPTOR_SET,
		ez_gfx_debug_handle(manager.descriptor_set),
		"ez_gfx bindless texture descriptor set",
	)
	return true
}

ez_gfx_texture_manager_create_upload_commands :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
) -> bool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = ctx.queue_family_index,
	}
	if vk.CreateCommandPool(ctx.device, &pool_info, nil, &manager.upload_command_pool) != .SUCCESS {
		fmt.eprintln("failed to create texture upload command pool")
		return false
	}
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = manager.upload_command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if vk.AllocateCommandBuffers(ctx.device, &alloc_info, &manager.upload_command_buffer) != .SUCCESS {
		fmt.eprintln("failed to allocate texture upload command buffer")
		return false
	}
	return true
}

ez_gfx_texture_upload_thread :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	manager := cast(^Ez_Gfx_Texture_Manager)worker.data
	ctx := ez_gfx_current_ctx
	if manager == nil {
		return
	}
	// The current context is thread-local, so the worker discovers its owner through the manager.
	ctx = ez_gfx_texture_manager_find_owner(manager)
	if ctx == nil {
		return
	}
	ez_gfx_set_current_ctx(ctx)

	for {
		job: Ez_Gfx_Texture_Load_Job
		has_job := false

		sync.mutex_lock(&manager.mutex)
		for len(manager.jobs) == 0 && !manager.shutdown {
			sync.cond_wait(&manager.cond, &manager.mutex)
		}
		if manager.shutdown {
			sync.mutex_unlock(&manager.mutex)
			break
		}
		job = manager.jobs[0]
		ordered_remove(&manager.jobs, 0)
		record := ez_gfx_texture_manager_find_locked(manager, job.id)
		if record != nil && record.state == .Queued {
			record.state = .Loading
			has_job = true
		}
		sync.mutex_unlock(&manager.mutex)

		if !has_job {
			ez_gfx_texture_load_job_destroy(&job)
			continue
		}

		err := ez_gfx_texture_upload_job(manager, ctx, &job)
		ez_gfx_texture_finish_job(manager, ctx, job.id, err)
		ez_gfx_texture_load_job_destroy(&job)
	}
}

ez_gfx_texture_manager_find_owner :: proc(manager: ^Ez_Gfx_Texture_Manager) -> ^Ez_Gfx_Ctx {
	// The manager lives directly inside the context. Reconstructing the owner avoids copying
	// the context into the worker and keeps shutdown ownership centralized in `Ez_Gfx_Ctx`.
	return cast(^Ez_Gfx_Ctx)(uintptr(manager) - offset_of(Ez_Gfx_Ctx, texture_manager))
}

ez_gfx_texture_upload_job :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Error {
	decoded_pixels: []u8
	width, height: u32
	decode_err := ez_gfx_texture_decode_job(job, &decoded_pixels, &width, &height)
	if decode_err != .None do return decode_err
	defer delete(decoded_pixels)

	sync.mutex_lock(&manager.mutex)
	record := ez_gfx_texture_manager_find_locked(manager, job.id)
	if record == nil || record.state == .Unloading {
		sync.mutex_unlock(&manager.mutex)
		return .None
	}
	record.width = width
	record.height = height
	mip_count := job.desc.mip_count
	if job.desc.generate_mips && mip_count == 1 {
		mip_count = ez_gfx_texture_full_mip_count(width, height)
	}
	record.mip_count = mip_count
	signal_value := record.last_write_timeline
	sync.mutex_unlock(&manager.mutex)

	image, allocation, allocation_info, image_err := ez_gfx_texture_create_image(
		ctx,
		job.desc.destination_format,
		width,
		height,
		mip_count,
	)
	if image_err != .None do return image_err

	staging, staging_ok := ez_gfx_buffer_create(
		vk.DeviceSize(len(decoded_pixels)),
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
		"ez_gfx texture staging buffer",
		0.2,
	)
	if !staging_ok {
		vma.destroy_image(ctx.vma_allocator, image, allocation)
		return .Vulkan_Failed
	}
	defer ez_gfx_buffer_destroy(&staging)
	if !ez_gfx_buffer_write(&staging, decoded_pixels) {
		vma.destroy_image(ctx.vma_allocator, image, allocation)
		return .Vulkan_Failed
	}

	view, sampler, resource_err := ez_gfx_texture_create_view_and_sampler(
		ctx,
		image,
		job.desc.destination_format,
		mip_count,
		job.desc,
	)
	if resource_err != .None {
		vma.destroy_image(ctx.vma_allocator, image, allocation)
		return resource_err
	}

	sync.mutex_lock(&manager.mutex)
	record = ez_gfx_texture_manager_find_locked(manager, job.id)
	if record == nil || record.state == .Unloading {
		sync.mutex_unlock(&manager.mutex)
		vk.DestroySampler(ctx.device, sampler, nil)
		vk.DestroyImageView(ctx.device, view, nil)
		vma.destroy_image(ctx.vma_allocator, image, allocation)
		return .None
	}
	record.image = image
	record.allocation = allocation
	record.allocation_info = allocation_info
	record.image_view = view
	record.sampler = sampler
	record.layout = .SHADER_READ_ONLY_OPTIMAL
	sync.mutex_unlock(&manager.mutex)

	ez_gfx_texture_update_descriptor(manager, ctx, job.id)

	if !ez_gfx_texture_submit_upload(
		manager,
		ctx,
		image,
		width,
		height,
		mip_count,
		&staging,
		signal_value,
	) {
		ez_gfx_texture_clear_failed_resource(manager, ctx, job.id, image)
		return .Vulkan_Failed
	}
	if !ez_gfx_ctx_wait_timeline(ctx, signal_value) {
		ez_gfx_texture_clear_failed_resource(manager, ctx, job.id, image)
		return .Vulkan_Failed
	}
	return .None
}

ez_gfx_texture_finish_job :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	id: Ez_Gfx_Texture_ID,
	err: Ez_Gfx_Texture_Error,
) {
	call_callback := false
	failed_timeline: u64

	sync.mutex_lock(&manager.mutex)
	record := ez_gfx_texture_manager_find_locked(manager, id)
	if record != nil {
		if record.state == .Unloading {
			append(&manager.pending_destroys, Ez_Gfx_Texture_Destroy_Job {
				record = record^,
				retire_timeline = record.last_write_timeline,
			})
			record^ = {}
		} else if err == .None {
			record.state = .Ready
		} else {
			record.state = .Failed
			record.error = err
		}
		failed_timeline = record.last_write_timeline
		intrinsics.atomic_store_explicit(
			&manager.latest_completed_texture_timeline,
			record.last_write_timeline,
			.Seq_Cst,
		)
		call_callback = true
	}
	sync.mutex_unlock(&manager.mutex)

	if call_callback && err != .None {
		if ez_gfx_texture_signal_timeline(ctx, failed_timeline) {
			ez_gfx_texture_manager_mark_submitted(manager, failed_timeline)
		}
	}
	if call_callback && ctx.texture_loaded_callback != nil {
		ctx.texture_loaded_callback(ctx, id, err, ctx.texture_loaded_user_data)
	}
}

ez_gfx_texture_decode_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
	out_pixels: ^[]u8,
	out_width: ^u32,
	out_height: ^u32,
) -> Ez_Gfx_Texture_Error {
	if len(job.regions) == 0 do return .Invalid_Arguments
	region := job.regions[0]
	switch job.desc.source_format {
	case .RGB, .RGBA:
		channels := 3
		if job.desc.source_format == .RGBA do channels = 4
		expected := int(job.desc.width) * int(job.desc.height) * channels
		if expected <= 0 || len(region.data) != expected do return .Invalid_Arguments
		pixels := make([]u8, int(job.desc.width) * int(job.desc.height) * 4)
		src := region.data
		for i in 0 ..< int(job.desc.width) * int(job.desc.height) {
			pixels[i * 4 + 0] = src[i * channels + 0]
			pixels[i * 4 + 1] = src[i * channels + 1]
			pixels[i * 4 + 2] = src[i * channels + 2]
			pixels[i * 4 + 3] = channels == 4 ? src[i * channels + 3] : 255
		}
		out_pixels^ = pixels
		out_width^ = job.desc.width
		out_height^ = job.desc.height
		return .None
	case .BMP, .JPEG, .PNG, .TGA:
		img, img_err := image.load_from_bytes(region.data, {.alpha_add_if_missing})
		if img_err != nil || img == nil {
			return .Decode_Failed
		}
		defer image.destroy(img)
		if img.width <= 0 || img.height <= 0 || img.depth != 8 || img.channels != 4 {
			return .Decode_Failed
		}
		pixels := make([]u8, img.width * img.height * 4)
		mem.copy(raw_data(pixels), raw_data(img.pixels.buf), len(pixels))
		out_pixels^ = pixels
		out_width^ = u32(img.width)
		out_height^ = u32(img.height)
		return .None
	}
	return .Unsupported_Format
}

ez_gfx_texture_create_image :: proc(
	ctx: ^Ez_Gfx_Ctx,
	format: vk.Format,
	width, height, mip_count: u32,
) -> (
	image: vk.Image,
	allocation: vma.Allocation,
	allocation_info: vma.Allocation_Info,
	err: Ez_Gfx_Texture_Error,
) {
	create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = format,
		extent = vk.Extent3D{width = width, height = height, depth = 1},
		mipLevels = mip_count,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.SAMPLED, .TRANSFER_DST, .TRANSFER_SRC},
		sharingMode = .EXCLUSIVE,
	}
	alloc_info := vma.Allocation_Create_Info {
		usage           = .Auto_Prefer_Device,
		required_flags  = {.DEVICE_LOCAL},
		preferred_flags = {.DEVICE_LOCAL},
		priority        = 0.7,
	}
	if vma.create_image(
		   ctx.vma_allocator,
		   create_info,
		   alloc_info,
		   &image,
		   &allocation,
		   &allocation_info,
	   ) !=
	   .SUCCESS {
		return image, allocation, allocation_info, .Vulkan_Failed
	}
	return image, allocation, allocation_info, .None
}

ez_gfx_texture_submit_upload :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	image: vk.Image,
	width, height, mip_count: u32,
	staging: ^Ez_Gfx_Buffer,
	signal_value: u64,
) -> bool {
	command_buffer := manager.upload_command_buffer
	vk.ResetCommandBuffer(command_buffer, {})
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(command_buffer, &begin_info) != .SUCCESS {
		return false
	}

	ez_gfx_transition_texture_mips(
		command_buffer,
		image,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{},
		{.TRANSFER_WRITE},
		{.TOP_OF_PIPE},
		{.TRANSFER},
		0,
		mip_count,
	)
	region := vk.BufferImageCopy {
		imageSubresource = vk.ImageSubresourceLayers {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageExtent = vk.Extent3D{width = width, height = height, depth = 1},
	}
	vk.CmdCopyBufferToImage(command_buffer, staging.handle, image, .TRANSFER_DST_OPTIMAL, 1, &region)

	if mip_count > 1 {
		ez_gfx_texture_generate_mips(command_buffer, image, width, height, mip_count)
	} else {
		ez_gfx_transition_texture_mips(
			command_buffer,
			image,
			.TRANSFER_DST_OPTIMAL,
			.SHADER_READ_ONLY_OPTIMAL,
			{.TRANSFER_WRITE},
			{.SHADER_SAMPLED_READ},
			{.TRANSFER},
			{.VERTEX_SHADER, .FRAGMENT_SHADER},
			0,
			1,
		)
	}

	if vk.EndCommandBuffer(command_buffer) != .SUCCESS {
		return false
	}

	signal_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = ctx.timeline_semaphore,
		value     = signal_value,
		stageMask = {.ALL_COMMANDS},
	}
	command_submit := vk.CommandBufferSubmitInfo {
		sType = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = command_buffer,
	}
	submit_info := vk.SubmitInfo2 {
		sType = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos = &command_submit,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos = &signal_info,
	}
	sync.mutex_lock(&ctx.queue_mutex)
	result := vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, vk.Fence(0))
	sync.mutex_unlock(&ctx.queue_mutex)
	if result != .SUCCESS do return false
	ez_gfx_texture_manager_mark_submitted(manager, signal_value)
	return true
}

ez_gfx_transition_texture_mips :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_access, dst_access: vk.AccessFlags2,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	base_mip, mip_count: u32,
) {
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
			baseMipLevel = base_mip,
			levelCount = mip_count,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	dependency := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers = &barrier,
	}
	vk.CmdPipelineBarrier2(command_buffer, &dependency)
}

ez_gfx_texture_generate_mips :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	width, height, mip_count: u32,
) {
	mip_width := i32(width)
	mip_height := i32(height)
	for level: u32 = 1; level < mip_count; level += 1 {
		ez_gfx_transition_texture_mips(
			command_buffer,
			image,
			.TRANSFER_DST_OPTIMAL,
			.TRANSFER_SRC_OPTIMAL,
			{.TRANSFER_WRITE},
			{.TRANSFER_READ},
			{.TRANSFER},
			{.TRANSFER},
			level - 1,
			1,
		)
		next_width := mip_width > 1 ? mip_width / 2 : 1
		next_height := mip_height > 1 ? mip_height / 2 : 1
		blit := vk.ImageBlit {
			srcSubresource = {
				aspectMask = {.COLOR},
				mipLevel = level - 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			srcOffsets = { {x = 0, y = 0, z = 0}, {x = mip_width, y = mip_height, z = 1} },
			dstSubresource = {
				aspectMask = {.COLOR},
				mipLevel = level,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			dstOffsets = { {x = 0, y = 0, z = 0}, {x = next_width, y = next_height, z = 1} },
		}
		vk.CmdBlitImage(
			command_buffer,
			image,
			.TRANSFER_SRC_OPTIMAL,
			image,
			.TRANSFER_DST_OPTIMAL,
			1,
			&blit,
			.LINEAR,
		)
		ez_gfx_transition_texture_mips(
			command_buffer,
			image,
			.TRANSFER_SRC_OPTIMAL,
			.SHADER_READ_ONLY_OPTIMAL,
			{.TRANSFER_READ},
			{.SHADER_SAMPLED_READ},
			{.TRANSFER},
			{.VERTEX_SHADER, .FRAGMENT_SHADER},
			level - 1,
			1,
		)
		mip_width = next_width
		mip_height = next_height
	}
	ez_gfx_transition_texture_mips(
		command_buffer,
		image,
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER_WRITE},
		{.SHADER_SAMPLED_READ},
		{.TRANSFER},
		{.VERTEX_SHADER, .FRAGMENT_SHADER},
		mip_count - 1,
		1,
	)
}

ez_gfx_texture_create_view_and_sampler :: proc(
	ctx: ^Ez_Gfx_Ctx,
	image: vk.Image,
	format: vk.Format,
	mip_count: u32,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> (
	view: vk.ImageView,
	sampler: vk.Sampler,
	err: Ez_Gfx_Texture_Error,
) {
	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image,
		viewType = .D2,
		format = format,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = mip_count,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	if vk.CreateImageView(ctx.device, &view_info, nil, &view) != .SUCCESS {
		return view, sampler, .Vulkan_Failed
	}
	filter_min := ez_gfx_texture_filter_to_vk(desc.min_filter)
	filter_mag := ez_gfx_texture_filter_to_vk(desc.mag_filter)
	sampler_info := vk.SamplerCreateInfo {
		sType = .SAMPLER_CREATE_INFO,
		magFilter = filter_mag,
		minFilter = filter_min,
		mipmapMode = desc.min_filter == .Linear ? vk.SamplerMipmapMode.LINEAR : vk.SamplerMipmapMode.NEAREST,
		addressModeU = ez_gfx_texture_address_mode_to_vk(desc.address_mode_u),
		addressModeV = ez_gfx_texture_address_mode_to_vk(desc.address_mode_v),
		addressModeW = ez_gfx_texture_address_mode_to_vk(desc.address_mode_w),
		maxLod = f32(mip_count),
	}
	if vk.CreateSampler(ctx.device, &sampler_info, nil, &sampler) != .SUCCESS {
		vk.DestroyImageView(ctx.device, view, nil)
		return vk.ImageView(0), sampler, .Vulkan_Failed
	}
	return view, sampler, .None
}

ez_gfx_texture_update_descriptor :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	id: Ez_Gfx_Texture_ID,
) {
	sync.mutex_lock(&manager.mutex)
	record := ez_gfx_texture_manager_find_locked(manager, id)
	if record == nil || record.image_view == vk.ImageView(0) || record.sampler == vk.Sampler(0) {
		sync.mutex_unlock(&manager.mutex)
		return
	}
	image_info := vk.DescriptorImageInfo {
		sampler = record.sampler,
		imageView = record.image_view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	array_index := u32(id)
	sync.mutex_unlock(&manager.mutex)

	write := vk.WriteDescriptorSet {
		sType = .WRITE_DESCRIPTOR_SET,
		dstSet = manager.descriptor_set,
		dstBinding = 0,
		dstArrayElement = array_index,
		descriptorCount = 1,
		descriptorType = .COMBINED_IMAGE_SAMPLER,
		pImageInfo = &image_info,
	}
	vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
}

ez_gfx_texture_record_destroy :: proc(ctx: ^Ez_Gfx_Ctx, record: ^Ez_Gfx_Texture_Record) {
	if ctx == nil || ctx.device == nil || record == nil do return
	if record.sampler != vk.Sampler(0) {
		vk.DestroySampler(ctx.device, record.sampler, nil)
	}
	if record.image_view != vk.ImageView(0) {
		vk.DestroyImageView(ctx.device, record.image_view, nil)
	}
	if record.image != vk.Image(0) || record.allocation != vma.Allocation(nil) {
		if ctx.vma_allocator != vma.Allocator(nil) {
			vma.destroy_image(ctx.vma_allocator, record.image, record.allocation)
		}
	}
	record^ = {}
}

ez_gfx_texture_clear_failed_resource :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	id: Ez_Gfx_Texture_ID,
	image: vk.Image,
) {
	record_copy: Ez_Gfx_Texture_Record
	has_record := false

	sync.mutex_lock(&manager.mutex)
	record := ez_gfx_texture_manager_find_locked(manager, id)
	if record != nil && record.image == image {
		record_copy = record^
		record.image = vk.Image(0)
		record.allocation = vma.Allocation(nil)
		record.allocation_info = {}
		record.image_view = vk.ImageView(0)
		record.sampler = vk.Sampler(0)
		record.layout = .UNDEFINED
		has_record = true
	}
	sync.mutex_unlock(&manager.mutex)

	if has_record {
		ez_gfx_texture_record_destroy(ctx, &record_copy)
	}
}

ez_gfx_texture_signal_timeline :: proc(ctx: ^Ez_Gfx_Ctx, value: u64) -> bool {
	if ctx == nil || value == 0 do return true
	current: u64
	if vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &current) == .SUCCESS &&
	   current >= value {
		return true
	}

	signal_info := vk.SemaphoreSignalInfo {
		sType     = .SEMAPHORE_SIGNAL_INFO,
		semaphore = ctx.timeline_semaphore,
		value     = value,
	}
	sync.mutex_lock(&ctx.queue_mutex)
	result := vk.SignalSemaphore(ctx.device, &signal_info)
	sync.mutex_unlock(&ctx.queue_mutex)
	if result != .SUCCESS {
		fmt.eprintln("failed to signal failed texture upload timeline")
		return false
	}
	return true
}

ez_gfx_texture_load_job_destroy :: proc(job: ^Ez_Gfx_Texture_Load_Job) {
	if raw_data(job.regions) != nil {
		delete(job.regions)
	}
	job^ = {}
}

ez_gfx_texture_manager_collect_destroyed :: proc(manager: ^Ez_Gfx_Texture_Manager, ctx: ^Ez_Gfx_Ctx) {
	completed := ez_gfx_gpu_heap_completed_timeline()
	sync.mutex_lock(&manager.mutex)
	i := 0
	for i < len(manager.pending_destroys) {
		if manager.pending_destroys[i].retire_timeline > completed {
			i += 1
			continue
		}
		job := manager.pending_destroys[i]
		ordered_remove(&manager.pending_destroys, i)
		sync.mutex_unlock(&manager.mutex)
		ez_gfx_texture_record_destroy(ctx, &job.record)
		sync.mutex_lock(&manager.mutex)
	}
	sync.mutex_unlock(&manager.mutex)
}

ez_gfx_texture_prepare_desc :: proc(desc: Ez_Gfx_Load_Texture_Desc) -> Ez_Gfx_Load_Texture_Desc {
	desc := desc
	if desc.destination_format == vk.Format(0) do desc.destination_format = .R8G8B8A8_UNORM
	if desc.mip_count == 0 do desc.mip_count = 1
	if desc.generate_mips && desc.mip_count == 1 && desc.width > 0 && desc.height > 0 {
		desc.mip_count = ez_gfx_texture_full_mip_count(desc.width, desc.height)
	}
	if desc.min_filter == {} do desc.min_filter = .Linear
	if desc.mag_filter == {} do desc.mag_filter = .Linear
	if desc.address_mode_u == {} do desc.address_mode_u = .Repeat
	if desc.address_mode_v == {} do desc.address_mode_v = .Repeat
	if desc.address_mode_w == {} do desc.address_mode_w = .Repeat
	return desc
}

ez_gfx_texture_full_mip_count :: proc(width, height: u32) -> u32 {
	levels: u32 = 1
	size := max(width, height)
	for size > 1 {
		size /= 2
		levels += 1
	}
	return levels
}

ez_gfx_texture_filter_to_vk :: proc(filter: Ez_Gfx_Texture_Filter) -> vk.Filter {
	if filter == .Nearest do return .NEAREST
	return .LINEAR
}

ez_gfx_texture_address_mode_to_vk :: proc(mode: Ez_Gfx_Texture_Address_Mode) -> vk.SamplerAddressMode {
	if mode == .Clamp_To_Edge do return .CLAMP_TO_EDGE
	return .REPEAT
}

ez_gfx_texture_copy_debug_label :: proc(record: ^Ez_Gfx_Texture_Record, label: string) {
	record.debug_label = {}
	record.debug_label_len = min(len(label), EZ_GFX_TEXTURE_DEBUG_LABEL_MAX)
	for i in 0 ..< record.debug_label_len {
		record.debug_label[i] = label[i]
	}
}

ez_gfx_texture_manager_alloc_slot :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
) -> (
	slot: ^Ez_Gfx_Texture_Record,
	slot_index: u32,
) {
	for i in 0 ..< len(manager.textures) {
		if manager.textures[i].state == .Empty {
			return &manager.textures[i], u32(i)
		}
	}
	return nil, 0
}

ez_gfx_texture_manager_find_locked :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	id: Ez_Gfx_Texture_ID,
) -> ^Ez_Gfx_Texture_Record {
	for i in 0 ..< len(manager.textures) {
		if manager.textures[i].id == id && manager.textures[i].state != .Empty {
			return &manager.textures[i]
		}
	}
	return nil
}

@(private)
_texture_manager_keep_image_loaders_registered :: proc() {
	_ = bmp.load
	_ = jpeg.load
	_ = png.load
	_ = tga.load
	_ = bytes.Buffer{}
}
