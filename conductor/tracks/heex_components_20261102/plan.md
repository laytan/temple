# Implementation Plan: HEEx-Style Component Tags (`<.component>`), Named Slots (`<:slot>`), and Inline Directives (`:for`, `:if`)

## Phase 1: Lexer & Parser Support for `<.component>`, Props, and Inline `:for` / `:if`

- [ ] Task: Lex and parse self-closing `<.component ... />` and paired `<.component>...</.component>` tags with props
    - [ ] Write 4-layer ATDD specifications in `cli/temple_spec_test.odin` (and DSL helpers in `cli/spec_dsl_test.odin`) for `<.component>` prop forms (`prop={expr}`, `prop="str"`, `active`, `{this.field}`), unclosed/mismatched tags, and duplicate props
    - [ ] Extend `cli/lexer.odin` and `cli/parser.odin` to tokenize and parse `<.component>` tags, attribute lists, and inline `:for={...}` / `:if={...}` directives into AST nodes validated by `core:odin/parser`
- [ ] Task: Resolve `<.component>` to in-scope `{% macro %}` or relative template files (`Node_Embed`)
    - [ ] Write ATDD specifications in `cli/temple_spec_test.odin` covering local macro resolution vs. dotted relative file resolution (`<.ui.card />`) and `--warn-unused` tracking
    - [ ] Implement target resolution in `cli/inheritance.odin` and `cli/collector.odin` (supporting `.temple.html`, `.temple.twig`, `.html`, `.twig` extensions and cycle detection)
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Lexer & Parser Support for <.component>, Props, and Inline :for / :if' (Protocol in workflow.md)

## Phase 2: Default Children, Named Slots (`<:slot>` / `{% slot %}`), and Lexical `this` Scope Hygiene

- [ ] Task: Parse `{% slot %}` declarations and caller `<:slot_name>...</:slot_name>` blocks
    - [ ] Write ATDD specifications in `cli/temple_spec_test.odin` for default children slots, named `<:slot>` blocks, fallback slot content, and unknown/duplicate slot diagnostics
    - [ ] Add `.Slot` token and `Node_Slot` AST support in `cli/lexer.odin` and `cli/parser.odin`, plus `<:name>...</:name>` child partitioning on paired `<.component>` nodes
- [ ] Task: Compile-time slot splicing with caller `this` scope preservation and `approx_bytes` estimation
    - [ ] Write ATDD and e2e tests in `cli/temple_spec_test.odin` and `tests/templates_test.odin` verifying caller `this` access inside slots, nested `<.component>` composition, and `approx_bytes` calculation
    - [ ] Implement compile-time slot splicing and `__temple_parent_this_<depth>` scope restoration in `cli/inheritance.odin` and `cli/transpiler.odin`
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Default Children, Named Slots (<:slot> / {% slot %}), and Lexical this Scope Hygiene' (Protocol in workflow.md)
