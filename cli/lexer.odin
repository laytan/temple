package temple_cli

import "core:strings"

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
	For,
	Else,
	ElseIf,
	Switch,
	Partial_Switch,
	Case,
	Let,
	Embed,
	Embed_Path,
	Embed_With,
	Extends,
	Block,
	Super,
	Macro,
	Call,
	End,
}

Lexer :: struct {
	source:          []byte,
	// The character before `ch` in the source.
	prev_ch:         byte,
	// The token that was last returned.
	prev_token:      Token,
	// The current character to check.
	ch:              byte,
	// The index into the source that `ch` is at.
	cursor:          int,
	// The amount of newline characters we have come across, aka the current line.
	line:            int,
	// The offset that the current line begins on.
	bol:             int,
	// Whether we are currently inside `{{ ... }}` or `{% ... %}`.
	in_tag:          bool,
	// Set when `-}}` or `-%}` is consumed so the next `.Text` token strips leading whitespace.
	trim_leading_ws: bool,
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
	for {
		// If we are outside a tag and `trim_leading_ws` was set by `-}}` or `-%}`,
		// skip all ASCII whitespace before the next token or tag.
		if !l.in_tag && l.trim_leading_ws {
			lexer_skip_all_whitespace(l)
			l.trim_leading_ws = false
		}

		t = {}
		t.pos = lexer_pos(l)

		switch {
		case l.ch == EOF:
			t.type = .EOF

		case !l.in_tag && ((l.ch == '{' && lexer_peek(l) == '#') || (l.ch == '{' && lexer_peek(l) == '-' && lexer_peek(l, 2) == '#')):
			// Comment tag: `{# ... #}`, `{#- ... -#}`, or `{-# ... #-}`
			open_pos := t.pos
			start_offset := l.cursor
			if lexer_peek(l) == '-' {
				_ = lexer_consume(l, "{-#")
			} else if lexer_peek(l, 2) == '-' {
				_ = lexer_consume(l, "{#-")
			} else {
				_ = lexer_consume(l, "{#")
			}
			closed := false
			for l.ch != EOF {
				if l.ch == '-' && lexer_peek(l) == '#' && lexer_peek(l, 2) == '}' {
					_ = lexer_consume(l, "-#}")
					l.trim_leading_ws = true
					closed = true
					break
				}
				if l.ch == '#' && lexer_peek(l) == '-' && lexer_peek(l, 2) == '}' {
					_ = lexer_consume(l, "#-}")
					l.trim_leading_ws = true
					closed = true
					break
				}
				if l.ch == '#' && lexer_peek(l) == '}' {
					_ = lexer_consume(l, "#}")
					closed = true
					break
				}
				lexer_read(l)
			}
			if !closed {
				t.pos = open_pos
				t.type = .Illegal
				t.value = string(l.source[start_offset:])
				l.prev_token = t
				return
			}
			continue

		case l.ch == '{' && lexer_peek(l) == '{':
			t.type = .Output_Open
			l.in_tag = true
			if lexer_peek(l, 2) == '-' && is_space_or_close(lexer_peek(l, 3)) {
				t.value = lexer_consume(l, "{{-")
				lexer_skip_all_whitespace(l)
			} else {
				t.value = lexer_consume(l, "{{")
			}

		case l.ch == '-' && lexer_peek(l) == '}' && lexer_peek(l, 2) == '}' && l.in_tag:
			t.type  = .Output_Close
			t.value = lexer_consume(l, "-}}")
			l.in_tag = false
			l.trim_leading_ws = true

		case l.ch == '}' && lexer_peek(l) == '}' && l.in_tag:
			t.type  = .Output_Close
			t.value = lexer_consume(l, "}}")
			l.in_tag = false

		case l.ch == '{' && lexer_peek(l) == '%':
			t.type = .Process_Open
			l.in_tag = true
			if lexer_peek(l, 2) == '-' {
				t.value = lexer_consume(l, "{%-")
			} else {
				t.value = lexer_consume(l, "{%")
			}
			lexer_skip_all_whitespace(l)

		case l.ch == '-' && lexer_peek(l) == '%' && lexer_peek(l, 2) == '}' && l.in_tag:
			t.type  = .Process_Close
			t.value = lexer_consume(l, "-%}")
			l.in_tag = false
			l.trim_leading_ws = true

		case l.ch == '%' && lexer_peek(l) == '}' && l.in_tag:
			t.type  = .Process_Close
			t.value = lexer_consume(l, "%}")
			l.in_tag = false

		case l.prev_token.type == .Process_Open:
			switch {
			case lexer_match_keyword(l, "if", false):
				t.type  = .If
				t.value = lexer_consume(l, "if")

			case lexer_match_keyword(l, "end", true):
				t.type  = .End
				t.value = lexer_consume(l, "end")
				lexer_skip_all_whitespace(l)

			case lexer_match_keyword(l, "for", false):
				t.type  = .For
				t.value = lexer_consume(l, "for")

			case lexer_match_keyword(l, "elseif", false):
				t.type  = .ElseIf
				t.value = lexer_consume(l, "elseif")

			case lexer_match_compound_keyword(l, "else", "if"):
				t.type = .ElseIf
				start := l.cursor
				_ = lexer_consume(l, "else")
				lexer_skip_all_whitespace(l)
				_ = lexer_consume(l, "if")
				t.value = string(l.source[start:l.cursor])

			case lexer_match_keyword(l, "else", true):
				t.type  = .Else
				t.value = lexer_consume(l, "else")
				lexer_skip_all_whitespace(l)

			case lexer_match_keyword(l, "switch", true):
				t.type  = .Switch
				t.value = lexer_consume(l, "switch")
				lexer_skip_all_whitespace(l)

			case lexer_match_compound_keyword(l, "#partial", "switch"):
				t.type = .Partial_Switch
				start := l.cursor
				_ = lexer_consume(l, "#partial")
				lexer_skip_all_whitespace(l)
				_ = lexer_consume(l, "switch")
				t.value = string(l.source[start:l.cursor])
				lexer_skip_all_whitespace(l)

			case lexer_match_keyword(l, "case", true):
				t.type  = .Case
				t.value = lexer_consume(l, "case")
				lexer_skip_all_whitespace(l)

			case lexer_match_keyword(l, "let", false):
				t.type  = .Let
				t.value = lexer_consume(l, "let")

			case lexer_match_keyword(l, "embed", false):
				t.type  = .Embed
				t.value = lexer_consume(l, "embed")
				lexer_skip_all_whitespace(l)

			case lexer_match_keyword(l, "extends", false):
				t.type  = .Extends
				t.value = lexer_consume(l, "extends")
				lexer_skip_all_whitespace(l)

			case lexer_match_keyword(l, "block", false):
				t.type  = .Block
				t.value = lexer_consume(l, "block")
				lexer_skip_all_whitespace(l)

			case lexer_match_keyword(l, "super", true):
				t.type  = .Super
				t.value = lexer_consume(l, "super")
				lexer_skip_all_whitespace(l)

			case lexer_match_keyword(l, "macro", true):
				t.type  = .Macro
				t.value = lexer_consume(l, "macro")
				lexer_skip_all_whitespace(l)

			case lexer_match_keyword(l, "call", true):
				t.type  = .Call
				t.value = lexer_consume(l, "call")
				lexer_skip_all_whitespace(l)

			case:
				t.type  = .Illegal
				t.value = lexer_consume_until(l, "-%}", "%}")
			}

		case (l.prev_token.type == .Embed || l.prev_token.type == .Extends) && l.ch == '"':
			t.type = .Embed_Path
			start := l.cursor
			_ = lexer_consume_until(l, "\"")
			if l.ch == EOF {
				t.value = string(l.source[start:])
			} else {
				t.value = string(l.source[start:l.cursor+1])
				lexer_read(l)
				lexer_skip_all_whitespace(l)
			}

		case l.prev_token.type == .Embed_Path && lexer_match_keyword(l, "with", false):
			t.type  = .Embed_With
			t.value = lexer_consume(l, "with")

		case:
			t.type = .Text
			if l.in_tag {
				t.value = lexer_consume_tag_expr(l)
			} else {
				raw := lexer_consume_text_until_tag(l)
				// Lookahead: if the next tag starts with `{{-`, `{%-`, `{#-`, or `{-#`, trim trailing whitespace
				if (l.ch == '{' && lexer_peek(l) == '{' && lexer_peek(l, 2) == '-' && is_space_or_close(lexer_peek(l, 3))) ||
				   (l.ch == '{' && lexer_peek(l) == '%' && lexer_peek(l, 2) == '-') ||
				   (l.ch == '{' && lexer_peek(l) == '#' && lexer_peek(l, 2) == '-') ||
				   (l.ch == '{' && lexer_peek(l) == '-' && lexer_peek(l, 2) == '#') {
					raw = strings.trim_right_space(raw)
					if len(raw) == 0 {
						// Entire text node was trimmed away; loop to scan the opening tag directly.
						continue
					}
				}
				t.value = raw
			}
		}

		l.prev_token = t
		return
	}
}

