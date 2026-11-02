package temple_cli

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import odin_parser "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"

Parser :: struct {
	lexer:          Lexer,
	allocator:      mem.Allocator,
	template:       Template,
	last_txt_node:  Maybe(^Node_Text),
	in_block:       int,
	body_depth:     int,
	seen_macros:    Small_Array(16, string),
	dummy_odin_pkg: ast.Package,
	slab:           Node_Slab,
}

Parser_Error :: struct {
	pos: Pos,
	msg: string,
}

Template :: struct {
	content: [dynamic]Node,
	err:     Maybe(Parser_Error),
}

Node :: struct {
	derived: Any_Node,
}

Any_Node :: union {
	^Node_Text,
	^Node_Output,
	^Node_If,
	^Node_For,
	^Node_Switch,
	^Node_Let,
	^Node_Embed,
	^Node_Extends,
	^Node_Block,
	^Node_Super,
	^Node_Macro,
	^Node_Call,
}

Node_Text :: struct {
	using node: Node,
	text:       Token,
}

Output_Write_Kind :: enum {
	Escaped_String,
	Raw_String,
	Magic_String,
	Url_String,
	Url_Param_String,
	Js_String,
	Fmt_Escaped,
	Fmt_Raw,
	Byte,
	Rune,
	Int,
	Uint,
	I128,
	U128,
	U64,
	I64,
	F32,
	F64,
	F64_Prec,
}

Node_Output :: struct {
	using node:  Node,
	open:        Token,
	expression:  Token,
	write_kind:  Output_Write_Kind,
	inner_expr:  string,
	wrap_call:   string, // Optional wrapper function/cast name, e.g. "len", "int", "f64"
	default_arg: string, // Optional second argument to `__temple_default(inner_expr, default_arg)`
	fmt_str:     string, // Populated when write_kind is .Fmt_Escaped or .Fmt_Raw
	float_prec:  int,    // Populated when write_kind is .F64_Prec
}

Node_If :: struct {
	using node: Node,
	_if:        Node_If_Part,
	elseifs:    [dynamic]^Node_If_Part,
	_else:      Maybe(^Node_If_Part),
}

Node_Case :: struct {
	open:       Token,
	expression: Maybe(Token), // `nil` for default `{% case %}`
	body:       [dynamic]Node,
}

Node_Switch :: struct {
	using node: Node,
	open:       Token,
	is_partial: bool,         // true for `{% #partial switch ... %}`
	expression: Maybe(Token), // `nil` for blank `{% switch %}`
	cases:      [dynamic]^Node_Case,
}

Node_Let :: struct {
	using node:    Node,
	open:          Token,
	assignment:    Token, // e.g., `x = this.count + 1` or `val, ok := this.opt.?`
	has_type_decl: bool,  // true when declared with explicit type e.g. `x: int = 5`
}

Embed_Prop :: struct {
	name:     string,
	val_expr: string,
	pos:      Pos,
}

Node_Embed :: struct {
	using node:    Node,
	open:          Token,
	path:          Token,
	resolved_path: string,
	origin_file:   string,
	origin_src:    []byte,
	with:          Maybe(^Node_Embed_With),
	props:         [dynamic]Embed_Prop, // Populated for `{% embed "x.html"(a = 1, b = 2) %}`
	approx_bytes:  int,
}

Node_Embed_With :: struct {
	with: Token,
	expr: Token,
}

Node_Extends :: struct {
	using node: Node,
	open:       Token,
	path:       Token,
}

Node_Block :: struct {
	using node:  Node,
	open:        Token,
	name_tok:    Token,
	name:        string,
	origin_file: string,
	origin_src:  []byte,
	body:        [dynamic]Node,
}

Node_Super :: struct {
	using node:  Node,
	open:        Token,
	super_tok:   Token,
	origin_file: string,
	origin_src:  []byte,
}

Node_Macro :: struct {
	using node:  Node,
	open:        Token,
	signature:   Token,
	name:        string,
	params_src:  string,
	param_names: [dynamic]string,
	min_args:    int,
	max_args:    int,
	has_varargs: bool,
	origin_file: string,
	origin_src:  []byte,
	body:        [dynamic]Node,
}

Call_Arg_Info :: struct {
	name: string,
	pos:  Pos,
}

Node_Call :: struct {
	using node:  Node,
	open:        Token,
	call_expr:   Token,
	name_pos:    Pos,
	name:        string,
	args_src:    string,
	arg_count:   int,
	args:        [dynamic]Call_Arg_Info,
	origin_file: string,
	origin_src:  []byte,
}

Node_If_Part :: struct {
	start: struct {
		open: Token,
		type: Token,
		expr: Maybe(Token), // Set if type is .If or .ElseIf, not with .Else.
	},
	body:  [dynamic]Node,
}

Node_For :: struct {
	using node: Node,
	start:      struct {
		open:       Token,
		expression: Token,
	},
	body:       [dynamic]Node,
}

parser_init_bytes :: proc(p: ^Parser, source: []byte, allocator := context.allocator) {
	lexer_init(&p.lexer, source)

	p.allocator = allocator
	init_cap := clamp(len(source) / 64, 2, 16)
	p.template.content = make([dynamic]Node, 0, init_cap, allocator)
	p.seen_macros = {}
	p.slab = {}
}

@(private = "file")
alloc_parser_node :: proc(p: ^Parser, $T: typeid) -> ^T {
	slab_bytes := clamp(len(p.lexer.source) * 2 + 512, 512, 4096)
	return slab_alloc_node(&p.slab, T, p.allocator, slab_bytes)
}

@(private = "file")
alloc_node_text :: #force_inline proc(p: ^Parser) -> ^Node_Text {
	return alloc_parser_node(p, Node_Text)
}

@(private = "file")
alloc_node_output :: #force_inline proc(p: ^Parser) -> ^Node_Output {
	return alloc_parser_node(p, Node_Output)
}

@(private = "file")
alloc_node_block :: #force_inline proc(p: ^Parser) -> ^Node_Block {
	return alloc_parser_node(p, Node_Block)
}

@(private = "file")
alloc_node_call :: #force_inline proc(p: ^Parser) -> ^Node_Call {
	return alloc_parser_node(p, Node_Call)
}

@(private = "file")
alloc_node_case :: #force_inline proc(p: ^Parser) -> ^Node_Case {
	return alloc_parser_node(p, Node_Case)
}

parser_init_str :: proc(p: ^Parser, source: string, allocator := context.allocator) {
	parser_init_bytes(p, transmute([]byte)source, allocator)
}

parser_init :: proc {
	parser_init_bytes,
	parser_init_str,
}

@(private = "file")
@(require_results)
error :: proc(p: ^Parser, pos: Pos, msg: string, args: ..any) -> bool {
	err: Parser_Error
	err.pos = pos

	{
		context.allocator = p.allocator
		err.msg = fmt.aprintf(msg, ..args)
	}

	p.template.err = err
	return false
}

@(private = "file")
append_parsed_node :: proc(p: ^Parser, container: ^[dynamic]Node, node: Node) {
	if txt, is_txt := node.derived.(^Node_Text); is_txt {
		if len(txt.text.value) == 0 {
			return
		}
		if len(container^) > 0 {
			if prev_txt, is_prev := container^[len(container^) - 1].derived.(^Node_Text); is_prev {
				prev_txt.text.value = strings.concatenate({prev_txt.text.value, txt.text.value}, p.allocator)
				p.last_txt_node = prev_txt
				return
			}
		}
		append(container, txt)
		return
	}

	if d, is_out := node.derived.(^Node_Output); is_out {
		if d.write_kind == .Fmt_Escaped || d.write_kind == .Fmt_Raw {
			v := d.inner_expr if len(d.inner_expr) > 0 else strings.trim_space(d.expression.value)
			if len(d.default_arg) > 0 || !has_top_level_comma(v) {
				if spec := try_parse_simple_fmt_literal(d.fmt_str, p.allocator); spec.is_simple {
					is_raw := d.write_kind == .Fmt_Raw
					if len(spec.prefix) > 0 {
						pre_val := spec.prefix if is_raw else escape_html_literal_at_compile_time(spec.prefix, p.allocator)
						append_parsed_node(p, container, parse_text(p, Token{type = .Text, value = pre_val, pos = d.open.pos}))
					}
					switch spec.verb {
					case 's':
						d.write_kind = .Raw_String if is_raw else .Escaped_String
						d.inner_expr = v
					case 'i', 'd':
						d.write_kind = .Int
						d.inner_expr = v
						if len(d.wrap_call) == 0 {
							d.wrap_call = "int"
						}
					case 'f':
						d.write_kind = .F64_Prec
						d.float_prec = spec.float_prec
						d.inner_expr = v
						if len(d.wrap_call) == 0 {
							d.wrap_call = "f64"
						}
					}
					append(container, d)
					p.last_txt_node = nil
					if len(spec.suffix) > 0 {
						suf_val := spec.suffix if is_raw else escape_html_literal_at_compile_time(spec.suffix, p.allocator)
						append_parsed_node(p, container, parse_text(p, Token{type = .Text, value = suf_val, pos = d.open.pos}))
					}
					return
				}
			}
		}
	}

	append(container, node)
	p.last_txt_node = nil
}

parse :: proc(p: ^Parser) -> Template {
	parse_loop: for {
		t := lexer_next(&p.lexer)

		switch t.type {
		case .Output_Open:
			if out, ok := parse_output(p, t); ok {
				append_parsed_node(p, &p.template.content, out)
			} else {
				break parse_loop
			}

		case .Text:
			append_parsed_node(p, &p.template.content, parse_text(p, t))

		case .Process_Open:
			if out, ok := parse_process(p, t); ok {
				append_parsed_node(p, &p.template.content, out)
			} else {
				break parse_loop
			}

		case .EOF:
			break parse_loop

		case .Output_Close, .Illegal, .Process_Close, .If, .End, .For, .Else, .ElseIf, .Switch, .Partial_Switch, .Case, .Let, .Embed_With, .Embed_Path, .Embed, .Extends, .Block, .Super, .Macro, .Call:
			fallthrough

		case:
			_ = error(p, t.pos, "invalid top level token: %q with content %q", t.type, t.value)
			break parse_loop
		}
	}

	if p.template.err == nil {
		validate_extends_structure(p)
	}

	return p.template
}

