package temple_cli

import "core:mem"
import "core:strings"
import "core:testing"

// ============================================================================
// Pattern A: Multi-Step Domain Workflows (Layout Inheritance, Super & Embeds)
// ============================================================================

@(test)
spec_three_level_layout_inheritance_with_super_and_relative_embeds :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	given_template(s, "/app/layouts/base.html",
		`<html>{% block head %}<meta>{% embed "../partials/icon.html" %}{% end %}{% block body %}BASE{% end %}</html>`,
	)
	given_template(s, "/app/partials/icon.html", `<link rel="icon">`)

	given_template(s, "/app/layouts/section/child.html",
		`{% extends "../base.html" %}{% block head %}{{ super() }}<title>{% block title %}Default{% end %}</title>{% embed "child_meta.html" %}{% end %}{% block body %}<main>{% super %}</main>{% end %}`,
	)
	given_template(s, "/app/layouts/section/child_meta.html", `<meta name="sec">`)

	given_template(s, "/app/views/pages/home.html",
		`{% extends "../../layouts/section/child.html" %}{% block title %}Home{% end %}{% block body %}{{ super() }}{% embed "footer.html" %}{% end %}`,
	)
	given_template(s, "/app/views/pages/footer.html", `<footer>foot</footer>`)

	upon_compiling_template(s, "/app/views/pages/home.html", relpath = "views/pages/home.html")

	then_static_literals_render_in_order(s, {
		"<html><meta>",
		`<link rel="icon">`,
		"<title>Home</title>",
		`<meta name="sec">`,
		"<main>BASE</main>",
		"<footer>foot</footer>",
		"</html>",
	})
}

@(test)
spec_missing_partial_reports_exact_coordinates_and_trace_chain :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	given_template(s, "/app/base.html", "<div>\n\t{% block content %}{% end %}\n</div>")
	given_template(s, "/app/page.html", "{% extends \"base.html\" %}\n{% block content %}\n  {% embed \"missing_card.html\" %}\n{% end %}")

	upon_compiling_template(s, "/app/page.html", called_from = "/app/routes.odin", line = 42, col = 10)

	then_diagnostic_is_reported(
		s,
		file             = "/app/page.html",
		line             = 3,
		col              = 12,
		message_contains = "unable to read template file",
		snippet          = `  {% embed "missing_card.html" %}`,
		caret_len        = len(`"missing_card.html"`),
		trace            = {
			{kind = .Call_Site, file = "/app/routes.odin", line = 42, col = 10},
			{kind = .Embed,     file = "/app/page.html",   line = 3,  col = 12},
		},
	)
}

@(test)
spec_self_embedding_root_template_fails_immediately_on_first_cycle :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	given_template(s, "/app/self.html", `{% embed "self.html" %}`)

	upon_compiling_template(s, "/app/self.html", called_from = "/app/main.odin", line = 10, col = 5)

	then_diagnostic_is_reported(
		s,
		file             = "/app/self.html",
		line             = 1,
		col              = 10,
		message_contains = "circular embed detected",
		caret_len        = len(`"self.html"`),
	)
}

@(test)
spec_odin_call_collection_resolves_out_of_order_consts_and_rejects_shadowed_params :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	upon_scanning_odin_source(s, `package sample
import "temple"

PKG_PATH :: "pkg_level.html"

valid_out_of_order :: proc() {
	_ = temple.compiled(LATE_LOCAL, int)
	LATE_LOCAL :: "late_local.html"
}

shadowed_by_param :: proc(PKG_PATH: string) {
	_ = temple.compiled(PKG_PATH, int)
}
`)

	then_collected_templates_are(s, {"late_local.html"})
	then_collection_error_contains(s, "must be a compile-time constant string expression")
}

// ============================================================================
// Tabular Specs: Output Expressions, Casts & Nested Delimiters
// ============================================================================

@(test)
spec_output_expressions_and_pseudo_casts :: proc(t: ^testing.T) {
	Output_Case :: struct {
		template:      string,
		expected_call: string,
	}

	cases := []Output_Case{
		{
			template      = "{{ this.title }}",
			expected_call = "__temple_write_escaped_string(__temple_w, this.title) or_return",
		},
		{
			template      = "{{ raw(get_html()) }}",
			expected_call = "__temple_io.write_string(__temple_w, get_html()) or_return",
		},
		{
			template      = "{{ raw(this.items[0]) }}",
			expected_call = "__temple_io.write_string(__temple_w, this.items[0]) or_return",
		},
		{
			template      = "{{ raw((this.a + this.b)) }}",
			expected_call = "__temple_io.write_string(__temple_w, (this.a + this.b)) or_return",
		},
		{
			template      = "{{ magic(get_title()) }}",
			expected_call = "__temple_write_magic_string(__temple_w, get_title()) or_return",
		},
		{
			template      = "{{ len(this.items) }}",
			expected_call = "__temple_write_int(__temple_w, len(this.items)) or_return",
		},
	}

	for c in cases {
		s := scenario_begin(t)
		upon_compiling_inline(s, c.template)
		then_emits_writer_call(s, c.expected_call)
		scenario_end(s)
	}
}

@(test)
spec_switch_approx_bytes_uses_largest_case_branch :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	upon_compiling_inline(
		s,
		`1234{% switch this.k %}{% case .A %}aaa{% case .B %}bbbbbbbbbbbbbbbbbbbbbbbbb{% case .C %}cccccccc{% end %}123456`,
	)

	// 4 ("1234") + 25 (max case .B) + 6 ("123456") = 35
	then_approx_bytes_is(s, 35)
}

@(test)
spec_for_loop_approx_bytes_scales_by_loop_multiplier :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	upon_compiling_inline(
		s,
		`<ul>{% for item in this.items %}<li>{{ item }}</li>{% end %}</ul>`,
	)

	// 4 ("<ul>") + 8 * (4 ("<li>") + 10 ("{{ item }}") + 5 ("</li>")) + 5 ("</ul>") = 4 + 8 * 19 + 5 = 161
	then_approx_bytes_is(s, 161)
}

