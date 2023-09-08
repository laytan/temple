package temple_cli

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Compile_Call :: struct {
	pos:  tokenizer.Pos,
	type: Call_Type,
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

main :: proc() {
	if len(os.args) < 3 {
		error(nil, "You need to pass a path and the path to temple")
	}

	calls := collect_compile_calls(os.args[1])
	free_all(context.temp_allocator)

	transpile_calls(os.args[2], calls[:])
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

collect_compile_calls :: proc(
	root: string,
	allocator := context.allocator,
) -> (
	calls: [dynamic]Compile_Call,
) {
	Collect_State :: struct {
		allocator: mem.Allocator,
		pkg:       ^ast.Package,
		calls:     ^[dynamic]Compile_Call,
	}

	s: Collect_State
	s.calls = &calls
	s.calls.allocator = allocator
	s.allocator = allocator

	// All stuff having to do with collection can be on the temp_allocator,
	// only the returning calls are allocated on the allocator that is given.
	context.allocator = context.temp_allocator

	fmt.printf("looking for compile calls in %q\n", root)

	// TODO: does not support symbolic links, communicate it to users.

	filepath.walk(
		root,
		proc(
			info: os.File_Info,
			in_err: os.Errno,
			user_data: rawptr,
		) -> (
			err: os.Errno,
			skip_dir: bool,
		) {
			if !info.is_dir {
				return
			}

			if in_err != os.ERROR_NONE {
				warn(nil, "%q error code %i", info.fullpath, in_err)
				return
			}


			pkg, ok := parser.parse_package_from_path(info.fullpath)
			if !ok {
				warn(nil, "%q is not a package", info.fullpath)
				return
			}

			s := cast(^Collect_State)user_data
			s.pkg = pkg

			// TODO: multithreading
			// TODO: return early if not imported
			// TODO; resolve any way it can be called (like alias `c :: temple.compiled`, or different import name `import t "temple"`)

			v := ast.Visitor {
				data = s,
				visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
					if node == nil do return nil

					#partial switch n in node.derived {
					case ^ast.Call_Expr:
						selector, ok := n.expr.derived_expr.(^ast.Selector_Expr)
						if !ok do return nil

						ident, iok := selector.expr.derived_expr.(^ast.Ident)
						if !iok do return nil

						if ident.name != "temple" {
							return nil
						}

						if selector.field.name != "compiled" && selector.field.name != "compiled_inline" {
							return nil
						}

						s := cast(^Collect_State)visitor.data

						if len(n.args) != 2 {
							error(
								n.pos,
								"calls to `temple.compiled` and `temple.compiled_inline` expect 2 arguments, got %i",
								len(n.args),
							)
						}

						path, pok := n.args[0].derived_expr.(^ast.Basic_Lit)
						if !pok || path.tok.kind != .String {
							error(
								n.pos,
								"the path/template argument of `temple.compiled` and `temple.compiled_inline` only accepts string literals",
							)
						}

						c: Compile_Call
						c.pos = path.pos
						c.pos.file = strings.clone(c.pos.file, s.allocator)

						switch selector.field.name {
						case "compiled":
							cp: Call_Path
							defer c.type = cp

							unqouted_path := strings.trim(path.tok.text, "\"`")

							cp.relpath = strings.clone(unqouted_path, s.allocator)
							cp.fullpath = filepath.join({s.pkg.fullpath, unqouted_path}, s.allocator)

						case "compiled_inline":
							cp: Call_Inline
							cp.template = strings.clone(strings.trim(path.tok.text, "\"`"), s.allocator)
							c.type = cp
						}

						append(s.calls, c)
					}

					return visitor
				},
			}

			ast.walk(&v, pkg)
			return
		},
		&s,
	)

	return
}

