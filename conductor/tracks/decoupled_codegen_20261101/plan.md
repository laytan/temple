# Implementation Plan: Decouple Generated Code for Shared Collection Support

## Phase 1: CLI Flag Parsing & Target Package Configuration

- [ ] Task: Add CLI flag parsing for `-out`, `-pkg`, and `-temple-import` while maintaining legacy positional argument support
    - [ ] Write unit tests in `cli/regression_test.odin` for CLI argument parsing (legacy positional vs. `-out`/`-pkg`/`-temple-import` flags and package inference)
    - [ ] Implement `Cli_Options` struct and parser in `cli/main.odin`
- [ ] Task: Update code generator header and runtime symbol qualification for external packages
    - [ ] Write unit tests verifying generated code output both in `package temple` mode and external `package views` mode
    - [ ] Update `transpile_calls` and `cli/transpiler.odin` to emit `import __temple "..."` and qualify `Compiled(T)` / `__temple_write_*` when target package is not `temple`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: CLI Flag Parsing & Target Package Configuration' (Protocol in workflow.md)

## Phase 2: Call Collection & End-to-End Integration

- [ ] Task: Support same-package `compiled` / `compiled_inline` call discovery alongside imported `temple.compiled`
    - [ ] Write AST call-collection tests in `cli/regression_test.odin` covering unqualified local package calls and aliased imports
    - [ ] Update `resolve_temple_proc_expr` and `visit_odin_node` in `cli/main.odin`
- [ ] Task: Add end-to-end test in `tests/` exercising external package generation with a read-only `temple` runtime import
    - [ ] Create integration test verifying compilation and rendering via generated external package file
    - [ ] Update `README.md` with shared collection / `-out` usage instructions
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Call Collection & End-to-End Integration' (Protocol in workflow.md)
