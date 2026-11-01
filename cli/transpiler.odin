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
	macro_names:  [8]string,
	macro_bytes:  [8]int,
	macro_count:  int,
	macro_approx: map[string]int,
	external_pkg: bool,
	emit_loc:     bool,

	embed_parser: Embed_Parser,
	embed_data:   rawptr,
}

@(private = "file")
set_macro_approx :: proc(t: ^Transpiler, name: string, bytes: int) {
	for i in 0 ..< t.macro_count {
		if t.macro_names[i] == name {
			t.macro_bytes[i] = bytes
			return
		}
	}
	if t.macro_count < len(t.macro_names) {
		t.macro_names[t.macro_count] = name
		t.macro_bytes[t.macro_count] = bytes
		t.macro_count += 1
		return
	}
	if t.macro_approx.allocator.procedure == nil {
		t.macro_approx = make(map[string]int, t.allocator)
	}
	t.macro_approx[name] = bytes
}

@(private = "file")
get_macro_approx :: proc(t: ^Transpiler, name: string) -> (int, bool) {
	for i in 0 ..< t.macro_count {
		if t.macro_names[i] == name {
			return t.macro_bytes[i], true
		}
	}
	if t.macro_approx.allocator.procedure != nil {
		if b, found := t.macro_approx[name]; found {
			return b, true
		}
	}
	return 0, false
}

Embed_Parser :: #type proc(t: ^Transpiler, embed: ^Node_Embed, user_data: rawptr) -> bool

@(private = "file")
NEWLINE_TABS :: "\n\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t"

@(private = "file")
append_uint_digits :: proc(buf: []byte, idx: int, val: int) -> int {
	if val < 10 {
		buf[idx] = byte('0' + val)
		return idx + 1
	}
	if val < 100 {
		buf[idx + 0] = byte('0' + val / 10)
		buf[idx + 1] = byte('0' + val % 10)
		return idx + 2
	}
	tmp: [20]byte
	pos := len(tmp)
	v := val
	for v > 0 {
		pos -= 1
		tmp[pos] = byte('0' + v % 10)
		v /= 10
	}
	n := len(tmp) - pos
	copy(buf[idx:], tmp[pos:])
	return idx + n
}

@(private = "file")
write_fast_uint :: proc(w: io.Writer, val: int) {
	if val >= 0 {
		buf: [20]byte
		end := append_uint_digits(buf[:], 0, val)
		ws(w, string(buf[:end]))
		return
	}
	io.write_int(w, val)
}

@(private = "file")
write_quoted_fast :: proc(w: io.Writer, str: string) {
	clean := true
	for i := 0; i < len(str); i += 1 {
		c := str[i]
		if c < 0x20 || c >= 0x7F || c == '"' || c == '\\' {
			clean = false
			break
		}
	}
	if clean {
		buf: [256]byte
		if len(str) + 2 <= len(buf) {
			buf[0] = '"'
			copy(buf[1:], str)
			buf[len(str) + 1] = '"'
			ws(w, string(buf[:len(str) + 2]))
			return
		}
		ws(w, "\"")
		ws(w, str)
		ws(w, "\"")
		return
	}

	qbuf: [512]byte
	qlen := 0
	qbuf[qlen] = '"'
	qlen += 1
	for i := 0; i < len(str); i += 1 {
		c := str[i]
		if c >= 0x80 || (c < 0x20 && c != '\n' && c != '\r' && c != '\t') {
			io.write_quoted_string(w, str)
			return
		}
		if qlen + 2 >= len(qbuf) - 1 {
			io.write_quoted_string(w, str)
			return
		}
		switch c {
		case '"':
			qbuf[qlen + 0] = '\\'
			qbuf[qlen + 1] = '"'
			qlen += 2
		case '\\':
			qbuf[qlen + 0] = '\\'
			qbuf[qlen + 1] = '\\'
			qlen += 2
		case '\n':
			qbuf[qlen + 0] = '\\'
			qbuf[qlen + 1] = 'n'
			qlen += 2
		case '\r':
			qbuf[qlen + 0] = '\\'
			qbuf[qlen + 1] = 'r'
			qlen += 2
		case '\t':
			qbuf[qlen + 0] = '\\'
			qbuf[qlen + 1] = 't'
			qlen += 2
		case:
			qbuf[qlen] = c
			qlen += 1
		}
	}
	qbuf[qlen] = '"'
	qlen += 1
	ws(w, string(qbuf[:qlen]))
}

