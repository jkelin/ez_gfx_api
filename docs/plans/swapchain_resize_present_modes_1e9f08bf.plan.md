---
name: swapchain resize
overview: Fix Vulkan swapchain resize handling so stale acquired images are not used or destroyed unsafely, then expose and test user-selectable swapchain present modes.
todos:
  - id: reproduce-resize-test
    content: Add an Odin resize regression test that captures the current validation failure.
    status: pending
  - id: fix-recreate-lifetime
    content: Update swapchain recreation and screenshot image handling to avoid stale acquired image use.
    status: pending
  - id: present-mode-api
    content: Expose supported present-mode query and selected present-mode setter on the context/swapchain path.
    status: pending
  - id: present-mode-tests
    content: Add pure and integration tests for present-mode query/selection/recreate behavior.
    status: pending
  - id: verify-just-test
    content: Run `just test` and fix any failures without disabling tests.
    status: pending
isProject: true
---

# Swapchain Resize And Present Modes

## Context

Current swapchain creation in [src/swapchain.odin](../../src/swapchain.odin) destroys the old swapchain before creating the replacement and hard-codes `presentMode = .FIFO`. Render presentation in [src/render.odin](../../src/render.odin) recreates after `VK_ERROR_OUT_OF_DATE_KHR`, `VK_SUBOPTIMAL_KHR`, or a framebuffer resize flag. Current present semaphores are already indexed by swapchain image, which matches the newer Vulkan validation guidance.

The likely resize validation failure is stale swapchain image ownership during recreation. [src/screenshot.odin](../../src/screenshot.odin) is especially suspicious because it acquires a swapchain image for screenshot readback, transitions/copies it, but never presents or otherwise releases that acquired image before future resize/recreate.

## Plan

1. Reproduce the issue with an Odin `@(test)` under [tests/](../../tests/), reusing the existing validation callback and triangle app helpers from [tests/triangle.odin](../../tests/triangle.odin). The test will draw at least one frame, trigger a resize/recreate path, and assert validation error counts stay at zero once fixed.

2. Fix swapchain resize/resource lifetime in [src/swapchain.odin](../../src/swapchain.odin), [src/window.odin](../../src/window.odin), and any affected call sites:
   - Use Vulkan's `oldSwapchain` field when creating a replacement swapchain so the old one is retired atomically.
   - Keep old image views, present semaphores, and the retired swapchain handle alive until explicit swapchain replacement can safely destroy them.
   - Do not add `vkQueueWaitIdle` or `vkDeviceWaitIdle` to normal frame rendering, screenshot/readback, acquire, submit, or present paths. Blocking idle waits are allowed only during explicit swapchain changes and shutdown.
   - Preserve existing render-target cache clearing on resize, because descriptors and image views are swapchain-size dependent.

3. Fix the screenshot-acquire path in [src/screenshot.odin](../../src/screenshot.odin) so it does not leave an acquired swapchain image outstanding. The conservative fix is to read the last presented image without acquiring a fresh swapchain image, using `last_presented_index` and existing timeline waits, or to explicitly present/release if that proves necessary during implementation.

4. Add present-mode APIs during context/swapchain initialization:
   - `ez_gfx_ctx_get_swapchain_present_modes(surface, modes_out)` or equivalent, querying `vk.GetPhysicalDeviceSurfacePresentModesKHR`.
   - `ez_gfx_ctx_set_swapchain_present_mode(mode)` or equivalent, validating the selected mode against the current surface-supported modes and falling back to `.FIFO` when unsupported.
   - Store the selected mode in `Ez_Gfx_Ctx` and use it in swapchain creation instead of the current `.FIFO` hard-code.

5. Add tests:
   - A pure selector test for FIFO fallback and supported-mode selection.
   - An integration test that queries present modes after context/device init, sets a supported mode, recreates the swapchain, and verifies no validation errors.
   - The resize reproduction test from step 1 remains as a regression test.

6. Verify with the project command from the Justfile: `just test`.

## Notes From Vulkan Guidance

Modern Vulkan resize handling should treat `VK_ERROR_OUT_OF_DATE_KHR` from acquire/present as requiring swapchain recreation and `VK_SUBOPTIMAL_KHR` as a recreate-at-next-opportunity signal. `oldSwapchain` should be passed during replacement when retaining or retiring the old swapchain, and present wait semaphores should be tracked by swapchain image index rather than frame index. This repo already does the image-indexed present semaphore part.
