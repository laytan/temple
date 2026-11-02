package temple_cli

import "core:fmt"
import "core:io"
import "core:mem"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

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
	existing_stripped := normalize_line_endings_lf(strip_generated_timestamp_header(existing_content), context.temp_allocator)
	new_stripped := normalize_line_endings_lf(strip_generated_timestamp_header(new_body), context.temp_allocator)
	return existing_stripped == new_stripped
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
	prev_alloc := context.allocator
	prev_temp := context.temp_allocator
	context.allocator = ctx.allocator
	context.temp_allocator = ctx.allocator
	defer {
		context.allocator = prev_alloc
		context.temp_allocator = prev_temp
	}

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