@(test)
spec_component_embed_with_named_props_and_shorthand_punning :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	given_template(s, "/app/components/card.html",
		`<article class="{{ this.theme }}"><h2>{{ this.title }}</h2><span>{{ int(this.count) }}</span></article>`,
	)
	given_template(s, "/app/page.html",
		`{% embed "components/card.html"(this.title, count = len(this.items), theme = "dark") %}`,
	)

	upon_compiling_template(s, "/app/page.html", relpath = "page.html")

	then_emits_writer_call(s, "__temple_prop_0 := this.title")
	then_emits_writer_call(s, "__temple_prop_1 := len(this.items)")
	then_emits_writer_call(s, `__temple_prop_2 := "dark"`)
	then_emits_writer_call(
		s,
		"this := struct { title: type_of(__temple_prop_0), count: type_of(__temple_prop_1), theme: type_of(__temple_prop_2) }{ title = __temple_prop_0, count = __temple_prop_1, theme = __temple_prop_2 }",
	)
}

@(test)
spec_component_embed_rejects_duplicate_prop_names :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	upon_compiling_inline(
		s,
		`{% embed "card.html"(title = "First", this.title) %}`,
		called_from = "/app/views.odin",
		line        = 12,
		col         = 4,
	)

	then_diagnostic_is_reported(
		s,
		file             = "/app/views.odin",
		line             = 12,
		col              = 42,
		message_contains = `duplicate prop "title" in embed tag`,
	)
}

@(test)
spec_ast_pipe_filters_and_fmt_expressions :: proc(t: ^testing.T) {
	Pipe_Case :: struct {
		template:      string,
		expected_call: string,
	}

	cases := []Pipe_Case{
		{
			template      = `{{ this.body | raw }}`,
			expected_call = `__temple_io.write_string(__temple_w, this.body) or_return`,
		},
		{
			template      = `{{ this.headline | magic }}`,
			expected_call = `__temple_write_magic_string(__temple_w, this.headline) or_return`,
		},
		{
			template      = `{{ this.items | len }}`,
			expected_call = `__temple_write_int(__temple_w, len(this.items)) or_return`,
		},
		{
			template      = `{{ this.price | fmt("$%.2f") }}`,
			expected_call = `__temple_write_f64_prec(__temple_w, f64(this.price), 2) or_return`,
		},
		{
			template      = `{{ this.price | fmt("$%6.2f") }}`,
			expected_call = `__temple_write_fmt_escaped(__temple_w, "$%6.2f", this.price) or_return`,
		},
		{
			template      = `{{ fmt("%s (%i)", this.name, this.count) }}`,
			expected_call = `__temple_write_fmt_escaped(__temple_w, "%s (%i)", this.name, this.count) or_return`,
		},
		{
			template      = `{{ this.nickname | default("Anonymous") }}`,
			expected_call = `__temple_write_escaped_string(__temple_w, __temple_default(this.nickname, "Anonymous")) or_return`,
		},
		{
			template      = `{{ (this.flags | 0x01) | int }}`,
			expected_call = `__temple_write_int(__temple_w, int((this.flags | 0x01))) or_return`,
		},
		{
			template      = `{{ (this.a | this.b) | fmt("%x") }}`,
			expected_call = `__temple_write_fmt_escaped(__temple_w, "%x", (this.a | this.b)) or_return`,
		},
		{
			template      = `{{ raw(default(this.name, "Guest")) }}`,
			expected_call = `__temple_io.write_string(__temple_w, __temple_default(this.name, "Guest")) or_return`,
		},
		{
			template      = `{{ raw(fmt("<b>%v</b>", this.name)) }}`,
			expected_call = `__temple_write_fmt_raw(__temple_w, "<b>%v</b>", this.name) or_return`,
		},
		{
			template      = `{{ raw(fmt("<b>%s</b>", this.name)) }}`,
			expected_call = `__temple_io.write_string(__temple_w, this.name) or_return`,
		},
		{
			template      = `{{ len(this.items) | fmt("items=%i") }}`,
			expected_call = `__temple_write_int(__temple_w, int(len(this.items))) or_return`,
		},
		{
			template      = `{{ this.name | fmt("<%s>") }}`,
			expected_call = `__temple_io.write_string(__temple_w, "&lt;") or_return`,
		},
	}

	for c in cases {
		s := scenario_begin(t)
		upon_compiling_inline(s, c.template)
		then_emits_writer_call(s, c.expected_call)
		scenario_end(s)
	}
}

// ============================================================================
// Regression Specs: AST Pipe Validation, Trailing Commas & Seeded Parse Errors
// ============================================================================

@(test)
spec_rejects_unknown_output_pipe_filters :: proc(t: ^testing.T) {
	Invalid_Pipe_Case :: struct {
		template:     string,
		col:          int,
		expected_err: string,
	}

	// Issue 1.1: Unknown identifier filters, unknown call filters, and non-filter expressions on RHS of `|`
	cases := []Invalid_Pipe_Case{
		{template = `{{ this.name | upper }}`,    col = 16, expected_err = `unknown output pipe filter "upper"`},
		{template = `{{ this.name | bogus(1) }}`, col = 16, expected_err = `unknown output pipe filter "bogus(1)"`},
		{template = `{{ this.flags | 0x01 }}`,    col = 17, expected_err = `unknown output pipe filter "0x01"`},
	}

	for c in cases {
		s := scenario_begin(t)
		upon_compiling_inline(s, c.template, called_from = "/app/view.odin", line = 1, col = 1)
		then_diagnostic_is_reported(
			s,
			file             = "/app/view.odin",
			line             = 1,
			col              = c.col,
			message_contains = c.expected_err,
		)
		scenario_end(s)
	}
}

