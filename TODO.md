# TODO

- Refactor the swapchain to use timeline semaphores and support multiple frames in flight instead of the current single-fence, single-command-buffer design.

- Update the vertex manager heap allocator so it reuses freed memory instead of acting as a bump allocator that only appends new allocations.

- Expand the pipeline cache key to include topology, blend, depth, and rasterization options instead of only shader identity and color format.

- Audit `odin-slang` object ownership in shader compilation so session/module/component objects can be released safely without causing heap corruption.
