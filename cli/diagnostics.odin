package temple_cli

import "core:fmt"
import "core:mem"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"

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
	trace:     []Trace_Frame, // Cloned snapshot of Compile_Context.trace_stack
}

Cached_Template :: struct {
	source:   []byte,
	template: Template,
}

Compile_Context :: struct {
	trace_stack:    Small_Array(8, Trace_Frame),
	diagnostics:    [dynamic]Diagnostic,
	raw_cache:      Small_Map(8, string, Cached_Template),
	resolved_cache: Small_Map(8, string, Template),
	used_files:     map[string]bool,
	allocator:      mem.Allocator,
	inline_file:    string,
	inline_pos:     tokenizer.Pos,
	external_pkg:   bool,
	ast_slab:       Node_Slab,
}

Transpiled_Template :: struct {
	identifier:  string,
	code:        string,
	diagnostics: [dynamic]Diagnostic,
	ok:          bool,
}

alloc_ctx_node :: #force_inline proc(ctx: ^Compile_Context, $T: typeid) -> ^T {
	return slab_alloc_node(&ctx.ast_slab, T, ctx.allocator)
}

push_trace_frame :: proc(ctx: ^Compile_Context, frame: Trace_Frame) -> int {
	return small_array_append(&ctx.trace_stack, frame, ctx.allocator)
}

pop_trace_frame :: proc(ctx: ^Compile_Context) {
	small_array_pop(&ctx.trace_stack)
}

get_trace_frames :: #force_inline proc(ctx: ^Compile_Context) -> []Trace_Frame {
	return small_array_slice(&ctx.trace_stack)
}

set_trace_frame_snippet :: proc(ctx: ^Compile_Context, idx: int, snippet: string) {
	if idx >= 0 && idx < small_array_len(&ctx.trace_stack) {
		small_array_get_ptr(&ctx.trace_stack, idx).snippet = snippet
	}
}

clear_trace_frames :: proc(ctx: ^Compile_Context) {
	small_array_clear(&ctx.trace_stack)
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
	prev_alloc := context.allocator
	context.allocator = ctx.allocator
	defer context.allocator = prev_alloc

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
