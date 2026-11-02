# Changelog

All notable changes to `temple` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.0] - 2026-11-01

### Added
- **Decoupled External Package Codegen & Shared Collection Support (`-out`, `-pkg`, `-temple-import`) (`cli/main.odin`, `cli/transpiler.odin`):**
  - Added `-out:<file>` / `--out=<file>`, `-pkg:<package>` / `--pkg=<package>` (with automatic package name inference from `.odin` files in the output directory and identifier sanitization for directory basenames), and `-temple-import:<path>` / `--temple-import=<path>` (defaulting to `"shared:temple"`) while maintaining full backwards compatibility with legacy 2-argument `<project_dir> <temple_dir>` invocations.
  - Emitted `import __temple "<import_path>"`, file-private `__temple_default :: __temple.__temple_default` alias, and qualified `__temple.Compiled(T)`, `__temple.__temple_write_escaped_string`, `__temple.__temple_write_magic_string`, `__temple.__temple_write_safe_url`, `__temple.__temple_write_url_param`, `__temple.__temple_write_js_string`, `__temple.__temple_write_fmt_escaped`, and `__temple.__temple_write_fmt_raw` when generating outside `package temple`.
  - Updated `collect_compile_calls` to discover unqualified same-package `compiled` / `compiled_inline` calls alongside imported `temple.compiled` / aliased package calls, avoided false-positive constant diagnostics on unrelated third-party `pkg.compiled(...)` calls, and skipped generated template files regardless of filename.
- **Context-Aware Escaping (`url`, `url_param`, `js` / `json`) (`runtime.odin`, `cli/parser.odin`, `cli/transpiler.odin`):**
  - Added `{{ url(expr) }}` / `{{ expr | url }}` (`__temple_write_safe_url`) to validate URL schemes against an explicit safe allowlist (`http`, `https`, `mailto`, `tel`, non-SVG `data:image/*`, and relative URLs), neutralize dangerous or control-char-obfuscated schemes (`javascript:`, `vbscript:`, `data:text/html`, `data:image/svg+xml`) to `#ZgotmplZ`, and HTML-escape the result.
  - Added `{{ url_param(expr) }}` / `{{ expr | url_param }}` (`__temple_write_url_param`) for RFC 3986 percent-encoding of query parameters and URI components.
  - Added `{{ js(expr) }}` / `{{ expr | js }}` and `{{ json(expr) }}` / `{{ expr | json }}` (`__temple_write_js_string`) to escape JavaScript/JSON string contents, control characters, line/paragraph separators (`\u2028`, `\u2029`), and `<`/`>`/`&`/`/` (`\u003c`, `\u003e`, `\u0026`, `\/`) to prevent `</script>` breakout inside inline script blocks.
- **AST-Powered Pipe Filter DSL (`|`), Streaming `fmt(...)`, and `default(...)` (`cli/parser.odin`, `cli/transpiler.odin`, `runtime.odin`):**
  - Added pipe filter syntax (`|`) inside `{{ ... }}` output tags for `raw`, `magic`, `url`, `url_param`, `js`, `json`, `len`, numeric/rune casts (`int`, `uint`, `i64`, `u64`, `i128`, `u128`, `f32`, `f64`, `byte`, `rune`), `fmt(...)`, and `default(...)`.
  - Added zero-allocation streaming formatted output via `{{ fmt(format, ...args) }}`, `{{ expr | fmt(format) }}` (`__temple_write_fmt_escaped`), and `{{ expr | fmt(format) | raw }}` (`__temple_write_fmt_raw`), wrapping the destination `io.Writer` in a stack-allocated `__Temple_Fmt_Writer` stream adapter (`fmt.wprintf`) without `context.temp_allocator` fallback.
  - Added overloaded default fallback expressions via `{{ default(val, fallback) }}` and `{{ val | default(fallback) }}` (`__temple_default` proc group supporting `string`, `$S/[]$E` slices, and `Maybe($T)`).
  - Added compile-time diagnostics for unknown pipe filters, piped `super()`, and invalid filter chains after terminal modifiers.
- **Component-Style Named Props on `embed` (`cli/parser.odin`, `cli/transpiler.odin`):**
  - Added `{% embed "path.html"(name = expr, ...) %}` (and `with (name = expr, ...)`) with field-punning shorthand (`this.field` -> `field = this.field` and `ident` -> `ident = ident`) and duplicate-prop diagnostics.
  - Transpiled component props to temporary local bindings (`__temple_prop_i`) and an inline anonymous `struct` typed via `type_of(__temple_prop_i)`.
- **Parameterized Template Macros (`{% macro %}` & `{% call %}`) (`cli/lexer.odin`, `cli/parser.odin`, `cli/transpiler.odin`, `cli/main.odin`):**
  - Added `{% macro name(params...) %}...{% end %}` with `core:odin/parser` signature validation (supporting typed parameters, default values, variadic parameters, and zero-argument macros) and `{% call name(args...) %}`.
  - Transpiled macros into hoisted local Odin procedures `__temple_macro_<name> :: proc(__temple_w: __temple_io.Writer, <params>) -> (__temple_n: int, __temple_err: __temple_io.Error)`, supported macro inheritance and overrides across `{% extends %}` layouts, validated call target existence/arity/named arguments at compile time, and scoped `macro_approx` byte estimates across `embed` boundaries.
- **Developer Experience & CLI Modes (`--check`, `--warn-unused`, `--watch`) (`cli/main.odin`):**
  - Added `--check` mode for CI pipelines to verify that all templates compile cleanly and the generated `.odin` file on disk matches the freshly transpiled output byte-for-byte without writing to disk.
  - Added `--warn-unused` to scan the project directory and report unreferenced `.temple.twig`, `.temple.html`, and `.twig` template files.
  - Added `--watch` polling mode with resilient non-fatal error recovery across `.odin` call collection and template transpilation, external layout tracking, and automatic skipping of `.`-prefixed, `vendor`, `node_modules`, `build`, `bin`, and `dist` directories.
- **Cross-Platform Path Normalization & GitHub Actions CI (`cli/main.odin`, `.github/workflows/ci.yml`):**
  - Added `normalize_slash_path` to normalize Windows backslash separators (`\`) to canonical forward slashes (`/`) across call collection, relative `extends`/`embed` resolution, unused template detection, and generated `when path == "..."` clauses.
  - Added multi-OS GitHub Actions CI workflow (`.github/workflows/ci.yml`) running unit, ATDD specification, CLI `--check` / `--warn-unused`, and end-to-end integration suites across `ubuntu-latest`, `macos-latest`, and `windows-latest`.
- **4-Layer ATDD Executable Specification Suite (`cli/temple_spec_test.odin`, `cli/spec_dsl_test.odin`, `cli/spec_driver_test.odin`):**
  - Added declarative executable specifications, a domain-specific test language, and an in-memory protocol driver that automatically verifies every compiled template parses as valid Odin AST via `core:odin/parser`.

### Changed
- Coalesced adjacent `Node_Text` AST nodes after layout inheritance (`splice_nodes` and `substitute_super_nodes`) to emit single combined `io.write_string` calls.

## [0.2.0] - 2026-11-01

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

[Unreleased]: https://github.com/boxxxie/temple/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/boxxxie/temple/compare/v0.2.0...v1.0.0
[0.2.0]: https://github.com/boxxxie/temple/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/boxxxie/temple/releases/tag/v0.1.0
