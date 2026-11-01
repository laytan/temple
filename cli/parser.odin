package temple_cli

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import odin_parser "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"

Parser :: struct {
	lexer:         Lexer,
	allocator:     mem.Allocator,
	template:      Template,
	last_txt_node: Maybe(^Node_Text),
	in_block:      int,
	body_depth:    int,
	seen_macros:   map[string]bool,
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
}

Node_Output :: struct {
	using node: Node,
	open:       Token,
	expression: Token,
	close:      Token,
	write_kind: Output_Write_Kind,
	inner_expr: string,
	fmt_str:    string, // Populated when write_kind is .Fmt_Escaped or .Fmt_Raw
}

Node_If :: struct {
	using node: Node,
	_if:        Node_If_Part,
	elseifs:    [dynamic]^Node_If_Part,
	_else:      Maybe(^Node_If_Part),
	end:        Node_End,
}

Node_Case :: struct {
	open:       Token,
	case_tok:   Token,
	expression: Maybe(Token), // `nil` for default `{% case %}`
	close:      Token,
	body:       [dynamic]Node,
}

Node_Switch :: struct {
	using node: Node,
	open:       Token,
	switch_tok: Token,
	is_partial: bool,         // true for `{% #partial switch ... %}`
	expression: Maybe(Token), // `nil` for blank `{% switch %}`
	close:      Token,
	cases:      [dynamic]^Node_Case,
	end:        Node_End,
}

Node_Let :: struct {
	using node:    Node,
	open:          Token,
	let_tok:       Token,
	assignment:    Token, // e.g., `x = this.count + 1` or `val, ok := this.opt.?`
	has_type_decl: bool,  // true when declared with explicit type e.g. `x: int = 5`
	close:         Token,
}

Embed_Prop :: struct {
	name:     string,
	val_expr: string,
	pos:      Pos,
}

Node_Embed :: struct {
	using node:    Node,
	open:          Token,
	embed:         Token,
	path:          Token,
	resolved_path: string,
	origin_file:   string,
	origin_src:    []byte,
	with:          Maybe(^Node_Embed_With),
	props:         [dynamic]Embed_Prop, // Populated for `{% embed "x.html"(a = 1, b = 2) %}`
	close:         Token,
}

Node_Embed_With :: struct {
	with: Token,
	expr: Token,
}

Node_Extends :: struct {
	using node: Node,
	open:       Token,
	extends:    Token,
	path:       Token,
	close:      Token,
}

Node_Block :: struct {
	using node:  Node,
	open:        Token,
	block:       Token,
	name_tok:    Token,
	name:        string,
	origin_file: string,
	origin_src:  []byte,
	close:       Token,
	body:        [dynamic]Node,
	end:         Node_End,
}

Node_Super :: struct {
	using node:  Node,
	open:        Token,
	super_tok:   Token,
	origin_file: string,
	origin_src:  []byte,
	close:       Token,
}

Node_Macro :: struct {
	using node:  Node,
	open:        Token,
	macro_tok:   Token,
	signature:   Token,
	name:        string,
	params_src:  string,
	origin_file: string,
	origin_src:  []byte,
	close:       Token,
	body:        [dynamic]Node,
	end:         Node_End,
}

Node_Call :: struct {
	using node: Node,
	open:       Token,
	call_tok:   Token,
	call_expr:  Token,
	name:       string,
	args_src:   string,
	close:      Token,
}

Node_If_Part :: struct {
	start: struct {
		open:  Token,
		type:  Token,
		expr:  Maybe(Token), // Set if type is .If or .ElseIf, not with .Else.
		close: Token,
	},
	body:  [dynamic]Node,
}

Node_For :: struct {
	using node: Node,
	start:      struct {
		open:       Token,
		_for:       Token,
		expression: Token,
		close:      Token,
	},
	body:       [dynamic]Node,
	end:        Node_End,
}

Node_End :: struct {
	open:  Token,
	end:   Token,
	close: Token,
}

