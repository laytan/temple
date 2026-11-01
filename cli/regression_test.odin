package temple_cli

import "core:mem"
import "core:odin/ast"
import odin_parser "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"
import "core:testing"

@(test)
test_raw_and_magic_nested_delimiters :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	Cases :: struct {
		src:           string,
		expected_kind: Output_Write_Kind,
		expected_expr: string,
		expected_call: string,
	}

	cases := []Cases{
		{
			src           = "{{ raw(get_html()) }}",
			expected_kind = .Raw_String,
			expected_expr = "get_html()",
			expected_call = "__temple_io.write_string(__temple_w, get_html()) or_return",
		},
		{
			src           = "{{ raw(this.items[0]) }}",
			expected_kind = .Raw_String,
			expected_expr = "this.items[0]",
			expected_call = "__temple_io.write_string(__temple_w, this.items[0]) or_return",
		},
		{
			src           = "{{ raw((this.a + this.b)) }}",
			expected_kind = .Raw_String,
			expected_expr = "(this.a + this.b)",
			expected_call = "__temple_io.write_string(__temple_w, (this.a + this.b)) or_return",
		},
		{
			src           = "{{ magic(get_title()) }}",
			expected_kind = .Magic_String,
			expected_expr = "get_title()",
			expected_call = "__temple_write_magic_string(__temple_w, get_title()) or_return",
		},
	}

	for c in cases {
		p: Parser
		parser_init(&p, c.src, alloc)
		templ := parse(&p)
		testing.expect(t, templ.err == nil, c.src)
		testing.expect_value(t, len(templ.content), 1)

		out_node, ok := templ.content[0].derived.(^Node_Output)
		testing.expect(t, ok)
		testing.expect_value(t, out_node.write_kind, c.expected_kind)
		testing.expect_value(t, out_node.inner_expr, c.expected_expr)

		sb := strings.builder_make(alloc)
		transpile(strings.to_writer(&sb), "inline", templ, nil, nil, alloc)
		code := strings.to_string(sb)
		testing.expect(t, strings.contains(code, c.expected_call), code)
	}
}

@(test)
test_multiline_control_tags_and_let_validation :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	valid_templates := []string{
		"{% if\n\tthis.active\n%}ok{% end %}",
		"{% for item in\n\tthis.items\n%}{{ item }}{% end %}",
		"{% switch\n\tthis.kind\n%}{% case\n\t.A\n%}a{% end %}",
		"{% let\n\tx = this.count + 1\n%}{{ int(x) }}",
	}

	for src in valid_templates {
		p: Parser
		parser_init(&p, src, alloc)
		templ := parse(&p)
		testing.expect(t, templ.err == nil, src)
	}

	// Multi-line `let` attempting to smuggle a second statement across a newline must fail
	{
		p: Parser
		parser_init(&p, "{% let x = 1\n y = 2 %}", alloc)
		templ := parse(&p)
		err, has_err := templ.err.?
		testing.expect(t, has_err)
		if has_err {
			testing.expect(t, strings.contains(err.msg, "unexpected trailing token"), err.msg)
		}
	}
}

@(test)
test_lexer_comments_and_delimiters :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	// 1. Unclosed comments must emit .Illegal and fail parsing
	for src in ([]string{"hello {# unclosed", "hello {-# unclosed"}) {
		p: Parser
		parser_init(&p, src, alloc)
		templ := parse(&p)
		testing.expect(t, templ.err != nil, src)
	}

	// 2. Literal `}}` and `%}` outside tags must lex as plain .Text
	{
		p: Parser
		parser_init(&p, "<div>{{ this.val }}}} and %}</div>", alloc)
		templ := parse(&p)
		testing.expect(t, templ.err == nil)
		testing.expect_value(t, len(templ.content), 3)
		if len(templ.content) == 3 {
			txt0 := templ.content[0].derived.(^Node_Text)
			txt2 := templ.content[2].derived.(^Node_Text)
			testing.expect_value(t, txt0.text.value, "<div>")
			testing.expect_value(t, txt2.text.value, "}} and %}</div>")
		}
	}

	// 3. `{{-` followed by newline skips all whitespace so expression pos is on line 1
	{
		l: Lexer
		lexer_init(&l, "{{-\n\tthis.val\n-}}")
		tok_open := lexer_next(&l)
		tok_expr := lexer_next(&l)
		tok_close := lexer_next(&l)
		testing.expect_value(t, tok_open.type, Token_Type.Output_Open)
		testing.expect_value(t, tok_expr.type, Token_Type.Text)
		testing.expect_value(t, tok_expr.pos.line, 1)
		testing.expect_value(t, tok_expr.pos.col, 1)
		testing.expect_value(t, tok_close.type, Token_Type.Output_Close)
	}

	// 4. `{% else if%}` without trailing space before `%}` must lex as .ElseIf
	{
		p: Parser
		parser_init(&p, "{% if this.a %}a{% else if%}b{% end %}", alloc)
		templ := parse(&p)
		err, has_err := templ.err.?
		testing.expect(t, has_err)
		if has_err {
			testing.expect(t, strings.contains(err.msg, "missing condition expression after \"else if\""), err.msg)
		}
	}
}