validate_extends_structure :: proc(p: ^Parser) {
	has_extends := false
	extends_index := -1

	for node, i in p.template.content {
		if ext, is_ext := node.derived.(^Node_Extends); is_ext {
			if has_extends {
				_ = error(p, ext.open.pos, "a template may only contain a single \"extends\" tag")
				return
			}
			has_extends = true
			extends_index = i
		}
	}

	if !has_extends {
		validate_standalone_macro_calls(p)
		return
	}

	// Ensure extends is the first non-whitespace node, and only blocks/macros/whitespace appear after it.
	for node, i in p.template.content {
		if i < extends_index {
			if txt, is_txt := node.derived.(^Node_Text); is_txt {
				if strings.trim_space(txt.text.value) == "" {
					continue
				}
			}
			ext := p.template.content[extends_index].derived.(^Node_Extends)
			_ = error(p, ext.open.pos, "\"extends\" must be the first tag in a child template")
			return
		} else if i == extends_index {
			continue
		} else {
			#partial switch d in node.derived {
			case ^Node_Block, ^Node_Macro:
				continue
			case ^Node_Call:
				_ = error(p, d.open.pos, "child template extending a layout cannot contain \"call\" tags outside of \"block\" or \"macro\" tags")
				return
			case ^Node_Text:
				if strings.trim_space(d.text.value) == "" {
					continue
				}
				_ = error(p, d.text.pos, "child template extending a layout can only contain \"block\" or \"macro\" tags at the top level")
				return
			case ^Node_Output:
				_ = error(p, d.open.pos, "child template extending a layout cannot contain output tags outside of \"block\" or \"macro\" tags")
				return
			case ^Node_If:
				_ = error(p, d._if.start.open.pos, "child template extending a layout cannot contain \"if\" tags outside of \"block\" or \"macro\" tags")
				return
			case ^Node_For:
				_ = error(p, d.start.open.pos, "child template extending a layout cannot contain \"for\" tags outside of \"block\" or \"macro\" tags")
				return
			case ^Node_Switch:
				_ = error(p, d.open.pos, "child template extending a layout cannot contain \"switch\" tags outside of \"block\" or \"macro\" tags")
				return
			case ^Node_Let:
				_ = error(p, d.open.pos, "child template extending a layout cannot contain \"let\" tags outside of \"block\" or \"macro\" tags")
				return
			case ^Node_Embed:
				_ = error(p, d.open.pos, "child template extending a layout cannot contain \"embed\" tags outside of \"block\" or \"macro\" tags")
				return
			case ^Node_Super:
				_ = error(p, d.open.pos, "\"super\" cannot be used outside of a \"block\" tag")
				return
			case:
				_ = error(p, {}, "child template extending a layout can only contain \"block\" or \"macro\" tags at the top level")
				return
			}
		}
	}
}

parse_output :: proc(p: ^Parser, open_token: Token) -> (n: Node, ok: bool) {
	expr_tok := lexer_next(&p.lexer)
	if expr_tok.type != .Text {
		error(
			p,
			expr_tok.pos,
			"invalid token following %q, expected an expression, got: %q",
			open_token.value,
			expr_tok.value,
		) or_return
	}

	close_tok := lexer_next(&p.lexer)
	if close_tok.type != .Output_Close {
		error(
			p,
			close_tok.pos,
			"invalid token following output expression, expected \"}}\", got: %q",
			close_tok.value,
		) or_return
	}

	t := alloc_node_output(p)
	t.derived = t
	t.open = open_token
	t.expression = expr_tok

	is_super := validate_and_classify_output_expr(p, t) or_return
	if is_super {
		if p.in_block <= 0 {
			error(p, open_token.pos, "\"super()\" can only be used inside a \"block\" tag") or_return
		}
		sup := alloc_parser_node(p, Node_Super)
		sup.derived = sup
		sup.open = open_token
		sup.super_tok = expr_tok
		return sup, true
	}

	return t, true
}

parse_text :: proc(p: ^Parser, text_token: Token) -> ^Node_Text {
	t := alloc_node_text(p)
	t.derived = t

	t.text = text_token

	p.last_txt_node = t
	return t
}

parse_process :: proc(p: ^Parser, process: Token, process_type_: Maybe(Token) = nil) -> (n: Node, ok: bool) {
	process_type, tok := process_type_.?
	if !tok {
		parser_maybe_remove_whitespace(p, process)
		process_type = lexer_next(&p.lexer)
	}

	switch process_type.type {
	case .If:
		return parse_if(p, process, process_type) or_return, true
	case .For:
		return parse_for(p, process, process_type) or_return, true
	case .Switch:
		return parse_switch(p, process, process_type, false) or_return, true
	case .Partial_Switch:
		return parse_switch(p, process, process_type, true) or_return, true
	case .Let:
		return parse_let(p, process, process_type) or_return, true
	case .Embed:
		return parse_embed(p, process, process_type) or_return, true
	case .Extends:
		return parse_extends(p, process, process_type) or_return, true
	case .Block:
		return parse_block(p, process, process_type) or_return, true
	case .Super:
		return parse_super(p, process, process_type) or_return, true
	case .Macro:
		return parse_macro(p, process, process_type) or_return, true
	case .Call:
		return parse_call(p, process, process_type) or_return, true
	case .Case:
		error(
			p,
			process_type.pos,
			"unexpected \"case\" without a matching \"switch\" tag",
		) or_return
	case .Else, .ElseIf:
		error(
			p,
			process_type.pos,
			"unexpected %q without a matching \"if\" tag",
			process_type.value,
		) or_return
	case .End:
		error(
			p,
			process_type.pos,
			"unexpected \"end\" without a matching opening \"if\", \"for\", \"switch\", or \"block\" tag",
		) or_return
	case .Process_Close, .Process_Open, .EOF, .Text, .Illegal, .Output_Open, .Output_Close, .Embed_Path, .Embed_With:
		fallthrough
	case:
		error(
			p,
			process_type.pos,
			"invalid process type token, expected \"if\", \"for\", \"switch\", \"let\", \"embed\", \"extends\", or \"block\", got: %q",
			process_type.value,
		) or_return
	}

	ok = true
	return
}

parse_let :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Let, ok: bool) {
	assert(process_type.type == .Let)

	t = alloc_parser_node(p, Node_Let)
	t.derived = t
	t.open = process

	expr_tok := lexer_next(&p.lexer)
	if expr_tok.type != .Text || len(strings.trim_space(expr_tok.value)) == 0 {
		error(
			p,
			process.pos,
			"`let` statement requires a variable assignment, e.g. `{{%% let x = this.val %%}}`",
		) or_return
	}

	// Ensure there is an `=` in the assignment (not `==`)
	eq_idx := find_assignment_equals(expr_tok.value)
	if eq_idx <= 0 {
		error(
			p,
			expr_tok.pos,
			"invalid `let` syntax %q: expected assignment (`=` or `:=`)",
			strings.trim_space(expr_tok.value),
		) or_return
	}

	lhs := strings.trim_space(expr_tok.value[:eq_idx])
	if strings.has_suffix(lhs, ":") {
		lhs = strings.trim_space(lhs[:len(lhs)-1])
	}
	if len(lhs) == 0 {
		error(p, expr_tok.pos, "missing variable name on left-hand side of `let` assignment") or_return
	}

	rhs := strings.trim_space(expr_tok.value[eq_idx+1:])
	if len(rhs) == 0 {
		error(p, expr_tok.pos, "missing expression on right-hand side of `let` assignment") or_return
	}

	has_type_decl := validate_let_assignment_expr(p, expr_tok, eq_idx) or_return

	t.assignment = expr_tok
	t.has_type_decl = has_type_decl
	close_tok := lexer_next(&p.lexer)
	if close_tok.type != .Process_Close {
		error(
			p,
			close_tok.pos,
			"invalid token following `let` assignment, expected \"%%}\", got: %q",
			close_tok.value,
		) or_return
	}

	ok = true
	return
}

find_assignment_equals :: proc(s: string) -> int {
	in_quote: byte = 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if in_quote != 0 {
			if c == '\\' && (in_quote == '"' || in_quote == '\'') {
				i += 1
				continue
			}
			if c == in_quote {
				in_quote = 0
			}
			continue
		}
		if c == '"' || c == '`' || c == '\'' {
			in_quote = c
			continue
		}
		if c == '=' {
			prev := s[i-1] if i > 0 else 0
			next := s[i+1] if i+1 < len(s) else 0
			if next == '=' {
				continue
			}
			switch prev {
			case '=', '!', '<', '>', '+', '-', '*', '/', '%', '&', '|', '~':
				continue
			}
			return i
		}
	}
	return -1
}

find_top_level_colon :: proc(s: string) -> int {
	in_quote: byte = 0
	depth := 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if in_quote != 0 {
			if c == '\\' && (in_quote == '"' || in_quote == '\'') {
				i += 1
				continue
			}
			if c == in_quote {
				in_quote = 0
			}
			continue
		}
		switch c {
		case '"', '`', '\'':
			in_quote = c
		case '(', '[', '{':
			depth += 1
		case ')', ']', '}':
			if depth > 0 {
				depth -= 1
			}
		case ':':
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

parse_switch :: proc(p: ^Parser, process: Token, process_type: Token, is_partial: bool) -> (t: ^Node_Switch, ok: bool) {
	t = alloc_parser_node(p, Node_Switch)
	t.derived = t
	t.open = process
	t.is_partial = is_partial
	t.cases = make([dynamic]^Node_Case, 0, 3, p.allocator)

	next := lexer_next(&p.lexer)
	close_tok: Token
	if next.type == .Text {
		if len(strings.trim_space(next.value)) > 0 {
			validate_switch_header_expr(p, next, is_partial) or_return
			t.expression = next
		}
		close_tok = lexer_next(&p.lexer)
	} else {
		close_tok = next
	}

	if close_tok.type != .Process_Close {
		error(
			p,
			close_tok.pos,
			"invalid token in \"switch\" tag, expected \"%%}\", got: %q",
			close_tok.value,
		) or_return
	}

	// 1. Skip whitespace-only text between `{% switch %}` and the first `{% case %}`
	tok := lexer_next(&p.lexer)
	for tok.type == .Text {
		if len(strings.trim_space(tok.value)) > 0 {
			error(
				p,
				tok.pos,
				"unexpected HTML/text inside `switch` before first `case`; all output must be inside a `{{%% case %%}}` block",
			) or_return
		}
		tok = lexer_next(&p.lexer)
	}

	if tok.type == .EOF {
		error(
			p,
			process.pos,
			"unclosed \"switch\" tag (opened at %i:%i), expected \"{{%% end %%}}\" before EOF",
			process.pos.line + 1,
			process.pos.col + 1,
		) or_return
	}

	if tok.type != .Process_Open {
		error(
			p,
			tok.pos,
			"expected `{{%% case %%}}` or `{{%% end %%}}` inside `switch`, got %q",
			tok.value,
		) or_return
	}

	parser_maybe_remove_whitespace(p, tok)
	stmt_open := tok
	stmt_type := lexer_next(&p.lexer)

	has_default := false
	for stmt_type.type == .Case {
		c := alloc_node_case(p)
		c.open = stmt_open
		c.body = make([dynamic]Node, 0, 2, p.allocator)

		case_next := lexer_next(&p.lexer)
		case_close: Token
		if case_next.type == .Text {
			if len(strings.trim_space(case_next.value)) > 0 {
				validate_case_expr(p, case_next) or_return
				c.expression = case_next
			} else {
				if has_default {
					error(p, stmt_open.pos, "duplicate default `{{%% case %%}}` in `switch` block") or_return
				}
				has_default = true
			}
			case_close = lexer_next(&p.lexer)
		} else {
			if has_default {
				error(p, stmt_open.pos, "duplicate default `{{%% case %%}}` in `switch` block") or_return
			}
			has_default = true
			case_close = case_next
		}

		if case_close.type != .Process_Close {
			error(
				p,
				case_close.pos,
				"invalid token in \"case\" tag, expected \"%%}\", got: %q",
				case_close.value,
			) or_return
		}

		is_case_or_end :: proc(tok: Token) -> bool {
			return tok.type == .Case || tok.type == .End
		}

		stmt_open, stmt_type = parse_body(
			p,
			&c.body,
			is_case_or_end,
			"switch",
			process.pos,
		) or_return

		append(&t.cases, c)
	}

	if stmt_type.type != .End {
		error(
			p,
			stmt_type.pos,
			"expected `{{%% case %%}}` or `{{%% end %%}}` inside `switch`, got %q",
			stmt_type.value,
		) or_return
	}

	if len(t.cases) == 0 {
		error(p, process.pos, "`switch` block must contain at least one `{{%% case %%}}`") or_return
	}

	end_close := lexer_next(&p.lexer)
	if end_close.type != .Process_Close {
		error(
			p,
			end_close.pos,
			"invalid token after \"end\", expected \"%%}\", got: %q",
			end_close.value,
		) or_return
	}

	ok = true
	return
}

parse_if :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_If, ok: bool) {
	assert(process_type.type == .If)
	open_pos := process.pos
	process, process_type := process, process_type

	t = alloc_parser_node(p, Node_If)
	t.derived = t
	t._if.body.allocator = p.allocator
	t.elseifs.allocator  = p.allocator

	parse_if_part :: proc(p: ^Parser, if_part: ^Node_If_Part, process: Token, process_type: Token, root_open_pos: Pos) -> (end_open: Token, end_type: Token, ok: bool) {
		if_part.start.open = process
		if_part.start.type = process_type

		if process_type.type == .If || process_type.type == .ElseIf {
			expr := lexer_next(&p.lexer)
			if expr.type == .Process_Close {
				error(
					p,
					expr.pos,
					"missing condition expression after %q",
					if_part.start.type.value,
				) or_return
			}
			if expr.type != .Text {
				error(
					p,
					expr.pos,
					"invalid token following %q, expected an expression to evaluate, got: %q",
					if_part.start.type.value,
					expr.value,
				) or_return
			}

			validate_if_condition_expr(p, expr, if_part.start.type.value) or_return
			if_part.start.expr = expr
		}

		close_tok := lexer_next(&p.lexer)
		if close_tok.type != .Process_Close {
			error(
				p,
				close_tok.pos,
				"invalid token, expected \"%%}\", got: %q",
				close_tok.value,
			) or_return
		}

		is_if_elseif_end :: proc(t: Token) -> bool {
			return t.type == .Else || t.type == .ElseIf || t.type == .End
		}

		is_else_end :: proc(t: Token) -> bool {
			return t.type == .End
		}

		end_open, end_type = parse_body(
			p,
			&if_part.body,
			is_else_end if if_part.start.type.type == .Else else is_if_elseif_end,
			"if",
			root_open_pos,
		) or_return
		ok = true
		return
	}

	process, process_type = parse_if_part(p, &t._if, process, process_type, open_pos) or_return
	for process_type.type == .ElseIf {
		part := alloc_parser_node(p, Node_If_Part)
		part.body.allocator = p.allocator
		process, process_type = parse_if_part(p, part, process, process_type, open_pos) or_return
		append(&t.elseifs, part)
	}

	#partial switch process_type.type {
	case .Else:
		part := alloc_parser_node(p, Node_If_Part)
		part.body.allocator = p.allocator
		process, process_type = parse_if_part(p, part, process, process_type, open_pos) or_return
		t._else = part

	case .End:
	case:
		error(p, process_type.pos, "invalid token, expected \"else\" or \"end\", got %q", process_type.value) or_return
	}

	if process_type.type != .End {
		error(p, process_type.pos, "invalid token, expected \"end\", got %q", process_type.value) or_return
	}

	end_close := lexer_next(&p.lexer)
	if end_close.type != .Process_Close {
		error(p, end_close.pos, "invalid token after \"end\", expected \"%%}\", got: %q", end_close.value) or_return
	}

	ok = true
	return
}

