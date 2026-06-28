#+build !windows

package main

import "core:fmt"

SCREENSHOT_PATH :: "screenshot.bmp"

// Saves the visible window contents to a BMP file for automated verification.
ez_gfx_screenshot_save_window :: proc(window: ^Ez_Gfx_Window, path: string) -> bool {
	fmt.eprintln("screenshot skipped: platform capture is only implemented on Windows")
	_ = window
	_ = path
	return false
}