@(test)
test_multiline_text_whitespace_preservation :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	// Spaces after text on the same line as `{%` must be preserved even when the text node started on an earlier line
	{
		p: Parser
		parser_init(&p, "hello\nworld   {% if this.ok %}!{% end %}", alloc)
		templ := parse(&p)
		testing.expect(t, templ.err == nil)
		txt := templ.content[0].derived.(^Node_Text)
		testing.expect_value(t, txt.text.value, "hello\nworld   ")
	}

	// Leading indentation on a line that only contains a process tag must still be stripped
	{
		p: Parser
		parser_init(&p, "hello\n   {% if this.ok %}!{% end %}", alloc)
		templ := parse(&p)
		testing.expect(t, templ.err == nil)
		txt := templ.content[0].derived.(^Node_Text)
		testing.expect_value(t, txt.text.value, "hello\n")
	}
}

@(test)
test_extends_rejected_inside_nested_bodies :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	invalid_Playbooks := []string{
		`{% if this.ok %}{% extends "base.html" %}{% end %}`,
		`{% for x in this.items %}{% extends "base.html" %}{% end %}`,
		`{% switch this.k %}{% case .A %}{% extends "base.html" %}{% end %}`,
	}

	for src in invalid_Playbooks {
		p: Parser
		parser_init(&p, src, alloc)
		templ := parse(&p)
		err, has_err := templ.err.?
		testing.expect(t, has_err, src)
		if has_err {
			testing.expect(t, strings.contains(err.msg, "\"extends\" must be at the top level of a template"), err.msg)
		}
	}
}

@(test)
test_self_embed_cycle_and_inline_trace_coordinates :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	// 1. Root template self-embedding itself must trigger circular embed on first expansion
	{
		ctx: Compile_Context
		ctx.allocator = alloc
		ctx.stack = make([dynamic]Trace_Frame, alloc)
		ctx.raw_cache = make(map[string]Cached_Template, alloc)
		ctx.diagnostics = make([dynamic]Diagnostic, alloc)

		self_src := transmute([]byte)string(`{% embed "self.html" %}`)
		p: Parser
		parser_init(&p, self_src, alloc)
		ctx.raw_cache["/virtual/self.html"] = Cached_Template{
			source   = self_src,
			template = parse(&p),
		}

		call := Compile_Call{
			pos        = tokenizer.Pos{file = "/virtual/main.odin", line = 10, column = 5},
			identifier = "self.html",
			type       = Call_Path{fullpath = "/virtual/self.html", relpath = "self.html"},
		}

		_, ok := compile_single_call(&ctx, call)
		testing.expect(t, !ok)
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) == 1 {
			testing.expect(t, strings.contains(ctx.diagnostics[0].message, "circular embed detected"))
		}
	}

	// 2. `compiled_inline` embedding a broken template must offset the inline trace frame's line/col
	{
		ctx: Compile_Context
		ctx.allocator = alloc
		ctx.stack = make([dynamic]Trace_Frame, alloc)
		ctx.raw_cache = make(map[string]Cached_Template, alloc)
		ctx.diagnostics = make([dynamic]Diagnostic, alloc)

		// Inline template at line 20, col 12 of `/virtual/app.odin`; embed is on line 2 of the inline string
		inline_str := "<div>\n  {% embed \"missing.html\" %}\n</div>"
		call := Compile_Call{
			pos        = tokenizer.Pos{file = "/virtual/app.odin", line = 20, column = 12},
			identifier = inline_str,
			type       = Call_Inline{template = inline_str},
		}

		_, ok := compile_single_call(&ctx, call)
		testing.expect(t, !ok)
		testing.expect_value(t, len(ctx.diagnostics), 1)
		if len(ctx.diagnostics) == 1 {
			diag := ctx.diagnostics[0]
			testing.expect_value(t, diag.pos.file, "/virtual/app.odin")
			testing.expect_value(t, diag.pos.line, 21) // 20 + 1
		}
	}
}

