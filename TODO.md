# TODO

- Audit `odin-slang` object ownership in shader compilation so session/module/component objects can be released safely without causing heap corruption. `ez_gfx_shader_create_linked_program` still creates per-compile Slang session/module/entry-point/program/blob objects without a proven release order; verify reflection and SPIR-V extraction cleanup with validation or allocator tracking.

- Investigate the Slang crash triggered by passing arguments to the zero-field `LoadTarget` attribute, then add a negative reflection fixture for that misuse. Keep this until the parser/Slang behavior is captured by a regression test.

- Decouple graphics pipeline caching from descriptor set/pool ownership. `Ez_Gfx_Pipeline_Record` still owns both `VkPipeline` and descriptor resources; `render_target_manager.version` mitigates stale render-target image views on resize, but vertex heap rebinding and per-frame descriptor lifetimes are still tied to cached pipeline records.

- Expand the pipeline cache key to include topology, blend, and rasterization options instead of only shader identity, color formats, and depth format. The current Vulkan pipeline state is hardcoded, so this is not a live bug yet, but the cache will return incompatible pipelines as soon as those states become configurable.

- Support arbitrary sampled and writable access to render targets. The renderer supports attachment writes and declaration-based sampled reads, but rejects feedback/read-write color targets and lacks storage-image write semantics, swapchain reads, and general hazard handling.

- Add explicit storage-image render target semantics when shaders need writable image resources outside attachment writes. Color render targets have `STORAGE` image usage and general-layout transitions, but descriptors are still combined image samplers rather than storage-image bindings.

- Document and enforce that explicit target attributes are the source of truth for engine render target intent, even when shader resource reflection changes due to compiler optimization. Declarations currently drive lifetime/format/load behavior, but graph scheduling still mixes declaration-derived reads with reflected color/depth writes.

- Decide and document the supported semantics for reading from `swapchain`. Shader reads from `swapchain` are currently rejected, while screenshots use transfer-source usage; if shader reads are intentionally unsupported, document that policy, otherwise add usage flags, layout transitions, format checks, and synchronization.

- Add render target pixel readback tests so multi-frame `LoadTarget` behavior can assert preserved contents, not only Vulkan validation cleanliness. The current history test exercises two frames without validation errors but does not read pixels back to prove the previous frame's color was loaded.

- Choose depth/stencil formats from device-supported candidates and prefer D24/D16 where the extra D32 precision is not required. Depth target parsing currently maps `d32_float` to a hardcoded `D24_UNORM_S8_UINT`, and the renderer still does not query `vkGetPhysicalDeviceFormatProperties` before choosing depth formats.

- Add a Vulkan memory allocator/suballocator so small buffers and images do not each consume a dedicated allocation. Buffer and render-target creation still call `vkAllocateMemory` per resource, which will scale poorly and can hit allocation-count limits.

- Update the vertex manager heap allocator so it reuses freed memory instead of acting as a bump allocator that only appends new allocations. `Ez_Gfx_Gpu_Heap` still advances `used` in `ez_gfx_gpu_heap_upload` and fails on capacity overflow; add free-list, ring, or frame-retired range reuse before long-lived vertex/index workloads can recycle GPU heap space.

- Add a dedicated transfer-queue upload path for textures and vertex data, including proper synchronization. Device setup still selects a graphics/present queue and uploads through host-visible buffers on the graphics path, so there is no async staging/copy queue yet.

- Replace remaining host-side waits for managed render target timeline dependencies with queue-side timeline waits so independent frame work can overlap more effectively. Graph node dependencies use queue-side timeline waits, but frame-start target clears and begin-render synchronization still call `ez_gfx_ctx_wait_timeline` on the CPU.

- Expose per-pipeline or per-draw dynamic state controls, including viewport and scissor rectangles, and derive render areas from active attachment extents. Vulkan viewport/scissor dynamic state is already enabled internally, but callers cannot set these values and render graph render areas still use swapchain extent even for scaled render targets.

- Model render target declarations with richer Vulkan usage metadata instead of deriving usage only from color/depth kind. `Ez_Gfx_Shader_Target_Declaration` still records name, scale, kind, format, binding, and load behavior, while image usage is derived broadly from color/depth classification.

- Allow per-target clear values for render target initialization each frame. Frame-start clears exist, but color/depth/swapchain clear values are hardcoded instead of coming from shader metadata or render target declarations.

- Coalesce compatible render graph nodes into larger passes when no resource dependency requires a barrier between them. `ez_gfx_render_graph_execute` still records/submits each node separately and each node begins/ends dynamic rendering, so adjacent compatible attachment writes cannot share a pass yet.

- Add render target aliasing based on render graph node dependencies. The manager still creates one image allocation per acquired target name/format/scale/extent; it does not reuse memory for targets whose lifetimes do not overlap within a frame.

- Add precompiled shader modules with reflection metadata so applications do not need to ship Slang source or compile reflection at runtime. Shader loading still uses Slang source modules and extracts reflection/SPIR-V during startup.

- Add a shader cache using precompiled shader modules. The current cache is an in-memory Vulkan pipeline cache keyed by shader identity and attachment formats; it does not persist Slang/SPIR-V/reflection artifacts across runs.

- Add streamed texture upload. The project still has render-target and swapchain image allocation, but no external texture asset upload API or frame-synchronized streaming path.

- Support compressed texture formats. Color target parsing is still limited to uncompressed formats such as `rgba8` and `rgba16f`, with no BC/ASTC/block-compressed texture handling.

- Add compute shader support. The public render API, linked Slang program creation, pipeline creation, and command recording paths are still graphics-only and bind `.GRAPHICS` pipelines.