indent :: proc(t: ^Transpiler) {
	t.indented += 1
}

dedent :: proc(t: ^Transpiler) {
	t.indented -= 1
}

write_newline :: proc(t: ^Transpiler) {
	nl_tabs := NEWLINE_TABS
	if t.indent == "\t" && t.indented >= 0 && t.indented + 1 <= len(nl_tabs) {
		ws(t.w, nl_tabs[:t.indented + 1])
		return
	}
	ws(t.w, "\n")
	write_indent(t)
}

write_indent :: proc(t: ^Transpiler) {
	nl_tabs := NEWLINE_TABS
	if t.indent == "\t" && t.indented >= 0 && t.indented < len(nl_tabs) {
		if t.indented > 0 {
			ws(t.w, nl_tabs[1 : t.indented + 1])
		}
		return
	}
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
	emit_loc := true,
) {
	t: Transpiler
	t.allocator = allocator
	t.external_pkg = external_pkg
	t.emit_loc = emit_loc
	t.embed_parser = embed_parser
	t.embed_data = embed_data
	t.indent = "\t"
	t.w = w

	indent(&t)
	write_indent(&t)
	ws(t.w, "when path == ")
	write_quoted_fast(t.w, identifier)
	ws(t.w, " {")

	indent(&t)
	write_newline(&t)
	ws(t.w, "return {")

	indent(&t)
	write_newline(&t)
	ws(t.w, "with = proc(" + ARG_W + ": " + PKG_IO + ".Writer, this: T) -> (" + RET_N + ": int, " + RET_ERR + ": " + PKG_IO + ".Error) {")

	indent(&t)
	write_newline(&t)

	transpile_template_nodes(&t, templ.content[:])

	ws(t.w, "return")

	dedent(&t)
	write_newline(&t)
	ws(t.w, "}, ")

	write_newline(&t)
	ws(t.w, "approx_bytes = ")
	write_fast_uint(t.w, t.approx_bytes)
	ws(t.w, ",")

	dedent(&t)
	write_newline(&t)
	ws(t.w, "}")

	dedent(&t)
	write_newline(&t)
	ws(t.w, "}")
}

const_for_loop_approx_multiplier :: 8

@(private = "file")
for_loop_approx_multiplier :: proc(loop_body_bytes: int) -> int {
	if loop_body_bytes >= 128 {
		return 60
	}
	return const_for_loop_approx_multiplier
}

@(private = "file")
estimate_nodes_approx :: proc(t: ^Transpiler, nodes: []Node) -> int {
	total := 0
	for node in nodes {
		switch d in node.derived {
		case ^Node_Text:
			total += len(d.text.value)
		case ^Node_Output:
			total += estimate_output_approx(d)
		case ^Node_If:
			max_b := estimate_nodes_approx(t, d._if.body[:])
			for ef in d.elseifs {
				max_b = max(max_b, estimate_nodes_approx(t, ef.body[:]))
			}
			if els, ok := d._else.?; ok {
				max_b = max(max_b, estimate_nodes_approx(t, els.body[:]))
			}
			total += max_b
		case ^Node_For:
			body_b := estimate_nodes_approx(t, d.body[:])
			total += body_b * for_loop_approx_multiplier(body_b)
		case ^Node_Switch:
			max_c := 0
			for c in d.cases {
				max_c = max(max_c, estimate_nodes_approx(t, c.body[:]))
			}
			total += max_c
		case ^Node_Block:
			total += estimate_nodes_approx(t, d.body[:])
		case ^Node_Call:
			if mb, found := get_macro_approx(t, d.name); found {
				total += mb
			} else {
				total += 10
			}
		case ^Node_Let, ^Node_Embed, ^Node_Macro, ^Node_Extends, ^Node_Super:
		}
	}
	return total
}

