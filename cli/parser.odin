package temple_cli

import "core:fmt"
import "core:mem"

Err_Handler :: #type proc(pos: Pos, fmt: string, args: ..any)

// TODO: show file path

default_error_handler :: proc(pos: Pos, msg: string, args: ..any) {
	fmt.eprintf("(%d:%d): ", pos.line + 1, pos.col + 1)
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
}

Parser :: struct {
	lexer:         Lexer,
	allocator:     mem.Allocator,
	template:      Template,
	err_handler:   Err_Handler,
	err_count:     int,
	last_txt_node: Maybe(^Node_Text),
}

Template :: struct {
	content: [dynamic]Node,
}

Node :: struct {
	derived: Any_Node,
}

Any_Node :: union {
	^Node_Text,
	^Node_Output,
	^Node_If,
	^Node_For,
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
	p.err_handler = default_error_handler
}

parser_init_str :: proc(p: ^Parser, source: string, allocator := context.allocator) {
	parser_init_bytes(p, transmute([]byte)source)
}

parser_init :: proc {
	parser_init_bytes,
	parser_init_str,
}

@(private = "file")
error :: proc(p: ^Parser, pos: Pos, msg: string, args: ..any) {
	p.err_count += 1
	if p.err_handler != nil {
		p.err_handler(pos, msg, ..args)
	}
}

parse :: proc(p: ^Parser) -> (Template, bool) {
	parse_loop: for {
		t := lexer_next(&p.lexer)

		switch t.type {
		case .Output_Open:
			append(&p.template.content, parse_output(p, t))

		case .Text:
			append(&p.template.content, parse_text(p, t))

		case .Process_Open:
			append(&p.template.content, parse_process(p, t))

		case .EOF:
			break parse_loop

		case .Output_Close, .Illegal, .Process_Close, .If, .End, .For, .Else, .ElseIf:
			fallthrough

		case:
			error(p, t.pos, "invalid top level token: %q with content %q", t.type, t.value)
		}
	}

	return p.template, p.err_count == 0
}

parse_output :: proc(p: ^Parser, open_token: Token) -> (t: ^Node_Output) {
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
		)
		return t
	}

	t.close = lexer_next(&p.lexer)
	if t.close.type != .Output_Close {
		error(
			p,
			t.close.pos,
			"invalid token following output expression, expected \"}}\", got: %q",
			t.close.value,
		)
		return t
	}

	return t
}

parse_text :: proc(p: ^Parser, text_token: Token) -> ^Node_Text {
	t := new(Node_Text, p.allocator)
	t.derived = t

	t.text = text_token
	
	p.last_txt_node = t
	return t
}

// TODO: if the only thing on a line is process tokens, remove the line completely.

parse_process :: proc(p: ^Parser, process: Token, process_type_: Maybe(Token) = nil) -> Node {
	parser_maybe_remove_whitespace(p, process)

	process_type, ok := process_type_.?
	if !ok {
		process_type = lexer_next(&p.lexer)
	}

	switch process_type.type {
	case .If:
		return parse_if(p, process, process_type)
	case .For:
		return parse_for(p, process, process_type)
	case .End, .Process_Close, .Process_Open, .EOF, .Text, .Illegal, .Output_Open, .Output_Close, .Else, .ElseIf:
		fallthrough
	case:
		error(
			p,
			process_type.pos,
			"invalid process type token, expected \"if\", or \"for\", got: %q",
			process_type.value,
		)

		// NOTE: do we want to return an empty/nil node?
		return {}
	}
}

parse_if :: proc(p: ^Parser, process: Token, process_type: Token) -> ^Node_If {
	assert(process_type.type == .If)

	t := new(Node_If, p.allocator)
	t.derived = t
	t._if.body.allocator = p.allocator
	t.elseifs.allocator  = p.allocator

	parse_if_part :: proc(p: ^Parser, if_part: ^Node_If_Part, process: Token, process_type: Token) -> (end_open: Token, end_type: Token) {
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
				)
				return
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
			)
			return
		}

		is_if_elseif_end :: proc(t: Token) -> bool {
			return t.type == .Else || t.type == .ElseIf || t.type == .End
		}

		is_else_end :: proc(t: Token) -> bool {
			return t.type == .End
		}

		end_open, end_type = parse_body(p, &if_part.body, is_else_end if if_part.start.type.type == .Else else is_if_elseif_end)
		return
	}

	process, process_type := parse_if_part(p, &t._if, process, process_type)
	for process_type.type == .ElseIf {
		part := new(Node_If_Part, p.allocator)
		part.body.allocator = p.allocator
		process, process_type = parse_if_part(p, part, process, process_type)
		append(&t.elseifs, part)
	}

	#partial switch process_type.type {
	case .Else:
		part := new(Node_If_Part, p.allocator)	
		part.body.allocator = p.allocator
		process, process_type = parse_if_part(p, part, process, process_type)
		t._else = part

	case .End:
	case:
		error(p, process_type.pos, "invalid token, expected \"else\" or \"end\", got %q", process_type.value)
	}

	if process_type.type != .End {
		error(p, process_type.pos, "invalid token, expected \"end\", got %q", process_type.value)
		return t
	}

	t.end.open = process
	t.end.end = process_type
	t.end.close = lexer_next(&p.lexer)
	if t.end.close.type != .Process_Close {
		error(p, t.end.close.pos, "invalid token after \"end\", expected \"%%}\", got: %q", t.end.close.value)
	}

	return t
}

parse_for :: proc(p: ^Parser, process: Token, process_type: Token) -> ^Node_For {
	assert(process_type.type == .For)

	t := new(Node_For, p.allocator)
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
		)
		return t
	}

	t.start.close = lexer_next(&p.lexer)
	if t.start.close.type != .Process_Close {
		error(
			p,
			t.start.close.pos,
			"invalid token following the for expression %q, expected \"%%}\", got: %q",
			t.start.expression.value,
			t.start.close.value,
		)
		return t
	}

	t.end.open, t.end.end = parse_body(p, &t.body, proc(t: Token) -> bool {return t.type == .End})

	t.end.close = lexer_next(&p.lexer)
	if t.end.close.type != .Process_Close {
		error(
			p,
			t.end.end.pos,
			"invalid token following the \"{{%% end\", expected \"%%}\", got: %q",
			t.end.end.value,
		)
	}

	return t
}

parse_body :: proc(
	p: ^Parser,
	container: ^[dynamic]Node,
	is_end: proc(t: Token) -> bool,
) -> (
	end_open: Token,
	end_process: Token,
) {
	for {
		tok := lexer_next(&p.lexer)

		switch tok.type {
		case .Output_Open:
			append(container, parse_output(p, tok))

		case .Text:
			append(container, parse_text(p, tok))

		case .Process_Open:
			parser_maybe_remove_whitespace(p, tok)

			process_type := lexer_next(&p.lexer)
			if is_end(process_type) {
				end_open = tok
				end_process = process_type
				return
			}

			append(container, parse_process(p, tok, process_type))

		case .EOF:
			error(p, tok.pos, "unexpected EOF while inside a body")
			return

		case .Output_Close, .Process_Close, .Illegal, .If, .End, .For, .Else, .ElseIf:
			fallthrough

		case:
			error(p, tok.pos, "invalid token inside a body: got %q", tok.value)
		}
	}
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
