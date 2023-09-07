package temple_cli

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:reflect"
import "core:strings"

ws :: io.write_string

// Identifiers used in the transpiled output.
PKG_IO  :: "__temple_io"
ARG_W   :: "__temple_w"
RET_N   :: "__temple_n"
RET_ERR :: "__temple_err"

Transpiler :: struct {
	allocator:    mem.Allocator,
	w:            io.Writer,
	indent:       string,
	indented:     int,
	approx_bytes: int,

	embed_parser: Embed_Parser,
	embed_data:   rawptr,
}

Embed_Parser :: #type proc(embed: ^Node_Embed, user_data: rawptr) -> (Template, bool)

indent :: proc(t: ^Transpiler) {
	t.indented += 1
}

dedent :: proc(t: ^Transpiler) {
	t.indented -= 1
}

write_newline :: proc(t: ^Transpiler) {
	ws(t.w, "\n")
	write_indent(t)
}

write_indent :: proc(t: ^Transpiler) {
	for _ in 0 ..< t.indented {
		ws(t.w, t.indent)
	}
}

transpile :: proc(w: io.Writer, identifier: string, templ: Template, embed_parser: Embed_Parser, embed_data: rawptr, allocator := context.allocator) {
	t: Transpiler
	t.embed_parser = embed_parser
	t.embed_data = embed_data
	t.indent = "\t"
	t.w = w

	indent(&t)
	write_indent(&t)
	ws(t.w, "when path == ")
	io.write_quoted_string(t.w, identifier)
	ws(t.w, " {")

	indent(&t)
	write_newline(&t)
	ws(t.w, "return {")

	indent(&t)
	write_newline(&t)
	fmt.wprintf(t.w, "with = proc(%s: %s.Writer, this: T) -> (%s: int, %s: %s.Error) {{", ARG_W, PKG_IO, RET_N, RET_ERR, PKG_IO)

	indent(&t)
	write_newline(&t)

	for node, i in templ.content {
		transpile_node(&t, node)
		write_newline(&t)
	}

	ws(t.w, "return")

	dedent(&t)
	write_newline(&t)
	ws(t.w, "}, ")

	write_newline(&t)
	ws(t.w, "approx_bytes = ")
	io.write_int(t.w, t.approx_bytes)
	ws(t.w, ",")

	dedent(&t)
	write_newline(&t)
	ws(t.w, "}")

	dedent(&t)
	write_newline(&t)
	ws(t.w, "}")
}

transpile_node :: proc(t: ^Transpiler, node: Node) {
	switch d in node.derived {
	case ^Node_Text:
		transpile_text(t, d)
	case ^Node_Output:
		transpile_output(t, d)
	case ^Node_If:
		transpile_if(t, d)
	case ^Node_For:
		transpile_for(t, d)
	case ^Node_Embed:
		transpile_embed(t, d)
	}
}

transpile_text :: proc(t: ^Transpiler, node: ^Node_Text) {
	t.approx_bytes += len(node.text.value)

	fmt.wprintf(t.w, "%s += %s.write_string(%s, ", RET_N, PKG_IO, ARG_W)
	io.write_quoted_string(t.w, node.text.value)
	ws(t.w, ") or_return")
}

