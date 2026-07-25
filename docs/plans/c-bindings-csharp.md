# C ABI, binding header, and C# ports

## Current refactor

- The existing branch has a handwritten C ABI header, Odin wrappers, a Roslyn header generator, managed API, and six example entry points.
- The existing ImGui demo remains a first-class C ABI and C# example path; this refactor deletes only the JSON/Python metadata path and makes the C# source generator the only managed binding generator.
- The generator emits compiler-generated source under the build's intermediate `obj/` directory; no duplicate generated binding file is tracked in the repository.

## Execution order

1. Create `feat/c-bindings-csharp`, preserve the pre-existing dirty `vendor/odin-imgui` state, inventory `src/` and `examples/`, read `Justfile`, and record `just test` as the native baseline.
2. Define the ABI manually in `include/ez_gfx_api.h` and implement the Odin boundary in `src/c_api.odin` and `src/c_api_types.odin`, using opaque handles and explicit pointer/count layouts. Update `AGENTS.md` so the handwritten header is the source of truth and the C# generator must stay synchronized with it.
3. Add a Roslyn incremental source-generator project at `csharp/EzGfx.BindingGenerator`. It reads `include/ez_gfx_api.h` as an `AdditionalFiles` input through `AdditionalTextsProvider`, parses the supported C typedef/struct/enum/function declarations, and emits `EzGfxNative.g.cs` with matching C# enums, sequential structs, and Cdecl P/Invoke methods. No JSON or Python binding metadata is used. Add DLL generation and export verification to `Justfile`.
4. Build `out/ez_gfx_native.dll`, verify every header function is exported, and runtime-load the DLL through generated P/Invoke. The native project is `csharp/EzGfx.Native/EzGfx.Native.csproj`; its project reference consumes the generator and includes the header as an `AdditionalFiles` item.
5. Add `csharp/EzGfx.sln`, the native loader/safe-handle support, and `csharp/EzGfx/EzGfx.csproj` with the managed Easy Graphics API (`EasyGraphics.cs`, resource/lifetime wrappers, command encoding, texture loaders, and errors).
6. Add `csharp/EzGfx.Examples/EzGfx.Examples.csproj`, `Program.cs`, `ExampleHost.cs`, and one `Examples/ExampleNN.cs` for every existing Odin example (`1_triangle`, `2_textured_cube`, `3_compute_structured_buffer`, `4_imgui`, `5_helmet_cgltf`, `6_sponza_ktx2`). Keep the ImGui example on the first-class C ABI path, reuse the same shaders and assets, and preserve each example's runtime behavior.
7. Add deterministic example-run recipes to `Justfile`, run each Odin and C# example with a fixed frame count, write screenshots to `artifacts/odin/` and `artifacts/csharp/`, and compare them with `tools/compare_images.py`. Exact equality is the default; a mismatch remains a defect.
8. Run the source-generator/header drift check, DLL build/export/load checks, `dotnet build csharp/EzGfx.sln --configuration Release`, the managed smoke path, `just test`, and every example/image comparison. Do not alter tests or reference images to make a check pass. Report baseline failures, nondeterministic examples, deployment dependencies, mismatches, and any extra changed files.
- Architecture override: window lifetime, input, resize/minimize observation, and event polling belong to the parent application. The C ABI exposes only a surface resource created from an externally owned native handle plus externally supplied framebuffer dimensions; it does not export window create/destroy/poll/close/query functions. `ez_gfx_c_surface_resize_pending` reports native present/acquire invalidation without querying the parent window, native surface recreation never queries GLFW, and `(0,0)` surface resize marks a minimized surface without rebuilding the swapchain.
- Architecture override: vertex and texture manager lifetime remain internal to the native device. The C ABI exposes vertex-heap/upload and texture-load operations, not manager construction/destruction. The managed `VertexManager`/texture facade is non-owning.
- The native Odin examples may keep their own application-side GLFW host while the core consumes its pointer and extent through the same surface contract; no GLFW lifecycle remains in `src/`.

## ABI and verification constraints

- All exported names use the `ez_gfx_c_` prefix and appear exactly once in the handwritten header and once as an Odin `@(export)` wrapper.
- No Odin slices, dynamic arrays, Odin strings, polymorphic values, or raw internal Vulkan structs cross the boundary. Strings are UTF-8 pointer/count values or documented null-terminated forms, arrays are pointer/count values, resources are opaque handles, and structs use explicit fixed-width fields.
- Boundary inputs validate pointers, lengths, enum values, and handles. Errors use stable result codes and actionable diagnostics.
- Generated C# is produced only by the Roslyn incremental generator from `include/ez_gfx_api.h`; it is never hand-edited.
- The C# loader must validate architecture, DLL resolution, dependent Odin DLLs, and ABI version. Safe handles must dispose resources in the documented order.
- ABI version `4` covers the resize-pending query and explicit surface snapshot-cache control; the native Odin DLL must export all 34 header declarations, checked by `tools/verify_exports.py`.
- Surface snapshot caching is disabled by default for interactive rendering and enabled explicitly by screenshot-producing C# examples; native GLFW examples enable it only when `EZ_GFX_SCREENSHOT` is set.
- Generated convenience wrappers keep the normal path allocation-free: `ReadOnlySpan<T>` inputs are pinned directly, UTF-8 strings and binding arrays use stack storage up to 16 KiB, and `ArrayPool<byte>` is used only above that threshold.
- Screenshot comparisons use the same assets, fixed frame/camera/seed, and explicit output paths. A mismatch is a defect, not a reason to weaken comparison checks.
