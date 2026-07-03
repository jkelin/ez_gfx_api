# TODO

- Decouple graphics pipeline caching from descriptor set/pool ownership. `Ez_Gfx_Pipeline_Record` still owns both `VkPipeline` and descriptor resources; `render_target_manager.version` mitigates stale render-target image views on resize, but vertex heap rebinding and per-frame descriptor lifetimes are still tied to cached pipeline records.

- Expand the pipeline cache key to include topology and rasterization options instead of only shader identity, color formats, depth format, and blend mode. Blend mode is now reflected from the `[BlendMode]` Slang attribute; topology and rasterization are still hardcoded.

- Add hardware per-draw scissor support for ImGui and other UI renderers. Example 4 currently enforces clip rectangles in the fragment shader via `discard`, which is correct but less efficient than dynamic scissor state.

- Example 4 handles ImGui 1.92 font atlas uploads through `Renderer_Has_Textures` and `DrawData.textures` status callbacks. Follow-up: add `ez_gfx_update_texture_region` for partial `Want_Updates` uploads instead of full atlas reloads.

- Support arbitrary sampled and writable access to managed render targets. The renderer supports attachment writes, declaration-based sampled reads, and managed storage-image writes, but still rejects attachment feedback/read-write color targets and lacks a fully general hazard model. The swapchain is intentionally shader write-only through `ColorTarget("swapchain", "write")`; shader reads from the swapchain are not supported.

- Expand explicit storage-image render target semantics beyond the first managed `RWTexture2D` path. Color render targets can now be bound as storage images, but the graph still treats storage declarations as conservative read/write accesses and needs richer per-stage/per-access hazard metadata.

- Document and enforce that explicit target attributes are the source of truth for engine render target intent, even when shader resource reflection changes due to compiler optimization. Declarations currently drive lifetime/format/load behavior, but graph scheduling still mixes declaration-derived reads with reflected color/depth writes.

- Document the swapchain shader policy in public-facing docs: `swapchain` is a presentation target and is shader write-only. Readback remains available through transfer-based screenshots, not shader resource reads.

- Add broader render target pixel snapshot coverage for more graph shapes. `LoadTarget` history and managed storage-image store/load now have snapshot tests, but fork/join and scaled-target render areas still need pixel assertions.

- Choose depth/stencil formats from device-supported candidates and prefer D24/D16 where the extra D32 precision is not required. Depth target parsing currently maps `d32_float` to a hardcoded `D24_UNORM_S8_UINT`, and the renderer still does not query `vkGetPhysicalDeviceFormatProperties` before choosing depth formats.

- Add a reusable vertex staging buffer pool. Vertex and index uploads now use asynchronous transfer-queue staging, but repeated uploads still allocate and retire one staging buffer and command buffer per upload.

- Batch transfer-queue vertex uploads. Vertex and index uploads currently submit one transfer command buffer per allocation; asset-heavy initialization should coalesce compatible copies into fewer command buffers/submits while preserving per-upload callbacks and error reporting.

- Replace global timeline signal serialization with queue-side dependencies or per-manager ordered timelines. Vertex and texture workers currently wait for the previous shared timeline value before submitting so timeline signals stay monotonic, which is simple but can serialize otherwise independent transfer work.

- Add a direct staging-write upload API for generated vertex data. The current async API copies caller memory into a staging buffer before the GPU copy; callers that procedurally generate vertices could avoid one CPU-side copy by writing directly into a mapped staging allocation owned by the upload system.

- Replace the global vertex upload wait in `ez_gfx_begin_render` with per-allocation or per-draw dependencies. The renderer currently waits for all scheduled vertex uploads to be submitted, even when the frame does not draw those allocations.

- Add stronger Vertex manager allocation ownership checks if async upload failures and user frees start interacting with range reuse. The free-list allocator still trusts handles returned by the allocation APIs rather than tracking every live allocation for double-free diagnostics.

