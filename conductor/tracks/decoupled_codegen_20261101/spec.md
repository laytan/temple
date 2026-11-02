# Specification: Decouple Generated Code for Shared Collection Support

## Overview

Currently, `temple_cli` writes `templates.odin` directly into the `temple/` library directory (`package temple`), which requires every project to vendor its own mutable copy of `temple`. This track decouples generated template code from the `temple` runtime library so projects can generate template procedures directly into their own package (e.g., `-out:views/templates_gen.odin -pkg:views`) while importing `temple` as an immutable library from Odin's `shared:` collection (while retaining backwards compatibility with the legacy 2-argument invocation).

## Functional Requirements

1. **CLI Output & Package Flags:**
   - Support `-out:<file_path>` (or `--out=<file_path>`) to specify where the generated `.odin` file is written.
   - Support `-pkg:<package_name>` (or automatically infer the package declaration from `.odin` files in the output directory) and `-temple-import:<import_path>` (defaulting to `"shared:temple"` or a configurable relative path when generating outside `package temple`).
   - Preserve backwards compatibility when invoked as `temple_cli <project_dir> <temple_dir>` with no flags.
2. **Generated Code Qualification:**
   - When generating into a user package (`package <pkg>`), import the `temple` runtime as `import __temple "<import_path>"` and qualify runtime types and helpers (`__temple.Compiled(T)`, `__temple.__temple_write_escaped_string`, `__temple.__temple_write_magic_string`, `__temple.__temple_write_fmt_escaped`, `__temple.__temple_write_fmt_raw`).
3. **Call Collection Support:**
   - Update `collect_compile_calls` in `cli/main.odin` to recognize `compiled` and `compiled_inline` calls targeting either the `temple` import or the local package's generated `compiled` / `compiled_inline` procedures.

## Acceptance Criteria

- Projects can place `temple` in a read-only directory (or `shared:temple`), generate `templates_gen.odin` into their own package directory, and compile/run templates without modifying any files inside `temple/`.
- Existing `temple_cli <project_dir> <temple_dir>` invocations continue to work without changes.
- All unit and integration tests pass with zero memory leaks.
