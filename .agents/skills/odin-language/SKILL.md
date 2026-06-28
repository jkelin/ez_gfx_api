---
name: odin-language
description: Applies Odin language and testing guidance from the official docs. Use when reading, writing, reviewing, debugging, building, or testing Odin code; when working with .odin files; or when the user mentions Odin, odin build, odin run, or odin test.
---

# Odin Language

Use this skill whenever the task involves Odin source code, Odin commands, Odin tests, or Odin project structure.

## Required References

- Read [overview.mapml](overview.mapml) before making or reviewing Odin code changes.
- Read [testing.mapml](testing.mapml) before creating, fixing, reviewing, or running Odin tests.

## Working Rules

- Prefer existing project commands, especially `just` recipes, before inventing raw `odin` commands.
- Keep Odin code explicit: use clear types at API boundaries, named arguments for ambiguous calls, and explicit conversions between different typed values.
- Manage memory deliberately. Pair `new`, `make`, dynamic arrays, maps, allocated strings, and custom allocators with the appropriate `free`, `delete`, `free_all`, or `defer`.
- Use `context.allocator` and `context.temp_allocator` intentionally. Do not hide allocation behavior behind surprising helpers.
- Preserve Odin's exhaustive checks. Do not add `#partial` switches unless intentionally handling only a subset of enum or union cases.
- Do not skip, disable, or comment out tests. Fix the test or the implementation.

## Verification

- For this repository, prefer `just test` for the configured test path.
- For packages with `@(test)` procedures, use `odin test <package-or-tests-dir>` and add `-all-packages` when tests are collected through required package imports.
- If a command needs Slang or project-specific PATH setup, prefer the repository's `Justfile` recipe instead of duplicating environment setup.

## Sources

- https://odin-lang.org/docs/overview/
- https://odin-lang.org/docs/testing/
