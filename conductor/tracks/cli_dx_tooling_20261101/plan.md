# Implementation Plan: Developer Experience & CLI Modes (`--check`, `--warn-unused`, `--watch`)

## Phase 1: CI Verification (`--check`) & Orphan Template Detection (`--warn-unused`)

- [x] Task: Implement `--check` mode in `cli/main.odin`
    - [x] Write unit tests in `cli/regression_test.odin` verifying up-to-date vs. stale/missing generated file detection without disk writes
    - [x] Update `transpile_calls` to support `check_only` verification mode
- [x] Task: Implement `--warn-unused` orphan template detection
    - [x] Write unit tests verifying that root templates, extended layouts, and embedded partials are marked used while unreferenced `.temple.twig` files trigger a warning
    - [x] Collect referenced template paths across workers and scan for unreferenced template files
- [x] Task: Conductor - User Manual Verification 'Phase 1: CI Verification (--check) & Orphan Template Detection (--warn-unused)' (Protocol in workflow.md)

## Phase 2: Watch Mode (`--watch`)

- [x] Task: Implement `--watch` incremental file polling loop in `cli/main.odin`
    - [x] Write unit tests for workspace mtime snapshot comparison and change detection
    - [x] Add `--watch` loop that re-runs collection and transpilation on `.odin` or template file changes
- [x] Task: Conductor - User Manual Verification 'Phase 2: Watch Mode (--watch)' (Protocol in workflow.md)