transpile_output :: proc(t: ^Transpiler, node: ^Node_Output) {
	t.approx_bytes += 10
	
	ws(t.w, RET_N)
	ws(t.w, " += ")

	v := strings.trim_space(node.expression.value)
	// Users can force a specific write call by wrapping the expression in a "cast".
	switch {
	case strings.has_prefix(v, "byte("):
		fmt.wprintf(t.w, "%s.write_byte(", PKG_IO)
	case strings.has_prefix(v, "rune("):
		fmt.wprintf(t.w, "%s.write_rune(", PKG_IO)
	case strings.has_prefix(v, "int("):
		fmt.wprintf(t.w, "%s.write_int(", PKG_IO)
	case strings.has_prefix(v, "uint("):
		fmt.wprintf(t.w, "%s.write_uint(", PKG_IO)
	case strings.has_prefix(v, "i128("):
		fmt.wprintf(t.w, "%s.write_i128(", PKG_IO)
	case strings.has_prefix(v, "u128("):
		fmt.wprintf(t.w, "%s.write_u128(", PKG_IO)
	case strings.has_prefix(v, "u64("):
		fmt.wprintf(t.w, "%s.write_u64(", PKG_IO)
	case strings.has_prefix(v, "i64("):
		fmt.wprintf(t.w, "%s.write_i64(", PKG_IO)
	case strings.has_prefix(v, "f32("):
		fmt.wprintf(t.w, "%s.write_f32(", PKG_IO)
	case strings.has_prefix(v, "f64("):
		fmt.wprintf(t.w, "%s.write_f64(", PKG_IO)
	case:
		ws(t.w, "__temple_write_escaped_string(")
	}

	ws(t.w, ARG_W)
	ws(t.w, ", ")

	ws(t.w, v)
	ws(t.w, ") or_return")
}

transpile_if :: proc(t: ^Transpiler, node: ^Node_If) {
	ws(t.w, "if ")
	ws(t.w, strings.trim_space(node._if.start.expr.?.value))

	ws(t.w, " {")
	indent(t)
	write_newline(t)

	approx_start := t.approx_bytes
	max_approx_bytes: int

	for n, i in node._if.body {
		transpile_node(t, n)

		if i != len(node._if.body) - 1 {
			write_newline(t)
		}
	}

	max_approx_bytes = t.approx_bytes - approx_start
	t.approx_bytes = approx_start

	dedent(t)
	write_newline(t)
	ws(t.w, "}")

	for elsef in node.elseifs {
		ws(t.w, " else if ")
		ws(t.w, strings.trim_space(elsef.start.expr.?.value))
		ws(t.w, " {")
		indent(t)
		write_newline(t)

		for n, i in elsef.body {
			transpile_node(t, n)

			if i != len(elsef.body) - 1 {
				write_newline(t)
			}
		}

		dedent(t)
		write_newline(t)
		ws(t.w, "}")
		
		// Check if this is the biggest branch in the if statement, and set max approx accordingly.
		approx_elseif := t.approx_bytes - approx_start
		t.approx_bytes = approx_start
		max_approx_bytes = max(max_approx_bytes, approx_elseif)
	}

	if els, ok := node._else.?; ok {
		ws(t.w, " else {")

		indent(t)
		write_newline(t)

		for n, i in els.body {
			transpile_node(t, n)

			if i != len(els.body) - 1 {
				write_newline(t)
			}
		}
		
		// Check if this is the biggest branch in the if statement, and set max approx accordingly.
		approx_else := t.approx_bytes - approx_start
		t.approx_bytes = approx_start
		max_approx_bytes = max(max_approx_bytes, approx_else)

		dedent(t)
		write_newline(t)
		ws(t.w, "}")
	}

	t.approx_bytes += max_approx_bytes
}

transpile_for :: proc(t: ^Transpiler, node: ^Node_For) {
	ws(t.w, "for ")
	ws(t.w, strings.trim_space(node.start.expression.value))

	ws(t.w, " {")
	indent(t)
	write_newline(t)

	for n, i in node.body {
		transpile_node(t, n)

		if i != len(node.body) - 1 {
			write_newline(t)
		}
	}

	dedent(t)
	write_newline(t)
	ws(t.w, "}")
}

transpile_embed :: proc(t: ^Transpiler, node: ^Node_Embed) {
	ws(t.w, "{ // ")
	ws(t.w, strings.trim(node.path.value, " \""))
	indent(t)
	write_newline(t)

	if with, ok := node.with.?; ok {
		ws(t.w, "this := ")
		ws(t.w, strings.trim_space(with.expr.value))
		write_newline(t)
	}

	if templ, ok := t.embed_parser(node, t.embed_data); ok {
		for node, i in templ.content {
			transpile_node(t, node)
			write_newline(t)
		}
	}

	dedent(t)
	write_newline(t)
	ws(t.w, "}")
}
