# Implementation Plan: Decouple Generated Code for Shared Collection Support

## Phase 1: CLI Flag Parsing & Target Package Configuration

- [x] Task: Add CLI flag parsing for `-out`, `-pkg`, and `-temple-import` while maintaining legacy positional argument support
    - [x] Write unit tests in `cli/regression_test.odin` for CLI argument parsing (legacy positional vs. `-out`/`-pkg`/`-temple-import` flags and package inference)
    - [x] Implement `Cli_Options` struct and parser in `cli/main.odin`
- [x] Task: Update code generator header and runtime symbol qualification for external packages
    - [x] Write ATDD specifications in `cli/temple_spec_test.odin` verifying generated code output both in `package temple` mode and external `package views` mode
    - [x] Update `transpile_calls` and `cli/transpiler.odin` to emit `import __temple "..."` and qualify `Compiled(T)` / `__temple_write_*` (including `__temple_write_fmt_escaped` and `__temple_write_fmt_raw`) when target package is not `temple`
- [x] Task: Conductor - User Manual Verification 'Phase 1: CLI Flag Parsing & Target Package Configuration' (Protocol in workflow.md)

## Phase 2: Call Collection & End-to-End Integration

- [x] Task: Support same-package `compiled` / `compiled_inline` call discovery alongside imported `temple.compiled`
    - [x] Write AST call-collection tests in `cli/regression_test.odin` covering unqualified local package calls and aliased imports
    - [x] Update `resolve_temple_proc_expr` and `visit_odin_node` in `cli/main.odin`
- [x] Task: Add end-to-end test in `tests/` exercising external package generation with a read-only `temple` runtime import
    - [x] Create integration test verifying compilation and rendering via generated external package file
    - [x] Update `README.md` with shared collection / `-out` usage instructions
- [x] Task: Conductor - User Manual Verification 'Phase 2: Call Collection & End-to-End Integration' (Protocol in workflow.md)
