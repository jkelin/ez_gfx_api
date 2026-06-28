# TODO

- Refactor the swapchain to use timeline semaphores and support multiple frames in flight instead of the current single-fence, single-command-buffer design.

- Update the vertex manager heap allocator so it reuses freed memory instead of acting as a bump allocator that only appends new allocations.

- Expand the pipeline cache key to include topology, blend, depth, and rasterization options instead of only shader identity and color format.

- Audit `odin-slang` object ownership in shader compilation so session/module/component objects can be released safely without causing heap corruption.

- Split graphics pipeline caching from per-frame resource descriptor binding so render target image views can be recreated on resize without leaving cached descriptor sets pointing at stale Vulkan resources.

- Add multi-pass render target scheduling for shaders that write one managed target and later read it from another pipeline, including pass grouping, ordering, and synchronization barriers.

- Decide and document the supported semantics for reading from `swapchain`; supporting it requires additional swapchain usage flags, layout transitions, format checks, and synchronization.

- Model render target declarations as Vulkan format/aspect/usage metadata rather than only a high-level layout string, especially for depth targets that require depth-stencil pipeline state and depth attachment setup.

- Generalize image layout transitions beyond color attachments so managed render targets can transition correctly for sampled, storage, color attachment, and depth attachment usage.

- Keep explicit target attributes as the source of truth for engine render target intent, even when shader resource reflection changes due to compiler optimization.
