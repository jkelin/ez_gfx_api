# Agent Guidance

- When creating structural TODOs or identifying project work that needs to be updated later, update `TODO.md` instead of leaving the task only in chat or inline code comments.

- After creating a plan in planning mode, add the plan into the `docs/plans` directory. When updating a plan, update the plan file directly.

- After completing a task, report whether anything extra has been changed that is not part of the task and report it.
- The handwritten `include/ez_gfx_api.h` is the C ABI layout source of truth. The Roslyn generator in `csharp/EzGfx.BindingGenerator` consumes that header as an `AdditionalFiles` input and must stay synchronized whenever an exported function or ABI-visible data structure changes; generated `.g.cs` output is never hand-edited.
- C# interop wrappers must use spans, stack allocation, and generated UTF-8/pointer marshalling on the normal path. Heap-backed fallback storage is permitted only for oversized boundary inputs that exceed the documented stack threshold.
- Window lifetime, input, resize/minimize observation, and event polling belong to the parent C# application. The C ABI accepts an externally owned native window handle only when creating a Vulkan surface; it must not create, destroy, poll, close, or query parent windows. `ez_gfx_c_surface_resize_pending` may report native present/acquire invalidation so the parent can retry the externally observed extent.
- Vertex and texture manager lifetime is internal to native device setup. The C ABI exposes resource operations (vertex/index heaps, uploads, texture load/unload), not manager construction/destruction; managed facades are non-owning.
