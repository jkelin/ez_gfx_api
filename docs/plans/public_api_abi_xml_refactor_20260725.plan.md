[public_api_abi_xml_refactor_20260725.plan.md#E0D7]
1:# Public API extraction and generational-handle refactor
2:
3:Date: 2026-07-25
4:
5:## Scope
6:
7:Refactor the Odin public boundary so the public API facade, C ABI adapter, public definitions, ImGui implementation, and handle storage have separate ownership:
8:
9:- `src/defs.odin` contains every struct, enum, and const definition currently owned by `src/ez_gfx_api.odin`, including public fixed-width status/value types and public opaque handle types. Packed-handle bit layout helpers live in package-private `src/handles.odin` (`#+private`); they are not a second public source.
10:- `src/ez_gfx_api.odin` contains public facade procedures and public-handle-to-private-reference translation. It does not retain moved definitions, C exports, or C-only marshalling.
11:- `src/ez_gfx_api_c.odin` contains every exported `ez_gfx_*` procedure, C ABI marshalling, validation of pointer-plus-length ABI shape, and result/diagnostic conversion. It uses the public handle representation and has no parallel C handle registry.
12:- `src/imgui.odin` contains all public and private ImGui-related declarations and implementation currently present anywhere under `src`.
13:- `src/generational_arena/` contains a generic generational arena and focused tests. A static context arena owns contexts; each context owns child arenas for handle-addressable resources. Internal context/resource structs remain private.
14:
15:The handwritten C ABI header and generated managed bindings remain authoritative integration artifacts. The ABI continues to use fixed-width structs, opaque fixed-width handles, and pointer-plus-length parameters. Generated C# output is never hand-edited.
16:
17:Public/C handles remain `u64` and use one representation: context slot+1 in bits 0-19, context generation in bits 20-39, child slot+1 in bits 40-51, and child generation in bits 52-63. Context handles require zero child fields; zero and out-of-range fields are invalid. Odin exposes distinct handle types while C retains fixed-width typedefs.

Cross-kind safety does not reserve kind bits in the packed `u64`. Instead each context owns one shared `handle_identity_arena`. Packed child slot/generation indexes that identity arena; the identity record stores `(Resource_Kind, typed-arena local handle)`. Resolvers and C wrappers validate the recorded kind before typed-arena lookup, so C ABI `uint64_t` misuse cannot alias equal child slot/generation values across resource kinds.
Texture descriptor indices are a separate runtime value from opaque texture handles. The Odin facade exposes `ez_gfx_texture_binding_index`, and the C ABI exposes `ez_gfx_c_texture_binding_index`; managed callers must resolve the index before writing shader material/push-constant data. Adding the C query increments the ABI version to 7.
18:
19:The ImGui extraction includes not only layouts and state but every ImGui procedure currently in the API path, including initialization, texture upload/destruction, demo rendering, and the C-facing demo export implementation. `ez_gfx_api_c.odin` may retain only non-ImGui C descriptors/adapters and delegates any C-facing ImGui entry point to `imgui.odin`.
20:
21:## Execution order
22:
23:1. Inventory `src/ez_gfx_api.odin`, `src/ez_gfx_api.h`, all `src/**/*.odin` API/C/ImGui references, examples 1-6, `Justfile`, and `csharp/`. Enumerate top-level struct/enum/const definitions, public handle types, C exports, and ImGui symbols; use LSP references before changing exported symbols. Record the baseline with `just test`, `just check-bindings`, `just build-native-dll`, and `dotnet build csharp/EzGfx.sln --configuration Release`.
24:2. Move every struct/enum/const definition from `src/ez_gfx_api.odin` to `src/defs.odin`, preserving names, field order, ABI attributes, comments, and visibility. Rewire all callers and leave exactly one definition per moved symbol. The facade retains API behavior but no moved definitions.
25:3. Move all C API-related declarations and implementation from `src/ez_gfx_api.odin` to `src/ez_gfx_api_c.odin`: exported `ez_gfx_*` procedures, export attributes, ABI adapters, pointer/count marshalling, and diagnostics. Remove the obsolete C handle system and make the adapter use public generational-handle values. Reconcile the handwritten header/source inputs and regenerate only through the official binding workflow.
26:4. Move all ImGui imports, state, types, constants, callbacks, lifecycle code, and helpers from `src` into `src/imgui.odin`, preserving public/private visibility and frame ordering. Remove duplicate ImGui implementation and avoid import cycles.
27:5. Implement `src/generational_arena/` as a generic typed arena with allocation, lookup, validity, removal, reuse, generation advancement, growth, clear/deinit, and fail-fast invalid/stale/double/exhausted-handle behavior. Add deterministic focused tests for empty lookup, reuse, stale handles, double removal, growth, zero handles, and generation exhaustion.
28:6. Replace every old C handle/registry path with arena-backed public handles. Add the process-level context arena and per-context arenas for every handle-addressable resource (including shader programs and all other inventory results). Centralize ownership/context validation and invalidate handles before private resource destruction. Update every public API, C wrapper, native example, focused test, and managed binding input; remove obsolete aliases and shims.
29:7. Regenerate and validate bindings with `just check-bindings`, build the native DLL with `just build-native-dll`, build managed code with `dotnet build csharp/EzGfx.sln --configuration Release`, and run the existing managed smoke path.
30:8. Run `just --list` and every existing native example build, fixed-frame smoke, and screenshot recipe named by the `Justfile`; run `just test` and `tools/compare_images.py` through the existing recipe with unchanged assets/settings. Run final lint/format checks only after behavior and ABI checks pass. Confirm final symbol ownership: definitions only in `defs.odin`, C ABI only in `ez_gfx_api_c.odin`, facade API in `ez_gfx_api.odin`, ImGui only in `imgui.odin`, and arena code/tests under `src/generational_arena/`.
31:
32:## Risks and verification
33:
34:- Preserve ABI layout and signatures; verify with binding drift checks, native DLL compilation, and C# Release compilation.
35:- Prevent stale, cross-context, zero, double-removed, and generation-exhausted handles; cover each in arena/lifecycle tests.
36:- Preserve destruction synchronization and invalidate handles before freeing private resources; exercise shutdown and example smoke paths.
37:- Preserve ImGui frame lifecycle; verify native smoke output and screenshots.
38:- Treat every unexpected screenshot mismatch as blocking; do not modify tests or verification assets to hide it.
39:- Report any changes outside this requested refactor. Expected non-code additions are this plan update; focused arena tests are part of the requested implementation.
40: