# Temple

An experimental in development templating engine for Odin

## Goals:

* Similar syntax as other mustache based templating engines
* No runtime overhead, templates are transpiled into regular Odin
* Safe for HTML output by default (XSS prevention) with an opt-out syntax
* Support Odin expressions, based on the given context/data
    * `{{ this.name.? or_else "no name" }}`
    * `{{ this.welcome if this.user.new else "" }}`
* Allow user to be explicit with a cast, and emit the correct write calls, eg: `{{ int(this.count + 5) }}`
* Odin's expressive looping syntax, eg: `{% for name in this.names %} {{ name }} {% endfor %}`
* Conditionals, eg: `{% if expression %} yeah! {% elseif expression %} No but Yeah! {% else %} No :( {% endif %}`
* Approximate the size of a templates output, so user can resize a buffer before templating into it
* Some simple way to include other templates, syntax not determined
* No/minimal runtime errors
    * Error when template does not exists
    * Error when temple is called incorrectly
    * Error when you use something in the template that you don't provide when using
    * etc.
* Catch common errors in the CLI, instead of having Odin catch it, this is because if Odin catches it, the source of the error is lost, in the CLI we have context
* Make the CLI be fast enough to not burden the development cycle, ideally almost instant

## Usage:

Temple has 2 parts, the compiler and the runtime. The compiler is used to compile templates into Odin code,
these transpiled templates can then be used by importing them into your code via the runtime.

This currently requires the temple code to be in your project, and only used by your project (so not in the shared collection), this might change.

1. Clone into project: `git submodule add https://github.com/laytan/temple`
2. Build the compiler CLI: `odin build temple/cli -o:speed -out:temple_cli`
3. Use the CLI, before running your template using project: `./temple_cli . temple`
    * The first argument is the path to the root of your project (where to look for templates)
    * The second argument is the path to temple itself

You can then use the templates like this:
```html
<!-- templates/home.temple.html -->

Hello, {{ this.name }}!

{% if this.name == "Laytan" %}Cool Name!{% end %}

<!-- add a cast to emit writing of that type (instead of a string), works with int, i64, f32, byte, rune etc. -->
The count is {{ int(this.count) }} 
```

```odin
package main

import "core:os"

import "temple"

Home_This :: struct {
    name: string,
    count: int,
}

home := temple.compiled("templates/home.temple.html", Home_This)

main :: proc() {
	w := os.stream_from_handle(os.stdout)
	home.with(w, {"Laytan", 10})

    // Output:
    // Hello, Laytan!
    //
    // Cool Name!
    //
    // The count is 10
}
```
