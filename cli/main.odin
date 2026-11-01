package temple_cli

import "core:fmt"
import "core:io"
import "core:mem"
import "core:odin/ast"
import odin_parser "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Compile_Call :: struct {
	pos:        tokenizer.Pos,
	identifier: string,
	type:       Call_Type,
}

Call_Type :: union {
	Call_Inline,
	Call_Path,
}

Call_Inline :: struct {
	template: string,
}

Call_Path :: struct {
	fullpath: string,
	relpath:  string,
}

Temple_Proc_Kind :: enum {
	None,
	Compiled,
	Compiled_Inline,
}

Trace_Kind :: enum {
	Call_Site, // temple.compiled(...) in .odin code
	Embed,     // embed "..." in a template
	Extends,   // extends "..." in a template
}

Trace_Frame :: struct {
	kind:    Trace_Kind,
	pos:     tokenizer.Pos, // Where the call/embed/extends occurred
	file:    string,        // Resolved target file being loaded
	snippet: string,        // Optional source line where the tag occurred
	col_len: int,           // Length of token to underline
}

Diagnostic :: struct {
	pos:       tokenizer.Pos, // Exact location of the error in the leaf template
	message:   string,
	snippet:   string,
	caret_col: int,
	col_len:   int,
	trace:     []Trace_Frame, // Cloned snapshot of Compile_Context.stack
}

Cached_Template :: struct {
	source:   []byte,
	template: Template,
}

Compile_Context :: struct {
	stack:           [dynamic]Trace_Frame,
	inline_stack:    [8]Trace_Frame,
	inline_stack_cnt: int,
	diagnostics:     [dynamic]Diagnostic,
	raw_cache:       map[string]Cached_Template,
	resolved_cache:  map[string]Template,
	inline_raw:      [8]struct {
		file:   string,
		cached: Cached_Template,
	},
	inline_raw_cnt:  int,
	inline_resolved: [8]struct {
		file:     string,
		template: Template,
	},
	inline_res_cnt:  int,
	used_files:      map[string]bool,
	allocator:       mem.Allocator,
	inline_file:     string,
	inline_pos:      tokenizer.Pos,
	external_pkg:    bool,
	ast_slab:        []byte,
	ast_slab_off:    int,
}

@(private = "file")
alloc_ctx_node :: proc(ctx: ^Compile_Context, $T: typeid) -> ^T {
	align :: int(align_of(T))
	size :: int(size_of(T))
	off := (ctx.ast_slab_off + (align - 1)) & ~(align - 1)
	if off + size > len(ctx.ast_slab) {
		slab_bytes := 1024
		if slab_bytes < size + align {
			slab_bytes = size + align
		}
		ctx.ast_slab = make([]byte, slab_bytes, ctx.allocator)
		off = 0
	}
	res := cast(^T)&ctx.ast_slab[off]
	ctx.ast_slab_off = off + size
	return res
}

@(private = "file")
push_trace_frame :: proc(ctx: ^Compile_Context, frame: Trace_Frame) -> int {
	if ctx.stack == nil && ctx.inline_stack_cnt < len(ctx.inline_stack) {
		idx := ctx.inline_stack_cnt
		ctx.inline_stack[idx] = frame
		ctx.inline_stack_cnt += 1
		return idx
	}
	if ctx.stack == nil {
		ctx.stack = make([dynamic]Trace_Frame, 0, len(ctx.inline_stack) * 2, ctx.allocator)
		for i in 0 ..< ctx.inline_stack_cnt {
			append(&ctx.stack, ctx.inline_stack[i])
		}
	}
	idx := len(ctx.stack)
	append(&ctx.stack, frame)
	return idx
}

@(private = "file")
pop_trace_frame :: proc(ctx: ^Compile_Context) {
	if ctx.stack != nil {
		pop(&ctx.stack)
	} else if ctx.inline_stack_cnt > 0 {
		ctx.inline_stack_cnt -= 1
	}
}

@(private = "file")
get_trace_frames :: proc(ctx: ^Compile_Context) -> []Trace_Frame {
	if ctx.stack != nil {
		return ctx.stack[:]
	}
	return ctx.inline_stack[:ctx.inline_stack_cnt]
}

@(private = "file")
set_trace_frame_snippet :: proc(ctx: ^Compile_Context, idx: int, snippet: string) {
	if ctx.stack != nil {
		ctx.stack[idx].snippet = snippet
	} else if idx >= 0 && idx < ctx.inline_stack_cnt {
		ctx.inline_stack[idx].snippet = snippet
	}
}

@(private = "file")
clear_trace_frames :: proc(ctx: ^Compile_Context) {
	if ctx.stack != nil {
		clear(&ctx.stack)
	}
	ctx.inline_stack_cnt = 0
}

Transpiled_Template :: struct {
	identifier:  string,
	code:        string,
	diagnostics: [dynamic]Diagnostic,
	ok:          bool,
}

VERSION :: "1.0.0"

Cli_Options :: struct {
	project_dir:   string,
	temple_dir:    string,
	out_file:      string,
	pkg_name:      string,
	temple_import: string,
	check_only:    bool,
	warn_unused:   bool,
	watch:         bool,
	show_version:  bool,
}

parse_cli_flag_kv :: proc(arg: string) -> (key: string, val: string, is_flag: bool, has_val: bool) {
	if !strings.has_prefix(arg, "-") {
		return "", "", false, false
	}
	trimmed := strings.trim_left(arg, "-")
	for i in 0 ..< len(trimmed) {
		if trimmed[i] == ':' || trimmed[i] == '=' {
			return trimmed[:i], trimmed[i+1:], true, true
		}
	}
	return trimmed, "", true, false
}

@(private)
is_abs_slash_path :: proc(path: string) -> bool {
	if strings.has_prefix(path, "/") || strings.has_prefix(path, "\\") {
		return true
	}
	if len(path) >= 3 && path[1] == ':' && (path[2] == '/' || path[2] == '\\') {
		return true
	}
	return filepath.is_abs(path)
}

@(private = "file")
slice_file_dir :: proc(file: string) -> string {
	if slash_idx := strings.last_index_any(file, "/\\"); slash_idx != -1 {
		if slash_idx == 0 {
			return file[:1]
		}
		return file[:slash_idx]
	}
	return "."
}

@(private)
clean_slash_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	norm := normalize_slash_path(path, allocator)
	if len(norm) == 0 {
		return "."
	}
	if !strings.contains(norm, "/.") && !strings.has_prefix(norm, "./") && !strings.has_prefix(norm, "../") && norm != "." && norm != ".." {
		if len(norm) > 1 && norm[len(norm)-1] == '/' {
			if !(len(norm) == 3 && norm[1] == ':' && norm[2] == '/') {
				return norm[:len(norm)-1]
			}
		}
		return norm
	}

	prefix := ""
	rest := norm
	if len(rest) >= 2 && rest[1] == ':' {
		if len(rest) >= 3 && rest[2] == '/' {
			prefix = rest[:3]
			rest = rest[3:]
		} else {
			prefix = rest[:2]
			rest = rest[2:]
		}
	} else if strings.has_prefix(rest, "/") {
		prefix = "/"
		rest = rest[1:]
	}
	rooted := strings.has_suffix(prefix, "/")

	segs_buf: [64]string
	seg_cnt := 0
	segs_var: [dynamic]string

	start := 0
	for i := 0; i <= len(rest); i += 1 {
		if i == len(rest) || rest[i] == '/' {
			part := rest[start:i]
			start = i + 1
			if len(part) == 0 || part == "." {
				continue
			}
			if part == ".." {
				cur_len := len(segs_var) if segs_var != nil else seg_cnt
				last_seg := ""
				if cur_len > 0 {
					last_seg = segs_var[cur_len-1] if segs_var != nil else segs_buf[cur_len-1]
				}
				if cur_len > 0 && last_seg != ".." {
					if segs_var != nil {
						pop(&segs_var)
					} else {
						seg_cnt -= 1
					}
				} else if !rooted {
					if segs_var != nil {
						append(&segs_var, "..")
					} else if seg_cnt < len(segs_buf) {
						segs_buf[seg_cnt] = ".."
						seg_cnt += 1
					} else {
						segs_var = make([dynamic]string, 0, seg_cnt * 2, allocator)
						for s in segs_buf {
							append(&segs_var, s)
						}
						append(&segs_var, "..")
					}
				}
				continue
			}
			if segs_var != nil {
				append(&segs_var, part)
			} else if seg_cnt < len(segs_buf) {
				segs_buf[seg_cnt] = part
				seg_cnt += 1
			} else {
				segs_var = make([dynamic]string, 0, seg_cnt * 2, allocator)
				for s in segs_buf {
					append(&segs_var, s)
				}
				append(&segs_var, part)
			}
		}
	}

	segs := segs_var[:] if segs_var != nil else segs_buf[:seg_cnt]
	if len(segs) == 0 {
		if len(prefix) > 0 {
			return prefix
		}
		return "."
	}

	total_len := len(prefix) + len(segs) - 1
	for s in segs {
		total_len += len(s)
	}
	sb := strings.builder_make(0, total_len, allocator)
	strings.write_string(&sb, prefix)
	for s, idx in segs {
		if idx > 0 {
			strings.write_byte(&sb, '/')
		}
		strings.write_string(&sb, s)
	}
	return strings.to_string(sb)
}

@(private)
join_relative_slash_path :: proc(origin_file, rel_path: string, allocator := context.temp_allocator) -> string {
	if !strings.has_prefix(rel_path, ".") && !strings.contains(rel_path, "/.") && !strings.contains(rel_path, "\\") {
		if slash_idx := strings.last_index_any(origin_file, "/\\"); slash_idx != -1 {
			dir_prefix := origin_file[:slash_idx + 1]
			return normalize_slash_path(strings.concatenate({dir_prefix, rel_path}, allocator), allocator)
		}
		return rel_path
	}
	base_dir := slice_file_dir(origin_file)
	if base_dir == "." {
		return clean_slash_path(rel_path, allocator)
	}
	if base_dir == "/" || base_dir == "\\" {
		return clean_slash_path(strings.concatenate({"/", rel_path}, allocator), allocator)
	}
	return clean_slash_path(strings.concatenate({base_dir, "/", rel_path}, allocator), allocator)
}

normalize_slash_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	if len(path) == 0 {
		return ""
	}
	needs_norm := false
	for i in 0 ..< len(path) {
		c := path[i]
		if c == '\\' || (c == '/' && i + 1 < len(path) && path[i + 1] == '/') {
			needs_norm = true
			break
		}
	}
	if !needs_norm {
		return path
	}
	sb := strings.builder_make(0, len(path), allocator)
	prev_slash := false
	for i in 0 ..< len(path) {
		c := path[i]
		if c == '\\' {
			c = '/'
		}
		if c == '/' {
			if prev_slash {
				continue
			}
			prev_slash = true
		} else {
			prev_slash = false
		}
		strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}

is_generated_temple_source :: proc(src: string) -> bool {
	trimmed := strings.trim_left_space(src)
	return strings.has_prefix(trimmed, "/* This file was generated by temple on ") ||
		strings.has_prefix(trimmed, "/* This file is generated by temple - DO NOT EDIT! */")
}

infer_package_from_odin_source :: proc(src: string, allocator := context.temp_allocator) -> (string, bool) {
	t: tokenizer.Tokenizer
	tokenizer.init(&t, src, "infer.odin", odin_silent_err_handler)
	tok := tokenizer.scan(&t)
	if tok.kind != .Package {
		return "", false
	}
	name_tok := tokenizer.scan(&t)
	if name_tok.kind != .Ident || len(name_tok.text) == 0 {
		return "", false
	}
	return strings.clone(name_tok.text, allocator), true
}

is_valid_odin_pkg_ident :: proc(s: string) -> bool {
	return is_valid_block_ident(s) && s != "_"
}

sanitize_package_ident :: proc(raw: string, allocator := context.temp_allocator) -> (string, bool) {
	trimmed := strings.trim_space(raw)
	if len(trimmed) == 0 {
		return "", false
	}

	sb := strings.builder_make(0, len(trimmed) + 1, allocator)
	if trimmed[0] >= '0' && trimmed[0] <= '9' {
		strings.write_byte(&sb, '_')
	}

	has_alnum := false
	for i in 0 ..< len(trimmed) {
		c := trimmed[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			has_alnum = true
			strings.write_byte(&sb, c)
		} else {
			strings.write_byte(&sb, '_')
		}
	}

	res := strings.to_string(sb)
	if !has_alnum || !is_valid_odin_pkg_ident(res) {
		return "", false
	}
	return res, true
}

should_skip_walk_dir :: proc(name: string) -> bool {
	if strings.has_prefix(name, ".") {
		return true
	}
	switch name {
	case "vendor", "node_modules", "build", "bin", "dist":
		return true
	}
	return false
}

infer_package_from_dir :: proc(
	dir_path: string,
	exclude_file := "",
	allocator := context.temp_allocator,
) -> (
	string,
	bool,
) {
	prev_alloc := context.allocator
	context.allocator = allocator
	defer context.allocator = prev_alloc

	exclude_base := filepath.base(exclude_file) if len(exclude_file) > 0 else ""

	if dir_handle, open_err := os.open(dir_path); open_err == nil {
		entries, read_err := os.read_dir(dir_handle, -1, allocator)
		os.close(dir_handle)
		if read_err == nil && len(entries) > 0 {
			matches := make([dynamic]string, 0, len(entries), allocator)
			for entry in entries {
				if entry.type != .Directory && strings.has_suffix(entry.name, ".odin") {
					if entry.name == "templates.odin" || (len(exclude_base) > 0 && entry.name == exclude_base) {
						continue
					}
					append(&matches, entry.fullpath)
				}
			}
			slice.sort(matches[:])
			for match in matches {
				if data, rerr := os.read_entire_file(match, allocator); rerr == nil {
					src := string(data)
					if is_generated_temple_source(src) {
						continue
					}
					if pkg_name, ok := infer_package_from_odin_source(src, allocator); ok {
						return pkg_name, true
					}
				}
			}
		}
	}

	base := filepath.base(dir_path)
	if len(base) > 0 && base != "." && base != ".." && base != "/" && base != "\\" {
		return sanitize_package_ident(base, allocator)
	}
	return "", false
}

