#+test
#+private
package ez_gfx

import "core:testing"
import vk "vendor:vulkan"

TEXTURE_DECODER_TEST_PNG :: #load("../examples/2_textured_cube/ez_graphics_api_texture.png")

texture_test_decoder :: proc(
	job: ^Ez_Gfx_Texture_Load_Job,
) -> Ez_Gfx_Texture_Upload_Job {
	pixels := make([]u8, 4)
	pixels[0] = 1
	pixels[1] = 2
	pixels[2] = 3
	pixels[3] = 4
	return Ez_Gfx_Texture_Upload_Job{
		load = job^,
		pixels = pixels,
		width = 1,
		height = 1,
		source = .RGBA,
		owns_pixels = true,
		err = .None,
	}
}


texture_test_job :: proc(
	data: []u8,
	format: Ez_Gfx_Source_Texture_Format,
	width, height: u32,
) -> Ez_Gfx_Texture_Load_Job {
	job: Ez_Gfx_Texture_Load_Job
	job.desc = {
		source_format = format,
		destination_format = .R8G8B8A8_UNORM,
		width = width,
		height = height,
		mip_count = 1,
	}
	job.regions = make([dynamic]Ez_Gfx_Texture_Memory_Region)
	append(&job.regions, Ez_Gfx_Texture_Memory_Region{data = data})
	return job
}

texture_test_job_destroy :: proc(job: ^Ez_Gfx_Texture_Load_Job) {
	delete(job.regions)
	job^ = {}
}

@(test)
texture_unregistered_png_rejects_before_workers :: proc(t: ^testing.T) {
	if !testing.expect(t, api_register_image_decoder(.PNG, nil) == .Ok) {
		return
	}
	defer api_enable_png_decoder()
	data := [?]u8{137}
	region := Ez_Gfx_Texture_Memory_Region{data = data[:]}
	manager: Ez_Gfx_Texture_Manager
	ctx: Ez_Gfx_Ctx
	_, err := api_texture_manager_load(
		&manager,
		&ctx,
		[]Ez_Gfx_Texture_Memory_Region{region},
		{source_format = .PNG},
	)

	testing.expect_value(t, err, Ez_Gfx_Texture_Error.Unsupported_Format)
	testing.expect_value(t, manager.latest_scheduled_texture_timeline, u64(0))
}


@(test)
texture_registers_custom_image_decoder :: proc(t: ^testing.T) {
	if !testing.expect(t, api_register_image_decoder(.BMP, texture_test_decoder) == .Ok) {
		return
	}
	defer api_enable_bmp_decoder()
	testing.expect(t, api_register_image_decoder(.RGB, texture_test_decoder) != .Ok)
	testing.expect(t, api_register_image_decoder(.BMP, nil) == .Ok)
	testing.expect(t, api_register_image_decoder(.BMP, texture_test_decoder) == .Ok)

	data := [?]u8{0}
	job := texture_test_job(data[:], .BMP, 0, 0)
	defer texture_test_job_destroy(&job)
	upload := api_texture_decode_upload_job(&job)
	defer api_texture_upload_job_destroy(&upload)

	if !testing.expect_value(t, upload.err, Ez_Gfx_Texture_Error.None) {
		return
	}
	testing.expect_value(t, upload.width, u32(1))
	testing.expect_value(t, upload.height, u32(1))
	testing.expect_value(t, upload.pixels[3], u8(4))
}

@(test)
texture_enable_all_decoders_enables_png :: proc(t: ^testing.T) {
	if !testing.expect(t, api_enable_all_decoders() == .Ok) {
		return
	}

	job := texture_test_job(TEXTURE_DECODER_TEST_PNG, .PNG, 0, 0)
	defer texture_test_job_destroy(&job)
	upload := api_texture_decode_upload_job(&job)
	defer api_texture_upload_job_destroy(&upload)

	if !testing.expect_value(t, upload.err, Ez_Gfx_Texture_Error.None) {
		return
	}
	testing.expect(t, upload.width > 0 && upload.height > 0)
	testing.expect_value(t, upload.source, Ez_Gfx_Texture_Decoded_Source.RGBA)
	testing.expect(t, upload.owns_pixels)
}

@(test)
texture_full_mip_count_halves_to_one_pixel :: proc(t: ^testing.T) {
	testing.expect_value(t, api_texture_full_mip_count(1024, 1024), u32(11))
	testing.expect_value(t, api_texture_full_mip_count(7, 3), u32(3))
	testing.expect_value(t, api_texture_full_mip_count(1, 1), u32(1))
}