@(private = "package")
Simple_Fmt_Spec :: struct {
	prefix:     string,
	verb:       byte,
	float_prec: int,
	suffix:     string,
	is_simple:  bool,
}

@(private = "package")
try_parse_simple_fmt_literal :: proc(fmt_expr_src: string, allocator := context.temp_allocator) -> Simple_Fmt_Spec {
	unquoted, ok := unquote_odin_string(strings.trim_space(fmt_expr_src))
	if !ok {
		return {}
	}

	// Scan for `%%` vs a single bare `%s`, `%i`, `%d`, `%f`, or `%.Nf` verb
	verb_idx := -1
	verb_end := -1
	verb_ch: byte = 0
	float_prec := 6
	for i := 0; i < len(unquoted); i += 1 {
		if unquoted[i] == '%' {
			if i + 1 >= len(unquoted) {
				return {}
			}
			next_c := unquoted[i + 1]
			if next_c == '%' {
				i += 1
				continue
			}
			if verb_idx != -1 {
				// Multiple format verbs
				return {}
			}
			switch next_c {
			case 's', 'i', 'd':
				verb_idx = i
				verb_end = i + 2
				verb_ch = next_c
				i += 1
			case 'f':
				verb_idx = i
				verb_end = i + 2
				verb_ch = 'f'
				float_prec = 6
				i += 1
			case '.':
				// Check for `%.Nf` where N is 1..2 decimal digits (0..18)
				j := i + 2
				if j >= len(unquoted) || unquoted[j] < '0' || unquoted[j] > '9' {
					return {}
				}
				prec := 0
				digits := 0
				for j < len(unquoted) && unquoted[j] >= '0' && unquoted[j] <= '9' {
					prec = prec * 10 + int(unquoted[j] - '0')
					j += 1
					digits += 1
					if digits > 2 {
						return {}
					}
				}
				if j >= len(unquoted) || unquoted[j] != 'f' || prec > 18 {
					return {}
				}
				verb_idx = i
				verb_end = j + 1
				verb_ch = 'f'
				float_prec = prec
				i = j
			case:
				return {}
			}
		}
	}

	if verb_idx == -1 {
		return {}
	}

	raw_prefix := unquoted[:verb_idx]
	raw_suffix := unquoted[verb_end:]
	prefix_str := raw_prefix
	if strings.index_byte(raw_prefix, '%') != -1 {
		prefix_str, _ = strings.replace_all(raw_prefix, "%%", "%", allocator)
	}
	suffix_str := raw_suffix
	if strings.index_byte(raw_suffix, '%') != -1 {
		suffix_str, _ = strings.replace_all(raw_suffix, "%%", "%", allocator)
	}

	return Simple_Fmt_Spec{
		prefix     = prefix_str,
		verb       = verb_ch,
		float_prec = float_prec,
		suffix     = suffix_str,
		is_simple  = true,
	}
}

@(private = "package")
has_top_level_comma :: proc(expr_src: string) -> bool {
	depth := 0
	in_quote: byte = 0
	for i := 0; i < len(expr_src); i += 1 {
		c := expr_src[i]
		if in_quote != 0 {
			if c == '\\' && (in_quote == '"' || in_quote == '\'') {
				i += 1
				continue
			}
			if c == in_quote {
				in_quote = 0
			}
			continue
		}
		switch c {
		case '"', '\'', '`':
			in_quote = c
		case '(', '[', '{':
			depth += 1
		case ')', ']', '}':
			depth -= 1
		case ',':
			if depth == 0 {
				return true
			}
		}
	}
	return false
}

@(private = "file")
estimate_output_approx :: proc(node: ^Node_Output) -> int {
	if node.write_kind == .Fmt_Escaped || node.write_kind == .Fmt_Raw {
		v := node.inner_expr if len(node.inner_expr) > 0 else strings.trim_space(node.expression.value)
		if len(node.default_arg) > 0 || !has_top_level_comma(v) {
			if spec := try_parse_simple_fmt_literal(node.fmt_str); spec.is_simple {
				is_raw := node.write_kind == .Fmt_Raw
				pre_len := len(spec.prefix) if is_raw else len(escape_html_literal_at_compile_time(spec.prefix))
				suf_len := len(spec.suffix) if is_raw else len(escape_html_literal_at_compile_time(spec.suffix))
				return pre_len + 10 + suf_len
			}
		}
	}
	return 10
}

