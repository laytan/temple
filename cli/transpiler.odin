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

// compiled :: proc($path: string, $T: typeid) -> Compiled(T) {
// 	when path == "templates/home.temple.html" {
// 		return {
// 			with = proc(w: io.Writer, this: T) {
// 				io.write_string(w, "<h1>Hello, ")
// 				write_escaped_string(w, this.name)
// 				io.write_string(w, "!</h1>\n")
// 			},
// 			approx_bytes = 43,
// 		}
// 	} else {
// 		#panic("undefined template \"" + path + "\" did you run the temple transpiler?")
// 	}
// }

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
	ws(t.w, "with = proc(w: io.Writer, this: T) {")

	indent(&t)
	write_newline(&t)

	for node, i in templ.content {
		transpile_node(&t, node)

		if i != len(templ.content) - 1 {
			write_newline(&t)
		}
	}

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
	}
}

transpile_text :: proc(t: ^Transpiler, node: ^Node_Text) {
	t.approx_bytes += len(node.text.value)

	ws(t.w, `io.write_string(w, `)
	io.write_quoted_string(t.w, node.text.value)
	ws(t.w, `)`)
}

transpile_output :: proc(t: ^Transpiler, node: ^Node_Output) {
	t.approx_bytes += 10

	// TODO: detect what type it is and use the right function.

	ws(t.w, "write_escaped_string(w, ")
	ws(t.w, strings.trim_space(node.expression.value))
	ws(t.w, `)`)
}
