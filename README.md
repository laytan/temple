# Temple

[![CI](https://github.com/boxxxie/temple/actions/workflows/ci.yml/badge.svg)](https://github.com/boxxxie/temple/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-v1.0.0-blue.svg)](CHANGELOG.md)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09%2B-3882D2.svg)](https://odin-lang.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A fast, zero-overhead, compile-time HTML templating engine for [Odin](https://odin-lang.org) that transpiles Twig/Mustache-inspired templates directly into native Odin procedures.

## Features

### Zero-Overhead Native Codegen
* **Compile-time transpilation** — Templates compile down to plain `"contextless"` Odin procedures (`proc(w: io.Writer, this: T)`). There is no runtime template parser, AST interpreter, reflection, or heap allocation during rendering.
* **Single self-contained binary** — Template files are only needed at build time; nothing extra to ship or load at runtime.
* **Compile-time `fmt` strength reduction** — Single-argument `fmt("%s")`, `fmt("%i")` / `fmt("%d")`, and `fmt("%.Nf")` expressions are decomposed at compile time into static string writes (coalesced with adjacent HTML) and direct stack-buffered numeric writers (`__temple_write_int`, `__temple_write_f64_prec`).
* **Precomputed buffer sizing (`approx_bytes`)** — Static output size estimation across text, loops, `if`/`switch` branches, macros, and `embed` trees lets callers pre-allocate output buffers in a single allocation or reuse a buffer with **0 allocations/op**.

### Context-Aware Security by Default
* **Automatic HTML XSS escaping** — `{{ expr }}` escapes `&`, `"`, `'`, `<`, and `>` by default using lookup-table fast paths and stack-batched slice writes (~3.8 GB/s on clean HTML, 0 allocations).
* **URL & query parameter sanitization** — `url` validates URL schemes against an explicit safe allowlist (`http`, `https`, `mailto`, `tel`, non-SVG `data:image/*`, and relative paths) and neutralizes dangerous schemes (`javascript:`, `vbscript:`, `data:text/html`) to `#ZgotmplZ`; `url_param` performs RFC 3986 percent-encoding.
* **JavaScript & JSON string escaping** — `js` / `json` escapes quotes, control characters, line separators (`\u2028`, `\u2029`), and `<`/`>`/`&`/`/` to prevent `</script>` and quote breakout inside `<script>` blocks.
* **Explicit raw & word-span writers** — Opt out of escaping for trusted markup with `raw`, or wrap space-separated words in `<span class="magic-text__word">` elements with `magic`.

### Expressive Template Syntax & Composition
* **Full Odin expressions** — Any valid Odin expression (`or_else`, ternary `if`/`else`, slice ranges, selectors) works inside tags and is validated at compile time by `core:odin/parser`.
* **Pipe filter DSL (`|`)** — Chain `default(...)` fallbacks, zero-allocation streaming `fmt(...)`, type casts (`int`, `f64`, `len`, etc.), and escapers (`{{ this.price | fmt("$%.2f") }}`, `{{ this.name | default("Anonymous") }}`).
* **Control flow & local bindings** — Conditionals (`{% if %}`, `{% elseif %}` / `{% else if %}`, `{% else %}`), pattern-matching switches (`{% switch %}`, `{% #partial switch %}`, `{% case %}`), Odin loops (`{% for item, idx in this.items %}`), and local variable bindings (`{% let x = expr %}`).
* **Layouts, components & macros** — Multi-level layout inheritance (`{% extends %}`, `{% block %}`, `{{ super() }}`), sub-template embedding with `with` or component-style named props (`{% embed "card.html"(this.title, active = true) %}`), and reusable typed macros (`{% macro %}` / `{% call %}`).
* **Whitespace control & comments** — Strip leading or trailing whitespace around any tag with hyphens (`{{-`, `-}}`, `{%-`, `-%}`, `{#-`, `-#}`) and strip template comments (`{# ... #}`) at compile time.

### Fast Compiler CLI & Developer Tooling
* **Multi-threaded compiler pipeline** — Parallel worker pool with per-worker arena allocators, unified AST slab allocation, cached layout splicing, and zero-allocation codegen.
* **Rich source diagnostics** — Rust/Odin-style error reporting with source snippets, caret underlines, and full `Call_Site -> Extends -> Embed` trace stacks.
* **Flexible workflow modes** — External package codegen (`-out`, `-pkg`, `-temple-import`), CI verification (`--check`), orphan template detection (`--warn-unused`), and incremental file watching (`--watch`).

---

## Quick Start

Temple consists of two parts: the compiler CLI (`cli/`) and a lightweight runtime package (`runtime.odin`). The CLI scans your Odin project for `compiled` and `compiled_inline` calls (including package/local string constants and procedure aliases) and generates the backing Odin procedures.

### Option A: Shared Collection / External Package Mode (`-out` / `-pkg`)

Install `temple` once into Odin's `shared:` collection (or as a dependency) and generate template procedures directly into your own package:

```sh
# 1. Build the compiler CLI
odin build temple/cli -o:speed -out:temple_cli

# 2. Generate templates into your package before building
./temple_cli src -out:src/views/templates_gen.odin -pkg:views
```

| Flag | Description |
| :--- | :--- |
| `-out:<file>` / `--out=<file>` | Destination `.odin` file to generate |
| `-pkg:<package>` / `--pkg=<package>` | Target package name (if omitted, automatically inferred from existing `.odin` files in the output directory) |
| `-temple-import:<path>` / `--temple-import=<path>` | Import path for the `temple` runtime library (defaults to `"shared:temple"` when generating outside `package temple`) |
| `--check` | Verify all templates compile cleanly and the generated `.odin` file on disk is up-to-date without modifying disk (exits `1` if missing or stale) |
| `--warn-unused` | Emit warnings for any `.temple.twig`, `.temple.html`, or `.twig` files in the project directory never referenced by `compiled`, `extends`, or `embed` |
| `--watch` | Poll `.odin` and template files for changes and incrementally re-run compilation during development |
| `--version` / `-v` | Print the compiler version |

### Option B: Vendored Submodule Mode

```sh
# 1. Add temple as a submodule
git submodule add https://github.com/laytan/temple

# 2. Build the compiler CLI
odin build temple/cli -o:speed -out:temple_cli

# 3. Generate temple/templates.odin (first arg: project root, second arg: temple directory)
./temple_cli . temple
```

### Example

Ending template filenames with `.temple.twig` or `.temple.html` is recommended for editor Twig/HTML syntax highlighting.

```twig
<!-- templates/home.temple.twig -->

Hello, {{ this.name }}!

{% if this.name == "Laytan" %}Cool Name!{% end %}

<!-- Cast or pipe non-string values (int, i64, f32, f64, byte, rune, len, etc.) -->
The count is {{ int(this.count) }}

{% for i in 1..=5 %}{{ int(i) }}{% end %}
```

```odin
package main

import "core:os"
import "temple"

Home_This :: struct {
	name:  string,
	count: int,
}

home := temple.compiled("templates/home.temple.twig", Home_This)

// Or inline templates:
// home := temple.compiled_inline(`Hello, {{ this.name }}`, Home_This)

main :: proc() {
	w := os.to_stream(os.stdout)
	_, _ = home.with(w, {"Laytan", 10})
}
```

Running `temple_cli` generates the following zero-overhead Odin code:

```odin
package temple

import __temple_io "core:io"

compiled :: proc "contextless" ($path: string, $T: typeid) -> Compiled(T) {
	when path == "templates/home.temple.twig" {
		return {
			with = proc(__temple_w: __temple_io.Writer, this: T) -> (__temple_n: int, __temple_err: __temple_io.Error) {
				__temple_n += __temple_io.write_string(__temple_w, "<!-- templates/home.temple.twig -->\n\nHello, ") or_return /* 1:1 in template */
				__temple_n += __temple_write_escaped_string(__temple_w, this.name) or_return /* 3:8 in template */
				__temple_n += __temple_io.write_string(__temple_w, "!\n") or_return /* 3:23 in template */
				if this.name == "Laytan" { /* 5:1 in template */
					__temple_n += __temple_io.write_string(__temple_w, "Cool Name!") or_return /* 5:31 in template */
				}
				__temple_n += __temple_io.write_string(__temple_w, "\n\n<!-- Cast or pipe non-string values (int, i64, f32, f64, byte, rune, len, etc.) -->\nThe count is ") or_return /* 5:50 in template */
				__temple_n += __temple_write_int(__temple_w, int(this.count)) or_return /* 8:14 in template */
				__temple_n += __temple_io.write_string(__temple_w, "\n") or_return /* 8:35 in template */
				for i in 1..=5 { /* 10:1 in template */
					__temple_n += __temple_write_int(__temple_w, int(i)) or_return /* 10:21 in template */
				}
				__temple_n += __temple_io.write_string(__temple_w, "\n") or_return /* 10:42 in template */
				return
			},
			approx_bytes = 197,
		}
	} else {
		#panic("undefined template \"" + path + "\" did you run the temple transpiler?")
	}
}
```

---

## Template Syntax Reference

### Output (`{{ ... }}`), Pipe Filters (`|`), and Type Writers

Output tags `{{ ... }}` evaluate any Odin expression and HTML-escape strings by default. Modifiers can be applied using either pipe syntax (`{{ expr | filter }}`) or call syntax (`{{ filter(expr) }}`):

| Filter / Writer | Pipe Syntax | Call Syntax | Behavior |
| :--- | :--- | :--- | :--- |
| **HTML (default)** | `{{ this.name }}` | `{{ this.name }}` | Escapes `&`, `"`, `'`, `<`, `>` |
| **`raw`** | `{{ this.html \| raw }}` | `{{ raw(this.html) }}` | Writes trusted string without escaping |
| **`url`** | `{{ this.href \| url }}` | `{{ url(this.href) }}` | Validates safe URL scheme (`http`, `https`, `mailto`, `tel`, safe `data:image/*`, relative) or writes `#ZgotmplZ`, then HTML-escapes |
| **`url_param`** | `{{ this.q \| url_param }}` | `{{ url_param(this.q) }}` | RFC 3986 percent-encodes query parameter values (`%XX`) |
| **`js` / `json`** | `{{ this.data \| js }}` | `{{ js(this.data) }}` | Escapes quotes, control chars, `\u2028`/`\u2029`, and `<`/`>`/`&`/`/` for JS/JSON string literals |
| **`magic`** | `{{ this.text \| magic }}` | `{{ magic(this.text) }}` | Wraps each word in `<span class="magic-text__word">...</span>` (HTML-escaped) |
| **`default`** | `{{ this.val \| default(fb) }}` | `{{ default(this.val, fb) }}` | Fallback when a `string` or slice `[]T` is empty, or when `Maybe(T)` is `nil` |
| **`fmt`** | `{{ this.val \| fmt("%.2f") }}` | `{{ fmt("%s (%i)", a, b) }}` | Zero-allocation formatted output (HTML-escaped by default; chain `\| raw` for unescaped) |
| **`len`** | `{{ this.items \| len }}` | `{{ len(this.items) }}` | Writes `len(expr)` as a base-10 integer |
| **Type casts** | `{{ this.n \| int }}` | `{{ int(this.n) }}` | Direct numeric/character writers for `int`, `uint`, `i64`, `u64`, `i128`, `u128`, `f32`, `f64`, `byte`, `rune` |

```odin
// Full Odin expressions (e.g. Maybe unwrap with or_else, ternary conditionals):
t := temple.compiled_inline(`{{ this.name.? or_else this.last_name }}`, struct{ name: Maybe(string), last_name: string })

// Context-aware URL, query param, and inline <script> escaping:
t := temple.compiled_inline(`<a href="{{ this.link | default("/home") | url }}?q={{ this.query | url_param }}">Link</a>`, Link_Ctx)
t := temple.compiled_inline(`<script>const msg = "{{ this.payload | js }}";</script>`, Script_Ctx)

// Formatted output (single-arg %s, %i, %d, %.Nf are strength-reduced at compile time; multi-arg streams with 0 allocations):
t := temple.compiled_inline(`{{ this.price | fmt("$%.2f") }}`, struct{ price: f64 })
t := temple.compiled_inline(`{{ fmt("%s (%i)", this.name, this.count) }}`, struct{ name: string, count: int })
t := temple.compiled_inline(`{{ this.price | fmt("<b>$%.2f</b>") | raw }}`, struct{ price: f64 })
```

### Conditionals (`if` / `else if` / `elseif` / `else`)

```odin
t := temple.compiled_inline(`
{% if this.count == 0 %}
    There are no items in your basket.
{% else if this.count == 1 %}
    There is one item in your basket.
{% elseif this.count > 100 %}
    There are too many items in your basket.
{% else %}
    There are {{ int(this.count) }} items in your basket.
{% end %}
`, struct{ count: int })
```

### Pattern Matching (`switch` & `#partial switch`)

Supports Odin value switches, type switches (`switch v in this.payload`), and enum `#partial switch`:

```odin
t := temple.compiled_inline(`
{% #partial switch this.status %}
    {% case .Loading %}
        <span>Loading...</span>
    {% case .Ready %}
        <span>Ready!</span>
    {% case %}
        <span>Idle</span>
{% end %}
`, Page_Ctx)
```

### Local Variable Bindings (`let`)

Bind local variables inside templates using `=`, `:=`, or explicit `: Type =`:

```odin
t := temple.compiled_inline(`
{% let total = this.price * this.qty %}
{% let label: string = "Total" %}
<span>{{ label }}: {{ int(total) }}</span>
`, Order_Ctx)
```

### Loops (`for`)

Any valid Odin `for` loop clause works:

```odin
t := temple.compiled_inline(`{% for i in 0..<5 %} {{ int(i) }} {% end %}`, struct{})
t := temple.compiled_inline(`{% for book, idx in this.books %} {{ int(idx) }}: {{ book.title }} {% end %}`, Library_Ctx)
```

### Layout Inheritance (`extends`, `block`, `super`)

Child templates can extend a parent layout (including multi-level inheritance chains), override named `{% block %}` sections, and render parent block content via `{{ super() }}` or `{% super %}`:

```twig
{# layouts/base.html #}
<!DOCTYPE html>
<html>
<head>
    <title>{% block title %}My Site{% end %}</title>
</head>
<body>
    {% block content %}Default content{% end %}
</body>
</html>
```

```twig
{# pages/home.html #}
{% extends "../layouts/base.html" %}

{% block title %}{{ super() }} - Home{% end %}

{% block content %}
    <main>Welcome, {{ this.user }}!</main>
{% end %}
```

### Sub-Template Embedding & Component Props (`embed`)

Embed sub-templates with the current `this`, narrow context via `with`, or pass component-style named props (supporting field-punning shorthand like `this.title` -> `title = this.title`):

```odin
// Inherit current `this`:
t := temple.compiled_inline(`{% embed "header.temple.twig" %}`, Page_Ctx)

// Pass a sub-struct as `this`:
t := temple.compiled_inline(`{% embed "header.temple.twig" with this.header %}`, struct{ header: Header_Data })

// Pass component-style named props (synthesizes an inline typed struct for `this`):
t := temple.compiled_inline(`
{% embed "components/card.html"(
    this.title,
    count = len(this.items),
    theme = "dark",
) %}
`, Page_Ctx)
```

### Parameterized Macros (`macro` & `call`)

> **Note:** Each `{% macro %}` compiles to a hoisted non-capturing local Odin procedure (`proc`), so values from `this` or outer `{% let %}` bindings must be passed explicitly as macro parameters.

```twig
{% macro badge(label: string, active := false) %}
  <span class="badge {% if active %}badge--active{% end %}">{{ label }}</span>
{% end %}

{% call badge(this.title, true) %}
{% call badge("Draft") %}
```

### Comments & Whitespace Trimming

```twig
{# Comments are stripped completely from generated output #}
{#- Add hyphens to opening or closing delimiters to strip adjacent whitespace/newlines -#}
<div>
  {%- if this.show -%}
    <span>{{- this.label -}}</span>
  {%- end -%}
</div>
```

---

## Performance & Benchmarks

Temple's runtime and compiler pipeline are heavily optimized for zero-allocation execution and high throughput. See [`benchmarks/README.md`](benchmarks/README.md) for the full benchmark suite, methodology, and architectural breakdown.

| Benchmark (`-o:speed`) | Time | Throughput | Allocs/op |
| :--- | ---: | ---: | ---: |
| `html_escape (clean 64KB doc)` | 16.3 µs | ~3,838 MB/s | 0 |
| `html_escape (mixed XSS 64KB doc)` | 68.6 µs | ~911 MB/s | 0 |
| `safe_url (valid https URL)` | 37.7 ns | ~1,038 MB/s | 0 |
| `write_int + write_f64_prec (direct fast writers)` | 38.3 ns | ~622 MB/s | 0 |
| `fmt("%s" / "%i") (compile-time strength reduced)` | 37.2 ns | ~1,564 MB/s | 0 |
| `compiled_inline (card, reused buf)` | 50.7 ns | ~1,654 MB/s | 0 |
| `compiled (50-row dashboard, 15.3 KB HTML, reused buf)` | 11.0 µs | ~1,326 MB/s | 0 |
| `cli: lexer tokenize (dashboard.temple.html)` | 2.58 µs | ~448 MB/s | 0 |
| `cli: pure transpile codegen (5.5 KB Odin code)` | 3.86 µs | ~1,357 MB/s | 0 |
| `cli: full parse + inheritance + transpile` | 14.8 µs | ~121 MB/s | 32 |

```sh
# Run the full benchmark suite
odin run benchmarks -o:speed
```