@(test)
spec_rejects_invalid_pipe_chains_and_piped_super :: proc(t: ^testing.T) {
	Invalid_Chain_Case :: struct {
		template:     string,
		col:          int,
		expected_err: string,
	}

	// Issue 1.2: Piping `super()` or chaining filters after terminal modifiers (`fmt`, `raw`, `magic`, `len`, casts)
	cases := []Invalid_Chain_Case{
		{
			template     = `{% block body %}{{ super() | raw }}{% end %}`,
			col          = 28,
			expected_err = `"super()" cannot be used with pipe filters`,
		},
		{
			template     = `{{ this.price | fmt("$%.2f") | default("N/A") }}`,
			col          = 32,
			expected_err = "cannot pipe additional filters after terminal output modifier",
		},
		{
			template     = `{{ this.price | fmt("$%.2f") | magic }}`,
			col          = 32,
			expected_err = "cannot pipe additional filters after terminal output modifier",
		},
		{
			template     = `{{ this.items | len | raw }}`,
			col          = 23,
			expected_err = "cannot pipe additional filters after terminal output modifier",
		},
		{
			template     = `{{ this.html | raw | magic }}`,
			col          = 22,
			expected_err = "cannot pipe additional filters after terminal output modifier",
		},
	}

	for c in cases {
		s := scenario_begin(t)
		upon_compiling_inline(s, c.template, called_from = "/app/view.odin", line = 5, col = 1)
		then_diagnostic_is_reported(
			s,
			file             = "/app/view.odin",
			line             = 5,
			col              = c.col,
			message_contains = c.expected_err,
		)
		scenario_end(s)
	}
}

@(test)
spec_valid_pipe_chains_and_trailing_comma_tolerance :: proc(t: ^testing.T) {
	Valid_Case :: struct {
		template:      string,
		expected_call: string,
	}

	// Issue 1.2 (valid chains) & Issue 2.1 (trailing commas inside `fmt` and `default`)
	cases := []Valid_Case{
		{
			template      = `{{ this.price | fmt("<b>$%.2f</b>") | raw }}`,
			expected_call = `__temple_write_f64_prec(__temple_w, f64(this.price), 2) or_return`,
		},
		{
			template      = `{{ this.price | fmt("<b>$%v</b>") | raw }}`,
			expected_call = `__temple_write_fmt_raw(__temple_w, "<b>$%v</b>", this.price) or_return`,
		},
		{
			template      = `{{ this.bio | default("<i>None</i>") | raw }}`,
			expected_call = `__temple_io.write_string(__temple_w, __temple_default(this.bio, "<i>None</i>")) or_return`,
		},
		{
			template      = `{{ this.name | default("Guest",) }}`,
			expected_call = `__temple_write_escaped_string(__temple_w, __temple_default(this.name, "Guest")) or_return`,
		},
		{
			template      = `{{ default(this.name, "Guest",) }}`,
			expected_call = `__temple_write_escaped_string(__temple_w, __temple_default(this.name, "Guest")) or_return`,
		},
		{
			template      = `{{ this.price | fmt("$%.2f",) }}`,
			expected_call = `__temple_write_f64_prec(__temple_w, f64(this.price), 2) or_return`,
		},
		{
			template      = `{{ this.price | fmt("$%v",) }}`,
			expected_call = `__temple_write_fmt_escaped(__temple_w, "$%v", this.price) or_return`,
		},
		{
			template      = `{{ fmt("%s: %i", this.name, this.count,) }}`,
			expected_call = `__temple_write_fmt_escaped(__temple_w, "%s: %i", this.name, this.count) or_return`,
		},
	}

	for c in cases {
		s := scenario_begin(t)
		upon_compiling_inline(s, c.template)
		// `then_emits_writer_call` also runs `driver_assert_valid_generated_odin` to prove no trailing comma leaked
		then_emits_writer_call(s, c.expected_call)
		scenario_end(s)
	}
}

@(test)
spec_seeded_template_with_syntax_error_reports_parse_diagnostic :: proc(t: ^testing.T) {
	// Issue 1.3: Ensure broken virtual templates in `raw_cache` report their parse error instead of hitting OS disk
	s := scenario_begin(t)
	defer scenario_end(s)

	given_template(s, "/app/broken.html", "<div>\n  {% if %}\n</div>")

	upon_compiling_template(s, "/app/broken.html", called_from = "/app/main.odin", line = 10, col = 4)

	then_diagnostic_is_reported(
		s,
		file             = "/app/broken.html",
		line             = 2,
		col              = 8,
		message_contains = `missing condition expression after "if"`,
		snippet          = "  {% if %}",
	)
}

@(test)
spec_macro_definition_and_call_with_typed_and_default_params :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	upon_compiling_inline(
		s,
		`{% macro badge(label: string, active := false,) /* inline comment */ %}<span class="{% if active %}on{% else %}off{% end %}">{{ label }}</span>{% end %}` +
		`{% macro divider() %}<hr>{% end %}` +
		`{% call badge(this.title, true,) %}{% call divider() %}`,
	)

	then_emits_writer_call(
		s,
		`__temple_macro_badge :: proc(__temple_w: __temple_io.Writer, label: string, active := false) -> (__temple_n: int, __temple_err: __temple_io.Error) {`,
	)
	then_emits_writer_call(
		s,
		`__temple_macro_divider :: proc(__temple_w: __temple_io.Writer) -> (__temple_n: int, __temple_err: __temple_io.Error) {`,
	)
	then_emits_writer_call(
		s,
		`__temple_n += __temple_macro_badge(__temple_w, this.title, true) or_return`,
	)
	then_emits_writer_call(
		s,
		`__temple_n += __temple_macro_divider(__temple_w) or_return`,
	)
	// badge approx_bytes = 13 (`<span class="`) + 3 (max of `"on"` vs `"off"`) + 2 (`">`) + 10 (`{{ label }}`) + 7 (`</span>`) = 35
	// divider approx_bytes = 4 (`<hr>`)
	// total approx_bytes = 35 + 4 = 39
	then_approx_bytes_is(s, 39)
}

