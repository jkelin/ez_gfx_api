# Async Vertex Transfer Queue Uploads

Implemented the Vertex Manager transfer-queue upload path in a fresh worktree on `cursor/vertex-transfer-queue`.

## Completed

- Vertex/index heaps are now device-local buffers with `TRANSFER_DST` usage.
- `ez_gfx_vertex_manager_upload_indices` and `ez_gfx_vertex_manager_upload_vertices` reserve heap ranges and return immediately, then queue worker-thread transfer uploads.
- The Vertex Manager owns a worker thread, transfer command pool, per-upload staging buffers, per-upload command buffers, timeline tracking, and upload completion callbacks.
- Frame begin waits for scheduled vertex uploads to be submitted, and the render graph waits on the vertex upload timeline before drawing.
- Queue-family handoff records buffer release/acquire barriers when transfer and graphics families differ.
- Tests/examples now pass addressable package-level upload data so async source memory stays valid through callback completion.

## Deferred

- Staging/command-buffer pooling for vertex uploads.
- Stronger live-allocation ownership tracking around frees and async upload failures.
- A shared transfer-upload substrate between textures and vertices once both paths settle.
