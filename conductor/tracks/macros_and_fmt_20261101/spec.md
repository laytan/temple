# Specification: Parameterized Macros (`{% macro %}`) & Format Helper (`{{ fmt(...) }}`)

## Overview

Currently, passing multiple parameters to a reusable UI snippet requires defining a dedicated Odin `struct` and using `{% embed "snippet.html" with My_Struct{...} %}`. Additionally, formatting numbers or custom values with format specifiers (e.g. `%.2f` or `%04d`) requires pre-formatting strings in Odin before rendering. This track adds `{{ fmt(format_str, ..args) }}` (and `{{ raw_fmt(format_str, ..args) }}`) plus parameterized `{% macro name(param: Type, ...) %}...{% end %}` and `{% call name(args...) %}` (or `{{ render_name(args...) }}`) reusable template components.

## Functional Requirements

1. **Formatted Output (`{{ fmt(format_str, ..args) }}`):**
   - Recognize `fmt(format_expr, ..args)` (HTML-escaped formatted output) and `raw_fmt(format_expr, ..args)` (unescaped formatted output via `fmt.wprintf(__temple_w, ...)`).
   - Validate in `validate_and_classify_output_expr` that `fmt(...)` / `raw_fmt(...)` receive at least 1 argument.
2. **Parameterized Macros (`{% macro %}`):**
   - Support defining reusable macros with typed Odin parameters: `{% macro badge(label: string, active := false) %}...{% end %}`.
   - Validate parameter list syntax using `core:odin/parser`.
   - Transpile macros into local Odin procedures accepting `(__temple_w: __temple_io.Writer, <params>) -> (__temple_n: int, __temple_err: __temple_io.Error)` and allow invoking them via `{% call badge("New", true) %}`.

## Acceptance Criteria

- `{{ fmt("$%.2f", this.price) }}` renders HTML-escaped formatted output without heap allocations when backed by stack buffer / writer.
- `{% macro ... %}` definitions compile into type-checked Odin procedures and can be called multiple times within a template or layout hierarchy.
- Invalid macro signatures or call arguments are caught by `core:odin/parser` snippet validation at CLI compile time.