@(test)
test_local_const_order_and_param_shadowing :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	context.allocator = alloc
	context.temp_allocator = alloc

	odin_src := `package sample
import "temple"

PKG_PATH :: "pkg_level.html"

valid_out_of_order :: proc() {
	_ = temple.compiled(LATE_LOCAL, int)
	LATE_LOCAL :: "late_local.html"
}

shadowed_by_param :: proc(PKG_PATH: string) {
	_ = temple.compiled(PKG_PATH, int)
}
`
	NO_POS :: tokenizer.Pos{}
	pkg := ast.new(ast.Package, NO_POS, NO_POS)
	pkg.fullpath = "/virtual"

	file := ast.new(ast.File, NO_POS, NO_POS)
	file.pkg = pkg
	file.src = odin_src
	file.fullpath = "/virtual/sample.odin"

	op := odin_parser.default_parser()
	op.err = odin_silent_err_handler
	op.warn = odin_silent_warn_handler
	parsed_ok := odin_parser.parse_file(&op, file)
	testing.expect(t, parsed_ok)

	pkg_string_consts := make(map[string]^ast.Expr, alloc)
	for decl in file.decls {
		collect_top_level_consts(decl, &pkg_string_consts)
	}

	resolved_consts := make(map[string]string, alloc)
	for name, expr in pkg_string_consts {
		visited := make(map[string]bool, alloc)
		if val, ok := eval_const_string_from_ast(expr, pkg_string_consts, &visited); ok {
			resolved_consts[name] = val
		}
	}

	calls := make([dynamic]Compile_Call, alloc)
	errs := make([dynamic]string, alloc)
	seen := make(map[string]string, alloc)

	walk_ctx := File_Collect_Ctx{
		pkg_fullpath    = pkg.fullpath,
		file            = file,
		temple_names    = {"temple"},
		proc_aliases    = make(map[string]Temple_Proc_Kind, alloc),
		string_consts   = resolved_consts,
		raw_const_exprs = pkg_string_consts,
		calls           = &calls,
		seen            = &seen,
		out_allocator   = alloc,
		out_errors      = &errs,
	}

	v := ast.Visitor{
		data  = &walk_ctx,
		visit = visit_odin_node,
	}
	for decl in file.decls {
		ast.walk(&v, decl)
	}

	// `LATE_LOCAL` should be collected, while `PKG_PATH` shadowed by proc param should fail
	testing.expect_value(t, len(calls), 1)
	if len(calls) == 1 {
		testing.expect_value(t, calls[0].identifier, "late_local.html")
	}
	testing.expect_value(t, len(errs), 1)
	if len(errs) == 1 {
		testing.expect(t, strings.contains(errs[0], "must be a compile-time constant string expression"), errs[0])
	}
}

@(private = "file")
put_virtual_template :: proc(ctx: ^Compile_Context, fullpath: string, src: string) {
	raw := transmute([]byte)src
	p: Parser
	parser_init(&p, raw, ctx.allocator)
	ctx.raw_cache[fullpath] = Cached_Template{
		source   = raw,
		template = parse(&p),
	}
}

