# Example 5: Helmet via cgltf + linalg

Implemented in `examples/5_helmet_cgltf/`.

- Loads glTF assets via `vendor:cgltf` in [`examples/shared/gltf_loader.odin`](examples/shared/gltf_loader.odin).
- Uploads all triangle primitives into the vertex manager (`position` / `normal` heaps + index heap).
- Fills a `Primitive_Record` structured buffer (transform, index/vertex start/count).
- Compute shader appends `DrawIndexedIndirectCommand` entries; forward pass renders world-space normals as color.

Run: `just example_5` (requires `helmet.glb` in shared assets).
