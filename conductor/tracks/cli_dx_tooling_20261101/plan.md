# Implementation Plan: Developer Experience & CLI Modes (`--check`, `--warn-unused`, `--watch`)

## Phase 1: CI Verification (`--check`) & Orphan Template Detection (`--warn-unused`)

- [ ] Task: Implement `--check` mode in `cli/main.odin`
    - [ ] Write unit tests in `cli/regression_test.odin` verifying up-to-date vs. stale/missing generated file detection without disk writes
    - [ ] Update `transpile_calls` to support `check_only` verification mode
- [ ] Task: Implement `--warn-unused` orphan template detection
    - [ ] Write unit tests verifying that root templates, extended layouts, and embedded partials are marked used while unreferenced `.temple.twig` files trigger a warning
    - [ ] Collect referenced template paths across workers and scan for unreferenced template files
- [ ] Task: Conductor - User Manual Verification 'Phase 1: CI Verification (--check) & Orphan Template Detection (--warn-unused)' (Protocol in workflow.md)

## Phase 2: Watch Mode (`--watch`)

- [ ] Task: Implement `--watch` incremental file polling loop in `cli/main.odin`
    - [ ] Write unit tests for workspace mtime snapshot comparison and change detection
    - [ ] Add `--watch` loop that re-runs collection and transpilation on `.odin` or template file changes
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Watch Mode (--watch)' (Protocol in workflow.md)