@(test)
test_lexer_progress_and_parser_fuzz :: proc(t: ^testing.T) {
	tokens := []string{
		"{{", "}}", "{{-", "-}}", "{%", "%}", "{%-", "-%}",
		"{#", "#}", "{#-", "-#}", "{-#", "#-}",
		"\"", "'", "`", "\\", "\n", "\r\n", "\t", " ",
		"if", "else", "elseif", "else if", "end",
		"switch", "#partial switch", "case", "let",
		"embed", "with", "extends", "block", "super", "super()",
		"raw(", "magic(", "int(", ")", "[", "]", "=", ":=", ":",
		"this.x", "a", "123",
	}

	// Deterministic xorshift64 PRNG so any failure is 100% reproducible
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

	for iter in 0 ..< 500 {
		mem.dynamic_arena_reset(&arena)

		sb := strings.builder_make(alloc)
		piece_count := int(next_u64(&state) % 24) + 1
		for _ in 0 ..< piece_count {
			idx := int(next_u64(&state) % u64(len(tokens)))
			strings.write_string(&sb, tokens[idx])
		}
		fuzz_src := strings.to_string(sb)

		// 1. Invariant: lexer cursor must strictly advance on every non-EOF token
		l: Lexer
		lexer_init(&l, fuzz_src)
		prev_cursor := -1
		steps := 0
		for {
			tok := lexer_next(&l)
			steps += 1
			testing.expect(t, steps <= len(fuzz_src) + 2, "lexer failed to terminate on fuzz input")
			if steps > len(fuzz_src) + 2 {
				break
			}
			if tok.type == .EOF {
				break
			}
			testing.expect(t, l.cursor > prev_cursor, "lexer cursor did not advance")
			prev_cursor = l.cursor
		}

		// 2. Invariant: parser must never panic or slice out-of-bounds on arbitrary token streams
		p: Parser
		parser_init(&p, fuzz_src, alloc)
		_ = parse(&p)
		_ = iter
	}
}

@(test)
test_three_level_inheritance_super_and_relative_embeds :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	ctx: Compile_Context
	ctx.allocator = alloc
	ctx.stack = make([dynamic]Trace_Frame, alloc)
	ctx.raw_cache = make(map[string]Cached_Template, alloc)
	ctx.diagnostics = make([dynamic]Diagnostic, alloc)

	// Root layout in `/app/layouts/base.html` embeds `../partials/icon.html` -> `/app/partials/icon.html`
	put_virtual_template(
		&ctx,
		"/app/layouts/base.html",
		`<html>{% block head %}<meta>{% embed "../partials/icon.html" %}{% end %}{% block body %}BASE{% end %}</html>`,
	)
	put_virtual_template(&ctx, "/app/partials/icon.html", `<link rel="icon">`)

	// Middle layout in `/app/layouts/section/child.html` extends `../base.html`, calls `{{ super() }}` & `{% super %}`,
	// defines nested block `title`, and embeds `child_meta.html` relative to `/app/layouts/section`
	put_virtual_template(
		&ctx,
		"/app/layouts/section/child.html",
		`{% extends "../base.html" %}{% block head %}{{ super() }}<title>{% block title %}Default{% end %}</title>{% embed "child_meta.html" %}{% end %}{% block body %}<main>{% super %}</main>{% end %}`,
	)
	put_virtual_template(&ctx, "/app/layouts/section/child_meta.html", `<meta name="sec">`)

	// Leaf template in `/app/views/pages/home.html` extends `../../layouts/section/child.html`,
	// overrides nested `title` block, calls `{{ super() }}` in `body`, and embeds `footer.html` relative to `/app/views/pages`
	put_virtual_template(
		&ctx,
		"/app/views/pages/home.html",
		`{% extends "../../layouts/section/child.html" %}{% block title %}Home{% end %}{% block body %}{{ super() }}{% embed "footer.html" %}{% end %}`,
	)
	put_virtual_template(&ctx, "/app/views/pages/footer.html", `<footer>foot</footer>`)

	call := Compile_Call{
		pos        = tokenizer.Pos{file = "/app/main.odin", line = 15, column = 8},
		identifier = "views/pages/home.html",
		type       = Call_Path{fullpath = "/app/views/pages/home.html", relpath = "views/pages/home.html"},
	}

	code, ok := compile_single_call(&ctx, call)
	testing.expect(t, ok)
	testing.expect_value(t, len(ctx.diagnostics), 0)

	// Verify all 3 levels and their relative embeds were spliced in the exact expected order
	expected_fragments := []string{
		`"<html>"`,
		`"<meta>"`,
		`"<link rel=\"icon\">"`,
		`"<title>"`,
		`"Home"`,
		`"</title>"`,
		`"<meta name=\"sec\">"`,
		`"<main>"`,
		`"BASE"`,
		`"</main>"`,
		`"<footer>foot</footer>"`,
		`"</html>"`,
	}

	last_idx := 0
	for frag in expected_fragments {
		rel_idx := strings.index(code[last_idx:], frag)
		testing.expectf(t, rel_idx != -1, "expected fragment %s after byte %i in:\n%s", frag, last_idx, code)
		if rel_idx != -1 {
			last_idx += rel_idx + len(frag)
		}
	}
}

