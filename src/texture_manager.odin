#+private
package ez_gfx

import vma "../vendor/odin-vma"
import ktx "../vendor/odin-ktx"
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


























@(private)
_ez_gfx_image_decoders: [Ez_Gfx_Source_Texture_Format]Ez_Gfx_Image_Decoder_Callback

@(private)
_ez_gfx_image_decoder_mutex: sync.Mutex

@(private)
image_decoder_format_supported :: proc(
	format: Ez_Gfx_Source_Texture_Format,
) -> bool {
	format_value := u8(format)
	return format_value >= u8(Ez_Gfx_Source_Texture_Format.BMP) &&
		format_value <= u8(Ez_Gfx_Source_Texture_Format.KTX2)
}

// Registers or clears an encoded-image decoder. Raw RGB/RGBA uploads remain built in.
register_image_decoder :: proc(
	format: Ez_Gfx_Source_Texture_Format,
	callback: Ez_Gfx_Image_Decoder_Callback,
) -> bool {
	if !image_decoder_format_supported(format) {
		return false
	}
	sync.mutex_lock(&_ez_gfx_image_decoder_mutex)
	_ez_gfx_image_decoders[format] = callback
	sync.mutex_unlock(&_ez_gfx_image_decoder_mutex)
	return true
}

@(private)
image_decoder_lookup :: proc(
	format: Ez_Gfx_Source_Texture_Format,
) -> Ez_Gfx_Image_Decoder_Callback {
	if !image_decoder_format_supported(format) {
		return nil
	}
	sync.mutex_lock(&_ez_gfx_image_decoder_mutex)
	callback := _ez_gfx_image_decoders[format]
	sync.mutex_unlock(&_ez_gfx_image_decoder_mutex)
	return callback
}

// Enables the built-in decoder for one encoded image format.
enable_bmp_decoder :: proc() -> bool {
	return register_image_decoder(.BMP, decode_bmp_upload_job)
}

enable_jpeg_decoder :: proc() -> bool {
	return register_image_decoder(.JPEG, decode_jpeg_upload_job)
}

enable_png_decoder :: proc() -> bool {
	return register_image_decoder(.PNG, decode_png_upload_job)
}

enable_tga_decoder :: proc() -> bool {
	return register_image_decoder(.TGA, decode_tga_upload_job)
}

enable_ktx2_decoder :: proc() -> bool {
	return register_image_decoder(.KTX2, decode_ktx2_upload_job)
}

// Enables every built-in encoded-image decoder.
enable_all_decoders :: proc() -> bool {
	bmp_ok := enable_bmp_decoder()
	jpeg_ok := enable_jpeg_decoder()
	png_ok := enable_png_decoder()
	tga_ok := enable_tga_decoder()
	ktx2_ok := enable_ktx2_decoder()
	return bmp_ok && jpeg_ok && png_ok && tga_ok && ktx2_ok
}










