# Specification: Developer Experience & CLI Modes (`--check`, `--warn-unused`, `--watch`)

## Overview

To make `temple_cli` first-class in both local development loops and CI pipelines, this track adds three CLI modes/flags:
1. `--check`: Verifies that all templates compile without errors and that the generated `templates.odin` on disk matches the freshly transpiled output, exiting non-zero without modifying disk if out-of-date.
2. `--warn-unused`: Scans the project for `.temple.twig` (and `.temple.html`) files that are never referenced by any `temple.compiled`, `{% embed %}`, or `{% extends %}`.
3. `--watch`: Polls/watches `.odin` and template files for mtime changes and incrementally re-runs compilation during development.

## Functional Requirements

1. **`--check` Flag:**
   - Run full call collection and template transpilation in memory.
   - Compare generated output bytes with the target output file on disk. If missing or different, print a clear error message and exit with code 1 without writing to disk.
2. **`--warn-unused` Flag:**
   - Record all template file paths visited during compilation (root `Call_Path`, `extends`, and `embed` targets).
   - Walk the project directory for `.temple.twig` / `.temple.html` files and emit a warning for any unreferenced template files.
3. **`--watch` Flag:**
   - Track file modification times across `.odin` and template files and re-run transpilation when changes are detected.

## Acceptance Criteria

- `temple_cli --check <project_dir> <temple_dir>` exits 0 when `templates.odin` is up-to-date and exits 1 without touching disk when stale.
- `--warn-unused` accurately identifies orphan template files while excluding layouts and partials reached via `extends` and `embed`.
