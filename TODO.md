# TODO

- Update the vertex manager heap allocator so it reuses freed memory instead of acting as a bump allocator that only appends new allocations.

- Expand the pipeline cache key to include topology, blend, and rasterization options instead of only shader identity, color formats, and depth format.

- Audit `odin-slang` object ownership in shader compilation so session/module/component objects can be released safely without causing heap corruption.

- Split graphics pipeline caching from per-frame resource descriptor binding so render target image views can be recreated on resize without leaving cached descriptor sets pointing at stale Vulkan resources.

- Coalesce compatible render graph nodes into larger passes when no resource dependency requires a barrier between them.

- Replace host-side waits for managed render target timeline dependencies with queue-side timeline waits so independent frame work can overlap more effectively.

- Decide and document the supported semantics for reading from `swapchain`; supporting it requires additional swapchain usage flags, layout transitions, format checks, and synchronization.

- Model render target declarations with richer Vulkan usage metadata instead of deriving usage only from color/depth kind.

- Add explicit storage-image render target semantics when shaders need writable image resources outside attachment writes.

- Keep explicit target attributes as the source of truth for engine render target intent, even when shader resource reflection changes due to compiler optimization.

- Transfer queue for uploading textures and vertex data, including proper synchronization

- Streamed texture upload

- Support for compressed texture formats

- Precompiled shader modules including reflection metadata to enable not shipping slang/original source code

- Shader cache using precompiled shader modules