@(test)
spec_forward_referenced_macro_calls_and_scoped_embed_macro_approx :: proc(t: ^testing.T) {
	// 1. Calling a macro before its declaration (and macro A calling forward-declared macro B)
	// hoists `Node_Macro` declarations and computes exact `approx_bytes` instead of falling back to 10.
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		upon_compiling_inline(
			s,
			`{% call outer(this.title) %}` +
			`{% macro outer(label: string) %}<div class="outer">{% call inner(label) %}</div>{% end %}` +
			`{% macro inner(text: string) %}<span>{{ text }}</span>{% end %}`,
		)

		// inner = 6 (`<span>`) + 10 (`{{ text }}`) + 7 (`</span>`) = 23
		// outer = 19 (`<div class="outer">`) + 23 (call inner) + 6 (`</div>`) = 48
		then_approx_bytes_is(s, 48)
	}

	// 2. An embedded partial defining a macro of the same name does not overwrite the parent's `macro_approx`.
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		given_template(
			s,
			"/app/partial.html",
			`{% macro item() %}ab{% end %}{% call item() %}`,
		)
		given_template(
			s,
			"/app/page.html",
			`{% macro item() %}12345678901234567890{% end %}{% embed "partial.html" %}{% call item() %}`,
		)

		upon_compiling_template(s, "/app/page.html", relpath = "page.html")

		// partial call item() = 2 bytes ("ab")
		// parent call item() after embed = 20 bytes ("12345678901234567890")
		// total approx_bytes = 22
		then_approx_bytes_is(s, 22)
	}
}

@(test)
spec_multiline_embed_props_with_inline_comments :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	given_template(s, "/app/card.html", `<div>{{ this.title }}</div>`)
	given_template(
		s,
		"/app/page.html",
		"{% embed \"card.html\"(\n" +
		"\ttitle = this.title, // main heading\n" +
		"\tactive = true, /* trailing block comment */\n" +
		") %}",
	)

	upon_compiling_template(s, "/app/page.html", relpath = "page.html")

	then_emits_writer_call(s, "__temple_prop_0 := this.title")
	then_emits_writer_call(s, "__temple_prop_1 := true")
}

@(test)
spec_macros_across_layout_inheritance_with_relative_embeds_and_child_overrides :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	given_template(
		s,
		"/app/layouts/base.html",
		`{% macro badge(label: string) %}<span class="base-badge">{% embed "../partials/dot.html" %}{{ label }}</span>{% end %}` +
		`{% macro chip(text: string) %}<b>{{ text }}</b>{% end %}` +
		`<main>{% block content %}{% end %}</main>`,
	)
	given_template(s, "/app/partials/dot.html", `<i>*</i>`)

	given_template(
		s,
		"/app/views/page.html",
		`{% extends "../layouts/base.html" %}` +
		`{% macro chip(text: string) %}<em>{{ text }}</em>{% end %}` +
		`{% macro pill(tag: string) %}[{{ tag }}]{% end %}` +
		`{% block content %}{% call badge("Status") %}{% call chip("Override") %}{% call pill("Child") %}{% end %}`,
	)

	upon_compiling_template(s, "/app/views/page.html", relpath = "views/page.html")

	then_emits_writer_call(s, `__temple_macro_pill :: proc(__temple_w: __temple_io.Writer, tag: string)`)
	then_emits_writer_call(s, `__temple_macro_badge :: proc(__temple_w: __temple_io.Writer, label: string)`)
	then_emits_writer_call(s, `"<i>*</i>"`)
	then_emits_writer_call(s, `"<em>"`)
	then_emits_writer_call(s, `__temple_n += __temple_macro_badge(__temple_w, "Status") or_return`)
	then_emits_writer_call(s, `__temple_n += __temple_macro_chip(__temple_w, "Override") or_return`)
	then_emits_writer_call(s, `__temple_n += __temple_macro_pill(__temple_w, "Child") or_return`)
}

@(test)
spec_rejects_invalid_macro_and_call_declarations :: proc(t: ^testing.T) {
	Invalid_Macro_Case :: struct {
		template:     string,
		col:          int,
		expected_err: string,
	}

	cases := []Invalid_Macro_Case{
		{
			template     = `{% macro %}{% end %}`,
			col          = 10,
			expected_err = `missing macro signature after "macro"`,
		},
		{
			template     = `{% macro badge %}{% end %}`,
			col          = 10,
			expected_err = `expected parameter list in parentheses`,
		},
		{
			template     = `{% macro 123(x: string) %}{% end %}`,
			col          = 10,
			expected_err = `invalid macro name "123"`,
		},
		{
			template     = `{% macro badge(label) %}{% end %}`,
			col          = 16,
			expected_err = `macro parameter in "badge" must have an explicit type or default value`,
		},
		{
			template     = `{% macro badge(label: string, label: int) %}{% end %}`,
			col          = 31,
			expected_err = `duplicate parameter "label" in macro "badge"`,
		},
		{
			template     = `{% macro badge(label: string) -> int %}{% end %}`,
			col          = 10,
			expected_err = `macros cannot declare a return type`,
		},
		{
			template     = `{% macro badge(label: string) extra %}{% end %}`,
			col          = 31,
			expected_err = `unexpected trailing token "extra" in macro parameter list`,
		},
		{
			template     = `{% macro badge(x: string) %}{% end %}{% macro badge(y: string) %}{% end %}`,
			col          = 47,
			expected_err = `duplicate macro definition "badge"`,
		},
		{
			template     = `{% call %}`,
			col          = 9,
			expected_err = `missing macro call expression after "call"`,
		},
		{
			template     = `{% call badge %}`,
			col          = 9,
			expected_err = `invalid "call" syntax "badge": expected a macro call like "name(args...)"`,
		},
		{
			template     = `{% call a.b(1) %}`,
			col          = 9,
			expected_err = `invalid macro call target: expected a macro identifier`,
		},
		{
			template     = `{% call badge("x") extra %}`,
			col          = 20,
			expected_err = `unexpected trailing token "extra" in "call" tag`,
		},
		{
			template     = `{% if this.ok %}{% macro nested(x: string) %}{% end %}{% end %}`,
			col          = 17,
			expected_err = `"macro" must be declared at the top level of a template`,
		},
		{
			template     = `{% block body %}{% macro nested(x: string) %}{% end %}{% end %}`,
			col          = 17,
			expected_err = `"macro" must be declared at the top level of a template`,
		},
		{
			template     = `{% macro badge(x: string) %}{{ super() }}{% end %}`,
			col          = 29,
			expected_err = `"super()" can only be used inside a "block" tag`,
		},
		{
			template     = `{% call unknown_macro(1) %}`,
			col          = 9,
			expected_err = `undefined macro "unknown_macro"`,
		},
		{
			template     = `{% macro badge(label: string) %}{% end %}{% call other("x") %}`,
			col          = 50,
			expected_err = `undefined macro "other" (available macros: badge)`,
		},
		{
			template     = `{% macro badge(label: string, count: int) %}{% end %}{% call badge("x") %}`,
			col          = 62,
			expected_err = `macro "badge" expects 2 argument(s), got 1`,
		},
		{
			template     = `{% macro badge(label: string, active := false) %}{% end %}{% call badge() %}`,
			col          = 67,
			expected_err = `macro "badge" expects 1 to 2 arguments, got 0`,
		},
		{
			template     = `{% macro badge(label: string, active := false) %}{% end %}{% call badge("x", true, 3) %}`,
			col          = 67,
			expected_err = `macro "badge" expects 1 to 2 arguments, got 3`,
		},
		{
			template     = `{% macro badge(label: string) %}{% end %}{% call badge(wrong = "x") %}`,
			col          = 56,
			expected_err = `unknown parameter "wrong" in call to macro "badge"`,
		},
		{
			template     = `{% macro badge(a: string, b: int) %}{% end %}{% call badge(a = "x", 1) %}`,
			col          = 69,
			expected_err = `positional argument cannot follow named argument in call to macro "badge"`,
		},
	}

	for c in cases {
		s := scenario_begin(t)
		upon_compiling_inline(s, c.template, called_from = "/app/view.odin", line = 1, col = 1)
		then_diagnostic_is_reported(
			s,
			file             = "/app/view.odin",
			line             = 1,
			col              = c.col,
			message_contains = c.expected_err,
		)
		scenario_end(s)
	}

	// Verify compile-time call target and arity validation across `{% extends %}` layout inheritance
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		given_template(
			s,
			"/app/layouts/base.html",
			`{% macro badge(label: string, active := false) %}<span>{{ label }}</span>{% end %}<main>{% block content %}{% end %}</main>`,
		)
		given_template(
			s,
			"/app/views/child_bad_arity.html",
			"{% extends \"../layouts/base.html\" %}\n{% block content %}\n  {% call badge(\"a\", true, 99) %}\n{% end %}",
		)

		upon_compiling_template(s, "/app/views/child_bad_arity.html", called_from = "/app/routes.odin", line = 10, col = 4)
		then_diagnostic_is_reported(
			s,
			file             = "/app/views/child_bad_arity.html",
			line             = 3,
			col              = 11,
			message_contains = `macro "badge" expects 1 to 2 arguments, got 3`,
			caret_len        = len("badge"),
		)
	}
}