parse_cli_args :: proc(
	args: []string,
	allocator := context.temp_allocator,
) -> (
	opts: Cli_Options,
	err_msg: string,
	ok: bool,
) {
	prev_alloc := context.allocator
	context.allocator = allocator
	defer context.allocator = prev_alloc

	if len(args) == 2 && (args[1] == "--version" || args[1] == "-v") {
		opts.show_version = true
		return opts, "", true
	}

	positionals := make([dynamic]string, 0, 2, allocator)

	for arg in args[1:] {
		if arg == "--version" || arg == "-v" {
			opts.show_version = true
			return opts, "", true
		}

		key, val, is_flag, has_val := parse_cli_flag_kv(arg)
		if is_flag {
			switch key {
			case "out":
				if !has_val || len(val) == 0 {
					return opts, "flag `-out` requires a non-empty file path (e.g. `-out:views/templates.odin`)", false
				}
				opts.out_file = val
			case "pkg":
				if !has_val || len(val) == 0 {
					return opts, "flag `-pkg` requires a non-empty package name (e.g. `-pkg:views`)", false
				}
				if !is_valid_odin_pkg_ident(val) {
					return opts, fmt.aprintf("invalid package name %q for `-pkg`: must be a valid Odin identifier", val, allocator = allocator), false
				}
				opts.pkg_name = val
			case "temple-import":
				if !has_val || len(val) == 0 {
					return opts, "flag `-temple-import` requires a non-empty import path (e.g. `-temple-import:shared:temple`)", false
				}
				opts.temple_import = val
			case "check":
				if has_val && val != "true" && val != "false" {
					return opts, "flag `--check` does not take a value", false
				}
				opts.check_only = !has_val || val == "true"
			case "warn-unused":
				if has_val && val != "true" && val != "false" {
					return opts, "flag `--warn-unused` does not take a value", false
				}
				opts.warn_unused = !has_val || val == "true"
			case "watch":
				if has_val && val != "true" && val != "false" {
					return opts, "flag `--watch` does not take a value", false
				}
				opts.watch = !has_val || val == "true"
			case:
				return opts, fmt.aprintf("unknown CLI flag %q", arg, allocator = allocator), false
			}
		} else {
			append(&positionals, arg)
		}
	}

	if opts.check_only && opts.watch {
		return opts, "flags `--check` and `--watch` cannot be used together", false
	}

	if len(positionals) == 0 {
		return opts, "You need to pass a path and the path to temple (or `-out:<file>`)", false
	}

	opts.project_dir = positionals[0]
	if len(positionals) >= 2 {
		opts.temple_dir = positionals[1]
	}

	if len(opts.out_file) == 0 {
		if len(opts.temple_dir) == 0 {
			return opts, "You need to pass a path and the path to temple (or `-out:<file>`)", false
		}
		joined_out, _ := filepath.join({opts.temple_dir, "templates.odin"}, allocator)
		opts.out_file = normalize_slash_path(joined_out, allocator)
	}

	if len(opts.pkg_name) == 0 {
		default_temple_out := normalize_slash_path(fmt.aprintf("%s/templates.odin", opts.temple_dir, allocator = allocator), allocator)
		if len(opts.temple_dir) > 0 && normalize_slash_path(opts.out_file, allocator) == default_temple_out {
			opts.pkg_name = "temple"
		} else {
			out_dir := filepath.dir(opts.out_file)
			if inferred, inf_ok := infer_package_from_dir(out_dir, opts.out_file, allocator); inf_ok {
				opts.pkg_name = inferred
			} else {
				opts.pkg_name = "temple"
			}
		}
	}

	if opts.pkg_name != "temple" && len(opts.temple_import) == 0 {
		opts.temple_import = "shared:temple"
	}

	return opts, "", true
}

run_cli_once :: proc(opts: Cli_Options, out_used_files: ^[dynamic]string = nil) -> bool {
	collect_errs := make([dynamic]string, context.temp_allocator)
	calls := collect_compile_calls(opts.project_dir, context.allocator, &collect_errs)
	defer delete(calls)

	if len(collect_errs) > 0 {
		for msg in collect_errs {
			fmt.eprintf("\x1b[0;31mTemple Error:\x1b[0m %s\n", msg)
		}
		free_all(context.temp_allocator)
		return false
	}
	free_all(context.temp_allocator)

	return transpile_calls(opts.temple_dir, calls[:], opts, out_used_files)
}

main :: proc() {
	opts, err_msg, ok := parse_cli_args(os.args, context.allocator)
	if !ok {
		error(nil, "%s", err_msg)
	}
	if opts.show_version {
		fmt.printf("temple %s\n", VERSION)
		return
	}

	if opts.watch {
		watch_workspace(opts)
		return
	}

	if !run_cli_once(opts) {
		os.exit(1)
	}
}

warn :: proc(pos: Maybe(tokenizer.Pos), msg: string, args: ..any) {
	if p, ok := pos.?; ok {
		fmt.eprintf("%s(%i:%i) \x1b[0;33mTemple Warning:\x1b[0m ", p.file, p.line, p.column)
	} else {
		fmt.eprint("\x1b[0;33mTemple Warning:\x1b[0m ")
	}

	fmt.eprintf(msg, ..args)
	fmt.eprint("\n")
}

error :: proc(pos: Maybe(tokenizer.Pos), msg: string, args: ..any) -> ! {
	if p, ok := pos.?; ok {
		fmt.eprintf("%s(%i:%i) \x1b[0;31mTemple Error:\x1b[0m ", p.file, p.line, p.column)
	} else {
		fmt.eprint("\x1b[0;31mTemple Error:\x1b[0m ")
	}

	fmt.eprintf(msg, ..args)
	fmt.eprint("\n")
	os.exit(1)
}

print_diagnostic :: proc(d: Diagnostic) {
	fmt.eprintf("\x1b[1;31merror\x1b[0m: %s\n", d.message)
	if len(d.pos.file) > 0 {
		fmt.eprintf("  \x1b[1;34m-->\x1b[0m %s:%i:%i\n", d.pos.file, d.pos.line, d.pos.column)
	}
	if len(d.snippet) > 0 && d.pos.line > 0 {
		line_str := fmt.tprintf("%i", d.pos.line)
		pad := strings.repeat(" ", len(line_str), context.temp_allocator)
		fmt.eprintf("   %s \x1b[1;34m|\x1b[0m\n", pad)
		fmt.eprintf("   \x1b[1;34m%s |\x1b[0m %s\n", line_str, d.snippet)
		col := d.caret_col if d.caret_col > 0 else d.pos.column
		caret_offset := max(col - 1, 0)
		caret_pad := strings.repeat(" ", caret_offset, context.temp_allocator)
		caret_len := max(d.col_len, 1)
		carets := strings.repeat("^", caret_len, context.temp_allocator)
		fmt.eprintf("   %s \x1b[1;34m|\x1b[0m %s\x1b[1;31m%s\x1b[0m\n", pad, caret_pad, carets)
	}

	// Walk trace in reverse from leaf back to root Odin call site
	#reverse for frame in d.trace {
		switch frame.kind {
		case .Embed:
			fmt.eprintf("  \x1b[1;34m=\x1b[0m embedded from %s:%i:%i\n", frame.pos.file, frame.pos.line, frame.pos.column)
		case .Extends:
			fmt.eprintf("  \x1b[1;34m=\x1b[0m extended from %s:%i:%i\n", frame.pos.file, frame.pos.line, frame.pos.column)
		case .Call_Site:
			fmt.eprintf("  \x1b[1;34m=\x1b[0m required by `temple.compiled` at %s:%i:%i\n", frame.pos.file, frame.pos.line, frame.pos.column)
		}
	}
}

extract_line_snippet :: proc(source: []byte, one_based_line: int, allocator := context.temp_allocator) -> string {
	if len(source) == 0 || one_based_line <= 0 {
		return ""
	}
	curr_line := 1
	for i := 0; i < len(source); i += 1 {
		if curr_line == one_based_line {
			line_end := i
			for line_end < len(source) && source[line_end] != '\n' && source[line_end] != '\r' {
				line_end += 1
			}
			// Replace tabs with single spaces so column alignment matches
			raw_line := string(source[i:line_end])
			res, _ := strings.replace_all(raw_line, "\t", " ", allocator)
			return res
		}
		if source[i] == '\n' {
			curr_line += 1
		}
	}
	return ""
}

clone_diagnostic :: proc(d: Diagnostic, allocator: mem.Allocator) -> Diagnostic {
	cd := d
	cd.pos.file = strings.clone(d.pos.file, allocator)
	cd.message = strings.clone(d.message, allocator)
	cd.snippet = strings.clone(d.snippet, allocator)
	frames := make([]Trace_Frame, len(d.trace), allocator)
	for f, i in d.trace {
		frames[i] = f
		frames[i].pos.file = strings.clone(f.pos.file, allocator)
		frames[i].file = strings.clone(f.file, allocator)
		frames[i].snippet = strings.clone(f.snippet, allocator)
	}
	cd.trace = frames
	return cd
}

destroy_diagnostic :: proc(d: Diagnostic, allocator := context.allocator) {
	delete(d.pos.file, allocator)
	delete(d.message, allocator)
	delete(d.snippet, allocator)
	for f in d.trace {
		delete(f.pos.file, allocator)
		delete(f.file, allocator)
		delete(f.snippet, allocator)
	}
	delete(d.trace, allocator)
}

record_diagnostic :: proc(
	ctx: ^Compile_Context,
	pos: tokenizer.Pos,
	source: []byte,
	col_len: int,
	msg: string,
	args: ..any,
	snippet_line := 0,
	snippet_col := 0,
) {
	context.allocator = ctx.allocator
	d: Diagnostic
	d.pos = pos
	target_line := snippet_line if snippet_line > 0 else pos.line
	target_col := snippet_col if snippet_col > 0 else pos.column
	if len(ctx.inline_file) > 0 && pos.file == ctx.inline_file && snippet_line == 0 {
		// Map 1-based inline template coordinates to the Odin call site's file coordinates
		zero_line := max(pos.line - 1, 0)
		zero_col := max(pos.column - 1, 0)
		d.pos.line = ctx.inline_pos.line + zero_line
		d.pos.column = (ctx.inline_pos.column + zero_col) if zero_line == 0 else (zero_col + 1)
		target_line = pos.line
		target_col = pos.column
	}
	d.pos.file = normalize_slash_path(d.pos.file, ctx.allocator)
	d.message = fmt.aprintf(msg, ..args)
	d.snippet = extract_line_snippet(source, target_line, ctx.allocator)
	d.caret_col = target_col
	d.col_len = max(col_len, 1)

	active_frames := get_trace_frames(ctx)
	frames := make([]Trace_Frame, len(active_frames), ctx.allocator)
	for f, i in active_frames {
		frames[i] = f
		if len(ctx.inline_file) > 0 && f.pos.file == ctx.inline_file && f.kind != .Call_Site {
			zero_line := max(f.pos.line - 1, 0)
			zero_col := max(f.pos.column - 1, 0)
			frames[i].pos.line = ctx.inline_pos.line + zero_line
			frames[i].pos.column = (ctx.inline_pos.column + zero_col) if zero_line == 0 else (zero_col + 1)
		}
		frames[i].pos.file = normalize_slash_path(f.pos.file, ctx.allocator)
		frames[i].file = normalize_slash_path(f.file, ctx.allocator)
		frames[i].snippet = strings.clone(f.snippet, ctx.allocator)
	}
	d.trace = frames
	append(&ctx.diagnostics, d)
}

// ============================================================================
// Stage 1: Collect `compiled` and `compiled_inline` Calls
// ============================================================================

collect_compile_calls :: proc(
	root: string,
	allocator := context.allocator,
	out_errors: ^[dynamic]string = nil,
) -> (
	calls: [dynamic]Compile_Call,
) {
	calls.allocator = allocator
	seen_identifiers := make(map[string]string, context.temp_allocator)

	context.allocator = context.temp_allocator

	fmt.printf("looking for compile calls in %q\n", root)

	// TODO: does not support symbolic links, communicate it to users.

	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, root)

	w := filepath.walker_create(root)
	defer filepath.walker_destroy(&w)

	for info in filepath.walker_walk(&w) {
		if path, err := filepath.walker_error(&w); err != nil {
			warn(nil, "%q error: %v", path, err)
			continue
		}

		if info.type != .Directory {
			continue
		}

		if info.fullpath == root {
			continue
		}

		if should_skip_walk_dir(info.name) {
			filepath.walker_skip_dir(&w)
			continue
		}

		append(&dirs, strings.clone(info.fullpath, context.temp_allocator))
	}

	if path, err := filepath.walker_error(&w); err != nil {
		warn(nil, "%q error: %v", path, err)
	}

	slice.sort(dirs[1:])
	for dir_path in dirs {
		collect_from_dir(dir_path, &calls, &seen_identifiers, allocator, out_errors)
	}

	return
}

Odin_Candidate_File :: struct {
	fullpath: string,
	src:      string,
	ast_file: ^ast.File,
}

collect_from_dir :: proc(
	dir_path: string,
	calls: ^[dynamic]Compile_Call,
	seen_identifiers: ^map[string]string,
	out_allocator: mem.Allocator,
	out_errors: ^[dynamic]string = nil,
) {
	pkg_path, pkg_path_err := os.get_absolute_path(dir_path, context.temp_allocator)
	if pkg_path_err != nil {
		return
	}

	dir_handle, open_err := os.open(pkg_path)
	if open_err != nil {
		return
	}
	entries, read_err := os.read_dir(dir_handle, -1, context.temp_allocator)
	os.close(dir_handle)
	if read_err != nil || len(entries) == 0 {
		return
	}

	matches := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if entry.type != .Directory && strings.has_suffix(entry.name, ".odin") {
			append(&matches, entry.fullpath)
		}
	}
	if len(matches) == 0 {
		return
	}
	slice.sort(matches[:])

	// Read files in this package; check if any file in the package mentions "temple"
	raw_files := make([dynamic]Odin_Candidate_File, context.temp_allocator)
	pkg_mentions_temple := false

	for match in matches {
		fullpath, fp_err := os.get_absolute_path(match, context.temp_allocator)
		if fp_err != nil {
			continue
		}
		// Skip generated templates.odin itself
		if filepath.base(fullpath) == "templates.odin" {
			continue
		}

		src_bytes, rerr := os.read_entire_file(fullpath, context.temp_allocator)
		if rerr != nil {
			continue
		}
		src := string(src_bytes)
		if strings.trim_space(src) == "" || is_generated_temple_source(src) {
			continue
		}
		if strings.contains(src, "temple") || strings.contains(src, "compiled") {
			pkg_mentions_temple = true
		}
		append(&raw_files, Odin_Candidate_File{fullpath = fullpath, src = src})
	}

	// Fast pre-filter: if no file in this package mentions "temple", skip AST parsing completely
	if !pkg_mentions_temple {
		return
	}

	NO_POS :: tokenizer.Pos{}
	pkg := ast.new(ast.Package, NO_POS, NO_POS)
	pkg.fullpath = pkg_path

	p := odin_parser.default_parser()
	p.err = odin_silent_err_handler
	p.warn = odin_silent_warn_handler

	// Parse files in the package that either mention "temple" or define constants
	parsed_files := make([dynamic]^ast.File, context.temp_allocator)
	for &rf in raw_files {
		file := ast.new(ast.File, NO_POS, NO_POS)
		file.pkg = pkg
		file.src = rf.src
		file.fullpath = rf.fullpath
		if odin_parser.parse_file(&p, file) {
			append(&parsed_files, file)
		}
	}

	if len(parsed_files) == 0 {
		return
	}

	collect_calls_from_parsed_files(
		pkg_path,
		parsed_files[:],
		calls,
		seen_identifiers,
		out_allocator,
		out_errors,
		context.temp_allocator,
	)
}