@(test)
test_exact_diagnostic_coordinates_and_trace_stack :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	ctx: Compile_Context
	ctx.allocator = alloc
	ctx.stack = make([dynamic]Trace_Frame, alloc)
	ctx.raw_cache = make(map[string]Cached_Template, alloc)
	ctx.diagnostics = make([dynamic]Diagnostic, alloc)

	put_virtual_template(
		&ctx,
		"/app/base.html",
		"<div>\n\t{% block content %}{% end %}\n</div>",
	)
	put_virtual_template(
		&ctx,
		"/app/page.html",
		"{% extends \"base.html\" %}\n{% block content %}\n  {% embed \"missing_card.html\" %}\n{% end %}",
	)

	call := Compile_Call{
		pos        = tokenizer.Pos{file = "/app/routes.odin", line = 42, column = 10},
		identifier = "page.html",
		type       = Call_Path{fullpath = "/app/page.html", relpath = "page.html"},
	}

	_, ok := compile_single_call(&ctx, call)
	testing.expect(t, !ok)
	testing.expect_value(t, len(ctx.diagnostics), 1)

	if len(ctx.diagnostics) == 1 {
		d := ctx.diagnostics[0]
		// The `embed "missing_card.html"` path token is on line 3, column 12 of `/app/page.html`
		testing.expect_value(t, d.pos.file, "/app/page.html")
		testing.expect_value(t, d.pos.line, 3)
		testing.expect_value(t, d.pos.column, 12)
		testing.expect_value(t, d.caret_col, 12)
		testing.expect_value(t, d.col_len, len(`"missing_card.html"`))
		testing.expect_value(t, d.snippet, `  {% embed "missing_card.html" %}`)

		// Trace stack should have 2 frames: [0] = .Call_Site, [1] = .Embed
		testing.expect_value(t, len(d.trace), 2)
		if len(d.trace) == 2 {
			testing.expect_value(t, d.trace[0].kind, Trace_Kind.Call_Site)
			testing.expect_value(t, d.trace[0].pos.file, "/app/routes.odin")
			testing.expect_value(t, d.trace[0].pos.line, 42)
			testing.expect_value(t, d.trace[0].pos.column, 10)

			testing.expect_value(t, d.trace[1].kind, Trace_Kind.Embed)
			testing.expect_value(t, d.trace[1].pos.file, "/app/page.html")
			testing.expect_value(t, d.trace[1].pos.line, 3)
			testing.expect_value(t, d.trace[1].pos.column, 12)
			testing.expect_value(t, d.trace[1].file, "/app/missing_card.html")
		}
	}
}

@(test)
test_switch_approx_bytes_calculation :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	// Prefix = 4 bytes ("1234"), Suffix = 6 bytes ("123456")
	// Case .A = 3 bytes ("aaa")
	// Case .B = 25 bytes ("bbbbbbbbbbbbbbbbbbbbbbbbb") -> max case
	// Case .C = 8 bytes ("cccccccc")
	// Expected approx_bytes = 4 + 25 + 6 = 35
	src := `1234{% switch this.k %}{% case .A %}aaa{% case .B %}bbbbbbbbbbbbbbbbbbbbbbbbb{% case .C %}cccccccc{% end %}123456`

	p: Parser
	parser_init(&p, src, alloc)
	templ := parse(&p)
	testing.expect(t, templ.err == nil)

	sb := strings.builder_make(alloc)
	transpile(strings.to_writer(&sb), "switch_approx", templ, nil, nil, alloc)
	code := strings.to_string(sb)

	testing.expect(t, strings.contains(code, "approx_bytes = 35,"), code)
}

