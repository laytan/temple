# temple Usage Rules & Agent Guide

This guide provides prescriptive rules, integration mode selection criteria, canonical recipes, and anti-patterns for using `temple` in Odin projects.

---

## Core Mental Model & Invariants

* **Ahead-of-Time Native Transpilation**: `temple` has no runtime template loader, AST interpreter, or reflection. The `temple_cli` compiler scans Odin source files for `compiled` and `compiled_inline` call sites, parses and validates referenced templates at build time, and generates plain Odin writer procedures (`with = proc(w: io.Writer, this: T) -> (n: int, err: io.Error)`).
* **File-Scope `"contextless"` Descriptors**: `compiled` and `compiled_inline` are generated as `proc "contextless" ($path: string, $T: typeid) -> Compiled(T)` using compile-time `when path == "..."` dispatch. Templates can be bound directly to package-level globals or inside `"contextless"` procedures with zero runtime initialization cost.
* **Zero-Allocation Rendering & `approx_bytes`**: Every `Compiled(T)` carries a statically computed `approx_bytes` estimate across static text, conditionals, loops, macros, and embedded partials. Pre-sizing a `strings.Builder` via `strings.builder_make(0, tmpl.approx_bytes, allocator)` or reusing a buffer yields **0 allocations/op**.
* **Context-Aware Security by Default**: Output tags `{{ expr }}` and `{{ expr | fmt(...) }}` HTML-escape `&`, `"`, `'`, `<`, and `>` by default. Non-string values (`int`, `f64`, `rune`, etc.) must be explicitly cast (`{{ int(this.count) }}`), piped (`{{ this.items | len }}`), or formatted (`{{ this.price | fmt("$%.2f") }}`).
* **Compile-Time `fmt` Strength Reduction**: Single-argument `fmt("%s")`, `fmt("%i")` / `fmt("%d")`, and `fmt("%.Nf")` expressions are decomposed at compile time into coalesced static string writes and direct stack-buffered numeric writers (`__temple_write_int`, `__temple_write_f64_prec`), bypassing `core:fmt` at runtime.

---

## Decision Tree: Integration Mode & Template Composition

