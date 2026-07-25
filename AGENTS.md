# Agent Guidance

- When creating structural TODOs or identifying project work that needs to be updated later, update `TODO.md` instead of leaving the task only in chat or inline code comments.

- After creating a plan in planning mode, add the plan into the `docs/plans` directory. When updating a plan, update the plan file directly.

- After completing a task, report whether anything extra has been changed that is not part of the task and report it.
- Repository-owned Odin implementation files use `#+private`; `src/ez_gfx_api.odin` is the sole engine-source exception and contains every public Odin API, public C adapter, and public type layout. `examples/shared/` remains public because native examples and tests import its cross-package support API. New implementation files follow this boundary.
- Internal procedures do not use the `ez_gfx_` prefix. Public Odin procedures are declared in `src/ez_gfx_api.odin`; package-visible implementation seams use `@(private)`.
- Public Odin APIs own boundary validation and return typed status values (or the documented typed resource error). Internal procedures assume validated arguments and must not duplicate public argument validation. C adapters are thin marshalling layers and do not perform semantic validation.
- `@(link_name=...)` is reserved for actual C-exported declarations paired with `@(export)`; ordinary public Odin procedures must retain their source names without `link_name`.
- Public C ABI declarations and their type layouts are maintained in `bindings/bindings.xml`; `include/ez_gfx_api.h` is generated from that XML and must never be hand-edited. The C# generator consumes the XML, not the generated header, and generated `.g.cs` output is never hand-edited.
- C# interop wrappers must use spans, stack allocation, and generated UTF-8/pointer marshalling on the normal path. Heap-backed fallback storage is permitted only for oversized boundary inputs that exceed the documented stack threshold.
- Window lifetime, input, resize/minimize observation, and event polling belong to the parent C# application. The C ABI accepts an externally owned native window handle only when creating a Vulkan surface; it must not create, destroy, poll, close, or query parent windows. `ez_gfx_c_surface_resize_pending` may report native present/acquire invalidation so the parent can retry the externally observed extent.
- Vertex and texture manager lifetime is internal to native device setup. The C ABI exposes resource operations (vertex/index heaps, uploads, texture load/unload), not manager construction/destruction; managed facades are non-owning.
