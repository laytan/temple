package temple_cli

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import odin_parser "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"
import "core:testing"

Spec_Driver :: struct {
	t:              ^testing.T,
	arena:          mem.Dynamic_Arena,
	alloc:          mem.Allocator,
	ctx:            Compile_Context,
	pkg_name:       string,
	temple_import:  string,
	seeded_files:   [dynamic]string,
	disk_gen_file:  string,
	has_disk_gen:   bool,
	collected:      [dynamic]Compile_Call,
	collect_errors: [dynamic]string,
	transpiled:     string,
	generated_file: string,
	compile_ok:     bool,
}

driver_init :: proc(t: ^testing.T) -> ^Spec_Driver {
	d := new(Spec_Driver, context.temp_allocator)
	d.t = t
	mem.dynamic_arena_init(&d.arena)
	d.alloc = mem.dynamic_arena_allocator(&d.arena)

	d.pkg_name = "temple"
	d.ctx.allocator = d.alloc
	d.ctx.stack = make([dynamic]Trace_Frame, d.alloc)
	d.ctx.raw_cache = make(map[string]Cached_Template, d.alloc)
	d.ctx.used_files = make(map[string]bool, d.alloc)
	d.ctx.diagnostics = make([dynamic]Diagnostic, d.alloc)
	d.seeded_files = make([dynamic]string, d.alloc)
	d.collected = make([dynamic]Compile_Call, d.alloc)
	d.collect_errors = make([dynamic]string, d.alloc)
	return d
}

driver_destroy :: proc(d: ^Spec_Driver) {
	mem.dynamic_arena_destroy(&d.arena)
}

driver_seed_template :: proc(d: ^Spec_Driver, fullpath: string, content: string) {
	raw := transmute([]byte)strings.clone(content, d.alloc)
	p: Parser
	parser_init(&p, raw, d.alloc)
	parsed := parse(&p)
	cloned_path := strings.clone(fullpath, d.alloc)
	d.ctx.raw_cache[cloned_path] = Cached_Template{
		source   = raw,
		template = parsed,
	}
	append(&d.seeded_files, cloned_path)
}

driver_compile_path :: proc(d: ^Spec_Driver, fullpath, relpath, odin_file: string, line, col: int) {
	clear(&d.ctx.stack)
	clear(&d.ctx.diagnostics)

	call := Compile_Call{
		pos        = tokenizer.Pos{file = odin_file, line = line, column = col},
		identifier = relpath,
		type       = Call_Path{fullpath = fullpath, relpath = relpath},
	}
	d.transpiled, d.compile_ok = compile_single_call(&d.ctx, call)
	if d.compile_ok {
		d.generated_file = driver_build_generated_file(d)
	}
}

driver_compile_inline :: proc(d: ^Spec_Driver, inline_src, odin_file: string, line, col: int) {
	clear(&d.ctx.stack)
	clear(&d.ctx.diagnostics)

	call := Compile_Call{
		pos        = tokenizer.Pos{file = odin_file, line = line, column = col},
		identifier = inline_src,
		type       = Call_Inline{template = inline_src},
	}
	d.transpiled, d.compile_ok = compile_single_call(&d.ctx, call)
	if d.compile_ok {
		d.generated_file = driver_build_generated_file(d)
	}
}

driver_build_generated_file :: proc(d: ^Spec_Driver) -> string {
	sb := strings.builder_make(d.alloc)
	w := strings.to_writer(&sb)
	write_generated_file_header_body(w, d.pkg_name, d.temple_import)
	strings.write_string(&sb, d.transpiled)
	write_generated_file_footer(w, true)
	return strings.to_string(sb)
}

// Cross-cutting invariant: wraps generated `when path == ...` branch inside a valid Odin package
// and verifies `core:odin/parser` parses the emitted code with zero syntax errors.
driver_assert_valid_generated_odin :: proc(d: ^Spec_Driver) {
	wrapper := d.generated_file if len(d.generated_file) > 0 else driver_build_generated_file(d)

	context.allocator = d.alloc
	context.temp_allocator = d.alloc
	NO_POS :: tokenizer.Pos{}
	pkg := ast.new(ast.Package, NO_POS, NO_POS)
	file := ast.new(ast.File, NO_POS, NO_POS)
	file.pkg = pkg
	file.src = wrapper
	file.fullpath = "generated_templates.odin"

	op := odin_parser.default_parser()
	op.err = odin_silent_err_handler
	op.warn = odin_silent_warn_handler
	tl_odin_diag = {}

	ok := odin_parser.parse_file(&op, file)
	testing.expectf(
		d.t,
		ok && !tl_odin_diag.has_err && op.error_count == 0,
		"Generated Odin code failed AST syntax check (%s):\n%s",
		tl_odin_diag.msg,
		d.transpiled,
	)
}

driver_collect_calls_from_source :: proc(d: ^Spec_Driver, pkg_dir, filename, odin_src: string) {
	context.allocator = d.alloc
	context.temp_allocator = d.alloc
	NO_POS :: tokenizer.Pos{}
	pkg := ast.new(ast.Package, NO_POS, NO_POS)
	pkg.fullpath = pkg_dir

	file := ast.new(ast.File, NO_POS, NO_POS)
	file.pkg = pkg
	file.src = odin_src
	file.fullpath = fmt.aprintf("%s/%s", pkg_dir, filename, allocator = d.alloc)

	op := odin_parser.default_parser()
	op.err = odin_silent_err_handler
	op.warn = odin_silent_warn_handler
	parsed_ok := odin_parser.parse_file(&op, file)
	testing.expect(d.t, parsed_ok, "test Odin source failed to parse")

	seen := make(map[string]string, d.alloc)
	parsed_files := []^ast.File{file}
	collect_calls_from_parsed_files(
		pkg.fullpath,
		parsed_files,
		&d.collected,
		&seen,
		d.alloc,
		&d.collect_errors,
		d.alloc,
	)
}