@(private = "file")
transpile_slice_needs_flatten :: proc(nodes: []Node) -> bool {
	prev_was_text := false
	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Text:
			if len(d.text.value) == 0 || prev_was_text {
				return true
			}
			prev_was_text = true
		case ^Node_Output:
			if d.write_kind == .Fmt_Escaped || d.write_kind == .Fmt_Raw {
				return true
			}
			prev_was_text = false
		case:
			prev_was_text = false
		}
	}
	return false
}

@(private = "file")
flatten_and_coalesce_nodes :: proc(t: ^Transpiler, nodes: []Node) -> []Node {
	if !transpile_slice_needs_flatten(nodes) {
		return nodes
	}
	out := make([dynamic]Node, 0, len(nodes), t.allocator)
	append_flattened_nodes(t, &out, nodes)
	return out[:]
}

@(private = "file")
append_coalesced_text :: proc(t: ^Transpiler, out: ^[dynamic]Node, txt_tok: Token, existing_node: Maybe(^Node_Text) = nil) {
	if len(txt_tok.value) == 0 {
		return
	}
	if len(out^) > 0 {
		if prev_txt, is_prev := out^[len(out^) - 1].derived.(^Node_Text); is_prev {
			merged := new(Node_Text, t.allocator)
			merged.derived = merged
			merged.text = prev_txt.text
			merged.text.value = strings.concatenate({prev_txt.text.value, txt_tok.value}, t.allocator)
			out^[len(out^) - 1] = merged
			return
		}
	}
	if ex, has_ex := existing_node.?; has_ex {
		append(out, ex)
		return
	}
	nt := new(Node_Text, t.allocator)
	nt.derived = nt
	nt.text = txt_tok
	append(out, nt)
}

@(private = "file")
append_flattened_nodes :: proc(t: ^Transpiler, out: ^[dynamic]Node, nodes: []Node) {
	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Text:
			append_coalesced_text(t, out, d.text, d)
		case ^Node_Output:
			v := d.inner_expr if len(d.inner_expr) > 0 else strings.trim_space(d.expression.value)
			if (d.write_kind == .Fmt_Escaped || d.write_kind == .Fmt_Raw) && !has_top_level_comma(v) {
				if spec := try_parse_simple_fmt_literal(d.fmt_str, t.allocator); spec.is_simple {
					is_raw := d.write_kind == .Fmt_Raw
					if len(spec.prefix) > 0 {
						pre_val := spec.prefix if is_raw else escape_html_literal_at_compile_time(spec.prefix, t.allocator)
						append_coalesced_text(t, out, Token{type = .Text, value = pre_val, pos = d.open.pos})
					}
					mid := new(Node_Output, t.allocator)
					mid^ = d^
					mid.derived = mid
					switch spec.verb {
					case 's':
						mid.write_kind = .Raw_String if is_raw else .Escaped_String
						mid.inner_expr = v
					case 'i', 'd':
						mid.write_kind = .Int
						mid.inner_expr = v
						mid.wrap_call = "int" if len(d.wrap_call) == 0 else d.wrap_call
					case 'f':
						mid.write_kind = .F64_Prec
						mid.float_prec = spec.float_prec
						mid.inner_expr = v
						mid.wrap_call = "f64" if len(d.wrap_call) == 0 else d.wrap_call
					}
					append(out, mid)
					if len(spec.suffix) > 0 {
						suf_val := spec.suffix if is_raw else escape_html_literal_at_compile_time(spec.suffix, t.allocator)
						append_coalesced_text(t, out, Token{type = .Text, value = suf_val, pos = d.open.pos})
					}
					continue
				}
			}
			append(out, node)
		case:
			append(out, node)
		}
	}
}

transpile_node_sequence :: proc(t: ^Transpiler, nodes: []Node, trailing_newline: bool) {
	flat := flatten_and_coalesce_nodes(t, nodes)
	for n, i in flat {
		transpile_node(t, n)
		if trailing_newline || i != len(flat) - 1 {
			write_newline(t)
		}
	}
}

