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
	lexer:       Lexer,
	allocator:   mem.Allocator,
	template:    Template,
	err_handler: Err_Handler,
	err_count:   int,
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
	start:      struct {
		open:       Token,
		_if:        Token,
		expression: Token,
		close:      Token,
	},
	if_true:    [dynamic]Node,
	end:        Node_End,
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

		case .Output_Close, .Illegal, .Process_Close, .If, .End, .For:
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

	return t
}

// TODO: if the only thing on a line is process tokens, remove the line completely.

parse_process :: proc(p: ^Parser, process: Token, process_type_: Maybe(Token) = nil) -> Node {
	process_type, ok := process_type_.?
	if !ok {
		process_type = lexer_next(&p.lexer)
	}

	switch process_type.type {
	case .If:
		return parse_if(p, process, process_type)
	case .For:
		return parse_for(p, process, process_type)
	case .End, .Process_Close, .Process_Open, .EOF, .Text, .Illegal, .Output_Open, .Output_Close:
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
	t.if_true.allocator = p.allocator

	t.start.open = process
	t.start._if = process_type

	t.start.expression = lexer_next(&p.lexer)
	if t.start.expression.type != .Text {
		error(
			p,
			t.start.expression.pos,
			"invalid token following \"if\", expected an expression to evaluate, got: %q",
			t.start.expression.value,
		)
		return t
	}

	t.start.close = lexer_next(&p.lexer)
	if t.start.close.type != .Process_Close {
		error(
			p,
			t.start.close.pos,
			"invalid token following the if expression %q, expected \"%%}\", got: %q",
			t.start.expression.value,
			t.start.close.value,
		)
		return t
	}

	t.end = parse_body(p, &t.if_true)
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

	t.end = parse_body(p, &t.body)
	return t
}

parse_body :: proc(p: ^Parser, container: ^[dynamic]Node) -> (end: Node_End) {
	parse_loop: for {
		tok := lexer_next(&p.lexer)

		switch tok.type {
		case .Output_Open:
			append(container, parse_output(p, tok))

		case .Text:
			append(container, parse_text(p, tok))

		case .Process_Open:
			process_type := lexer_next(&p.lexer)
			if process_type.type == .End {
				end.open = tok
				end.end = process_type
				break parse_loop
			}

			append(container, parse_process(p, tok, process_type))

		case .EOF:
			error(p, tok.pos, "unexpected EOF while inside a body")
			return end

		case .Output_Close, .Process_Close, .Illegal, .If, .End, .For:
			fallthrough

		case:
			error(p, tok.pos, "invalid token inside body a body: got %q", tok.value)
		}
	}

	end.end = lexer_next(&p.lexer)
	if end.end.type != .Process_Close {
		error(
			p,
			end.end.pos,
			"invalid token following the \"{{%% end\", expected \"%%}\", got: %q",
			end.end.value,
		)
		// Purposefully returning the kinda invalid token because it might have context about the err.
	}
	return
}
