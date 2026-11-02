package temple_cli

import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"

cache_raw_template :: proc(ctx: ^Compile_Context, fullpath: string, cached: Cached_Template) {
	small_map_set(&ctx.raw_cache, fullpath, cached, ctx.allocator)
}

@(private = "file")
lookup_raw_cache :: proc(ctx: ^Compile_Context, fullpath: string) -> (Cached_Template, bool) {
	return small_map_get(&ctx.raw_cache, fullpath)
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
	return small_map_get(&ctx.resolved_cache, fullpath)
}

@(private = "file")
store_resolved_cache :: proc(ctx: ^Compile_Context, fullpath: string, resolved: Template) {
	small_map_set_if_absent(&ctx.resolved_cache, fullpath, resolved, ctx.allocator)
}

@(private = "file")
is_extending_parent :: proc(ctx: ^Compile_Context) -> bool {
	frames := get_trace_frames(ctx)
	return len(frames) > 0 && frames[len(frames) - 1].kind == .Extends
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

	parent_mode := is_extending_parent(ctx)
	if parent_mode {
		if cached_res, found := lookup_resolved_cache(ctx, fullpath); found {
			return cached_res, raw_src, true
		}
	}

	resolved, res_ok := resolve_template_inheritance(ctx, raw_templ, raw_src, fullpath)
	if !res_ok {
		return {}, nil, false
	}
	if parent_mode {
		store_resolved_cache(ctx, fullpath, resolved)
	}
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
			} else if node_contains_block(node) {
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
	child_blocks_arr: Small_Array(16, ^Node_Block)
	child_macros_arr: Small_Array(16, ^Node_Macro)

	for node in child_templ.content {
		if blk, is_blk := node.derived.(^Node_Block); is_blk {
			normalized_blk := clone_scoped_node_with_resolved_embeds(ctx, blk, child_dir, child_file, child_src)
			replaced := false
			cur_blocks := small_array_slice(&child_blocks_arr)
			for i in 0 ..< len(cur_blocks) {
				if cur_blocks[i].name == blk.name {
					cur_blocks[i] = normalized_blk
					replaced = true
					break
				}
			}
			if !replaced {
				small_array_append(&child_blocks_arr, normalized_blk, ctx.allocator)
			}
		} else if mac, is_mac := node.derived.(^Node_Macro); is_mac {
			normalized_mac := clone_scoped_node_with_resolved_embeds(ctx, mac, child_dir, child_file, child_src)
			small_array_append(&child_macros_arr, normalized_mac, ctx.allocator)
		}
	}
	child_blocks := small_array_slice(&child_blocks_arr)
	child_macro_order := small_array_slice(&child_macros_arr)

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
	flatten_blocks := !is_extending_parent(ctx)
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
	if !flatten_blocks && len(child_file) > 0 && child_file != ctx.inline_file {
		store_resolved_cache(ctx, child_file, spliced)
	}
	return spliced, true
}

@(private = "file")
node_contains_call :: proc(node: Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_contain_call(body)
	}
	#partial switch d in node.derived {
	case ^Node_Call:
		return true
	case ^Node_Block:
		return nodes_contain_call(d.body[:])
	case ^Node_Macro:
		return nodes_contain_call(d.body[:])
	case:
		return !walk_branch_children(node, nil, visit_cb)
	}
}

@(private = "file")
nodes_contain_call :: proc(nodes: []Node) -> bool {
	for node in nodes {
		if node_contains_call(node) {
			return true
		}
	}
	return false
}

@(private = "file")
node_contains_any_super :: proc(node: Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_contain_any_super(body)
	}
	#partial switch d in node.derived {
	case ^Node_Super:
		return true
	case ^Node_Block:
		return nodes_contain_any_super(d.body[:])
	case:
		return !walk_branch_children(node, nil, visit_cb)
	}
}

@(private = "file")
nodes_contain_any_super :: proc(nodes: []Node) -> bool {
	for node in nodes {
		if node_contains_any_super(node) {
			return true
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
	macros_arr: Small_Array(16, ^Node_Macro)
	macros_slice := collect_top_level_macros(nodes, &macros_arr, ctx.allocator)
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
node_contains_block :: proc(node: Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_contain_block(body)
	}
	if _, is_blk := node.derived.(^Node_Block); is_blk {
		return true
	}
	return !walk_branch_children(node, nil, visit_cb)
}

@(private = "file")
nodes_contain_block :: proc(nodes: []Node) -> bool {
	for node in nodes {
		if node_contains_block(node) {
			return true
		}
	}
	return false
}

@(private = "file")
node_contains_super :: proc(node: Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_contain_super(body)
	}
	#partial switch d in node.derived {
	case ^Node_Super:
		return true
	case ^Node_Block:
		// Do not inspect inside nested `Node_Block` (outer block's `super` does not substitute there)
		return false
	case:
		return !walk_branch_children(node, nil, visit_cb)
	}
}

@(private = "file")
nodes_contain_super :: proc(nodes: []Node) -> bool {
	for node in nodes {
		if node_contains_super(node) {
			return true
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
					new_blk := alloc_ctx_node(ctx, Node_Block)
					new_blk^ = child_blk^
					new_blk.derived = new_blk
					new_blk.body = final_body
					append_coalesced_node(ctx, &out, new_blk)
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
			if node_contains_block(node) {
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
						flattened_inner := splice_nodes(ctx, inner_blk.body[:], nil, true)
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
			if node_contains_super(node) || (flatten_blocks && node_contains_block(node)) {
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

clone_scoped_node_with_resolved_embeds :: proc(
	ctx: ^Compile_Context,
	node: ^$T,
	base_dir: string,
	origin_file := "",
	origin_src: []byte = nil,
) -> ^T {
	if !nodes_need_embed_rewrite(node.body[:]) && (len(node.origin_file) == 0 || node.origin_file == origin_file) {
		apply_origin_fallback(&node.origin_file, &node.origin_src, origin_file, origin_src)
		return node
	}
	cloned := alloc_ctx_node(ctx, T)
	cloned^ = node^
	cloned.derived = cloned
	apply_origin_fallback(&cloned.origin_file, &cloned.origin_src, origin_file, origin_src)
	if nodes_need_embed_rewrite(node.body[:]) {
		cloned.body = rewrite_nodes_embeds(ctx, node.body[:], base_dir, origin_file, origin_src)
	}
	return cloned
}

@(private = "file")
node_needs_embed_rewrite :: proc(node: Node) -> bool {
	visit_cb :: proc(body: []Node, _: rawptr) -> bool {
		return !nodes_need_embed_rewrite(body)
	}
	#partial switch d in node.derived {
	case ^Node_Embed:
		return len(d.resolved_path) == 0 || len(d.origin_file) == 0
	case ^Node_Super:
		return len(d.origin_file) == 0
	case ^Node_Call:
		return len(d.origin_file) == 0
	case ^Node_Block:
		return nodes_need_embed_rewrite(d.body[:])
	case ^Node_Macro:
		return nodes_need_embed_rewrite(d.body[:])
	case:
		return !walk_branch_children(node, nil, visit_cb)
	}
}

@(private = "file")
nodes_need_embed_rewrite :: proc(nodes: []Node) -> bool {
	for node in nodes {
		if node_needs_embed_rewrite(node) {
			return true
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
			append(&out, clone_scoped_node_with_resolved_embeds(ctx, d, base_dir, origin_file, origin_src))
		case ^Node_Macro:
			append(&out, clone_scoped_node_with_resolved_embeds(ctx, d, base_dir, origin_file, origin_src))
		case:
			if node_needs_embed_rewrite(node) {
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
