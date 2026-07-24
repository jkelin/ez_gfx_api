# Odin Overview Map

Source: https://odin-lang.org/docs/overview/

## Use This Map

Read this map before editing, reviewing, or generating Odin code. It summarizes the high-value rules from the official overview page and highlights mistakes agents commonly make when coming from C, Go, Rust, or Zig.

## Declarations

- Every `.odin` file starts with a package declaration. All files in one directory must use the same package name.
- Variables use `name: Type`, `name: Type = value`, or `name := value`.
- `:=` is shorthand for declaration plus assignment, not reassignment. Declarations must be unique in a scope.
- Constants use `::` or typed constant declarations like `name : Type : value`; constant values must be compile-time known.
- Variables default to zero values unless explicitly initialized with `---`, which leaves memory uninitialized.
- Use `---` only when intentionally avoiding initialization for performance or interop reasons.

## Packages And Visibility

- Imports use collection prefixes such as `core:fmt`, `base:runtime`, or `vendor:glfw`.
- Imports without a collection prefix are relative to the current file.
- Declarations are public by default.
- Use `@(private)` for package-private declarations and `@(private="file")` for file-private declarations.
- Package subdirectories are taxonomy only. `core:image/png` does not imply an import dependency on `core:image`.

## Control Flow

- Odin has one loop construct: `for`.
- `for init; condition; post {}` is the C-style loop form.
- `for condition {}` is the while-style form.
- `for {}` is an infinite loop.
- Range loops use `a..<b` for half-open ranges and `a..=b` for inclusive ranges.
- `for value in array_or_slice` iterates copies. Use `for &value in slice` to mutate elements.
- Strings iterate as UTF-8 runes, not bytes, and cannot be iterated by reference.
- Map iteration can use `for key, value in m`; values can be by-reference with `for key, &value in m`, but keys are immutable.
- `if` and `switch` do not need parentheses, but braces or `do` are required.
- `switch` over enums and unions is exhaustive by default. Use `#partial switch` only when intentionally ignoring cases.
- `defer` runs at scope exit and is the idiomatic cleanup mechanism for ordinary control flow.
- `when` is compile-time conditional compilation and does not create a runtime scope.

## Procedures

- Procedures are declared with `proc`, usually bound to a constant name: `foo :: proc(...) -> ... {}`.
- Consecutive parameters can share a type: `proc(x, y: int)`.
- Parameters are immutable. If a parameter must be reassigned, shadow it explicitly: `x := x`.
- Passing a pointer copies the pointer, not the pointee. Slices, dynamic arrays, and maps are normal structs with pointer fields.
- Procedures can return multiple values: `proc() -> (T, Error)`.
- Named return values are variables in the procedure scope. Bare `return` is clearest only in short procedures.
- Named arguments improve clarity for large call sites. Positional arguments cannot follow named arguments.
- Default parameter values must be compile-time known.
- Overloading is explicit with procedure groups: `to_string :: proc{bool_to_string, int_to_string}`.

## Basic Types And Conversion

- Default to `int` for ordinary integer work unless a sized, unsigned, pointer-sized, endian-specific, or foreign type is required.
- `string` stores pointer plus length. `cstring` is for zero-terminated C strings.
- Zero values include `0`, `false`, `""`, and `nil` for pointer-like values.
- Assignments between different typed values require explicit conversion.
- Prefer `T(value)` for normal conversions. `cast(T)value` has the same semantic meaning and is useful in contexts where call syntax is awkward.
- `transmute(T)value` is a bit-cast between same-size types. Use it only when reinterpretation is intended.
- `auto_cast` is for prototyping and quick tests; do not use it as a default in durable code.

## Containers

- Fixed arrays are `[N]T`; infer literal length with `[?]T{...}`.
- Array and slice indexing is bounds-checked by default. Use `#no_bounds_check` only in narrow blocks where bounds are proven.
- Slices are `[]T`, store pointer plus length, and reference existing data.
- The zero value of a slice is `nil`; nil slices have length zero.
- Dynamic arrays are `[dynamic]T`; they allocate with the current context allocator unless explicitly given another allocator.
- Append dynamic arrays through pointers: `append(&items, value)`.
- Dynamic arrays can be sliced with `items[:]`.
- Allocate slices and dynamic arrays with `make`; release allocated backing storage with `delete`.
- `[dynamic; N]T` is a fixed-capacity dynamic array that can remain on the stack.
- Maps are `map[K]V`; the zero value is `nil`, and initialized maps usually come from `make(map[K]V)`.
- Reading a missing map key returns the element zero value. Use `value, ok := m[key]` or `key in m` to distinguish absence.
- Remove map entries with `delete_key(&m, key)`.
- Map literals and dynamic array literals that allocate require `#+feature dynamic-literals` per file.
- Do not assign directly to fields of a struct stored in a map slot. Take a pointer to the slot or replace the whole value.

## User Types