collect_calls_from_parsed_files :: proc(
	pkg_fullpath: string,
	parsed_files: []^ast.File,
	calls: ^[dynamic]Compile_Call,
	seen_identifiers: ^map[string]string,
	out_allocator: mem.Allocator,
	out_errors: ^[dynamic]string = nil,
	allocator := context.temp_allocator,
) {
	// Pass 1: Build per-file temple import alias table and package-level constant tables
	file_temple_pkgs := make([][dynamic]string, len(parsed_files), allocator)
	file_strict_temple_pkgs := make([][dynamic]string, len(parsed_files), allocator)
	pkg_string_consts: map[string]^ast.Expr
	pkg_proc_aliases: map[string]Temple_Proc_Kind

	has_any_temple_import := false

	for file, file_idx in parsed_files {
		import_names := make([dynamic]string, 0, max(len(file.imports), 2), allocator)
		strict_names := make([dynamic]string, 0, max(len(file.imports) + 1, 2), allocator)
		append(&strict_names, "temple")
		for imp in file.imports {
			trimmed_path := strings.trim(imp.fullpath, "\"`")
			if strings.has_prefix(trimmed_path, "core:") ||
				strings.has_prefix(trimmed_path, "base:") ||
				strings.has_prefix(trimmed_path, "vendor:") {
				continue
			}
			base_pkg := trimmed_path
			if colon_idx := strings.last_index_byte(base_pkg, ':'); colon_idx != -1 {
				base_pkg = base_pkg[colon_idx+1:]
			}
			base_pkg = strings.trim_right(base_pkg, "/\\")
			if slash_idx := strings.last_index_any(base_pkg, "/\\"); slash_idx != -1 {
				base_pkg = base_pkg[slash_idx+1:]
			}
			alias := imp.name.text if len(imp.name.text) > 0 else base_pkg
			if len(alias) > 0 && alias != "." && alias != ".." {
				has_any_temple_import = true
				append(&import_names, alias)
				if base_pkg == "temple" || alias == "temple" {
					append(&strict_names, alias)
				}
			}
		}
		file_temple_pkgs[file_idx] = import_names
		file_strict_temple_pkgs[file_idx] = strict_names

		// Collect top-level constant declarations
		for decl in file.decls {
			collect_top_level_consts(decl, &pkg_string_consts, allocator)
		}
	}

	// If no file in this package imports temple, fallback to allowing "temple" identifier
	// in case the user is in a sub-file or test setup without standard import path suffix
	if !has_any_temple_import {
		for file, file_idx in parsed_files {
			if strings.contains(file.src, "temple") {
				append(&file_temple_pkgs[file_idx], "temple")
			}
		}
	}

	// Resolve constant procedure aliases (e.g. `c :: temple.compiled` or `ci :: t.compiled_inline`)
	// Iteratively resolve aliases in case of chained aliases `c1 :: temple.compiled; c2 :: c1`
	for _ in 0 ..< 3 {
		for file, file_idx in parsed_files {
			strict_names := file_strict_temple_pkgs[file_idx]
			for decl in file.decls {
				collect_proc_aliases(decl, strict_names[:], &pkg_proc_aliases, allocator)
			}
		}
	}

	// Evaluate package-level string constants
	resolved_consts: map[string]string
	visited: map[string]bool
	for name, expr in pkg_string_consts {
		if visited.allocator.procedure != nil {
			clear(&visited)
		}
		if val, ok := eval_const_string_from_ast(expr, pkg_string_consts, &visited, allocator); ok {
			if resolved_consts.allocator.procedure == nil {
				resolved_consts = make(map[string]string, allocator)
			}
			resolved_consts[name] = val
		}
	}

	// Pass 2: Walk only files that import temple or reference a package-level temple alias
	for file, file_idx in parsed_files {
		temple_names := file_temple_pkgs[file_idx]
		strict_names := file_strict_temple_pkgs[file_idx]
		if len(temple_names) == 0 && len(pkg_proc_aliases) == 0 && !strings.contains(file.src, "compiled") {
			continue
		}

		walk_ctx := File_Collect_Ctx {
			pkg_fullpath        = pkg_fullpath,
			file                = file,
			temple_names        = temple_names[:],
			strict_temple_names = strict_names[:],
			proc_aliases        = pkg_proc_aliases,
			string_consts       = resolved_consts,
			raw_const_exprs     = pkg_string_consts,
			calls               = calls,
			seen                = seen_identifiers,
			out_allocator       = out_allocator,
			out_errors          = out_errors,
			owns_proc_aliases   = false,
			owns_string_consts  = false,
		}

		v := ast.Visitor {
			data  = &walk_ctx,
			visit = visit_odin_node,
		}
		for decl in file.decls {
			if decl != nil && decl.pos.offset >= 0 && decl.end.offset > decl.pos.offset && decl.end.offset <= len(file.src) {
				if vdecl, is_vd := decl.derived_stmt.(^ast.Value_Decl); is_vd && !vdecl.is_mutable {
					all_procs := len(vdecl.values) > 0
					for val in vdecl.values {
						if _, is_proc := val.derived_expr.(^ast.Proc_Lit); !is_proc {
							all_procs = false
							break
						}
					}
					if all_procs {
						span := file.src[decl.pos.offset : decl.end.offset]
						has_candidate := strings.index(span, "compiled") != -1
						if !has_candidate && strings.index(span, "::") != -1 {
							for t_name in temple_names {
								if strings.index(span, t_name) != -1 {
									has_candidate = true
									break
								}
							}
						}
						if !has_candidate && len(pkg_proc_aliases) > 0 {
							for alias_name, kind in pkg_proc_aliases {
								if kind != .None && strings.index(span, alias_name) != -1 {
									has_candidate = true
									break
								}
							}
						}
						if !has_candidate {
							continue
						}
					}
				}
			}
			ast.walk(&v, decl)
		}
	}
}

clone_proc_aliases :: proc(src: map[string]Temple_Proc_Kind, allocator := context.temp_allocator) -> map[string]Temple_Proc_Kind {
	res := make(map[string]Temple_Proc_Kind, len(src), allocator)
	for k, v in src {
		res[k] = v
	}
	return res
}

clone_string_consts :: proc(src: map[string]string, allocator := context.temp_allocator) -> map[string]string {
	res := make(map[string]string, len(src), allocator)
	for k, v in src {
		res[k] = v
	}
	return res
}

collect_top_level_consts :: proc(stmt: ^ast.Stmt, out_consts: ^map[string]^ast.Expr, allocator := context.temp_allocator) {
	if stmt == nil do return
	#partial switch d in stmt.derived_stmt {
	case ^ast.Value_Decl:
		if d.is_mutable do return
		for name_expr, i in d.names {
			if i >= len(d.values) do break
			if _, is_proc := d.values[i].derived_expr.(^ast.Proc_Lit); is_proc do continue
			if ident, ok := name_expr.derived_expr.(^ast.Ident); ok {
				if out_consts.allocator.procedure == nil {
					out_consts^ = make(map[string]^ast.Expr, allocator)
				}
				out_consts[ident.name] = d.values[i]
			}
		}
	case ^ast.When_Stmt:
		if d.body != nil {
			if blk, ok := d.body.derived_stmt.(^ast.Block_Stmt); ok {
				for s in blk.stmts {
					collect_top_level_consts(s, out_consts, allocator)
				}
			}
		}
		if d.else_stmt != nil {
			if blk, ok := d.else_stmt.derived_stmt.(^ast.Block_Stmt); ok {
				for s in blk.stmts {
					collect_top_level_consts(s, out_consts, allocator)
				}
			} else {
				collect_top_level_consts(d.else_stmt, out_consts, allocator)
			}
		}
	}
}

collect_proc_aliases :: proc(
	stmt: ^ast.Stmt,
	temple_names: []string,
	proc_aliases: ^map[string]Temple_Proc_Kind,
	allocator := context.temp_allocator,
) {
	if stmt == nil do return
	#partial switch d in stmt.derived_stmt {
	case ^ast.Value_Decl:
		if d.is_mutable {
			for name_expr in d.names {
				if ident, ok := name_expr.derived_expr.(^ast.Ident); ok {
					if ident.name == "compiled" || ident.name == "compiled_inline" {
						if proc_aliases.allocator.procedure == nil {
							proc_aliases^ = make(map[string]Temple_Proc_Kind, allocator)
						}
						proc_aliases[ident.name] = .None
					} else if proc_aliases.allocator.procedure != nil {
						delete_key(proc_aliases, ident.name)
					}
				}
			}
			return
		}
		for name_expr, i in d.names {
			if i >= len(d.values) do break
			if _, is_proc := d.values[i].derived_expr.(^ast.Proc_Lit); is_proc do continue
			ident, ok := name_expr.derived_expr.(^ast.Ident)
			if !ok do continue
			val := ast.unparen_expr(d.values[i])
			kind := resolve_temple_proc_expr(val, temple_names, proc_aliases^)
			if kind != .None {
				if proc_aliases.allocator.procedure == nil {
					proc_aliases^ = make(map[string]Temple_Proc_Kind, allocator)
				}
				proc_aliases[ident.name] = kind
			} else if ident.name == "compiled" || ident.name == "compiled_inline" {
				if proc_aliases.allocator.procedure == nil {
					proc_aliases^ = make(map[string]Temple_Proc_Kind, allocator)
				}
				proc_aliases[ident.name] = .None
			} else if proc_aliases.allocator.procedure != nil {
				delete_key(proc_aliases, ident.name)
			}
		}
	}
}

resolve_temple_proc_expr :: proc(
	expr: ^ast.Expr,
	temple_names: []string,
	proc_aliases: map[string]Temple_Proc_Kind,
) -> Temple_Proc_Kind {
	if expr == nil do return .None
	expr := ast.unparen_expr(expr)

	#partial switch e in expr.derived_expr {
	case ^ast.Selector_Expr:
		ident, iok := e.expr.derived_expr.(^ast.Ident)
		if !iok do return .None
		is_temple_pkg := false
		for tn in temple_names {
			if ident.name == tn {
				is_temple_pkg = true
				break
			}
		}
		if !is_temple_pkg do return .None
		switch e.field.name {
		case "compiled":
			return .Compiled
		case "compiled_inline":
			return .Compiled_Inline
		}
	case ^ast.Ident:
		if kind, found := proc_aliases[e.name]; found {
			return kind
		}
		switch e.name {
		case "compiled":
			return .Compiled
		case "compiled_inline":
			return .Compiled_Inline
		}
	}
	return .None
}

eval_const_string_from_ast :: proc(
	expr: ^ast.Expr,
	const_exprs: map[string]^ast.Expr,
	visited: ^map[string]bool,
	allocator := context.temp_allocator,
) -> (string, bool) {
	if expr == nil do return "", false
	expr := ast.unparen_expr(expr)

	#partial switch e in expr.derived_expr {
	case ^ast.Basic_Lit:
		if e.tok.kind == .String {
			return unquote_odin_string(e.tok.text)
		}
	case ^ast.Binary_Expr:
		if e.op.kind == .Add {
			lhs, lok := eval_const_string_from_ast(e.left, const_exprs, visited, allocator)
			if !lok do return "", false
			rhs, rok := eval_const_string_from_ast(e.right, const_exprs, visited, allocator)
			if !rok do return "", false
			return strings.concatenate({lhs, rhs}, allocator), true
		}
	case ^ast.Ident:
		if visited[e.name] {
			return "", false
		}
		if target, ok := const_exprs[e.name]; ok {
			if visited.allocator.procedure == nil {
				visited^ = make(map[string]bool, allocator)
			}
			visited[e.name] = true
			defer delete_key(visited, e.name)
			return eval_const_string_from_ast(target, const_exprs, visited, allocator)
		}
	}
	return "", false
}

eval_const_string :: proc(
	expr: ^ast.Expr,
	consts: map[string]string,
	const_exprs: map[string]^ast.Expr,
) -> (string, bool) {
	if expr == nil do return "", false
	expr := ast.unparen_expr(expr)

	#partial switch e in expr.derived_expr {
	case ^ast.Basic_Lit:
		if e.tok.kind == .String {
			return unquote_odin_string(e.tok.text)
		}
	case ^ast.Binary_Expr:
		if e.op.kind == .Add {
			lhs, lok := eval_const_string(e.left, consts, const_exprs)
			if !lok do return "", false
			rhs, rok := eval_const_string(e.right, consts, const_exprs)
			if !rok do return "", false
			return strings.concatenate({lhs, rhs}, context.temp_allocator), true
		}
	case ^ast.Ident:
		if val, found := consts[e.name]; found {
			return val, true
		}
		return "", false
	}
	return "", false
}

unquote_odin_string :: proc(lit: string) -> (string, bool) {
	if len(lit) < 2 {
		return "", false
	}
	if lit[0] == '`' && lit[len(lit)-1] == '`' {
		return lit[1 : len(lit)-1], true
	}
	if lit[0] == '"' && lit[len(lit)-1] == '"' {
		if strings.index_byte(lit[1 : len(lit)-1], '\\') == -1 {
			return lit[1 : len(lit)-1], true
		}
		res, allocated, ok := strconv.unquote_string(lit, context.temp_allocator)
		_ = allocated
		return res, ok
	}
	return "", false
}

is_strict_temple_call :: proc(
	expr: ^ast.Expr,
	strict_temple_names: []string,
	proc_aliases: map[string]Temple_Proc_Kind,
) -> bool {
	if expr == nil do return false
	expr := ast.unparen_expr(expr)

	#partial switch e in expr.derived_expr {
	case ^ast.Selector_Expr:
		ident, iok := e.expr.derived_expr.(^ast.Ident)
		if !iok do return false
		if ident.name == "temple" do return true
		for tn in strict_temple_names {
			if ident.name == tn do return true
		}
		return false
	case ^ast.Ident:
		if kind, found := proc_aliases[e.name]; found {
			return kind != .None
		}
		return e.name == "compiled" || e.name == "compiled_inline"
	}
	return false
}

File_Collect_Ctx :: struct {
	pkg_fullpath:        string,
	file:                ^ast.File,
	temple_names:        []string,
	strict_temple_names: []string,
	proc_aliases:        map[string]Temple_Proc_Kind,
	string_consts:       map[string]string,
	raw_const_exprs:     map[string]^ast.Expr,
	calls:               ^[dynamic]Compile_Call,
	seen:                ^map[string]string,
	out_allocator:       mem.Allocator,
	out_errors:          ^[dynamic]string,
	owns_proc_aliases:   bool,
	owns_string_consts:  bool,
}

@(private = "file")
ensure_owned_proc_aliases :: proc(ctx: ^File_Collect_Ctx) {
	if !ctx.owns_proc_aliases {
		ctx.proc_aliases = clone_proc_aliases(ctx.proc_aliases, context.temp_allocator)
		ctx.owns_proc_aliases = true
	}
}

