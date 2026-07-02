package tests

import gfx "../src"
import "core:testing"
import vk "vendor:vulkan"

@(test)
timeline_values_are_monotonic :: proc(t: ^testing.T) {
	ctx: gfx.Ez_Gfx_Ctx

	first := gfx.ez_gfx_ctx_next_timeline_value(&ctx)
	second := gfx.ez_gfx_ctx_next_timeline_value(&ctx)

	testing.expect_value(t, first, u64(1))
	testing.expect_value(t, second, u64(2))
}

@(test)
present_mode_selector_uses_requested_mode_when_supported :: proc(t: ^testing.T) {
	modes := [?]vk.PresentModeKHR{.FIFO, .MAILBOX}

	selected := gfx.ez_gfx_swapchain_choose_present_mode(modes[:], .MAILBOX)

	testing.expect_value(t, selected, vk.PresentModeKHR(.MAILBOX))
}

@(test)
present_mode_selector_falls_back_to_fifo_when_unsupported :: proc(t: ^testing.T) {
	modes := [?]vk.PresentModeKHR{.FIFO}

	selected := gfx.ez_gfx_swapchain_choose_present_mode(modes[:], .IMMEDIATE)

	testing.expect_value(t, selected, vk.PresentModeKHR(.FIFO))
}

@(test)
transfer_queue_selector_prefers_dedicated_transfer_family :: proc(t: ^testing.T) {
	queues := [?]vk.QueueFamilyProperties {
		{queueFlags = {.GRAPHICS, .TRANSFER}, queueCount = 1},
		{queueFlags = {.TRANSFER}, queueCount = 1},
	}

	selected := gfx.ez_gfx_ctx_choose_transfer_queue_family(queues[:], 0)

	testing.expect_value(t, selected, u32(1))
}

@(test)
transfer_queue_selector_falls_back_to_graphics_family :: proc(t: ^testing.T) {
	queues := [?]vk.QueueFamilyProperties {
		{queueFlags = {.GRAPHICS, .TRANSFER}, queueCount = 1},
	}

	selected := gfx.ez_gfx_ctx_choose_transfer_queue_family(queues[:], 0)

	testing.expect_value(t, selected, u32(0))
}