// Schedules an asynchronous texture load. On success, the returned texture ID is the
// bindless descriptor array index; ID 0 is a valid texture. The caller must keep every
// memory region valid until the texture_loaded callback fires, including failure callbacks.
load_texture :: proc(
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> (
	texture_id: Ez_Gfx_Texture_ID,
	err: Ez_Gfx_Texture_Error,
) {
	ctx := get_current_ctx()
	return texture_manager_load(&ctx.texture_manager, ctx, regions, desc)
}

unload_texture :: proc(texture_id: Ez_Gfx_Texture_ID) -> Ez_Gfx_Texture_Error {
	ctx := get_current_ctx()
	return texture_manager_unload(&ctx.texture_manager, ctx, texture_id)
}

texture_manager_create :: proc(manager: ^Ez_Gfx_Texture_Manager, ctx: ^Ez_Gfx_Ctx) -> bool {
	manager^ = {}
	manager.decode_worker_count = texture_manager_resolve_decode_worker_count(ctx)
	manager.decode_workers = make([dynamic]^thread.Thread)
	manager.decode_jobs = make([dynamic]Ez_Gfx_Texture_Load_Job)
	manager.upload_jobs = make([dynamic]Ez_Gfx_Texture_Upload_Job)
	manager.pending_destroys = make([dynamic]Ez_Gfx_Texture_Destroy_Job)
	manager.pending_staging = make([dynamic]Ez_Gfx_Texture_Staging_Retire_Job)
	manager.pending_graphics_handoffs = make([dynamic]Ez_Gfx_Texture_Graphics_Handoff_Job)

	if !texture_manager_create_descriptors(manager, ctx) {
		texture_manager_destroy(manager, ctx)
		return false
	}
	if !texture_manager_create_upload_commands(manager, ctx) {
		texture_manager_destroy(manager, ctx)
		return false
	}

	for i: u32 = 0; i < manager.decode_worker_count; i += 1 {
		worker := thread.create(texture_decode_thread)
		if worker == nil {
			fmt.eprintln("failed to create texture decode thread")
			texture_manager_destroy(manager, ctx)
			return false
		}
		worker.data = manager
		append(&manager.decode_workers, worker)
		thread.start(worker)
	}

	manager.upload_worker = thread.create(texture_upload_thread)
	if manager.upload_worker == nil {
		fmt.eprintln("failed to create texture upload thread")
		texture_manager_destroy(manager, ctx)
		return false
	}
	manager.upload_worker.data = manager
	thread.start(manager.upload_worker)
	return true
}

texture_manager_destroy :: proc(manager: ^Ez_Gfx_Texture_Manager, ctx: ^Ez_Gfx_Ctx) {
	if manager.upload_worker != nil || len(manager.decode_workers) > 0 {
		sync.mutex_lock(&manager.mutex)
		manager.shutdown = true
		sync.mutex_unlock(&manager.mutex)
		sync.cond_broadcast(&manager.cond)
		if manager.upload_worker != nil {
			thread.join(manager.upload_worker)
			thread.destroy(manager.upload_worker)
			manager.upload_worker = nil
		}
		for worker in manager.decode_workers {
			if worker == nil do continue
			thread.join(worker)
			thread.destroy(worker)
		}
	}

	for i in 0 ..< len(manager.decode_jobs) {
		texture_load_job_destroy(&manager.decode_jobs[i])
	}
	if raw_data(manager.decode_jobs) != nil do delete(manager.decode_jobs)
	for i in 0 ..< len(manager.upload_jobs) {
		texture_upload_job_destroy(&manager.upload_jobs[i])
	}
	if raw_data(manager.upload_jobs) != nil do delete(manager.upload_jobs)
	if raw_data(manager.decode_workers) != nil do delete(manager.decode_workers)
	for i in 0 ..< len(manager.pending_destroys) {
		texture_record_destroy(ctx, &manager.pending_destroys[i].record)
	}
	if raw_data(manager.pending_destroys) != nil do delete(manager.pending_destroys)
	for i in 0 ..< len(manager.pending_staging) {
		buffer_destroy(&manager.pending_staging[i].buffer)
	}
	if raw_data(manager.pending_staging) != nil do delete(manager.pending_staging)
	if raw_data(manager.pending_graphics_handoffs) != nil do delete(manager.pending_graphics_handoffs)

	for i in 0 ..< len(manager.textures) {
		texture_record_destroy(ctx, &manager.textures[i])
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

texture_manager_load :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	regions: []Ez_Gfx_Texture_Memory_Region,
	desc: Ez_Gfx_Load_Texture_Desc,
) -> (
	texture_id: Ez_Gfx_Texture_ID,
	err: Ez_Gfx_Texture_Error,
) {
	desc := texture_prepare_desc(desc)
	if image_decoder_format_supported(desc.source_format) &&
	   image_decoder_lookup(desc.source_format) == nil {
		return 0, .Unsupported_Format
	}
	if manager.upload_worker == nil || len(manager.decode_workers) == 0 do return 0, .Worker_Unavailable
	sync.mutex_lock(&manager.mutex)
	defer sync.mutex_unlock(&manager.mutex)

	slot, slot_index := texture_manager_alloc_slot(manager)
	if slot == nil do return 0, .Out_Of_Texture_Handles

	texture_id = Ez_Gfx_Texture_ID(slot_index)
	slot^ = {}
	slot.id = texture_id
	slot.state = .Queued
	slot.format = texture_destination_format_to_vk(desc.destination_format)
	slot.width = desc.width
	slot.height = desc.height
	slot.mip_count = desc.mip_count
	slot.layout = .UNDEFINED
	slot.last_write_timeline = ctx_next_timeline_value(ctx)
	texture_copy_debug_label(slot, shader_cstring_to_string(desc.debug_label))
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
	append(&manager.decode_jobs, job)
	sync.cond_broadcast(&manager.cond)
	return texture_id, .None
}

texture_manager_unload :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	texture_id: Ez_Gfx_Texture_ID,
) -> Ez_Gfx_Texture_Error {
	if ctx == nil || manager == nil do return .Invalid_Context

	sync.mutex_lock(&manager.mutex)
	defer sync.mutex_unlock(&manager.mutex)

	record := texture_manager_find_locked(manager, texture_id)
	if record == nil do return .Not_Found
	texture_manager_remove_pending_handoffs_locked(manager, texture_id)
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

texture_manager_latest_scheduled_timeline :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
) -> u64 {
	if manager == nil do return 0
	return intrinsics.atomic_load_explicit(&manager.latest_scheduled_texture_timeline, .Seq_Cst)
}

texture_manager_wait_submitted_timeline :: proc(
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

texture_manager_mark_submitted :: proc(manager: ^Ez_Gfx_Texture_Manager, timeline: u64) {
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

texture_manager_create_descriptors :: proc(
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
	debug_set_object_name(
		ctx,
		.DESCRIPTOR_SET_LAYOUT,
		debug_handle(manager.descriptor_set_layout),
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
	debug_set_object_name(
		ctx,
		.DESCRIPTOR_SET,
		debug_handle(manager.descriptor_set),
		"ez_gfx bindless texture descriptor set",
	)
	return true
}

texture_manager_create_upload_commands :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
) -> bool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = ctx.transfer_queue_family_index,
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

texture_decode_thread :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	manager := cast(^Ez_Gfx_Texture_Manager)worker.data
	if manager == nil {
		return
	}

	for {
		job: Ez_Gfx_Texture_Load_Job
		has_job := false

		sync.mutex_lock(&manager.mutex)
		for len(manager.decode_jobs) == 0 && !manager.shutdown {
			sync.cond_wait(&manager.cond, &manager.mutex)
		}
		if manager.shutdown {
			sync.mutex_unlock(&manager.mutex)
			break
		}
		job = manager.decode_jobs[0]
		ordered_remove(&manager.decode_jobs, 0)
		record := texture_manager_find_locked(manager, job.id)
		if record != nil && record.state == .Queued {
			record.state = .Loading
			has_job = true
		}
		sync.mutex_unlock(&manager.mutex)

		if !has_job {
			texture_load_job_destroy(&job)
			continue
		}

		upload_job := texture_decode_upload_job(&job)
		sync.mutex_lock(&manager.mutex)
		if manager.shutdown {
			sync.mutex_unlock(&manager.mutex)
			texture_upload_job_destroy(&upload_job)
			continue
		}
		append(&manager.upload_jobs, upload_job)
		sync.mutex_unlock(&manager.mutex)
		sync.cond_broadcast(&manager.cond)
	}
}

// Decode workers can finish out of order; wait until no earlier texture is still pending
// before allowing a later upload to block the shared command buffer.
texture_manager_take_ready_upload_job_locked :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
) -> int {
	if manager == nil || len(manager.upload_jobs) == 0 {
		return -1
	}

	earliest_pending_timeline := ~u64(0)
	for &record in manager.textures {
		if record.state == .Queued || record.state == .Loading {
			earliest_pending_timeline = min(
				earliest_pending_timeline,
				record.last_write_timeline,
			)
		}
	}

	best_index := -1
	best_timeline := ~u64(0)
	for candidate, index in manager.upload_jobs {
		timeline := u64(0)
		if record := texture_manager_find_locked(manager, candidate.load.id); record != nil {
			timeline = record.last_write_timeline
		}
		if timeline < best_timeline {
			best_timeline = timeline
			best_index = index
		}
	}
	if best_index < 0 || best_timeline > earliest_pending_timeline {
		return -1
	}
	return best_index
}

texture_upload_thread :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	manager := cast(^Ez_Gfx_Texture_Manager)worker.data
	if manager == nil {
		return
	}
	ctx := texture_manager_find_owner(manager)
	if ctx == nil {
		return
	}
	// Bind the owner to this worker's Odin context before using engine helpers.
	context.user_ptr = ctx

	for {
		job: Ez_Gfx_Texture_Upload_Job

		shutdown := false
		sync.mutex_lock(&manager.mutex)
		for {
			if manager.shutdown {
				shutdown = true
				break
			}
			job_index := texture_manager_take_ready_upload_job_locked(manager)
			if job_index >= 0 {
				job = manager.upload_jobs[job_index]
				ordered_remove(&manager.upload_jobs, job_index)
				break
			}
			sync.cond_wait(&manager.cond, &manager.mutex)
		}
		sync.mutex_unlock(&manager.mutex)
		if shutdown {
			break
		}

		err := job.err
		if err == .None {
			err = texture_upload_decoded_job(manager, ctx, &job)
		}
		texture_finish_job(manager, ctx, job.load.id, err)
		texture_upload_job_destroy(&job)
	}
}

