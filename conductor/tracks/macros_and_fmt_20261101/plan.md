# Implementation Plan: AST Pipe DSL, Component `embed` Props & Parameterized Macros

## Phase 1: AST Pipe Filter DSL (`|`, `fmt`, `default`), Component `embed` Props & 4-Layer ATDD Suite

- [x] Task: Add runtime and transpiler support for `{{ fmt(...) }}`, pipe filters (`|`), and `default(...)`
    - [x] Write unit tests in `runtime_test.odin` (including 512-byte UTF-8 boundary overflow test) and ATDD executable specifications in `cli/temple_spec_test.odin`
    - [x] Implement `__temple_write_fmt_escaped` and `__temple_write_fmt_raw` in `runtime.odin` and `classify_output_ast` (`Fmt_Escaped`, `Fmt_Raw`, pipe chain validation, trailing-comma stripping) in `cli/parser.odin` and `cli/transpiler.odin`
- [x] Task: Add component-style named `embed` props (`{% embed "card.html"(this.title, count = 1) %}`) and 4-Layer ATDD architecture
    - [x] Implement `Embed_Prop`, `parse_embed_props_expr`, and `try_parse_embed_props` in `cli/parser.odin` plus anonymous struct `this` binding via `type_of(__temple_prop_i)` in `cli/transpiler.odin`
    - [x] Create 4-layer ATDD suite (`cli/temple_spec_test.odin`, `cli/spec_dsl_test.odin`, `cli/spec_driver_test.odin`) with automatic generated-Odin AST verification
- [x] Task: Conductor - User Manual Verification 'Phase 1: AST Pipe Filter DSL (|, fmt, default), Component embed Props & 4-Layer ATDD Suite' (Protocol in workflow.md)

## Phase 2: Parameterized Template Macros (`{% macro %}` & `{% call %}`)

- [x] Task: Lex and parse `{% macro name(params...) %}...{% end %}` and `{% call name(args...) %}`
    - [x] Write ATDD specifications in `cli/temple_spec_test.odin` for valid and invalid `macro` / `call` declarations
    - [x] Add `.Macro` and `.Call` tokens in `cli/lexer.odin` and `Node_Macro` / `Node_Call` AST nodes + Odin signature validation in `cli/parser.odin`
- [x] Task: Transpile `Node_Macro` and `Node_Call` and support macros across layout inheritance
    - [x] Write transpiler and e2e specs in `cli/temple_spec_test.odin` and `tests/templates_test.odin`
    - [x] Implement `transpile_macro` and `transpile_call` in `cli/transpiler.odin` and update AST traversal helpers in `cli/main.odin`
- [x] Task: Conductor - User Manual Verification 'Phase 2: Parameterized Template Macros ({% macro %} & {% call %})' (Protocol in workflow.md)