@(test)
texture_decode_raw_rgb_expands_alpha :: proc(t: ^testing.T) {
	data := [?]u8{10, 20, 30, 40, 50, 60}
	job := texture_test_job(data[:], .RGB, 2, 1)
	defer texture_test_job_destroy(&job)

	pixels: []u8
	width, height: u32
	err := api_texture_decode_job(&job, &pixels, &width, &height)
	defer delete(pixels)

	testing.expect_value(t, err, Ez_Gfx_Texture_Error.None)
	testing.expect_value(t, width, u32(2))
	testing.expect_value(t, height, u32(1))
	testing.expect_value(t, pixels[0], u8(10))
	testing.expect_value(t, pixels[1], u8(20))
	testing.expect_value(t, pixels[2], u8(30))
	testing.expect_value(t, pixels[3], u8(255))
	testing.expect_value(t, pixels[7], u8(255))
}

@(test)
texture_decode_raw_rgba_preserves_alpha :: proc(t: ^testing.T) {
	data := [?]u8{10, 20, 30, 40}
	job := texture_test_job(data[:], .RGBA, 1, 1)
	defer texture_test_job_destroy(&job)

	pixels: []u8
	width, height: u32
	err := api_texture_decode_job(&job, &pixels, &width, &height)
	defer delete(pixels)

	testing.expect_value(t, err, Ez_Gfx_Texture_Error.None)
	testing.expect_value(t, width, u32(1))
	testing.expect_value(t, height, u32(1))
	testing.expect_value(t, pixels[0], u8(10))
	testing.expect_value(t, pixels[1], u8(20))
	testing.expect_value(t, pixels[2], u8(30))
	testing.expect_value(t, pixels[3], u8(40))
}

@(test)
texture_decode_raw_rejects_wrong_byte_count :: proc(t: ^testing.T) {
	data := [?]u8{10, 20, 30}
	job := texture_test_job(data[:], .RGBA, 1, 1)
	defer texture_test_job_destroy(&job)

	pixels: []u8
	width, height: u32
	err := api_texture_decode_job(&job, &pixels, &width, &height)

	testing.expect_value(t, err, Ez_Gfx_Texture_Error.Invalid_Arguments)
	testing.expect_value(t, len(pixels), 0)
	testing.expect_value(t, width, u32(0))
	testing.expect_value(t, height, u32(0))
}

@(test)
texture_decode_upload_job_reuses_raw_rgba_region :: proc(t: ^testing.T) {
	data := [?]u8{10, 20, 30, 40}
	job := texture_test_job(data[:], .RGBA, 1, 1)

	upload := api_texture_decode_upload_job(&job)
	defer api_texture_upload_job_destroy(&upload)

	testing.expect_value(t, upload.err, Ez_Gfx_Texture_Error.None)
	testing.expect_value(t, upload.source, Ez_Gfx_Texture_Decoded_Source.RGBA)
	testing.expect(t, !upload.owns_pixels)
	testing.expect(t, raw_data(upload.pixels) == raw_data(data[:]))
	testing.expect_value(t, api_texture_staging_size(&upload), vk.DeviceSize(4))
}

@(test)
texture_decode_upload_job_keeps_raw_rgb_for_staging_expand :: proc(t: ^testing.T) {
	data := [?]u8{10, 20, 30, 40, 50, 60}
	job := texture_test_job(data[:], .RGB, 2, 1)

	upload := api_texture_decode_upload_job(&job)
	defer api_texture_upload_job_destroy(&upload)

	testing.expect_value(t, upload.err, Ez_Gfx_Texture_Error.None)
	testing.expect_value(t, upload.source, Ez_Gfx_Texture_Decoded_Source.RGB)
	testing.expect(t, !upload.owns_pixels)
	testing.expect(t, raw_data(upload.pixels) == raw_data(data[:]))
	testing.expect_value(t, api_texture_staging_size(&upload), vk.DeviceSize(8))
}

@(test)
texture_manager_allocates_and_finds_id_slots :: proc(t: ^testing.T) {
	manager: Ez_Gfx_Texture_Manager
	slot, slot_index := api_texture_manager_alloc_slot(&manager)
	if !testing.expect(t, slot != nil) {
		return
	}
	testing.expect_value(t, slot_index, u32(0))

	slot.id = Ez_Gfx_Texture_ID(slot_index)
	slot.state = .Queued

	found := api_texture_manager_find_locked(&manager, Ez_Gfx_Texture_ID(slot_index))
	missing := api_texture_manager_find_locked(&manager, Ez_Gfx_Texture_ID(7))
	testing.expect(t, found == slot)
	testing.expect(t, missing == nil)
}