* **External Package Codegen (`-out:<file> -pkg:<pkg> -temple-import:<path>`)**: Use when `temple` is installed in `shared:temple` or vendored under a `deps/` directory. Emits `compiled` and `compiled_inline` directly into your own package (for example, `views/templates_gen.odin`) while importing runtime writers from `temple`.
* **Vendored In-Place Mode (`temple_cli <project_dir> <temple_dir>`)**: Use when each project owns a dedicated mutable copy of the `temple` directory and imports it directly as `package temple` (generates `<temple_dir>/templates.odin`).
* **`compiled("path.temple.twig", T)` vs. `compiled_inline("...", T)`**: Use `compiled` for file-backed pages, layouts, and partials (paths are resolved relative to the calling `.odin` file's directory); use `compiled_inline` for self-contained components, tests, or small inline fragments.
* **`{% extends %}` / `{% block %}` vs. `{% embed %}` vs. `{% macro %}`**:
  * **Layout Inheritance (`{% extends "base.temple.twig" %}` + `{% block name %}`)**: Use for page shells where a child template overrides named blocks of a parent layout and optionally invokes `{{ super() }}` or `{% super %}`.
  * **Sub-Template Embedding (`{% embed "card.temple.twig" %}`)**: Use to compose separate template files using the current `this`, a narrowed sub-expression (`with this.card`), or component-style named props (`{% embed "card.temple.twig"(this.title, active = true) %}`).
  * **Parameterized Macros (`{% macro name(...) %}` + `{% call name(...) %}`)**: Use for reusable, strongly-typed UI snippets that compile to hoisted non-capturing local Odin procedures (`proc`).

---

## Output Filters, Type Writers & Escaping Modes

Modifiers can be written using pipe syntax (`{{ expr | filter }}`) or call syntax (`{{ filter(expr) }}`). `default(...)` can be chained before any writer or cast (`{{ this.title | default("Untitled") }}`), and `| raw` can be chained after `fmt(...)`.

| Filter / Writer | Pipe Syntax | Call Syntax | Input Type | Runtime Lowering & Security Behavior |
| :--- | :--- | :--- | :--- | :--- |
| **HTML (default)** | `{{ this.name }}` | `{{ this.name }}` | `string` | `__temple_write_escaped_string`: escapes `&`, `"`, `'`, `<`, `>` |
| **`raw`** | `{{ this.html \| raw }}` | `{{ raw(this.html) }}` | `string` | `io.write_string`: writes trusted markup without escaping |
| **`url`** | `{{ this.href \| url }}` | `{{ url(this.href) }}` | `string` | `__temple_write_safe_url`: allows `http`, `https`, `mailto`, `tel`, safe `data:image/*`, and relative paths; neutralizes unsafe schemes to `#ZgotmplZ` and HTML-escapes |
| **`url_param`** | `{{ this.q \| url_param }}` | `{{ url_param(this.q) }}` | `string` | `__temple_write_url_param`: RFC 3986 percent-encodes non-unreserved bytes (`%XX`) |
| **`js` / `json`** | `{{ this.data \| js }}` | `{{ js(this.data) }}` | `string` | `__temple_write_js_string`: escapes quotes, control chars, `\u2028`/`\u2029`, and `<`/`>`/`&`/`/` to prevent `</script>` breakout |
| **`magic`** | `{{ this.text \| magic }}` | `{{ magic(this.text) }}` | `string` | `__temple_write_magic_string`: wraps each word in `<span class="magic-text__word">...</span>` (HTML-escaped) |
| **`default`** | `{{ this.val \| default(fb) }}` | `{{ default(this.val, fb) }}` | `string`, `[]T`, `Maybe(T)` | `__temple_default`: returns `fb` when `string`/`[]T` is empty or `Maybe(T)` is `nil` |
| **`fmt`** | `{{ this.v \| fmt("%.2f") }}` | `{{ fmt("%s: %i", a, b) }}` | `any` | Strength-reduced to static/fast writers for single-arg `%s`, `%i`/`%d`, `%.Nf`; otherwise zero-alloc `__temple_write_fmt_escaped` (or `__temple_write_fmt_raw` when piped to `\| raw`) |
| **`len`** | `{{ this.items \| len }}` | `{{ len(this.items) }}` | slice / array / `string` / `map` | `__temple_write_int(w, int(len(expr)))`: writes base-10 length with 0 allocations |
| **Type casts** | `{{ this.n \| int }}` | `{{ int(this.n) }}` | numeric / `byte` / `rune` | Direct writers for `int`, `uint`, `i64`, `u64`, `i128`, `u128`, `f32`, `f64`, `byte`, `rune` |

---

## Canonical Recipes

### 1. CLI Codegen Workflows (External Package, Vendored & CI Verification)

Run `temple_cli` whenever `.temple.twig` / `.temple.html` files change or `compiled` / `compiled_inline` calls are added:

```bash
# External package mode (generates `compiled` inside `package views`, importing runtime from `shared:temple` or custom path):
odin run temple/cli -- src/views -out:src/views/templates_gen.odin -pkg:views -temple-import:../deps/temple

# Vendored submodule mode (generates `temple/templates.odin` inside `package temple`):
odin run temple/cli -- src temple

# CI check & orphan template audit (exits non-zero if `templates_gen.odin` is missing or stale):
odin run temple/cli -- --check --warn-unused src/views -out:src/views/templates_gen.odin -pkg:views -temple-import:../deps/temple

# Development watch mode (polls `.odin` and template files and incrementally recompiles):
odin run temple/cli -- --watch src/views -out:src/views/templates_gen.odin -pkg:views
```

### 2. Zero-Allocation Rendering with `approx_bytes`

Bind templates at file scope and pre-size your `strings.Builder` (or reuse a buffer across requests) using `approx_bytes`:

```odin
package views

import "core:strings"

Page_View :: struct {
	title: string,
	items: []string,
}

// `compiled` is "contextless" and safe at global scope.
// Path is resolved relative to this `.odin` file's directory.
page_tmpl := compiled("templates/page.temple.twig", Page_View)

render_page :: proc(view: Page_View, allocator := context.temp_allocator) -> (html: string, ok: bool) {
	sb := strings.builder_make(0, page_tmpl.approx_bytes, allocator)
	_, err := page_tmpl.with(strings.to_writer(&sb), view)
	return strings.to_string(sb), err == nil
}
```

### 3. Context-Aware Security Escaping & `default` Fallbacks

Always match the output filter to the HTML/URL/JS context where the value is interpolated:

```odin
Link_Context :: struct {
	href:       Maybe(string),
	query:      string,
	title:      string,
	trusted_md: string,
	js_state:   string,
}

link_tmpl := compiled_inline(`
<a href="{{ this.href | default("/home") | url }}?q={{ this.query | url_param }}">
  {{ this.title | default("Untitled") }}
</a>
<div class="prose">{{ this.trusted_md | raw }}</div>
<script>
  window.__INITIAL_STATE__ = "{{ this.js_state | js }}";
</script>
`, Link_Context)
```

### 4. Control Flow, Pattern Matching (`switch`), Local Bindings (`let`) & Whitespace Control

All control blocks (`if`, `switch`, `for`) close with `{% end %}`. Add hyphens (`{{-`, `-}}`, `{%-`, `-%}`, `{#-`, `-#}`) to strip adjacent whitespace:

```twig
{%- let item_count = len(this.items) -%}
<section data-count="{{ item_count | int }}">
  {%- if item_count == 0 -%}
    <p>No items found.</p>
  {%- elseif item_count == 1 -%}
    <p>1 item available.</p>
  {%- else -%}
    <ul>
      {%- for item, idx in this.items -%}
        <li>{{ idx | int }}: {{ item }}</li>
      {%- end -%}
    </ul>
  {%- end -%}

  {%- #partial switch this.status -%}
    {%- case .Loading -%}
      <span>Loading...</span>
    {%- case .Ready -%}
      {%- switch payload in this.payload -%}
        {%- case string -%}
          <span>{{ payload }}</span>
        {%- case int -%}
          <span>Code {{ payload | int }}</span>
      {%- end -%}
    {%- case -%}
      <span>Idle</span>
  {%- end -%}
</section>
```

### 5. Multi-Level Layout Inheritance (`extends`, `block`, `super`)

Child templates must place `{% extends "..." %}` at the top of the file (only comments/whitespace may precede it) and may only contain `{% block ... %}` or `{% macro ... %}` declarations at top level:

```twig
{# layouts/base.temple.twig #}
<!DOCTYPE html>
<html>
<head>
  <title>{% block title %}Acme{% end %}</title>
</head>
<body>
  {% block content %}Default body{% end %}
</body>
</html>
```

```twig
{# pages/dashboard.temple.twig #}
{% extends "../layouts/base.temple.twig" %}

{% block title %}{{ super() }} — {{ this.page_title }}{% end %}

{% block content %}
  <main>{{ this.body_html | raw }}</main>
{% end %}
```

### 6. Component Composition (`embed`) & Typed Macros (`macro` / `call`)

Use `{% embed %}` to render another template file with the current `this`, a sub-struct via `with`, or inline named props (supporting field-punning like `this.title` -> `title = this.title`). Use `{% macro %}` and `{% call %}` for typed helper procedures:

```twig
{% macro badge(label: string, active := false) %}
  <span class="badge {% if active %}badge--active{% end %}">{{ label | default("N/A") }}</span>
{% end %}

{# 1. Call a hoisted macro #}
{% call badge(this.title, true) %}
{% call badge("Draft") %}

{# 2. Embed a sub-template inheriting `this` or passing a sub-struct with `with` #}
{% embed "partials/nav.temple.twig" %}
{% embed "partials/author.temple.twig" with this.author %}

{# 3. Embed a component with named props (synthesizes an inline struct for the partial's `this`) #}
{% embed "components/card.temple.twig"(
    this.title,
    count = len(this.items),
    price_label = fmt("$%.2f", this.price),
) %}
```

---

## Anti-Patterns (DO vs. DO NOT)

* **DO NOT** forget to re-run `temple_cli` after adding/renaming a `compiled(...)` call or editing a template file; missing paths hit `#panic("undefined template ... did you run the temple transpiler?")` at compile time. **DO** run `temple_cli` before `odin build` / `odin test` and enforce `--check --warn-unused` in CI.
* **DO NOT** output non-string types (`int`, `f64`, `bool`, enums) in bare `{{ this.count }}` tags; bare output lowers to `__temple_write_escaped_string(w, expr)` and fails Odin typechecking. **DO** use `{{ this.count | int }}`, `{{ this.items | len }}`, or `{{ this.price | fmt("$%.2f") }}`.
* **DO NOT** use Jinja/Twig closing tags like `{% endif %}`, `{% endfor %}`, `{% endswitch %}`, `{% endblock %}`, or `{% endmacro %}`. **DO** close every block construct in `temple` with `{% end %}`.
* **DO NOT** reference `this` or outer `{% let %}` variables implicitly inside a `{% macro %}` body; macros compile to hoisted non-capturing local Odin procedures (`proc(__temple_w: io.Writer, ...)`). **DO** pass all values needed by the macro as explicit typed parameters (`{% macro row(name: string, count: int) %}`).
* **DO NOT** place raw HTML or output tags outside `{% block ... %}` (or `{% macro ... %}`) in a child template that uses `{% extends "..." %}`; top-level content outside blocks in an extending template is rejected by the compiler.
* **DO NOT** pass runtime variables, function parameters, or shadowed local identifiers as the first argument to `compiled(path, T)` or `compiled_inline(src, T)`. **DO** pass string literals or unambiguous package/local compile-time string constants (`CARD_PATH :: "card.temple.twig"`).
* **DO NOT** use `| raw` on untrusted user URLs or inline `<script>` values. **DO** use `| url` for `href`/`src` attributes, `| url_param` for query string values, and `| js` inside `<script>` string literals.