parse_for :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_For, ok: bool) {
	assert(process_type.type == .For)

	t = alloc_parser_node(p, Node_For)
	t.derived = t
	t.body = make([dynamic]Node, 0, 12, p.allocator)

	t.start.open = process

	t.start.expression = lexer_next(&p.lexer)
	if t.start.expression.type != .Text {
		error(
			p,
			t.start.expression.pos,
			"invalid token following \"for\", expected a for expression to evaluate, got: %q",
			t.start.expression.value,
		) or_return
	}

	validate_for_clause_expr(p, t.start.expression) or_return

	close_tok := lexer_next(&p.lexer)
	if close_tok.type != .Process_Close {
		error(
			p,
			close_tok.pos,
			"invalid token following the for expression %q, expected \"%%}\", got: %q",
			t.start.expression.value,
			close_tok.value,
		) or_return
	}

	_, end_tok := parse_body(
		p,
		&t.body,
		proc(t: Token) -> bool { return t.type == .End },
		"for",
		process.pos,
	) or_return

	end_close := lexer_next(&p.lexer)
	if end_close.type != .Process_Close {
		error(
			p,
			end_tok.pos,
			"invalid token following the \"{{%% end\", expected \"%%}\", got: %q",
			end_tok.value,
		) or_return
	}

	ok = true
	return
}

parse_block :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Block, ok: bool) {
	assert(process_type.type == .Block)

	t = alloc_node_block(p)
	t.derived = t
	t.body = make([dynamic]Node, 0, 8, p.allocator)
	t.open = process

	name_tok := lexer_next(&p.lexer)
	if name_tok.type != .Text {
		error(
			p,
			name_tok.pos,
			"invalid token following \"block\", expected a block identifier, got: %q",
			name_tok.value,
		) or_return
	}

	name := strings.trim_space(name_tok.value)
	if !is_valid_block_ident(name) {
		error(
			p,
			name_tok.pos,
			"invalid block name %q, expected a valid identifier",
			name,
		) or_return
	}

	t.name_tok = name_tok
	t.name = name

	close_tok := lexer_next(&p.lexer)
	if close_tok.type != .Process_Close {
		error(
			p,
			close_tok.pos,
			"invalid token following block name %q, expected \"%%}\", got: %q",
			name,
			close_tok.value,
		) or_return
	}

	p.in_block += 1
	defer p.in_block -= 1

	_, _ = parse_body(
		p,
		&t.body,
		proc(t: Token) -> bool { return t.type == .End },
		"block",
		process.pos,
	) or_return

	end_close := lexer_next(&p.lexer)
	if end_close.type != .Process_Close {
		error(
			p,
			end_close.pos,
			"invalid token after \"end\", expected \"%%}\", got: %q",
			end_close.value,
		) or_return
	}

	ok = true
	return
}

parse_extends :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Extends, ok: bool) {
	assert(process_type.type == .Extends)

	if p.in_block > 0 {
		error(p, process.pos, "\"extends\" cannot be used inside a \"block\" tag") or_return
	}
	if p.body_depth > 0 {
		error(p, process.pos, "\"extends\" must be at the top level of a template") or_return
	}

	t = alloc_parser_node(p, Node_Extends)
	t.derived = t
	t.open = process

	t.path = lexer_next(&p.lexer)
	if t.path.type != .Embed_Path || len(t.path.value) < 2 || t.path.value[len(t.path.value)-1] != '"' {
		error(
			p,
			t.path.pos,
			"invalid token after \"extends\", expected a double quoted string pointing at a layout template file, got: %q",
			t.path.value,
		) or_return
	}

	if len(t.path.value) <= 2 {
		error(p, t.path.pos, "invalid extends path, expected a non-empty path, got: %q", t.path.value) or_return
	}

	close_tok := lexer_next(&p.lexer)
	if close_tok.type != .Process_Close {
		error(p, close_tok.pos, "invalid token after extends path, expected \"%%}\", got: %q", close_tok.value) or_return
	}

	ok = true
	return
}

parse_super :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Super, ok: bool) {
	assert(process_type.type == .Super)

	if p.in_block <= 0 {
		error(p, process.pos, "\"super\" can only be used inside a \"block\" tag") or_return
	}

	t = alloc_parser_node(p, Node_Super)
	t.derived = t
	t.open = process
	t.super_tok = process_type

	close_tok := lexer_next(&p.lexer)
	if close_tok.type != .Process_Close {
		error(p, close_tok.pos, "invalid token after \"super\", expected \"%%}\", got: %q", close_tok.value) or_return
	}

	ok = true
	return
}

parse_macro :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Macro, ok: bool) {
	assert(process_type.type == .Macro)

	if p.body_depth > 0 {
		error(p, process.pos, "\"macro\" must be declared at the top level of a template") or_return
	}

	t = alloc_parser_node(p, Node_Macro)
	t.derived = t
	t.body.allocator = p.allocator
	t.open = process

	sig_tok := lexer_next(&p.lexer)
	if sig_tok.type != .Text || len(strings.trim_space(sig_tok.value)) == 0 {
		error(
			p,
			sig_tok.pos,
			"missing macro signature after \"macro\", expected \"name(params...)\"",
		) or_return
	}

	validate_macro_signature(p, sig_tok, t) or_return

	t.signature = sig_tok
	close_tok := lexer_next(&p.lexer)
	if close_tok.type != .Process_Close {
		error(
			p,
			close_tok.pos,
			"invalid token following macro signature %q, expected \"%%}\", got: %q",
			t.name,
			close_tok.value,
		) or_return
	}

	prev_in_block := p.in_block
	p.in_block = 0
	defer p.in_block = prev_in_block

	_, _ = parse_body(
		p,
		&t.body,
		proc(tok: Token) -> bool { return tok.type == .End },
		"macro",
		process.pos,
	) or_return

	end_close := lexer_next(&p.lexer)
	if end_close.type != .Process_Close {
		error(
			p,
			end_close.pos,
			"invalid token after \"end\", expected \"%%}\", got: %q",
			end_close.value,
		) or_return
	}

	ok = true
	return
}

parse_call :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Call, ok: bool) {
	assert(process_type.type == .Call)

	t = alloc_node_call(p)
	t.derived = t
	t.open = process

	expr_tok := lexer_next(&p.lexer)
	if expr_tok.type != .Text || len(strings.trim_space(expr_tok.value)) == 0 {
		error(
			p,
			expr_tok.pos,
			"missing macro call expression after \"call\", expected \"name(args...)\"",
		) or_return
	}

	validate_call_expr(p, expr_tok, t) or_return

	t.call_expr = expr_tok
	close_tok := lexer_next(&p.lexer)
	if close_tok.type != .Process_Close {
		error(
			p,
			close_tok.pos,
			"invalid token following \"call\" expression, expected \"%%}\", got: %q",
			close_tok.value,
		) or_return
	}

	ok = true
	return
}

@(private = "file")
parse_prefixed_odin_expr :: proc(
	p: ^Parser,
	tok: Token,
	raw_src: string,
	prefix: string,
	err_context := "",
	raw_offset := 0,
) -> (
	expr: ^ast.Expr,
	synthetic: string,
	ok: bool,
) {
	part := raw_src[raw_offset:]
	synthetic = strings.concatenate({prefix, part}, p.allocator) if len(prefix) > 0 else part

	op: odin_parser.Parser
	file: ast.File
	init_odin_snippet_parser(p, &op, &file, synthetic, false)

	expr = odin_parser.parse_expr(&op, false)
	if tl_odin_diag.has_err || expr == nil || op.error_count > 0 {
		if len(err_context) > 0 {
			rel_offset := raw_offset + max(tl_odin_diag.pos.offset - len(prefix), 0)
			err_pos := advance_pos_by_offset(tok.pos, raw_src, rel_offset)
			msg := tl_odin_diag.msg if len(tl_odin_diag.msg) > 0 else fmt.tprintf("invalid %s", err_context)
			_ = error(p, err_pos, "invalid %s: %s", err_context, msg)
		}
		return nil, synthetic, false
	}

	if op.curr_tok.kind != .EOF {
		if len(err_context) > 0 {
			rel_offset := raw_offset + max(op.curr_tok.pos.offset - len(prefix), 0)
			err_pos := advance_pos_by_offset(tok.pos, raw_src, rel_offset)
			_ = error(p, err_pos, "unexpected trailing token %q in %s", op.curr_tok.text, err_context)
		}
		return nil, synthetic, false
	}

	return expr, synthetic, true
}