texture_manager_find_owner :: proc(manager: ^Ez_Gfx_Texture_Manager) -> ^Ez_Gfx_Ctx {
	// The manager lives directly inside the context. Reconstructing the owner avoids copying
	// the context into the worker and keeps shutdown ownership centralized in `Ez_Gfx_Ctx`.
	return cast(^Ez_Gfx_Ctx)(uintptr(manager) - offset_of(Ez_Gfx_Ctx, texture_manager))
}

texture_upload_decoded_job :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	job: ^Ez_Gfx_Texture_Upload_Job,
) -> Ez_Gfx_Texture_Error {
	sync.mutex_lock(&manager.mutex)
	record := texture_manager_find_locked(manager, job.load.id)
	if record == nil || record.state == .Unloading {
		sync.mutex_unlock(&manager.mutex)
		return .None
	}
	record.width = job.width
	record.height = job.height
	mip_count := job.load.desc.mip_count
	if job.load.desc.generate_mips && mip_count == 1 {
		mip_count = texture_full_mip_count(job.width, job.height)
	}
	record.mip_count = mip_count
	signal_value := record.last_write_timeline
	sync.mutex_unlock(&manager.mutex)

	image, allocation, allocation_info, image_err := texture_create_image(
		ctx,
		texture_destination_format_to_vk(job.load.desc.destination_format),
		job.width,
		job.height,
		mip_count,
	)
	if image_err != .None do return image_err

	staging, staging_ok := buffer_create(
		texture_staging_size(job),
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
		"ez_gfx texture staging buffer",
		0.2,
		persistently_mapped = true,
	)
	if !staging_ok {
		vma.destroy_image(ctx.vma_allocator, image, allocation)
		return .Vulkan_Failed
	}
	if !texture_write_staging_pixels(&staging, job) {
		buffer_destroy(&staging)
		vma.destroy_image(ctx.vma_allocator, image, allocation)
		return .Vulkan_Failed
	}

	view, sampler, resource_err := texture_create_view_and_sampler(
		ctx,
		image,
		texture_destination_format_to_vk(job.load.desc.destination_format),
		mip_count,
		job.load.desc,
	)
	if resource_err != .None {
		buffer_destroy(&staging)
		vma.destroy_image(ctx.vma_allocator, image, allocation)
		return resource_err
	}

	sync.mutex_lock(&manager.mutex)
	record = texture_manager_find_locked(manager, job.load.id)
	if record == nil || record.state == .Unloading {
		sync.mutex_unlock(&manager.mutex)
		vk.DestroySampler(ctx.device, sampler, nil)
		vk.DestroyImageView(ctx.device, view, nil)
		buffer_destroy(&staging)
		vma.destroy_image(ctx.vma_allocator, image, allocation)
		return .None
	}
	record.image = image
	record.allocation = allocation
	record.allocation_info = allocation_info
	record.image_view = view
	record.sampler = sampler
	record.layout = .TRANSFER_DST_OPTIMAL
	sync.mutex_unlock(&manager.mutex)

	if !texture_submit_upload(
		manager,
		ctx,
		image,
		job.width,
		job.height,
		mip_count,
		&staging,
		signal_value,
	) {
		buffer_destroy(&staging)
		texture_clear_failed_resource(manager, ctx, job.load.id, image)
		return .Vulkan_Failed
	}
	texture_manager_track_submitted_upload(
		manager,
		job.load.id,
		image,
		job.width,
		job.height,
		mip_count,
		signal_value,
		staging,
	)
	texture_update_descriptor(manager, ctx, job.load.id)
	return .None
}