- Type aliases use `Alias :: Existing_Type`; aliases are equal to the target type.
- Distinct types use `Name :: distinct Existing_Type`; distinct types are not equal to the underlying type.
- Struct literals must provide all fields positionally or use named fields for partial initialization.
- Struct pointers support field access without explicit dereference: `p.x` works like `p^.x`.
- Struct directives include `#align`, `#raw_union`, `#packed`, `#min_field_align`, `#max_field_align`, `#simple`, and `#all_or_none`.
- Unions are tagged/discriminated unions. Their zero value is usually `nil`.
- Type assertions use `v.(T)` or `value, ok := v.(T)`.
- Type switches use `switch x in value { case T: ... }`.
- `#no_nil` unions have no nil state and use the first variant as the default.
- Enums support implicit selectors like `.North` when the expected type is known.
- Enumerated arrays use enum values as indices: `[Direction]Vec2`.
- Bit sets model sets and are often better than integer flag constants.
- Pointers use `^T`, address-of uses `&`, dereference uses `p^`. Odin has no pointer arithmetic; use `core:mem` helpers such as `ptr_offset` when needed.

## Optional-Ok Control Operators

- `or_else` supplies a default for optional-ok expressions such as map lookups and type assertions.
- `or_return` propagates a false ok value or non-nil error-like final result from a multi-valued expression.
- For multi-return procedures using `or_return`, named return values are often required so a bare `return` can assign the final result.
- `or_continue` and `or_break` simplify loop control with optional-ok expressions and can take labels.
- Use these operators where they improve clarity; ordinary `if` checks are preferable when custom cleanup, logging, or non-bare returns are clearer.

## Conditional Compilation

- Platform-specific file suffixes such as `_windows.odin`, `_linux.odin`, or `_windows_amd64.odin` are often clearer than broad build tags.
- `when ODIN_OS == .Linux { ... }` compiles conditionally.
- `-define:NAME=value` pairs with `NAME :: #config(NAME, default)` for project-wide compile-time options.
- `#+build` includes or excludes files for target tags, but file suffixes are usually easier to reason about when they fit.
- `#+test` makes a file ignored except during `odin test`.
- `#+ignore` makes a file ignored entirely.
- `#+private` before the package declaration makes declarations private by default.
- `#+feature dynamic-literals` enables allocating map and dynamic array literals in that file.

## Context, Allocation, And Logging

- Every Odin-calling-convention procedure receives an implicit `context` pointer.
- `context` is local to scope and can be copied or temporarily modified.
- `new`, `make`, dynamic arrays, maps, and many core APIs use `context.allocator` by default.
- `context.allocator` is for general subsystem allocations.
- `context.temp_allocator` is for short-lived temporary allocations and should be cleared with `free_all(context.temp_allocator)` at the appropriate cycle boundary.
- Prefer `defer delete(x)` or `defer free(x)` close to the allocation site when ownership stays in the same scope.
- Free memory with the same allocator that allocated it.
- Use the tracking allocator in debug builds to catch leaks and bad frees when memory ownership is uncertain.
- Procedures with non-Odin calling conventions, such as `proc "c"`, must assign `context = runtime.default_context()` before calling Odin procedures that require context.

## Foreign And Vendor Interop

- Foreign libraries use `foreign import name "path-or-library"` and `foreign name { ... }`.
- Foreign procedure declarations use `---` because they have no Odin body.
- Foreign procedures default to C calling convention unless specified.
- Attributes such as `@(link_name="...")` and `@(default_calling_convention="...")` customize linkage.
- Keep vendor binding names close to upstream naming to make porting easier.
- Callback procedures declared with `proc "c"` need explicit context setup before using Odin core procedures like `fmt.println`.

## Parametric Polymorphism

- Compile-time constant parameters use `$`, such as `$N: int` or `$T: typeid`.
- Polymorphic records can take type parameters: `Table_Slot :: struct($Key, $Value: typeid) { ... }`.
- For record data types, `$` is optional because parameters are constant.
- Implicit parametric polymorphism can infer type parameters from arguments.
- Specialization constraints use forms like `$T/[]$E` or `^$T/Table`.
- `where` clauses constrain polymorphic procedures and records with compile-time predicates.

## Directives And Attributes

- Directives use `#name` and extend language behavior.
- Attributes use `@(name)` and modify declarations.
- Prefer exhaustive switches and full enumerated array initialization; use `#partial` only when partial handling is intended.
- Use `#packed`, `#raw_union`, and `#align` for ABI, layout, or memory-size requirements, not routine data modeling.
- Use `#caller_location` and `#caller_expression` for diagnostics-style APIs.
- `#c_vararg` is for foreign vararg procedures.

## Common Agent Pitfalls

- Do not write C-style pointer syntax like `*T` or `*p`; Odin uses `^T` and `p^`.
- Do not assume map indexing tells you whether a key exists; use comma-ok or `key in m`.
- Do not mutate range-loop copies when the target container must change; use by-reference iteration.
- Do not rely on garbage collection; Odin memory management is manual.
- Do not add broad build tags when platform suffix files would be clearer.
- Do not use `auto_cast`, `transmute`, `#no_bounds_check`, or `---` as convenience shortcuts in normal application code.