@(test)
spec_decoupled_codegen_qualifies_runtime_symbols_in_external_package :: proc(t: ^testing.T) {
	template_src := `{{ this.title | default("Untitled") }}{{ this.headline | magic }}{{ this.price | fmt("$%.2f") }}{{ this.price | fmt("$%6.2f") }}{{ this.badge | fmt("<b>%v</b>") | raw }}{{ this.link | url }}{{ this.query | url_param }}{{ this.payload | js }}`

	// 1. Default `package temple` mode emits unqualified runtime calls and `Compiled(T)`
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		upon_compiling_inline(s, template_src)

		then_generated_file_contains(s, "package temple\n")
		then_generated_file_contains(s, "compiled :: proc \"contextless\" ($path: string, $T: typeid) -> Compiled(T) {")
		then_emits_writer_call(s, `__temple_write_escaped_string(__temple_w, __temple_default(this.title, "Untitled")) or_return`)
		then_emits_writer_call(s, `__temple_write_magic_string(__temple_w, this.headline) or_return`)
		then_emits_writer_call(s, `__temple_write_f64_prec(__temple_w, f64(this.price), 2) or_return`)
		then_emits_writer_call(s, `__temple_write_fmt_escaped(__temple_w, "$%6.2f", this.price) or_return`)
		then_emits_writer_call(s, `__temple_write_fmt_raw(__temple_w, "<b>%v</b>", this.badge) or_return`)
		then_emits_writer_call(s, `__temple_write_safe_url(__temple_w, this.link) or_return`)
		then_emits_writer_call(s, `__temple_write_url_param(__temple_w, this.query) or_return`)
		then_emits_writer_call(s, `__temple_write_js_string(__temple_w, this.payload) or_return`)
	}

	// 2. External `package views` mode emits `import __temple` and qualifies `Compiled(T)` and all runtime helpers
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		given_target_package(s, "views", "shared:temple")
		upon_compiling_inline(s, template_src)

		then_generated_file_contains(s, "package views\n")
		then_generated_file_contains(s, `import __temple "shared:temple"`)
		then_generated_file_contains(s, "__temple_default :: __temple.__temple_default")
		then_generated_file_contains(s, "compiled :: proc \"contextless\" ($path: string, $T: typeid) -> __temple.Compiled(T) {")
		then_emits_writer_call(s, `__temple.__temple_write_escaped_string(__temple_w, __temple_default(this.title, "Untitled")) or_return`)
		then_emits_writer_call(s, `__temple.__temple_write_magic_string(__temple_w, this.headline) or_return`)
		then_emits_writer_call(s, `__temple.__temple_write_f64_prec(__temple_w, f64(this.price), 2) or_return`)
		then_emits_writer_call(s, `__temple.__temple_write_fmt_escaped(__temple_w, "$%6.2f", this.price) or_return`)
		then_emits_writer_call(s, `__temple.__temple_write_fmt_raw(__temple_w, "<b>%v</b>", this.badge) or_return`)
		then_emits_writer_call(s, `__temple.__temple_write_safe_url(__temple_w, this.link) or_return`)
		then_emits_writer_call(s, `__temple.__temple_write_url_param(__temple_w, this.query) or_return`)
		then_emits_writer_call(s, `__temple.__temple_write_js_string(__temple_w, this.payload) or_return`)
	}

	// 3. String literal containing `"__temple_default("` is never corrupted in external package mode
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		given_target_package(s, "views", "shared:temple")
		upon_compiling_inline(s, `{{ this.label | default("call __temple_default(x, y)") }}`)

		then_emits_writer_call(
			s,
			`__temple.__temple_write_escaped_string(__temple_w, __temple_default(this.label, "call __temple_default(x, y)")) or_return`,
		)
	}
}

