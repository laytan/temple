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
}

Lexer :: struct {
	source:  []byte,
	// The character before `ch` in the source.
	prev_ch: byte,
	// The current character to check.
	ch:      byte,
	// The index into the source that `ch` is at.
	cursor:  int,
	// The amount of newline characters we have come across, aka the current line.
	line:    int,
	// The offset that the current line begins on.
	bol:     int,
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
		t.type = .Output_Open
		t.value = lexer_consume(l, "{{")

	case l.ch == '}' && lexer_peek(l) == '}':
		t.type = .Output_Close
		t.value = lexer_consume(l, "}}")

	case:
		t.type = .Text

		start := l.cursor
		if end, has_end := lexer_consume_until(l, "{{", "}}"); has_end {
			t.value = string(l.source[start:end])
		} else {
			t.value = string(l.source[start:])
		}
	}

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
lexer_consume_until :: proc(l: ^Lexer, terminators: ..string) -> (end: int, has_end: bool) {
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
			end = l.cursor
			has_end = true
			return
		}
	}

	return
}

@(private)
lexer_peek :: proc(l: ^Lexer, offset: int = 1) -> byte {
	if l.cursor + offset >= len(l.source) {
		return EOF
	}
	return l.source[l.cursor + offset]
}