@(private = "file")
validate_macro_signature :: proc(p: ^Parser, tok: Token, out_node: ^Node_Macro) -> bool {
	raw_src := strings.trim_right_space(tok.value)
	context.allocator = p.allocator

	open_paren := strings.index_byte(raw_src, '(')
	if open_paren == -1 {
		return error(
			p,
			tok.pos,
			"invalid macro signature %q: expected parameter list in parentheses, e.g. \"name(param: string)\"",
			strings.trim_space(raw_src),
		)
	}

	name_raw := raw_src[:open_paren]
	name_lead := 0
	for name_lead < len(name_raw) && is_ws(name_raw[name_lead]) {
		name_lead += 1
	}
	name_pos := advance_pos_by_offset(tok.pos, raw_src, name_lead)
	name := strings.trim_space(name_raw)
	if !is_valid_block_ident(name) {
		return error(p, name_pos, "invalid macro name %q, expected a valid identifier", name)
	}

	for prev_name in small_array_slice(&p.seen_macros) {
		if prev_name == name {
			return error(p, name_pos, "duplicate macro definition %q in template", name)
		}
	}

	prefix :: "proc"
	expr, synthetic := parse_prefixed_odin_expr(
		p,
		tok,
		raw_src,
		prefix,
		"macro parameter list",
		open_paren,
	) or_return

	proc_type, is_proc := expr.derived_expr.(^ast.Proc_Type)
	if !is_proc {
		return error(p, tok.pos, "invalid macro signature %q", strings.trim_space(raw_src))
	}
	if proc_type.results != nil {
		return error(p, tok.pos, "invalid macro signature: macros cannot declare a return type")
	}

	if out_node.param_names == nil {
		out_node.param_names = make([dynamic]string, p.allocator)
	}
	out_node.min_args = 0
	out_node.max_args = 0
	out_node.has_varargs = false

	if proc_type.params != nil {
		for field in proc_type.params.list {
			field_syn_off := field.pos.offset
			if field_syn_off <= 0 && field.type != nil {
				field_syn_off = field.type.pos.offset
			}
			rel_field_offset := open_paren + max(field_syn_off - len(prefix), 0)
			field_pos := advance_pos_by_offset(tok.pos, raw_src, rel_field_offset)

			is_unnamed_type_only := field.type != nil && (len(field.names) == 0 || field.names[0].pos.offset >= field.type.pos.offset)
			if len(field.names) == 0 || is_unnamed_type_only || (field.type == nil && field.default_value == nil) {
				return error(
					p,
					field_pos,
					"macro parameter in %q must have an explicit type or default value (e.g. \"param: string\" or \"active := false\")",
					name,
				)
			}

			is_vararg := false
			if field.type != nil {
				_, is_vararg = field.type.derived_expr.(^ast.Ellipsis)
			}

			for name_expr in field.names {
				rel_name_offset := open_paren + max(name_expr.pos.offset - len(prefix), 0)
				param_pos := advance_pos_by_offset(tok.pos, raw_src, rel_name_offset)
				ident, is_ident := name_expr.derived_expr.(^ast.Ident)
				if !is_ident {
					return error(p, param_pos, "invalid parameter name in macro %q", name)
				}
				for prev_p in out_node.param_names {
					if prev_p == ident.name {
						return error(p, param_pos, "duplicate parameter %q in macro %q", ident.name, name)
					}
				}
				append(&out_node.param_names, ident.name)
				if is_vararg {
					out_node.has_varargs = true
				} else if field.default_value != nil {
					out_node.max_args += 1
				} else {
					out_node.min_args += 1
					out_node.max_args += 1
				}
			}
		}
	}

	small_array_append(&p.seen_macros, name, p.allocator)
	out_node.name = name
	if proc_type.params != nil && len(proc_type.params.list) > 0 {
		close_paren_off := proc_type.end.offset - 1
		if close_paren_off > len(prefix) + 1 && close_paren_off <= len(synthetic) {
			inner_params := strip_trailing_comma_and_comments(
				synthetic[len(prefix) + 1 : close_paren_off],
			)
			out_node.params_src = inner_params
		}
	}
	return true
}

@(private = "file")
try_fast_validate_call_expr :: proc(p: ^Parser, tok: Token, raw_src: string, out_node: ^Node_Call) -> bool {
	if len(raw_src) < 3 || raw_src[len(raw_src) - 1] != ')' {
		return false
	}
	open_p := strings.index_byte(raw_src, '(')
	if open_p <= 0 {
		return false
	}
	name_lead := 0
	for name_lead < open_p && is_ws(raw_src[name_lead]) {
		name_lead += 1
	}
	name := strings.trim_space(raw_src[:open_p])
	if !is_valid_non_keyword_ident(name) {
		return false
	}

	inner_args := raw_src[open_p + 1 : len(raw_src) - 1]
	trimmed_inner := strings.trim_space(inner_args)
	out_node.name = name
	out_node.name_pos = advance_pos_by_offset(tok.pos, raw_src, name_lead)
	out_node.arg_count = 0
	out_node.args = nil

	if len(trimmed_inner) == 0 {
		out_node.args_src = ""
		return true
	}

	// Fast path for comma-separated simple arguments (clean string literals or simple selector chains)
	// with no nested parentheses, brackets, braces, comments, or '=' named arguments.
	in_quote := false
	for i := 0; i < len(inner_args); i += 1 {
		c := inner_args[i]
		if in_quote {
			if c == '\\' || c == '\n' || c == '\r' {
				return false
			}
			if c == '"' {
				in_quote = false
			}
			continue
		}
		switch c {
		case '"':
			in_quote = true
		case '(', ')', '[', ']', '{', '}', '=', '/', '`', '\'':
			return false
		}
	}
	if in_quote {
		return false
	}

	parsed_count := 0
	seg_start := 0
	for i := 0; i <= len(inner_args); i += 1 {
		if i == len(inner_args) || inner_args[i] == ',' {
			seg := inner_args[seg_start:i]
			arg_trimmed := strings.trim_space(seg)
			if len(arg_trimmed) == 0 {
				if i == len(inner_args) && parsed_count > 0 {
					// Trailing comma after valid arguments
					break
				}
				return false
			}
			if !is_simple_clean_string_literal(arg_trimmed) && !is_simple_selector_expr(arg_trimmed) {
				return false
			}
			parsed_count += 1
			seg_start = i + 1
		}
	}

	out_node.arg_count = parsed_count
	out_node.args_src = strip_trailing_comma_and_comments(inner_args)
	return true
}

@(private = "file")
validate_call_expr :: proc(p: ^Parser, tok: Token, out_node: ^Node_Call) -> bool {
	raw_src := strings.trim_right_space(tok.value)
	context.allocator = p.allocator

	if try_fast_validate_call_expr(p, tok, raw_src, out_node) {
		return true
	}

	expr, _ := parse_prefixed_odin_expr(p, tok, raw_src, "", "\"call\" tag") or_return

	call, is_call := expr.derived_expr.(^ast.Call_Expr)
	if !is_call {
		err_pos := advance_pos_by_offset(tok.pos, raw_src, expr.pos.offset)
		return error(
			p,
			err_pos,
			"invalid \"call\" syntax %q: expected a macro call like \"name(args...)\"",
			strings.trim_space(raw_src),
		)
	}

	ident, is_ident := call.expr.derived_expr.(^ast.Ident)
	if !is_ident {
		err_pos := advance_pos_by_offset(tok.pos, raw_src, call.expr.pos.offset)
		return error(p, err_pos, "invalid macro call target: expected a macro identifier")
	}

	out_node.name = ident.name
	out_node.name_pos = advance_pos_by_offset(tok.pos, raw_src, call.expr.pos.offset)
	out_node.args = make([dynamic]Call_Arg_Info, 0, len(call.args), p.allocator)

	seen_named := false
	for arg in call.args {
		arg_pos := advance_pos_by_offset(tok.pos, raw_src, arg.pos.offset)
		if fv, is_fv := arg.derived_expr.(^ast.Field_Value); is_fv {
			seen_named = true
			field_ident, is_field_ident := fv.field.derived_expr.(^ast.Ident)
			if !is_field_ident {
				return error(p, arg_pos, "invalid named argument in call to macro %q: expected parameter identifier", ident.name)
			}
			for prev_arg in out_node.args {
				if prev_arg.name == field_ident.name {
					return error(p, arg_pos, "duplicate argument %q in call to macro %q", field_ident.name, ident.name)
				}
			}
			append(&out_node.args, Call_Arg_Info{name = field_ident.name, pos = arg_pos})
		} else {
			if seen_named {
				return error(
					p,
					arg_pos,
					"positional argument cannot follow named argument in call to macro %q",
					ident.name,
				)
			}
			append(&out_node.args, Call_Arg_Info{pos = arg_pos})
		}
	}

	inner_args := raw_src[call.open.offset + 1 : call.close.offset]
	out_node.arg_count = len(out_node.args)
	out_node.args_src = strip_trailing_comma_and_comments(inner_args)
	return true
}

check_macro_call_node :: proc(
	call_node: ^Node_Call,
	macros: []^Node_Macro,
	allocator := context.temp_allocator,
) -> (
	err_pos: Pos,
	err_col_len: int,
	err_msg: string,
	ok: bool,
) {
	mac: ^Node_Macro
	for m in macros {
		if m.name == call_node.name {
			mac = m
			break
		}
	}
	if mac == nil {
		if len(macros) == 0 {
			return call_node.name_pos,
				len(call_node.name),
				fmt.aprintf("undefined macro %q (no macros are defined in this template)", call_node.name, allocator = allocator),
				false
		}
		valid_names := make([dynamic]string, 0, len(macros), allocator)
		for m in macros {
			append(&valid_names, m.name)
		}
		for i := 1; i < len(valid_names); i += 1 {
			key := valid_names[i]
			j := i - 1
			for j >= 0 && valid_names[j] > key {
				valid_names[j + 1] = valid_names[j]
				j -= 1
			}
			valid_names[j + 1] = key
		}
		valid_list := strings.join(valid_names[:], ", ", allocator)
		return call_node.name_pos,
			len(call_node.name),
			fmt.aprintf("undefined macro %q (available macros: %s)", call_node.name, valid_list, allocator = allocator),
			false
	}

	for arg in call_node.args {
		if len(arg.name) > 0 {
			known_param := false
			for pname in mac.param_names {
				if pname == arg.name {
					known_param = true
					break
				}
			}
			if !known_param {
				return arg.pos,
					len(arg.name),
					fmt.aprintf("unknown parameter %q in call to macro %q", arg.name, call_node.name, allocator = allocator),
					false
			}
		}
	}

	n_args := call_node.arg_count if len(call_node.args) == 0 else len(call_node.args)
	if mac.has_varargs {
		if n_args < mac.min_args {
			return call_node.name_pos,
				len(call_node.name),
				fmt.aprintf("macro %q expects at least %i argument(s), got %i", call_node.name, mac.min_args, n_args, allocator = allocator),
				false
		}
	} else if mac.min_args == mac.max_args {
		if n_args != mac.min_args {
			return call_node.name_pos,
				len(call_node.name),
				fmt.aprintf("macro %q expects %i argument(s), got %i", call_node.name, mac.min_args, n_args, allocator = allocator),
				false
		}
	} else {
		if n_args < mac.min_args || n_args > mac.max_args {
			return call_node.name_pos,
				len(call_node.name),
				fmt.aprintf("macro %q expects %i to %i arguments, got %i", call_node.name, mac.min_args, mac.max_args, n_args, allocator = allocator),
				false
		}
	}

	return {}, 0, "", true
}