@(private = "file")
ensure_owned_string_consts :: proc(ctx: ^File_Collect_Ctx) {
	if !ctx.owns_string_consts {
		ctx.string_consts = clone_string_consts(ctx.string_consts, context.temp_allocator)
		ctx.owns_string_consts = true
	}
}

@(private = "file")
ctx_set_proc_alias :: proc(ctx: ^File_Collect_Ctx, name: string, kind: Temple_Proc_Kind) {
	ensure_owned_proc_aliases(ctx)
	ctx.proc_aliases[name] = kind
	ctx_delete_string_const(ctx, name)
}

@(private = "file")
ctx_set_string_const :: proc(ctx: ^File_Collect_Ctx, name: string, val: string) {
	ensure_owned_string_consts(ctx)
	ctx.string_consts[name] = val
	ctx_delete_proc_alias(ctx, name)
}

@(private = "file")
ctx_delete_proc_alias :: proc(ctx: ^File_Collect_Ctx, name: string) {
	if name == "compiled" || name == "compiled_inline" {
		if kind, found := ctx.proc_aliases[name]; !found || kind != .None {
			ensure_owned_proc_aliases(ctx)
			ctx.proc_aliases[name] = .None
		}
		return
	}
	if _, found := ctx.proc_aliases[name]; found {
		ensure_owned_proc_aliases(ctx)
		delete_key(&ctx.proc_aliases, name)
	}
}

@(private = "file")
ctx_delete_string_const :: proc(ctx: ^File_Collect_Ctx, name: string) {
	if _, found := ctx.string_consts[name]; found {
		ensure_owned_string_consts(ctx)
		delete_key(&ctx.string_consts, name)
	}
}

@(private = "file")
ctx_shadow_ident :: proc(ctx: ^File_Collect_Ctx, name: string) {
	ctx_delete_string_const(ctx, name)
	ctx_delete_proc_alias(ctx, name)
}

collect_error :: proc(ctx: ^File_Collect_Ctx, pos: tokenizer.Pos, msg: string, args: ..any) {
	if ctx.out_errors != nil {
		prev_alloc := context.allocator
		context.allocator = ctx.out_allocator
		defer context.allocator = prev_alloc
		append(ctx.out_errors, fmt.aprintf(msg, ..args))
		return
	}
	error(pos, msg, ..args)
}

precollect_scope_consts :: proc(stmts: []^ast.Stmt, ctx: ^File_Collect_Ctx) {
	has_const_decl := false
	for stmt in stmts {
		if stmt == nil do continue
		if vdecl, ok := stmt.derived_stmt.(^ast.Value_Decl); ok && !vdecl.is_mutable {
			has_const_decl = true
			break
		}
	}
	if !has_const_decl do return

	for _ in 0 ..< 2 {
		for stmt in stmts {
			if stmt == nil do continue
			if vdecl, ok := stmt.derived_stmt.(^ast.Value_Decl); ok && !vdecl.is_mutable {
				for name_expr, i in vdecl.names {
					if i >= len(vdecl.values) do break
					if ident, iok := name_expr.derived_expr.(^ast.Ident); iok {
						val_expr := vdecl.values[i]
						if kind := resolve_temple_proc_expr(val_expr, ctx.temple_names, ctx.proc_aliases); kind != .None {
							ctx_set_proc_alias(ctx, ident.name, kind)
						} else if str_val, sok := eval_const_string(val_expr, ctx.string_consts, ctx.raw_const_exprs); sok {
							ctx_set_string_const(ctx, ident.name, str_val)
						} else {
							ctx_shadow_ident(ctx, ident.name)
						}
					}
				}
			}
		}
	}
}

visit_odin_node :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil

	ctx := cast(^File_Collect_Ctx)visitor.data

	#partial switch n in node.derived {
	case ^ast.Proc_Lit:
		// Isolate procedure-local constants and shadowing variables to this procedure's scope using copy-on-write
		scoped_ctx := ctx^
		scoped_ctx.owns_proc_aliases = false
		scoped_ctx.owns_string_consts = false
		if n.type != nil {
			if n.type.params != nil {
				for field in n.type.params.list {
					for name_expr in field.names {
						if ident, ok := name_expr.derived_expr.(^ast.Ident); ok {
							ctx_shadow_ident(&scoped_ctx, ident.name)
						}
					}
				}
			}
			if n.type.results != nil {
				for field in n.type.results.list {
					for name_expr in field.names {
						if ident, ok := name_expr.derived_expr.(^ast.Ident); ok {
							ctx_shadow_ident(&scoped_ctx, ident.name)
						}
					}
				}
			}
		}
		scoped_v := ast.Visitor{
			data  = &scoped_ctx,
			visit = visit_odin_node,
		}
		if n.body != nil {
			ast.walk(&scoped_v, n.body)
		}
		return nil

	case ^ast.Block_Stmt:
		// Isolate block-local constants and shadowing variables to this block's scope using copy-on-write
		scoped_ctx := ctx^
		scoped_ctx.owns_proc_aliases = false
		scoped_ctx.owns_string_consts = false
		// Pre-collect non-mutable constant declarations in this block so order-independent constants resolve
		precollect_scope_consts(n.stmts, &scoped_ctx)
		scoped_v := ast.Visitor{
			data  = &scoped_ctx,
			visit = visit_odin_node,
		}
		for stmt in n.stmts {
			ast.walk(&scoped_v, stmt)
		}
		return nil

	case ^ast.Value_Decl:
		// Support local constant declarations inside procedures/blocks, and handle shadowing by mutable variables
		if !n.is_mutable {
			for name_expr, i in n.names {
				if i >= len(n.values) do break
				if ident, ok := name_expr.derived_expr.(^ast.Ident); ok {
					val_expr := n.values[i]
					if kind := resolve_temple_proc_expr(val_expr, ctx.temple_names, ctx.proc_aliases); kind != .None {
						ctx_set_proc_alias(ctx, ident.name, kind)
					} else if str_val, sok := eval_const_string(val_expr, ctx.string_consts, ctx.raw_const_exprs); sok {
						ctx_set_string_const(ctx, ident.name, str_val)
					} else {
						ctx_shadow_ident(ctx, ident.name)
					}
				}
			}
		} else {
			for name_expr in n.names {
				if ident, ok := name_expr.derived_expr.(^ast.Ident); ok {
					ctx_shadow_ident(ctx, ident.name)
				}
			}
		}

	case ^ast.Call_Expr:
		kind := resolve_temple_proc_expr(n.expr, ctx.temple_names, ctx.proc_aliases)
		if kind == .None {
			return visitor
		}
		is_strict := is_strict_temple_call(n.expr, ctx.strict_temple_names, ctx.proc_aliases)

		if len(n.args) != 2 {
			if !is_strict {
				return visitor
			}
			collect_error(
				ctx,
				n.pos,
				"calls to `temple.compiled` and `temple.compiled_inline` expect 2 arguments, got %i",
				len(n.args),
			)
			return nil
		}

		// Support positional or named arguments: `temple.compiled(path = "...", T = ...)`
		path_arg: ^ast.Expr
		has_path := false
		has_T := false
		seen_named := false
		had_arg_err := false
		for arg, idx in n.args {
			if fv, is_fv := arg.derived_expr.(^ast.Field_Value); is_fv {
				seen_named = true
				if field_ident, fok := fv.field.derived_expr.(^ast.Ident); fok {
					if field_ident.name == "path" {
						if has_path {
							if is_strict {
								collect_error(
									ctx,
									fv.pos,
									"duplicate parameter `path` in call to `temple.compiled`",
								)
							}
							had_arg_err = true
						}
						has_path = true
						path_arg = fv.value
					} else if field_ident.name == "T" {
						if has_T {
							if is_strict {
								collect_error(
									ctx,
									fv.pos,
									"duplicate parameter `T` in call to `temple.compiled`",
								)
							}
							had_arg_err = true
						}
						has_T = true
					} else {
						if is_strict {
							collect_error(
								ctx,
								fv.pos,
								"unknown named parameter %q in call to `temple.compiled` (expected `path` or `T`)",
								field_ident.name,
							)
						}
						had_arg_err = true
					}
				}
			} else {
				if seen_named {
					if is_strict {
						collect_error(
							ctx,
							arg.pos,
							"positional argument cannot follow named argument in call to `temple.compiled`",
						)
					}
					had_arg_err = true
				} else if idx == 0 {
					has_path = true
					path_arg = arg
				} else if idx == 1 {
					has_T = true
				}
			}
		}

		if had_arg_err {
			return nil if is_strict else visitor
		}

		if !has_path || path_arg == nil {
			if !is_strict {
				return visitor
			}
			collect_error(
				ctx,
				n.pos,
				"missing `path` argument in call to `temple.compiled`",
			)
			return nil
		}

		if !has_T {
			if !is_strict {
				return visitor
			}
			collect_error(
				ctx,
				n.pos,
				"missing `T` argument in call to `temple.compiled`",
			)
			return nil
		}

		resolved_str, ok := eval_const_string(path_arg, ctx.string_consts, ctx.raw_const_exprs)
		if !ok {
			if !is_strict {
				return visitor
			}
			collect_error(
				ctx,
				path_arg.pos,
				"the path/template argument of `temple.compiled` and `temple.compiled_inline` must be a compile-time constant string expression",
			)
			return nil
		}

		if kind == .Compiled {
			resolved_str = normalize_slash_path(resolved_str, context.temp_allocator)
		}

		target_fullpath := resolved_str
		if kind == .Compiled && !is_abs_slash_path(resolved_str) {
			target_fullpath = clean_slash_path(strings.concatenate({ctx.pkg_fullpath, "/", resolved_str}, context.temp_allocator), context.temp_allocator)
		}

		// Deduplicate calls with identical template identifier, erroring on cross-package collisions
		if existing_fullpath, found := ctx.seen[resolved_str]; found {
			if existing_fullpath != target_fullpath {
				collect_error(
					ctx,
					path_arg.pos,
					"duplicate template path identifier %q resolves to two different files: %q and %q",
					resolved_str,
					existing_fullpath,
					target_fullpath,
				)
			}
			return nil
		}
		ctx.seen[strings.clone(resolved_str, context.temp_allocator)] = strings.clone(target_fullpath, context.temp_allocator)

		c: Compile_Call
		c.pos = path_arg.pos
		c.pos.file = strings.clone(c.pos.file, ctx.out_allocator)
		c.identifier = strings.clone(resolved_str, ctx.out_allocator)

		switch kind {
		case .Compiled:
			cp: Call_Path
			cp.relpath = c.identifier
			cp.fullpath = strings.clone(target_fullpath, ctx.out_allocator)
			c.type = cp

		case .Compiled_Inline:
			cp: Call_Inline
			cp.template = c.identifier
			c.type = cp

		case .None:
		}

		append(ctx.calls, c)
		return nil
	}

	return visitor
}

// ============================================================================
// Stage 2 & 3: Parallel Validation, Layout Splicing, & Transpilation -> Emit
// ============================================================================

Worker_Batch :: struct {
	calls:        []Compile_Call,
	results:      []Transpiled_Template,
	used_files:   ^map[string]bool,
	heap_alloc:   mem.Allocator,
	heap_mutex:   ^sync.Mutex,
	external_pkg: bool,
}

transpile_calls :: proc(
	temple_path: string,
	calls: []Compile_Call,
	opts: Cli_Options = {},
	out_used_files: ^[dynamic]string = nil,
) -> bool {
	pkg_name := opts.pkg_name if len(opts.pkg_name) > 0 else "temple"
	external_pkg := pkg_name != "temple"

	// Sort calls deterministically by identifier before compiling
	slice.sort_by(calls, proc(a, b: Compile_Call) -> bool {
		return a.identifier < b.identifier
	})

	results := make([]Transpiled_Template, len(calls))
	defer {
		for res in results {
			delete(res.code)
			for d in res.diagnostics {
				destroy_diagnostic(d)
			}
			delete(res.diagnostics)
		}
		delete(results)
	}
	used_files := make(map[string]bool)
	defer {
		for k in used_files {
			delete(k)
		}
		delete(used_files)
	}

	if len(calls) > 0 {
		heap_mutex: sync.Mutex
		heap_alloc := context.allocator

		// Use parallel worker threads when there are enough templates to amortize thread creation
		num_workers := min(len(calls), 8) if len(calls) >= 8 else 1
		if num_workers <= 1 {
			batch := Worker_Batch{
				calls        = calls,
				results      = results,
				used_files   = &used_files,
				heap_alloc   = heap_alloc,
				heap_mutex   = &heap_mutex,
				external_pkg = external_pkg,
			}
			compile_batch_worker(&batch)
		} else {
			pool: thread.Pool
			thread.pool_init(&pool, heap_alloc, num_workers)
			defer thread.pool_destroy(&pool)
			thread.pool_start(&pool)

			chunk_size := (len(calls) + num_workers - 1) / num_workers
			batches := make([dynamic]^Worker_Batch, 0, num_workers)
			defer delete(batches)

			for start := 0; start < len(calls); start += chunk_size {
				end := min(start + chunk_size, len(calls))
				b := new(Worker_Batch)
				b.calls = calls[start:end]
				b.results = results[start:end]
				b.used_files = &used_files
				b.heap_alloc = heap_alloc
				b.heap_mutex = &heap_mutex
				b.external_pkg = external_pkg
				append(&batches, b)
				thread.pool_add_task(
					&pool,
					heap_alloc,
					proc(task: thread.Task) {
						batch := cast(^Worker_Batch)task.data
						compile_batch_worker(batch)
					},
					b,
				)
			}

			thread.pool_finish(&pool)
			for b in batches {
				free(b)
			}
		}
	}

	if out_used_files != nil {
		for k, v in used_files {
			if v {
				append(out_used_files, strings.clone(k, out_used_files.allocator))
			}
		}
		slice.sort(out_used_files[:])
	}

	// Check for any diagnostics across all compiled calls
	total_errors := 0
	good_calls := 0
	for res in results {
		if len(res.diagnostics) > 0 {
			for d in res.diagnostics {
				print_diagnostic(d)
				total_errors += 1
			}
		}
		if res.ok {
			good_calls += 1
		}
	}

	if total_errors > 0 {
		fmt.eprintf(
			"\x1b[1;31mTemple Error:\x1b[0m failed to compile %i template(s) due to %i error(s); `templates.odin` was not modified\n",
			len(calls) - good_calls,
			total_errors,
		)
		return false
	}

	if opts.warn_unused && len(opts.project_dir) > 0 {
		candidates := discover_project_template_files(opts.project_dir, context.temp_allocator)
		normalized_used := make(map[string]bool, len(used_files), context.temp_allocator)
		for k, v in used_files {
			if !v do continue
			normalized_used[k] = true
			if ap, err := os.get_absolute_path(k, context.temp_allocator); err == nil {
				normalized_used[ap] = true
			}
		}
		unused := filter_unused_templates(candidates[:], normalized_used, context.temp_allocator)
		for orphan in unused {
			warn(nil, "unused template file %q is never referenced by `compiled`, `extends`, or `embed`", orphan)
		}
	}

	// Stage 3: Emit to in-memory buffer and compare with existing output file
	compiled_path: string
	if len(opts.out_file) > 0 {
		compiled_path = strings.clone(opts.out_file)
	} else {
		compiled_path, _ = filepath.join({temple_path, "templates.odin"})
	}
	defer delete(compiled_path)

	body_builder := strings.builder_make()
	defer strings.builder_destroy(&body_builder)
	bw := strings.to_writer(&body_builder)

	write_generated_file_header_body(bw, pkg_name, opts.temple_import)

	written := 0
	for res in results {
		if !res.ok do continue
		if written > 0 {
			io.write_string(bw, " else")
		}
		io.write_string(bw, res.code)
		written += 1
	}

	write_generated_file_footer(bw, written > 0)
	new_body := strings.to_string(body_builder)

	if opts.check_only {
		existing_bytes, rerr := os.read_entire_file(compiled_path, context.temp_allocator)
		if rerr != nil {
			fmt.eprintf(
				"\x1b[1;31mTemple Error:\x1b[0m generated file %q does not exist; run temple_cli without `--check` to generate\n",
				compiled_path,
			)
			return false
		}
		if !is_generated_output_up_to_date(string(existing_bytes), new_body) {
			fmt.eprintf(
				"\x1b[1;31mTemple Error:\x1b[0m %q is out-of-date; run temple_cli without `--check` to regenerate\n",
				compiled_path,
			)
			return false
		}
		fmt.printf("check passed: %q is up-to-date (%i compile calls)\n", compiled_path, good_calls)
		return true
	}

	// Skip disk write if existing `templates.odin` has identical body content
	if existing_bytes, rerr := os.read_entire_file(compiled_path, context.temp_allocator); rerr == nil {
		if is_generated_output_up_to_date(string(existing_bytes), new_body) {
			fmt.printf("found %i compile calls of which %i were up-to-date (skipped writing unchanged templates.odin)\n", len(calls), good_calls)
			return true
		}
	}

	// Build final file buffer with timestamp header (when calls > 0)
	final_builder := strings.builder_make()
	defer strings.builder_destroy(&final_builder)
	fw := strings.to_writer(&final_builder)

	if written > 0 {
		fmt.wprintf(
			fw,
			"/* This file was generated by temple on %v - DO NOT EDIT! */\n\n",
			time.now(),
		)
	} else {
		io.write_string(fw, "/* This file is generated by temple - DO NOT EDIT! */\n\n")
	}
	io.write_string(fw, new_body)

	handle, err := os.open(compiled_path, {.Write, .Create, .Trunc})
	if err != nil {
		error(nil, "%q: unable to open file for generation (%v)", compiled_path, err)
	}
	defer os.close(handle)

	_, werr := os.write(handle, final_builder.buf[:])
	if werr != nil {
		error(nil, "%q: unable to write generated templates (%v)", compiled_path, werr)
	}

	fmt.printf("found %i compile calls of which %i were successfully compiled\n", len(calls), good_calls)
	return true
}