parser_init_bytes :: proc(p: ^Parser, source: []byte, allocator := context.allocator) {
	lexer_init(&p.lexer, source)

	p.allocator = allocator
	p.template.content = make([dynamic]Node, allocator)
	p.seen_macros = make(map[string]bool, allocator)
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

parse :: proc(p: ^Parser) -> Template {
	parse_loop: for {
		t := lexer_next(&p.lexer)

		switch t.type {
		case .Output_Open:
			if out, ok := parse_output(p, t); ok {
				append(&p.template.content, out)
			} else {
				break parse_loop
			}

		case .Text:
			append(&p.template.content, parse_text(p, t))

		case .Process_Open:
			if out, ok := parse_process(p, t); ok {
				append(&p.template.content, out)
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

	t := new(Node_Output, p.allocator)
	t.derived = t
	t.open = open_token
	t.expression = expr_tok
	t.close = close_tok

	is_super := validate_and_classify_output_expr(p, t) or_return
	if is_super {
		if p.in_block <= 0 {
			error(p, open_token.pos, "\"super()\" can only be used inside a \"block\" tag") or_return
		}
		sup := new(Node_Super, p.allocator)
		sup.derived = sup
		sup.open = open_token
		sup.super_tok = expr_tok
		sup.close = close_tok
		return sup, true
	}

	return t, true
}

parse_text :: proc(p: ^Parser, text_token: Token) -> ^Node_Text {
	t := new(Node_Text, p.allocator)
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

	t = new(Node_Let, p.allocator)
	t.derived = t
	t.open = process
	t.let_tok = process_type

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
	t.close = lexer_next(&p.lexer)
	if t.close.type != .Process_Close {
		error(
			p,
			t.close.pos,
			"invalid token following `let` assignment, expected \"%%}\", got: %q",
			t.close.value,
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
	t = new(Node_Switch, p.allocator)
	t.derived = t
	t.open = process
	t.switch_tok = process_type
	t.is_partial = is_partial
	t.cases.allocator = p.allocator

	next := lexer_next(&p.lexer)
	if next.type == .Text {
		if len(strings.trim_space(next.value)) > 0 {
			validate_switch_header_expr(p, next, is_partial) or_return
			t.expression = next
		}
		t.close = lexer_next(&p.lexer)
	} else {
		t.close = next
	}

	if t.close.type != .Process_Close {
		error(
			p,
			t.close.pos,
			"invalid token in \"switch\" tag, expected \"%%}\", got: %q",
			t.close.value,
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
		c := new(Node_Case, p.allocator)
		c.open = stmt_open
		c.case_tok = stmt_type
		c.body.allocator = p.allocator

		case_next := lexer_next(&p.lexer)
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
			c.close = lexer_next(&p.lexer)
		} else {
			if has_default {
				error(p, stmt_open.pos, "duplicate default `{{%% case %%}}` in `switch` block") or_return
			}
			has_default = true
			c.close = case_next
		}

		if c.close.type != .Process_Close {
			error(
				p,
				c.close.pos,
				"invalid token in \"case\" tag, expected \"%%}\", got: %q",
				c.close.value,
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

	t.end.open = stmt_open
	t.end.end = stmt_type
	t.end.close = lexer_next(&p.lexer)
	if t.end.close.type != .Process_Close {
		error(
			p,
			t.end.close.pos,
			"invalid token after \"end\", expected \"%%}\", got: %q",
			t.end.close.value,
		) or_return
	}

	ok = true
	return
}

parse_if :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_If, ok: bool) {
	assert(process_type.type == .If)
	open_pos := process.pos
	process, process_type := process, process_type

	t = new(Node_If, p.allocator)
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

		if_part.start.close = lexer_next(&p.lexer)
		if if_part.start.close.type != .Process_Close {
			error(
				p,
				if_part.start.close.pos,
				"invalid token, expected \"%%}\", got: %q",
				if_part.start.close.value,
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
		part := new(Node_If_Part, p.allocator)
		part.body.allocator = p.allocator
		process, process_type = parse_if_part(p, part, process, process_type, open_pos) or_return
		append(&t.elseifs, part)
	}

	#partial switch process_type.type {
	case .Else:
		part := new(Node_If_Part, p.allocator)
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

	t.end.open = process
	t.end.end = process_type
	t.end.close = lexer_next(&p.lexer)
	if t.end.close.type != .Process_Close {
		error(p, t.end.close.pos, "invalid token after \"end\", expected \"%%}\", got: %q", t.end.close.value) or_return
	}

	ok = true
	return
}

parse_for :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_For, ok: bool) {
	assert(process_type.type == .For)

	t = new(Node_For, p.allocator)
	t.derived = t
	t.body.allocator = p.allocator

	t.start.open = process
	t.start._for = process_type

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

	t.start.close = lexer_next(&p.lexer)
	if t.start.close.type != .Process_Close {
		error(
			p,
			t.start.close.pos,
			"invalid token following the for expression %q, expected \"%%}\", got: %q",
			t.start.expression.value,
			t.start.close.value,
		) or_return
	}

	t.end.open, t.end.end = parse_body(
		p,
		&t.body,
		proc(t: Token) -> bool { return t.type == .End },
		"for",
		process.pos,
	) or_return

	t.end.close = lexer_next(&p.lexer)
	if t.end.close.type != .Process_Close {
		error(
			p,
			t.end.end.pos,
			"invalid token following the \"{{%% end\", expected \"%%}\", got: %q",
			t.end.end.value,
		) or_return
	}

	ok = true
	return
}

parse_block :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Block, ok: bool) {
	assert(process_type.type == .Block)

	t = new(Node_Block, p.allocator)
	t.derived = t
	t.body.allocator = p.allocator
	t.open = process
	t.block = process_type

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

	t.close = lexer_next(&p.lexer)
	if t.close.type != .Process_Close {
		error(
			p,
			t.close.pos,
			"invalid token following block name %q, expected \"%%}\", got: %q",
			name,
			t.close.value,
		) or_return
	}

	p.in_block += 1
	defer p.in_block -= 1

	t.end.open, t.end.end = parse_body(
		p,
		&t.body,
		proc(t: Token) -> bool { return t.type == .End },
		"block",
		process.pos,
	) or_return

	t.end.close = lexer_next(&p.lexer)
	if t.end.close.type != .Process_Close {
		error(
			p,
			t.end.close.pos,
			"invalid token after \"end\", expected \"%%}\", got: %q",
			t.end.close.value,
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

	t = new(Node_Extends, p.allocator)
	t.derived = t
	t.open = process
	t.extends = process_type

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

	t.close = lexer_next(&p.lexer)
	if t.close.type != .Process_Close {
		error(p, t.close.pos, "invalid token after extends path, expected \"%%}\", got: %q", t.close.value) or_return
	}

	ok = true
	return
}

parse_super :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Super, ok: bool) {
	assert(process_type.type == .Super)

	if p.in_block <= 0 {
		error(p, process.pos, "\"super\" can only be used inside a \"block\" tag") or_return
	}

	t = new(Node_Super, p.allocator)
	t.derived = t
	t.open = process
	t.super_tok = process_type

	t.close = lexer_next(&p.lexer)
	if t.close.type != .Process_Close {
		error(p, t.close.pos, "invalid token after \"super\", expected \"%%}\", got: %q", t.close.value) or_return
	}

	ok = true
	return
}

parse_macro :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Macro, ok: bool) {
	assert(process_type.type == .Macro)

	if p.body_depth > 0 {
		error(p, process.pos, "\"macro\" must be declared at the top level of a template") or_return
	}

	t = new(Node_Macro, p.allocator)
	t.derived = t
	t.body.allocator = p.allocator
	t.open = process
	t.macro_tok = process_type

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
	t.close = lexer_next(&p.lexer)
	if t.close.type != .Process_Close {
		error(
			p,
			t.close.pos,
			"invalid token following macro signature %q, expected \"%%}\", got: %q",
			t.name,
			t.close.value,
		) or_return
	}

	prev_in_block := p.in_block
	p.in_block = 0
	defer p.in_block = prev_in_block

	t.end.open, t.end.end = parse_body(
		p,
		&t.body,
		proc(tok: Token) -> bool { return tok.type == .End },
		"macro",
		process.pos,
	) or_return

	t.end.close = lexer_next(&p.lexer)
	if t.end.close.type != .Process_Close {
		error(
			p,
			t.end.close.pos,
			"invalid token after \"end\", expected \"%%}\", got: %q",
			t.end.close.value,
		) or_return
	}

	ok = true
	return
}

parse_call :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Call, ok: bool) {
	assert(process_type.type == .Call)

	t = new(Node_Call, p.allocator)
	t.derived = t
	t.open = process
	t.call_tok = process_type

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
	t.close = lexer_next(&p.lexer)
	if t.close.type != .Process_Close {
		error(
			p,
			t.close.pos,
			"invalid token following \"call\" expression, expected \"%%}\", got: %q",
			t.close.value,
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
	init_odin_snippet_parser(&op, &file, synthetic, false)

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

	if p.seen_macros[name] {
		return error(p, name_pos, "duplicate macro definition %q in template", name)
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

	if proc_type.params != nil {
		seen_params := make(map[string]bool, p.allocator)
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

			for name_expr in field.names {
				rel_name_offset := open_paren + max(name_expr.pos.offset - len(prefix), 0)
				param_pos := advance_pos_by_offset(tok.pos, raw_src, rel_name_offset)
				ident, is_ident := name_expr.derived_expr.(^ast.Ident)
				if !is_ident {
					return error(p, param_pos, "invalid parameter name in macro %q", name)
				}
				if seen_params[ident.name] {
					return error(p, param_pos, "duplicate parameter %q in macro %q", ident.name, name)
				}
				seen_params[ident.name] = true
			}
		}
	}

	p.seen_macros[name] = true
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
validate_call_expr :: proc(p: ^Parser, tok: Token, out_node: ^Node_Call) -> bool {
	raw_src := strings.trim_right_space(tok.value)
	context.allocator = p.allocator

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
	inner_args := raw_src[call.open.offset + 1 : call.close.offset]
	out_node.args_src = strip_trailing_comma_and_comments(inner_args)
	return true
}

@(private = "file")
strip_trailing_comma_and_comments :: proc(s: string) -> string {
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
			append(container, parse_output(p, tok) or_return)

		case .Text:
			append(container, parse_text(p, tok))

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

			append(container, parse_process(p, tok, process_type) or_return)

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

	t = new(Node_Embed, p.allocator)
	t.derived = t
	t.props.allocator = p.allocator

	t.open  = process
	t.embed = process_type

	t.path = lexer_next(&p.lexer)
	if t.path.type != .Embed_Path || len(t.path.value) < 2 || t.path.value[len(t.path.value)-1] != '"' {
		error(p, t.path.pos, "invalid token after \"embed\", expected a double quoted string pointing at a template file, got: %q", t.path.value) or_return
	}

	if len(t.path.value) <= 2 {
		error(p, t.path.pos, "invalid embed path, expected at least 3 characters, got: %q", t.path.value) or_return
	}

	next := lexer_next(&p.lexer)
	if next.type == .Embed_With {
		with := new(Node_Embed_With, p.allocator)
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

		t.close = lexer_next(&p.lexer)
		if t.close.type != .Process_Close {
			error(p, t.close.pos, "invalid token after with expression, expected \"%%}\", got: %q", t.close.value) or_return
		}
	} else if next.type == .Text {
		// Support direct call-style `{% embed "card.html"(title = this.title, active = true) %}`
		trimmed := strings.trim_space(next.value)
		if !strings.has_prefix(trimmed, "(") {
			error(p, next.pos, "invalid token after embed path, expected \"with\", \"(props...)\", or \"%%}\", got: %q", next.value) or_return
		}
		parse_embed_props_expr(p, next, &t.props) or_return

		t.close = lexer_next(&p.lexer)
		if t.close.type != .Process_Close {
			error(p, t.close.pos, "invalid token after embed props, expected \"%%}\", got: %q", t.close.value) or_return
		}
	} else if next.type == .Process_Close {
		t.close = next
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
parse_embed_props_expr :: proc(p: ^Parser, tok: Token, out_props: ^[dynamic]Embed_Prop) -> bool {
	raw_src := strings.trim_right_space(tok.value)
	context.allocator = p.allocator

	prefix :: "__component"
	expr, synthetic := parse_prefixed_odin_expr(p, tok, raw_src, prefix, "embed props") or_return

	call, is_call := expr.derived_expr.(^ast.Call_Expr)
	if !is_call || len(call.args) == 0 {
		return error(p, tok.pos, "embed props list cannot be empty; pass at least one prop or omit parentheses")
	}

	seen_names := make(map[string]bool, p.allocator)

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

		if seen_names[prop_name] {
			return error(p, arg_pos, "duplicate prop %q in embed tag", prop_name)
		}
		seen_names[prop_name] = true

		append(out_props, Embed_Prop{
			name     = prop_name,
			val_expr = val_str,
			pos      = arg_pos,
		})
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
init_odin_snippet_parser :: proc(op: ^odin_parser.Parser, file: ^ast.File, src: string, insert_semicolon := true) {
	NO_POS :: tokenizer.Pos{}
	op^ = odin_parser.default_parser()
	op.err = odin_silent_err_handler
	op.warn = odin_silent_warn_handler
	file^ = {}
	file.pkg = ast.new(ast.Package, NO_POS, NO_POS)
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
validate_and_classify_output_expr :: proc(p: ^Parser, node: ^Node_Output) -> (is_super: bool, ok: bool) {
	raw_src := node.expression.value
	trimmed := strings.trim_space(raw_src)
	if len(trimmed) == 0 {
		return false, error(p, node.expression.pos, "empty output expression inside \"{{ ... }}\"")
	}

	context.allocator = p.allocator

	op: odin_parser.Parser
	file: ast.File
	init_odin_snippet_parser(&op, &file, raw_src, false)

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
			switch ident.name {
			case "raw":
				node.write_kind = .Fmt_Raw if node.write_kind == .Fmt_Escaped else .Raw_String
				node.inner_expr = effective_lhs
				return false, true
			case "magic":
				node.write_kind = .Magic_String
				node.inner_expr = effective_lhs
				return false, true
			case "url":
				node.write_kind = .Url_String
				node.inner_expr = effective_lhs
				return false, true
			case "url_param":
				node.write_kind = .Url_Param_String
				node.inner_expr = effective_lhs
				return false, true
			case "js", "json":
				node.write_kind = .Js_String
				node.inner_expr = effective_lhs
				return false, true
			case "len":
				node.write_kind = .Int
				node.inner_expr = fmt.aprintf("len(%s)", effective_lhs, allocator = p.allocator)
				return false, true
			case "int", "uint", "i64", "u64", "i128", "u128", "f32", "f64", "byte", "rune":
				node.write_kind = cast_name_to_write_kind(ident.name)
				node.inner_expr = fmt.aprintf("%s(%s)", ident.name, effective_lhs, allocator = p.allocator)
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
					node.inner_expr = fmt.aprintf(
						"__temple_default(%s, %s)",
						effective_lhs,
						fallback_str,
						allocator = p.allocator,
					)
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
				target_kind: Output_Write_Kind
				switch ident.name {
				case "raw":        target_kind = .Raw_String
				case "magic":      target_kind = .Magic_String
				case "url":        target_kind = .Url_String
				case "url_param":  target_kind = .Url_Param_String
				case "js", "json": target_kind = .Js_String
				}
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
				node.inner_expr = fmt.aprintf(
					"__temple_default(%s, %s)",
					val_str,
					fallback_str,
					allocator = p.allocator,
				)
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
				node.write_kind = cast_name_to_write_kind(ident.name)
			}
		}
	}

	return false, true
}

@(private = "file")
cast_name_to_write_kind :: proc(name: string) -> Output_Write_Kind {
	switch name {
	case "byte":       return .Byte
	case "rune":       return .Rune
	case "int", "len": return .Int
	case "uint":       return .Uint
	case "i128":       return .I128
	case "u128":       return .U128
	case "u64":        return .U64
	case "i64":        return .I64
	case "f32":        return .F32
	case "f64":        return .F64
	}
	return .Escaped_String
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

	synthetic: string
	if strings.has_suffix(lhs_trimmed, ":") {
		ident_part := strings.trim_space(lhs_trimmed[:len(lhs_trimmed)-1])
		synthetic = strings.concatenate({ident_part, " :=", rhs_slice}, p.allocator)
	} else if find_top_level_colon(lhs_trimmed) != -1 {
		has_type_decl = true
		synthetic = raw_src
	} else {
		synthetic = strings.concatenate({lhs_slice, ":=", rhs_slice}, p.allocator)
	}

	op: odin_parser.Parser
	file: ast.File
	init_odin_snippet_parser(&op, &file, synthetic)

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

	synthetic := strings.concatenate({prefix, raw_src, suffix}, p.allocator)
	op: odin_parser.Parser
	file: ast.File
	init_odin_snippet_parser(&op, &file, synthetic)

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
	return validate_wrapped_stmt(p, tok, "switch { case ", ": }", "\"case\" expression")
}

@(private = "file")
validate_switch_header_expr :: proc(p: ^Parser, tok: Token, is_partial: bool) -> bool {
	prefix := "#partial switch " if is_partial else "switch "
	return validate_wrapped_stmt(p, tok, prefix, " {}", "\"switch\" expression")
}

@(private = "file")
validate_if_condition_expr :: proc(p: ^Parser, tok: Token, tag_name: string) -> bool {
	if len(strings.trim_space(tok.value)) == 0 {
		return error(p, tok.pos, "missing condition expression after %q", tag_name)
	}
	label := fmt.aprintf("%q condition", tag_name, allocator = p.allocator)
	return validate_wrapped_stmt(p, tok, "if ", " {}", label)
}

@(private = "file")
validate_for_clause_expr :: proc(p: ^Parser, tok: Token) -> bool {
	if len(strings.trim_space(tok.value)) == 0 {
		return error(p, tok.pos, "missing loop clause after \"for\"")
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
	init_odin_snippet_parser(&op, &file, raw_src, false)

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
