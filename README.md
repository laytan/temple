# Temple

An experimental in development templating engine for Odin

## Features:

* Similar syntax as other mustache based templating engines
* No runtime overhead, templates are transpiled into regular Odin
* Safe for HTML output by default (XSS prevention) with an opt-out syntax
* Support Odin expressions, based on the given context/data
    * `{{ this.name.? or_else "no name" }}`
    * `{{ this.welcome if this.user.new else "" }}`
* Allow user to be explicit with a cast, and emit the correct write calls, eg: `{{ int(this.count + 5) }}`
* Odin's expressive looping syntax, eg: `{% for name in this.names %} {{ name }} {% end %}`
* Conditionals, eg: `{% if expression %} yeah! {% elseif expression %} No but Yeah! {% else %} No :( {% end %}`
* Approximate the size of a templates output, so user can resize a buffer before templating into it
* Embedding other templates
* No/minimal runtime errors
    * Error when template does not exists
    * Error when temple is called incorrectly
    * Error when you use something in the template that you don't provide when using
    * etc.
* No dependence on having template files after compiling, a single binary contains everything

## Goals:

* More robust and complete parsing of code for `compiled` and `compiled_inline` calls
* Catch common errors in the CLI, instead of having Odin catch it, this is because if Odin catches it, the source of the error is lost, in the CLI we have context
* Make the CLI be as fast as possible to not burden the development cycle, ideally almost instant for hundreds of templates
* Layouts, similar to [{% extends %} in Twig](https://twig.symfony.com/doc/2.x/tags/extends.html)
* Better errors when inside of an embed, give more context of the embed tree and bubble the error all the way back up 

## Usage:

Temple has 2 parts, the compiler and the runtime. The compiler is used to compile templates into Odin code,
these transpiled templates can then be used by importing them into your code via the runtime.

This currently requires the temple code to be in your project, and only used by your project (so not in the shared collection), this might change.

1. Clone into project: `git submodule add https://github.com/laytan/temple`
2. Build the compiler CLI: `odin build temple/cli -o:speed -out:temple_cli`
3. Use the CLI, before running your template using project: `./temple_cli . temple`
    * The first argument is the path to the root of your project (where to look for templates)
    * The second argument is the path to temple itself

The syntax is most similar/works best with syntax highlighting for the Twig templating engine, so I suggest ending template filenames with `.temple.twig`.
That is a suggestion and you can call template files however you like.

You can then use the templates like this:

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
    name: string,
    count: int,
}

home := temple.compiled("templates/home.temple.twig", Home_This)

// Or inline templates:
// home := temple.compiled_inline(`Hello, {{ this.name }}`, Home_This)

main :: proc() {
	w := os.stream_from_handle(os.stdout)
	home.with(w, {"Laytan", 10})

    // Output:
    // <!-- templates/home.temple.twig -->
    //
    // Hello, Laytan!!
    //
    //
    // <!-- add a cast to emit writing of that type (instead of a string), works with int, i64, f32, byte, rune etc. -->
    // The count is 10
    // 12345
}
```

Generated code for the previous example looks like the following:

```odin
package temple

import __temple_io "core:io"

compiled :: proc($path: string, $T: typeid) -> Compiled(T) {
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
				__temple_n += __temple_io.write_string(__temple_w, " \n") or_return /* 8:35 in template */
				for i in 1..=5 { /* 10:1 in template */
					__temple_n += __temple_io.write_int(__temple_w, int(i)) or_return /* 10:21 in template */
				}
				__temple_n += __temple_io.write_string(__temple_w, "\n") or_return /* 10:42 in template */
				return
			}, 
			approx_bytes = 218,
		}
	} else {
		#panic("undefined template \"" + path + "\" did you run the temple transpiler?")
	}
}
```

### Output

```odin
// Output is denoted by an opening {{ and closing }}
t := temple.compiled_inline(`{{ "Hello" }}`, struct{})
// Reference passed in values with `this`, which is of the type you pass as a second argument.
t := temple.compiled_inline(`{{ this.name }}`, struct{ name: string })
// Any Odin expression will work, as long as it results in a single string or single value with a cast (next example).
t := temple.compiled_inline(`{{ this.name or_else this.last_name }}`, struct{ name: Maybe(string), last_name: string })
// If the value you want to print is not a string, put a cast around it like `int()`, `f32()` or any other types that have a writer in the `io.write_*` namespace.
t := temple.compiled_inline(`{{ int(this.count) }}`, struct{ count: int })
```

### If

```odin
// If statements start with a {% if condition %}, can then contain one or more {% elseif condition %}, then an optional {% else %}, and then an {% end %}.
t := temple.compiled_inline(`{% if this.name == "Laytan" %}Cool Name!{% end %}`, struct{ name: string })
t := temple.compiled_inline(`
{% if this.count == 0 %}
    There are no items in your basket.
{% elseif this.count == 1 %}
    There is one item in your basket.
{% elseif this.count > 100 %}
    There are too many items in your basket.
{% else %}
    There are {{ int(this.count) }} items in your basket.
{% end %}
`, struct{count: int})
```

### For

```odin
// For loops are started with a {% for expression %} and ended with an {% end %}.
// They can contain any valid Odin loop that works on the `this` of the template.
t := temple.compiled_inline(`{% for i in 0..<5 %} {{ int(i) }} {% end %}`, struct{})
t := temple.compiled_inline(`{% for book in books %} {{ book.title }} {% end %}`, struct{ books: []struct{ title: string } })
```

### Embed

```odin
// Embed can be used to embed other templates into the current one, paths are relative to the current template (or the file that called `compiled_inline` with inline templates).

// The embedded template will have the same `this` as the current template by default.
t := temple.compiled_inline(`{% embed "header.temple.twig" %}`, struct{})

// Changing the `this` inside the embedded template can be done with the `with` keyword.
t := temple.compiled_inline(`{% embed "header.temple.twig" with this.header %}` struct{ header: struct{ title: string } })
