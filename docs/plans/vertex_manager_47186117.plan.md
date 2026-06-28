---
name: Vertex Manager
overview: Add a shared vertex manager with one bump-allocated index heap and named bump-allocated vertex heaps, then update the triangle sample to upload geometry through those heaps and bind shader-visible vertex heaps via Slang reflection attributes.
todos:
  - id: heap-module
    content: Add the generic bump-allocated GPU heap and named vertex manager interface.
    status: completed
  - id: reflection-bindings
    content: Reflect Slang `VertexHeap` attributes and produce Vulkan descriptor bindings.
    status: completed
  - id: descriptor-plumbing
    content: Create descriptor set layout/pool/set and update it with matched named vertex heaps.
    status: completed
  - id: triangle-migration
    content: Move triangle geometry upload to index and vertex heaps, and update shader reads.
    status: completed
  - id: verify
    content: Run `just build` and `just run`, then fix any compile/runtime validation issues.
    status: completed
isProject: false
---

# Vertex Manager Plan

## Assumptions

- The index heap and vertex heaps will share one generic GPU heap implementation: a host-visible Vulkan buffer plus CPU-side bump offset, parameterized by capacity and element size.
- Shader-visible vertex heaps will use Slang `StructuredBuffer<T>` resources, which map to Vulkan storage-buffer descriptors. The index heap will not be shader-visible; it will always be bound with `vk.CmdBindIndexBuffer`.
- For the first version, heap storage is append-only for the process lifetime. I will add TODOs for free/reuse or reset behavior rather than designing a full allocator now.

## Implementation Shape

- Add `[src/vertex_manager.odin](src/vertex_manager.odin)` with:
  - `Ez_Gfx_Gpu_Heap`: owns an `Ez_Gfx_Buffer`, capacity, stride, and used byte count.
  - `ez_gfx_gpu_heap_upload`: writes a typed slice at the current bump offset and returns the starting element index.
  - `Ez_Gfx_Vertex_Manager`: owns one index heap and a fixed set of named vertex heaps.
  - `ez_gfx_vertex_manager_upload_indices` and `ez_gfx_vertex_manager_upload_vertices` as the small caller-facing interface.
- Extend `[src/buffer.odin](src/buffer.odin)` with an offset write helper so heap uploads can copy into subranges instead of overwriting the whole buffer.
- Store the shared manager on `[src/ctx.odin](src/ctx.odin)` and destroy it from `ez_gfx_ctx_destroy`, replacing the direct `ctx.index_buffer` ownership.

## Shader Reflection And Binding

- Update `[src/shader.odin](src/shader.odin)` so compiling the triangle also returns a small reflected binding list:
  - Walk `program->getLayout(...)->getGlobalParamsVarLayout()`.
  - Find global variables with a user attribute named `VertexHeap`.
  - Read the attribute string argument as the vertex heap name.
  - Read the reflected binding index/space for that resource.
- Update `[src/pipeline.odin](src/pipeline.odin)` to create one descriptor set layout for reflected vertex heap bindings and use it in `vk.CreatePipelineLayout`.
- Add descriptor pool/set allocation and updates, likely in a focused helper near the pipeline or vertex manager. Each reflected binding will be updated with the matching named vertex heap buffer.

## Triangle Example

- Update `[shaders/triangle.slang](shaders/triangle.slang)` to define and use a custom attribute:

```hlsl
[__AttributeUsage(_AttributeTargets.Var)]
struct VertexHeapAttribute
{
    string name;
};

[VertexHeap("position")]
[[vk::binding(0, 0)]]
StructuredBuffer<float3> positions;
```

- Change `vertexmain` to read `positions[vertex_index]`, where `vertex_index : SV_VertexID` comes from the indexed draw.
- Update `[src/main.odin](src/main.odin)` triangle setup to:
  - Initialize the vertex manager with an index heap and a `position` vertex heap.
  - Upload `{0, 1, 2}` through the index heap.
  - Upload the three triangle positions through the `position` heap.
  - Bind the manager’s index heap buffer in `record_frame_commands` before `vk.CmdDrawIndexed`.
  - Bind the descriptor set containing reflected vertex heap buffers before the draw.

## Verification

- Use the configured just commands from `[Justfile](Justfile)`:
  - `just build` to catch Odin/Vulkan/Slang compile errors.
  - `just run` to render the triangle and save the screenshot path already used by the sample.
- If descriptor validation errors appear at runtime, fix them rather than weakening the sample or skipping verification.