is_generated_output_up_to_date :: proc(existing_content: string, new_body: string) -> bool {
	return strip_generated_timestamp_header(existing_content) == strip_generated_timestamp_header(new_body)
}

// Intentional distinction from `is_watched_workspace_file`: `--warn-unused` only checks
// explicit template suffixes (`.temple.twig`, `.temple.html`, `.twig`) and ignores plain
// `.html` files so static HTML assets in the repository are not flagged as orphan templates.
is_template_candidate_file :: proc(path: string) -> bool {
	return strings.has_suffix(path, ".temple.twig") ||
		strings.has_suffix(path, ".temple.html") ||
		strings.has_suffix(path, ".twig")
}

filter_unused_templates :: proc(
	candidate_files: []string,
	used_files: map[string]bool,
	allocator := context.allocator,
) -> [dynamic]string {
	unused := make([dynamic]string, 0, len(candidate_files), allocator)
	for f in candidate_files {
		if !is_template_candidate_file(f) {
			continue
		}
		if !used_files[f] {
			append(&unused, strings.clone(f, allocator))
		}
	}
	slice.sort(unused[:])
	return unused
}

discover_project_template_files :: proc(root_dir: string, allocator := context.allocator) -> [dynamic]string {
	files := make([dynamic]string, allocator)
	w := filepath.walker_create(root_dir)
	defer filepath.walker_destroy(&w)

	for info in filepath.walker_walk(&w) {
		if _, err := filepath.walker_error(&w); err != nil {
			continue
		}
		if info.type == .Directory {
			if info.fullpath != root_dir && should_skip_walk_dir(info.name) {
				filepath.walker_skip_dir(&w)
			}
			continue
		}
		if !is_template_candidate_file(info.name) {
			continue
		}
		if ap, err := os.get_absolute_path(info.fullpath, allocator); err == nil {
			append(&files, ap)
		} else {
			append(&files, strings.clone(info.fullpath, allocator))
		}
	}
	slice.sort(files[:])
	return files
}

File_Stamp :: struct {
	mtime_nsec: i64,
	size:       i64,
}

Workspace_Snapshot :: map[string]File_Stamp

is_watched_workspace_file :: proc(name: string) -> bool {
	return strings.has_suffix(name, ".odin") ||
		strings.has_suffix(name, ".temple.twig") ||
		strings.has_suffix(name, ".temple.html") ||
		strings.has_suffix(name, ".twig") ||
		strings.has_suffix(name, ".html")
}

capture_workspace_snapshot :: proc(
	root_dir: string,
	exclude_out_file := "",
	allocator := context.allocator,
	extra_files: []string = nil,
) -> Workspace_Snapshot {
	snap := make(Workspace_Snapshot, allocator)
	abs_exclude := ""
	if len(exclude_out_file) > 0 {
		if ap, err := os.get_absolute_path(exclude_out_file, context.temp_allocator); err == nil {
			abs_exclude = ap
		} else {
			abs_exclude = exclude_out_file
		}
	}

	snapshot_walk_dir :: proc(
		dir_to_walk: string,
		abs_exclude: string,
		snap: ^Workspace_Snapshot,
		allocator: mem.Allocator,
	) {
		w := filepath.walker_create(dir_to_walk)
		defer filepath.walker_destroy(&w)

		for info in filepath.walker_walk(&w) {
			if _, err := filepath.walker_error(&w); err != nil {
				continue
			}
			if info.type == .Directory {
				if info.fullpath != dir_to_walk && should_skip_walk_dir(info.name) {
					filepath.walker_skip_dir(&w)
				}
				continue
			}
			if !is_watched_workspace_file(info.name) || info.name == "templates.odin" {
				continue
			}
			abs_path := info.fullpath
			if ap, err := os.get_absolute_path(info.fullpath, context.temp_allocator); err == nil {
				abs_path = ap
			}
			if len(abs_exclude) > 0 && abs_path == abs_exclude {
				continue
			}
			if _, exists := snap^[abs_path]; !exists {
				snap^[strings.clone(abs_path, allocator)] = File_Stamp{
					mtime_nsec = info.modification_time._nsec,
					size       = info.size,
				}
			}
		}
	}

	snapshot_walk_dir(root_dir, abs_exclude, &snap, allocator)

	for extra in extra_files {
		if len(extra) == 0 {
			continue
		}
		abs_extra := extra
		if ap, err := os.get_absolute_path(extra, context.temp_allocator); err == nil {
			abs_extra = ap
		}
		if len(abs_exclude) > 0 && abs_extra == abs_exclude {
			continue
		}
		if info, stat_err := os.stat(abs_extra, context.temp_allocator); stat_err == nil {
			if info.type == .Directory {
				snapshot_walk_dir(abs_extra, abs_exclude, &snap, allocator)
			} else if _, exists := snap[abs_extra]; !exists {
				snap[strings.clone(abs_extra, allocator)] = File_Stamp{
					mtime_nsec = info.modification_time._nsec,
					size       = info.size,
				}
			}
		}
	}

	return snap
}

has_workspace_snapshot_changed :: proc(prev, curr: Workspace_Snapshot) -> bool {
	if len(prev) != len(curr) {
		return true
	}
	for k, curr_val in curr {
		prev_val, found := prev[k]
		if !found || prev_val != curr_val {
			return true
		}
	}
	return false
}

watch_workspace :: proc(opts: Cli_Options, max_iterations := 0, poll_interval := 250 * time.Millisecond) {
	fmt.printf("watching %q for template and Odin file changes...\n", opts.project_dir)

	snapshot_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&snapshot_arena)
	defer mem.dynamic_arena_destroy(&snapshot_arena)
	snap_alloc := mem.dynamic_arena_allocator(&snapshot_arena)

	watched_used := make([dynamic]string, snap_alloc)
	_ = run_cli_once(opts, &watched_used)

	prev_snap := capture_workspace_snapshot(opts.project_dir, opts.out_file, snap_alloc, watched_used[:])
	free_all(context.temp_allocator)

	for iter := 0; max_iterations <= 0 || iter < max_iterations; iter += 1 {
		time.sleep(poll_interval)

		curr_snap := capture_workspace_snapshot(opts.project_dir, opts.out_file, context.temp_allocator, watched_used[:])
		if has_workspace_snapshot_changed(prev_snap, curr_snap) {
			fmt.println("change detected; recompiling templates...")
			mem.dynamic_arena_reset(&snapshot_arena)
			watched_used = make([dynamic]string, snap_alloc)
			_ = run_cli_once(opts, &watched_used)
			prev_snap = capture_workspace_snapshot(opts.project_dir, opts.out_file, snap_alloc, watched_used[:])
		}
		free_all(context.temp_allocator)
	}
}

strip_generated_timestamp_header :: proc(content: string) -> string {
	PREFIX_TS :: "/* This file was generated by temple on "
	PREFIX_STATIC :: "/* This file is generated by temple - DO NOT EDIT! */"
	rest := content
	if strings.has_prefix(rest, PREFIX_TS) {
		if nl := strings.index_byte(rest, '\n'); nl != -1 {
			rest = rest[nl+1:]
		}
	}
	if strings.has_prefix(rest, PREFIX_STATIC) {
		if nl := strings.index_byte(rest, '\n'); nl != -1 {
			rest = rest[nl+1:]
		}
	}
	return strings.trim_left(rest, "\r\n")
}

compile_batch_worker :: proc(batch: ^Worker_Batch) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	arena_alloc := mem.dynamic_arena_allocator(&arena)
	context.allocator = arena_alloc
	context.temp_allocator = arena_alloc

	ctx: Compile_Context
	ctx.allocator = arena_alloc
	ctx.stack = make([dynamic]Trace_Frame, arena_alloc)
	ctx.raw_cache = make(map[string]Cached_Template, arena_alloc)
	ctx.resolved_cache = make(map[string]Template, arena_alloc)
	ctx.used_files = make(map[string]bool, arena_alloc)
	ctx.external_pkg = batch.external_pkg

	for call, i in batch.calls {
		clear_trace_frames(&ctx)
		ctx.diagnostics = make([dynamic]Diagnostic, arena_alloc)

		code, ok := compile_single_call(&ctx, call)

		sync.guard(batch.heap_mutex)
		if batch.used_files != nil {
			for k, v in ctx.used_files {
				if v && !batch.used_files^[k] {
					batch.used_files^[strings.clone(k, batch.heap_alloc)] = true
				}
			}
		}
		cloned_diags := make([dynamic]Diagnostic, 0, len(ctx.diagnostics), batch.heap_alloc)
		for d in ctx.diagnostics {
			append(&cloned_diags, clone_diagnostic(d, batch.heap_alloc))
		}

		batch.results[i] = Transpiled_Template {
			identifier  = call.identifier,
			code        = strings.clone(code, batch.heap_alloc) if ok else "",
			diagnostics = cloned_diags,
			ok          = ok && len(ctx.diagnostics) == 0,
		}
	}
}

compile_single_call :: proc(ctx: ^Compile_Context, call: Compile_Call) -> (code: string, ok: bool) {
	context.allocator = ctx.allocator
	context.temp_allocator = ctx.allocator

	identifier: string
	file: string
	source: []byte
	templ: Template

	switch t in call.type {
	case Call_Path:
		identifier = normalize_slash_path(t.relpath, ctx.allocator)
		file = normalize_slash_path(t.fullpath, ctx.allocator)
		call_pos := call.pos
		call_pos.file = normalize_slash_path(call.pos.file, ctx.allocator)

		_ = push_trace_frame(ctx, Trace_Frame{
			kind = .Call_Site,
			pos  = call_pos,
			file = file,
		})
		defer pop_trace_frame(ctx)

		loaded_templ, loaded_src, load_ok := load_and_resolve_template_file(ctx, file, call_pos, nil, 0)
		if !load_ok {
			return "", false
		}
		templ = loaded_templ
		source = loaded_src

		sb := strings.builder_make(ctx.allocator)
		w := strings.to_writer(&sb)

		embed_state := Embed_Callback_State {
			ctx          = ctx,
			current_file = file,
			current_src  = source,
		}

		transpile(w, identifier, templ, embed_parser_with_ctx, &embed_state, ctx.allocator, ctx.external_pkg)
		if len(ctx.diagnostics) > 0 {
			return "", false
		}

		return strings.to_string(sb), true

	case Call_Inline:
		identifier = t.template
		file = call.pos.file
		source = transmute([]byte)t.template
		ctx.inline_file = call.pos.file
		ctx.inline_pos = call.pos
		defer {
			ctx.inline_file = ""
			ctx.inline_pos = {}
		}

		_ = push_trace_frame(ctx, Trace_Frame{
			kind = .Call_Site,
			pos  = call.pos,
			file = call.pos.file,
		})
		defer pop_trace_frame(ctx)

		p: Parser
		parser_init(&p, source, ctx.allocator)
		raw_templ := parse(&p)
		if err, has_err := raw_templ.err.?; has_err {
			pos := tokenizer.Pos{
				offset = err.pos.offset,
				line   = call.pos.line + err.pos.line,
				column = (call.pos.column + err.pos.col) if err.pos.line == 0 else (err.pos.col + 1),
				file   = call.pos.file,
			}
			record_diagnostic(
				ctx,
				pos,
				source,
				1,
				"%s",
				err.msg,
				snippet_line = err.pos.line + 1,
				snippet_col  = err.pos.col + 1,
			)
			return "", false
		}

		resolved_templ, res_ok := resolve_template_inheritance(ctx, raw_templ, source, file)
		if !res_ok {
			return "", false
		}
		templ = resolved_templ

		sb := strings.builder_make(ctx.allocator)
		w := strings.to_writer(&sb)

		embed_state := Embed_Callback_State {
			ctx          = ctx,
			current_file = file,
			current_src  = source,
		}

		transpile(w, identifier, templ, embed_parser_with_ctx, &embed_state, ctx.allocator, ctx.external_pkg)
		if len(ctx.diagnostics) > 0 {
			return "", false
		}

		return strings.to_string(sb), true
	}

	return "", false
}