transpile_calls :: proc(temple_path: string, calls: []Compile_Call) {
	compiled_path := filepath.join({temple_path, "templates.odin"})
	handle, errno := os.open(compiled_path, os.O_TRUNC | os.O_RDWR | os.O_CREATE, 0o600)
	if errno != os.ERROR_NONE {
		error(nil, "%q: unable to open file for generation", compiled_path)
	}
	defer os.close(handle)

	s := os.stream_from_handle(handle)

	bw: bufio.Writer
	bufio.writer_init(&bw, s)
	defer bufio.writer_destroy(&bw)
	defer bufio.writer_flush(&bw)

	w := bufio.writer_to_writer(&bw)

	good_calls := len(calls)

	write_generated_file_header(w, good_calls > 0)

	for c, i in calls {
		if !write_transpiled_call(w, c) {
			good_calls -= 1
			continue
		}

		if i != len(calls)-1 {
			io.write_string(w, "else")
		}
	}

	write_generated_file_footer(w, good_calls > 0)

	fmt.printf("found %i compile calls of which %i where successfully compiled\n", len(calls), good_calls)
}

write_generated_file_header :: proc(w: io.Writer, has_calls: bool) {
	if has_calls {
		fmt.wprintf(
			w,
			"/* This file was generated by temple on %v - DO NOT EDIT! */\n",
			time.now(),
		)
	}

	io.write_string(
		w,
		`/* This file is generated by temple - DO NOT EDIT! */

package temple

import __temple_io "core:io"

compiled_inline :: compiled

/*
Returns the compiled template for the template file at the given path.

Use 'Compiled.with' to render the template into the given (recommended to be buffered) writer with 'this' set to the given T in the template.
Use 'Compiled.approx_bytes' to resize your buffered writer before calling.

**This procedure and file is generated based on your templates, if there is an error here, it most likely originates from your template.**
*/
compiled :: proc($path: string, $T: typeid) -> Compiled(T) {
`,
	)
}

// NOTE: we should not use `error` in this scope, because that would close the file in a bad state.
write_transpiled_call :: proc(w: io.Writer, call: Compile_Call) -> (ok: bool) {
	// Anything allocated is not needed anymore when we return.
	context.allocator = context.temp_allocator

	data: []byte
	identifier: string
	file: string

	switch t in call.type {
	case Call_Path:
		identifier = t.relpath
		file = t.fullpath
		d, ok := os.read_entire_file_from_filename(t.fullpath)
		if !ok {
			warn(nil, "unable to read template file at %q, skipping", t.fullpath)
			return
		}
		data = d
	case Call_Inline:
		identifier = t.template
		data = transmute([]byte)t.template
		file = call.pos.file
	}

	parser: Parser
	parser_init(&parser, data)
	templ := parse(&parser)
	if err, has_err := templ.err.?; has_err {
		pos := tokenizer.Pos{
			offset = err.pos.offset,
			line   = err.pos.line + 1,
			column = err.pos.col + 1,
			file   = file,
		}
		warn(pos, "skipping template because of the error: %s", err.msg)
		return
	}

	transpile(w, identifier, templ, embed_parser, &file)

	ok = true
	return
}

write_generated_file_footer :: proc(w: io.Writer, has_calls: bool) {
	if has_calls {
		io.write_string(w, ` else {
		#panic("undefined template \"" + path + "\" did you run the temple transpiler?")
	}
}`)
	} else {
		io.write_string(w, `	#panic("undefined template \"" + path + "\" did you run the temple transpiler?")
}`)
	}
}

embed_parser :: proc(node: ^Node_Embed, parent_path_: rawptr) -> (Template, bool) {
	parent_path := (cast(^string)parent_path_)^
	relpath := node.path.value[1:len(node.path.value)-1]
	fullpath := filepath.join({filepath.dir(parent_path), relpath})

	data, ok := os.read_entire_file_from_filename(fullpath)
	if !ok {
		pos := tokenizer.Pos{
			offset = node.path.pos.offset,
			line   = node.path.pos.line + 1,
			column = node.path.pos.col + 1,
			file   = parent_path,
		}
		warn(pos, "unable to read embedded template file at %q, skipping", fullpath)
		return {}, false
	}

	// TODO: better error handling.

	parser: Parser
	parser_init(&parser, data)
	templ := parse(&parser)
	if err, has_err := templ.err.?; has_err {
		pos := tokenizer.Pos{
			offset = err.pos.offset,
			line   = err.pos.line + 1,
			column = err.pos.col + 1,
			file   = fullpath,
		}
		warn(pos, "skipping template because of the error: %s", err.msg)
		return {}, false
	}

	return templ, templ.err == nil
}