collect_top_level_macros :: proc(nodes: []Node, out: ^Small_Array(16, ^Node_Macro), allocator: mem.Allocator) -> []^Node_Macro {
	for node in nodes {
		if mac, is_mac := node.derived.(^Node_Macro); is_mac {
			small_array_append(out, mac, allocator)
		}
	}
	return small_array_slice(out)
}

@(private = "file")
validate_standalone_macro_calls :: proc(p: ^Parser) {
	macros_arr: Small_Array(16, ^Node_Macro)
	macros_slice := collect_top_level_macros(p.template.content[:], &macros_arr, p.allocator)
	_ = validate_calls_in_parser_nodes(p, p.template.content[:], macros_slice)
}

@(private = "file")
validate_calls_in_parser_nodes :: proc(
	p: ^Parser,
	nodes: []Node,
	macros: []^Node_Macro,
) -> bool {
	Walk_State :: struct {
		p:      ^Parser,
		macros: []^Node_Macro,
	}
	state := Walk_State{p, macros}
	visit_cb :: proc(body: []Node, user_data: rawptr) -> bool {
		s := cast(^Walk_State)user_data
		return validate_calls_in_parser_nodes(s.p, body, s.macros)
	}

	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Call:
			if err_pos, _, err_msg, ok := check_macro_call_node(d, macros, p.allocator); !ok {
				return error(p, err_pos, "%s", err_msg)
			}
		case ^Node_Block:
			validate_calls_in_parser_nodes(p, d.body[:], macros) or_return
		case:
			walk_branch_children(node, &state, visit_cb) or_return
		}
	}
	return true
}

@(private = "file")
strip_trailing_comma_and_comments :: proc(s: string) -> string {
	// Fast path when no `//` or `/*` comments are present
	if strings.index_byte(s, '/') == -1 {
		end := len(s)
		for end > 0 {
			c := s[end - 1]
			if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',' {
				end -= 1
			} else {
				break
			}
		}
		start := 0
		for start < end {
			c := s[start]
			if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
				start += 1
			} else {
				break
			}
		}
		return s[start:end]
	}

	t: tokenizer.Tokenizer
	tokenizer.init(&t, s, "snippet", odin_silent_err_handler)
	t.flags += {.Insert_Semicolon}

	last_non_comma_end := 0
	for {
		tok := tokenizer.scan(&t)
		if tok.kind == .EOF {
			break
		}
		if tok.kind == .Semicolon && (tok.text == "\n" || tok.text == "\r\n") {
			continue
		}
		if tok.kind == .Comment {
			continue
		}
		if tok.kind == .Comma {
			continue
		}
		last_non_comma_end = tok.pos.offset + len(tok.text)
	}
	if last_non_comma_end == 0 {
		return ""
	}
	return strings.trim_space(s[:last_non_comma_end])
}

parse_body :: proc(
	p: ^Parser,
	container: ^[dynamic]Node,
	is_end: proc(t: Token) -> bool,
	block_kind := "block",
	open_pos := Pos{},
) -> (
	end_open: Token,
	end_process: Token,
	ok: bool,
) {
	p.body_depth += 1
	defer p.body_depth -= 1

	for {
		tok := lexer_next(&p.lexer)

		switch tok.type {
		case .Output_Open:
			append_parsed_node(p, container, parse_output(p, tok) or_return)

		case .Text:
			append_parsed_node(p, container, parse_text(p, tok))

		case .Process_Open:
			parser_maybe_remove_whitespace(p, tok)

			process_type := lexer_next(&p.lexer)
			if is_end(process_type) {
				end_open = tok
				end_process = process_type
				ok = true
				return
			}

			if (process_type.type == .Else || process_type.type == .ElseIf) && block_kind != "if" {
				error(
					p,
					process_type.pos,
					"unexpected %q inside %q block (opened at %i:%i)",
					process_type.value,
					block_kind,
					open_pos.line + 1,
					open_pos.col + 1,
				) or_return
			}

			if process_type.type == .Case && block_kind != "switch" {
				error(
					p,
					process_type.pos,
					"unexpected \"case\" inside %q block (opened at %i:%i)",
					block_kind,
					open_pos.line + 1,
					open_pos.col + 1,
				) or_return
			}

			append_parsed_node(p, container, parse_process(p, tok, process_type) or_return)

		case .EOF:
			error(
				p,
				open_pos,
				"unclosed %q tag (opened at %i:%i), expected \"{{%% end %%}}\" before EOF",
				block_kind,
				open_pos.line + 1,
				open_pos.col + 1,
			) or_return

		case .Output_Close, .Process_Close, .Illegal, .If, .End, .For, .Else, .ElseIf, .Switch, .Partial_Switch, .Case, .Let, .Embed_With, .Embed_Path, .Embed, .Extends, .Block, .Super, .Macro, .Call:
			fallthrough

		case:
			error(p, tok.pos, "invalid token inside %q body: got %q", block_kind, tok.value) or_return
		}
	}
}

parse_embed :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Embed, ok: bool) {
	assert(process_type.type == .Embed)

	t = alloc_parser_node(p, Node_Embed)
	t.derived = t
	t.props.allocator = p.allocator

	t.open = process

	t.path = lexer_next(&p.lexer)
	if t.path.type != .Embed_Path || len(t.path.value) < 2 || t.path.value[len(t.path.value)-1] != '"' {
		error(p, t.path.pos, "invalid token after \"embed\", expected a double quoted string pointing at a template file, got: %q", t.path.value) or_return
	}

	if len(t.path.value) <= 2 {
		error(p, t.path.pos, "invalid embed path, expected at least 3 characters, got: %q", t.path.value) or_return
	}

	next := lexer_next(&p.lexer)
	if next.type == .Embed_With {
		with := alloc_parser_node(p, Node_Embed_With)
		with.with = next

		with.expr = lexer_next(&p.lexer)
		if with.expr.type != .Text {
			error(p, with.expr.pos, "invalid token after \"with\", expected an expression, got: %q", with.expr.value) or_return
		}

		trimmed_with := strings.trim_space(with.expr.value)
		if strings.has_prefix(trimmed_with, "(") && strings.has_suffix(trimmed_with, ")") {
			// Support `{% embed "card.html" with (title = this.title, active = true) %}`
			if is_props, props_ok := try_parse_embed_props(p, with.expr, &t.props); is_props {
				if !props_ok do return nil, false
			} else {
				validate_embed_with_expr(p, with.expr) or_return
				t.with = with
			}
		} else {
			validate_embed_with_expr(p, with.expr) or_return
			t.with = with
		}

		close_tok := lexer_next(&p.lexer)
		if close_tok.type != .Process_Close {
			error(p, close_tok.pos, "invalid token after with expression, expected \"%%}\", got: %q", close_tok.value) or_return
		}
	} else if next.type == .Text {
		// Support direct call-style `{% embed "card.html"(title = this.title, active = true) %}`
		trimmed := strings.trim_space(next.value)
		if !strings.has_prefix(trimmed, "(") {
			error(p, next.pos, "invalid token after embed path, expected \"with\", \"(props...)\", or \"%%}\", got: %q", next.value) or_return
		}
		parse_embed_props_expr(p, next, &t.props) or_return

		close_tok := lexer_next(&p.lexer)
		if close_tok.type != .Process_Close {
			error(p, close_tok.pos, "invalid token after embed props, expected \"%%}\", got: %q", close_tok.value) or_return
		}
	} else if next.type == .Process_Close {
		// Valid close token
	} else {
		error(p, next.pos, "invalid token after embed path, expected \"with\", \"(props...)\", or \"%%}\", got: %q", next.value) or_return
	}

	ok = true
	return
}

@(private = "file")
try_parse_embed_props :: proc(p: ^Parser, tok: Token, out_props: ^[dynamic]Embed_Prop) -> (is_props: bool, ok: bool) {
	raw_src := strings.trim_right_space(tok.value)
	context.allocator = p.allocator

	prefix :: "__component"
	expr, _, parse_ok := parse_prefixed_odin_expr(p, tok, raw_src, prefix)
	if !parse_ok {
		return false, false
	}
	call, is_call := expr.derived_expr.(^ast.Call_Expr)
	if !is_call {
		return false, false
	}
	// Distinguish `(a + b)` (a parenthesized single binary expr) from `(a = 1, b = 2)`
	if len(call.args) == 1 {
		if _, is_fv := call.args[0].derived_expr.(^ast.Field_Value); !is_fv {
			return false, false
		}
	}
	return true, parse_embed_props_expr(p, tok, out_props)
}

@(private = "file")
is_simple_embed_prop_value :: proc(s: string) -> bool {
	if s == "true" || s == "false" || s == "nil" {
		return true
	}
	if is_simple_clean_string_literal(s) || is_simple_selector_expr(s) {
		return true
	}
	if len(s) > 0 && s[0] >= '0' && s[0] <= '9' {
		all_digits := true
		for i in 0 ..< len(s) {
			if (s[i] < '0' || s[i] > '9') && s[i] != '_' {
				all_digits = false
				break
			}
		}
		if all_digits {
			return true
		}
	}
	return false
}

@(private = "file")
try_fast_parse_embed_props :: proc(p: ^Parser, tok: Token, raw_src: string, out_props: ^[dynamic]Embed_Prop) -> bool {
	open_p := 0
	for open_p < len(raw_src) && is_ws(raw_src[open_p]) {
		open_p += 1
	}
	if open_p >= len(raw_src) || raw_src[open_p] != '(' || raw_src[len(raw_src) - 1] != ')' {
		return false
	}
	inner := raw_src[open_p + 1 : len(raw_src) - 1]
	if len(strings.trim_space(inner)) == 0 {
		return false
	}

	// Reject characters that require full Odin expression parsing
	prop_count := 1
	in_quote := false
	for i := 0; i < len(inner); i += 1 {
		c := inner[i]
		if in_quote {
			if c == '\\' || c == '\n' || c == '\r' {
				return false
			}
			if c == '"' {
				in_quote = false
			}
			continue
		}
		switch c {
		case '"':
			in_quote = true
		case '(', ')', '[', ']', '{', '}', '/', '`', '\'', ':', '+', '-', '*', '%', '&', '|', '<', '>', '!':
			return false
		case ',':
			prop_count += 1
		}
	}
	if in_quote {
		return false
	}

	temp_props := make([dynamic]Embed_Prop, 0, prop_count, p.allocator)
	seg_start := 0
	for i := 0; i <= len(inner); i += 1 {
		if i == len(inner) || inner[i] == ',' {
			seg := inner[seg_start:i]
			lead := 0
			for lead < len(seg) && is_ws(seg[lead]) {
				lead += 1
			}
			seg_trimmed := strings.trim_space(seg)
			if len(seg_trimmed) == 0 {
				if i == len(inner) && len(temp_props) > 0 {
					break
				}
				return false
			}
			arg_pos := advance_pos_by_offset(tok.pos, raw_src, open_p + 1 + seg_start + lead)
			prop_name: string
			val_str: string

			if eq_idx := strings.index_byte(seg_trimmed, '='); eq_idx != -1 {
				lhs := strings.trim_space(seg_trimmed[:eq_idx])
				rhs := strings.trim_space(seg_trimmed[eq_idx + 1:])
				if !is_valid_non_keyword_ident(lhs) || !is_simple_embed_prop_value(rhs) {
					return false
				}
				prop_name = lhs
				val_str = rhs
			} else if is_simple_selector_expr(seg_trimmed) {
				if dot_idx := strings.last_index_byte(seg_trimmed, '.'); dot_idx != -1 {
					prop_name = seg_trimmed[dot_idx + 1:]
				} else {
					prop_name = seg_trimmed
				}
				val_str = seg_trimmed
			} else {
				return false
			}

			for prev_prop in temp_props {
				if prev_prop.name == prop_name {
					return false
				}
			}

			append(&temp_props, Embed_Prop{
				name     = prop_name,
				val_expr = val_str,
				pos      = arg_pos,
			})
			seg_start = i + 1
		}
	}

	out_props^ = temp_props
	return true
}