transpile_template_nodes :: proc(t: ^Transpiler, nodes: []Node) {
	macro_count := 0
	all_macros_at_front := true
	seen_non_macro := false
	for node in nodes {
		if _, is_mac := node.derived.(^Node_Macro); is_mac {
			macro_count += 1
			if seen_non_macro {
				all_macros_at_front = false
			}
		} else {
			seen_non_macro = true
		}
	}
	if macro_count == 0 {
		transpile_node_sequence(t, nodes, true)
		return
	}

	// Pre-seed macro approx_bytes so even forward macro-to-macro calls resolve accurately.
	passes := 2 if macro_count > 1 else 1
	for _ in 0 ..< passes {
		for node in nodes {
			if mac, is_mac := node.derived.(^Node_Macro); is_mac {
				set_macro_approx(t, mac.name, estimate_nodes_approx(t, mac.body[:]))
			}
		}
	}

	if all_macros_at_front {
		for i in 0 ..< macro_count {
			transpile_macro(t, nodes[i].derived.(^Node_Macro))
			write_newline(t)
		}
		transpile_node_sequence(t, nodes[macro_count:], true)
		return
	}

	// Pass 1: Hoist all `Node_Macro` declarations before body nodes so `t.macro_approx`
	// is populated (including any embedded templates inside macros) before `transpile_call` runs.
	body_only := make([dynamic]Node, 0, len(nodes) - macro_count, t.allocator)
	for node in nodes {
		if mac, is_mac := node.derived.(^Node_Macro); is_mac {
			transpile_macro(t, mac)
			write_newline(t)
		} else {
			append(&body_only, node)
		}
	}

	// Pass 2: Flatten `Node_Block` wrappers, coalesce adjacent `Node_Text` (and strength-reduced `fmt` literals), and emit.
	transpile_node_sequence(t, body_only[:], true)
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
	transpile_node_sequence(t, node.body[:], false)
}

transpile_macro :: proc(t: ^Transpiler, node: ^Node_Macro) {
	ws(t.w, "__temple_macro_")
	ws(t.w, node.name)
	if len(node.params_src) > 0 {
		ws(t.w, " :: proc(" + ARG_W + ": " + PKG_IO + ".Writer, ")
		ws(t.w, node.params_src)
		ws(t.w, ") -> (" + RET_N + ": int, " + RET_ERR + ": " + PKG_IO + ".Error) {")
	} else {
		ws(t.w, " :: proc(" + ARG_W + ": " + PKG_IO + ".Writer) -> (" + RET_N + ": int, " + RET_ERR + ": " + PKG_IO + ".Error) {")
	}
	transpile_loc(t, node.open.pos)
	indent(t)
	write_newline(t)

	approx_start := t.approx_bytes
	transpile_node_sequence(t, node.body[:], true)
	set_macro_approx(t, node.name, t.approx_bytes - approx_start)
	t.approx_bytes = approx_start

	ws(t.w, "return")
	dedent(t)
	write_newline(t)
	ws(t.w, "}")
}

