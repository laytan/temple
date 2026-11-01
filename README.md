# Temple

A fast, compile-time templating engine for Odin that transpiles Twig/Mustache-inspired templates directly into zero-overhead Odin code.

## Features:

* Similar syntax to Twig / Mustache templating engines
* Zero runtime overhead — templates are transpiled into regular Odin procedures
* Safe for HTML output by default (batched XSS escaping) with explicit opt-out (`{{ raw(...) }}`) and word-span wrapping (`{{ magic(...) }}`)
* Full Odin expressions inside templates, validated at compile time by `core:odin/parser`
    * `{{ this.name.? or_else "no name" }}`
    * `{{ this.welcome if this.user.new else "" }}`
* Explicit type-cast writers (`int`, `uint`, `i64`, `u64`, `i128`, `u128`, `f32`, `f64`, `byte`, `rune`, `len`), e.g. `{{ int(this.count + 5) }}`
* Local variable bindings via `{% let x = expr %}`, `{% let x := expr %}`, or `{% let x: int = expr %}`
* Conditionals (`{% if ... %}`, `{% elseif ... %}` / `{% else if ... %}`, `{% else %}`, `{% end %}`)
* Pattern matching & enum/union switches (`{% switch ... %}`, `{% #partial switch ... %}`, `{% case ... %}`, `{% case %}`)
* Odin's expressive looping syntax (`{% for name in this.names %} {{ name }} {% end %}`)
* Layout inheritance (`{% extends "base.html" %}`, `{% block name %}...{% end %}`, and `{{ super() }}` / `{% super %}`)
* Sub-template embedding (`{% embed "card.html" %}` and `{% embed "card.html" with this.card %}`)
* Template comments (`{# ... #}`) and whitespace trimming markers (`{{-`, `-}}`, `{%-`, `-%}`, `{#-`, `-#}`)
* Precomputed `approx_bytes` output size estimation (including branch-aware `switch` estimation) so buffers can be pre-sized before rendering
* Parallel multi-threaded CLI compilation with Rust/Odin-style diagnostics and full `Call_Site -> Extends -> Embed` trace stacks
* `"contextless"` template descriptors so `temple.compiled` and `temple.compiled_inline` work in global/file-scope declarations
* Single self-contained binary at runtime — no template files needed after compilation

## Usage:

Temple has 2 parts: the compiler (`cli/`) and the runtime (`runtime.odin`). The compiler scans your Odin project for `temple.compiled` and `temple.compiled_inline` calls (including package/local string constants and procedure aliases) and generates `templates.odin`.

1. Clone into project: `git submodule add https://github.com/laytan/temple`
2. Build the compiler CLI: `odin build temple/cli -o:speed -out:temple_cli`
3. Run the CLI before building your project: `./temple_cli . temple`
    * The first argument is the path to the root of your project (where to look for template calls)
    * The second argument is the path to `temple` itself
    * Run `./temple_cli --version` to print the compiler version

The syntax works great with Twig syntax highlighting, so ending template filenames with `.temple.twig` (or `.html`) is recommended.

```twig
<!-- templates/home.temple.twig -->

Hello, {{ this.name }}!

{% if this.name == "Laytan" %}Cool Name!{% end %}

<!-- add a cast to emit writing of that type (instead of a string), works with int, i64, f32, byte, rune etc. -->
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

Generated code for the previous example looks like the following:

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
				__temple_n += __temple_io.write_string(__temple_w, "\n\n<!-- add a cast to emit writing of that type (instead of a string), works with int, i64, f32, byte, rune etc. -->\nThe count is ") or_return /* 5:50 in template */
				__temple_n += __temple_io.write_int(__temple_w, int(this.count)) or_return /* 8:14 in template */
				__temple_n += __temple_io.write_string(__temple_w, "\n") or_return /* 8:35 in template */
				for i in 1..=5 { /* 10:1 in template */
					__temple_n += __temple_io.write_int(__temple_w, int(i)) or_return /* 10:21 in template */
				}
				__temple_n += __temple_io.write_string(__temple_w, "\n") or_return /* 10:42 in template */
				return
			},
			approx_bytes = 217,
		}
	} else {
		#panic("undefined template \"" + path + "\" did you run the temple transpiler?")
	}
}
```

### Output (`{{ ... }}`, `raw`, `magic`, and Type Casts)

```odin
// Output is denoted by an opening {{ and closing }} and is HTML-escaped by default:
t := temple.compiled_inline(`{{ "Hello" }}`, struct{})

// Reference passed-in values with `this`, which has the type passed as the second argument:
t := temple.compiled_inline(`{{ this.name }}`, struct{ name: string })

// Any valid Odin expression works:
t := temple.compiled_inline(`{{ this.name.? or_else this.last_name }}`, struct{ name: Maybe(string), last_name: string })

// Use `raw(...)` to write trusted HTML without escaping:
t := temple.compiled_inline(`{{ raw(this.trusted_html) }}`, struct{ trusted_html: string })

// Use `magic(...)` to wrap each space-separated word in `<span class="magic-text__word">...</span>`:
t := temple.compiled_inline(`{{ magic(this.headline) }}`, struct{ headline: string })

// Wrap non-string values in a type cast (`int()`, `uint()`, `i64()`, `u64()`, `i128()`, `u128()`, `f32()`, `f64()`, `byte()`, `rune()`, `len()`):
t := temple.compiled_inline(`{{ int(this.count) }}`, struct{ count: int })
```

### If / Else If / Else

```odin
// Supports both `{% elseif ... %}` and `{% else if ... %}`:
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

### Switch & Partial Switch

```odin
// Supports Odin value switches, type switches (`switch v in this.payload`), and `#partial switch`:
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

### Let Variable Bindings

```odin
// Bind local variables inside templates using `=`, `:=`, or `: Type =`:
t := temple.compiled_inline(`
{% let total = this.price * this.qty %}
{% let label: string = "Total" %}
<span>{{ label }}: {{ int(total) }}</span>
`, Order_Ctx)
```

### For Loops

```odin
// Any valid Odin `for` loop clause works:
t := temple.compiled_inline(`{% for i in 0..<5 %} {{ int(i) }} {% end %}`, struct{})
t := temple.compiled_inline(`{% for book, idx in this.books %} {{ int(idx) }}: {{ book.title }} {% end %}`, Library_Ctx)
```

### Layout Inheritance (`extends`, `block`, `super`)

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

### Embed

```odin
// Embed another template relative to the current template file:
t := temple.compiled_inline(`{% embed "header.temple.twig" %}`, struct{})

// Narrow or replace `this` for the embedded template with `with`:
t := temple.compiled_inline(`{% embed "header.temple.twig" with this.header %}`, struct{ header: Header_Data })
```

### Comments & Whitespace Trimming

```twig
{# Comments are stripped completely from generated output #}
{#- Use hyphens on opening/closing delimiters to strip adjacent whitespace/newlines -#}
<div>
  {%- if this.show -%}
    <span>{{- this.label -}}</span>
  {%- end -%}
</div>
```