@(test)
spec_same_package_and_aliased_compile_call_discovery_without_false_positives :: proc(t: ^testing.T) {
	// 1. Unqualified same-package `compiled` / `compiled_inline` and local aliases without importing `temple`
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		upon_scanning_odin_source(s, `package views

Page_Ctx :: struct { title: string }

HOME_TPL :: "home.temple.twig"
local_inline :: compiled_inline

home_view := compiled(HOME_TPL, Page_Ctx)
badge_view := local_inline("<span>{{ this.title }}</span>", Page_Ctx)
`)

		then_collected_templates_are(s, {
			"home.temple.twig",
			"<span>{{ this.title }}</span>",
		})
	}

	// 2. Imported external views package (`import v "../views"`) alongside `import "shared:temple"`
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		upon_scanning_odin_source(s, `package app
import "shared:temple"
import v "../views"

Ctx :: struct { name: string }

a := temple.compiled("a.html", Ctx)
b := v.compiled("b.html", Ctx)
c := v.compiled_inline("<p>{{ this.name }}</p>", Ctx)
`)

		then_collected_templates_are(s, {
			"a.html",
			"b.html",
			"<p>{{ this.name }}</p>",
		})
	}

	// 3. User-defined unrelated `compiled :: proc(...)` shadows default unqualified `compiled` without false errors
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		upon_scanning_odin_source(s, `package custom

compiled :: proc(x: int) -> int {
	return x + 1
}

main :: proc() {
	_ = compiled(42)
}
`)

		then_collected_templates_are(s, {})
		testing.expect_value(t, len(s.collect_errors), 0)
	}

	// 4. Unrelated third-party package selector `shader.compiled(runtime_var, flags)` or `regex.compiled(pat)`
	// must NOT emit false-positive constant string errors
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		upon_scanning_odin_source(s, `package app
import "shared:temple"
import shader "../gfx/shader"
import regex "../util/regex"

Ctx :: struct { name: string }

compile_assets :: proc(runtime_src: string, flags: u32) {
	_ = shader.compiled(runtime_src, flags)
	_ = regex.compiled(runtime_src)
	_ = temple.compiled("valid_page.html", Ctx)
}
`)

		then_collected_templates_are(s, {"valid_page.html"})
		testing.expect_value(t, len(s.collect_errors), 0)
	}
}

@(test)
spec_context_aware_escaping_for_urls_query_params_and_js :: proc(t: ^testing.T) {
	Escaping_Case :: struct {
		template:      string,
		expected_call: string,
	}

	cases := []Escaping_Case{
		// Safe URL (`url(...)` and `| url`)
		{
			template      = `{{ url(this.link) }}`,
			expected_call = `__temple_write_safe_url(__temple_w, this.link) or_return`,
		},
		{
			template      = `{{ this.link | url }}`,
			expected_call = `__temple_write_safe_url(__temple_w, this.link) or_return`,
		},
		{
			template      = `{{ url(get_link(this.items[0])) }}`,
			expected_call = `__temple_write_safe_url(__temple_w, get_link(this.items[0])) or_return`,
		},
		{
			template      = `{{ url(this.link,) }}`,
			expected_call = `__temple_write_safe_url(__temple_w, this.link) or_return`,
		},
		// URL query parameter (`url_param(...)` and `| url_param`)
		{
			template      = `{{ url_param(this.q) }}`,
			expected_call = `__temple_write_url_param(__temple_w, this.q) or_return`,
		},
		{
			template      = `{{ this.q | url_param }}`,
			expected_call = `__temple_write_url_param(__temple_w, this.q) or_return`,
		},
		{
			template      = `{{ url_param(this.q,) }}`,
			expected_call = `__temple_write_url_param(__temple_w, this.q) or_return`,
		},
		// JavaScript / JSON string escaping (`js(...)`, `| js`, `json(...)`, `| json`)
		{
			template      = `{{ js(this.payload) }}`,
			expected_call = `__temple_write_js_string(__temple_w, this.payload) or_return`,
		},
		{
			template      = `{{ this.payload | js }}`,
			expected_call = `__temple_write_js_string(__temple_w, this.payload) or_return`,
		},
		{
			template      = `{{ json(this.payload) }}`,
			expected_call = `__temple_write_js_string(__temple_w, this.payload) or_return`,
		},
		{
			template      = `{{ this.payload | json }}`,
			expected_call = `__temple_write_js_string(__temple_w, this.payload) or_return`,
		},
		{
			template      = `{{ js(this.payload,) }}`,
			expected_call = `__temple_write_js_string(__temple_w, this.payload) or_return`,
		},
		// Composition with `default(...)`
		{
			template      = `{{ this.link | default("/home") | url }}`,
			expected_call = `__temple_write_safe_url(__temple_w, __temple_default(this.link, "/home")) or_return`,
		},
		{
			template      = `{{ url(default(this.link, "/home")) }}`,
			expected_call = `__temple_write_safe_url(__temple_w, __temple_default(this.link, "/home")) or_return`,
		},
		{
			template      = `{{ this.q | default("all") | url_param }}`,
			expected_call = `__temple_write_url_param(__temple_w, __temple_default(this.q, "all")) or_return`,
		},
		{
			template      = `{{ url_param(default(this.q, "all")) }}`,
			expected_call = `__temple_write_url_param(__temple_w, __temple_default(this.q, "all")) or_return`,
		},
		{
			template      = `{{ this.payload | default("none") | js }}`,
			expected_call = `__temple_write_js_string(__temple_w, __temple_default(this.payload, "none")) or_return`,
		},
		{
			template      = `{{ js(default(this.payload, "none")) }}`,
			expected_call = `__temple_write_js_string(__temple_w, __temple_default(this.payload, "none")) or_return`,
		},
	}

	for c in cases {
		s := scenario_begin(t)
		upon_compiling_inline(s, c.template)
		then_emits_writer_call(s, c.expected_call)
		scenario_end(s)
	}
}

