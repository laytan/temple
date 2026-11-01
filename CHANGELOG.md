# Changelog

All notable changes to `temple` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **Layout Inheritance (`extends`, `block`, `super`):**
  - Added Twig-style layout inheritance via `{% extends "layout.html" %}`, `{% block name %}...{% end %}`, and parent block rendering with `{{ super() }}` or `{% super %}`.
  - Added support for multi-level inheritance chains (`grandchild -> child -> base`), nested blocks inside overridden blocks, and per-node origin tracking so relative `{% embed %}` paths inside inherited blocks resolve relative to the file that declared them.
  - Added cycle detection across `extends` chains and validation for duplicate block definitions, orphan `super()` calls in non-extending templates, and unknown child blocks (listing available parent blocks).
- **Control Flow & Variable Bindings (`switch`, `let`, `else if`, Comments):**
  - Added `{% switch ... %}`, `{% #partial switch ... %}`, and `{% case ... %}` (including default `{% case %}`) with branch-aware `approx_bytes` calculation.
  - Added `{% let x = expr %}`, `{% let x := expr %}`, and typed `{% let x: T = expr %}` local variable bindings inside templates.
  - Added support for two-word `{% else if ... %}` alongside `{% elseif ... %}`.
  - Added template comment tags (`{# ... #}`, `{#- ... -#}`, and `{-# ... #-}`).
- **Whitespace Trimming Markers:**
  - Added leading and trailing whitespace trim markers on output, process, and comment tags (`{{-`, `-}}`, `{%-`, `-%}`, `{#-`, `-#}`, `{-#`, `#-}`).
- **Output Writers (`raw` & `magic`):**
  - Added `{{ raw(expr) }}` for unescaped string output.
  - Added `{{ magic(expr) }}` (`__temple_write_magic_string`) to wrap space-separated words in `<span class="magic-text__word">` elements with HTML-escaped content while preserving boundary and consecutive spaces.
- **Compile-Time Odin AST Validation (`cli/parser.odin`):**
  - Validated all output (`{{ ... }}`), `embed ... with`, `if`/`elseif`, `for`, `switch`/`#partial switch`, `case`, and `let` expressions at template parse time using `core:odin/parser` (`validate_wrapped_stmt`, `validate_and_classify_output_expr`, `validate_let_assignment_expr`), reporting exact template line/column coordinates before Odin codegen.
- **Enhanced Call Collection (`cli/main.odin`):**
  - Added resolution for `import` aliases, procedure aliases (`c :: temple.compiled`), named call arguments (`path = ...`, `T = ...`), and compile-time constant string expressions (including string concatenation `+` and order-independent procedure/block-local constants).
  - Added lexical scope isolation and shadowing checks for mutable variables, procedure parameters, and named return values.
  - Replaced `filepath.glob` directory scanning with `os.open` + `os.read_dir` so route directories containing bracket parameters (e.g. `[id]`, `[slug]`) are discovered and `.`-prefixed hidden directories are skipped.
- **Parallel Compilation & Rich Diagnostics (`cli/main.odin`):**
  - Added multi-threaded worker pool compilation (`transpile_calls`) with per-worker arena allocators and template caches.
  - Added Rust/Odin-style source diagnostics with caret underlines and full `Call_Site -> Extends -> Embed` trace stacks.
  - Added atomic `templates.odin` output generation (`templates.odin.tmp` + `os.rename`) and no-op write skipping when generated code is unchanged.
- **Test Suites (`cli/cli_test.odin`, `cli/regression_test.odin`, `runtime_test.odin`, `tests/templates_test.odin`):**
  - Added unit, regression, deterministic lexer/parser fuzzing, 3-level inheritance, diagnostic coordinate, runtime escaping, and end-to-end rendering test suites.

### Changed
- **Batched HTML Escaping (`runtime.odin`):**
  - Replaced byte-by-byte writes in `__temple_write_escaped_string` with contiguous slice writes between special characters (`&`, `"`, `'`, `<`, `>`).
- **Quote-Aware Tag Lexing (`cli/lexer.odin`):**
  - Updated tag expression scanning (`lexer_consume_tag_expr`) to ignore closing delimiters (`}}`, `-}}`, `%}`, `-%}`) inside double-quoted, single-quoted, and raw backtick string literals, and allowed literal `}}` and `%}` in plain text outside tags.
- **Odin `dev-2026-09` Compatibility & `"contextless"` Support:**
  - Updated `core:os` and `core:path/filepath` calls for Odin `dev-2026-09` APIs (`7125537`).
  - Marked generated `temple.compiled` and `temple.compiled_inline` procedures as `"contextless"` so templates can be instantiated at file/global scope (`5d33d7e`).

### Fixed
- Fixed `{{ raw(...) }}` and `{{ magic(...) }}` argument slicing so nested function calls, indexing, slices, and parenthesized expressions preserve their closing delimiters.
- Fixed `parser_maybe_remove_whitespace` so trailing spaces after text on the same line as a `{%` tag are preserved when the text node spans multiple lines.
- Fixed self-embedding root templates to trigger cycle detection on the first recursive expansion.
- Fixed inline template (`temple.compiled_inline`) diagnostics and intermediate `.Embed`/`.Extends` trace frames to map 1-based template coordinates back to the `.odin` call site's line and column.

---

## [0.1.0] - 2023-09-08

### Added
- Initial experimental Odin template transpiler (`cli/`) and runtime (`runtime.odin`) (`bda19ae`).
- Output tags (`{{ ... }}`) with default XSS HTML escaping and explicit type cast writers (`int()`, `uint()`, `i64()`, `u64()`, `i128()`, `u128()`, `f32()`, `f64()`, `byte()`, `rune()`, `len()`) (`aa4245b`, `601e5b7`).
- Conditional blocks (`{% if %}`, `{% elseif %}`, `{% else %}`, `{% end %}`) (`457fbde`, `6b0795b`, `e525a88`).
- Loop blocks (`{% for ... in ... %}...{% end %}`) (`baa173a`).
- File and inline template compilation (`temple.compiled` and `temple.compiled_inline`) (`c0a3363`).
- Sub-template embedding (`{% embed "path" %}` and `{% embed "path" with expr %}`) (`190d31e`).
- Source-location comments (`/* line:col in template */`) on generated Odin statements and `approx_bytes` output size estimation (`fbec568`).
- MIT License (`6cc7417`).
