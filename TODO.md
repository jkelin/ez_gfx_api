# TODO

- Replace `screenshot_windows.odin` with a universal screenshot path that takes a window struct, reads back the swapchain image through the Vulkan API, and writes PNG or JPEG output using Odin (no platform-specific GDI/Win32 capture).

- Refactor the swapchain to use timeline semaphores and support multiple frames in flight instead of the current single-fence, single-command-buffer design.

- Update the vertex manager heap allocator so it reuses freed memory instead of acting as a bump allocator that only appends new allocations.

- Expand the pipeline cache key to include topology, blend, depth, and rasterization options instead of only shader identity and color format.

- Audit `odin-slang` object ownership in shader compilation so session/module/component objects can be released safely without causing heap corruption.
