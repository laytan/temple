# Specification: AST Pipe DSL (`|`, `fmt`, `default`), Component `embed` Props & Parameterized Macros (`{% macro %}`)

## Overview

Passing multiple parameters to a reusable UI partial previously required defining a dedicated Odin `struct` and using `{% embed "snippet.html" with My_Struct{...} %}`, and formatting numbers or fallback values required pre-formatting strings in Odin before rendering. This track adds:
1. An **AST-powered Output Expression & Pipe Filter DSL** (`|`, `fmt(...)`, `default(...)`) built directly on `core:odin/parser`.
2. **Component-Style Named `embed` Props** (`{% embed "card.html"(this.title, count = len(this.items), active = true) %}`) with field-punning shorthand and anonymous `struct` construction via `type_of(...)`.
3. A **4-Layer ATDD Executable Specification Suite** (`cli/temple_spec_test.odin`, `cli/spec_dsl_test.odin`, `cli/spec_driver_test.odin`).
4. In-file **Parameterized Macros** (`{% macro name(param: Type, ...) %}...{% end %}` and `{% call name(args...) %}`).

## Functional Requirements

1. **AST Pipe Filter DSL, `fmt(...)`, and `default(...)` (`cli/parser.odin`, `cli/transpiler.odin`, `runtime.odin`):**
   - Support left-associative pipe chains (`|`, parsed as `^ast.Binary_Expr` with `op.kind == .Or`) in `classify_output_ast`: `{{ this.body | raw }}`, `{{ this.headline | magic }}`, `{{ this.items | len }}`, `{{ this.val | int }}` (and other numeric/rune casts).
   - Support stack-buffered formatted output via `{{ fmt(format_str, ..args) }}`, `{{ this.price | fmt("$%.2f") }}` (`.Fmt_Escaped` -> `__temple_write_fmt_escaped`), and `{{ this.price | fmt("<b>$%.2f</b>") | raw }}` (`.Fmt_Raw` -> `__temple_write_fmt_raw`), falling back to `fmt.tprintf` when `len(formatted) >= len(buf) - 4` to preserve multi-byte UTF-8 runes at the 512-byte boundary.
   - Support default fallback expressions via `{{ default(val, fallback) }}` and `{{ val | default(fallback) }}`, emitting `((val) if len(val) > 0 else (fallback))`.
   - Reject unknown pipe filters, disallow piping `super()`, disallow chaining filters after terminal modifiers (except `fmt(...) | raw`), and strip trailing commas in argument slices.
2. **Component-Style Named Props on `embed` (`cli/parser.odin`, `cli/transpiler.odin`):**
   - Support `{% embed "card.html"(title = this.title, count = len(this.items), active = true) %}` (and `with (...)`) as well as identifier/selector shorthand punning (`this.title` -> `title = this.title`, `title` -> `title = title`).
   - Reject empty prop lists and duplicate prop names with exact line/column diagnostics.
   - Transpile props by binding `__temple_prop_i := <expr>` before shadowing `this` with an inline anonymous `struct` typed via `type_of(__temple_prop_i)`.
3. **Parameterized In-File Macros (`{% macro %}`):**
   - Support defining reusable in-file macros with typed Odin parameters: `{% macro badge(label: string, active := false) %}...{% end %}`.
   - Validate parameter list syntax using `core:odin/parser`.
   - Transpile macros into local Odin procedures accepting `(__temple_w: __temple_io.Writer, <params>) -> (__temple_n: int, __temple_err: __temple_io.Error)` and allow invoking them via `{% call badge("New", true) %}`.

## Acceptance Criteria

- `{{ fmt("$%.2f", this.price) }}` and `{{ this.price | fmt("$%.2f") }}` render HTML-escaped formatted output without heap allocations for strings under 508 bytes and preserve multi-byte UTF-8 runes across the 512-byte buffer boundary.
- Component-style `{% embed "card.html"(...) %}` props support named arguments, untyped literals, and shorthand punning while rejecting duplicate prop names.
- Every positive compilation specification in the 4-layer ATDD suite verifies that generated Odin code parses with zero AST errors.
- `{% macro ... %}` definitions compile into type-checked Odin procedures and can be called multiple times within a template or layout hierarchy.
