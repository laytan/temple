package temple_cli

import "core:fmt"
import "core:mem"

Parser :: struct {
	lexer:         Lexer,
	allocator:     mem.Allocator,
	template:      Template,
	last_txt_node: Maybe(^Node_Text),
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
	^Node_Embed,
}

Node_Text :: struct {
	using node: Node,
	text:       Token,
}

Node_Output :: struct {
	using node: Node,
	open:       Token,
	expression: Token,
	close:      Token,
}

Node_If :: struct {
	using node: Node,
	_if:        Node_If_Part,
	elseifs:    [dynamic]^Node_If_Part,
	_else:      Maybe(^Node_If_Part),
	end:        Node_End,
}

Node_Embed :: struct {
	using node: Node,
	open:       Token,
	embed:      Token,
	path:       Token,
	with:       Maybe(^Node_Embed_With),
	close:      Token,
}

Node_Embed_With :: struct {
	with: Token,
	expr: Token,
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
}

parser_init_str :: proc(p: ^Parser, source: string, allocator := context.allocator) {
	parser_init_bytes(p, transmute([]byte)source)
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

		case .Output_Close, .Illegal, .Process_Close, .If, .End, .For, .Else, .ElseIf, .Embed_With, .Embed_Path, .Embed:
			fallthrough

		case:
			_ = error(p, t.pos, "invalid top level token: %q with content %q", t.type, t.value)
			break parse_loop
		}
	}
	
	return p.template
}

parse_output :: proc(p: ^Parser, open_token: Token) -> (t: ^Node_Output, ok: bool) {
	t = new(Node_Output, p.allocator)
	t.derived = t
	t.open = open_token

	t.expression = lexer_next(&p.lexer)
	if t.expression.type != .Text {
		error(
			p,
			t.expression.pos,
			"invalid token following \"{{\", expected an expression, got: %q",
			t.expression.value,
		) or_return
	}

	t.close = lexer_next(&p.lexer)
	if t.close.type != .Output_Close {
		error(
			p,
			t.close.pos,
			"invalid token following output expression, expected \"}}\", got: %q",
			t.close.value,
		) or_return
	}
	
	ok = true
	return
}

parse_text :: proc(p: ^Parser, text_token: Token) -> ^Node_Text {
	t := new(Node_Text, p.allocator)
	t.derived = t

	t.text = text_token
	
	p.last_txt_node = t
	return t
}

parse_process :: proc(p: ^Parser, process: Token, process_type_: Maybe(Token) = nil) -> (n: Node, ok: bool) {
	parser_maybe_remove_whitespace(p, process)

	process_type, tok := process_type_.?
	if !tok {
		process_type = lexer_next(&p.lexer)
	}

	switch process_type.type {
	case .If:
		return parse_if(p, process, process_type)
	case .For:
		return parse_for(p, process, process_type)
	case .Embed:
		return parse_embed(p, process, process_type)
	case .End, .Process_Close, .Process_Open, .EOF, .Text, .Illegal, .Output_Open, .Output_Close, .Else, .ElseIf, .Embed_Path, .Embed_With:
		fallthrough
	case:
		error(
			p,
			process_type.pos,
			"invalid process type token, expected \"if\", \"for\" or \"embed\", got: %q",
			process_type.value,
		) or_return
	}
	
	ok = true
	return
}

parse_if :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_If, ok: bool) {
	assert(process_type.type == .If)

	t = new(Node_If, p.allocator)
	t.derived = t
	t._if.body.allocator = p.allocator
	t.elseifs.allocator  = p.allocator

	parse_if_part :: proc(p: ^Parser, if_part: ^Node_If_Part, process: Token, process_type: Token) -> (end_open: Token, end_type: Token, ok: bool) {
		parser_maybe_remove_whitespace(p, process)

		if_part.start.open = process
		if_part.start.type = process_type

		if process_type.type == .If || process_type.type == .ElseIf {
			expr := lexer_next(&p.lexer)
			if expr.type != .Text {
				error(
					p,
					expr.pos,
					"invalid token following %q, expected an expression to evaluate, got: %q",
					if_part.start.type.value,
					expr.value,
				) or_return
			}
			
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

		end_open, end_type = parse_body(p, &if_part.body, is_else_end if if_part.start.type.type == .Else else is_if_elseif_end) or_return
		ok = true
		return
	}

	process, process_type := parse_if_part(p, &t._if, process, process_type) or_return
	for process_type.type == .ElseIf {
		part := new(Node_If_Part, p.allocator)
		part.body.allocator = p.allocator
		process, process_type = parse_if_part(p, part, process, process_type) or_return
		append(&t.elseifs, part)
	}

	#partial switch process_type.type {
	case .Else:
		part := new(Node_If_Part, p.allocator)	
		part.body.allocator = p.allocator
		process, process_type = parse_if_part(p, part, process, process_type) or_return
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

	t.end.open, t.end.end = parse_body(p, &t.body, proc(t: Token) -> bool {return t.type == .End}) or_return

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

parse_body :: proc(
	p: ^Parser,
	container: ^[dynamic]Node,
	is_end: proc(t: Token) -> bool,
) -> (
	end_open: Token,
	end_process: Token,
	ok: bool,
) {
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

			append(container, parse_process(p, tok, process_type) or_return)

		case .EOF:
			error(p, tok.pos, "unexpected EOF while inside a body") or_return

		case .Output_Close, .Process_Close, .Illegal, .If, .End, .For, .Else, .ElseIf, .Embed_With, .Embed_Path, .Embed:
			fallthrough

		case:
			error(p, tok.pos, "invalid token inside a body: got %q", tok.value) or_return
		}
	}
}

parse_embed :: proc(p: ^Parser, process: Token, process_type: Token) -> (t: ^Node_Embed, ok: bool) {
	assert(process_type.type == .Embed)

	t = new(Node_Embed, p.allocator)
	t.derived = t

	t.open  = process
	t.embed = process_type
	
	t.path = lexer_next(&p.lexer)
	if t.path.type != .Embed_Path {
		error(p, t.path.pos, "invalid token after \"embed\", expected a double quoted string pointing at a template file, got: %q", t.path.value) or_return
	}
	
	if len(t.path.value) <= 2 {
		error(p, t.path.pos, "invalid embed path, expected at least 3 characters, got: %q", t.path.value) or_return
	}

	next := lexer_next(&p.lexer)
	#partial switch next.type {
	case .Embed_With:
		with := new(Node_Embed_With, p.allocator)

		with.with = next
		with.expr = lexer_next(&p.lexer)
		if with.expr.type != .Text {
			error(p, with.expr.pos, "invalid token after \"with\", expected an expression, got: %q", with.expr.value) or_return
		}

		t.with = with

		t.close = lexer_next(&p.lexer)
		if t.close.type != .Process_Close {
			error(p, t.close.pos, "invalid token after with expression, expected \"%%}\", got: %q", t.close.value) or_return
		}

	case .Process_Close:
		t.close = next

	case:
		error(p, next.pos, "invalid token after embed path, expected \"with\" or \"%%}\", got: %q", next.value) or_return
	}

	ok = true
	return
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

	new_end: int
	#reverse for c, i in transmute([]byte)last_txt.text.value {
		new_end = i
		switch c {
		case ' ', '\t':
			continue
		}
		break
	}

	last_txt.text.value = last_txt.text.value[0:new_end]
}
