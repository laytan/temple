# AGENTS.md — temple Repository Guide

This document provides repository architecture, build/test commands, and development rules for coding agents working on `temple`.

---

## Repository Overview & Architecture

* **Root (`package temple`)** — Zero-allocation runtime library with zero external dependencies:
  * **`runtime.odin`**: `Compiled($T)` descriptor (`with` writer procedure and precomputed `approx_bytes`), context-aware security escapers (`__temple_write_escaped_string`, `__temple_write_safe_url`, `__temple_write_url_param`, `__temple_write_js_string`, `__temple_write_magic_string`), direct stack-buffered numeric writers (`__temple_write_int`, `__temple_write_f64_prec`), zero-allocation streaming formatters (`__temple_write_fmt_escaped`, `__temple_write_fmt_raw`), and `__temple_default` overloads (`string`, `[]T`, `Maybe(T)`).
  * **`templates.odin`**: Generated `"contextless"` `compiled` and `compiled_inline` dispatch table for the local test suite.
  * **`runtime_test.odin`**: Unit tests for runtime writers, context-aware escapers, numeric boundaries, and zero-allocation streaming invariants.
* **`cli/` (`package temple_cli`)** — Ahead-of-time multi-threaded template compiler CLI and 3-layer ATDD specification suite:
  * **`main.odin` & `cli_args.odin`**: CLI flag parser (`-out`, `-pkg`, `-temple-import`, `--check`, `--warn-unused`, `--watch`, `--version`), parallel worker pool with per-worker dynamic arenas, and timestamp-agnostic file emission.
  * **`collector.odin`**: Odin AST scanner (`core:odin/parser`) that discovers `compiled` and `compiled_inline` calls across packages, resolving package/local string constants and procedure aliases while rejecting shadowed runtime identifiers.
  * **`lexer.odin` & `parser.odin`**: Zero-allocation template tokenizer, unified `Node_Slab` AST allocator, pipe filter (`|`) and call modifier parser, compile-time `fmt` strength reduction, and Odin expression/statement validation via `core:odin/parser`.
  * **`inheritance.odin`**: Multi-level layout inheritance (`extends`, `block`, `super`), `embed` cycle detection, macro hoisting, and `raw_cache` / `resolved_cache` memoization.
  * **`transpiler.odin`**: Zero-allocation Odin code generator and static `approx_bytes` buffer size estimator.
  * **`diagnostics.odin` & `watcher.odin`**: Rust/Odin-style source diagnostics with caret underlines and `Call_Site -> Extends -> Embed` trace stacks, orphan template detection (`--warn-unused`), and incremental file polling (`--watch`).
  * **`containers.odin`**: Stack-first inline `Small_Array` and `Small_Map` containers.
* **`tests/` (`package temple_tests`)** — End-to-end integration test suite and `tests/external_views/` decoupled external package codegen fixture.
* **`benchmarks/` (`package benchmarks`)** — Runtime and compiler pipeline benchmark suite.

---

## Build, Check & Test Commands

```bash
# 1. Typecheck runtime, CLI, and integration test packages
odin check . -no-entry-point
odin check cli
odin check tests -no-entry-point

# 2. Run the CLI & 3-layer ATDD specification suite
odin test cli -all-packages

# 3. Run runtime unit tests and end-to-end integration tests
odin test .
odin test tests

# 4. Run a single test by name
odin test cli -define:ODIN_TEST_NAMES=temple_cli.spec_three_level_layout_inheritance_with_super_and_relative_embeds

# 5. Verify generated templates (--check & --warn-unused)
odin run cli -- --check --warn-unused tests .
odin run cli -- --check --warn-unused tests/external_views --out=tests/external_views/templates_gen.odin --temple-import=../../
odin run cli -- --check --warn-unused benchmarks --out=benchmarks/templates_gen.odin --pkg=benchmarks --temple-import=..

# 6. Build the compiler CLI binary and run benchmarks
odin build cli -out:temple_cli -o:speed
odin run benchmarks -o:speed
```

---

## Coding & Testing Rules for Agents

* **Read [`usage-rules.md`](usage-rules.md) First**: Follow all template syntax rules, context-aware escaping filters (`url`, `url_param`, `js`, `raw`, `magic`), pipe chaining rules, and CLI codegen workflows defined in [`usage-rules.md`](usage-rules.md).
* **Preserve `"contextless"` & Zero-Allocation Runtime Invariants**: Generated `compiled` and `compiled_inline` procedures must remain `proc "contextless" ($path: string, $T: typeid) -> Compiled(T)` so callers can bind templates at global scope. Runtime procedures in [`runtime.odin`](runtime.odin) must never allocate on the heap or `context.temp_allocator`.
* **Never Hand-Edit Generated `templates.odin` or `templates_gen.odin` Files**: Always re-run `odin run cli -- ...` after editing template fixtures, adding `compiled` / `compiled_inline` calls, or modifying codegen in [`cli/main.odin`](cli/main.odin) and [`cli/transpiler.odin`](cli/transpiler.odin).
* **Zero Leaks Under `odin test`**: The Odin test runner attaches a tracking allocator to `context.allocator`. Free all heap allocations, use `context.temp_allocator` for ephemeral test builders, and ensure every `Spec_Driver` arena (`defer scenario_end(s)`) is destroyed.
* **Follow the 3-Layer ATDD Test Architecture in `cli/`**:
  * **Layer 1 ([`cli/temple_spec_test.odin`](cli/temple_spec_test.odin))**: Express behavioral specifications using domain `given_*`, `upon_*`, and `then_*` steps with zero raw parser, AST, or transpiler plumbing.
  * **Layer 2 ([`cli/spec_dsl_test.odin`](cli/spec_dsl_test.odin))**: Bridge domain steps (`scenario_begin`, `given_template`, `upon_compiling_template`, `then_emits_writer_call`, `then_diagnostic_is_reported`) to protocol driver procedures.
  * **Layer 3 ([`cli/spec_driver_test.odin`](cli/spec_driver_test.odin))**: Isolate direct `Compile_Context`, `Parser`, and `transpile` calls, manage the per-scenario `mem.Dynamic_Arena`, and enforce cross-cutting AST syntax verification (`driver_assert_valid_generated_odin`) on every compiled template.