@(private)
texture_upload_job_is_valid :: proc(
	job: ^Ez_Gfx_Texture_Upload_Job,
) -> bool {
	if job == nil || job.err != .None || job.width == 0 || job.height == 0 {
		return false
	}

	channels: u64
	switch job.source {
	case .RGB:
		channels = 3
	case .RGBA:
		channels = 4
	case .None:
		return false
	}

	max_u64 := ~u64(0)
	width := u64(job.width)
	height := u64(job.height)
	if width > max_u64 / height {
		return false
	}
	pixel_count := width * height
	if pixel_count > max_u64 / channels {
		return false
	}
	expected_size := pixel_count * channels
	return expected_size == u64(len(job.pixels))
}

texture_decode_upload_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job {
	upload: Ez_Gfx_Texture_Upload_Job
	if job == nil {
		upload.err = .Invalid_Arguments
		return upload
	}
	upload.load = job^
	if len(job.regions) == 0 {
		upload.err = .Invalid_Arguments
		return upload
	}

	if callback := image_decoder_lookup(job.desc.source_format); callback != nil {
		upload = callback(job)
		upload.load = job^
		if upload.err == .None && !texture_upload_job_is_valid(&upload) {
			upload.err = .Decode_Failed
		}
		return upload
	}

	region := job.regions[0]
	switch job.desc.source_format {
	case .RGB, .RGBA:
		channels := 3
		upload.source = .RGB
		if job.desc.source_format == .RGBA {
			channels = 4
			upload.source = .RGBA
		}
		expected := int(job.desc.width) * int(job.desc.height) * channels
		if expected <= 0 || len(region.data) != expected {
			upload.err = .Invalid_Arguments
			return upload
		}
		upload.pixels = region.data
		upload.width = job.desc.width
		upload.height = job.desc.height
		upload.err = .None
		return upload
	case .BMP, .JPEG, .PNG, .TGA, .KTX2:
		upload.err = .Unsupported_Format
		return upload
	}
	upload.err = .Unsupported_Format
	return upload
}