@(private = "file")
parse_embed_props_expr :: proc(p: ^Parser, tok: Token, out_props: ^[dynamic]Embed_Prop) -> bool {
	raw_src := strings.trim_right_space(tok.value)
	context.allocator = p.allocator

	if try_fast_parse_embed_props(p, tok, raw_src, out_props) {
		return true
	}

	prefix :: "__component"
	expr, synthetic := parse_prefixed_odin_expr(p, tok, raw_src, prefix, "embed props") or_return

	call, is_call := expr.derived_expr.(^ast.Call_Expr)
	if !is_call || len(call.args) == 0 {
		return error(p, tok.pos, "embed props list cannot be empty; pass at least one prop or omit parentheses")
	}

	for arg, i in call.args {
		arg_limit := call.args[i + 1].pos.offset if i + 1 < len(call.args) else call.close.offset
		rel_arg_offset := max(arg.pos.offset - len(prefix), 0)
		arg_pos := advance_pos_by_offset(tok.pos, raw_src, rel_arg_offset)

		prop_name: string
		val_str: string

		#partial switch a in arg.derived_expr {
		case ^ast.Field_Value:
			ident, is_ident := a.field.derived_expr.(^ast.Ident)
			if !is_ident {
				return error(p, arg_pos, "invalid embed prop name: expected an identifier on left-hand side of '='")
			}
			prop_name = ident.name
			val_str = strip_trailing_comma_and_comments(synthetic[a.value.pos.offset : arg_limit])

		case ^ast.Ident:
			// Shorthand punning: `{% embed "card.html"(title) %}` -> `title = title`
			prop_name = a.name
			val_str = a.name

		case ^ast.Selector_Expr:
			// Shorthand punning: `{% embed "card.html"(this.title) %}` -> `title = this.title`
			if a.field == nil {
				return error(p, arg_pos, "invalid selector shorthand in embed props")
			}
			prop_name = a.field.name
			val_str = strip_trailing_comma_and_comments(synthetic[arg.pos.offset : arg_limit])

		case:
			return error(
				p,
				arg_pos,
				"invalid embed prop: expected 'name = expr' or shorthand 'this.field'",
			)
		}

		for prev_prop in out_props^ {
			if prev_prop.name == prop_name {
				return error(p, arg_pos, "duplicate prop %q in embed tag", prop_name)
			}
		}

		append(out_props, Embed_Prop{
			name     = prop_name,
			val_expr = val_str,
			pos      = arg_pos,
		})
	}

	return true
}

@(private = "file")
is_odin_reserved_keyword :: proc(s: string) -> bool {
	switch s {
	case "asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast",
	     "continue", "defer", "distinct", "do", "dynamic", "else", "enum",
	     "fallthrough", "for", "foreign", "if", "import", "in", "map",
	     "matrix", "not_in", "or_break", "or_continue", "or_else", "or_return",
	     "package", "proc", "return", "struct", "switch", "transmute",
	     "typeid", "union", "using", "when", "where":
		return true
	}
	return false
}

@(private = "file")
is_valid_non_keyword_ident :: proc(s: string) -> bool {
	return is_valid_block_ident(s) && !is_odin_reserved_keyword(s)
}

@(private = "file")
is_simple_selector_expr :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	seg_start := 0
	for i := 0; i <= len(s); i += 1 {
		if i == len(s) || s[i] == '.' {
			seg := s[seg_start:i]
			if !is_valid_non_keyword_ident(seg) {
				return false
			}
			seg_start = i + 1
		}
	}
	return true
}

@(private = "file")
is_simple_clean_string_literal :: proc(s: string) -> bool {
	if len(s) < 2 || s[0] != '"' || s[len(s) - 1] != '"' {
		return false
	}
	for i := 1; i < len(s) - 1; i += 1 {
		c := s[i]
		if c < 0x20 || c == '"' || c == '\\' {
			return false
		}
	}
	return true
}

is_valid_block_ident :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if i == 0 {
			if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
				return false
			}
		} else {
			if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') {
				return false
			}
		}
	}
	return true
}

Odin_Parse_Diagnostic :: struct {
	has_err: bool,
	pos:     tokenizer.Pos,
	msg:     string,
}

@(thread_local)
tl_odin_diag: Odin_Parse_Diagnostic

odin_silent_err_handler :: proc(pos: tokenizer.Pos, fmt_str: string, args: ..any) {
	if !tl_odin_diag.has_err {
		tl_odin_diag.has_err = true
		tl_odin_diag.pos = pos
		tl_odin_diag.msg = fmt.tprintf(fmt_str, ..args)
	}
}

odin_silent_warn_handler :: proc(pos: tokenizer.Pos, fmt_str: string, args: ..any) {
}

@(private = "file")
advance_pos_by_offset :: proc(base: Pos, src: string, byte_offset: int) -> Pos {
	res := base
	limit := min(max(byte_offset, 0), len(src))
	for i in 0 ..< limit {
		if src[i] == '\n' {
			res.line += 1
			res.col = 0
		} else {
			res.col += 1
		}
		res.offset += 1
	}
	return res
}

@(private = "file")
init_odin_snippet_parser :: proc(p: ^Parser, op: ^odin_parser.Parser, file: ^ast.File, src: string, insert_semicolon := true) {
	op^ = odin_parser.default_parser()
	op.err = odin_silent_err_handler
	op.warn = odin_silent_warn_handler
	file^ = {}
	file.pkg = &p.dummy_odin_pkg
	file.src = src
	file.fullpath = "template"
	op.file = file
	tl_odin_diag = {}
	tokenizer.init(&op.tok, file.src, file.fullpath, odin_silent_err_handler)
	if insert_semicolon {
		op.tok.flags += {.Insert_Semicolon}
	}
	odin_parser.advance_token(op)
}

@(private = "file")
is_simple_int_literal :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if !((c >= '0' && c <= '9') || (i > 0 && c == '_')) {
			return false
		}
	}
	return true
}

@(private = "file")
is_simple_value_expr :: proc(s: string) -> bool {
	if is_simple_selector_expr(s) {
		return true
	}
	if strings.has_prefix(s, "len(") && s[len(s) - 1] == ')' {
		return is_simple_selector_expr(strings.trim_space(s[4 : len(s) - 1]))
	}
	for i := 1; i < len(s) - 1; i += 1 {
		if s[i] == '+' || s[i] == '-' {
			lhs := strings.trim_space(s[:i])
			rhs := strings.trim_space(s[i + 1:])
			if is_simple_selector_expr(lhs) && (is_simple_int_literal(rhs) || is_simple_selector_expr(rhs)) {
				return true
			}
		}
	}
	return false
}

@(private = "file")
filter_name_to_write_kind :: proc(name: string) -> (kind: Output_Write_Kind, is_wrap: bool, ok: bool) {
	switch name {
	case "raw":        return .Raw_String, false, true
	case "magic":      return .Magic_String, false, true
	case "url":        return .Url_String, false, true
	case "url_param":  return .Url_Param_String, false, true
	case "js", "json": return .Js_String, false, true
	case "byte":       return .Byte, true, true
	case "rune":       return .Rune, true, true
	case "int", "len": return .Int, true, true
	case "uint":       return .Uint, true, true
	case "i128":       return .I128, true, true
	case "u128":       return .U128, true, true
	case "u64":        return .U64, true, true
	case "i64":        return .I64, true, true
	case "f32":        return .F32, true, true
	case "f64":        return .F64, true, true
	}
	return .Escaped_String, false, false
}

@(private = "file")
try_fast_classify_output_expr :: proc(p: ^Parser, node: ^Node_Output, trimmed: string) -> (matched: bool, is_super: bool) {
	if trimmed == "super()" {
		return true, true
	}
	if is_simple_selector_expr(trimmed) {
		node.write_kind = .Escaped_String
		node.inner_expr = trimmed
		return true, false
	}

	// Single-pipe and two-stage pipe fast path: `<simple_expr> | <filter>` or `<simple_expr> | <stage1> | <stage2>`
	if pipe_idx := strings.index_byte(trimmed, '|'); pipe_idx > 0 {
		lhs := strings.trim_space(trimmed[:pipe_idx])
		rhs := strings.trim_space(trimmed[pipe_idx + 1:])
		if is_simple_value_expr(lhs) {
			second_pipe := strings.index_byte(rhs, '|')
			if second_pipe == -1 {
				if is_valid_non_keyword_ident(rhs) {
					if kind, is_wrap, ok := filter_name_to_write_kind(rhs); ok {
						node.write_kind = kind
						node.inner_expr = lhs
						if is_wrap {
							node.wrap_call = rhs
						}
						return true, false
					}
				} else if strings.has_prefix(rhs, "default(") && rhs[len(rhs) - 1] == ')' {
					arg := strings.trim_space(rhs[8 : len(rhs) - 1])
					if is_simple_clean_string_literal(arg) || is_simple_selector_expr(arg) {
						node.write_kind = .Escaped_String
						node.inner_expr = lhs
						node.default_arg = arg
						return true, false
					}
				} else if strings.has_prefix(rhs, "fmt(") && rhs[len(rhs) - 1] == ')' {
					arg := strings.trim_space(rhs[4 : len(rhs) - 1])
					if is_simple_clean_string_literal(arg) {
						node.write_kind = .Fmt_Escaped
						node.fmt_str = arg
						node.inner_expr = lhs
						return true, false
					}
				}
			} else if second_pipe > 0 {
				stage1 := strings.trim_space(rhs[:second_pipe])
				stage2 := strings.trim_space(rhs[second_pipe + 1:])
				if strings.index_byte(stage2, '|') == -1 {
					if strings.has_prefix(stage1, "default(") && stage1[len(stage1) - 1] == ')' {
						def_arg := strings.trim_space(stage1[8 : len(stage1) - 1])
						if is_simple_clean_string_literal(def_arg) || is_simple_selector_expr(def_arg) {
							if is_valid_non_keyword_ident(stage2) {
								if kind, is_wrap, ok := filter_name_to_write_kind(stage2); ok && (!is_wrap || stage2 == "len") {
									node.write_kind = kind
									node.inner_expr = lhs
									node.default_arg = def_arg
									if is_wrap {
										node.wrap_call = stage2
									}
									return true, false
								}
							}
						}
					} else if strings.has_prefix(stage1, "fmt(") && stage1[len(stage1) - 1] == ')' && stage2 == "raw" {
						fmt_arg := strings.trim_space(stage1[4 : len(stage1) - 1])
						if is_simple_clean_string_literal(fmt_arg) {
							node.write_kind = .Fmt_Raw
							node.fmt_str = fmt_arg
							node.inner_expr = lhs
							return true, false
						}
					}
				}
			}
		}
		return false, false
	}

	// Simple single-arg function/cast call: `int(total_rows)`, `int(idx + 1)`, `raw(this.html)`, etc.
	if open_p := strings.index_byte(trimmed, '('); open_p > 0 && trimmed[len(trimmed) - 1] == ')' {
		fn_name := trimmed[:open_p]
		arg := strings.trim_space(trimmed[open_p + 1 : len(trimmed) - 1])
		if is_simple_value_expr(arg) {
			if kind, is_wrap, ok := filter_name_to_write_kind(fn_name); ok {
				node.write_kind = kind
				node.inner_expr = trimmed if is_wrap else arg
				return true, false
			}
		}
	}

	return false, false
}

