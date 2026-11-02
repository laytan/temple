package temple_cli

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import odin_parser "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

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

Odin_Candidate_File :: struct {
	fullpath: string,
	src:      string,
	ast_file: ^ast.File,
}

collect_compile_calls :: proc(
	root: string,
	allocator := context.allocator,
	out_errors: ^[dynamic]string = nil,
) -> (
	calls: [dynamic]Compile_Call,
) {
	calls.allocator = allocator
	seen_identifiers := make(map[string]string, context.temp_allocator)

	prev_alloc := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = prev_alloc

	fmt.printf("looking for compile calls in %q\n", root)

	// TODO: does not support symbolic links, communicate it to users.

	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, root)

	Walk_Dirs_State :: struct {
		root: string,
		dirs: ^[dynamic]string,
	}
	state := Walk_Dirs_State{root = root, dirs = &dirs}
	walk_project_tree(root, &state, proc(info: os.File_Info, user_data: rawptr) {
		s := cast(^Walk_Dirs_State)user_data
		if info.type == .Directory && info.fullpath != s.root {
			append(s.dirs, strings.clone(info.fullpath, context.temp_allocator))
		}
	}, warn_on_error = true)

	slice.sort(dirs[1:])
	for dir_path in dirs {
		collect_from_dir(dir_path, &calls, &seen_identifiers, allocator, out_errors)
	}

	return
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

	// Resolve constant procedure aliases (e.g. `c :: temple.compiled`, `ci :: t.compiled_inline`, or `render :: views.compiled`)
	// Iteratively resolve aliases in case of chained aliases `c1 :: temple.compiled; c2 :: c1`
	for _ in 0 ..< 3 {
		for file, file_idx in parsed_files {
			temple_names := file_temple_pkgs[file_idx]
			for decl in file.decls {
				collect_proc_aliases(decl, temple_names[:], &pkg_proc_aliases, allocator)
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
		raw := lit[1 : len(lit)-1]
		if strings.index_byte(raw, '\r') != -1 {
			return normalize_line_endings_lf(raw, context.temp_allocator), true
		}
		return raw, true
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

		// Walk arguments first in case of nested expressions
		for arg in n.args {
			ast.walk(visitor, arg)
		}

		if len(n.args) == 0 {
			if !is_strict {
				return visitor
			}
			collect_error(
				ctx,
				n.pos,
				"missing arguments in call to `temple.compiled` (expected `path` and `T`)",
			)
			return nil
		}

		if len(n.args) > 2 {
			if !is_strict {
				return visitor
			}
			collect_error(
				ctx,
				n.args[2].pos,
				"too many arguments in call to `temple.compiled` (expected at most 2: `path` and `T`)",
			)
			return nil
		}

		path_arg: ^ast.Expr = nil
		has_path := false
		has_T := false
		seen_named := false
		had_arg_err := false

		for arg, idx in n.args {
			if fv, is_fv := arg.derived_expr.(^ast.Field_Value); is_fv {
				seen_named = true
				if field_ident, ok := fv.field.derived_expr.(^ast.Ident); ok {
					if field_ident.name == "path" {
						if has_path {
							if is_strict {
								collect_error(ctx, fv.pos, "duplicate `path` argument in call to `temple.compiled`")
							}
							had_arg_err = true
						}
						has_path = true
						path_arg = fv.value
					} else if field_ident.name == "T" {
						if has_T {
							if is_strict {
								collect_error(ctx, fv.pos, "duplicate `T` argument in call to `temple.compiled`")
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
