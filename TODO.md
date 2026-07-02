# TODO

- Decouple graphics pipeline caching from descriptor set/pool ownership. `Ez_Gfx_Pipeline_Record` still owns both `VkPipeline` and descriptor resources; `render_target_manager.version` mitigates stale render-target image views on resize, but vertex heap rebinding and per-frame descriptor lifetimes are still tied to cached pipeline records.

- Expand the pipeline cache key to include topology, blend, and rasterization options instead of only shader identity, color formats, and depth format. The current Vulkan pipeline state is hardcoded, so this is not a live bug yet, but the cache will return incompatible pipelines as soon as those states become configurable.

- Support arbitrary sampled and writable access to managed render targets. The renderer supports attachment writes, declaration-based sampled reads, and managed storage-image writes, but still rejects attachment feedback/read-write color targets and lacks a fully general hazard model. The swapchain is intentionally shader write-only through `ColorTarget("swapchain", "write")`; shader reads from the swapchain are not supported.

- Expand explicit storage-image render target semantics beyond the first managed `RWTexture2D` path. Color render targets can now be bound as storage images, but the graph still treats storage declarations as conservative read/write accesses and needs richer per-stage/per-access hazard metadata.

- Document and enforce that explicit target attributes are the source of truth for engine render target intent, even when shader resource reflection changes due to compiler optimization. Declarations currently drive lifetime/format/load behavior, but graph scheduling still mixes declaration-derived reads with reflected color/depth writes.

- Document the swapchain shader policy in public-facing docs: `swapchain` is a presentation target and is shader write-only. Readback remains available through transfer-based screenshots, not shader resource reads.

- Add broader render target pixel snapshot coverage for more graph shapes. `LoadTarget` history and managed storage-image store/load now have snapshot tests, but fork/join and scaled-target render areas still need pixel assertions.

- Choose depth/stencil formats from device-supported candidates and prefer D24/D16 where the extra D32 precision is not required. Depth target parsing currently maps `d32_float` to a hardcoded `D24_UNORM_S8_UINT`, and the renderer still does not query `vkGetPhysicalDeviceFormatProperties` before choosing depth formats.

- Add stronger Vertex manager allocation ownership checks if callers start freeing arbitrary user-provided ranges. The current free-list allocator merges and reuses released chunks, but it trusts handles returned by the allocation APIs rather than tracking every live allocation for double-free diagnostics.

- Add a dedicated transfer-queue upload path for vertex data. Texture uploads now use a transfer-queue-aware staging path with graphics-queue handoff, but vertex/index data still writes directly to host-visible buffers instead of staging through the transfer queue.

- Replace remaining host-side waits for managed render target timeline dependencies with queue-side timeline waits so independent frame work can overlap more effectively. Graph node dependencies use queue-side timeline waits, but frame-start target clears and begin-render synchronization still call `ez_gfx_ctx_wait_timeline` on the CPU.

- Expose per-pipeline or per-draw dynamic state controls, including viewport and scissor rectangles, and derive render areas from active attachment extents. Vulkan viewport/scissor dynamic state is already enabled internally, but callers cannot set these values and render graph render areas still use swapchain extent even for scaled render targets.

- Model render target declarations with richer Vulkan usage metadata instead of deriving usage only from color/depth kind. `Ez_Gfx_Shader_Target_Declaration` still records name, scale, kind, format, binding, and load behavior, while image usage is derived broadly from color/depth classification.

- Allow per-target clear values for render target initialization each frame. Frame-start clears exist, but color/depth/swapchain clear values are hardcoded instead of coming from shader metadata or render target declarations.

- Coalesce compatible render graph nodes into larger passes when no resource dependency requires a barrier between them. `ez_gfx_render_graph_execute` still records/submits each node separately and each node begins/ends dynamic rendering, so adjacent compatible attachment writes cannot share a pass yet.

- Add render target aliasing based on render graph node dependencies. The manager still creates one image allocation per acquired target name/format/scale/extent; it does not reuse memory for targets whose lifetimes do not overlap within a frame.

- Add precompiled shader modules with reflection metadata so applications do not need to ship Slang source or compile reflection at runtime. Shader loading still uses Slang source modules and extracts reflection/SPIR-V during startup.

- Add a shader cache using precompiled shader modules. The current cache is an in-memory Vulkan pipeline cache keyed by shader identity and attachment formats; it does not persist Slang/SPIR-V/reflection artifacts across runs.

- Add streamed texture upload with minimal-required mip readiness. The texture manager can load external texture assets asynchronously, but it does not yet expose progressive mip uploads where a low-resolution mip can become ready before finer mips stream in later.

- Support compressed texture formats. Color target parsing is still limited to uncompressed formats such as `rgba8` and `rgba16f`, with no BC/ASTC/block-compressed texture handling.

- Add compute shader support. The public render API, linked Slang program creation, pipeline creation, and command recording paths are still graphics-only and bind `.GRAPHICS` pipelines.
