# Specification: Cross-Platform Path Normalization & GitHub Actions CI Pipeline

## Overview

For `1.0.0` stability across Linux, macOS, and Windows, generated `templates.odin` files must be byte-for-byte deterministic regardless of host OS path separators (`/` vs `\`), and every push/PR must be verified by an automated GitHub Actions CI workflow.

## Functional Requirements

1. **Path Normalization (`cli/main.odin`):**
   - Normalize relative template identifiers (`relpath`) and source-comment paths to forward slashes (`/`) so `when path == "..."` clauses in generated Odin code are identical across Windows and POSIX hosts.
2. **GitHub Actions CI (`.github/workflows/ci.yml`):**
   - Run `odin test cli`, `odin test .`, and `odin run cli -- tests . && odin test tests` on push and pull_request events across Linux, macOS, and Windows runners.

## Acceptance Criteria

- Template path identifiers with backslashes or mixed separators normalize consistently to `/`.
- `.github/workflows/ci.yml` executes the full test matrix cleanly.
