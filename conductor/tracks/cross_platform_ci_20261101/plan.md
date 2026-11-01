# Implementation Plan: Cross-Platform Path Normalization & GitHub Actions CI

## Phase 1: Path Normalization & Deterministic Codegen

- [x] Task: Normalize template identifiers and embed paths to forward slashes across platforms
    - [x] Write unit tests in `cli/regression_test.odin` verifying path normalization on mixed `/` and `\` separators
    - [x] Normalize `relpath` and diagnostic/comment paths in `cli/main.odin`
- [x] Task: Conductor - User Manual Verification 'Phase 1: Path Normalization & Deterministic Codegen' (Protocol in workflow.md)

## Phase 2: GitHub Actions CI Pipeline & 1.0.0 Release Readiness

- [x] Task: Add `.github/workflows/ci.yml` running `odin test cli`, `odin test .`, and `odin test tests`
    - [x] Create `.github/workflows/ci.yml` for Linux, macOS, and Windows
    - [x] Verify all test suites and `--check` pass cleanly
- [x] Task: Conductor - User Manual Verification 'Phase 2: GitHub Actions CI Pipeline & 1.0.0 Release Readiness' (Protocol in workflow.md)
