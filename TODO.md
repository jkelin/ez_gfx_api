# TODO

- Replace `screenshot_windows.odin` with a universal screenshot path that takes a window struct, reads back the swapchain image through the Vulkan API, and writes PNG or JPEG output using Odin (no platform-specific GDI/Win32 capture).

- Refactor the swapchain to use timeline semaphores and support multiple frames in flight instead of the current single-fence, single-command-buffer design.
