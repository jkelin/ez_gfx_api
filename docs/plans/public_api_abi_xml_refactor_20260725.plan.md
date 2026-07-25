# Public API, Context, Validation, and XML ABI Refactor

Date: 2026-07-25

## Scope

Refactor the Odin engine public boundary so `src/ez_gfx_api.odin` is the sole non-private engine source file and owns public procedures, public type layouts, and C-export adapters. The non-engine `examples/shared/` support package remains public because native examples and tests import it. Remove the `ez_gfx_` prefix from internal functions, replace thread-local context lookup with Odin-context/final-C-argument flow, move validation and typed status results to public APIs, and make manually maintained `bindings/bindings.xml` the source for both the generated C header and C# bindings.

## Execution order

1. Inventory repository-owned Odin files, public exports, internal prefix usage, thread-local/context access, validation branches, binding generators, and all native/managed example callsites. Capture the baseline with `just test`, `just check-bindings`, `just build-native-dll`, and `dotnet build csharp/EzGfx.sln --configuration Release`.
2. Add `#+private` to every repository-owned Odin engine source file except the public facade; preserve the cross-package `examples/shared/` support API; use `@private` for intentional package-visible seams; remove `ez_gfx_` from internal-only functions; move all public type layouts and exported C ABI declarations into the facade with `@(link_name=...)`; update `AGENTS.md` with the visibility/facade rules.
3. Remove thread-local context access. Public Odin APIs use the Odin `context`; C wrappers accept the context in the final ABI argument, install/use it for the delegated public call, and do not perform semantic validation themselves. The delegated public Odin API validates the resulting context and returns the typed status. Add focused context propagation and invalid-context coverage.
4. Put argument validation in public APIs, return a typed status enum, make internals assume validated arguments, and make C wrappers thin adapters with no duplicated semantic validation. Cover dimensions, sizes/counts, pointers/handles, enum values, unsupported formats, and failure output state.
5. Author `bindings/bindings.xml` with the complete public C ABI, GI-style docs, layouts, enums, validation metadata, names, and context metadata. Create/update the XML-to-header generator and Justfile recipes; generate `include/ez_gfx_api.h` with GI comments, `access`, and `counted_by` attributes and portability guards.
6. Rewire `csharp/EzGfx.BindingGenerator` to consume the XML rather than the header. Generate names, marshalling, validations, structs/enums, docs, status conversion, and context handling from XML with minimal special cases; preserve span/stack allocation and oversized-input fallback.
7. Migrate native and C# examples and focused tests to the public facade/status API while preserving deterministic settings and screenshot specifications.
8. Audit visibility, prefixes, TLS, validation placement, generated-file ownership, and C# header-parser removal. Run `just check-bindings`, `just build-native-dll`, the C# solution build, `just test`, and all existing example build/smoke/screenshot recipes. Run formatters/linters only after tests pass and repeat affected verification.

## Acceptance criteria

- Every repository-owned Odin engine source file except `src/ez_gfx_api.odin` has `#+private`; `examples/shared/` remains a deliberate public support-package exception.
- Public example-used Odin APIs, their public type layouts, and the complete public C ABI are defined in `src/ez_gfx_api.odin`; internal functions have no `ez_gfx_` prefix.
- No thread-local context lookup remains; Odin APIs use Odin context and C wrappers use the final context argument.
- Public APIs return typed statuses and own boundary validation; internals and C wrappers do not duplicate semantic validation.
- `bindings/bindings.xml` is manually maintained and drives deterministic generation of `include/ez_gfx_api.h` and C# bindings.
- Generated headers contain GI-style function docs plus guarded GCC/Clang `access` and `counted_by` annotations.
- Native and C# examples compile and existing deterministic tests/screenshot checks pass without modifying tests or verification assets to hide failures.
