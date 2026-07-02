package tests

import gfx "../src"
import "core:fmt"
import image "core:image"
import "core:os"
import "core:testing"

SNAPSHOT_DIR :: "tests/snapshots"
SNAPSHOT_CHANNEL_TOLERANCE :: u8(1)

Snapshot_Options :: struct {
	channel_tolerance: u8,
}

expect_window_snapshot :: proc(
	t: ^testing.T,
	window: ^gfx.Ez_Gfx_Window,
	name: string,
	options: Snapshot_Options = {},
) {
	tolerance := options.channel_tolerance
	if tolerance == 0 {
		tolerance = SNAPSHOT_CHANNEL_TOLERANCE
	}

	width := int(window.swapchain.extent.width)
	height := int(window.swapchain.extent.height)
	bgra: []u8
	if !testing.expect(t, gfx.ez_gfx_screenshot_read_swapchain_bgra(&window.swapchain, &bgra)) {
		return
	}
	defer delete(bgra)

	current_path := snapshot_current_path(name)
	defer delete(current_path)
	expected_path := snapshot_expected_path(name)
	defer delete(expected_path)

	if !testing.expect(t, snapshot_ensure_dir(), "failed to create snapshot output directory") {
		return
	}
	testing.expectf(
		t,
		gfx.ez_gfx_screenshot_write_png(current_path, width, height, bgra),
		"failed to write current snapshot: %v",
		current_path,
	)

	rgba, conv_ok := gfx.ez_gfx_screenshot_bgra_to_rgba(bgra, width, height)
	if !testing.expect(t, conv_ok, "failed to convert captured snapshot pixels") {
		return
	}
	defer delete(rgba)

	expected, expected_width, expected_height, loaded := snapshot_load_png_rgba(expected_path)
	if !testing.expectf(
		t,
		loaded,
		"missing or invalid expected snapshot: %v; compare %v and copy it to .expected.png after approving it",
		expected_path,
		current_path,
	) {
		return
	}
	defer delete(expected)

	if !testing.expectf(
		t,
		expected_width == width && expected_height == height,
		"snapshot size mismatch for %v: expected %dx%d current %dx%d",
		name,
		expected_width,
		expected_height,
		width,
		height,
	) {
		return
	}

	diff := snapshot_compare_rgba(expected, rgba, width, height, tolerance)
	testing.expectf(
		t,
		diff.different_pixels == 0,
		"snapshot mismatch for %v: %d pixels differ, max delta %d at (%d,%d) channel %d; expected=%v current=%v",
		name,
		diff.different_pixels,
		diff.max_delta,
		diff.max_x,
		diff.max_y,
		diff.max_channel,
		expected_path,
		current_path,
	)
}

Snapshot_Diff :: struct {
	different_pixels: int,
	max_delta:        int,
	max_x:            int,
	max_y:            int,
	max_channel:      int,
}

snapshot_compare_rgba :: proc(expected, current: []u8, width, height: int, tolerance: u8) -> Snapshot_Diff {
	diff: Snapshot_Diff
	pixel_count := width * height
	for pixel in 0 ..< pixel_count {
		pixel_diff := false
		for channel in 0 ..< 4 {
			index := pixel * 4 + channel
			delta := abs(int(expected[index]) - int(current[index]))
			if delta > int(tolerance) {
				pixel_diff = true
			}
			if delta > diff.max_delta {
				diff.max_delta = delta
				diff.max_x = pixel % width
				diff.max_y = pixel / width
				diff.max_channel = channel
			}
		}
		if pixel_diff {
			diff.different_pixels += 1
		}
	}
	return diff
}

snapshot_load_png_rgba :: proc(path: string) -> (
	pixels: []u8,
	width: int,
	height: int,
	ok: bool,
) {
	bytes, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return nil, 0, 0, false
	}
	defer delete(bytes)

	img, img_err := image.load_from_bytes(bytes, {.alpha_add_if_missing})
	if img_err != nil || img == nil {
		return nil, 0, 0, false
	}
	defer image.destroy(img)
	if img.width <= 0 || img.height <= 0 || img.depth != 8 || img.channels != 4 {
		return nil, 0, 0, false
	}

	decoded, alloc_err := make([]u8, img.width * img.height * 4)
	if alloc_err != nil {
		return nil, 0, 0, false
	}
	for i in 0 ..< len(decoded) {
		decoded[i] = img.pixels.buf[i]
	}
	return decoded, img.width, img.height, true
}

snapshot_ensure_dir :: proc() -> bool {
	if os.exists(SNAPSHOT_DIR) {
		return true
	}
	return os.make_directory(SNAPSHOT_DIR) == nil
}

snapshot_expected_path :: proc(name: string) -> string {
	return snapshot_path(name, ".expected.png")
}

snapshot_current_path :: proc(name: string) -> string {
	return snapshot_path(name, ".current.png")
}

snapshot_path :: proc(name, suffix: string) -> string {
	separator := "/"
	size := len(SNAPSHOT_DIR) + len(separator) + len(name) + len(suffix)
	bytes, alloc_err := make([]byte, size)
	if alloc_err != nil {
		return ""
	}
	offset := 0
	for value in SNAPSHOT_DIR {
		bytes[offset] = byte(value)
		offset += 1
	}
	for value in separator {
		bytes[offset] = byte(value)
		offset += 1
	}
	for value in name {
		bytes[offset] = byte(value)
		offset += 1
	}
	for value in suffix {
		bytes[offset] = byte(value)
		offset += 1
	}
	return string(bytes)
}
