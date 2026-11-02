package temple_cli

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Helper to tokenize, parse, and transpile a template string in memory.
parse_template :: proc(src: string, allocator := context.temp_allocator) -> (tmpl: Template, ok: bool) {
	p: Parser
	parser_init(&p, src, allocator)
	tmpl = parse(&p)
	ok = tmpl.err == nil
	return
}

transpile_to_string :: proc(src: string) -> (out: string, ok: bool) {
	context.allocator = context.temp_allocator

	tmpl, parse_ok := parse_template(src, context.temp_allocator)
	if !parse_ok {
		return "", false
	}

	sb := strings.builder_make(context.temp_allocator)
	transpile(strings.to_writer(&sb), "inline", tmpl, nil, nil, context.temp_allocator)
	return strings.to_string(sb), true
}

@(test)
test_whitespace_trimming_lexer_and_output :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// 1. Both-side trimming around statements and outputs
	src := "<div>\n  {%- if this.show -%}\n    <span>{{- this.name -}}</span>\n  {%- end -%}\n</div>"
	tmpl, ok := parse_template(src)
	testing.expect(t, ok, "expected template with whitespace trim markers to parse")

	// First text node should have its trailing newline and spaces stripped ("<div>")
	first_text, is_text := tmpl.content[0].derived.(^Node_Text)
	testing.expect(t, is_text)
	if is_text {
		testing.expect_value(t, first_text.text.value, "<div>")
	}

	// Last text node should have its leading newline stripped ("</div>")
	last_text, is_last_text := tmpl.content[len(tmpl.content) - 1].derived.(^Node_Text)
	testing.expect(t, is_last_text)
	if is_last_text {
		testing.expect_value(t, last_text.text.value, "</div>")
	}
}

@(test)
test_transpile_raw_output :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	code, ok := transpile_to_string(`{{ raw(this.trusted_html) }}`)
	testing.expect(t, ok)

	// Verify `raw(...)` emits a direct `write_string` call rather than HTML escaping
	testing.expect(
		t,
		strings.contains(code, ".write_string(__temple_w, this.trusted_html) or_return"),
		"expected raw() to transpile to direct write_string call",
	)
}

@(test)
test_let_bindings_valid_and_invalid :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// 1. Twig-style `=` normalizes to `:=`
	{
		code, ok := transpile_to_string(`{% let total = this.price * this.qty %}`)
		testing.expect(t, ok)
		testing.expect(t, strings.contains(code, "total := this.price * this.qty"))
	}

	// 2. Odin-style `:=` (`x :=` and `x: =`) and explicit type `: int =` are preserved/normalized
	{
		code, ok := transpile_to_string(`{% let a := 10 %}{% let a_space: = 15 %}{% let b: int = 20 %}`)
		testing.expect(t, ok)
		testing.expect(t, strings.contains(code, "a := 10"))
		testing.expect(t, strings.contains(code, "a_space := 15"))
		testing.expect(t, strings.contains(code, "b: int = 20"))
	}

	// 3. Invalid `let` statements (including trailing tokens) should be rejected by the parser
	invalid_cases := []string{
		`{% let %}`,
		`{% let x %}`,
		`{% let x == 5 %}`,
		`{% let x = %}`,
		`{% let x = 1 bogus %}`,
	}
	for src in invalid_cases {
		_, ok := parse_template(src)
		testing.expectf(t, !ok, "expected malformed let %q to fail parsing", src)
	}
}

@(test)
test_switch_and_partial_switch_parsing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// 1. Standard switch + default case
	{
		src := `
		{% switch v in this.state %}
			{% case int %}
				<span>Int</span>
			{% case %}
				<span>Default</span>
		{% end %}`

		code, ok := transpile_to_string(src)
		testing.expect(t, ok)
		testing.expect(t, strings.contains(code, "switch v in this.state {"))
		testing.expect(t, strings.contains(code, "case int:"))
		testing.expect(t, strings.contains(code, "case:"))
	}

	// 2. `#partial switch` on an enum
	{
		src := `
		{% #partial switch this.status %}
			{% case .Active, .Pending %}
				Active
		{% end %}`

		code, ok := transpile_to_string(src)
		testing.expect(t, ok)
		testing.expect(t, strings.contains(code, "#partial switch this.status {"))
		testing.expect(t, strings.contains(code, "case .Active, .Pending:"))
	}

	// 3. Invalid switch blocks should fail in the CLI parser
	invalid_switches := []string{
		// Non-whitespace HTML between `switch` and first `case`
		`{% switch this.x %}<div>stray html</div>{% case 1 %}ok{% end %}`,
		// Switch with zero cases
		`{% switch this.x %}{% end %}`,
		// Duplicate default `case`
		`{% switch this.x %}{% case %}A{% case %}B{% end %}`,
		// Unclosed switch
		`{% switch this.x %}{% case 1 %}A`,
	}
	for src in invalid_switches {
		_, ok := parse_template(src)
		testing.expectf(t, !ok, "expected invalid switch %q to fail parsing", src)
	}
}

