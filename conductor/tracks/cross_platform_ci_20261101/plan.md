# Implementation Plan: Cross-Platform Path Normalization & GitHub Actions CI

## Phase 1: Path Normalization & Deterministic Codegen

- [ ] Task: Normalize template identifiers and embed paths to forward slashes across platforms
    - [ ] Write unit tests in `cli/regression_test.odin` verifying path normalization on mixed `/` and `\` separators
    - [ ] Normalize `relpath` and diagnostic/comment paths in `cli/main.odin`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Path Normalization & Deterministic Codegen' (Protocol in workflow.md)

## Phase 2: GitHub Actions CI Pipeline & 1.0.0 Release Readiness

- [ ] Task: Add `.github/workflows/ci.yml` running `odin test cli`, `odin test .`, and `odin test tests`
    - [ ] Create `.github/workflows/ci.yml` for Linux, macOS, and Windows
    - [ ] Verify all test suites and `--check` pass cleanly
- [ ] Task: Conductor - User Manual Verification 'Phase 2: GitHub Actions CI Pipeline & 1.0.0 Release Readiness' (Protocol in workflow.md)