cache_raw_template :: proc(ctx: ^Compile_Context, fullpath: string, cached: Cached_Template) {
	for i in 0 ..< ctx.inline_raw_cnt {
		if ctx.inline_raw[i].file == fullpath {
			ctx.inline_raw[i].cached = cached
			return
		}
	}
	if ctx.inline_raw_cnt < len(ctx.inline_raw) {
		ctx.inline_raw[ctx.inline_raw_cnt] = {
			file   = fullpath,
			cached = cached,
		}
		ctx.inline_raw_cnt += 1
		return
	}
	if ctx.raw_cache.allocator.procedure == nil {
		ctx.raw_cache = make(map[string]Cached_Template, ctx.allocator)
	}
	ctx.raw_cache[fullpath] = cached
}

@(private = "file")
lookup_raw_cache :: proc(ctx: ^Compile_Context, fullpath: string) -> (Cached_Template, bool) {
	for i in 0 ..< ctx.inline_raw_cnt {
		if ctx.inline_raw[i].file == fullpath {
			return ctx.inline_raw[i].cached, true
		}
	}
	if ctx.raw_cache.allocator.procedure != nil {
		if cached, found := ctx.raw_cache[fullpath]; found {
			return cached, true
		}
	}
	return {}, false
}

load_raw_template :: proc(
	ctx: ^Compile_Context,
	fullpath: string,
	req_pos: tokenizer.Pos,
	req_src: []byte,
	req_col_len: int,
) -> (
	templ: Template,
	source: []byte,
	ok: bool,
) {
	if ctx.used_files.allocator.procedure != nil && !ctx.used_files[fullpath] {
		ctx.used_files[strings.clone(fullpath, ctx.allocator)] = true
	}
	if cached, found := lookup_raw_cache(ctx, fullpath); found {
		if err, has_err := cached.template.err.?; has_err {
			pos := tokenizer.Pos{
				offset = err.pos.offset,
				line   = err.pos.line + 1,
				column = err.pos.col + 1,
				file   = fullpath,
			}
			record_diagnostic(ctx, pos, cached.source, 1, "%s", err.msg)
			return {}, nil, false
		}
		return cached.template, cached.source, true
	}

	data, rerr := os.read_entire_file(fullpath, ctx.allocator)
	if rerr != nil {
		record_diagnostic(
			ctx,
			req_pos,
			req_src,
			req_col_len,
			"unable to read template file %q (%v)",
			fullpath,
			rerr,
		)
		return {}, nil, false
	}

	p: Parser
	parser_init(&p, data, ctx.allocator)
	parsed := parse(&p)
	if err, has_err := parsed.err.?; has_err {
		pos := tokenizer.Pos{
			offset = err.pos.offset,
			line   = err.pos.line + 1,
			column = err.pos.col + 1,
			file   = fullpath,
		}
		record_diagnostic(ctx, pos, data, 1, "%s", err.msg)
		return {}, nil, false
	}

	cloned_path := strings.clone(fullpath, ctx.allocator)
	cache_raw_template(ctx, cloned_path, Cached_Template{
		source   = data,
		template = parsed,
	})
	return parsed, data, true
}

@(private = "file")
lookup_resolved_cache :: proc(ctx: ^Compile_Context, fullpath: string) -> (Template, bool) {
	for i in 0 ..< ctx.inline_res_cnt {
		if ctx.inline_resolved[i].file == fullpath {
			return ctx.inline_resolved[i].template, true
		}
	}
	if ctx.resolved_cache.allocator.procedure != nil {
		if cached_res, found := ctx.resolved_cache[fullpath]; found {
			return cached_res, true
		}
	}
	return {}, false
}

@(private = "file")
store_resolved_cache :: proc(ctx: ^Compile_Context, fullpath: string, resolved: Template) {
	for i in 0 ..< ctx.inline_res_cnt {
		if ctx.inline_resolved[i].file == fullpath {
			return
		}
	}
	if ctx.inline_res_cnt < len(ctx.inline_resolved) {
		ctx.inline_resolved[ctx.inline_res_cnt] = {
			file     = fullpath,
			template = resolved,
		}
		ctx.inline_res_cnt += 1
		return
	}
	if ctx.resolved_cache.allocator.procedure != nil {
		if _, exists := ctx.resolved_cache[fullpath]; !exists {
			ctx.resolved_cache[strings.clone(fullpath, ctx.allocator)] = resolved
		}
	}
}

load_and_resolve_template_file :: proc(
	ctx: ^Compile_Context,
	fullpath: string,
	req_pos: tokenizer.Pos,
	req_src: []byte,
	req_col_len: int,
) -> (
	templ: Template,
	source: []byte,
	ok: bool,
) {
	raw_templ, raw_src, raw_ok := load_raw_template(ctx, fullpath, req_pos, req_src, req_col_len)
	if !raw_ok {
		return {}, nil, false
	}

	if cached_res, found := lookup_resolved_cache(ctx, fullpath); found {
		return cached_res, raw_src, true
	}

	resolved, res_ok := resolve_template_inheritance(ctx, raw_templ, raw_src, fullpath)
	if !res_ok {
		return {}, nil, false
	}
	store_resolved_cache(ctx, fullpath, resolved)
	return resolved, raw_src, true
}

// ============================================================================
// Goal 4: Layout Inheritance (`extends`, `block`, `super`)
// ============================================================================

find_extends_node :: proc(templ: Template) -> (^Node_Extends, bool) {
	for node in templ.content {
		if ext, is_ext := node.derived.(^Node_Extends); is_ext {
			return ext, true
		}
	}
	return nil, false
}

walk_branch_children :: proc(
	node: Node,
	user_data: rawptr,
	visit_body: proc(body: []Node, user_data: rawptr) -> bool,
) -> bool {
	#partial switch d in node.derived {
	case ^Node_If:
		if !visit_body(d._if.body[:], user_data) do return false
		for ef in d.elseifs {
			if !visit_body(ef.body[:], user_data) do return false
		}
		if els, ok := d._else.?; ok {
			if !visit_body(els.body[:], user_data) do return false
		}
	case ^Node_For:
		if !visit_body(d.body[:], user_data) do return false
	case ^Node_Switch:
		for c in d.cases {
			if !visit_body(c.body[:], user_data) do return false
		}
	case ^Node_Macro:
		if !visit_body(d.body[:], user_data) do return false
	}
	return true
}

map_branch_children :: proc(
	ctx: ^Compile_Context,
	node: Node,
	user_data: rawptr,
	map_body: proc(ctx: ^Compile_Context, body: []Node, user_data: rawptr) -> [dynamic]Node,
) -> (
	mapped: Node,
	handled: bool,
) {
	#partial switch d in node.derived {
	case ^Node_If:
		new_if := alloc_ctx_node(ctx, Node_If)
		new_if^ = d^
		new_if.derived = new_if
		new_if._if.body = map_body(ctx, d._if.body[:], user_data)
		new_if.elseifs = make([dynamic]^Node_If_Part, 0, len(d.elseifs), ctx.allocator)
		for ef in d.elseifs {
			new_ef := alloc_ctx_node(ctx, Node_If_Part)
			new_ef^ = ef^
			new_ef.body = map_body(ctx, ef.body[:], user_data)
			append(&new_if.elseifs, new_ef)
		}
		if els, has_els := d._else.?; has_els {
			new_els := alloc_ctx_node(ctx, Node_If_Part)
			new_els^ = els^
			new_els.body = map_body(ctx, els.body[:], user_data)
			new_if._else = new_els
		}
		return new_if, true
	case ^Node_For:
		new_for := alloc_ctx_node(ctx, Node_For)
		new_for^ = d^
		new_for.derived = new_for
		new_for.body = map_body(ctx, d.body[:], user_data)
		return new_for, true
	case ^Node_Switch:
		new_sw := alloc_ctx_node(ctx, Node_Switch)
		new_sw^ = d^
		new_sw.derived = new_sw
		new_sw.cases = make([dynamic]^Node_Case, 0, len(d.cases), ctx.allocator)
		for c in d.cases {
			new_c := alloc_ctx_node(ctx, Node_Case)
			new_c^ = c^
			new_c.body = map_body(ctx, c.body[:], user_data)
			append(&new_sw.cases, new_c)
		}
		return new_sw, true
	case ^Node_Macro:
		new_mac := alloc_ctx_node(ctx, Node_Macro)
		new_mac^ = d^
		new_mac.derived = new_mac
		new_mac.body = map_body(ctx, d.body[:], user_data)
		return new_mac, true
	}
	return node, false
}

validate_unique_blocks_in_nodes :: proc(
	ctx: ^Compile_Context,
	nodes: []Node,
	seen: ^map[string]^Node_Block,
	fallback_src: []byte,
	fallback_file: string,
) -> bool {
	Walk_State :: struct {
		ctx:           ^Compile_Context,
		seen:          ^map[string]^Node_Block,
		fallback_src:  []byte,
		fallback_file: string,
	}
	state := Walk_State{ctx, seen, fallback_src, fallback_file}

	visit_cb :: proc(body: []Node, user_data: rawptr) -> bool {
		s := cast(^Walk_State)user_data
		return validate_unique_blocks_in_nodes(s.ctx, body, s.seen, s.fallback_src, s.fallback_file)
	}

	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Block:
			if _, exists := seen[d.name]; exists {
				file := d.origin_file if len(d.origin_file) > 0 else fallback_file
				src := d.origin_src if d.origin_src != nil else fallback_src
				blk_pos := tokenizer.Pos{
					offset = d.name_tok.pos.offset,
					line   = d.name_tok.pos.line + 1,
					column = d.name_tok.pos.col + 1,
					file   = file,
				}
				record_diagnostic(
					ctx,
					blk_pos,
					src,
					len(d.name),
					"duplicate block definition %q in template",
					d.name,
				)
				return false
			}
			seen[d.name] = d
			if !validate_unique_blocks_in_nodes(ctx, d.body[:], seen, fallback_src, fallback_file) {
				return false
			}
		case:
			if !walk_branch_children(node, &state, visit_cb) {
				return false
			}
		}
	}
	return true
}

resolve_template_inheritance :: proc(
	ctx: ^Compile_Context,
	child_templ: Template,
	child_src: []byte,
	child_file: string,
) -> (
	resolved: Template,
	ok: bool,
) {
	// Validate that all blocks defined in this template (top-level or nested) have unique names
	if nodes_contain_block(child_templ.content[:]) {
		top_blk_count := 0
		has_branch_blk := false
		for node in child_templ.content {
			if blk, is_blk := node.derived.(^Node_Block); is_blk {
				top_blk_count += 1
				if nodes_contain_block(blk.body[:]) {
					has_branch_blk = true
				}
			} else if nodes_contain_block((&[1]Node{node})[:]) {
				has_branch_blk = true
			}
		}
		if has_branch_blk || top_blk_count > 8 {
			seen_local_blocks := make(map[string]^Node_Block, ctx.allocator)
			if !validate_unique_blocks_in_nodes(ctx, child_templ.content[:], &seen_local_blocks, child_src, child_file) {
				return {}, false
			}
		} else if top_blk_count > 1 {
			seen_names: [8]string
			seen_len := 0
			for node in child_templ.content {
				if d, is_blk := node.derived.(^Node_Block); is_blk {
					for i in 0 ..< seen_len {
						if seen_names[i] == d.name {
							file := d.origin_file if len(d.origin_file) > 0 else child_file
							src := d.origin_src if d.origin_src != nil else child_src
							blk_pos := tokenizer.Pos{
								offset = d.name_tok.pos.offset,
								line   = d.name_tok.pos.line + 1,
								column = d.name_tok.pos.col + 1,
								file   = file,
							}
							record_diagnostic(
								ctx,
								blk_pos,
								src,
								len(d.name),
								"duplicate block definition %q in template",
								d.name,
							)
							return {}, false
						}
					}
					seen_names[seen_len] = d.name
					seen_len += 1
				}
			}
		}
	}

	ext, has_ext := find_extends_node(child_templ)
	if !has_ext {
		// Still validate that blocks in a non-extending template don't call `super()`
		if nodes_contain_any_super(child_templ.content[:]) {
			if !validate_no_orphan_super_in_nodes(ctx, child_templ.content[:], child_src, child_file) {
				return {}, false
			}
		}
		if !nodes_need_embed_rewrite(child_templ.content[:]) {
			return child_templ, true
		}
		base_dir := "" if child_file == ctx.inline_file else slice_file_dir(child_file)
		return rewrite_embeds_relative_to_dir(ctx, child_templ, base_dir, child_file, child_src), true
	}

	child_dir := slice_file_dir(child_file)
	relpath := normalize_slash_path(ext.path.value[1 : len(ext.path.value)-1], ctx.allocator)
	parent_fullpath := join_relative_slash_path(child_file, relpath, ctx.allocator)

	ext_pos := tokenizer.Pos{
		offset = ext.path.pos.offset,
		line   = ext.path.pos.line + 1,
		column = ext.path.pos.col + 1,
		file   = child_file,
	}

	// Cycle check across active stack
	for frame in get_trace_frames(ctx) {
		if frame.file == parent_fullpath {
			record_diagnostic(
				ctx,
				ext_pos,
				child_src,
				len(ext.path.value),
				"circular layout inheritance detected: %q extends %q which is already in the inheritance chain",
				child_file,
				parent_fullpath,
			)
			return {}, false
		}
	}

	// Collect child blocks and macros (top-level overrides/definitions) and normalize relative embeds/origins inside them
	child_blocks_buf: [16]^Node_Block
	child_block_cnt := 0
	child_blocks_var: [dynamic]^Node_Block
	child_macros_buf: [16]^Node_Macro
	child_macro_cnt := 0
	child_macros_var: [dynamic]^Node_Macro

	for node in child_templ.content {
		if blk, is_blk := node.derived.(^Node_Block); is_blk {
			normalized_blk := clone_block_with_resolved_embeds(ctx, blk, child_dir, child_file, child_src)
			replaced := false
			if child_blocks_var != nil {
				for &b in child_blocks_var {
					if b.name == blk.name {
						b = normalized_blk
						replaced = true
						break
					}
				}
				if !replaced {
					append(&child_blocks_var, normalized_blk)
				}
			} else {
				for i in 0 ..< child_block_cnt {
					if child_blocks_buf[i].name == blk.name {
						child_blocks_buf[i] = normalized_blk
						replaced = true
						break
					}
				}
				if !replaced {
					if child_block_cnt < len(child_blocks_buf) {
						child_blocks_buf[child_block_cnt] = normalized_blk
						child_block_cnt += 1
					} else {
						child_blocks_var = make([dynamic]^Node_Block, 0, child_block_cnt * 2, ctx.allocator)
						for b in child_blocks_buf {
							append(&child_blocks_var, b)
						}
						append(&child_blocks_var, normalized_blk)
					}
				}
			}
		} else if mac, is_mac := node.derived.(^Node_Macro); is_mac {
			normalized_mac := clone_macro_with_resolved_embeds(ctx, mac, child_dir, child_file, child_src)
			if child_macros_var != nil {
				append(&child_macros_var, normalized_mac)
			} else if child_macro_cnt < len(child_macros_buf) {
				child_macros_buf[child_macro_cnt] = normalized_mac
				child_macro_cnt += 1
			} else {
				child_macros_var = make([dynamic]^Node_Macro, 0, child_macro_cnt * 2, ctx.allocator)
				for m in child_macros_buf {
					append(&child_macros_var, m)
				}
				append(&child_macros_var, normalized_mac)
			}
		}
	}
	child_blocks := child_blocks_var[:] if child_blocks_var != nil else child_blocks_buf[:child_block_cnt]
	child_macro_order := child_macros_var[:] if child_macros_var != nil else child_macros_buf[:child_macro_cnt]

	// Push extends frame and load/resolve parent layout (supports multi-level inheritance)
	parent_templ: Template
	parent_ok: bool
	{
		ext_frame_idx := push_trace_frame(ctx, Trace_Frame{
			kind    = .Extends,
			pos     = ext_pos,
			file    = parent_fullpath,
			col_len = len(ext.path.value),
		})
		defer pop_trace_frame(ctx)

		parent_templ, _, parent_ok = load_and_resolve_template_file(
			ctx,
			parent_fullpath,
			ext_pos,
			child_src,
			len(ext.path.value),
		)
		if !parent_ok {
			set_trace_frame_snippet(ctx, ext_frame_idx, extract_line_snippet(child_src, ext_pos.line, ctx.allocator))
			return {}, false
		}
	}

	// Validate that every child block exists in the parent layout (only allocate map on error)
	for child_blk in child_blocks {
		blk_name := child_blk.name
		if !has_layout_block_named(parent_templ.content[:], blk_name) {
			parent_blocks := make(map[string]^Node_Block, ctx.allocator)
			collect_layout_blocks(parent_templ.content[:], &parent_blocks)
			valid_names := make([dynamic]string, ctx.allocator)
			for k in parent_blocks {
				append(&valid_names, k)
			}
			slice.sort(valid_names[:])
			valid_list := strings.join(valid_names[:], ", ", ctx.allocator) if len(valid_names) > 0 else "(none)"

			blk_pos := tokenizer.Pos{
				offset = child_blk.name_tok.pos.offset,
				line   = child_blk.name_tok.pos.line + 1,
				column = child_blk.name_tok.pos.col + 1,
				file   = child_file,
			}
			record_diagnostic(
				ctx,
				blk_pos,
				child_src,
				len(child_blk.name),
				"unknown block %q in child template (available blocks in parent layout: %s)",
				blk_name,
				valid_list,
			)
			return {}, false
		}
	}

	// Splice child blocks and macros into parent layout AST (handling `super()` recursively)
	flatten_blocks := len(get_trace_frames(ctx)) <= 1
	spliced_parent := splice_nodes(ctx, parent_templ.content[:], child_blocks, flatten_blocks)
	spliced: Template
	if len(child_macro_order) > 0 {
		merged := make([dynamic]Node, 0, len(spliced_parent) + len(child_macro_order), ctx.allocator)
		for mac in child_macro_order {
			in_parent := false
			for node in spliced_parent {
				if pmac, is_mac := node.derived.(^Node_Macro); is_mac && pmac.name == mac.name {
					in_parent = true
					break
				}
			}
			if !in_parent {
				append(&merged, mac)
			}
		}
		for node in spliced_parent {
			if mac, is_mac := node.derived.(^Node_Macro); is_mac {
				override_mac: ^Node_Macro
				for cmac in child_macro_order {
					if cmac.name == mac.name {
						override_mac = cmac
					}
				}
				if override_mac != nil {
					append(&merged, override_mac)
					continue
				}
			}
			append(&merged, node)
		}
		spliced.content = merged
	} else {
		spliced.content = spliced_parent
	}
	if nodes_contain_any_super(spliced.content[:]) {
		if !validate_no_orphan_super_in_nodes(ctx, spliced.content[:], child_src, child_file) {
			return {}, false
		}
	}
	if !validate_macro_calls_in_template(ctx, spliced.content[:], child_src, child_file) {
		return {}, false
	}
	if len(child_file) > 0 && child_file != ctx.inline_file {
		store_resolved_cache(ctx, child_file, spliced)
	}
	return spliced, true
}

