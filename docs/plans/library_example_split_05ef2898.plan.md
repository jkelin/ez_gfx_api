---
name: Library Example Split
overview: Refactor the current single-package triangle demo into a reusable `ez_gfx` library under `src` plus an executable `examples/one_triangle` sample. The new render interface will own frame recording, cached graphics pipelines, and reusable multi-draw indirect buffers while the example owns triangle data, shader path, and the render loop.
todos:
  - id: split-packages
    content: Convert `src` into `package ez_gfx` and create `examples/one_triangle` as `package main`.
    status: in_progress
  - id: generic-shader-pipeline
    content: Generalize shader and pipeline creation away from triangle-specific constants.
    status: pending
  - id: render-interface
    content: Implement `begin_render`, `render_add_vertex_pipeline`, and `finish_render` around frame recording/submission.
    status: pending
  - id: indirect-manager
    content: Add reusable multi-draw indirect buffer manager with stride-aware command and payload writes.
    status: pending
  - id: move-example
    content: Move triangle shader/data/render-loop code into `examples/one_triangle`.
    status: pending
  - id: verify
    content: Update and run `just build` and `just run`.
    status: pending
isProject: false
---

# Refactor EasyGraphics Into Library And Example

## Package And Layout

- Change every reusable source file in [`src`](src) from `package main` to `package ez_gfx`.
- Move executable/demo policy out of [`src/main.odin`](src/main.odin) into [`examples/one_triangle/main.odin`](examples/one_triangle/main.odin): `App`, `main`, init/run/cleanup loop, env-driven screenshot/run duration, and triangle constants.
- Move [`shaders/triangle.slang`](shaders/triangle.slang) to [`examples/one_triangle/triangle.slang`](examples/one_triangle/triangle.slang); the example will pass that path into the library shader loader.
- Update [`Justfile`](Justfile) so `just build` and `just run` build/run `examples/one_triangle`, using the existing Slang `PATH` setup.

## Thread-Local Context

- Store the active `Ez_Gfx_Ctx` in thread-local library state so public library functions do not need a `ctx` parameter.
- Add an explicit context activation function, for example `ez_gfx_set_current_ctx(&app.ctx)`, and make context-dependent public functions read the current thread-local context internally.
- Keep context lifetime owned by the example `App`, but require the example to make that context current before creating windows/swapchains, uploading buffers, compiling shaders, beginning renders, or destroying GPU resources.
- Add a clear invariant: context-dependent public functions should fail clearly if no current context is set, and cleanup should clear the current context when it points at the destroyed context.

## Library Render Interface

- Add a library render module, likely [`src/render.odin`](src/render.odin), with:
  - `Ez_Gfx_Render` created by `ez_gfx_begin_render(window)` using the current thread-local context and stored as the current thread-local render.
  - `ez_gfx_render_add_vertex_pipeline(shader, indirect_stride, indirect_capacity)` returning `Ez_Gfx_Vertex_Pipeline_Descriptor` for the current thread-local render.
  - `ez_gfx_finish_render()` to record commands, submit, present, recycle transient resources, and clear the current thread-local render.
- Move the current acquire/reset/record/submit/present flow from `draw_frame` and `record_frame_commands` behind `begin_render`/`finish_render`.
- Add a clear invariant: every render-thread call sequence must be `ez_gfx_begin_render`, zero or more `ez_gfx_render_add_vertex_pipeline` calls, then `ez_gfx_finish_render`; calling add/finish without a current render should fail clearly.
- Keep swapchain recreation handling in the library frame path because callers should not need Vulkan acquire/present error handling for each example.

## Pipeline Manager

- Replace `Ez_Gfx_Ctx.pipeline`, `pipeline_layout`, `descriptor_*`, and triangle draw offsets with reusable managers on `Ez_Gfx_Ctx`:
  - `Ez_Gfx_Pipeline_Manager` caches graphics pipelines by shader identity and swapchain color format.
  - `Ez_Gfx_Pipeline_Record` owns pipeline, layout, descriptor set layout, descriptor pool, descriptor set, and LRU metadata.
  - Cleanup happens from `ez_gfx_ctx_destroy` through a manager destroy function.
- Refactor [`src/pipeline.odin`](src/pipeline.odin) from `ez_gfx_pipeline_create_triangle` into generic pipeline creation using shader entries/reflected vertex heap bindings.
- Keep the first cache key conservative: shader identity plus color format. Add a TODO for future options such as topology, blend/depth state, and rasterization settings.

## Shader Generalization

- Replace `ez_gfx_shader_compile_triangle` with a generic shader compile function, for example `ez_gfx_shader_compile(ctx, Ez_Gfx_Shader_Desc)`.
- `Ez_Gfx_Shader_Desc` should include `path`, `vertex_entry`, and `fragment_entry`; default entry constants can remain convenience values if useful.
- `Ez_Gfx_Shader_Program` should carry enough stable identity for the pipeline cache. If the shader is loaded each frame, the identity should be based on descriptor fields and not the transient Vulkan module handle alone.

## Multi-Draw Indirect Buffer Manager

- Add a library module, likely [`src/indirect_buffer.odin`](src/indirect_buffer.odin), with `Ez_Gfx_Multi_Draw_Indirect_Buffer_Manager` on `Ez_Gfx_Ctx`.
- Use one host-visible buffer allocation per descriptor where offset `0` stores a `u32` draw count and offset `stride` begins the command array.
- Store each element as a user-selected stride whose first bytes are `vk.DrawIndexedIndirectCommand`; any bytes after that are caller-owned per-draw data.
- Provide focused writer helpers on `Ez_Gfx_Vertex_Pipeline_Descriptor`, such as setting draw count, writing one command at an index, and writing optional user payload bytes. This keeps the interface small while allowing custom stride data.
- `finish_render` will issue `vk.CmdDrawIndexedIndirectCount` using the same buffer for count and command data, with `countOffset = 0`, `indirectOffset = stride`, `maxDrawCount = capacity`, and `stride = descriptor.indirect_stride`.
- Enable and validate Vulkan device features needed for indirect-count/multi-draw in [`src/ctx.odin`](src/ctx.odin). If unsupported, initialization should fail clearly rather than silently falling back.

## Example Rendering Flow

- The one-triangle example will initialize GLFW/window/context/swapchain through the library, create/upload triangle index and position buffers through `Ez_Gfx_Vertex_Manager`, then each frame:
  1. `ez_gfx_begin_render(main_window)`
  2. compile/load `examples/one_triangle/triangle.slang`
  3. `pipeline := ez_gfx_render_add_vertex_pipeline(&shader, size_of(Triangle_Draw), 1)`
  4. write draw count and one indexed draw command into the indirect descriptor
  5. `ez_gfx_finish_render()`
- Remove triangle-specific fields from `Ez_Gfx_Ctx` and keep triangle offsets/counts inside the example app state.

## Verification

- Run `just build` to verify the new library/example package layout compiles.
- Run `just run` to exercise the example and screenshot path on Windows.
- There are no existing test files in the repo, so verification will rely on build plus the existing run/screenshot command unless new tests are added later.
