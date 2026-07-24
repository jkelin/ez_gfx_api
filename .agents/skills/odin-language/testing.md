# Odin Testing Map

Source: https://odin-lang.org/docs/testing/

## Use This Map

Read this map before creating, fixing, reviewing, or running Odin tests. It summarizes the official test runner documentation and the conventions that matter most while working in a codebase.

## Test Basics

- Run tests with `odin test <package-or-directory>`.
- Odin tests are ordinary Odin procedures marked with `@(test)`.
- Test procedures must accept exactly one argument of type `^testing.T`.
- Import `core:testing` in test files.
- By convention, name the argument `t`.

```odin
package tests

import "core:testing"

@(test)
my_test :: proc(t: ^testing.T) {
	testing.expect(t, true)
}
```

## Expectations

- Use `testing.expect(t, condition, optional_message)` for boolean checks.
- Use `testing.expectf(t, condition, format, values...)` for formatted failure messages.
- Use `testing.expect_value(t, actual, expected)` when comparing values; it produces a useful failure message.
- A test can contain multiple expectations.
- Prefer returning early after a failed setup expectation when later checks depend on setup success.

```odin
if !testing.expect_value(t, open_error, os.ERROR_NONE) {
	return
}
```

## Logging And Failure

- Tests use the normal logging system through packages such as `core:log`.
- The test runner logs info level by default; change it with `-define:ODIN_TEST_LOG_LEVEL=warning`, `error`, etc.
- Any `error` or `fatal` log message raised during a test makes that test fail.
- Use `testing.fail(t)` for an explicit failure.
- Use `testing.fail_now(t)` only when execution must stop immediately.

## Cleanup

- Prefer `defer` for ordinary cleanup. It keeps allocation and cleanup close together.
- Use `testing.cleanup` only for emergency cleanup after panics, assertions, memory faults, or timeouts where `defer` might not run.
- `testing.cleanup` callbacks run with elevated responsibility in the main thread; they must not panic, assert, bounds-fail, or access invalid memory.
- Even if a catastrophic test failure leaks memory, each test thread has a custom allocator wiped before the next test.

## Memory Tracking

- Test memory tracking is enabled by default.
- The runner reports leaks and bad frees at the end of tests.
- A leak report includes leaked size, allocation count, and source location.
- A bad-free report points to invalid, double, or non-owned frees.
- Do not silence leak reports by disabling memory tracking unless the user explicitly asks.
- Fix memory ownership with `defer free(...)`, `defer delete(...)`, allocator pairing, or by removing the unnecessary allocation.

## Timeouts And Randomness

- Use `testing.set_fail_timeout(t, duration)` for tests that might hang or have expected upper time bounds.
- Import `core:time` for durations such as `5 * time.Second`.
- Each test gets `t.seed`, shared across the run but different by default per run.
- Use `rand.reset(t.seed)` when a test needs reproducible random behavior from the runner's seed.
- Reproduce a failing random run with `-define:ODIN_TEST_RANDOM_SEED=<n>`.

## Separating Tests

- Prefer small, focused tests over one large `test_everything`.
- Small tests give clearer failure points and better parallelism.
- Keep setup helpers ordinary procedures and mark only actual test cases with `@(test)`.
- Do not skip, disable, or comment out failing tests. Fix the test or the code.

## Multiple Packages

- By default, `odin test` compiles tests in the specified package, not every imported package.
- Use `-all-packages` to run every `@(test)` procedure in imported packages too.
- A top-level tests package can use `@require import "foo"` to force subpackages into the test build.

```odin
package tests

@require import "foo"
@require import "bar"
```

Then run:

```text
odin test tests/ -all-packages
```

## Useful Test Defines

- `-define:ODIN_TEST_THREADS=<n>` controls test thread count; `0` uses available cores.
- `-define:ODIN_TEST_TRACK_MEMORY=false` disables memory tracking. Avoid this unless explicitly requested.
- `-define:ODIN_TEST_ALWAYS_REPORT_MEMORY=true` reports memory use for all tests.
- `-define:ODIN_TEST_NAMES=<package.test_name,test_name>` runs selected tests.
- `-define:ODIN_TEST_FANCY=false` disables animated ANSI progress.
- `-define:ODIN_TEST_SHORT_LOGS=true` keeps output compact.
- `-define:ODIN_TEST_LOG_LEVEL=<debug|info|warning|error|fatal>` filters logs.
- `-define:ODIN_TEST_RANDOM_SEED=<n>` reproduces seed-dependent failures.

## Project Workflow

- Prefer this repository's configured command: `just test`.
- If no `just` recipe fits, use PowerShell syntax and run `odin test` from the project root or with explicit paths.
- Use `odin test` for packages containing `@(test)` procedures.
- Use `odin run` only for executable-style test programs that are intentionally not written as `@(test)` tests.
- When adding tests to existing executable-style test directories, follow the local pattern unless the user asks to convert them to `odin test`.

## Common Agent Pitfalls

- Do not forget `@(test)` or the `^testing.T` parameter.
- Do not call expectations without passing `t`.
- Do not ignore failed setup and continue into checks that depend on valid resources.
- Do not use `testing.cleanup` where `defer` is sufficient.
- Do not disable memory tracking to hide leaks.
- Do not run only a narrow test after changing shared behavior; also run the repository's configured test command.
