#+private
package ez_gfx

import "core:os"
import "core:strconv"

EZ_GFX_MAX_SECONDS_ENV :: "EZ_GFX_MAX_SECONDS"
EZ_GFX_MAX_FRAMES_ENV :: "EZ_GFX_MAX_FRAMES"
EZ_GFX_HIDDEN_WINDOW_ENV :: "EZ_GFX_HIDDEN_WINDOW"
EZ_GFX_SCREENSHOT_ENV :: "EZ_GFX_SCREENSHOT"

// Maximum run duration in seconds; unset means run until the window is closed.
config_run_seconds :: proc() -> f64 {
	buf: [64]u8
	if value, err := os.lookup_env(buf[:], EZ_GFX_MAX_SECONDS_ENV); err == nil {
		if seconds, parse_ok := strconv.parse_f64(value); parse_ok && seconds > 0 {
			return seconds
		}
		return 2.0
	}
	return -1.0
}

// Maximum number of frames; unset means run until the window is closed or the time limit is reached.
config_max_frames :: proc() -> int {
	buf: [64]u8
	if value, err := os.lookup_env(buf[:], EZ_GFX_MAX_FRAMES_ENV); err == nil {
		if frames, parse_ok := strconv.parse_int(value); parse_ok && frames > 0 {
			return frames
		}
	}
	return -1
}

// Forces the window to stay hidden for deterministic snapshot-based captures.
config_hidden_window :: proc() -> bool {
	buf: [64]u8
	if value, err := os.lookup_env(buf[:], EZ_GFX_HIDDEN_WINDOW_ENV); err == nil {
		switch value {
		case "1", "true", "TRUE", "yes", "YES":
			return true
		}
	}
	return false
}

// Whether to save a screenshot after the run loop finishes.
config_screenshot_enabled :: proc() -> bool {
	buf: [64]u8
	if value, err := os.lookup_env(buf[:], EZ_GFX_SCREENSHOT_ENV); err == nil {
		switch value {
		case "1", "true", "TRUE", "yes", "YES":
			return true
		}
	}
	return false
}