transpile_call :: proc(t: ^Transpiler, node: ^Node_Call) {
	if macro_bytes, found := get_macro_approx(t, node.name); found {
		t.approx_bytes += macro_bytes
	} else {
		t.approx_bytes += 10
	}
	ws(t.w, RET_N + " += __temple_macro_")
	ws(t.w, node.name)
	if len(node.args_src) > 0 {
		ws(t.w, "(" + ARG_W + ", ")
		ws(t.w, node.args_src)
		ws(t.w, ") or_return")
	} else {
		ws(t.w, "(" + ARG_W + ") or_return")
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
		ws(t.w, ident_part)
		ws(t.w, " := ")
		ws(t.w, rhs)
	} else if node.has_type_decl {
		ws(t.w, lhs)
		ws(t.w, " = ")
		ws(t.w, rhs)
	} else {
		ws(t.w, lhs)
		ws(t.w, " := ")
		ws(t.w, rhs)
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
			ws(t.w, "case ")
			ws(t.w, strings.trim_space(expr.value))
			ws(t.w, ":")
		} else {
			ws(t.w, "case:")
		}
		transpile_loc(t, c.open.pos)

		indent(t)
		flat_case := flatten_and_coalesce_nodes(t, c.body[:])
		for child in flat_case {
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

	ws(t.w, RET_N + " += " + PKG_IO + ".write_string(" + ARG_W + ", ")
	write_quoted_fast(t.w, node.text.value)
	ws(t.w, ") or_return")
	transpile_loc(t, node.text.pos)
}

@(private = "file")
write_output_expr :: proc(w: io.Writer, node: ^Node_Output, v: string, force_wrap := "") {
	wrap := force_wrap if len(force_wrap) > 0 else node.wrap_call
	if len(wrap) > 0 {
		ws(w, wrap)
		ws(w, "(")
	}
	if len(node.default_arg) > 0 {
		ws(w, "__temple_default(")
		ws(w, v)
		ws(w, ", ")
		ws(w, node.default_arg)
		ws(w, ")")
	} else {
		ws(w, v)
	}
	if len(wrap) > 0 {
		ws(w, ")")
	}
}

transpile_output :: proc(t: ^Transpiler, node: ^Node_Output) {
	v := node.inner_expr if len(node.inner_expr) > 0 else strings.trim_space(node.expression.value)
	ext := t.external_pkg

	// Compile-time strength reduction for single-argument `fmt("...", expr)` with `%s`, `%i`, or `%d`:
	// emits direct static writes + `write_escaped_string` / `write_string` / `write_int` instead of `fmt.wprintf`.
	if (node.write_kind == .Fmt_Escaped || node.write_kind == .Fmt_Raw) && (len(node.default_arg) > 0 || !has_top_level_comma(v)) {
		if spec := try_parse_simple_fmt_literal(node.fmt_str, t.allocator); spec.is_simple {
			is_raw := node.write_kind == .Fmt_Raw
			has_emitted := false

			if len(spec.prefix) > 0 {
				escaped_pre := spec.prefix if is_raw else escape_html_literal_at_compile_time(spec.prefix, t.allocator)
				t.approx_bytes += len(escaped_pre)
				ws(t.w, RET_N + " += " + PKG_IO + ".write_string(" + ARG_W + ", ")
				write_quoted_fast(t.w, escaped_pre)
				ws(t.w, ") or_return")
				transpile_loc(t, node.open.pos)
				has_emitted = true
			}

			if has_emitted {
				write_newline(t)
			}
			t.approx_bytes += 10
			switch spec.verb {
			case 's':
				if is_raw {
					ws(t.w, RET_N + " += " + PKG_IO + ".write_string(" + ARG_W + ", ")
				} else {
					ws(t.w, RET_N + " += __temple.__temple_write_escaped_string(" + ARG_W + ", " if ext else RET_N + " += __temple_write_escaped_string(" + ARG_W + ", ")
				}
				write_output_expr(t.w, node, v)
				ws(t.w, ") or_return")
			case 'i', 'd':
				ws(t.w, RET_N + " += __temple.__temple_write_int(" + ARG_W + ", " if ext else RET_N + " += __temple_write_int(" + ARG_W + ", ")
				write_output_expr(t.w, node, v, "int")
				ws(t.w, ") or_return")
			case 'f':
				ws(t.w, RET_N + " += __temple.__temple_write_f64_prec(" + ARG_W + ", " if ext else RET_N + " += __temple_write_f64_prec(" + ARG_W + ", ")
				write_output_expr(t.w, node, v, "f64")
				ws(t.w, ", ")
				write_fast_uint(t.w, spec.float_prec)
				ws(t.w, ") or_return")
			}
			transpile_loc(t, node.open.pos)

			if len(spec.suffix) > 0 {
				write_newline(t)
				escaped_suf := spec.suffix if is_raw else escape_html_literal_at_compile_time(spec.suffix, t.allocator)
				t.approx_bytes += len(escaped_suf)
				ws(t.w, RET_N + " += " + PKG_IO + ".write_string(" + ARG_W + ", ")
				write_quoted_fast(t.w, escaped_suf)
				ws(t.w, ") or_return")
				transpile_loc(t, node.open.pos)
			}
			return
		}
	}

	t.approx_bytes += 10

	switch node.write_kind {
	case .Fmt_Escaped:
		ws(t.w, RET_N + " += __temple.__temple_write_fmt_escaped(" + ARG_W + ", " if ext else RET_N + " += __temple_write_fmt_escaped(" + ARG_W + ", ")
		ws(t.w, node.fmt_str)
		ws(t.w, ", ")
		write_output_expr(t.w, node, v)
		ws(t.w, ") or_return")
		transpile_loc(t, node.open.pos)
		return
	case .Fmt_Raw:
		ws(t.w, RET_N + " += __temple.__temple_write_fmt_raw(" + ARG_W + ", " if ext else RET_N + " += __temple_write_fmt_raw(" + ARG_W + ", ")
		ws(t.w, node.fmt_str)
		ws(t.w, ", ")
		write_output_expr(t.w, node, v)
		ws(t.w, ") or_return")
		transpile_loc(t, node.open.pos)
		return
	case .Raw_String:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_string(" + ARG_W + ", ")
	case .Magic_String:
		ws(t.w, RET_N + " += __temple.__temple_write_magic_string(" + ARG_W + ", " if ext else RET_N + " += __temple_write_magic_string(" + ARG_W + ", ")
	case .Url_String:
		ws(t.w, RET_N + " += __temple.__temple_write_safe_url(" + ARG_W + ", " if ext else RET_N + " += __temple_write_safe_url(" + ARG_W + ", ")
	case .Url_Param_String:
		ws(t.w, RET_N + " += __temple.__temple_write_url_param(" + ARG_W + ", " if ext else RET_N + " += __temple_write_url_param(" + ARG_W + ", ")
	case .Js_String:
		ws(t.w, RET_N + " += __temple.__temple_write_js_string(" + ARG_W + ", " if ext else RET_N + " += __temple_write_js_string(" + ARG_W + ", ")
	case .Byte:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_byte(" + ARG_W + ", ")
	case .Rune:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_rune(" + ARG_W + ", ")
	case .Int:
		ws(t.w, RET_N + " += __temple.__temple_write_int(" + ARG_W + ", " if ext else RET_N + " += __temple_write_int(" + ARG_W + ", ")
	case .Uint:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_uint(" + ARG_W + ", ")
	case .I128:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_i128(" + ARG_W + ", ")
	case .U128:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_u128(" + ARG_W + ", ")
	case .U64:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_u64(" + ARG_W + ", ")
	case .I64:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_i64(" + ARG_W + ", ")
	case .F32:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_f32(" + ARG_W + ", ")
	case .F64:
		ws(t.w, RET_N + " += " + PKG_IO + ".write_f64(" + ARG_W + ", ")
	case .F64_Prec:
		ws(t.w, RET_N + " += __temple.__temple_write_f64_prec(" + ARG_W + ", " if ext else RET_N + " += __temple_write_f64_prec(" + ARG_W + ", ")
		write_output_expr(t.w, node, v)
		ws(t.w, ", ")
		write_fast_uint(t.w, node.float_prec)
		ws(t.w, ") or_return")
		transpile_loc(t, node.open.pos)
		return
	case .Escaped_String:
		ws(t.w, RET_N + " += __temple.__temple_write_escaped_string(" + ARG_W + ", " if ext else RET_N + " += __temple_write_escaped_string(" + ARG_W + ", ")
	}

	write_output_expr(t.w, node, v)
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

	transpile_node_sequence(t, node._if.body[:], false)

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

		transpile_node_sequence(t, elsef.body[:], false)

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

		transpile_node_sequence(t, els.body[:], false)

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

@(private = "package")
escape_html_literal_at_compile_time :: proc(str: string, allocator := context.temp_allocator) -> string {
	needs_escape := false
	for i in 0 ..< len(str) {
		switch str[i] {
		case '&', '"', '\'', '<', '>':
			needs_escape = true
			break
		}
	}
	if !needs_escape {
		return str
	}
	sb := strings.builder_make(0, len(str) + 8, allocator)
	for i in 0 ..< len(str) {
		switch str[i] {
		case '&':
			strings.write_string(&sb, "&amp;")
		case '"':
			strings.write_string(&sb, "&quot;")
		case '\'':
			strings.write_string(&sb, "&#039;")
		case '<':
			strings.write_string(&sb, "&lt;")
		case '>':
			strings.write_string(&sb, "&gt;")
		case:
			strings.write_byte(&sb, str[i])
		}
	}
	return strings.to_string(sb)
}

transpile_for :: proc(t: ^Transpiler, node: ^Node_For) {
	ws(t.w, "for ")
	ws(t.w, strings.trim_space(node.start.expression.value))

	ws(t.w, " {")
	transpile_loc(t, node.start.open.pos)
	indent(t)
	write_newline(t)

	approx_start := t.approx_bytes
	transpile_node_sequence(t, node.body[:], false)
	loop_body_bytes := t.approx_bytes - approx_start
	t.approx_bytes = approx_start + loop_body_bytes * for_loop_approx_multiplier(loop_body_bytes)

	dedent(t)
	write_newline(t)
	ws(t.w, "}")
}

transpile_embed :: proc(t: ^Transpiler, node: ^Node_Embed) {
	ws(t.w, "{")
	norm_path := normalize_slash_path(node.path.value, t.allocator)
	if t.emit_loc {
		ws(t.w, " /* ")
		write_fast_uint(t.w, node.open.pos.line + 1)
		ws(t.w, ":")
		write_fast_uint(t.w, node.open.pos.col + 1)
		ws(t.w, " in template embedding ")
		ws(t.w, norm_path)
		ws(t.w, " */")
	}
	indent(t)
	write_newline(t)

	if len(node.props) > 0 {
		for prop, i in node.props {
			ws(t.w, "__temple_prop_")
			write_fast_uint(t.w, i)
			ws(t.w, " := ")
			ws(t.w, prop.val_expr)
			write_newline(t)
		}
		ws(t.w, "this := struct { ")
		for prop, i in node.props {
			if i > 0 do ws(t.w, ", ")
			ws(t.w, prop.name)
			ws(t.w, ": type_of(__temple_prop_")
			write_fast_uint(t.w, i)
			ws(t.w, ")")
		}
		ws(t.w, " }{ ")
		for prop, i in node.props {
			if i > 0 do ws(t.w, ", ")
			ws(t.w, prop.name)
			ws(t.w, " = __temple_prop_")
			write_fast_uint(t.w, i)
		}
		ws(t.w, " }")
		write_newline(t)
	} else if with, ok := node.with.?; ok {
		ws(t.w, "this := ")
		ws(t.w, strings.trim_space(with.expr.value))
		write_newline(t)
	}

	if t.embed_parser != nil {
		prev_macro_names := t.macro_names
		prev_macro_bytes := t.macro_bytes
		prev_macro_count := t.macro_count
		prev_macro_approx := t.macro_approx
		t.macro_count = 0
		t.macro_approx = {}
		defer {
			t.macro_names = prev_macro_names
			t.macro_bytes = prev_macro_bytes
			t.macro_count = prev_macro_count
			t.macro_approx = prev_macro_approx
		}

		_ = t.embed_parser(t, node, t.embed_data)
	}

	dedent(t)
	write_newline(t)
	ws(t.w, "}")
}

transpile_loc :: proc(t: ^Transpiler, pos: Pos, extra := "") {
	if !t.emit_loc do return
	if len(extra) == 0 {
		buf: [48]byte
		copy(buf[:], " /* ")
		idx := append_uint_digits(buf[:], 4, pos.line + 1)
		buf[idx] = ':'
		idx = append_uint_digits(buf[:], idx + 1, pos.col + 1)
		copy(buf[idx:], " in template */")
		ws(t.w, string(buf[:idx + 15]))
		return
	}
	ws(t.w, " /* ")
	write_fast_uint(t.w, pos.line + 1)
	ws(t.w, ":")
	write_fast_uint(t.w, pos.col + 1)
	ws(t.w, " in template ")
	ws(t.w, extra)
	ws(t.w, "*/")
}
