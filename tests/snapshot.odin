#+private
package tests

import shared "../examples/shared"
import gfx "../src"
import image "core:image"
import "core:os"
import "core:strings"
import "core:testing"

SNAPSHOT_DIR :: "tests/snapshots"
SNAPSHOT_CHANNEL_TOLERANCE :: u8(1)

Snapshot_Options :: struct {
	channel_tolerance: u8,
}

expect_window_snapshot :: proc(
	t: ^testing.T,
	window: ^shared.Example_Window,
	name: string,
	options: Snapshot_Options = {},
) {
	tolerance := options.channel_tolerance
	if tolerance == 0 {
		tolerance = SNAPSHOT_CHANNEL_TOLERANCE
	}

	current_path := snapshot_current_path(name)
	defer delete(current_path)
	expected_path := snapshot_expected_path(name)
	current_path_c, current_path_error := strings.clone_to_cstring(current_path, context.temp_allocator)
	if !testing.expect(t, current_path_error == nil, "failed to prepare NUL-terminated snapshot path") {
		return
	}
	defer delete(expected_path)

	if !testing.expect(t, snapshot_ensure_dir(), "failed to create snapshot output directory") {
		return
	}
	if !testing.expectf(
		t,
		gfx.ez_gfx_screenshot_save(window.ctx, window.surface, current_path_c) == .Ok,
		"failed to write current snapshot: %v",
		current_path,
	) {
		return
	}

	current, width, height, current_loaded := snapshot_load_png_rgba(current_path)
	if !testing.expectf(t, current_loaded, "missing or invalid current snapshot: %v", current_path) {
		return
	}
	defer delete(current)

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

	diff := snapshot_compare_rgba(expected, current, width, height, tolerance)
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
	if img_err != nil {
		return nil, 0, 0, false
	}
	defer image.destroy(img)
	if img.width <= 0 || img.height <= 0 || len(img.pixels.buf) != img.width * img.height * 4 {
		return nil, 0, 0, false
	}
	pixels = make([]u8, len(img.pixels.buf))
	copy(pixels, img.pixels.buf[:])
	return pixels, img.width, img.height, true
}

snapshot_current_path :: proc(name: string) -> string {
	return snapshot_path(name, "current")
}

snapshot_expected_path :: proc(name: string) -> string {
	return snapshot_path(name, "expected")
}

snapshot_path :: proc(name, suffix: string) -> string {
	file_name := strings.concatenate({name, ".", suffix, ".png"})
	defer delete(file_name)
	path, err := os.join_path({SNAPSHOT_DIR, file_name}, context.allocator)
	if err != nil do return ""
	return path
}

snapshot_ensure_dir :: proc() -> bool {
	if os.is_dir(SNAPSHOT_DIR) do return true
	err := os.make_directory(SNAPSHOT_DIR)
	return err == nil || os.is_dir(SNAPSHOT_DIR)
}
