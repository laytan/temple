# Implementation Plan: Parameterized Macros & Format Helper

## Phase 1: Formatted Output (`{{ fmt(...) }}` & `{{ raw_fmt(...) }}`)

- [ ] Task: Add runtime and transpiler support for `{{ fmt(format_str, ..args) }}` and `{{ raw_fmt(format_str, ..args) }}`
    - [ ] Write unit tests in `runtime_test.odin` and `cli/regression_test.odin` for `fmt(...)` and `raw_fmt(...)` validation and escaping
    - [ ] Implement `__temple_write_fmt` in `runtime.odin` and `Fmt` / `Raw_Fmt` classification in `cli/parser.odin` and `cli/transpiler.odin`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Formatted Output ({{ fmt(...) }} & {{ raw_fmt(...) }})' (Protocol in workflow.md)

## Phase 2: Parameterized Template Macros (`{% macro %}` & `{% call %}`)

- [ ] Task: Lex and parse `{% macro name(params...) %}...{% end %}` and `{% call name(args...) %}`
    - [ ] Write lexer and parser unit tests in `cli/regression_test.odin` for valid and invalid `macro` / `call` declarations
    - [ ] Add `.Macro` and `.Call` tokens in `cli/lexer.odin` and `Node_Macro` / `Node_Call` AST nodes + Odin signature validation in `cli/parser.odin`
- [ ] Task: Transpile `Node_Macro` and `Node_Call` and support macros across layout inheritance
    - [ ] Write transpiler and e2e tests in `cli/regression_test.odin` and `tests/templates_test.odin`
    - [ ] Implement `transpile_macro` and `transpile_call` in `cli/transpiler.odin` and update AST traversal helpers in `cli/main.odin`
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Parameterized Template Macros ({% macro %} & {% call %})' (Protocol in workflow.md)