@(test)
test_cli_options_parsing_and_package_inference :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	// 1. Version flags
	{
		opts, _, ok := parse_cli_args({"temple_cli", "--version"}, alloc)
		testing.expect(t, ok)
		testing.expect(t, opts.show_version)

		opts_short, _, ok_short := parse_cli_args({"temple_cli", "-v"}, alloc)
		testing.expect(t, ok_short)
		testing.expect(t, opts_short.show_version)
	}

	// 2. Legacy 2-argument positional mode
	{
		opts, err_msg, ok := parse_cli_args({"temple_cli", "app", "vendor/temple"}, alloc)
		testing.expect(t, ok, err_msg)
		testing.expect_value(t, opts.project_dir, "app")
		testing.expect_value(t, opts.temple_dir, "vendor/temple")
		testing.expect_value(t, opts.out_file, "vendor/temple/templates.odin")
		testing.expect_value(t, opts.pkg_name, "temple")
		testing.expect_value(t, opts.temple_import, "")
	}

	// 3. Odin-style flags (`-out:`, `-pkg:`, `-temple-import:`) with default `"shared:temple"` import
	{
		opts, err_msg, ok := parse_cli_args({"temple_cli", "src", "-out:views/templates_gen.odin", "-pkg:views"}, alloc)
		testing.expect(t, ok, err_msg)
		testing.expect_value(t, opts.project_dir, "src")
		testing.expect_value(t, opts.out_file, "views/templates_gen.odin")
		testing.expect_value(t, opts.pkg_name, "views")
		testing.expect_value(t, opts.temple_import, "shared:temple")
	}

	// 4. GNU-style flags (`--out=`, `--pkg=`, `--temple-import=`) before positional arg
	{
		opts, err_msg, ok := parse_cli_args(
			{"temple_cli", "--out=ui/templates_gen.odin", "--pkg=ui", "--temple-import=../temple", "src"},
			alloc,
		)
		testing.expect(t, ok, err_msg)
		testing.expect_value(t, opts.project_dir, "src")
		testing.expect_value(t, opts.out_file, "ui/templates_gen.odin")
		testing.expect_value(t, opts.pkg_name, "ui")
		testing.expect_value(t, opts.temple_import, "../temple")
	}

	// 5. Automatic package inference from existing `.odin` files in output directory (`tests/` -> `package temple_tests`)
	{
		opts, err_msg, ok := parse_cli_args({"temple_cli", "tests", "-out:tests/templates_gen.odin"}, alloc)
		testing.expect(t, ok, err_msg)
		testing.expect_value(t, opts.pkg_name, "temple_tests")
		testing.expect_value(t, opts.temple_import, "shared:temple")
	}

	// 6. Automatic package inference fallback to directory basename when directory has no `.odin` files yet
	{
		opts, err_msg, ok := parse_cli_args({"temple_cli", "src", "-out:nonexistent_views_dir/templates_gen.odin"}, alloc)
		testing.expect(t, ok, err_msg)
		testing.expect_value(t, opts.pkg_name, "nonexistent_views_dir")
		testing.expect_value(t, opts.temple_import, "shared:temple")
	}

	// 7. Invalid invocations must fail cleanly
	{
		_, _, ok_empty := parse_cli_args({"temple_cli"}, alloc)
		testing.expect(t, !ok_empty)

		_, _, ok_missing_out := parse_cli_args({"temple_cli", "src"}, alloc)
		testing.expect(t, !ok_missing_out)

		_, _, ok_unknown_flag := parse_cli_args({"temple_cli", "src", "temple", "-bogus:123"}, alloc)
		testing.expect(t, !ok_unknown_flag)

		_, _, ok_empty_val := parse_cli_args({"temple_cli", "src", "-out:"}, alloc)
		testing.expect(t, !ok_empty_val)
	}
}

@(test)
test_same_package_and_aliased_compile_call_discovery :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	context.allocator = alloc
	context.temp_allocator = alloc

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
}
