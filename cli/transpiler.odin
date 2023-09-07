package temple_cli

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:reflect"
import "core:strings"

ws :: io.write_string

Transpiler :: struct {
	allocator:    mem.Allocator,
	w:            io.Writer,
	indent:       string,
	indented:     int,
	approx_bytes: int,
}

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

transpile :: proc(w: io.Writer, path: string, templ: Template, allocator := context.allocator) {
	t: Transpiler
	t.indent = "\t"
	t.w = w

	indent(&t)
	write_indent(&t)
	ws(t.w, "when path == ")
	io.write_quoted_string(t.w, path)
	ws(t.w, " {")

	indent(&t)
	write_newline(&t)
	ws(t.w, "return {")

	indent(&t)
	write_newline(&t)
	ws(t.w, "with = proc(w: io.Writer, this: T) -> (n: int, err: io.Error) {")

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
	}
}

transpile_text :: proc(t: ^Transpiler, node: ^Node_Text) {
	t.approx_bytes += len(node.text.value)

	ws(t.w, "n += io.write_string(w, ")
	io.write_quoted_string(t.w, node.text.value)
	ws(t.w, ") or_return")
}

transpile_output :: proc(t: ^Transpiler, node: ^Node_Output) {
	t.approx_bytes += 10

	ws(t.w, "n += ")

	v := strings.trim_space(node.expression.value)
	// Users can force a specific write call by wrapping the expression in a "cast".
	switch {
	case strings.has_prefix(v, "byte("):
		ws(t.w, "io.write_byte(w, ")
	case strings.has_prefix(v, "rune("):
		ws(t.w, "io.write_rune(w, ")
	case strings.has_prefix(v, "int("):
		ws(t.w, "io.write_int(w, ")
	case strings.has_prefix(v, "uint("):
		ws(t.w, "io.write_uint(w, ")
	case strings.has_prefix(v, "i128("):
		ws(t.w, "io.write_i128(w, ")
	case strings.has_prefix(v, "u128("):
		ws(t.w, "io.write_u128(w, ")
	case strings.has_prefix(v, "u64("):
		ws(t.w, "io.write_u64(w, ")
	case strings.has_prefix(v, "i64("):
		ws(t.w, "io.write_i64(w, ")
	case strings.has_prefix(v, "f32("):
		ws(t.w, "io.write_f32(w, ")
	case strings.has_prefix(v, "f64("):
		ws(t.w, "io.write_f64(w, ")
	case:
		ws(t.w, "write_escaped_string(w, ")
	}

	ws(t.w, v)
	ws(t.w, ") or_return")
}

transpile_if :: proc(t: ^Transpiler, node: ^Node_If) {
	ws(t.w, "if ")
	ws(t.w, strings.trim_space(node.start.expression.value))

	ws(t.w, " {")
	indent(t)
	write_newline(t)

	// NOTE: if we add else, we need to take the max() between the approx bytes of the two branches.

	for n, i in node.if_true {
		transpile_node(t, n)

		if i != len(node.if_true) - 1 {
			write_newline(t)
		}
	}

	dedent(t)
	write_newline(t)
	ws(t.w, "}")
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
