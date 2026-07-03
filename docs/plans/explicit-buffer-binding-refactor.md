# Explicit Buffer and Render-Target Binding Refactor

## Goal

Split frame-scoped resource lifetime from per-pipeline binding:

- Acquire structured buffers and indirect buffers as reusable handles.
- Bind every shader-required structured/indirect buffer explicitly by name when adding a pipeline.
- Validate node-local bindings at render submit.
- Add explicit render-target IDs via a describe API, while preserving implicit shader-declaration target acquisition for unbound targets.

## Implemented Shape

- `ez_gfx_render_acquire_structured_buffer` now returns `Ez_Gfx_Structured_Buffer_Handle`.
- `ez_gfx_render_acquire_indirect_buffer` now returns `Ez_Gfx_Indirect_Buffer_Handle`.
- `ez_gfx_render_add_vertex_pipeline` and `ez_gfx_render_add_compute_pipeline` accept `[]Ez_Gfx_Render_Binding`.
- Render graph nodes own resolved buffer bindings; descriptor updates hash and write node-local bindings.
- `ez_gfx_render_graph_validate` checks stale handles, size/capacity mismatches, and target declaration compatibility before submit.
- `ez_gfx_render_target_describe(width, height, debug_label)` returns `Ez_Gfx_Render_Target_Id`; explicit target IDs can be bound per pipeline by shader name.

## Follow-Up

`Ez_Gfx_Pipeline_Record` still owns descriptor sets by cached pipeline/frame slot. This matches the existing TODO about decoupling pipeline caching from descriptor set/pool ownership.
