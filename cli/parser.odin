package temple_cli

import "core:fmt"
import "core:mem"

Err_Handler :: #type proc(pos: Pos, fmt: string, args: ..any)

default_error_handler :: proc(pos: Pos, msg: string, args: ..any) {
	fmt.eprintf("(%d:%d): ", pos.line, pos.col)
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

@(private="file")
error :: proc(p: ^Parser, pos: Pos, msg: string, args: ..any) {
	p.err_count += 1
	if p.err_handler != nil {
		p.err_handler(pos, msg, args)
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

		case .EOF:
			break parse_loop

		case .Output_Close, .Illegal:
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

	text := lexer_next(&p.lexer)
	#partial switch text.type {
	case .Text:
		t.expression = text
	case .Output_Close:
		error(p, open_token.pos, "invalid empty output node")
		return nil
	case:
		error(
			p,
			text.pos,
			"invalid token following output open token, expected Output_Close, got: %q with content %q",
			text.type,
			text.value,
		)
		return nil
	}

	close := lexer_next(&p.lexer)
	#partial switch close.type {
	case .Output_Close:
		t.close = close
	case:
		error(
			p,
			text.pos,
			"invalid token following Text token, expected Output_Close, got: %q with content %q",
			text.type,
			text.value,
		)
		return nil
	}

	return t
}

parse_text :: proc(p: ^Parser, text_token: Token) -> ^Node_Text {
	t := new(Node_Text, p.allocator)
	t.derived = t

	t.text = text_token

	return t
}