texture_decode_ktx2 :: proc(
	data: []u8,
) -> (
	pixels: []u8,
	width: u32,
	height: u32,
	err: Ez_Gfx_Texture_Error,
) {
	if len(data) == 0 {
		err = .Invalid_Arguments
		return
	}

	texture: ^ktx.ktxTexture2
	flags := ktx.ktxTextureCreateFlags(
		ktx.ktxTextureCreateFlagBits.KTX_TEXTURE_CREATE_LOAD_IMAGE_DATA_BIT |
		ktx.ktxTextureCreateFlagBits.KTX_TEXTURE_CREATE_CHECK_GLTF_BASISU_BIT,
	)
	create_err := ktx.ktxTexture2_CreateFromMemory(
		cast(^ktx.ktx_uint8_t)raw_data(data),
		ktx.ktx_size_t(len(data)),
		flags,
		&texture,
	)
	if create_err != .KTX_SUCCESS || texture == nil {
		err = .Decode_Failed
		return
	}
	defer ktx.ktxTexture2_Destroy(texture)

	if texture.base.numDimensions != 2 ||
	   texture.base.baseWidth == 0 ||
	   texture.base.baseHeight == 0 ||
	   texture.base.numLayers != 1 ||
	   texture.base.numFaces != 1 {
		err = .Unsupported_Format
		return
	}

	if ktx.ktxTexture2_NeedsTranscoding(texture) {
		transcode_err := ktx.ktxTexture2_TranscodeBasis(
			texture,
			.KTX_TTF_RGBA32,
			0,
		)
		if transcode_err != .KTX_SUCCESS {
			err = .Decode_Failed
			return
		}
	} else {
		format := ktx.ktxTexture2_GetVkFormat(texture)
		if format != .R8G8B8A8_UNORM && format != .R8G8B8A8_SRGB {
			err = .Unsupported_Format
			return
		}
	}

	image_offset: ktx.ktx_size_t
	if ktx.ktxTexture2_GetImageOffset(texture, 0, 0, 0, &image_offset) != .KTX_SUCCESS {
		err = .Decode_Failed
		return
	}
	image_size := ktx.ktxTexture_GetImageSize(&texture.base, 0)
	expected_size := ktx.ktx_size_t(texture.base.baseWidth) *
		ktx.ktx_size_t(texture.base.baseHeight) *
		ktx.ktx_size_t(4)
	if image_size != expected_size ||
	   image_offset > texture.base.dataSize ||
	   image_size > texture.base.dataSize - image_offset {
		err = .Decode_Failed
		return
	}

	pixels = make([]u8, int(image_size))
	source := mem.ptr_offset(texture.base.pData, uintptr(image_offset))
	mem.copy(raw_data(pixels), source, len(pixels))
	width = texture.base.baseWidth
	height = texture.base.baseHeight
	err = .None
	return
}

@(private)
decode_core_image_upload_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
	loader: image.Loader_Proc,
) -> Ez_Gfx_Texture_Upload_Job {
	upload: Ez_Gfx_Texture_Upload_Job
	if job != nil {
		upload.load = job^
	}
	if job == nil || loader == nil || len(job.regions) == 0 {
		upload.err = .Invalid_Arguments
		return upload
	}

	region := job.regions[0]
	img, img_err := loader(region.data, {.alpha_add_if_missing}, context.allocator)
	if img_err != nil || img == nil {
		upload.err = .Decode_Failed
		return upload
	}
	defer image.destroy(img)
	if img.width <= 0 || img.height <= 0 || img.depth != 8 || img.channels != 4 {
		upload.err = .Decode_Failed
		return upload
	}

	upload.pixels = make([]u8, img.width * img.height * 4)
	mem.copy(raw_data(upload.pixels), raw_data(img.pixels.buf), len(upload.pixels))
	upload.width = u32(img.width)
	upload.height = u32(img.height)
	upload.source = .RGBA
	upload.owns_pixels = true
	upload.err = .None
	return upload
}

@(private)
decode_bmp_upload_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job {
	return decode_core_image_upload_job(job, bmp.load_from_bytes)
}

@(private)
decode_jpeg_upload_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job {
	return decode_core_image_upload_job(job, jpeg.load_from_bytes)
}

@(private)
decode_png_upload_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job {
	return decode_core_image_upload_job(job, png.load_from_bytes)
}

@(private)
decode_tga_upload_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job {
	return decode_core_image_upload_job(job, tga.load_from_bytes)
}

@(private)
decode_ktx2_upload_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job {
	upload: Ez_Gfx_Texture_Upload_Job
	if job != nil {
		upload.load = job^
	}
	if job == nil || len(job.regions) == 0 {
		upload.err = .Invalid_Arguments
		return upload
	}

	pixels, width, height, err := texture_decode_ktx2(job.regions[0].data)
	if err != .None {
		upload.err = err
		return upload
	}
	upload.pixels = pixels
	upload.width = width
	upload.height = height
	upload.source = .RGBA
	upload.owns_pixels = true
	upload.err = .None
	return upload
}

texture_staging_size :: proc(job: ^Ez_Gfx_Texture_Upload_Job) -> vk.DeviceSize {
	return vk.DeviceSize(job.width) * vk.DeviceSize(job.height) * 4
}

texture_write_staging_pixels :: proc(
	staging: ^Ez_Gfx_Buffer,
	job: ^Ez_Gfx_Texture_Upload_Job,
) -> bool {
	byte_size := texture_staging_size(job)
	if byte_size == 0 || byte_size > staging.size {
		fmt.eprintln("texture staging buffer is too small")
		return false
	}

	ctx := get_current_ctx()
	if ctx == nil do return false

	mapped := staging.mapped_data
	mapped_here := false
	if mapped == nil {
		if vma.map_memory(ctx.vma_allocator, staging.allocation, &mapped) != .SUCCESS {
			fmt.eprintln("failed to map texture staging buffer")
			return false
		}
		mapped_here = true
	}
	defer if mapped_here {
		vma.unmap_memory(ctx.vma_allocator, staging.allocation)
	}

	dst := ([^]u8)(mapped)
	switch job.source {
	case .RGBA:
		if len(job.pixels) != int(byte_size) {
			fmt.eprintln("RGBA texture byte count does not match staging size")
			return false
		}
		mem.copy(dst, raw_data(job.pixels), len(job.pixels))
		return true
	case .RGB:
		pixel_count := int(job.width) * int(job.height)
		if len(job.pixels) != pixel_count * 3 {
			fmt.eprintln("RGB texture byte count does not match staging size")
			return false
		}
		src := job.pixels
		for i in 0 ..< pixel_count {
			dst[i * 4 + 0] = src[i * 3 + 0]
			dst[i * 4 + 1] = src[i * 3 + 1]
			dst[i * 4 + 2] = src[i * 3 + 2]
			dst[i * 4 + 3] = 255
		}
		return true
	case .None:
		return false
	}
	return false
}

