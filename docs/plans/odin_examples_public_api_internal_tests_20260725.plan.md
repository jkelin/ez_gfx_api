# Odin examples-only public API and internal test boundary

Date: 2026-07-25

## Goal

Make the Odin package imported by `examples/` expose the example-facing handle API
rather than test seams or implementation managers. Keep package-private behavior
available to source-local tests, keep the C ABI stable, and make
`src/ez_gfx_api.odin` the sole engine-facing facade for public Odin declarations,
public C adapters, and public type layouts.

## Completed boundary inventory

The facade now exposes the 31 Odin procedures consumed by the six native examples
and `examples/shared/`:

- context creation, idle, and destruction;
- surface creation, destruction, device initialization, and resize;
- shader creation and release;
- texture load, binding lookup, and unload;
- decoder enablement;
- vertex/index heap creation and uploads;
- render begin/finish;
- indirect and structured resource operations;
- handle-based graphics and compute pipeline creation;
- screenshot saving; and
- deterministic configuration queries.

Package-private validation, context-query, present-mode, render-target, resource
manager, raw upload, and vertex-copy seams remain available to source-local tests
without being exported by the facade. The public type layouts required by those
example calls were moved into `src/ez_gfx_api.odin`; implementation-only layouts
remain in `src/defs.odin` under `#+private`. The C-facing layouts and exported
adapters were co-located in `src/ez_gfx_api.odin`; `src/ez_gfx_api_c.odin` was
removed. The ImGui implementation file is private, while its C export remains in
the facade; C-only ImGui staging layouts are private.

The XML contract in `bindings/bindings.xml`, generated `include/ez_gfx_api.h`,
and generated C# output were not changed.

## Test relocation and package structure

Tests that use package-private engine seams now compile with the owning `ez_gfx`
package:

- `tests/cube.odin` -> `src/cube_test.odin`;
- `tests/triangle.odin` -> `src/triangle_test.odin`;
- `tests/render_target_graph.odin` -> `src/render_target_graph_test.odin`;
- `tests/vertex_copy.odin` -> `src/vertex_copy_test.odin`;
- `tests/generational_arena.odin` -> `src/arena_test.odin`.

`src/test_shared.odin` and `src/test_snapshot.odin` provide package-local test
support without importing `examples/shared` (which imports `src` and would form a
cycle). The remaining external integration tests stay under `tests/`; their
shared fixture constants are in `tests/test_support.odin`. All repository-owned
source tests use `#+test` and `#+private`.

The generational arena implementation now lives in `src/arena.odin` as a private
part of the `ez_gfx` package. This avoids exposing a second imported package while
preserving the arena behavior and test coverage.

## Build and verification wiring

`Justfile`'s `test` recipe runs both package-local source tests and the remaining
external integration tests with the existing deterministic and screenshot
environment:

- `odin test src -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1`;
- `odin test tests -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1`.

The intended final checks are:

- build all six native examples;
- run the fixed-frame/headless Odin example recipe;
- run `just test`;
- run `just check-bindings`;
- run `just build-native-dll` and `just verify-native-exports`; and
- run `dotnet build csharp/EzGfx.sln --configuration Release`.

## Risks and non-goals

- Relocated source tests cannot import `examples/shared`; the local support copy
  must remain behaviorally aligned with the native example window/camera helpers.
- External integration tests intentionally remain separate and must not be dropped
  from `just test`.
- C adapter source ownership changed, but C signatures, link names, XML, generated
  headers, and managed bindings are intentionally unchanged.
- The refactor does not change rendering semantics, resource ownership, or ABI
  validation policy; any image mismatch remains a blocking defect.