@(private = "file")
validate_and_classify_output_expr :: proc(p: ^Parser, node: ^Node_Output) -> (is_super: bool, ok: bool) {
	raw_src := node.expression.value
	trimmed := strings.trim_space(raw_src)
	if len(trimmed) == 0 {
		return false, error(p, node.expression.pos, "empty output expression inside \"{{ ... }}\"")
	}

	if matched, fast_super := try_fast_classify_output_expr(p, node, trimmed); matched {
		return fast_super, true
	}

	context.allocator = p.allocator

	op: odin_parser.Parser
	file: ast.File
	init_odin_snippet_parser(p, &op, &file, raw_src, false)

	expr := odin_parser.parse_expr(&op, false)
	if tl_odin_diag.has_err || expr == nil || op.error_count > 0 {
		err_pos := advance_pos_by_offset(node.expression.pos, raw_src, tl_odin_diag.pos.offset)
		msg := tl_odin_diag.msg if len(tl_odin_diag.msg) > 0 else "invalid Odin expression"
		return false, error(p, err_pos, "invalid output expression: %s", msg)
	}

	if _, is_bad := expr.derived.(^ast.Bad_Expr); is_bad {
		err_pos := advance_pos_by_offset(node.expression.pos, raw_src, expr.pos.offset)
		return false, error(p, err_pos, "invalid output expression")
	}

	if op.curr_tok.kind != .EOF {
		err_pos := advance_pos_by_offset(node.expression.pos, raw_src, op.curr_tok.pos.offset)
		if op.curr_tok.kind == .Eq || op.curr_tok.kind == .Colon {
			return false, error(
				p,
				err_pos,
				"unexpected %q in output expression (statements/assignments are not allowed inside \"{{ ... }}\")",
				op.curr_tok.text,
			)
		}
		return false, error(p, err_pos, "unexpected trailing token %q in output expression", op.curr_tok.text)
	}

	node.write_kind = .Escaped_String
	node.inner_expr = trimmed

	return classify_output_ast(p, node, raw_src, expr)
}

@(private = "file")
classify_output_ast :: proc(
	p: ^Parser,
	node: ^Node_Output,
	raw_src: string,
	expr: ^ast.Expr,
) -> (
	is_super: bool,
	ok: bool,
) {
	// 1. Pipe filter syntax: `lhs | filter` or `lhs | filter(arg)`
	// Check BEFORE `ast.unparen_expr(expr)` so parenthesized bitwise-OR expressions
	// like `{{ (this.flags | 0x01) | int }}` are preserved as Odin bitwise-OR on the LHS.
	if bin, is_bin := expr.derived_expr.(^ast.Binary_Expr); is_bin && bin.op.kind == .Or {
		lhs_str := strings.trim_space(raw_src[bin.left.pos.offset : bin.op.pos.offset])
		node.inner_expr = lhs_str
		lhs_is_super, lhs_ok := classify_output_ast(p, node, raw_src, bin.left)
		if !lhs_ok do return false, false
		if lhs_is_super {
			return false, error(
				p,
				advance_pos_by_offset(node.expression.pos, raw_src, bin.op.pos.offset),
				"\"super()\" cannot be used with pipe filters",
			)
		}
		effective_lhs := node.inner_expr

		rhs := ast.unparen_expr(bin.right)

		// Once a terminal writer kind is selected on the LHS, only `fmt(...) | raw` or numeric/`len` -> `fmt(...)` is valid
		if node.write_kind != .Escaped_String {
			is_raw_ident := false
			if ident, is_ident := rhs.derived_expr.(^ast.Ident); is_ident && ident.name == "raw" {
				is_raw_ident = true
			}
			is_fmt_call := false
			if call, is_call := rhs.derived_expr.(^ast.Call_Expr); is_call {
				if ident, is_ident := call.expr.derived_expr.(^ast.Ident); is_ident && ident.name == "fmt" {
					is_fmt_call = true
				}
			}
			allowed_chain := (node.write_kind == .Fmt_Escaped && is_raw_ident) ||
				(is_fmt_call &&
					node.write_kind != .Raw_String &&
					node.write_kind != .Magic_String &&
					node.write_kind != .Url_String &&
					node.write_kind != .Url_Param_String &&
					node.write_kind != .Js_String &&
					node.write_kind != .Fmt_Escaped &&
					node.write_kind != .Fmt_Raw)
			if !allowed_chain {
				return false, error(
					p,
					advance_pos_by_offset(node.expression.pos, raw_src, rhs.pos.offset),
					"cannot pipe additional filters after terminal output modifier",
				)
			}
		}

		// Bare identifier filter: `{{ this.html | raw }}`, `{{ this.title | magic }}`, `{{ this.link | url }}`, `{{ this.q | url_param }}`, `{{ this.payload | js }}`, `{{ this.items | len }}`
		if ident, is_ident := rhs.derived_expr.(^ast.Ident); is_ident {
			if kind, is_wrap, ok := filter_name_to_write_kind(ident.name); ok {
				if kind == .Raw_String && node.write_kind == .Fmt_Escaped {
					node.write_kind = .Fmt_Raw
				} else {
					node.write_kind = kind
				}
				node.inner_expr = effective_lhs
				if is_wrap {
					node.wrap_call = ident.name
				}
				return false, true
			}
		}

		// Parameterized pipe filter: `{{ this.price | fmt("%.2f") }}` or `{{ this.name | default("Guest") }}`
		if call, is_call := rhs.derived_expr.(^ast.Call_Expr); is_call {
			if ident, is_ident := call.expr.derived_expr.(^ast.Ident); is_ident {
				switch ident.name {
				case "fmt":
					if len(call.args) != 1 {
						return false, error(
							p,
							advance_pos_by_offset(node.expression.pos, raw_src, call.pos.offset),
							"pipe filter \"fmt()\" expects 1 format string argument, got %i",
							len(call.args),
						)
					}
					node.write_kind = .Fmt_Escaped
					node.fmt_str = strip_trailing_comma_and_comments(raw_src[call.open.offset + 1 : call.close.offset])
					node.inner_expr = effective_lhs
					return false, true
				case "default":
					if len(call.args) != 1 {
						return false, error(
							p,
							advance_pos_by_offset(node.expression.pos, raw_src, call.pos.offset),
							"pipe filter \"default()\" expects 1 fallback argument, got %i",
							len(call.args),
						)
					}
					fallback_str := strip_trailing_comma_and_comments(raw_src[call.open.offset + 1 : call.close.offset])
					if len(node.default_arg) == 0 && len(node.wrap_call) == 0 {
						node.inner_expr = effective_lhs
						node.default_arg = fallback_str
					} else {
						node.inner_expr = fmt.aprintf(
							"__temple_default(%s, %s)",
							effective_lhs,
							fallback_str,
							allocator = p.allocator,
						)
					}
					return false, true
				}
			}
		}

		rhs_end := rhs.end.offset
		if call, is_call := rhs.derived_expr.(^ast.Call_Expr); is_call {
			rhs_end = max(rhs_end, call.close.offset + 1)
		}
		rhs_end = min(rhs_end, len(raw_src))

		return false, error(
			p,
			advance_pos_by_offset(node.expression.pos, raw_src, rhs.pos.offset),
			"unknown output pipe filter %q",
			strings.trim_space(raw_src[rhs.pos.offset : rhs_end]),
		)
	}

	expr := ast.unparen_expr(expr)

	// 2. Call syntax: `super()`, `raw(...)`, `magic(...)`, `fmt(format, ...args)`, `default(val, fallback)`, casts
	if call, is_call := expr.derived_expr.(^ast.Call_Expr); is_call {
		if ident, is_ident := call.expr.derived_expr.(^ast.Ident); is_ident {
			switch ident.name {
			case "super":
				if len(call.args) != 0 {
					return false, error(
						p,
						advance_pos_by_offset(node.expression.pos, raw_src, call.pos.offset),
						"\"super()\" expects 0 arguments, got %i",
						len(call.args),
					)
				}
				return true, true
			case "raw", "magic", "url", "url_param", "js", "json":
				if len(call.args) != 1 {
					return false, error(
						p,
						advance_pos_by_offset(node.expression.pos, raw_src, call.pos.offset),
						"\"%s()\" expects exactly 1 argument, got %i",
						ident.name,
						len(call.args),
					)
				}
				target_kind, _, _ := filter_name_to_write_kind(ident.name)
				arg_expr := call.args[0]
				node.inner_expr = strip_trailing_comma_and_comments(raw_src[call.open.offset + 1 : call.close.offset])
				arg_is_super, arg_ok := classify_output_ast(p, node, raw_src, arg_expr)
				if !arg_ok do return false, false
				if arg_is_super {
					return false, error(
						p,
						advance_pos_by_offset(node.expression.pos, raw_src, arg_expr.pos.offset),
						"\"super()\" cannot be used inside \"%s()\"",
						ident.name,
					)
				}
				if target_kind == .Raw_String && node.write_kind == .Fmt_Escaped {
					node.write_kind = .Fmt_Raw
				} else if node.write_kind != .Escaped_String {
					return false, error(
						p,
						advance_pos_by_offset(node.expression.pos, raw_src, arg_expr.pos.offset),
						"cannot wrap terminal output modifier inside \"%s()\"",
						ident.name,
					)
				} else {
					node.write_kind = target_kind
				}
				return false, true
			case "fmt":
				if len(call.args) < 2 {
					return false, error(
						p,
						advance_pos_by_offset(node.expression.pos, raw_src, call.pos.offset),
						"\"fmt()\" expects a format string and at least 1 value, got %i argument(s)",
						len(call.args),
					)
				}
				first_arg := call.args[0]
				second_arg := call.args[1]
				node.write_kind = .Fmt_Escaped
				node.fmt_str = strip_trailing_comma_and_comments(raw_src[first_arg.pos.offset : second_arg.pos.offset])
				node.inner_expr = strip_trailing_comma_and_comments(raw_src[second_arg.pos.offset : call.close.offset])
				return false, true
			case "default":
				if len(call.args) != 2 {
					return false, error(
						p,
						advance_pos_by_offset(node.expression.pos, raw_src, call.pos.offset),
						"\"default()\" expects 2 arguments (value, fallback), got %i",
						len(call.args),
					)
				}
				first_arg := call.args[0]
				second_arg := call.args[1]
				val_str := strip_trailing_comma_and_comments(raw_src[first_arg.pos.offset : second_arg.pos.offset])
				fallback_str := strip_trailing_comma_and_comments(raw_src[second_arg.pos.offset : call.close.offset])
				node.inner_expr = val_str
				node.default_arg = fallback_str
				return false, true
			case "byte", "rune", "int", "len", "uint", "i128", "u128", "u64", "i64", "f32", "f64":
				if len(call.args) != 1 {
					return false, error(
						p,
						advance_pos_by_offset(node.expression.pos, raw_src, call.pos.offset),
						"\"%s()\" expects 1 argument, got %i",
						ident.name,
						len(call.args),
					)
				}
				node.write_kind, _, _ = filter_name_to_write_kind(ident.name)
			}
		}
	}

	return false, true
}

