package tests

import gfx "../src"
import "core:testing"

@(test)
texture_full_mip_count_halves_to_one_pixel :: proc(t: ^testing.T) {
	testing.expect_value(t, gfx.ez_gfx_texture_full_mip_count(1024, 1024), u32(11))
	testing.expect_value(t, gfx.ez_gfx_texture_full_mip_count(7, 3), u32(3))
	testing.expect_value(t, gfx.ez_gfx_texture_full_mip_count(1, 1), u32(1))
}

@(test)
texture_decode_raw_rgb_expands_alpha :: proc(t: ^testing.T) {
	data := [?]u8{10, 20, 30, 40, 50, 60}
	job := texture_test_job(data[:], .RGB, 2, 1)
	defer texture_test_job_destroy(&job)

	pixels: []u8
	width, height: u32
	err := gfx.ez_gfx_texture_decode_job(&job, &pixels, &width, &height)
	defer delete(pixels)

	testing.expect_value(t, err, gfx.Ez_Gfx_Texture_Error.None)
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
	err := gfx.ez_gfx_texture_decode_job(&job, &pixels, &width, &height)
	defer delete(pixels)

	testing.expect_value(t, err, gfx.Ez_Gfx_Texture_Error.None)
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
	err := gfx.ez_gfx_texture_decode_job(&job, &pixels, &width, &height)

	testing.expect_value(t, err, gfx.Ez_Gfx_Texture_Error.Invalid_Arguments)
	testing.expect_value(t, len(pixels), 0)
	testing.expect_value(t, width, u32(0))
	testing.expect_value(t, height, u32(0))
}

@(test)
texture_manager_allocates_and_finds_id_slots :: proc(t: ^testing.T) {
	manager: gfx.Ez_Gfx_Texture_Manager
	slot, slot_index := gfx.ez_gfx_texture_manager_alloc_slot(&manager)
	if !testing.expect(t, slot != nil) {
		return
	}
	testing.expect_value(t, slot_index, u32(0))

	slot.id = gfx.Ez_Gfx_Texture_ID(slot_index)
	slot.state = .Queued

	found := gfx.ez_gfx_texture_manager_find_locked(&manager, gfx.Ez_Gfx_Texture_ID(slot_index))
	missing := gfx.ez_gfx_texture_manager_find_locked(&manager, gfx.Ez_Gfx_Texture_ID(7))
	testing.expect(t, found == slot)
	testing.expect(t, missing == nil)
}

texture_test_job :: proc(
	data: []u8,
	format: gfx.Ez_Gfx_Source_Texture_Format,
	width, height: u32,
) -> gfx.Ez_Gfx_Texture_Load_Job {
	job: gfx.Ez_Gfx_Texture_Load_Job
	job.desc = {
		source_format = format,
		destination_format = .R8G8B8A8_UNORM,
		width = width,
		height = height,
		mip_count = 1,
	}
	job.regions = make([dynamic]gfx.Ez_Gfx_Texture_Memory_Region)
	append(&job.regions, gfx.Ez_Gfx_Texture_Memory_Region{data = data})
	return job
}

texture_test_job_destroy :: proc(job: ^gfx.Ez_Gfx_Texture_Load_Job) {
	delete(job.regions)
	job^ = {}
}
