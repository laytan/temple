package temple_cli

import "core:bufio"
import "core:bytes"
import "core:fmt"
import "core:io"

EOF :: 0

Token :: struct {
	type:  Token_Type,
	value: string,
	pos:   Pos,
}

Pos :: struct {
	line:   int,
	col:    int,
	offset: int,
}

Token_Type :: enum {
	Illegal,
	EOF,
	Text,
	Output_Open,
	Output_Close,
	Process_Open,
	Process_Close,
	If,
	End,
}

Lexer :: struct {
	source:     []byte,
	// The character before `ch` in the source.
	prev_ch:    byte,
	// The token that was last returned.
	prev_token: Token,
	// The current character to check.
	ch:         byte,
	// The index into the source that `ch` is at.
	cursor:     int,
	// The amount of newline characters we have come across, aka the current line.
	line:       int,
	// The offset that the current line begins on.
	bol:        int,
}

lexer_init_bytes :: proc(l: ^Lexer, source: []byte) {
	l.source = source
	l.cursor = -1
	lexer_read(l)
}

lexer_init_str :: proc(l: ^Lexer, source: string) {
	lexer_init_bytes(l, transmute([]byte)source)
}

lexer_init :: proc {
	lexer_init_str,
	lexer_init_bytes,
}

lexer_next :: proc(l: ^Lexer) -> (t: Token) {
	t.pos = lexer_pos(l)

	switch {
	case l.ch == EOF:
		t.type = .EOF

	case l.ch == '{' && lexer_peek(l) == '{':
		t.type  = .Output_Open
		t.value = lexer_consume(l, "{{")

	case l.ch == '}' && lexer_peek(l) == '}':
		t.type  = .Output_Close
		t.value = lexer_consume(l, "}}")

	case l.ch == '{' && lexer_peek(l) == '%':
		t.type  = .Process_Open
		t.value = lexer_consume(l, "{%")
		lexer_skip_spaces(l)

	case l.ch == '%' && lexer_peek(l) == '}':
		t.type  = .Process_Close
		t.value = lexer_consume(l, "%}")

	case l.prev_token.type == .Process_Open:
		switch {
		case l.ch == 'i' && lexer_peek(l) == 'f' && lexer_peek(l, 2) == ' ':
			t.type  = .If
			t.value = lexer_consume(l, "if")
			lexer_skip_spaces(l)

		case l.ch == 'e' && lexer_peek(l) == 'n' && lexer_peek(l, 2) == 'd':
			t.type  = .End
			t.value = lexer_consume(l, "end")
			lexer_skip_spaces(l)

		case:
			t.type  = .Illegal
			start  := l.cursor
			t.value = lexer_consume_until(l, "%}")
		}

	case:
		t.type  = .Text
		start  := l.cursor
		t.value = lexer_consume_until(l, "{{", "}}", "{%", "%}")
	}

	l.prev_token = t
	return
}

@(private)
lexer_read :: proc(l: ^Lexer) {
	l.cursor += 1
	if l.cursor >= len(l.source) {
		l.ch = EOF
		return
	}

	l.prev_ch = l.ch
	l.ch = l.source[l.cursor]

	lexer_check_newline(l)
}

@(private)
lexer_check_newline :: proc(l: ^Lexer) {
	if l.prev_ch != '\n' do return

	l.line += 1
	l.bol = l.cursor
}

@(private)
lexer_pos :: proc(l: ^Lexer) -> (p: Pos) {
	p.line = l.line
	p.col = l.cursor - l.bol
	p.offset = l.cursor
	return
}

@(private)
lexer_consume :: proc(l: ^Lexer, value: string) -> string {
	for i in 0 ..< len(value) {
		assert(l.ch == value[i])
		lexer_read(l)
	}
	return value
}

@(private)
lexer_consume_until :: proc(l: ^Lexer, terminators: ..string) -> string {
	start := l.cursor
	for l.ch != EOF {
		lexer_read(l)

		checks: for terminator in terminators {
			for i in 0 ..< len(terminator) {
				if terminator[i] != lexer_peek(l, i) {
					// No match, check the next.
					continue checks
				}
			}

			// The terminator matched, return.
			return string(l.source[start:l.cursor])
		}
	}

	return string(l.source[start:])
}

@(private)
lexer_peek :: proc(l: ^Lexer, offset: int = 1) -> byte {
	if l.cursor + offset >= len(l.source) {
		return EOF
	}
	return l.source[l.cursor + offset]
}

lexer_skip_spaces :: proc(l: ^Lexer) {
	for l.ch != EOF {
		if l.ch != ' ' do return
		lexer_read(l)
	}
}
