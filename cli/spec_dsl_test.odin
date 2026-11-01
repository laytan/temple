package temple_cli

import "core:fmt"
import "core:io"
import "core:strings"
import "core:testing"

Expected_Trace :: struct {
	kind: Trace_Kind,
	file: string,
	line: int,
	col:  int,
}

// --- Lifecycle ---

scenario_begin :: proc(t: ^testing.T) -> ^Spec_Driver {
	return driver_init(t)
}

scenario_end :: proc(d: ^Spec_Driver) {
	driver_destroy(d)
}

// --- GIVEN steps ---

given_template :: proc(d: ^Spec_Driver, path: string, content: string) {
	driver_seed_template(d, path, content)
}

given_target_package :: proc(d: ^Spec_Driver, pkg_name: string, temple_import := "shared:temple") {
	d.pkg_name = pkg_name
	d.temple_import = temple_import
	d.ctx.external_pkg = len(pkg_name) > 0 && pkg_name != "temple"
}

// --- UPON steps ---

upon_compiling_template :: proc(
	d: ^Spec_Driver,
	fullpath: string,
	relpath := "",
	called_from := "/app/main.odin",
	line := 1,
	col := 1,
) {
	id := relpath if len(relpath) > 0 else fullpath
	driver_compile_path(d, fullpath, id, called_from, line, col)
}

upon_compiling_inline :: proc(
	d: ^Spec_Driver,
	inline_template: string,
	called_from := "/app/main.odin",
	line := 1,
	col := 1,
) {
	driver_compile_inline(d, inline_template, called_from, line, col)
}

upon_scanning_odin_source :: proc(d: ^Spec_Driver, odin_src: string, pkg_dir := "/app", filename := "routes.odin") {
	driver_collect_calls_from_source(d, pkg_dir, filename, odin_src)
}

// --- THEN steps ---

then_compilation_succeeds :: proc(d: ^Spec_Driver) {
	testing.expectf(d.t, d.compile_ok, "expected compilation to succeed, got %i diagnostic(s)", len(d.ctx.diagnostics))
	testing.expect_value(d.t, len(d.ctx.diagnostics), 0)
	if d.compile_ok {
		// Automatically enforce cross-cutting AST validity invariant on every successful compilation
		driver_assert_valid_generated_odin(d)
	}
}

then_static_literals_render_in_order :: proc(d: ^Spec_Driver, literals: []string) {
	then_compilation_succeeds(d)

	sb := strings.builder_make(d.alloc)
	w := strings.to_writer(&sb)

	last_idx := 0
	for lit in literals {
		strings.builder_reset(&sb)
		io.write_quoted_string(w, lit)
		quoted := strings.to_string(sb)

		rel_idx := strings.index(d.transpiled[last_idx:], quoted)
		testing.expectf(
			d.t,
			rel_idx != -1,
			"expected static literal %s after byte %i in transpiled output:\n%s",
			quoted,
			last_idx,
			d.transpiled,
		)
		if rel_idx != -1 {
			last_idx += rel_idx + len(quoted)
		}
	}
}

then_approx_bytes_is :: proc(d: ^Spec_Driver, expected_bytes: int) {
	then_compilation_succeeds(d)
	needle := fmt.aprintf("approx_bytes = %i,", expected_bytes, allocator = d.alloc)
	testing.expectf(d.t, strings.contains(d.transpiled, needle), "expected %q in:\n%s", needle, d.transpiled)
}

then_emits_writer_call :: proc(d: ^Spec_Driver, expected_call: string) {
	then_compilation_succeeds(d)
	testing.expectf(
		d.t,
		strings.contains(d.transpiled, expected_call),
		"expected emitted writer call %q in:\n%s",
		expected_call,
		d.transpiled,
	)
}

then_generated_file_contains :: proc(d: ^Spec_Driver, expected_fragment: string) {
	then_compilation_succeeds(d)
	testing.expectf(
		d.t,
		strings.contains(d.generated_file, expected_fragment),
		"expected generated file to contain %q in:\n%s",
		expected_fragment,
		d.generated_file,
	)
}

then_diagnostic_is_reported :: proc(
	d: ^Spec_Driver,
	file: string,
	line: int,
	col: int,
	message_contains: string,
	snippet := "",
	caret_len := 0,
	trace: []Expected_Trace = nil,
) {
	testing.expect(d.t, !d.compile_ok, "expected compilation to fail with a diagnostic, but it succeeded")
	testing.expect_value(d.t, len(d.ctx.diagnostics), 1)
	if len(d.ctx.diagnostics) != 1 {
		return
	}

	diag := d.ctx.diagnostics[0]
	testing.expect_value(d.t, diag.pos.file, file)
	testing.expect_value(d.t, diag.pos.line, line)
	testing.expect_value(d.t, diag.pos.column, col)
	testing.expectf(
		d.t,
		strings.contains(diag.message, message_contains),
		"expected diagnostic message %q to contain %q",
		diag.message,
		message_contains,
	)

	if len(snippet) > 0 {
		testing.expect_value(d.t, diag.snippet, snippet)
	}
	if caret_len > 0 {
		testing.expect_value(d.t, diag.col_len, caret_len)
	}
	if trace != nil {
		testing.expect_value(d.t, len(diag.trace), len(trace))
		for expected, i in trace {
			if i >= len(diag.trace) do break
			actual := diag.trace[i]
			testing.expect_value(d.t, actual.kind, expected.kind)
			testing.expect_value(d.t, actual.pos.file, expected.file)
			testing.expect_value(d.t, actual.pos.line, expected.line)
			testing.expect_value(d.t, actual.pos.column, expected.col)
		}
	}
}

then_collected_templates_are :: proc(d: ^Spec_Driver, expected_identifiers: []string) {
	testing.expect_value(d.t, len(d.collected), len(expected_identifiers))
	for id, i in expected_identifiers {
		if i >= len(d.collected) do break
		testing.expect_value(d.t, d.collected[i].identifier, id)
	}
}

then_collection_error_contains :: proc(d: ^Spec_Driver, substr: string) {
	testing.expect(d.t, len(d.collect_errors) > 0, "expected at least 1 call collection error")
	if len(d.collect_errors) > 0 {
		testing.expectf(
			d.t,
			strings.contains(d.collect_errors[0], substr),
			"expected collection error %q to contain %q",
			d.collect_errors[0],
			substr,
		)
	}
}