texture_finish_job :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	id: Ez_Gfx_Texture_ID,
	err: Ez_Gfx_Texture_Error,
) {
	call_callback := false
	failed_timeline: u64

	sync.mutex_lock(&manager.mutex)
	record := texture_manager_find_locked(manager, id)
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
		if texture_signal_timeline(ctx, failed_timeline) {
			texture_manager_mark_submitted(manager, failed_timeline)
		}
	}
	if call_callback && ctx.texture_loaded_callback != nil {
		context_handle, handle_ok := handle_pack_context(ctx.local_handle)
		if handle_ok {
			ctx.texture_loaded_callback(context_handle, id, err, ctx.texture_loaded_user_data)
		}
	}
}

texture_decode_job :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
	out_pixels: ^[]u8,
	out_width: ^u32,
	out_height: ^u32,
) -> Ez_Gfx_Texture_Error {
	if job == nil || out_pixels == nil || out_width == nil || out_height == nil {
		return .Invalid_Arguments
	}
	out_pixels^ = nil
	out_width^ = 0
	out_height^ = 0

	upload := texture_decode_upload_job(job)
	defer texture_upload_job_destroy(&upload)
	if upload.err != .None {
		return upload.err
	}

	pixel_count := int(upload.width) * int(upload.height)
	pixels := make([]u8, pixel_count * 4)
	switch upload.source {
	case .RGB:
		for i in 0 ..< pixel_count {
			pixels[i * 4 + 0] = upload.pixels[i * 3 + 0]
			pixels[i * 4 + 1] = upload.pixels[i * 3 + 1]
			pixels[i * 4 + 2] = upload.pixels[i * 3 + 2]
			pixels[i * 4 + 3] = 255
		}
	case .RGBA:
		mem.copy(raw_data(pixels), raw_data(upload.pixels), len(pixels))
	case .None:
		delete(pixels)
		return .Decode_Failed
	}
	out_pixels^ = pixels
	out_width^ = upload.width
	out_height^ = upload.height
	return .None
}

texture_create_image :: proc(
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

texture_submit_upload :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	image: vk.Image,
	width, height, mip_count: u32,
	staging: ^Ez_Gfx_Buffer,
	signal_value: u64,
) -> bool {
	if signal_value > 1 && !ctx_wait_timeline(ctx, signal_value - 1) {
		return false
	}
	command_buffer := manager.upload_command_buffer
	vk.ResetCommandBuffer(command_buffer, {})
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(command_buffer, &begin_info) != .SUCCESS {
		return false
	}

	transition_texture_mips(
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

	if ctx.transfer_queue_family_index != ctx.queue_family_index {
		transition_texture_mips_queue_family(
			command_buffer,
			image,
			.TRANSFER_DST_OPTIMAL,
			.TRANSFER_DST_OPTIMAL,
			{.TRANSFER_WRITE},
			{},
			{.TRANSFER},
			{.ALL_COMMANDS},
			0,
			mip_count,
			ctx.transfer_queue_family_index,
			ctx.queue_family_index,
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
	result := vk.QueueSubmit2(ctx.transfer_queue, 1, &submit_info, vk.Fence(0))
	sync.mutex_unlock(&ctx.queue_mutex)
	if result != .SUCCESS do return false
	texture_manager_mark_submitted(manager, signal_value)
	return true
}

texture_manager_track_submitted_upload :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	id: Ez_Gfx_Texture_ID,
	image: vk.Image,
	width, height, mip_count: u32,
	transfer_timeline: u64,
	staging: Ez_Gfx_Buffer,
) {
	sync.mutex_lock(&manager.mutex)
	append(&manager.pending_staging, Ez_Gfx_Texture_Staging_Retire_Job {
		buffer = staging,
		retire_timeline = transfer_timeline,
	})
	append(&manager.pending_graphics_handoffs, Ez_Gfx_Texture_Graphics_Handoff_Job {
		id = id,
		image = image,
		width = width,
		height = height,
		mip_count = mip_count,
		transfer_timeline = transfer_timeline,
	})
	sync.mutex_unlock(&manager.mutex)
}

texture_manager_remove_pending_handoffs_locked :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	id: Ez_Gfx_Texture_ID,
) {
	i := 0
	for i < len(manager.pending_graphics_handoffs) {
		if manager.pending_graphics_handoffs[i].id == id {
			ordered_remove(&manager.pending_graphics_handoffs, i)
			continue
		}
		i += 1
	}
}

texture_manager_record_graphics_handoffs :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	command_buffer: vk.CommandBuffer,
	up_to_timeline: u64,
) {
	if manager == nil || ctx == nil || command_buffer == nil do return
	sync.mutex_lock(&manager.mutex)
	i := 0
	for i < len(manager.pending_graphics_handoffs) {
		handoff := manager.pending_graphics_handoffs[i]
		if handoff.transfer_timeline > up_to_timeline {
			i += 1
			continue
		}
		ordered_remove(&manager.pending_graphics_handoffs, i)
		record := texture_manager_find_locked(manager, handoff.id)
		record_valid := record != nil && record.image == handoff.image && record.state != .Empty
		if record_valid {
			record.layout = .SHADER_READ_ONLY_OPTIMAL
		}
		sync.mutex_unlock(&manager.mutex)
		if record_valid {
			texture_record_graphics_handoff(ctx, command_buffer, handoff)
		}
		sync.mutex_lock(&manager.mutex)
	}
	sync.mutex_unlock(&manager.mutex)
}

