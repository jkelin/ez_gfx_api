# Texture Decode Worker Pool

Implemented a configurable CPU decode worker pool for the Texture Manager while keeping GPU upload serialized through the existing transfer-queue upload worker.

## Completed

- Added `Ez_Gfx_Ctx_Desc.texture_decode_worker_count`; `0` resolves to logical CPU count minus two, with a minimum of one worker.
- Split texture work into decode jobs consumed by a decode worker pool and decoded upload jobs consumed by one upload worker.
- Preserved the existing callback contract: `texture_loaded_callback` fires from the upload worker after upload submission or failure.
- Reduced raw texture memory traffic by keeping raw RGBA/RGB source slices through decode and writing/copying them directly into staging.
- Added optional persistent mapping support to `Ez_Gfx_Buffer` and enabled it for texture staging buffers.
- Reduced mip generation barrier churn by transitioning generated mips to shader-read layout after the blit chain.

## Deferred

- Reusable texture staging buffer pool.
- Per-texture sample-ready state and deferred descriptor updates.
- Per-texture render dependencies instead of the global texture upload wait.
- Batched transfer-queue texture submissions.
- Texture upload profiling counters.
- Compressed texture formats and progressive/minimal-required mip streaming.