@(test)
spec_rejects_invalid_context_escaping_calls_and_pipe_chains :: proc(t: ^testing.T) {
	Invalid_Escaping_Case :: struct {
		template:     string,
		col:          int,
		expected_err: string,
	}

	cases := []Invalid_Escaping_Case{
		{
			template     = `{{ url() }}`,
			col          = 4,
			expected_err = `"url()" expects exactly 1 argument, got 0`,
		},
		{
			template     = `{{ url(this.a, this.b) }}`,
			col          = 4,
			expected_err = `"url()" expects exactly 1 argument, got 2`,
		},
		{
			template     = `{{ url_param() }}`,
			col          = 4,
			expected_err = `"url_param()" expects exactly 1 argument, got 0`,
		},
		{
			template     = `{{ url_param(this.a, this.b) }}`,
			col          = 4,
			expected_err = `"url_param()" expects exactly 1 argument, got 2`,
		},
		{
			template     = `{{ js() }}`,
			col          = 4,
			expected_err = `"js()" expects exactly 1 argument, got 0`,
		},
		{
			template     = `{{ js(this.a, this.b) }}`,
			col          = 4,
			expected_err = `"js()" expects exactly 1 argument, got 2`,
		},
		{
			template     = `{% block body %}{{ url(super()) }}{% end %}`,
			col          = 24,
			expected_err = `"super()" cannot be used inside "url()"`,
		},
		{
			template     = `{% block body %}{{ url_param(super()) }}{% end %}`,
			col          = 30,
			expected_err = `"super()" cannot be used inside "url_param()"`,
		},
		{
			template     = `{% block body %}{{ js(super()) }}{% end %}`,
			col          = 23,
			expected_err = `"super()" cannot be used inside "js()"`,
		},
		{
			template     = `{{ this.link | url | raw }}`,
			col          = 22,
			expected_err = "cannot pipe additional filters after terminal output modifier",
		},
		{
			template     = `{{ this.q | url_param | default("x") }}`,
			col          = 25,
			expected_err = "cannot pipe additional filters after terminal output modifier",
		},
		{
			template     = `{{ this.payload | js | raw }}`,
			col          = 24,
			expected_err = "cannot pipe additional filters after terminal output modifier",
		},
		{
			template     = `{{ this.link | url | fmt("%s") }}`,
			col          = 22,
			expected_err = "cannot pipe additional filters after terminal output modifier",
		},
		{
			template     = `{{ url(raw(this.link)) }}`,
			col          = 8,
			expected_err = `cannot wrap terminal output modifier inside "url()"`,
		},
		{
			template     = `{{ raw(url(this.link)) }}`,
			col          = 8,
			expected_err = `cannot wrap terminal output modifier inside "raw()"`,
		},
	}

	for c in cases {
		s := scenario_begin(t)
		upon_compiling_inline(s, c.template, called_from = "/app/view.odin", line = 3, col = 1)
		then_diagnostic_is_reported(
			s,
			file             = "/app/view.odin",
			line             = 3,
			col              = c.col,
			message_contains = c.expected_err,
		)
		scenario_end(s)
	}
}

@(test)
spec_warn_unused_identifies_orphan_templates_and_excludes_layouts_and_embeds :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	given_template(
		s,
		"/app/views/home.temple.twig",
		`{% extends "../layouts/base.temple.twig" %}{% block body %}{% embed "../partials/card.temple.twig" %}{% end %}`,
	)
	given_template(
		s,
		"/app/layouts/base.temple.twig",
		`<html>{% block body %}{% end %}{% embed "../partials/footer.temple.html" %}</html>`,
	)
	given_template(s, "/app/partials/card.temple.twig", `<div>Card</div>`)
	given_template(s, "/app/partials/footer.temple.html", `<footer>Foot</footer>`)
	given_template(s, "/app/views/orphan_page.temple.twig", `<p>Never compiled</p>`)
	given_template(s, "/app/partials/unused_widget.temple.html", `<span>Never embedded</span>`)
	given_template(s, "/app/public/static_landing.html", `<h1>Static non-template HTML</h1>`)

	upon_compiling_template(s, "/app/views/home.temple.twig", relpath = "views/home.temple.twig")

	then_used_templates_are(s, {
		"/app/layouts/base.temple.twig",
		"/app/partials/card.temple.twig",
		"/app/partials/footer.temple.html",
		"/app/views/home.temple.twig",
	})
	then_unused_templates_are(s, {
		"/app/partials/unused_widget.temple.html",
		"/app/views/orphan_page.temple.twig",
	})
}

@(test)
spec_check_mode_verifies_up_to_date_and_rejects_stale_or_missing_generated_file :: proc(t: ^testing.T) {
	// 1. Missing generated file on disk fails `--check`
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		upon_compiling_inline(s, `<h1>{{ this.title }}</h1>`)
		then_check_mode_matches_existing_file(s, false)
	}

	// 2. Stale generated file on disk fails `--check`
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		given_existing_generated_file(s, "/* This file was generated by temple on 2026-01-01 - DO NOT EDIT! */\n\npackage temple\n// stale\n")
		upon_compiling_inline(s, `<h1>{{ this.title }}</h1>`)
		then_check_mode_matches_existing_file(s, false)
	}

	// 3. Up-to-date generated file (even with different timestamp header or Windows CRLF line endings) passes `--check`
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		upon_compiling_inline(s, `<h1>{{ this.title }}</h1>`)
		with_timestamp := strings.concatenate({
			"/* This file was generated by temple on 2026-10-31 12:00:00 - DO NOT EDIT! */\r\n\r\n",
			s.generated_file,
		}, s.alloc)
		crlf_existing, _ := strings.replace_all(with_timestamp, "\n", "\r\n", s.alloc)
		given_existing_generated_file(s, crlf_existing)
		then_check_mode_matches_existing_file(s, true)
	}
}

@(test)
spec_cross_platform_backslash_paths_normalize_in_codegen_embeds_and_diagnostics :: proc(t: ^testing.T) {
	// 1. Backslashes in `relpath`, `extends`, and `embed` normalize to `/` in generated code and comments
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		given_template(s, "/app/layouts/base.html", `<main>{% block body %}{% end %}</main>`)
		given_template(s, "/app/partials/card.html", `<section>Card</section>`)
		given_template(
			s,
			"/app/views/home.html",
			`{% extends "..\\layouts\\base.html" %}{% block body %}{% embed "..\\partials\\card.html" %}{% end %}`,
		)

		upon_compiling_template(s, "/app/views/home.html", relpath = `views\home.html`)

		then_generated_file_contains(s, `when path == "views/home.html"`)
		then_emits_writer_call(s, `embedding "../partials/card.html"`)
		then_static_literals_render_in_order(s, {
			"<main>",
			"<section>Card</section>",
			"</main>",
		})
	}

	// 2. Backslashes in `temple.compiled` call sites normalize to `/` during call collection
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		upon_scanning_odin_source(s, `package sample
import "temple"

view := temple.compiled("views\\dashboard\\index.temple.twig", int)
`)

		then_collected_templates_are(s, {"views/dashboard/index.temple.twig"})
	}

	// 3. Diagnostic coordinates and trace stack normalize `\` to `/`
	{
		s := scenario_begin(t)
		defer scenario_end(s)

		given_template(s, "/app/views/page.html", `{% embed "sub\\missing.html" %}`)

		upon_compiling_template(
			s,
			`/\app\views\page.html`,
			relpath     = `views\page.html`,
			called_from = `\app\routes.odin`,
			line        = 15,
			col         = 4,
		)

		then_diagnostic_is_reported(
			s,
			file             = "/app/views/page.html",
			line             = 1,
			col              = 10,
			message_contains = "unable to read template file",
			trace            = {
				{kind = .Call_Site, file = "/app/routes.odin",     line = 15, col = 4},
				{kind = .Embed,     file = "/app/views/page.html", line = 1,  col = 10},
			},
		)
	}
}

// ============================================================================
// Pattern D: Property-Based Invariants (Lexer Progress & Parser Crash-Freedom)
// ============================================================================

@(test)
property_lexer_strictly_advances_and_parser_never_panics_on_arbitrary_inputs :: proc(t: ^testing.T) {
	vocab := []string{
		"{{", "}}", "{{-", "-}}", "{%", "%}", "{%-", "-%}",
		"{#", "#}", "{#-", "-#}", "{-#", "#-}",
		"\"", "'", "`", "\\", "\n", "\r\n", "\t", " ",
		"if", "else", "elseif", "else if", "end",
		"switch", "#partial switch", "case", "let",
		"embed", "with", "extends", "block", "super", "super()", "macro", "call",
		"raw(", "magic(", "url(", "url_param(", "js(", "json(", "fmt(", "default(", "int(",
		"raw", "magic", "url", "url_param", "js", "json", "len", "|", "(", ")", "[", "]", ",", "=", ":=", ":",
		"this.x", "a", "123",
	}

	state: u64 = 0xCAFE_BABE_1234_5678
	next_u64 :: proc(s: ^u64) -> u64 {
		x := s^
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		s^ = x
		return x
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	for _ in 0 ..< 500 {
		mem.dynamic_arena_reset(&arena)

		sb := strings.builder_make(alloc)
		pieces := int(next_u64(&state) % 24) + 1
		for _ in 0 ..< pieces {
			strings.write_string(&sb, vocab[int(next_u64(&state) % u64(len(vocab)))])
		}
		fuzz_src := strings.to_string(sb)

		// Invariant 1: Lexer cursor strictly advances on every token and terminates
		l: Lexer
		lexer_init(&l, fuzz_src)
		prev_cursor := -1
		for step in 0 ..= len(fuzz_src) + 2 {
			tok := lexer_next(&l)
			testing.expect(t, step <= len(fuzz_src) + 1, "lexer failed to terminate")
			if tok.type == .EOF do break
			testing.expect(t, l.cursor > prev_cursor, "lexer cursor stalled")
			prev_cursor = l.cursor
		}

		// Invariant 2: Parser never panics or slices out-of-bounds
		p: Parser
		parser_init(&p, fuzz_src, alloc)
		templ := parse(&p)

		// Invariant 3: Whenever `parse(&p)` succeeds, `transpile` never panics or slices out-of-bounds
		if templ.err == nil {
			out_sb := strings.builder_make(alloc)
			transpile(strings.to_writer(&out_sb), "fuzz", templ, nil, nil, alloc)
		}
	}
}

@(test)
spec_multi_level_layout_inheritance_does_not_mutate_cached_blocks_or_poison_resolved_cache :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	given_template(
		s,
		"/app/layouts/base.html",
		`<html>{% block body %}BASE{% end %}</html>`,
	)
	given_template(
		s,
		"/app/layouts/section.html",
		`{% extends "base.html" %}{% block body %}[SECTION:{{ super() }}]{% end %}`,
	)
	given_template(
		s,
		"/app/views/page_a.html",
		`{% extends "../layouts/section.html" %}{% block body %}(A:{{ super() }}){% end %}`,
	)
	given_template(
		s,
		"/app/views/page_b.html",
		`{% extends "../layouts/section.html" %}{% block body %}(B:{{ super() }}){% end %}`,
	)

	// 1. Compile the intermediate layout as a standalone root template first
	upon_compiling_template(s, "/app/layouts/section.html", relpath = "layouts/section.html")
	then_static_literals_render_in_order(s, {
		"<html>[SECTION:BASE]</html>",
	})

	// 2. Compile child template A extending `section.html` in the same Compile_Context
	upon_compiling_template(s, "/app/views/page_a.html", relpath = "views/page_a.html")
	then_static_literals_render_in_order(s, {
		"<html>(A:[SECTION:BASE])</html>",
	})

	// 3. Compile child template B extending `section.html` in the same Compile_Context
	//    (must not see mutated `section.html` block body from earlier compilations)
	upon_compiling_template(s, "/app/views/page_b.html", relpath = "views/page_b.html")
	then_static_literals_render_in_order(s, {
		"<html>(B:[SECTION:BASE])</html>",
	})
}

@(test)
spec_collects_top_level_proc_aliases_to_imported_views_packages :: proc(t: ^testing.T) {
	s := scenario_begin(t)
	defer scenario_end(s)

	upon_scanning_odin_source(s, `package controllers
import v "../views"

render_tpl    :: v.compiled
render_inline :: v.compiled_inline

main :: proc() {
	_ = render_tpl("users/profile.temple.twig", int)
	_ = render_inline("<p>{{ this }}</p>", int)
}
`)

	then_collected_templates_are(s, {
		"users/profile.temple.twig",
		"<p>{{ this }}</p>",
	})
}

