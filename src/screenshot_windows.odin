#+build windows

package main

import "core:fmt"
import "core:os"
import win32 "core:sys/windows"
import "vendor:glfw"

SCREENSHOT_PATH :: "screenshot.bmp"

// Saves the visible window contents to a BMP file for automated verification.
ez_gfx_screenshot_save_window :: proc(window: ^Ez_Gfx_Window, path: string) -> bool {
	hwnd := glfw.GetWin32Window(window.handle)
	if hwnd == nil {
		fmt.eprintln("failed to get Win32 window handle")
		return false
	}

	width, height := glfw.GetFramebufferSize(window.handle)
	if width <= 0 || height <= 0 {
		fmt.eprintln("screenshot skipped: invalid framebuffer size")
		return false
	}

	window_dc := win32.GetDC(hwnd)
	if window_dc == nil {
		fmt.eprintln("failed to get window device context")
		return false
	}
	defer win32.ReleaseDC(hwnd, window_dc)

	memory_dc := win32.CreateCompatibleDC(window_dc)
	if memory_dc == nil {
		fmt.eprintln("failed to create compatible device context")
		return false
	}
	defer win32.DeleteDC(memory_dc)

	bitmap := win32.CreateCompatibleBitmap(window_dc, width, height)
	if bitmap == nil {
		fmt.eprintln("failed to create compatible bitmap")
		return false
	}
	defer win32.DeleteObject(win32.HGDIOBJ(bitmap))

	old_bitmap := win32.SelectObject(memory_dc, win32.HGDIOBJ(bitmap))
	defer win32.SelectObject(memory_dc, old_bitmap)

	if !win32.BitBlt(memory_dc, 0, 0, width, height, window_dc, 0, 0, win32.SRCCOPY) {
		fmt.eprintln("failed to copy window pixels")
		return false
	}

	row_stride := ((width * 3) + 3) / 4 * 4
	pixel_data_size := row_stride * height
	pixels, alloc_err := make([]u8, pixel_data_size, context.temp_allocator)
	if alloc_err != nil {
		fmt.eprintf("failed to allocate screenshot buffer: %v\n", alloc_err)
		return false
	}

	info := win32.BITMAPINFOHEADER {
		biSize        = u32(size_of(win32.BITMAPINFOHEADER)),
		biWidth       = width,
		biHeight      = -height,
		biPlanes      = 1,
		biBitCount    = 24,
		biCompression = win32.BI_RGB,
	}

	if win32.GetDIBits(
		   memory_dc,
		   bitmap,
		   0,
		   u32(height),
		   raw_data(pixels),
		   &win32.BITMAPINFO{bmiHeader = info},
		   win32.DIB_RGB_COLORS,
	   ) ==
	   0 {
		fmt.eprintln("failed to read window pixels")
		return false
	}

	return ez_gfx_write_bmp_rgb(path, int(width), int(height), int(row_stride), pixels)
}

ez_gfx_write_bmp_rgb :: proc(path: string, width, height, row_stride: int, rgb: []u8) -> bool {
	file_size := 54 + len(rgb)

	file, err := os.open(path, {.Write, .Create, .Trunc}, os.perm_number(0o644))
	if err != nil {
		fmt.eprintf("failed to open screenshot file %v: %v\n", path, err)
		return false
	}
	defer os.close(file)

	header := [54]u8{}
	header[0] = 'B'
	header[1] = 'M'
	put_u32(&header[2], u32(file_size))
	put_u32(&header[10], 54)
	put_u32(&header[14], 40)
	put_u32(&header[18], u32(width))
	put_i32(&header[22], i32(height))
	put_u16(&header[26], 1)
	put_u16(&header[28], 24)
	if _, write_err := os.write(file, header[:]); write_err != nil {
		fmt.eprintf("failed to write BMP header: %v\n", write_err)
		return false
	}

	for y in 0 ..< height {
		row := rgb[y * row_stride:(y + 1) * row_stride]
		if _, write_err := os.write(file, row[:width * 3]); write_err != nil {
			fmt.eprintf("failed to write BMP row: %v\n", write_err)
			return false
		}
		padding := row_stride - width * 3
		if padding > 0 {
			pad := [3]u8{}
			if _, write_err := os.write(file, pad[:padding]); write_err != nil {
				fmt.eprintf("failed to write BMP row padding: %v\n", write_err)
				return false
			}
		}
	}

	fmt.printf("saved screenshot to %v\n", path)
	return true
}

put_u16 :: proc(dst: [^]u8, value: u16) {
	dst[0] = u8(value)
	dst[1] = u8(value >> 8)
}

put_u32 :: proc(dst: [^]u8, value: u32) {
	dst[0] = u8(value)
	dst[1] = u8(value >> 8)
	dst[2] = u8(value >> 16)
	dst[3] = u8(value >> 24)
}

put_i32 :: proc(dst: [^]u8, value: i32) {
	put_u32(dst, u32(value))
}
