package temple_cli

import "core:fmt"
import "core:io"
import "core:mem"
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
	macro_approx: map[string]int,
	external_pkg: bool,

	embed_parser: Embed_Parser,
	embed_data:   rawptr,
}

Embed_Parser :: #type proc(t: ^Transpiler, embed: ^Node_Embed, user_data: rawptr) -> bool

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

transpile :: proc(
	w: io.Writer,
	identifier: string,
	templ: Template,
	embed_parser: Embed_Parser,
	embed_data: rawptr,
	allocator := context.allocator,
	external_pkg := false,
) {
	t: Transpiler
	t.allocator = allocator
	t.macro_approx = make(map[string]int, allocator)
	t.external_pkg = external_pkg
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

	for node in templ.content {
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
	case ^Node_Switch:
		transpile_switch(t, d)
	case ^Node_Let:
		transpile_let(t, d)
	case ^Node_Embed:
		transpile_embed(t, d)
	case ^Node_Block:
		transpile_block(t, d)
	case ^Node_Macro:
		transpile_macro(t, d)
	case ^Node_Call:
		transpile_call(t, d)
	case ^Node_Extends:
		// Resolved during layout splicing before transpilation.
	case ^Node_Super:
		// Resolved during layout splicing before transpilation.
	}
}

transpile_block :: proc(t: ^Transpiler, node: ^Node_Block) {
	for n, i in node.body {
		transpile_node(t, n)
		if i != len(node.body) - 1 {
			write_newline(t)
		}
	}
}

transpile_macro :: proc(t: ^Transpiler, node: ^Node_Macro) {
	if len(node.params_src) > 0 {
		fmt.wprintf(
			t.w,
			"__temple_macro_%s :: proc(%s: %s.Writer, %s) -> (%s: int, %s: %s.Error) {{",
			node.name,
			ARG_W,
			PKG_IO,
			node.params_src,
			RET_N,
			RET_ERR,
			PKG_IO,
		)
	} else {
		fmt.wprintf(
			t.w,
			"__temple_macro_%s :: proc(%s: %s.Writer) -> (%s: int, %s: %s.Error) {{",
			node.name,
			ARG_W,
			PKG_IO,
			RET_N,
			RET_ERR,
			PKG_IO,
		)
	}
	transpile_loc(t, node.open.pos)
	indent(t)
	write_newline(t)

	approx_start := t.approx_bytes
	for n in node.body {
		transpile_node(t, n)
		write_newline(t)
	}
	t.macro_approx[node.name] = t.approx_bytes - approx_start
	t.approx_bytes = approx_start

	ws(t.w, "return")
	dedent(t)
	write_newline(t)
	ws(t.w, "}")
}

transpile_call :: proc(t: ^Transpiler, node: ^Node_Call) {
	if macro_bytes, found := t.macro_approx[node.name]; found {
		t.approx_bytes += macro_bytes
	} else {
		t.approx_bytes += 10
	}
	if len(node.args_src) > 0 {
		fmt.wprintf(t.w, "%s += __temple_macro_%s(%s, %s) or_return", RET_N, node.name, ARG_W, node.args_src)
	} else {
		fmt.wprintf(t.w, "%s += __temple_macro_%s(%s) or_return", RET_N, node.name, ARG_W)
	}
	transpile_loc(t, node.open.pos)
}

transpile_let :: proc(t: ^Transpiler, node: ^Node_Let) {
	raw := strings.trim_space(node.assignment.value)
	eq_idx := find_assignment_equals(raw)

	lhs := strings.trim_space(raw[:eq_idx])
	rhs := strings.trim_space(raw[eq_idx + 1:])

	// If the user wrote `{% let x := 5 %}`, `lhs` ends with `:` -> emit `lhs= rhs` (`x := 5`).
	// If the user wrote `{% let x: int = 5 %}`, `node.has_type_decl` is true -> emit `lhs = rhs` (`x: int = 5`).
	// If the user wrote `{% let x = 5 %}`, emit `lhs := rhs` (`x := 5`).
	if strings.has_suffix(lhs, ":") {
		ident_part := strings.trim_space(lhs[:len(lhs)-1])
		fmt.wprintf(t.w, "%s := %s", ident_part, rhs)
	} else if node.has_type_decl {
		fmt.wprintf(t.w, "%s = %s", lhs, rhs)
	} else {
		fmt.wprintf(t.w, "%s := %s", lhs, rhs)
	}
	transpile_loc(t, node.open.pos)
}

transpile_switch :: proc(t: ^Transpiler, node: ^Node_Switch) {
	if node.is_partial {
		ws(t.w, "#partial switch ")
	} else {
		ws(t.w, "switch ")
	}

	if expr, has_expr := node.expression.?; has_expr {
		ws(t.w, strings.trim_space(expr.value))
		ws(t.w, " ")
	}

	ws(t.w, "{")
	transpile_loc(t, node.open.pos)
	write_newline(t)

	approx_start := t.approx_bytes
	max_case_bytes: int

	for c in node.cases {
		if expr, has_expr := c.expression.?; has_expr {
			fmt.wprintf(t.w, "case %s:", strings.trim_space(expr.value))
		} else {
			ws(t.w, "case:")
		}
		transpile_loc(t, c.open.pos)

		indent(t)
		for child in c.body {
			write_newline(t)
			transpile_node(t, child)
		}
		dedent(t)
		write_newline(t)

		case_bytes := t.approx_bytes - approx_start
		t.approx_bytes = approx_start
		max_case_bytes = max(max_case_bytes, case_bytes)
	}

	ws(t.w, "}")
	t.approx_bytes += max_case_bytes
}

