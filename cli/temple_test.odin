package temple_cli

import "core:fmt"

import tst "core:testing"

@(test)
lex_empty :: proc(t: ^tst.T) {
	l: Lexer
	lexer_init(&l, "")

	expect_tokens(t, &l, Token{type = .EOF})
}

@(test)
lex_hello_world :: proc(t: ^tst.T) {
	l: Lexer
	lexer_init(&l, "Hello World!")

	expect_tokens(
		t,
		&l,
		Token{type = .Text, value = "Hello World!"},
		Token{type = .EOF, pos = {col = 12, offset = 12}},
	)
}

@(test)
lex_output :: proc(t: ^tst.T) {
	l: Lexer
	lexer_init(&l, "{{ pp }}")

	expect_tokens(
		t,
		&l,
		Token{type = .Output_Open, value = "{{"},
		Token{type = .Text, value = " pp ", pos = {col = 2, offset = 2}},
		Token{type = .Output_Close, value = "}}", pos = {col = 6, offset = 6}},
		Token{type = .EOF, pos = {col = 8, offset = 8}},
	)
}

@(test)
lex_mixed :: proc(t: ^tst.T) {
	l: Lexer
	lexer_init(&l, `Ya!{{ pp }}
Wowie!`)

	expect_tokens(
		t,
		&l,
		Token{type = .Text, value = "Ya!"},
		Token{type = .Output_Open, value = "{{", pos = {col = 3, offset = 3}},
		Token{type = .Text, value = " pp ", pos = {col = 5, offset = 5}},
		Token{type = .Output_Close, value = "}}", pos = {col = 9, offset = 9}},
		Token{type = .Text, value = "\nWowie!", pos = {line = 0, col = 11, offset = 11}},
		Token{type = .EOF, pos = {line = 1, col = 6, offset = 18}},
	)
}

@(test)
parse_empty :: proc(t: ^tst.T) {
	p: Parser
	parser_init(&p, "")
	template, ok := parse(&p)

	tst.expect(t, ok)
	tst.expect(t, len(template.content) == 0, "expected 0 nodes in template")
}

@(test)
parse_hello_world :: proc(t: ^tst.T) {
	p: Parser
	parser_init(&p, "Hello, World!")
	template, ok := parse(&p)

	tst.expect(t, ok)
	tst.expect(t, len(template.content) == 1, "expected 1 node in template")

	n := template.content[0]
	nn, nok := n.derived.(^Node_Text)

	tst.expect(t, nok, fmt.tprintf("expected Node_Text, got %T", n.derived))
	tst.expect_value(t, nn.text.value, "Hello, World!")
}

@(test)
parse_mixed :: proc(t: ^tst.T) {
	p: Parser
	parser_init(&p, `Ya!{{ pp }}
Wowie!`)
	template, ok := parse(&p)

	tst.expect(t, ok)
	tst.expect(t, len(template.content) == 3, "expected 3 nodes in template")

	one := template.content[0]
	onet, oneok := one.derived.(^Node_Text)
	tst.expect(t, oneok, "expected first node to be Text")
	tst.expect_value(t, onet.text.value, "Ya!")

	two := template.content[1]
	twot, twook := two.derived.(^Node_Output)
	tst.expect(t, twook, "expected second node to be Output")
	tst.expect_value(t, twot.open.value, "{{")
	tst.expect_value(t, twot.expression.value, " pp ")
	tst.expect_value(t, twot.close.value, "}}")

	three := template.content[2]
	threet, threeok := three.derived.(^Node_Text)
	tst.expect(t, threeok, "expected third node to be Text")
	tst.expect_value(t, threet.text.value, "\nWowie!")
}

@(test)
transpile_mixed :: proc(t: ^tst.T) {
	p: Parser
	parser_init(&p, `Ya!{{ this.pp }}
Wowie!`)
	template, ok := parse(&p)
	tst.expect(t, ok)

	Ctx :: struct {
		pp: string,
	}
	out := transpile("foo", Ctx, template)

	tst.expect_value(
		t,
		out,
		`	when path == "foo" {
		return proc(w: io.Writer, this: T) {
			io.write_string(w, "Ya!")
			io.write_string(w, this.pp)
			io.write_string(w, "\nWowie!")
		}
	}`,
	)
}

expect_tokens :: proc(t: ^tst.T, l: ^Lexer, toks: ..Token, loc := #caller_location) {
	for tok in toks {
		got := lexer_next(l)
		tst.expect_value(t, got, tok, loc)
	}
}
