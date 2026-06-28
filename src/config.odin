package main

import "core:os"
import "core:strconv"

EZ_GFX_MAX_SECONDS_ENV :: "EZ_GFX_MAX_SECONDS"
EZ_GFX_SCREENSHOT_ENV :: "EZ_GFX_SCREENSHOT"

// Maximum run duration in seconds; defaults to 2 when the env var is unset or invalid.
ez_gfx_config_run_seconds :: proc() -> f64 {
	if value, ok := os.lookup_env_alloc(EZ_GFX_MAX_SECONDS_ENV, context.temp_allocator); ok {
		if seconds, parse_ok := strconv.parse_f64(value); parse_ok && seconds > 0 {
			return seconds
		}
	}
	return 2.0
}

// Whether to save a screenshot after the run loop finishes.
ez_gfx_config_screenshot_enabled :: proc() -> bool {
	if value, ok := os.lookup_env_alloc(EZ_GFX_SCREENSHOT_ENV, context.temp_allocator); ok {
		switch value {
		case "1", "true", "TRUE", "yes", "YES":
			return true
		}
	}
	return false
}