- Replace remaining host-side waits for managed render target timeline dependencies with queue-side timeline waits so independent frame work can overlap more effectively. Graph node dependencies use queue-side timeline waits, but frame-start target clears and begin-render synchronization still call `ez_gfx_ctx_wait_timeline` on the CPU.

- Expose per-pipeline or per-draw dynamic state controls, including viewport and scissor rectangles. Vulkan viewport/scissor dynamic state is already enabled internally, and render graph render areas now derive from active attachments, but callers cannot set these values.

- Model render target declarations with richer Vulkan usage metadata instead of deriving usage only from color/depth kind. `Ez_Gfx_Shader_Target_Declaration` still records name, scale, kind, format, binding, and load behavior, while image usage is derived broadly from color/depth classification.

- Allow per-target clear values for render target initialization each frame. Frame-start clears exist, but color/depth/swapchain clear values are hardcoded instead of coming from shader metadata or render target declarations.

- Coalesce compatible render graph nodes into larger passes when no resource dependency requires a barrier between them. `ez_gfx_render_graph_execute` still records/submits each node separately and each node begins/ends dynamic rendering, so adjacent compatible attachment writes cannot share a pass yet.

- Add render target aliasing based on render graph node dependencies. The manager still creates one image allocation per acquired target name/format/scale/extent; it does not reuse memory for targets whose lifetimes do not overlap within a frame.

- Add precompiled shader modules with reflection metadata so applications do not need to ship Slang source or compile reflection at runtime. Shader loading still uses Slang source modules and extracts reflection/SPIR-V during startup.

- Add a shader cache using precompiled shader modules. The current cache is an in-memory Vulkan pipeline cache keyed by shader identity and attachment formats; it does not persist Slang/SPIR-V/reflection artifacts across runs.

- Add streamed texture upload with minimal-required mip readiness. The texture manager can load external texture assets asynchronously, but it does not yet expose progressive mip uploads where a low-resolution mip can become ready before finer mips stream in later.

- Add a reusable texture staging buffer pool. Texture uploads currently retire staging buffers correctly by timeline, but repeated loads still allocate and destroy dedicated staging buffers instead of reusing bucketed host-visible transfer buffers.

- Add per-texture sample-ready state and defer descriptor updates until the graphics handoff has transitioned textures to `SHADER_READ_ONLY_OPTIMAL`. Descriptor writes currently rely on render-side timeline waits and pending handoff recording, but a distinct sample-ready state would make callback semantics and validation ownership more explicit.

- Replace the global texture upload wait in `ez_gfx_begin_render` with per-texture or per-draw dependencies. The renderer currently waits for all scheduled texture uploads to be submitted, even when the frame does not sample those textures.

- Batch transfer-queue texture submissions. Texture uploads currently submit one transfer command buffer per texture; bulk loading screens could reduce queue overhead by recording multiple copies into one submit while preserving per-texture error and unload semantics.

- Add texture upload profiling counters for queued decode time, decode duration, staging bytes, transfer submit latency, graphics handoff latency, and callback latency so future streaming changes can be measured instead of guessed.

- Support compressed texture formats. Color target parsing is still limited to uncompressed formats such as `rgba8` and `rgba16f`, with no BC/ASTC/block-compressed texture handling.

- Add compute shader support. The public render API, linked Slang program creation, pipeline creation, and command recording paths are still graphics-only and bind `.GRAPHICS` pipelines.

- Render-graph structured-buffer and indirect barriers use blanket source stage/access masks (`HOST|COMPUTE|VERTEX|FRAGMENT|DRAW_INDIRECT`) before every node. Replace with tracked node-to-node hazard metadata.

- `examples/shared/assets/sponza.glb` uses KTX2/Basis Universal textures via `KHR_texture_basisu` (18.8 MB, down from 52.6 MB). Regenerate with `npx @gltf-transform/cli etc1s examples/shared/assets/sponza.glb <output.glb>`. KTX2 image parsing is provided by `vendor/patches/glTF2/ktx2-image-type.patch` (applied during `just setup`); runtime KTX2 decode is not implemented yet.