@(private = "file")
is_synthetic_eof :: proc(tok: tokenizer.Token, min_offset := 0) -> bool {
	if tok.kind == .EOF {
		return true
	}
	if tok.kind == .Semicolon && (tok.text == "\n" || tok.text == "\r\n") && tok.pos.offset >= min_offset {
		return true
	}
	return false
}

@(private = "file")
validate_let_assignment_expr :: proc(p: ^Parser, tok: Token, eq_idx: int) -> (has_type_decl: bool, ok: bool) {
	raw_src := strings.trim_right_space(tok.value)
	context.allocator = p.allocator

	if eq_idx <= 0 || eq_idx >= len(raw_src) {
		return false, error(p, tok.pos, "invalid `let` assignment")
	}
	lhs_slice := raw_src[:eq_idx]
	rhs_slice := raw_src[eq_idx+1:]
	lhs_trimmed := strings.trim_space(lhs_slice)
	rhs_trimmed := strings.trim_space(rhs_slice)

	ident_candidate := strings.trim_space(lhs_trimmed[:len(lhs_trimmed)-1]) if strings.has_suffix(lhs_trimmed, ":") else lhs_trimmed
	if is_valid_non_keyword_ident(ident_candidate) {
		if is_simple_selector_expr(rhs_trimmed) || is_simple_clean_string_literal(rhs_trimmed) {
			return false, true
		}
		if strings.has_prefix(rhs_trimmed, "len(") && rhs_trimmed[len(rhs_trimmed)-1] == ')' {
			if is_simple_selector_expr(strings.trim_space(rhs_trimmed[4 : len(rhs_trimmed)-1])) {
				return false, true
			}
		}
	}

	synthetic: string
	stack_buf: [512]byte
	if strings.has_suffix(lhs_trimmed, ":") {
		ident_part := strings.trim_space(lhs_trimmed[:len(lhs_trimmed)-1])
		total_len := len(ident_part) + 3 + len(rhs_slice)
		if total_len <= len(stack_buf) {
			copy(stack_buf[0:], ident_part)
			copy(stack_buf[len(ident_part):], " :=")
			copy(stack_buf[len(ident_part)+3:], rhs_slice)
			synthetic = string(stack_buf[:total_len])
		} else {
			synthetic = strings.concatenate({ident_part, " :=", rhs_slice}, p.allocator)
		}
	} else if find_top_level_colon(lhs_trimmed) != -1 {
		has_type_decl = true
		synthetic = raw_src
	} else {
		total_len := len(lhs_slice) + 2 + len(rhs_slice)
		if total_len <= len(stack_buf) {
			copy(stack_buf[0:], lhs_slice)
			copy(stack_buf[len(lhs_slice):], ":=")
			copy(stack_buf[len(lhs_slice)+2:], rhs_slice)
			synthetic = string(stack_buf[:total_len])
		} else {
			synthetic = strings.concatenate({lhs_slice, ":=", rhs_slice}, p.allocator)
		}
	}

	op: odin_parser.Parser
	file: ast.File
	init_odin_snippet_parser(p, &op, &file, synthetic)

	dummy_node: ast.Node
	op.curr_proc = &dummy_node

	stmt := odin_parser.parse_stmt(&op)
	if tl_odin_diag.has_err || stmt == nil || op.error_count > 0 {
		err_pos := advance_pos_by_offset(tok.pos, raw_src, tl_odin_diag.pos.offset)
		msg := tl_odin_diag.msg if len(tl_odin_diag.msg) > 0 else "invalid assignment in `let`"
		return false, error(p, err_pos, "invalid `let` assignment: %s", msg)
	}

	if !is_synthetic_eof(op.curr_tok, len(synthetic)) {
		err_pos := advance_pos_by_offset(tok.pos, raw_src, op.curr_tok.pos.offset)
		return false, error(p, err_pos, "unexpected trailing token %q in `let` assignment", op.curr_tok.text)
	}

	if stmt == nil || stmt.derived_stmt == nil {
		return false, error(p, tok.pos, "invalid `let` assignment")
	}
	vdecl, is_vdecl := stmt.derived_stmt.(^ast.Value_Decl)
	if !is_vdecl || !vdecl.is_mutable || len(vdecl.names) == 0 {
		return false, error(
			p,
			tok.pos,
			"invalid `let` assignment: expected a variable declaration (e.g. `let x = 1` or `let x: int = 1`)",
		)
	}

	for name_expr in vdecl.names {
		if _, is_ident := name_expr.derived_expr.(^ast.Ident); !is_ident {
			err_pos := advance_pos_by_offset(tok.pos, raw_src, name_expr.pos.offset)
			return false, error(
				p,
				err_pos,
				"invalid `let` assignment: left-hand side must be identifier(s), got expression",
			)
		}
	}

	return has_type_decl, true
}

@(private = "file")
validate_wrapped_stmt :: proc(p: ^Parser, tok: Token, prefix, suffix, label: string) -> bool {
	raw_src := strings.trim_right_space(tok.value)
	context.allocator = p.allocator

	synthetic: string
	stack_buf: [512]byte
	total_len := len(prefix) + len(raw_src) + len(suffix)
	if total_len <= len(stack_buf) {
		copy(stack_buf[0:], prefix)
		copy(stack_buf[len(prefix):], raw_src)
		copy(stack_buf[len(prefix)+len(raw_src):], suffix)
		synthetic = string(stack_buf[:total_len])
	} else {
		synthetic = strings.concatenate({prefix, raw_src, suffix}, p.allocator)
	}
	op: odin_parser.Parser
	file: ast.File
	init_odin_snippet_parser(p, &op, &file, synthetic)

	dummy_node: ast.Node
	op.curr_proc = &dummy_node

	stmt := odin_parser.parse_stmt(&op)
	if tl_odin_diag.has_err || stmt == nil || op.error_count > 0 {
		rel_offset := max(tl_odin_diag.pos.offset - len(prefix), 0)
		err_pos := advance_pos_by_offset(tok.pos, raw_src, rel_offset)
		msg := tl_odin_diag.msg if len(tl_odin_diag.msg) > 0 else "invalid syntax"
		return error(p, err_pos, "invalid %s: %s", label, msg)
	}

	if !is_synthetic_eof(op.curr_tok, len(synthetic)) {
		rel_offset := max(op.curr_tok.pos.offset - len(prefix), 0)
		err_pos := advance_pos_by_offset(tok.pos, raw_src, rel_offset)
		return error(p, err_pos, "unexpected trailing token %q in %s", op.curr_tok.text, label)
	}

	return true
}

@(private = "file")
validate_case_expr :: proc(p: ^Parser, tok: Token) -> bool {
	trimmed := strings.trim_space(tok.value)
	if len(trimmed) > 1 && trimmed[0] == '.' && is_valid_non_keyword_ident(trimmed[1:]) {
		return true
	}
	if is_simple_clean_string_literal(trimmed) || is_simple_selector_expr(trimmed) {
		return true
	}
	return validate_wrapped_stmt(p, tok, "switch { case ", ": }", "\"case\" expression")
}

@(private = "file")
validate_switch_header_expr :: proc(p: ^Parser, tok: Token, is_partial: bool) -> bool {
	trimmed := strings.trim_space(tok.value)
	if is_simple_selector_expr(trimmed) {
		return true
	}
	prefix := "#partial switch " if is_partial else "switch "
	return validate_wrapped_stmt(p, tok, prefix, " {}", "\"switch\" expression")
}

@(private = "file")
validate_if_condition_expr :: proc(p: ^Parser, tok: Token, tag_name: string) -> bool {
	trimmed := strings.trim_space(tok.value)
	if len(trimmed) == 0 {
		return error(p, tok.pos, "missing condition expression after %q", tag_name)
	}
	if is_simple_selector_expr(trimmed) {
		return true
	}
	if len(trimmed) > 1 && trimmed[0] == '!' && is_simple_selector_expr(strings.trim_space(trimmed[1:])) {
		return true
	}
	label: string
	switch tag_name {
	case "if":
		label = "\"if\" condition"
	case "elseif":
		label = "\"elseif\" condition"
	case:
		label = fmt.aprintf("%q condition", tag_name, allocator = p.allocator)
	}
	return validate_wrapped_stmt(p, tok, "if ", " {}", label)
}

@(private = "file")
validate_for_clause_expr :: proc(p: ^Parser, tok: Token) -> bool {
	trimmed := strings.trim_space(tok.value)
	if len(trimmed) == 0 {
		return error(p, tok.pos, "missing loop clause after \"for\"")
	}
	if in_idx := strings.index(trimmed, " in "); in_idx > 0 {
		lhs := strings.trim_space(trimmed[:in_idx])
		rhs := strings.trim_space(trimmed[in_idx + 4:])
		if is_simple_selector_expr(rhs) {
			if is_valid_non_keyword_ident(lhs) {
				return true
			}
			if comma_idx := strings.index_byte(lhs, ','); comma_idx > 0 {
				v1 := strings.trim_space(lhs[:comma_idx])
				v2 := strings.trim_space(lhs[comma_idx + 1:])
				if is_valid_non_keyword_ident(v1) && is_valid_non_keyword_ident(v2) {
					return true
				}
			}
		}
	}
	return validate_wrapped_stmt(p, tok, "for ", " {}", "\"for\" clause")
}

@(private = "file")
validate_embed_with_expr :: proc(p: ^Parser, tok: Token) -> bool {
	raw_src := tok.value
	if len(strings.trim_space(raw_src)) == 0 {
		return error(p, tok.pos, "missing expression after \"with\"")
	}

	context.allocator = p.allocator

	op: odin_parser.Parser
	file: ast.File
	init_odin_snippet_parser(p, &op, &file, raw_src, false)

	expr := odin_parser.parse_expr(&op, false)
	if tl_odin_diag.has_err || expr == nil || op.error_count > 0 {
		err_pos := advance_pos_by_offset(tok.pos, raw_src, tl_odin_diag.pos.offset)
		msg := tl_odin_diag.msg if len(tl_odin_diag.msg) > 0 else "invalid expression"
		return error(p, err_pos, "invalid \"with\" expression: %s", msg)
	}

	if op.curr_tok.kind != .EOF {
		err_pos := advance_pos_by_offset(tok.pos, raw_src, op.curr_tok.pos.offset)
		return error(p, err_pos, "unexpected trailing token %q in \"with\" expression", op.curr_tok.text)
	}

	return true
}

/*
Removes whitespace occupied by the space before the given process token,
from the previous text node if it directly borders it, and it is on a previous line.

This makes lines that only contain process nodes not end up in the output as blank lines,
but just removes them for more concise and accurate output.
*/
parser_maybe_remove_whitespace :: proc(p: ^Parser, token: Token) {
	assert(token.type == .Process_Open)

	last_txt, ok := p.last_txt_node.?
	if !ok do return

	// If the last text node doesn't border this token, keep the whitespace.
	last_offset := last_txt.text.pos.offset + len(last_txt.text.value)
	if last_offset != token.pos.offset {
		return
	}

	// If they are on the same line, keep the whitespace.
	if last_txt.text.pos.line == token.pos.line {
		return
	}

	new_end := len(last_txt.text.value)
	#reverse for c, i in transmute([]byte)last_txt.text.value {
		switch c {
		case ' ', '\t':
			new_end = i
			continue
		}
		break
	}

	if new_end > 0 && last_txt.text.value[new_end - 1] == '\n' {
		last_txt.text.value = last_txt.text.value[:new_end]
	}
}