@(private)
is_space_or_close :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '}' || c == '%'
}

@(private)
lexer_match_keyword :: proc(l: ^Lexer, kw: string, allow_process_close: bool) -> bool {
	if l.ch != kw[0] {
		return false
	}
	for i in 1 ..< len(kw) {
		if lexer_peek(l, i) != kw[i] {
			return false
		}
	}
	after := lexer_peek(l, len(kw))
	if after == ' ' || after == '\t' || after == '\n' || after == '\r' {
		return true
	}
	if allow_process_close {
		if after == '%' && lexer_peek(l, len(kw)+1) == '}' {
			return true
		}
		if after == '-' && lexer_peek(l, len(kw)+1) == '%' && lexer_peek(l, len(kw)+2) == '}' {
			return true
		}
	}
	return false
}

@(private)
is_ws :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private)
lexer_match_compound_keyword :: proc(l: ^Lexer, kw1, kw2: string) -> bool {
	if l.ch != kw1[0] {
		return false
	}
	for i in 1 ..< len(kw1) {
		if lexer_peek(l, i) != kw1[i] {
			return false
		}
	}
	idx := len(kw1)
	if !is_ws(lexer_peek(l, idx)) {
		return false
	}
	for is_ws(lexer_peek(l, idx)) {
		idx += 1
	}
	for i in 0 ..< len(kw2) {
		if lexer_peek(l, idx+i) != kw2[i] {
			return false
		}
	}
	after := lexer_peek(l, idx+len(kw2))
	if is_ws(after) {
		return true
	}
	if after == '%' && lexer_peek(l, idx+len(kw2)+1) == '}' {
		return true
	}
	if after == '-' && lexer_peek(l, idx+len(kw2)+1) == '%' && lexer_peek(l, idx+len(kw2)+2) == '}' {
		return true
	}
	return false
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
lexer_consume_text_until_tag :: proc(l: ^Lexer) -> string {
	start := l.cursor
	src := l.source
	n := len(src)

	for l.ch != EOF {
		// Advance at least 1 character from `start` before checking for a tag opener
		lexer_read(l)
		// Fast-forward through raw HTML text until `{` or EOF
		for l.cursor < n && l.ch != '{' {
			if l.ch == '\n' {
				l.prev_ch = '\n'
				l.cursor += 1
				l.line += 1
				l.bol = l.cursor
				if l.cursor >= n {
					l.ch = EOF
					break
				}
				l.ch = src[l.cursor]
			} else {
				l.prev_ch = l.ch
				l.cursor += 1
				if l.cursor >= n {
					l.ch = EOF
					break
				}
				l.ch = src[l.cursor]
			}
		}
		if l.ch == '{' {
			next_b := lexer_peek(l, 1)
			if next_b == '{' || next_b == '%' || next_b == '#' || (next_b == '-' && lexer_peek(l, 2) == '#') {
				return string(src[start:l.cursor])
			}
		}
	}

	return string(src[start:])
}

@(private)
lexer_consume_until :: proc(l: ^Lexer, terminators: ..string) -> string {
	start := l.cursor
	for l.ch != EOF {
		lexer_read(l)

		checks: for terminator in terminators {
			if l.ch != terminator[0] {
				continue checks
			}
			for i in 1 ..< len(terminator) {
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
lexer_consume_tag_expr :: proc(l: ^Lexer) -> string {
	start := l.cursor
	src := l.source
	n := len(src)
	in_quote: byte = 0

	for l.ch != EOF {
		if in_quote != 0 {
			if l.ch == '\\' && (in_quote == '"' || in_quote == '\'') {
				lexer_read(l)
				if l.ch != EOF {
					lexer_read(l)
				}
				continue
			}
			if l.ch == in_quote {
				in_quote = 0
			}
			lexer_read(l)
			continue
		}

		// Fast-forward unquoted expression characters that cannot close a tag or start a quote
		for l.cursor < n {
			c := l.ch
			if c == '"' || c == '`' || c == '\'' || c == '-' || c == '}' || c == '%' || c == '\n' {
				break
			}
			l.prev_ch = c
			l.cursor += 1
			if l.cursor >= n {
				l.ch = EOF
				return string(src[start:])
			}
			l.ch = src[l.cursor]
		}

		switch l.ch {
		case '"', '`', '\'':
			in_quote = l.ch
			lexer_read(l)
			continue
		case '-':
			next_b := lexer_peek(l, 1)
			if (next_b == '}' || next_b == '%') && lexer_peek(l, 2) == '}' {
				return string(src[start:l.cursor])
			}
		case '}', '%':
			if lexer_peek(l, 1) == '}' {
				return string(src[start:l.cursor])
			}
		}

		lexer_read(l)
	}

	return string(src[start:])
}

@(private)
lexer_peek :: proc(l: ^Lexer, offset: int = 1) -> byte {
	if l.cursor == -1 {
		return EOF
	}
	if l.cursor + offset >= len(l.source) {
		return EOF
	}
	return l.source[l.cursor + offset]
}

lexer_skip_spaces :: proc(l: ^Lexer) {
	src := l.source
	n := len(src)
	for l.cursor < n && (l.ch == ' ' || l.ch == '\t') {
		l.prev_ch = l.ch
		l.cursor += 1
		if l.cursor >= n {
			l.ch = EOF
			return
		}
		l.ch = src[l.cursor]
	}
}

lexer_skip_all_whitespace :: proc(l: ^Lexer) {
	src := l.source
	n := len(src)
	for l.cursor < n {
		c := l.ch
		if c == ' ' || c == '\t' || c == '\r' {
			l.prev_ch = c
			l.cursor += 1
			if l.cursor >= n {
				l.ch = EOF
				return
			}
			l.ch = src[l.cursor]
		} else if c == '\n' {
			l.prev_ch = '\n'
			l.cursor += 1
			l.line += 1
			l.bol = l.cursor
			if l.cursor >= n {
				l.ch = EOF
				return
			}
			l.ch = src[l.cursor]
		} else {
			return
		}
	}
}
