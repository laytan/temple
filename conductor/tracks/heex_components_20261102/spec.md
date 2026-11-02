# Specification: HEEx-Style Component Tags (`<.component>`), Named Slots (`<:slot>`), and Inline Directives (`:for`, `:if`)

## Overview

While Temple already supports component-style named props on `{% embed "card.html"(title = this.title, active = true) %}` and parameterized in-file `{% macro %}` / `{% call %}`, authoring deeply nested UI compositions with Twig block tags can be verbose and lacks ergonomic slot passing for inner markup.

This track introduces Phoenix LiveView HEEx-inspired **`<.component>`** tags, **`<:slot>`** named slots, **`{% slot %}`** targets, and inline **`:for` / `:if`** component directives—compiled 100% ahead-of-time into zero-allocation, `"contextless"` Odin streaming code without constructing runtime DOM trees or closures.

## Functional Requirements

1. **Component Tag Lexing & Parsing (`<.name ... />` and `<.name ...>...</.name>`):**
   - Recognize `<.ident>` (and dotted paths like `<.ui.card>` / `<.components.modal>`) and closing `</.ident>` tags outside of `{{ ... }}` / `{% ... %}` while leaving standard HTML elements (`<div>`, `<script>`, etc.) untouched as raw `.Text` tokens.
   - Support both self-closing `<.card ... />` and paired `<.card ...>...</.card>` tags with exact tag-name matching and line/column diagnostics on unclosed or mismatched closing tags.

2. **Component Prop & Attribute Syntax:**
   - **Braced Odin expressions:** `prop={expr}` (validated via `core:odin/parser`, supporting nested braces/strings inside `expr`).
   - **Quoted string literals:** `prop="static text"` (and single-quoted `'...'`).
   - **Bare boolean attributes:** `active` / `disabled` (desugaring to `active = true`).
   - **Shorthand field punning:** `{this.title}` or `{title}` (desugaring to `title = this.title` / `title = title`).
   - Reject duplicate prop names with exact caret diagnostics.

3. **Target Resolution (Local Macro First, Relative Template File Fallback):**
   - **Macro resolution:** If an in-scope `{% macro name(...) %}` matches a single-segment `<.name ... />`, resolve to a macro call (`Node_Call`), mapping positional/named props to the macro's signature.
   - **File resolution (`Node_Embed`):** Otherwise, map dotted segments (`<.ui.card>` -> `ui/card`) and resolve relative to the current template directory (checking `.temple.html`, `.temple.twig`, `.html`, `.twig` extensions) with full `Call_Site -> Extends -> Embed` trace stack and cycle detection.

4. **Default Children & Named Slots (`<:slot>` and `{% slot %}`):**
   - **Target slot declaration:** Support `{% slot %}Fallback content{% end %}` (default children slot) and `{% slot header %}Fallback header{% end %}` (named slot) inside component templates.
   - **Caller slot passing:**
     - Direct inner nodes inside `<.card>...</.card>` populate the default `{% slot %}`.
     - `<:header>...</:header>` tags inside `<.card>...</.card>` populate the corresponding named `{% slot header %}`.
   - **Lexical `this` Scope Hygiene (Zero-Allocation Splicing):**
     - Expressions inside the component file evaluate against the component's synthesized `this` prop struct.
     - Expressions inside caller-provided default children and `<:slot>` bodies evaluate against the **caller's** `this` (and caller loop/let bindings) by saving `__temple_parent_this_<depth> := this` before shadowing `this` in the component block and restoring `this := __temple_parent_this_<depth>` inside spliced slot bodies.
     - Preserve adjacent static text coalescing and static `approx_bytes` accumulation across spliced slots.

5. **Inline Component Directives (`:for` and `:if`):**
   - Support `:for={item, i in this.items}` and `:if={item.visible}` on `<.component>` tags.
   - When both `:for` and `:if` are present on the same component tag, wrap the component expansion in `Node_For` outside `Node_If` (so `:if` can reference loop variables bound by `:for`).

## Non-Functional Requirements

- **Zero Runtime Allocations:** Component expansion and slot splicing must happen completely at compile time; generated code remains `"contextless"` with 0 allocations/op.
- **Zero Memory Leaks:** All compiler arenas and test runs under `odin test`'s tracking allocator must report 0 leaks.
- **Unused Template Tracking:** Files referenced via `<.component>` must be registered in `ctx.used_files` so `--warn-unused` accurately recognizes them as used.

## Acceptance Criteria

- Self-closing `<.card {this.title} count={len(this.items)} active />` and paired `<.card>...</.card>` with `<:header>` named slots compile into valid, zero-allocation Odin code verified by `core:odin/parser`.
- Caller expressions inside slot bodies access the caller's `this` context rather than the component's prop `this` struct.
- Inline `:for` and `:if` directives on `<.component>` desugar cleanly into loops and conditionals.
- 4-layer ATDD specs (`cli/temple_spec_test.odin`), CLI unit tests (`cli/cli_test.odin`), and e2e tests (`tests/templates_test.odin`) pass with zero memory leaks.
