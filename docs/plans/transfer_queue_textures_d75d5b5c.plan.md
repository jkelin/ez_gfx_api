# Transfer Queue Texture Uploads

Implemented the Texture Manager transfer-queue upload path without adding minimal-required mip streaming yet.

## Completed

- Context device setup now selects a graphics/present queue plus a transfer-capable queue, preferring a dedicated transfer family and falling back to graphics when needed.
- Texture uploads use a transfer-family command pool and submit staging copies through `ctx.transfer_queue`.
- Upload staging buffers are retained until their transfer timeline is complete instead of being destroyed immediately after submission.
- The render graph records pending graphics-side texture handoffs at the start of the first command buffer, after the existing texture upload timeline wait.
- Graphics handoff performs queue-family acquire when needed, then generates mips or transitions the uploaded image to `SHADER_READ_ONLY_OPTIMAL` before sampling.
- Tests cover transfer queue family selection and the textured cube validation path for the render/upload section.

## Deferred

- Minimal-required mip readiness and progressive streamed mip uploads remain follow-up work.
- Vertex/index transfer-queue staging remains follow-up work.