texture_record_graphics_handoff :: proc(
	ctx: ^Ez_Gfx_Ctx,
	command_buffer: vk.CommandBuffer,
	handoff: Ez_Gfx_Texture_Graphics_Handoff_Job,
) {
	if ctx.transfer_queue_family_index != ctx.queue_family_index {
		transition_texture_mips_queue_family(
			command_buffer,
			handoff.image,
			.TRANSFER_DST_OPTIMAL,
			.TRANSFER_DST_OPTIMAL,
			{},
			{.TRANSFER_WRITE},
			{.ALL_COMMANDS},
			{.TRANSFER},
			0,
			handoff.mip_count,
			ctx.transfer_queue_family_index,
			ctx.queue_family_index,
		)
	}
	if handoff.mip_count > 1 {
		texture_generate_mips(
			command_buffer,
			handoff.image,
			handoff.width,
			handoff.height,
			handoff.mip_count,
		)
	} else {
		transition_texture_mips(
			command_buffer,
			handoff.image,
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
}

transition_texture_mips :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_access, dst_access: vk.AccessFlags2,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	base_mip, mip_count: u32,
) {
	transition_texture_mips_queue_family(
		command_buffer,
		image,
		old_layout,
		new_layout,
		src_access,
		dst_access,
		src_stage,
		dst_stage,
		base_mip,
		mip_count,
		vk.QUEUE_FAMILY_IGNORED,
		vk.QUEUE_FAMILY_IGNORED,
	)
}

transition_texture_mips_queue_family :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_access, dst_access: vk.AccessFlags2,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	base_mip, mip_count: u32,
	src_queue_family_index, dst_queue_family_index: u32,
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage,
		srcAccessMask = src_access,
		dstStageMask = dst_stage,
		dstAccessMask = dst_access,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = src_queue_family_index,
		dstQueueFamilyIndex = dst_queue_family_index,
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

texture_generate_mips :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	width, height, mip_count: u32,
) {
	mip_width := i32(width)
	mip_height := i32(height)
	for level: u32 = 1; level < mip_count; level += 1 {
		transition_texture_mips(
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
		mip_width = next_width
		mip_height = next_height
	}
	transition_texture_mips(
		command_buffer,
		image,
		.TRANSFER_SRC_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER_READ},
		{.SHADER_SAMPLED_READ},
		{.TRANSFER},
		{.VERTEX_SHADER, .FRAGMENT_SHADER},
		0,
		mip_count - 1,
	)
	transition_texture_mips(
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

texture_create_view_and_sampler :: proc(
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
	filter_min := texture_filter_to_vk(desc.min_filter)
	filter_mag := texture_filter_to_vk(desc.mag_filter)
	anisotropy_enabled := desc.max_anisotropy > 1.0 &&
		ctx.sampler_anisotropy_enabled &&
		ctx.max_sampler_anisotropy > 1.0
	max_anisotropy: f32 = 1.0
	if anisotropy_enabled {
		max_anisotropy = min(max(desc.max_anisotropy, 1.0), ctx.max_sampler_anisotropy)
	}
	sampler_info := vk.SamplerCreateInfo {
		sType = .SAMPLER_CREATE_INFO,
		magFilter = filter_mag,
		minFilter = filter_min,
		mipmapMode = desc.min_filter == .Linear ? vk.SamplerMipmapMode.LINEAR : vk.SamplerMipmapMode.NEAREST,
		anisotropyEnable = b32(anisotropy_enabled),
		maxAnisotropy  = max_anisotropy,
		addressModeU = texture_address_mode_to_vk(desc.address_mode_u),
		addressModeV = texture_address_mode_to_vk(desc.address_mode_v),
		addressModeW = texture_address_mode_to_vk(desc.address_mode_w),
		maxLod = f32(mip_count),
	}
	if vk.CreateSampler(ctx.device, &sampler_info, nil, &sampler) != .SUCCESS {
		vk.DestroyImageView(ctx.device, view, nil)
		return vk.ImageView(0), sampler, .Vulkan_Failed
	}
	return view, sampler, .None
}

texture_update_descriptor :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	id: Ez_Gfx_Texture_ID,
) {
	sync.mutex_lock(&manager.mutex)
	record := texture_manager_find_locked(manager, id)
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

texture_record_destroy :: proc(ctx: ^Ez_Gfx_Ctx, record: ^Ez_Gfx_Texture_Record) {
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

texture_clear_failed_resource :: proc(
	manager: ^Ez_Gfx_Texture_Manager,
	ctx: ^Ez_Gfx_Ctx,
	id: Ez_Gfx_Texture_ID,
	image: vk.Image,
) {
	record_copy: Ez_Gfx_Texture_Record
	has_record := false

	sync.mutex_lock(&manager.mutex)
	record := texture_manager_find_locked(manager, id)
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
		texture_record_destroy(ctx, &record_copy)
	}
}

texture_signal_timeline :: proc(ctx: ^Ez_Gfx_Ctx, value: u64) -> bool {
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

texture_load_job_destroy :: proc(job: ^Ez_Gfx_Texture_Load_Job) {
	if raw_data(job.regions) != nil {
		delete(job.regions)
	}
	job^ = {}
}

texture_upload_job_destroy :: proc(job: ^Ez_Gfx_Texture_Upload_Job) {
	if job.owns_pixels && raw_data(job.pixels) != nil {
		delete(job.pixels)
	}
	texture_load_job_destroy(&job.load)
	job^ = {}
}

texture_manager_resolve_decode_worker_count :: proc(ctx: ^Ez_Gfx_Ctx) -> u32 {
	if ctx == nil || ctx.texture_decode_worker_count == 0 do return 1
	return ctx.texture_decode_worker_count
}

texture_manager_collect_destroyed :: proc(manager: ^Ez_Gfx_Texture_Manager, ctx: ^Ez_Gfx_Ctx) {
	completed := gpu_heap_completed_timeline()
	sync.mutex_lock(&manager.mutex)
	staging_index := 0
	for staging_index < len(manager.pending_staging) {
		if manager.pending_staging[staging_index].retire_timeline > completed {
			staging_index += 1
			continue
		}
		job := manager.pending_staging[staging_index]
		ordered_remove(&manager.pending_staging, staging_index)
		sync.mutex_unlock(&manager.mutex)
		buffer_destroy(&job.buffer)
		sync.mutex_lock(&manager.mutex)
	}
	i := 0
	for i < len(manager.pending_destroys) {
		if manager.pending_destroys[i].retire_timeline > completed {
			i += 1
			continue
		}
		job := manager.pending_destroys[i]
		ordered_remove(&manager.pending_destroys, i)
		sync.mutex_unlock(&manager.mutex)
		texture_record_destroy(ctx, &job.record)
		sync.mutex_lock(&manager.mutex)
	}
	sync.mutex_unlock(&manager.mutex)
}

texture_prepare_desc :: proc(desc: Ez_Gfx_Load_Texture_Desc) -> Ez_Gfx_Load_Texture_Desc {
	desc := desc
	if desc.destination_format == {} do desc.destination_format = .R8G8B8A8_UNORM
	if desc.mip_count == 0 do desc.mip_count = 1
	if desc.generate_mips && desc.mip_count == 1 && desc.width > 0 && desc.height > 0 {
		desc.mip_count = texture_full_mip_count(desc.width, desc.height)
	}
	if desc.min_filter == {} do desc.min_filter = .Linear
	if desc.mag_filter == {} do desc.mag_filter = .Linear
	if desc.address_mode_u == {} do desc.address_mode_u = .Repeat
	if desc.address_mode_v == {} do desc.address_mode_v = .Repeat
	if desc.address_mode_w == {} do desc.address_mode_w = .Repeat
	return desc
}

texture_full_mip_count :: proc(width, height: u32) -> u32 {
	levels: u32 = 1
	size := max(width, height)
	for size > 1 {
		size /= 2
		levels += 1
	}
	return levels
}

texture_filter_to_vk :: proc(filter: Ez_Gfx_Texture_Filter) -> vk.Filter {
	if filter == .Nearest do return .NEAREST
	return .LINEAR
}

texture_address_mode_to_vk :: proc(mode: Ez_Gfx_Texture_Address_Mode) -> vk.SamplerAddressMode {
	if mode == .Clamp_To_Edge do return .CLAMP_TO_EDGE
	return .REPEAT
}

texture_destination_format_to_vk :: proc(format: Ez_Gfx_Texture_Destination_Format) -> vk.Format {
	switch format {
	case .R8G8B8A8_UNORM:
		return .R8G8B8A8_UNORM
	}
	panic("invalid texture destination format")
}

texture_copy_debug_label :: proc(record: ^Ez_Gfx_Texture_Record, label: string) {
	record.debug_label = {}
	record.debug_label_len = min(len(label), EZ_GFX_TEXTURE_DEBUG_LABEL_MAX)
	for i in 0 ..< record.debug_label_len {
		record.debug_label[i] = label[i]
	}
}

texture_manager_alloc_slot :: proc(
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

texture_manager_find_locked :: proc(
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
