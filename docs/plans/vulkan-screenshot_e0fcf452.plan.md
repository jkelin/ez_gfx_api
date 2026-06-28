---
name: vulkan-screenshot
overview: Replace the platform-specific screenshot path with a Vulkan swapchain readback that saves PNG/JPEG output from `Ez_Gfx_Window` using the existing render context and buffer helpers.
todos:
  - id: swapchain-readback-state
    content: Add transfer-source swapchain usage and last-presented image tracking.
    status: completed
  - id: render-present-index
    content: Record the successfully presented image index in the swapchain.
    status: completed
  - id: universal-screenshot
    content: Implement Vulkan image-to-buffer screenshot readback in `src/screenshot.odin`.
    status: completed
  - id: image-encoding
    content: Encode PNG/JPEG from readback pixels using Odin image writer APIs.
    status: completed
  - id: cleanup-verify
    content: Remove platform screenshot file/TODO and verify with `just build` and `just run`.
    status: completed
isProject: false
---

# Vulkan Screenshot Implementation

## Scope

Implement the TODO in [`TODO.md`](TODO.md): replace [`src/screenshot_windows.odin`](src/screenshot_windows.odin) and the non-Windows stub in [`src/screenshot.odin`](src/screenshot.odin) with one universal Vulkan screenshot path.

The public API remains:

```odin
ez_gfx_screenshot_save_window :: proc(window: ^Ez_Gfx_Window, path: string) -> bool
```

Default screenshot output changes from `screenshot.bmp` to `screenshot.png`, while `.png`, `.jpg`, and `.jpeg` paths are encoded based on extension. BMP support will not be retained unless it is needed for compatibility, because the TODO asks for PNG/JPEG and removal of the platform capture path.

## Implementation Plan

1. Update swapchain state in [`src/swapchain.odin`](src/swapchain.odin):
   - Add `last_presented_index` and `has_presented_image` to `Ez_Gfx_Swapchain`.
   - Create swapchain images with `vk.ImageUsageFlags{.COLOR_ATTACHMENT, .TRANSFER_SRC}` so Vulkan image-to-buffer copy is legal.
   - Reset screenshot tracking fields when destroying/recreating the swapchain.

2. Persist the screenshot source image in [`src/render.odin`](src/render.odin):
   - After successful `vk.QueuePresentKHR`, store `render.image_index` as the last presented image.
   - Leave existing image layout tracking intact; screenshot will read from the image currently tracked as `.PRESENT_SRC_KHR`.

3. Replace the screenshot modules:
   - Remove build tags/platform-specific imports from [`src/screenshot.odin`](src/screenshot.odin).
   - Delete [`src/screenshot_windows.odin`](src/screenshot_windows.odin) after moving any still-useful helper logic, or leave it empty only if Odin package rules require it. Prefer deletion.
   - Implement Vulkan readback using the current context, `Ez_Gfx_Window.swapchain`, `ez_gfx_buffer_create`, and `ez_gfx_transition_image`.

4. Vulkan readback flow:
   - Require a valid current context, initialized swapchain, and a successfully presented image.
   - Create a host-visible, host-coherent staging buffer with `.TRANSFER_DST` usage sized as `width * height * 4`.
   - Wait idle, reset the existing command buffer, record a one-time command buffer that transitions the swapchain image from its tracked layout to `.TRANSFER_SRC_OPTIMAL`, calls `vk.CmdCopyImageToBuffer`, then transitions it back to `.PRESENT_SRC_KHR`.
   - Submit on `ctx.graphics_queue`, wait on `ctx.in_flight`, map staging memory, and copy pixels into a temporary CPU slice.

5. Encode output:
   - Convert swapchain BGRA pixels to RGBA for PNG and RGB for JPEG.
   - Use Odin's `vendor:stb/image` writer functions if available in the local Odin distribution.
   - If the local `vendor:stb/image` API differs, adapt to the installed API rather than adding a new dependency.
   - Print clear errors for unsupported extensions and failed writes.

6. Update example/config artifacts:
   - Change `SCREENSHOT_PATH` to `screenshot.png`.
   - Update [`.gitignore`](.gitignore) to ignore `screenshot.jpg` / `screenshot.jpeg` if needed.
   - Remove the completed TODO from [`TODO.md`](TODO.md) after implementation succeeds.

## Verification

Use the repo's Justfile commands from the workspace root:

```powershell
just build
just run
```

Expected result: `just run` builds and runs the triangle example, `EZ_GFX_SCREENSHOT=1` saves `screenshot.png`, and the captured image contains the rendered triangle rather than a compositor/window capture. If local Vulkan or display access prevents `just run`, report the exact failure and still ensure `just build` passes.