@(test)
test_walker_skips_dot_directories_and_visits_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	cwd, _ := os.get_working_directory(context.temp_allocator)
	tmp_root, _ := filepath.join({cwd, ".tmp", "temple_walker_test"}, context.temp_allocator)
	hidden_dir, _ := filepath.join({tmp_root, ".git"}, context.temp_allocator)
	sub_dir, _ := filepath.join({tmp_root, "routes"}, context.temp_allocator)

	_ = os.make_directory_all(hidden_dir)
	_ = os.make_directory_all(sub_dir)
	defer os.remove_all(tmp_root)

	root_file, _ := filepath.join({tmp_root, "root.odin"}, context.temp_allocator)
	sub_file, _ := filepath.join({sub_dir, "routes.odin"}, context.temp_allocator)
	hidden_file, _ := filepath.join({hidden_dir, "ignored.odin"}, context.temp_allocator)

	_ = os.write_entire_file(
		root_file,
		transmute([]byte)string(`package main; import "temple"; a :: proc() { _ = temple.compiled_inline("root", int) }`),
	)
	_ = os.write_entire_file(
		sub_file,
		transmute([]byte)string(`package routes; import "temple"; b :: proc() { _ = temple.compiled_inline("sub", int) }`),
	)
	_ = os.write_entire_file(
		hidden_file,
		transmute([]byte)string(`package ignored; import "temple"; c :: proc() { _ = temple.compiled_inline("hidden", int) }`),
	)

	calls := collect_compile_calls(tmp_root, context.temp_allocator)

	// Should find the root call and nested `routes` call, but skip `.git`
	testing.expect_value(t, len(calls), 2)
}

@(test)
test_output_expression_validation_and_casts :: proc(t: ^testing.T) {
	// 1. Valid output with raw(...) and compound expressions
	{
		p: Parser
		parser_init(&p, `{{ raw(this.html) }} / {{ raw(this.a) + raw(this.b) }} / {{ int(this.count) }}`, context.temp_allocator)
		templ := parse(&p)
		testing.expect(t, templ.err == nil, "expected valid template")
		testing.expect_value(t, len(templ.content), 5)

		out0 := templ.content[0].derived.(^Node_Output)
		testing.expect_value(t, out0.write_kind, Output_Write_Kind.Raw_String)
		testing.expect_value(t, out0.inner_expr, "this.html")

		// Compound expression `raw(this.a) + raw(this.b)` should NOT be misclassified as top-level `raw(...)`
		out1 := templ.content[2].derived.(^Node_Output)
		testing.expect_value(t, out1.write_kind, Output_Write_Kind.Escaped_String)
		testing.expect_value(t, out1.inner_expr, "raw(this.a) + raw(this.b)")

		out2 := templ.content[4].derived.(^Node_Output)
		testing.expect_value(t, out2.write_kind, Output_Write_Kind.Int)
		testing.expect_value(t, out2.inner_expr, "int(this.count)")
	}

	// 2. Invalid raw() argument count
	{
		p: Parser
		parser_init(&p, `{{ raw(a, b) }}`, context.temp_allocator)
		templ := parse(&p)
		err, has_err := templ.err.?
		testing.expect(t, has_err, "expected error for raw(a, b)")
		if has_err {
			testing.expect(t, strings.contains(err.msg, "\"raw()\" expects exactly 1 argument"), err.msg)
		}
	}

	// 3. Invalid assignment inside {{ ... }}
	{
		p: Parser
		parser_init(&p, `{{ this.a = 1 }}`, context.temp_allocator)
		templ := parse(&p)
		err, has_err := templ.err.?
		testing.expect(t, has_err, "expected error for assignment inside output tag")
		if has_err {
			testing.expect(t, strings.contains(err.msg, "statements/assignments are not allowed"), err.msg)
		}
	}

	// 4. Empty output expression
	{
		p: Parser
		parser_init(&p, `{{   }}`, context.temp_allocator)
		templ := parse(&p)
		_, has_err := templ.err.?
		testing.expect(t, has_err, "expected error for empty output tag")
	}

	// 5. Unclosed if block reports opening coordinates
	{
		p: Parser
		parser_init(&p, "line1\n{% if this.ok %}\nhello", context.temp_allocator)
		templ := parse(&p)
		err, has_err := templ.err.?
		testing.expect(t, has_err, "expected error for unclosed if tag")
		if has_err {
			testing.expect(t, strings.contains(err.msg, "unclosed \"if\" tag (opened at 2:1)"), err.msg)
		}
	}
}

@(test)
test_layout_extends_block_and_super :: proc(t: ^testing.T) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	tmp_dir, _ := filepath.join({cwd, ".tmp", "test_layouts"}, context.temp_allocator)
	os.make_directory_all(tmp_dir)
	defer os.remove_all(tmp_dir)

	base_path, _ := filepath.join({tmp_dir, "base.html"}, context.temp_allocator)
	section_path, _ := filepath.join({tmp_dir, "section.html"}, context.temp_allocator)
	page_path, _ := filepath.join({tmp_dir, "page.html"}, context.temp_allocator)
	bad_block_path, _ := filepath.join({tmp_dir, "bad_block.html"}, context.temp_allocator)

	_ = os.write_entire_file(
		base_path,
		transmute([]byte)string(`<html><head><title>{% block title %}Base{% end %}</title></head><body>{% block body %}Default{% end %}</body></html>`),
	)
	_ = os.write_entire_file(
		section_path,
		transmute([]byte)string(`{% extends "base.html" %}{% block title %}{{ super() }} - Section{% end %}{% block body %}<main>{% block content %}Empty{% end %}</main>{% end %}`),
	)
	_ = os.write_entire_file(
		page_path,
		transmute([]byte)string(`{% extends "section.html" %}{% block title %}{{ super() }} - Page{% end %}{% block content %}<p>{{ this.title }}</p>{% end %}`),
	)
	_ = os.write_entire_file(
		bad_block_path,
		transmute([]byte)string(`{% extends "base.html" %}{% block unknown_blk %}Oops{% end %}`),
	)

	// 1. Multi-level layout with super() and nested blocks
	{
		ctx: Compile_Context
		ctx.allocator = context.temp_allocator
		ctx.diagnostics = make([dynamic]Diagnostic, context.temp_allocator)

		call := Compile_Call{
			identifier = "page.html",
			type = Call_Path{
				relpath  = "page.html",
				fullpath = page_path,
			},
		}

		code, ok := compile_single_call(&ctx, call)
		testing.expect(t, ok, "expected multi-level layout compilation to succeed")
		testing.expect_value(t, len(ctx.diagnostics), 0)
		testing.expect(t, strings.contains(code, `"<html><head><title>Base - Section - Page</title></head><body><main><p>"`), "expected coalesced title and section body wrapper across blocks")
		testing.expect(t, strings.contains(code, `this.title`), "expected page content expression")
	}

	// 2. Unknown block in child template reports available parent blocks
	{
		ctx: Compile_Context
		ctx.allocator = context.temp_allocator
		ctx.diagnostics = make([dynamic]Diagnostic, context.temp_allocator)

		call := Compile_Call{
			identifier = "bad_block.html",
			type = Call_Path{
				relpath  = "bad_block.html",
				fullpath = bad_block_path,
			},
		}

		_, ok := compile_single_call(&ctx, call)
		testing.expect(t, !ok, "expected unknown block to fail compilation")
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) > 0 {
			msg := ctx.diagnostics[0].message
			testing.expect(t, strings.contains(msg, "unknown block \"unknown_blk\""), msg)
			testing.expect(t, strings.contains(msg, "body, title"), msg)
		}
	}
}

@(test)
test_embed_error_trace_and_cycle_detection :: proc(t: ^testing.T) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	tmp_dir, _ := filepath.join({cwd, ".tmp", "test_embeds"}, context.temp_allocator)
	os.make_directory_all(tmp_dir)
	defer os.remove_all(tmp_dir)

	root_path, _ := filepath.join({tmp_dir, "root.html"}, context.temp_allocator)
	card_path, _ := filepath.join({tmp_dir, "card.html"}, context.temp_allocator)
	cycle_a_path, _ := filepath.join({tmp_dir, "cycle_a.html"}, context.temp_allocator)
	cycle_b_path, _ := filepath.join({tmp_dir, "cycle_b.html"}, context.temp_allocator)

	_ = os.write_entire_file(root_path, transmute([]byte)string(`<div>{% embed "card.html" %}</div>`))
	_ = os.write_entire_file(card_path, transmute([]byte)string(`<section>{% embed "missing.html" %}</section>`))
	_ = os.write_entire_file(cycle_a_path, transmute([]byte)string(`{% embed "cycle_b.html" %}`))
	_ = os.write_entire_file(cycle_b_path, transmute([]byte)string(`{% embed "cycle_a.html" %}`))

	// 1. Nested missing embed preserves full trace stack
	{
		ctx: Compile_Context
		ctx.allocator = context.temp_allocator
		ctx.diagnostics = make([dynamic]Diagnostic, context.temp_allocator)

		call := Compile_Call{
			identifier = "root.html",
			type = Call_Path{
				relpath  = "root.html",
				fullpath = root_path,
			},
		}

		_, ok := compile_single_call(&ctx, call)
		testing.expect(t, !ok, "expected missing nested embed to fail")
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) > 0 {
			d := ctx.diagnostics[0]
			testing.expect(t, strings.contains(d.message, "unable to read template file"), d.message)
			// Trace should contain Call_Site -> Embed(card.html) -> Embed(missing.html)
			testing.expect_value(t, len(d.trace), 3)
			testing.expect_value(t, d.trace[0].kind, Trace_Kind.Call_Site)
			testing.expect_value(t, d.trace[1].kind, Trace_Kind.Embed)
			testing.expect_value(t, d.trace[2].kind, Trace_Kind.Embed)
		}
	}

	// 2. Circular embed is caught cleanly
	{
		ctx: Compile_Context
		ctx.allocator = context.temp_allocator
		ctx.diagnostics = make([dynamic]Diagnostic, context.temp_allocator)

		call := Compile_Call{
			identifier = "cycle_a.html",
			type = Call_Path{
				relpath  = "cycle_a.html",
				fullpath = cycle_a_path,
			},
		}

		_, ok := compile_single_call(&ctx, call)
		testing.expect(t, !ok, "expected circular embed to fail")
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) > 0 {
			testing.expect(t, strings.contains(ctx.diagnostics[0].message, "circular embed detected"), ctx.diagnostics[0].message)
		}
	}
}

@(test)
test_collect_compile_calls_aliases_and_consts :: proc(t: ^testing.T) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	tmp_dir, _ := filepath.join({cwd, ".tmp", "test_collect"}, context.temp_allocator)
	os.make_directory_all(tmp_dir)
	defer os.remove_all(tmp_dir)

	src_file, _ := filepath.join({tmp_dir, "routes.odin"}, context.temp_allocator)
	code := `package routes

import tpl "temple"

DIR :: "pages/"
HOME_PATH :: DIR + "home.html"
compile_tpl :: tpl.compiled
inline_tpl  :: tpl.compiled_inline

Ctx :: struct { name: string }

a := compile_tpl(HOME_PATH, Ctx)
b := tpl.compiled(path = DIR + "about.html", T = Ctx)
c := inline_tpl("Hello {{ this.name }}", Ctx)
`
	_ = os.write_entire_file(src_file, transmute([]byte)code)

		calls := collect_compile_calls(tmp_dir, context.temp_allocator)
		testing.expect_value(t, len(calls), 3)
		if len(calls) == 3 {
			testing.expect_value(t, calls[0].identifier, "pages/home.html")
			testing.expect_value(t, calls[1].identifier, "pages/about.html")
			testing.expect_value(t, calls[2].identifier, "Hello {{ this.name }}")
		}
}

@(test)
test_review_regressions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// 1. Multiline expressions with trailing tokens in output or with tags are rejected,
	// while valid CRLF / multiline single expressions are accepted.
	{
		_, ok_bad_out := parse_template("{{\n this.a\n this.b\n}}")
		testing.expect(t, !ok_bad_out, "expected two expressions separated by newline in {{ ... }} to fail")

		_, ok_good_crlf := parse_template("{{ this.a +\r\n this.b\r\n}}")
		testing.expect(t, ok_good_crlf, "expected multiline CRLF expression in {{ ... }} to succeed")

		_, ok_bad_with := parse_template("{% embed \"card.html\" with\n this.a\n this.b\n%}")
		testing.expect(t, !ok_bad_with, "expected trailing token after newline in with expression to fail")
	}

	// 2. Trailing tokens in if, for, and switch headers (e.g., premature `}`) are rejected
	{
		_, ok_if := parse_template(`{% if this.ok } extra %}hello{% end %}`)
		testing.expect(t, !ok_if, "expected trailing token in if condition to fail")

		_, ok_for := parse_template(`{% for item in this.items } extra %}hello{% end %}`)
		testing.expect(t, !ok_for, "expected trailing token in for clause to fail")

		_, ok_sw := parse_template(`{% switch this.state } extra %}{% case 1 %}hi{% end %}`)
		testing.expect(t, !ok_sw, "expected trailing token in switch expression to fail")
	}

	// 3. Orphan super() inside a child-only nested block is caught during layout splicing
	{
		cwd, _ := os.get_working_directory(context.temp_allocator)
		tmp_dir, _ := filepath.join({cwd, ".tmp", "test_review_regressions"}, context.temp_allocator)
		os.make_directory_all(tmp_dir)
		defer os.remove_all(tmp_dir)

		base_path, _ := filepath.join({tmp_dir, "base.html"}, context.temp_allocator)
		child_path, _ := filepath.join({tmp_dir, "child.html"}, context.temp_allocator)
		broken_embed_1, _ := filepath.join({tmp_dir, "broken1.html"}, context.temp_allocator)
		broken_embed_2, _ := filepath.join({tmp_dir, "broken2.html"}, context.temp_allocator)

		_ = os.write_entire_file(base_path, transmute([]byte)string(`<div>{% block body %}Base{% end %}</div>`))
		_ = os.write_entire_file(
			child_path,
			transmute([]byte)string(`{% extends "base.html" %}{% block body %}{% block child_only %}{{ super() }}{% end %}{% end %}`),
		)
		_ = os.write_entire_file(broken_embed_1, transmute([]byte)string(`{% embed "missing.html" %}`))
		_ = os.write_entire_file(broken_embed_2, transmute([]byte)string(`{% embed "missing.html" %}`))

		ctx: Compile_Context
		ctx.allocator = context.temp_allocator
		ctx.diagnostics = make([dynamic]Diagnostic, context.temp_allocator)

		_, ok_super := compile_single_call(&ctx, Compile_Call{
			identifier = "child.html",
			type = Call_Path{relpath = "child.html", fullpath = child_path},
		})
		testing.expect(t, !ok_super, "expected orphan super() in child-only nested block to fail")
		testing.expect_value(t, len(ctx.diagnostics), 1)

		// 4. Missing embed diagnostic caret length matches token `"missing.html"` (14 chars), not absolute path,
		// and subsequent calls in the same worker batch still emit diagnostics (raw_cache does not cache failures).
		clear_trace_frames(&ctx)
		clear(&ctx.diagnostics)
		_, ok_b1 := compile_single_call(&ctx, Compile_Call{
			identifier = "broken1.html",
			type = Call_Path{relpath = "broken1.html", fullpath = broken_embed_1},
		})
		testing.expect(t, !ok_b1)
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) == 1 {
			testing.expect_value(t, ctx.diagnostics[0].col_len, len(`"missing.html"`))
		}

		clear_trace_frames(&ctx)
		clear(&ctx.diagnostics)
		_, ok_b2 := compile_single_call(&ctx, Compile_Call{
			identifier = "broken2.html",
			type = Call_Path{relpath = "broken2.html", fullpath = broken_embed_2},
		})
		testing.expect(t, !ok_b2)
		testing.expect_value(t, len(ctx.diagnostics), 1)
	}

	// 5. Inline template error extracts the snippet from the inline string, not the Odin file line offset
	{
		ctx: Compile_Context
		ctx.allocator = context.temp_allocator
		ctx.diagnostics = make([dynamic]Diagnostic, context.temp_allocator)

		call := Compile_Call{
			pos        = {file = "routes.odin", line = 42, column = 15},
			identifier = "<div>{{ }}</div>",
			type       = Call_Inline{template = "<div>{{ }}</div>"},
		}
		_, ok_inline := compile_single_call(&ctx, call)
		testing.expect(t, !ok_inline)
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) == 1 {
			testing.expect_value(t, ctx.diagnostics[0].pos.line, 42)
			testing.expect_value(t, ctx.diagnostics[0].snippet, "<div>{{ }}</div>")
			testing.expect_value(t, ctx.diagnostics[0].caret_col, 8)
		}

		// Multiline inline template failing on line 2 (`err.pos.line == 1`)
		clear_trace_frames(&ctx)
		clear(&ctx.diagnostics)
		multiline_src := "<div>\n  <span>{{ }}</span>\n</div>"
		call_ml := Compile_Call{
			pos        = {file = "routes.odin", line = 100, column = 20},
			identifier = multiline_src,
			type       = Call_Inline{template = multiline_src},
		}
		_, ok_ml := compile_single_call(&ctx, call_ml)
		testing.expect(t, !ok_ml)
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) == 1 {
			testing.expect_value(t, ctx.diagnostics[0].pos.line, 101)
			testing.expect_value(t, ctx.diagnostics[0].snippet, "  <span>{{ }}</span>")
			testing.expect_value(t, ctx.diagnostics[0].caret_col, 11)
		}
	}

	// 6. Transpiling `{% embed %}` with `embed_parser == nil` does not crash
	{
		code, ok := transpile_to_string(`{% embed "card.html" with this.user %}`)
		testing.expect(t, ok, "expected transpile_to_string with nil embed_parser to succeed")
		testing.expect(t, strings.contains(code, "this := this.user"))
	}

	// 7. Standalone process tags (`let`, `switch`, `block`, `embed`, `for`, `if`) strip preceding line indentation
	{
		for src in ([]string{
			"<div>\n    {% let x = 1 %}",
			"<div>\n    {% switch this.x %}\n    {% case 1 %}ok{% end %}",
			"<div>\n    {% block content %}ok{% end %}",
			"<div>\n    {% embed \"card.html\" %}",
			"<div>\n    {% for item in this.items %}ok{% end %}",
			"<div>\n    {% if this.ok %}ok{% end %}",
		}) {
			tmpl, ok := parse_template(src)
			testing.expectf(t, ok, "expected %q to parse", src)
			if ok && len(tmpl.content) > 0 {
				txt, is_txt := tmpl.content[0].derived.(^Node_Text)
				testing.expect(t, is_txt)
				if is_txt {
					testing.expect_value(t, txt.text.value, "<div>\n")
				}
			}
		}
	}

	// 8. Cross-package duplicate relative template path collision & named parameter validation after `path = ...`
	{
		cwd, _ := os.get_working_directory(context.temp_allocator)
		tmp_dir, _ := filepath.join({cwd, ".tmp", "test_collect_collisions"}, context.temp_allocator)
		pkg_a, _ := filepath.join({tmp_dir, "pkg_a"}, context.temp_allocator)
		pkg_b, _ := filepath.join({tmp_dir, "pkg_b"}, context.temp_allocator)
		_ = os.make_directory_all(pkg_a)
		_ = os.make_directory_all(pkg_b)
		defer os.remove_all(tmp_dir)

		file_a, _ := filepath.join({pkg_a, "a.odin"}, context.temp_allocator)
		file_b, _ := filepath.join({pkg_b, "b.odin"}, context.temp_allocator)

		// Same file referenced twice in pkg_a (and via `../pkg_a/index.html` from pkg_b) deduplicates;
		// pkg_b referencing its own "index.html" collides;
		// pkg_b also has an invalid second named parameter after `path = "..."`.
		_ = os.write_entire_file(
			file_a,
			transmute([]byte)string(`package pkg_a; import "temple"; x := temple.compiled("index.html", int); y := temple.compiled("index.html", int)`),
		)
		_ = os.write_entire_file(
			file_b,
			transmute([]byte)string(`package pkg_b; import "temple"; z := temple.compiled("index.html", int); w := temple.compiled(path = "other.html", bad_param = int)`),
		)

		errs := make([dynamic]string, context.temp_allocator)
		calls := collect_compile_calls(tmp_dir, context.temp_allocator, &errs)
		testing.expect_value(t, len(calls), 1)
		testing.expect_value(t, len(errs), 2)
		if len(errs) == 2 {
			testing.expect(t, strings.contains(errs[0], `duplicate template path identifier "index.html"`), errs[0])
			testing.expect(t, strings.contains(errs[1], `unknown named parameter "bad_param"`), errs[1])
		}
	}
}

@(test)
test_review_round_two_fixes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// 1. Nested block overrides with super() do not duplicate child overrides or recurse infinitely
	{
		cwd, _ := os.get_working_directory(context.temp_allocator)
		tmp_dir, _ := filepath.join({cwd, ".tmp", "test_nested_super_splice"}, context.temp_allocator)
		os.make_directory_all(tmp_dir)
		defer os.remove_all(tmp_dir)

		base_path, _ := filepath.join({tmp_dir, "base.html"}, context.temp_allocator)
		child_path, _ := filepath.join({tmp_dir, "child.html"}, context.temp_allocator)
		parent_err_base, _ := filepath.join({tmp_dir, "err_base.html"}, context.temp_allocator)
		parent_err_child, _ := filepath.join({tmp_dir, "err_child.html"}, context.temp_allocator)
		dup_base, _ := filepath.join({tmp_dir, "dup_base.html"}, context.temp_allocator)

		_ = os.write_entire_file(
			base_path,
			transmute([]byte)string(`{% block body %}[Body:{% block content %}Default{% end %}]{% end %}`),
		)
		_ = os.write_entire_file(
			child_path,
			transmute([]byte)string(`{% extends "base.html" %}{% block body %}({{ super( ) }}){% end %}{% block content %}{{ super() }}+Extra{% end %}`),
		)
		_ = os.write_entire_file(
			parent_err_base,
			transmute([]byte)string("line1\n{% block body %}{% embed \"missing_in_base.html\" %}{% end %}"),
		)
		_ = os.write_entire_file(
			parent_err_child,
			transmute([]byte)string("{% extends \"err_base.html\" %}\n{% block body %}{{ super() }}{% end %}"),
		)
		_ = os.write_entire_file(
			dup_base,
			transmute([]byte)string(`{% block a %}1{% end %}{% block a %}2{% end %}`),
		)

		ctx: Compile_Context
		ctx.allocator = context.temp_allocator
		ctx.diagnostics = make([dynamic]Diagnostic, context.temp_allocator)

		code, ok := compile_single_call(&ctx, Compile_Call{
			identifier = "child.html",
			type = Call_Path{relpath = "child.html", fullpath = child_path},
		})
		testing.expect(t, ok, "expected nested super() override to compile")
		// Verify `+Extra` appears exactly once and is coalesced with `Default` and surrounding block text
		first_idx := strings.index(code, `"([Body:Default+Extra])"`)
		last_idx := strings.last_index(code, `"([Body:Default+Extra])"`)
		testing.expect(t, first_idx != -1 && first_idx == last_idx, "expected Default+Extra to be spliced and coalesced exactly once")

		// 2. Broken embed inside parent layout reports parent layout file and snippet, not child file
		clear_trace_frames(&ctx)
		clear(&ctx.diagnostics)
		_, ok_err := compile_single_call(&ctx, Compile_Call{
			identifier = "err_child.html",
			type = Call_Path{relpath = "err_child.html", fullpath = parent_err_child},
		})
		testing.expect(t, !ok_err)
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) == 1 {
			d := ctx.diagnostics[0]
			testing.expect_value(t, d.pos.file, normalize_slash_path(parent_err_base, context.temp_allocator))
			testing.expect_value(t, d.pos.line, 2)
			testing.expect(t, strings.contains(d.snippet, `missing_in_base.html`), d.snippet)
		}

		// 3. Duplicate block in non-extending base template is caught
		clear_trace_frames(&ctx)
		clear(&ctx.diagnostics)
		_, ok_dup := compile_single_call(&ctx, Compile_Call{
			identifier = "dup_base.html",
			type = Call_Path{relpath = "dup_base.html", fullpath = dup_base},
		})
		testing.expect(t, !ok_dup, "expected duplicate block in root template to fail")
		testing.expect_value(t, len(ctx.diagnostics), 1)
	}

	// 4. String literals containing `}}` or `%}` inside tags, newlines inside tags, comments `{# ... #}`, and `{% else if %}`
	{
		src := "{#- comment -#}\n" +
			"{{ \"100%}\" }} / {{ `raw }} text` }}\n" +
			"{%\n  if this.suffix == \"}}\"\n%}\n" +
			"  A\n" +
			"{% else if this.other == \"%}\" %}\n" +
			"  B\n" +
			"{% end\n%}"
		code, ok := transpile_to_string(src)
		testing.expect(t, ok, "expected quote-aware lexer, multiline keywords, comments, and else if to succeed")
		testing.expect(t, strings.contains(code, `"100%}"`), code)
		testing.expect(t, strings.contains(code, `else if this.other == "%}"`), code)
	}

	// 5. `{{ super(arg) }}` with arguments is rejected, while `{{ super( ) }}` is accepted inside a block
	{
		_, ok_super_ws := parse_template(`{% block a %}{{ super( ) }}{% end %}`)
		testing.expect(t, ok_super_ws, "expected {{ super( ) }} with whitespace to parse")

		_, ok_super_arg := parse_template(`{% block a %}{{ super(123) }}{% end %}`)
		testing.expect(t, !ok_super_arg, "expected {{ super(123) }} with arguments to fail")
	}

	// 6. `{% case %}` expressions are validated by Odin snippet parser, and `{% let %}` rejects compound assignments / reassignments
	{
		_, ok_bad_case := parse_template(`{% switch this.x %}{% case .Ready: %}ok{% end %}`)
		testing.expect(t, !ok_bad_case, "expected trailing colon in case expression to fail")

		_, ok_compound_let := parse_template(`{% let x += 1 %}`)
		testing.expect(t, !ok_compound_let, "expected compound assignment in let to fail")

		_, ok_index_let := parse_template(`{% let x[0:2] = y %}`)
		testing.expect(t, !ok_index_let, "expected slice assignment on LHS of let to fail")

		code_slice_rhs, ok_slice_rhs := transpile_to_string(`{% let x = this.items[0:2] %}`)
		testing.expect(t, ok_slice_rhs, "expected slice on RHS of let to succeed")
		testing.expect(t, strings.contains(code_slice_rhs, "x := this.items[0:2]"), code_slice_rhs)
	}

	// 7. Route directories with `[slug]`, local constant isolation, variable shadowing, and duplicate named arguments
	{
		cwd, _ := os.get_working_directory(context.temp_allocator)
		tmp_dir, _ := filepath.join({cwd, ".tmp", "test_glob_and_scopes"}, context.temp_allocator)
		bracket_dir, _ := filepath.join({tmp_dir, "routes", "[slug]"}, context.temp_allocator)
		_ = os.make_directory_all(bracket_dir)
		defer os.remove_all(tmp_dir)

		file_1, _ := filepath.join({bracket_dir, "a_first.odin"}, context.temp_allocator)
		file_2, _ := filepath.join({bracket_dir, "b_second.odin"}, context.temp_allocator)

		// file_1 defines package constant `TPL :: "pkg.html"`, a proc with a local constant `LOCAL_ONLY`,
		// a proc that shadows `TPL` with a mutable variable `TPL := "runtime"`,
		// and a call with duplicate `path = ...` named arguments.
		_ = os.write_entire_file(
			file_1,
			transmute([]byte)string(`package slug_route
import "temple"
TPL :: "pkg.html"
p1 :: proc() {
	LOCAL_ONLY :: "local.html"
	_ = temple.compiled(LOCAL_ONLY, int)
}
p2 :: proc() {
	TPL := "runtime_shadow.html"
	_ = temple.compiled(TPL, int)
}
p3 :: proc() {
	_ = temple.compiled(path = "a.html", path = "b.html")
}
`),
		)
		// file_2 tries to use `LOCAL_ONLY` from file_1's p1 (should fail), and uses `TPL` (should still resolve to "pkg.html").
		_ = os.write_entire_file(
			file_2,
			transmute([]byte)string(`package slug_route
import "temple"
p4 :: proc() {
	_ = temple.compiled(LOCAL_ONLY, int)
	_ = temple.compiled(TPL, int)
}
`),
		)

		errs := make([dynamic]string, context.temp_allocator)
		calls := collect_compile_calls(tmp_dir, context.temp_allocator, &errs)
		// Valid calls: `LOCAL_ONLY` in p1 ("local.html") and `TPL` in p4 ("pkg.html") -> 2 calls
		testing.expect_value(t, len(calls), 2)
		// Errors: shadowed mutable `TPL` in p2, duplicate `path` in p3, and out-of-scope `LOCAL_ONLY` in p4 -> 3 errors
		testing.expect_value(t, len(errs), 3)
	}
}

@(test)
test_review_round_three_fixes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// 1.1 `{{ raw(...) }}` preserves closing delimiters on calls, indexing, slices, and parenthesized expressions
	{
		code_call, ok_call := transpile_to_string(`{{ raw(get_html()) }}`)
		testing.expect(t, ok_call)
		testing.expect(t, strings.contains(code_call, ".write_string(__temple_w, get_html()) or_return"), code_call)

		code_idx, ok_idx := transpile_to_string(`{{ raw(this.items[0]) }}`)
		testing.expect(t, ok_idx)
		testing.expect(t, strings.contains(code_idx, ".write_string(__temple_w, this.items[0]) or_return"), code_idx)

		code_paren, ok_paren := transpile_to_string(`{{ raw((this.a + this.b)) }}`)
		testing.expect(t, ok_paren)
		testing.expect(t, strings.contains(code_paren, ".write_string(__temple_w, (this.a + this.b)) or_return"), code_paren)
	}

	// 1.2 Multi-line tags: trailing newlines before `%}` succeed, while multi-statement `let` across lines is rejected
	{
		_, ok_bad_multiline_let := parse_template("{% let x = 1\n   y = 2 %}")
		testing.expect(t, !ok_bad_multiline_let, "expected two statements separated by newline in let to fail")

		code_ml_tags, ok_ml_tags := transpile_to_string(
			"{% if\n  this.is_active\n%}\n" +
			"{% for\n  item in this.items\n%}\n" +
			"{% switch\n  this.state\n%}\n" +
			"{% case\n  1\n%}ok{% end %}\n" +
			"{% end %}\n" +
			"{% end %}",
		)
		testing.expect(t, ok_ml_tags, "expected multiline if/for/switch/case with trailing newlines before %} to succeed")
		testing.expect(t, strings.contains(code_ml_tags, "if this.is_active {"), code_ml_tags)
	}

	// 1.3 `{% extends "..." %}` inside `if`, `for`, or `switch` is rejected
	{
		_, ok_ext_if := parse_template(`{% if this.ok %}{% extends "base.html" %}{% end %}`)
		testing.expect(t, !ok_ext_if, "expected extends inside if block to fail")

		_, ok_ext_for := parse_template(`{% for x in this.items %}{% extends "base.html" %}{% end %}`)
		testing.expect(t, !ok_ext_for, "expected extends inside for block to fail")
	}

	// 1.4 & 2.1 Unclosed `{#` comment is rejected, and `{#` inside `{{ ... }}` is not treated as a comment tag
	{
		_, ok_unclosed_comment := parse_template(`<div>{# unclosed comment</div>`)
		testing.expect(t, !ok_unclosed_comment, "expected unclosed {# comment to fail")

		_, ok_comment_in_tag := parse_template(`{{{# comment -#} this.x }}`)
		testing.expect(t, !ok_comment_in_tag, "expected {# inside {{ ... }} not to be lexed as a template comment")
	}

	// 2.2, 2.3, 2.4 Empty tag expr at close delimiter, `{{-\n expr }}` line tracking, and `{% else if%}` error message
	{
		p_elif: Parser
		parser_init(&p_elif, `{% if this.a %}A{% else if%}B{% end %}`, context.temp_allocator)
		tmpl_elif := parse(&p_elif)
		err_elif, has_elif_err := tmpl_elif.err.?
		testing.expect(t, has_elif_err, "expected {% else if%} without condition to fail")
		if has_elif_err {
			testing.expect(t, strings.contains(err_elif.msg, "else if"), err_elif.msg)
		}

		p_nl: Parser
		parser_init(&p_nl, "{{-\n  this.bad = 1\n}}", context.temp_allocator)
		tmpl_nl := parse(&p_nl)
		err_nl, has_nl_err := tmpl_nl.err.?
		testing.expect(t, has_nl_err)
		if has_nl_err {
			// Line 0 is `{{-`, line 1 is `  this.bad = 1`
			testing.expect_value(t, err_nl.pos.line, 1)
		}
	}

	// 2.5 Self-embedding root template (`self.html` embeds `self.html`) is caught immediately on first expansion,
	// and inline template diagnostics in resolve_template_inheritance map line numbers to the Odin call site.
	{
		cwd, _ := os.get_working_directory(context.temp_allocator)
		tmp_dir, _ := filepath.join({cwd, ".tmp", "test_round_three"}, context.temp_allocator)
		_ = os.make_directory_all(tmp_dir)
		defer os.remove_all(tmp_dir)

		self_path, _ := filepath.join({tmp_dir, "self.html"}, context.temp_allocator)
		_ = os.write_entire_file(self_path, transmute([]byte)string(`<div>{% embed "self.html" %}</div>`))

		ctx: Compile_Context
		ctx.allocator = context.temp_allocator
		ctx.diagnostics = make([dynamic]Diagnostic, context.temp_allocator)

		_, ok_self := compile_single_call(&ctx, Compile_Call{
			identifier = "self.html",
			type = Call_Path{relpath = "self.html", fullpath = self_path},
		})
		testing.expect(t, !ok_self, "expected self-embedding template to fail")
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) == 1 {
			// Should catch on the first embed (stack has only 1 frame: Call_Site)
			testing.expect_value(t, len(ctx.diagnostics[0].trace), 1)
		}

		// Inline template with orphan super() on line 2 of inline string reports call.pos.line + 1
		clear_trace_frames(&ctx)
		clear(&ctx.diagnostics)
		inline_src := "<div>\n  {% block a %}{{ super() }}{% end %}\n</div>"
		_, ok_inline_sup := compile_single_call(&ctx, Compile_Call{
			pos        = {file = "routes.odin", line = 50, column = 10},
			identifier = inline_src,
			type       = Call_Inline{template = inline_src},
		})
		testing.expect(t, !ok_inline_sup)
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) == 1 {
			testing.expect_value(t, ctx.diagnostics[0].pos.line, 51)
			testing.expect_value(t, ctx.diagnostics[0].snippet, "  {% block a %}{{ super() }}{% end %}")
		}

		// Inline template embedding a broken external file adjusts intermediate Embed trace frame line/col
		broken_ext_path, _ := filepath.join({tmp_dir, "broken_ext.html"}, context.temp_allocator)
		_ = os.write_entire_file(broken_ext_path, transmute([]byte)string(`{{ }}`))
		clear_trace_frames(&ctx)
		clear(&ctx.diagnostics)
		inline_embed_src := "<div>\n  {% embed \"broken_ext.html\" %}\n</div>"
		routes_fake_path, _ := filepath.join({tmp_dir, "routes.odin"}, context.temp_allocator)
		_, ok_inline_emb := compile_single_call(&ctx, Compile_Call{
			pos        = {file = routes_fake_path, line = 80, column = 12},
			identifier = inline_embed_src,
			type       = Call_Inline{template = inline_embed_src},
		})
		testing.expect(t, !ok_inline_emb)
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) == 1 {
			d := ctx.diagnostics[0]
			testing.expect_value(t, len(d.trace), 2)
			if len(d.trace) == 2 {
				// Trace[1] is the Embed frame on line 2 of the inline string -> 80 + 1 = 81
				testing.expect_value(t, d.trace[1].pos.line, 81)
			}
		}
	}

	// 2.6 Order-independent local constants inside a procedure body, and procedure parameter/return shadowing
	{
		cwd, _ := os.get_working_directory(context.temp_allocator)
		tmp_dir, _ := filepath.join({cwd, ".tmp", "test_proc_const_order"}, context.temp_allocator)
		_ = os.make_directory_all(tmp_dir)
		defer os.remove_all(tmp_dir)

		odin_file, _ := filepath.join({tmp_dir, "order.odin"}, context.temp_allocator)
		_ = os.write_entire_file(
			odin_file,
			transmute([]byte)string(`package order_test
import "temple"
PKG_PATH :: "pkg.html"
render :: proc() {
	_ = c(LATE_CONST, int)
	LATE_CONST :: BASE_DIR + "view.html"
	BASE_DIR   :: "views/"
	c          :: temple.compiled
}
shadow_param :: proc(PKG_PATH: string) {
	_ = temple.compiled(PKG_PATH, int)
}
shadow_return :: proc() -> (PKG_PATH: string) {
	_ = temple.compiled(PKG_PATH, int)
	return ""
}
`),
		)

		errs := make([dynamic]string, context.temp_allocator)
		calls := collect_compile_calls(tmp_dir, context.temp_allocator, &errs)
		testing.expect_value(t, len(errs), 2)
		testing.expect_value(t, len(calls), 1)
		if len(calls) == 1 {
			testing.expect_value(t, calls[0].identifier, "views/view.html")
		}
	}

	// 2.7 `parser_maybe_remove_whitespace` preserves spaces after text on the same line when `last_txt` spans multiple lines,
	// and literal `}}` / `%}` outside tags are lexed consistently as `.Text`.
	{
		tmpl_same_line, ok_sl := parse_template("hello\nworld   {% if this.ok %}ok{% end %}")
		testing.expect(t, ok_sl)
		if ok_sl && len(tmpl_same_line.content) > 0 {
			txt, is_txt := tmpl_same_line.content[0].derived.(^Node_Text)
			testing.expect(t, is_txt)
			if is_txt {
				testing.expect_value(t, txt.text.value, "hello\nworld   ")
			}
		}

		code_close_adj, ok_adj := transpile_to_string(`{{ this.x }}}}`)
		testing.expect(t, ok_adj, "expected adjacent literal }} after output tag to parse as text")
		testing.expect(t, strings.contains(code_close_adj, `"}}"`), code_close_adj)

		code_leading_close, ok_lead := transpile_to_string(`}} hello %} {{ this.x }}`)
		testing.expect(t, ok_lead, "expected leading }} and %} outside tags to parse as text")
		testing.expect(t, strings.contains(code_leading_close, `"}} hello %} "`), code_leading_close)
	}
}