@(private = "file")
nodes_contain_call :: proc(nodes: []Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_contain_call(body)
	}
	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Call:
			return true
		case ^Node_Block:
			if nodes_contain_call(d.body[:]) {
				return true
			}
		case ^Node_Macro:
			if nodes_contain_call(d.body[:]) {
				return true
			}
		case:
			if !walk_branch_children(node, nil, visit_cb) {
				return true
			}
		}
	}
	return false
}

@(private = "file")
nodes_contain_any_super :: proc(nodes: []Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_contain_any_super(body)
	}
	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Super:
			return true
		case ^Node_Block:
			if nodes_contain_any_super(d.body[:]) {
				return true
			}
		case:
			if !walk_branch_children(node, nil, visit_cb) {
				return true
			}
		}
	}
	return false
}

validate_macro_calls_in_template :: proc(
	ctx: ^Compile_Context,
	nodes: []Node,
	fallback_src: []byte,
	fallback_file: string,
) -> bool {
	if !nodes_contain_call(nodes) {
		return true
	}
	inline_macros: [16]^Node_Macro
	macro_count := 0
	var_macros: [dynamic]^Node_Macro

	for node in nodes {
		if mac, is_mac := node.derived.(^Node_Macro); is_mac {
			if macro_count < len(inline_macros) {
				inline_macros[macro_count] = mac
				macro_count += 1
			} else {
				if var_macros == nil {
					var_macros = make([dynamic]^Node_Macro, 0, macro_count * 2, ctx.allocator)
					for m in inline_macros {
						append(&var_macros, m)
					}
				}
				append(&var_macros, mac)
			}
		}
	}
	macros_slice := var_macros[:] if var_macros != nil else inline_macros[:macro_count]
	return validate_macro_calls_in_nodes(ctx, nodes, macros_slice, fallback_src, fallback_file)
}

validate_macro_calls_in_nodes :: proc(
	ctx: ^Compile_Context,
	nodes: []Node,
	macros: []^Node_Macro,
	src: []byte,
	file: string,
) -> bool {
	Walk_State :: struct {
		ctx:    ^Compile_Context,
		macros: []^Node_Macro,
		src:    []byte,
		file:   string,
	}
	state := Walk_State{ctx, macros, src, file}

	visit_cb :: proc(body: []Node, user_data: rawptr) -> bool {
		s := cast(^Walk_State)user_data
		return validate_macro_calls_in_nodes(s.ctx, body, s.macros, s.src, s.file)
	}

	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Call:
			actual_file := d.origin_file if len(d.origin_file) > 0 else file
			actual_src := d.origin_src if d.origin_src != nil else src
			if err_pos, err_col_len, err_msg, ok := check_macro_call_node(d, macros, ctx.allocator); !ok {
				pos := tokenizer.Pos{
					offset = err_pos.offset,
					line   = err_pos.line + 1,
					column = err_pos.col + 1,
					file   = actual_file,
				}
				record_diagnostic(ctx, pos, actual_src, err_col_len, "%s", err_msg)
				return false
			}
		case ^Node_Block:
			blk_file := d.origin_file if len(d.origin_file) > 0 else file
			blk_src := d.origin_src if d.origin_src != nil else src
			if !validate_macro_calls_in_nodes(ctx, d.body[:], macros, blk_src, blk_file) {
				return false
			}
		case ^Node_Macro:
			mac_file := d.origin_file if len(d.origin_file) > 0 else file
			mac_src := d.origin_src if d.origin_src != nil else src
			if !validate_macro_calls_in_nodes(ctx, d.body[:], macros, mac_src, mac_file) {
				return false
			}
		case:
			if !walk_branch_children(node, &state, visit_cb) {
				return false
			}
		}
	}
	return true
}

validate_no_orphan_super_in_nodes :: proc(
	ctx: ^Compile_Context,
	nodes: []Node,
	src: []byte,
	file: string,
) -> bool {
	Walk_State :: struct {
		ctx:  ^Compile_Context,
		src:  []byte,
		file: string,
	}
	state := Walk_State{ctx, src, file}

	visit_cb :: proc(body: []Node, user_data: rawptr) -> bool {
		s := cast(^Walk_State)user_data
		return validate_no_orphan_super_in_nodes(s.ctx, body, s.src, s.file)
	}

	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Super:
			actual_file := d.origin_file if len(d.origin_file) > 0 else file
			actual_src := d.origin_src if d.origin_src != nil else src
			pos := tokenizer.Pos{
				offset = d.open.pos.offset,
				line   = d.open.pos.line + 1,
				column = d.open.pos.col + 1,
				file   = actual_file,
			}
			record_diagnostic(
				ctx,
				pos,
				actual_src,
				len(d.super_tok.value),
				"\"super\" cannot be used in a root template that does not extend a parent layout",
			)
			return false
		case ^Node_Block:
			blk_file := d.origin_file if len(d.origin_file) > 0 else file
			blk_src := d.origin_src if d.origin_src != nil else src
			if !validate_no_orphan_super_in_nodes(ctx, d.body[:], blk_src, blk_file) {
				return false
			}
		case:
			if !walk_branch_children(node, &state, visit_cb) {
				return false
			}
		}
	}
	return true
}

has_layout_block_named :: proc(nodes: []Node, target: string) -> bool {
	State :: struct {
		target: string,
	}
	state := State{target}
	visit_cb :: proc(body: []Node, user_data: rawptr) -> bool {
		s := cast(^State)user_data
		return !has_layout_block_named(body, s.target)
	}

	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Block:
			if d.name == target || has_layout_block_named(d.body[:], target) {
				return true
			}
		case:
			if !walk_branch_children(node, &state, visit_cb) {
				return true
			}
		}
	}
	return false
}

collect_layout_blocks :: proc(nodes: []Node, out: ^map[string]^Node_Block) {
	visit_cb :: proc(body: []Node, user_data: rawptr) -> bool {
		collect_layout_blocks(body, cast(^map[string]^Node_Block)user_data)
		return true
	}

	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Block:
			out[d.name] = d
			collect_layout_blocks(d.body[:], out)
		case:
			_ = walk_branch_children(node, out, visit_cb)
		}
	}
}

@(private = "file")
find_override_block :: proc(overrides: []^Node_Block, name: string) -> ^Node_Block {
	for b in overrides {
		if b.name == name {
			return b
		}
	}
	return nil
}

clone_overrides_without :: proc(
	ctx: ^Compile_Context,
	overrides: []^Node_Block,
	exclude_name: string,
) -> []^Node_Block {
	if len(overrides) <= 1 {
		return nil
	}
	n := 0
	res_backing := make([]^Node_Block, len(overrides) - 1, ctx.allocator)
	for v in overrides {
		if v.name != exclude_name {
			res_backing[n] = v
			n += 1
		}
	}
	return res_backing[:n]
}

@(private = "file")
nodes_contain_block :: proc(nodes: []Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_contain_block(body)
	}
	for node in nodes {
		if _, is_blk := node.derived.(^Node_Block); is_blk {
			return true
		}
		if !walk_branch_children(node, nil, visit_cb) {
			return true
		}
	}
	return false
}

@(private = "file")
nodes_contain_super :: proc(nodes: []Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_contain_super(body)
	}
	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Super:
			return true
		case ^Node_Block:
			// Do not inspect inside nested `Node_Block` (outer block's `super` does not substitute there)
			continue
		case:
			if !walk_branch_children(node, nil, visit_cb) {
				return true
			}
		}
	}
	return false
}

@(private = "file")
nodes_need_coalesce :: proc(nodes: []Node) -> bool {
	prev_txt := false
	for node in nodes {
		if txt, is_txt := node.derived.(^Node_Text); is_txt {
			if len(txt.text.value) == 0 || prev_txt {
				return true
			}
			prev_txt = true
		} else {
			prev_txt = false
		}
	}
	return false
}

@(private = "file")
append_coalesced_node :: proc(ctx: ^Compile_Context, out: ^[dynamic]Node, node: Node) {
	if txt, is_txt := node.derived.(^Node_Text); is_txt {
		if len(txt.text.value) == 0 {
			return
		}
		if len(out^) > 0 {
			if prev_txt, is_prev_txt := out^[len(out^) - 1].derived.(^Node_Text); is_prev_txt {
				merged := alloc_ctx_node(ctx, Node_Text)
				merged.derived = merged
				merged.text = prev_txt.text
				merged.text.value = strings.concatenate({prev_txt.text.value, txt.text.value}, ctx.allocator)
				out^[len(out^) - 1] = merged
				return
			}
		}
	}
	append(out, node)
}

splice_nodes :: proc(
	ctx: ^Compile_Context,
	nodes: []Node,
	overrides: []^Node_Block,
	flatten_blocks := false,
) -> [dynamic]Node {
	if len(overrides) == 0 && (!nodes_contain_block(nodes) || !flatten_blocks) {
		if !nodes_need_coalesce(nodes) {
			out := make([dynamic]Node, len(nodes), ctx.allocator)
			copy(out[:], nodes)
			return out
		}
		return coalesce_adjacent_text_nodes(ctx, nodes)
	}

	Splice_State :: struct {
		overrides:      []^Node_Block,
		flatten_blocks: bool,
	}
	state := Splice_State{overrides, flatten_blocks}
	map_cb :: proc(ctx: ^Compile_Context, body: []Node, user_data: rawptr) -> [dynamic]Node {
		s := cast(^Splice_State)user_data
		return splice_nodes(ctx, body, s.overrides, s.flatten_blocks)
	}

	out := make([dynamic]Node, 0, len(nodes) + (4 if flatten_blocks else 0), ctx.allocator)
	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Block:
			if child_blk := find_override_block(overrides, d.name); child_blk != nil {
				parent_has_inner_blk := nodes_contain_block(d.body[:])
				child_has_inner_blk := nodes_contain_block(child_blk.body[:])
				if !parent_has_inner_blk && !child_has_inner_blk && !nodes_contain_super(child_blk.body[:]) {
					if flatten_blocks {
						for cn in child_blk.body {
							append_coalesced_node(ctx, &out, cn)
						}
						continue
					}
					if !nodes_need_coalesce(child_blk.body[:]) {
						append_coalesced_node(ctx, &out, child_blk)
						continue
					}
				}
				inner_overrides: []^Node_Block
				if parent_has_inner_blk || child_has_inner_blk {
					inner_overrides = clone_overrides_without(ctx, overrides, d.name)
				}
				// First splice any nested blocks inside the parent block body so `super()` gets them
				spliced_parent_body := splice_nodes(ctx, d.body[:], inner_overrides, flatten_blocks) if (parent_has_inner_blk || flatten_blocks) else d.body
				// Splice any nested blocks declared inside the child override itself before substituting `super()` (do not flatten yet so nested blocks do not inherit the outer block's `super()`)
				spliced_child_body := splice_nodes(ctx, child_blk.body[:], inner_overrides, false) if child_has_inner_blk else child_blk.body
				// Replace `Node_Super` inside the child block body with `spliced_parent_body`
				final_body := substitute_super_nodes(ctx, spliced_child_body[:], spliced_parent_body[:], flatten_blocks)

				if flatten_blocks {
					for fn in final_body {
						append_coalesced_node(ctx, &out, fn)
					}
				} else {
					child_blk.body = final_body
					append_coalesced_node(ctx, &out, child_blk)
				}
			} else if !nodes_contain_block(d.body[:]) {
				if flatten_blocks {
					for dn in d.body {
						append_coalesced_node(ctx, &out, dn)
					}
				} else if !nodes_need_coalesce(d.body[:]) {
					append_coalesced_node(ctx, &out, d)
				} else {
					new_blk := alloc_ctx_node(ctx, Node_Block)
					new_blk^ = d^
					new_blk.derived = new_blk
					new_blk.body = splice_nodes(ctx, d.body[:], overrides, false)
					append_coalesced_node(ctx, &out, new_blk)
				}
			} else {
				spliced_body := splice_nodes(ctx, d.body[:], overrides, flatten_blocks)
				if flatten_blocks {
					for sn in spliced_body {
						append_coalesced_node(ctx, &out, sn)
					}
				} else {
					new_blk := alloc_ctx_node(ctx, Node_Block)
					new_blk^ = d^
					new_blk.derived = new_blk
					new_blk.body = spliced_body
					append_coalesced_node(ctx, &out, new_blk)
				}
			}
		case:
			if nodes_contain_block((&[1]Node{node})[:]) {
				if mapped, ok := map_branch_children(ctx, node, &state, map_cb); ok {
					append_coalesced_node(ctx, &out, mapped)
				} else {
					append_coalesced_node(ctx, &out, node)
				}
			} else {
				append_coalesced_node(ctx, &out, node)
			}
		}
	}
	return out
}