transpile_text :: proc(t: ^Transpiler, node: ^Node_Text) {
	t.approx_bytes += len(node.text.value)

	fmt.wprintf(t.w, "%s += %s.write_string(%s, ", RET_N, PKG_IO, ARG_W)
	io.write_quoted_string(t.w, node.text.value)
	ws(t.w, ") or_return")
	transpile_loc(t, node.text.pos)
}

transpile_output :: proc(t: ^Transpiler, node: ^Node_Output) {
	t.approx_bytes += 10

	ws(t.w, RET_N)
	ws(t.w, " += ")

	v := node.inner_expr if len(node.inner_expr) > 0 else strings.trim_space(node.expression.value)
	rt_prefix := "__temple." if t.external_pkg else ""

	switch node.write_kind {
	case .Fmt_Escaped:
		fmt.wprintf(t.w, "%s__temple_write_fmt_escaped(%s, %s, %s) or_return", rt_prefix, ARG_W, node.fmt_str, v)
		transpile_loc(t, node.open.pos)
		return
	case .Fmt_Raw:
		fmt.wprintf(t.w, "%s__temple_write_fmt_raw(%s, %s, %s) or_return", rt_prefix, ARG_W, node.fmt_str, v)
		transpile_loc(t, node.open.pos)
		return
	case .Raw_String:
		fmt.wprintf(t.w, "%s.write_string(", PKG_IO)
	case .Magic_String:
		fmt.wprintf(t.w, "%s__temple_write_magic_string(", rt_prefix)
	case .Url_String:
		fmt.wprintf(t.w, "%s__temple_write_safe_url(", rt_prefix)
	case .Url_Param_String:
		fmt.wprintf(t.w, "%s__temple_write_url_param(", rt_prefix)
	case .Js_String:
		fmt.wprintf(t.w, "%s__temple_write_js_string(", rt_prefix)
	case .Byte:
		fmt.wprintf(t.w, "%s.write_byte(", PKG_IO)
	case .Rune:
		fmt.wprintf(t.w, "%s.write_rune(", PKG_IO)
	case .Int:
		fmt.wprintf(t.w, "%s.write_int(", PKG_IO)
	case .Uint:
		fmt.wprintf(t.w, "%s.write_uint(", PKG_IO)
	case .I128:
		fmt.wprintf(t.w, "%s.write_i128(", PKG_IO)
	case .U128:
		fmt.wprintf(t.w, "%s.write_u128(", PKG_IO)
	case .U64:
		fmt.wprintf(t.w, "%s.write_u64(", PKG_IO)
	case .I64:
		fmt.wprintf(t.w, "%s.write_i64(", PKG_IO)
	case .F32:
		fmt.wprintf(t.w, "%s.write_f32(", PKG_IO)
	case .F64:
		fmt.wprintf(t.w, "%s.write_f64(", PKG_IO)
	case .Escaped_String:
		fmt.wprintf(t.w, "%s__temple_write_escaped_string(", rt_prefix)
	}

	ws(t.w, ARG_W)
	ws(t.w, ", ")

	ws(t.w, v)
	ws(t.w, ") or_return")
	transpile_loc(t, node.open.pos)
}

transpile_if :: proc(t: ^Transpiler, node: ^Node_If) {
	ws(t.w, "if ")
	ws(t.w, strings.trim_space(node._if.start.expr.?.value))

	ws(t.w, " {")
	transpile_loc(t, node._if.start.open.pos)
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
		transpile_loc(t, elsef.start.open.pos)
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
		transpile_loc(t, els.start.open.pos)

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
	transpile_loc(t, node.start.open.pos)
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
	ws(t.w, "{")
	norm_path := normalize_slash_path(node.path.value, t.allocator)
	transpile_loc(t, node.open.pos, fmt.tprintf("embedding %s ", norm_path))
	indent(t)
	write_newline(t)

	if len(node.props) > 0 {
		for prop, i in node.props {
			fmt.wprintf(t.w, "__temple_prop_%i := %s", i, prop.val_expr)
			write_newline(t)
		}
		ws(t.w, "this := struct { ")
		for prop, i in node.props {
			if i > 0 do ws(t.w, ", ")
			fmt.wprintf(t.w, "%s: type_of(__temple_prop_%i)", prop.name, i)
		}
		ws(t.w, " }{ ")
		for prop, i in node.props {
			if i > 0 do ws(t.w, ", ")
			fmt.wprintf(t.w, "%s = __temple_prop_%i", prop.name, i)
		}
		ws(t.w, " }")
		write_newline(t)
	} else if with, ok := node.with.?; ok {
		ws(t.w, "this := ")
		ws(t.w, strings.trim_space(with.expr.value))
		write_newline(t)
	}

	if t.embed_parser != nil {
		_ = t.embed_parser(t, node, t.embed_data)
	}

	dedent(t)
	write_newline(t)
	ws(t.w, "}")
}

transpile_loc :: proc(t: ^Transpiler, pos: Pos, extra := "") {
	fmt.wprintf(t.w, " /* %i:%i in template %s*/", pos.line + 1, pos.col + 1, extra)
}
