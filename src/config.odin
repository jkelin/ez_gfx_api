package ez_gfx

import "core:os"
import "core:strconv"

EZ_GFX_MAX_SECONDS_ENV :: "EZ_GFX_MAX_SECONDS"
EZ_GFX_SCREENSHOT_ENV :: "EZ_GFX_SCREENSHOT"

// Maximum run duration in seconds; unset means run until the window is closed.
ez_gfx_config_run_seconds :: proc() -> f64 {
	buf: [64]u8
	if value, err := os.lookup_env(buf[:], EZ_GFX_MAX_SECONDS_ENV); err == nil {
		if seconds, parse_ok := strconv.parse_f64(value); parse_ok && seconds > 0 {
			return seconds
		}
		return 2.0
	}
	return -1.0
}

// Whether to save a screenshot after the run loop finishes.
ez_gfx_config_screenshot_enabled :: proc() -> bool {
	buf: [64]u8
	if value, err := os.lookup_env(buf[:], EZ_GFX_SCREENSHOT_ENV); err == nil {
		switch value {
		case "1", "true", "TRUE", "yes", "YES":
			return true
		}
	}
	return false
}