coalesce_adjacent_text_nodes :: proc(ctx: ^Compile_Context, nodes: []Node) -> [dynamic]Node {
	out := make([dynamic]Node, 0, len(nodes), ctx.allocator)
	for node in nodes {
		append_coalesced_node(ctx, &out, node)
	}
	return out
}

substitute_super_nodes :: proc(
	ctx: ^Compile_Context,
	nodes: []Node,
	parent_body: []Node,
	flatten_blocks := false,
) -> [dynamic]Node {
	if !nodes_contain_super(nodes) && (!flatten_blocks || !nodes_contain_block(nodes)) {
		if !nodes_need_coalesce(nodes) {
			out := make([dynamic]Node, len(nodes), ctx.allocator)
			copy(out[:], nodes)
			return out
		}
		return coalesce_adjacent_text_nodes(ctx, nodes)
	}

	Sub_State :: struct {
		parent_body:    []Node,
		flatten_blocks: bool,
	}
	state := Sub_State{parent_body, flatten_blocks}
	map_cb :: proc(ctx: ^Compile_Context, body: []Node, user_data: rawptr) -> [dynamic]Node {
		s := cast(^Sub_State)user_data
		return substitute_super_nodes(ctx, body, s.parent_body, s.flatten_blocks)
	}

	out := make([dynamic]Node, 0, len(nodes) + len(parent_body), ctx.allocator)
	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Super:
			for pn in parent_body {
				append_coalesced_node(ctx, &out, pn)
			}
		case ^Node_Block:
			// Do not substitute outer block's super inside an inner nested block
			if flatten_blocks {
				for bn in d.body {
					if inner_blk, is_iblk := bn.derived.(^Node_Block); is_iblk {
						flattened_inner := splice_nodes(ctx, (&[1]Node{inner_blk})[:], nil, true)
						for fn in flattened_inner {
							append_coalesced_node(ctx, &out, fn)
						}
					} else {
						append_coalesced_node(ctx, &out, bn)
					}
				}
			} else {
				append_coalesced_node(ctx, &out, node)
			}
		case:
			if nodes_contain_super((&[1]Node{node})[:]) || (flatten_blocks && nodes_contain_block((&[1]Node{node})[:])) {
				if mapped, ok := map_branch_children(ctx, node, &state, map_cb); ok {
					append_coalesced_node(ctx, &out, mapped)
				} else {
					append_coalesced_node(ctx, &out, node)
				}
			} else {
				append_coalesced_node(ctx, &out, node)
			}
		}
	}
	return out
}

rewrite_embeds_relative_to_dir :: proc(
	ctx: ^Compile_Context,
	templ: Template,
	base_dir: string,
	origin_file := "",
	origin_src: []byte = nil,
) -> Template {
	out: Template
	out.content = rewrite_nodes_embeds(ctx, templ.content[:], base_dir, origin_file, origin_src)
	return out
}

@(private = "file")
apply_origin_fallback :: proc(
	origin_file: ^string,
	origin_src: ^[]byte,
	fallback_file: string,
	fallback_src: []byte,
) {
	if len(origin_file^) == 0 && len(fallback_file) > 0 {
		origin_file^ = fallback_file
	}
	if origin_src^ == nil && fallback_src != nil {
		origin_src^ = fallback_src
	}
}

clone_block_with_resolved_embeds :: proc(
	ctx: ^Compile_Context,
	blk: ^Node_Block,
	base_dir: string,
	origin_file := "",
	origin_src: []byte = nil,
) -> ^Node_Block {
	if !nodes_need_embed_rewrite(blk.body[:]) && (len(blk.origin_file) == 0 || blk.origin_file == origin_file) {
		apply_origin_fallback(&blk.origin_file, &blk.origin_src, origin_file, origin_src)
		return blk
	}
	new_blk := alloc_ctx_node(ctx, Node_Block)
	new_blk^ = blk^
	new_blk.derived = new_blk
	apply_origin_fallback(&new_blk.origin_file, &new_blk.origin_src, origin_file, origin_src)
	if nodes_need_embed_rewrite(blk.body[:]) {
		new_blk.body = rewrite_nodes_embeds(ctx, blk.body[:], base_dir, origin_file, origin_src)
	}
	return new_blk
}

clone_macro_with_resolved_embeds :: proc(
	ctx: ^Compile_Context,
	mac: ^Node_Macro,
	base_dir: string,
	origin_file := "",
	origin_src: []byte = nil,
) -> ^Node_Macro {
	if !nodes_need_embed_rewrite(mac.body[:]) && (len(mac.origin_file) == 0 || mac.origin_file == origin_file) {
		apply_origin_fallback(&mac.origin_file, &mac.origin_src, origin_file, origin_src)
		return mac
	}
	new_mac := alloc_ctx_node(ctx, Node_Macro)
	new_mac^ = mac^
	new_mac.derived = new_mac
	apply_origin_fallback(&new_mac.origin_file, &new_mac.origin_src, origin_file, origin_src)
	if nodes_need_embed_rewrite(mac.body[:]) {
		new_mac.body = rewrite_nodes_embeds(ctx, mac.body[:], base_dir, origin_file, origin_src)
	}
	return new_mac
}

@(private = "file")
nodes_need_embed_rewrite :: proc(nodes: []Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_need_embed_rewrite(body)
	}
	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Embed:
			if len(d.resolved_path) == 0 || len(d.origin_file) == 0 {
				return true
			}
		case ^Node_Super:
			if len(d.origin_file) == 0 {
				return true
			}
		case ^Node_Call:
			if len(d.origin_file) == 0 {
				return true
			}
		case ^Node_Block:
			if nodes_need_embed_rewrite(d.body[:]) {
				return true
			}
		case ^Node_Macro:
			if nodes_need_embed_rewrite(d.body[:]) {
				return true
			}
		case:
			if !walk_branch_children(node, nil, visit_cb) {
				return true
			}
		}
	}
	return false
}

rewrite_nodes_embeds :: proc(
	ctx: ^Compile_Context,
	nodes: []Node,
	base_dir: string,
	origin_file := "",
	origin_src: []byte = nil,
) -> [dynamic]Node {
	if !nodes_need_embed_rewrite(nodes) {
		out := make([dynamic]Node, len(nodes), ctx.allocator)
		copy(out[:], nodes)
		return out
	}

	Rewrite_State :: struct {
		base_dir:    string,
		origin_file: string,
		origin_src:  []byte,
	}
	state := Rewrite_State{base_dir, origin_file, origin_src}
	map_cb :: proc(ctx: ^Compile_Context, body: []Node, user_data: rawptr) -> [dynamic]Node {
		s := cast(^Rewrite_State)user_data
		return rewrite_nodes_embeds(ctx, body, s.base_dir, s.origin_file, s.origin_src)
	}

	out := make([dynamic]Node, 0, len(nodes), ctx.allocator)
	for node in nodes {
		#partial switch d in node.derived {
		case ^Node_Embed:
			rel := normalize_slash_path(d.path.value[1 : len(d.path.value)-1], ctx.allocator)
			new_emb := alloc_ctx_node(ctx, Node_Embed)
			new_emb^ = d^
			new_emb.derived = new_emb
			apply_origin_fallback(&new_emb.origin_file, &new_emb.origin_src, origin_file, origin_src)
			if len(new_emb.resolved_path) == 0 && !is_abs_slash_path(rel) && len(base_dir) > 0 {
				if len(origin_file) > 0 {
					new_emb.resolved_path = join_relative_slash_path(origin_file, rel, ctx.allocator)
				} else {
					new_emb.resolved_path = clean_slash_path(strings.concatenate({base_dir, "/", rel}, ctx.allocator), ctx.allocator)
				}
			}
			append(&out, new_emb)
		case ^Node_Super:
			new_sup := alloc_ctx_node(ctx, Node_Super)
			new_sup^ = d^
			new_sup.derived = new_sup
			apply_origin_fallback(&new_sup.origin_file, &new_sup.origin_src, origin_file, origin_src)
			append(&out, new_sup)
		case ^Node_Call:
			new_call := alloc_ctx_node(ctx, Node_Call)
			new_call^ = d^
			new_call.derived = new_call
			apply_origin_fallback(&new_call.origin_file, &new_call.origin_src, origin_file, origin_src)
			append(&out, new_call)
		case ^Node_Block:
			append(&out, clone_block_with_resolved_embeds(ctx, d, base_dir, origin_file, origin_src))
		case ^Node_Macro:
			append(&out, clone_macro_with_resolved_embeds(ctx, d, base_dir, origin_file, origin_src))
		case:
			if nodes_need_embed_rewrite((&[1]Node{node})[:]) {
				if mapped, ok := map_branch_children(ctx, node, &state, map_cb); ok {
					append(&out, mapped)
				} else {
					append(&out, node)
				}
			} else {
				append(&out, node)
			}
		}
	}
	return out
}

// ============================================================================
// Goal 5: Embed Resolution with Full Trace Stack & Cycle Detection
// ============================================================================

Embed_Callback_State :: struct {
	ctx:          ^Compile_Context,
	current_file: string,
	current_src:  []byte,
}

embed_parser_with_ctx :: proc(t: ^Transpiler, node: ^Node_Embed, user_data: rawptr) -> bool {
	state := cast(^Embed_Callback_State)user_data
	ctx := state.ctx
	context.allocator = ctx.allocator
	context.temp_allocator = ctx.allocator

	embed_origin_file := node.origin_file if len(node.origin_file) > 0 else state.current_file
	embed_origin_src := node.origin_src if node.origin_src != nil else state.current_src

	raw_path := normalize_slash_path(node.path.value[1 : len(node.path.value)-1], ctx.allocator)
	fullpath: string
	if len(node.resolved_path) > 0 {
		fullpath = normalize_slash_path(node.resolved_path, ctx.allocator)
	} else if is_abs_slash_path(raw_path) {
		fullpath = raw_path
	} else {
		fullpath = join_relative_slash_path(embed_origin_file, raw_path, ctx.allocator)
	}

	embed_pos := tokenizer.Pos{
		offset = node.path.pos.offset,
		line   = node.path.pos.line + 1,
		column = node.path.pos.col + 1,
		file   = embed_origin_file,
	}

	// Cycle check across active stack
	for frame in get_trace_frames(ctx) {
		if frame.file == fullpath {
			record_diagnostic(
				ctx,
				embed_pos,
				embed_origin_src,
				len(node.path.value),
				"circular embed detected: %q embeds %q which is already being embedded",
				embed_origin_file,
				fullpath,
			)
			return false
		}
	}

	prev_file := state.current_file
	prev_src := state.current_src
	defer {
		state.current_file = prev_file
		state.current_src = prev_src
	}

	embed_frame_idx := push_trace_frame(ctx, Trace_Frame{
		kind    = .Embed,
		pos     = embed_pos,
		file    = fullpath,
		col_len = len(node.path.value),
	})
	defer pop_trace_frame(ctx)

	templ, loaded_src, ok := load_and_resolve_template_file(
		ctx,
		fullpath,
		embed_pos,
		embed_origin_src,
		len(node.path.value),
	)
	if !ok {
		set_trace_frame_snippet(ctx, embed_frame_idx, extract_line_snippet(embed_origin_src, embed_pos.line, ctx.allocator))
		return false
	}

	state.current_file = fullpath
	state.current_src = loaded_src

	transpile_template_nodes(t, templ.content[:])

	return true
}

write_generated_file_header_body :: proc(w: io.Writer, pkg_name := "temple", temple_import := "") {
	actual_pkg := pkg_name if len(pkg_name) > 0 else "temple"
	if actual_pkg == "temple" {
		io.write_string(
			w,
			`package temple

import __temple_io "core:io"

compiled_inline :: compiled

/*
Returns the compiled template for the template file at the given path.

Use 'Compiled.with' to render the template into the given (recommended to be buffered) writer with 'this' set to the given T in the template.
Use 'Compiled.approx_bytes' to resize your buffered writer before calling.

**This procedure and file is generated based on your templates, if there is an error here, it most likely originates from your template.**
*/
compiled :: proc "contextless" ($path: string, $T: typeid) -> Compiled(T) {
`,
		)
	} else {
		imp := temple_import if len(temple_import) > 0 else "shared:temple"
		fmt.wprintf(
			w,
			`package %s

import __temple_io "core:io"
import __temple %q

compiled_inline :: compiled
@(private = "file")
__temple_default :: __temple.__temple_default

/*
Returns the compiled template for the template file at the given path.

Use 'Compiled.with' to render the template into the given (recommended to be buffered) writer with 'this' set to the given T in the template.
Use 'Compiled.approx_bytes' to resize your buffered writer before calling.

**This procedure and file is generated based on your templates, if there is an error here, it most likely originates from your template.**
*/
compiled :: proc "contextless" ($path: string, $T: typeid) -> __temple.Compiled(T) {{
`,
			actual_pkg,
			imp,
		)
	}
}

write_generated_file_footer :: proc(w: io.Writer, has_calls: bool) {
	if has_calls {
		io.write_string(w, " else {\n\t\t#panic(\"undefined template \\\"\" + path + \"\\\" did you run the temple transpiler?\")\n\t}\n}\n")
	} else {
		io.write_string(w, "\t#panic(\"undefined template \\\"\" + path + \"\\\" did you run the temple transpiler?\")\n}\n")
	}
}
