package benchmarks

import "core:fmt"
import "core:io"
import "core:mem"
import "core:odin/ast"
import odin_parser "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "core:time"

import temple ".."
import temple_cli "../cli"

Host_State :: enum {
	Healthy,
	Degraded,
	Offline,
}

Host_Row :: struct {
	host:       string,
	region:     string,
	endpoint:   string,
	latency_ms: f64,
	state:      Host_State,
}

Dashboard_Ctx :: struct {
	page_title: string,
	boot_token: string,
	docs_url:   string,
	env:        string,
	rows:       []Host_Row,
}

dashboard_tmpl := compiled("templates/dashboard.temple.html", Dashboard_Ctx)
section_layout_tmpl := compiled("templates/section_layout.temple.html", Dashboard_Ctx)

inline_card_tmpl := compiled_inline(
	`<article class="card"><h2>{{ this.host | default("unknown") }}</h2><span>{{ this.latency_ms | fmt("%.2f ms") }}</span></article>`,
	Host_Row,
)

inline_macro_badge_tmpl := compiled_inline(
	`{%- macro badge(label: string, status_class := "ok") -%}<span class="badge badge--{{ status_class }}">{{ label | default("N/A") }}</span>{%- end -%}{%- call badge(this.host, "ok") -%}`,
	Host_Row,
)

inline_fmt_simple_tmpl := compiled_inline(
	`{{ this.host | fmt("<span class='host'>%s</span>") | raw }} ({{ len(this.host) | fmt("len=%i") }})`,
	Host_Row,
)

inline_embed_badge_tmpl := compiled_inline(
	`{%- embed "templates/badge_component.temple.html"(label = this.host, status_class = "ok") -%}`,
	Host_Row,
)

Default_Chain_Ctx :: struct {
	opt_tag:       Maybe(string),
	empty_region:  string,
	tags:          []string,
	fallback_tags: []string,
}

inline_default_chain_tmpl := compiled_inline(
	`{{ this.opt_tag | default("untagged & global") | url_param }}/{{ this.empty_region | default("us-east-1") }} ({{ this.tags | default(this.fallback_tags) | len }})`,
	Default_Chain_Ctx,
)

Bench_Result :: struct {
	name:         string,
	iterations:   int,
	ns_per_op:    f64,
	bytes_per_op: int,
	mb_per_sec:   f64,
	allocs_per_op: int,
	alloc_bytes_per_op: int,
}

sink_bytes: int

run_bench :: proc(
	name: string,
	iterations: int,
	bytes_processed_override: int,
	fn: proc() -> int,
) -> Bench_Result {
	// Warmup
	warmup := clamp(iterations / 20, 10, 1000)
	for _ in 0 ..< warmup {
		sink_bytes += fn()
	}

	track_heap: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track_heap, context.allocator)
	defer mem.tracking_allocator_destroy(&track_heap)

	track_temp: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track_temp, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&track_temp)

	prev_alloc := context.allocator
	prev_temp := context.temp_allocator
	context.allocator = mem.tracking_allocator(&track_heap)
	context.temp_allocator = mem.tracking_allocator(&track_temp)

	sw: time.Stopwatch
	time.stopwatch_start(&sw)

	last_bytes := 0
	for _ in 0 ..< iterations {
		last_bytes = fn()
		sink_bytes += last_bytes
	}

	time.stopwatch_stop(&sw)

	context.allocator = prev_alloc
	context.temp_allocator = prev_temp

	elapsed_ns := f64(time.duration_nanoseconds(time.stopwatch_duration(sw)))
	ns_op := elapsed_ns / f64(iterations)

	b_op := bytes_processed_override if bytes_processed_override > 0 else last_bytes
	mb_s := 0.0
	if elapsed_ns > 0 && b_op > 0 {
		total_bytes := f64(b_op) * f64(iterations)
		seconds := elapsed_ns / 1e9
		mb_s = (total_bytes / (1024.0 * 1024.0)) / seconds
	}

	total_allocs := int(track_heap.total_allocation_count + track_temp.total_allocation_count)
	total_alloc_bytes := int(track_heap.total_memory_allocated + track_temp.total_memory_allocated)

	return Bench_Result{
		name               = name,
		iterations         = iterations,
		ns_per_op          = ns_op,
		bytes_per_op       = b_op,
		mb_per_sec         = mb_s,
		allocs_per_op      = total_allocs / iterations,
		alloc_bytes_per_op = total_alloc_bytes / iterations,
	}
}

print_results_table :: proc(title: string, results: []Bench_Result) {
	fmt.printf("\n### %s\n\n", title)
	fmt.println("| Benchmark | Iterations | Time (ns/op) | Throughput (MB/s) | Output / Input B/op | Allocs/op | Alloc B/op |")
	fmt.println("| :--- | ---: | ---: | ---: | ---: | ---: | ---: |")
	for r in results {
		tp_str := fmt.tprintf("%.1f MB/s", r.mb_per_sec) if r.mb_per_sec > 0 else "—"
		fmt.printf(
			"| `%s` | %i | %.1f ns | %s | %i B | %i | %i B |\n",
			r.name,
			r.iterations,
			r.ns_per_op,
			tp_str,
			r.bytes_per_op,
			r.allocs_per_op,
			r.alloc_bytes_per_op,
		)
	}
}

main :: proc() {
	fmt.println("# Temple Benchmark Suite")

	// Prepare shared pre-allocated output buffer (128 KB) so runtime escaping & rendering
	// benchmarks measure pure template execution and verify 0 allocations per operation.
	render_sb := strings.builder_make(0, 131072)
	defer strings.builder_destroy(&render_sb)
	render_w := strings.to_writer(&render_sb)

	// Prepare 64 KB clean HTML-like text and 64 KB mixed HTML text for throughput tests
	clean_chunk := "The quick brown fox jumps over the lazy dog 0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ! "
	clean_64k_sb := strings.builder_make(0, 65536)
	defer strings.builder_destroy(&clean_64k_sb)
	for strings.builder_len(clean_64k_sb) < 65536 {
		strings.write_string(&clean_64k_sb, clean_chunk)
	}
	clean_64k := strings.to_string(clean_64k_sb)[:65536]

	xss_chunk := `<script attr="val" & 'single'>alert("xss" & '1');</script><span>Hello &amp; World</span>`
	mixed_64k_sb := strings.builder_make(0, 65536)
	defer strings.builder_destroy(&mixed_64k_sb)
	for strings.builder_len(mixed_64k_sb) < 65536 {
		strings.write_string(&mixed_64k_sb, clean_chunk)
		strings.write_string(&mixed_64k_sb, xss_chunk)
	}
	mixed_64k := strings.to_string(mixed_64k_sb)[:65536]

	// Prepare 50-row dashboard dataset
	rows := make([]Host_Row, 50)
	defer delete(rows)
	for i in 0 ..< 50 {
		state := Host_State(i % 3)
		rows[i] = Host_Row{
			host       = "edge-node-01.prod.internal",
			region     = "us-east-1" if i % 2 == 0 else "",
			endpoint   = "https://metrics.example.com/nodes/view",
			latency_ms = 12.34 + f64(i) * 0.75,
			state      = state,
		}
	}

	dash_ctx := Dashboard_Ctx{
		page_title = "Production Fleet <Cluster A & B>",
		boot_token = `tok_99a\b"c'</script>`,
		docs_url   = "https://docs.example.com/fleet?tab=nodes&sort=asc",
		env        = "prod us-east & eu-west=1",
		rows       = rows,
	}

	runtime_results := make([dynamic]Bench_Result)
	defer delete(runtime_results)

	// 1. HTML Escaping microbenchmarks
	clean_short := "Welcome to Temple: zero-overhead compile-time HTML templates for Odin!"
	g_render_sb = &render_sb
	g_render_w = render_w
	g_str_input = clean_short
	append(&runtime_results, run_bench(
		"html_escape (clean ASCII 70B)",
		1_000_000,
		len(clean_short),
		bench_escape_string,
	))

	g_str_input = xss_chunk
	append(&runtime_results, run_bench(
		"html_escape (dense XSS 88B)",
		500_000,
		len(xss_chunk),
		bench_escape_string,
	))

	g_str_input = clean_64k
	append(&runtime_results, run_bench(
		"html_escape (clean 64KB doc)",
		20_000,
		len(clean_64k),
		bench_escape_string,
	))

	g_str_input = mixed_64k
	append(&runtime_results, run_bench(
		"html_escape (mixed XSS 64KB doc)",
		5_000,
		len(mixed_64k),
		bench_escape_string,
	))

	// 2. Context-aware escapers
	g_str_input = "/nodes/view?cluster=prod&id=42"
	append(&runtime_results, run_bench(
		"safe_url (relative path fast-path)",
		1_000_000,
		len(g_str_input),
		bench_safe_url,
	))

	g_str_input = "https://example.com/search?q=odin&lang=en"
	append(&runtime_results, run_bench(
		"safe_url (valid https URL)",
		1_000_000,
		len(g_str_input),
		bench_safe_url,
	))

	g_str_input = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA"
	append(&runtime_results, run_bench(
		"safe_url (data:image/png MIME check)",
		1_000_000,
		len(g_str_input),
		bench_safe_url,
	))

	g_str_input = "   JaVaScRiPt:alert('xss')"
	append(&runtime_results, run_bench(
		"safe_url (blocked javascript:)",
		1_000_000,
		len(g_str_input),
		bench_safe_url,
	))

	g_str_input = "odin_lang-1.0.0_release.tar.gz"
	append(&runtime_results, run_bench(
		"url_param (unreserved fast-path)",
		1_000_000,
		len(g_str_input),
		bench_url_param,
	))

	g_str_input = "hello world & filter=a+b?c#d"
	append(&runtime_results, run_bench(
		"url_param (percent-encoded query)",
		500_000,
		len(g_str_input),
		bench_url_param,
	))

	g_str_input = `</script><script>alert("xss" & '1')</script>` + "\n\u2028"
	append(&runtime_results, run_bench(
		"js_string (script & quote escape)",
		500_000,
		len(g_str_input),
		bench_js_string,
	))

	g_str_input = "Zero overhead compile-time <Odin & HTML> templates"
	append(&runtime_results, run_bench(
		"magic_string (8-word span splitter)",
		500_000,
		len(g_str_input),
		bench_magic_string,
	))

	// 3. Direct type-cast writers & strength-reduced fmt vs Streaming fmt vs fmt.tprintf
	append(&runtime_results, run_bench(
		"write_int + write_f64_prec (direct fast writers)",
		500_000,
		0,
		bench_direct_type_casts,
	))

	append(&runtime_results, run_bench(
		"write_int(10-digit) + write_f64_prec(4-dec neg)",
		500_000,
		0,
		bench_direct_large_numbers,
	))

	g_host_row = rows[0]
	append(&runtime_results, run_bench(
		"fmt(\"%s\" / \"%i\") (compile-time strength reduced)",
		500_000,
		0,
		bench_fmt_strength_reduced,
	))

	fallback_tags := [2]string{"core", "edge"}
	g_default_chain_ctx = Default_Chain_Ctx{
		opt_tag       = nil,
		empty_region  = "",
		tags          = nil,
		fallback_tags = fallback_tags[:],
	}
	append(&runtime_results, run_bench(
		"default(Maybe/slice/str) + chained pipe",
		500_000,
		0,
		bench_default_chained_pipe,
	))

	append(&runtime_results, run_bench(
		"fmt_escaped (streaming 0-alloc)",
		500_000,
		0,
		bench_fmt_streaming,
	))

	append(&runtime_results, run_bench(
		"fmt_raw (direct multi-arg fmt.wprintf)",
		500_000,
		0,
		bench_fmt_raw,
	))

	append(&runtime_results, run_bench(
		"fmt.tprintf + write_escaped",
		500_000,
		0,
		bench_fmt_tprintf,
	))

	// 4. Component composition: Macro call vs Embed with component props
	append(&runtime_results, run_bench(
		"component: {% call badge(...) %} (macro proc)",
		1_000_000,
		0,
		bench_component_macro,
	))

	append(&runtime_results, run_bench(
		"component: {% embed \"...\"(...) %} (inline props)",
		1_000_000,
		0,
		bench_component_embed,
	))

	// 5. Full template rendering (inline component vs 50-row inherited dashboard)
	append(&runtime_results, run_bench(
		"compiled_inline (card, reused buf)",
		500_000,
		0,
		bench_inline_card_preallocated,
	))

	append(&runtime_results, run_bench(
		"compiled_inline (card, approx_bytes alloc)",
		500_000,
		0,
		bench_inline_card_approx_bytes,
	))

	append(&runtime_results, run_bench(
		"compiled_inline (card, unbuffered grow)",
		500_000,
		0,
		bench_inline_card_unbuffered,
	))

	g_dash_ctx = dash_ctx
	append(&runtime_results, run_bench(
		"compiled (50-row dashboard, reused buf)",
		50_000,
		0,
		bench_dashboard_reused_buf,
	))

	append(&runtime_results, run_bench(
		"compiled (50-row dashboard, approx_bytes alloc)",
		50_000,
		0,
		bench_dashboard_approx_bytes_alloc,
	))

	append(&runtime_results, run_bench(
		"compiled (50-row dashboard, sized 16KB alloc)",
		50_000,
		0,
		bench_dashboard_sized_alloc,
	))

	append(&runtime_results, run_bench(
		"compiled (50-row dashboard, unbuffered grow)",
		50_000,
		0,
		bench_dashboard_unbuffered_grow,
	))

	print_results_table("1. Runtime Escaping & Template Rendering (`-o:speed`)", runtime_results[:])

	// 6. Compiler Pipeline Benchmarks (Stage 1 Call Discovery, Stage 2 Lex/Parse/Inheritance, Stage 3 Transpile)
	dash_path := "benchmarks/templates/dashboard.temple.html"
	layout_path := "benchmarks/templates/layout.temple.html"
	section_path := "benchmarks/templates/section_layout.temple.html"
	badge_path := "benchmarks/templates/badge_component.temple.html"
	odin_path := "benchmarks/main.odin"
	if !os.exists(dash_path) {
		dash_path = "templates/dashboard.temple.html"
		layout_path = "templates/layout.temple.html"
		section_path = "templates/section_layout.temple.html"
		badge_path = "templates/badge_component.temple.html"
		odin_path = "main.odin"
	}
	dash_bytes, rerr := os.read_entire_file(dash_path, context.allocator)
	layout_bytes, lerr := os.read_entire_file(layout_path, context.allocator)
	section_bytes, serr := os.read_entire_file(section_path, context.allocator)
	badge_bytes, berr := os.read_entire_file(badge_path, context.allocator)
	odin_bytes, oerr := os.read_entire_file(odin_path, context.allocator)
	if rerr == nil && lerr == nil && serr == nil && berr == nil && oerr == nil {
		defer delete(dash_bytes)
		defer delete(layout_bytes)
		defer delete(section_bytes)
		defer delete(badge_bytes)
		defer delete(odin_bytes)
		g_template_bytes = dash_bytes
		g_layout_bytes = layout_bytes
		g_section_bytes = section_bytes
		g_badge_bytes = badge_bytes
		g_odin_src = string(odin_bytes)
		g_dash_path = dash_path
		g_layout_path = layout_path
		g_section_path = section_path
		g_badge_path = badge_path
		g_odin_path = odin_path

		p_parent: temple_cli.Parser
		temple_cli.parser_init(&p_parent, layout_bytes, context.allocator)
		g_cached_parent_templ = temple_cli.parse(&p_parent)

		p_section: temple_cli.Parser
		temple_cli.parser_init(&p_section, section_bytes, context.allocator)
		g_cached_section_templ = temple_cli.parse(&p_section)

		p_badge: temple_cli.Parser
		temple_cli.parser_init(&p_badge, badge_bytes, context.allocator)
		g_cached_badge_templ = temple_cli.parse(&p_badge)

		leaf_3level_src := `{% extends "section_layout.temple.html" %}{% block title %}{{ super() }} :: Node Detail{% end %}{% block content %}{{ super() }}<article>{{ this.page_title }}</article>{% end %}`
		g_leaf_3level_bytes = transmute([]byte)leaf_3level_src

		embed_host_src := `<div>{% embed "badge_component.temple.html"(label = this.host, status_class = "ok") %}</div>`
		g_embed_host_bytes = transmute([]byte)embed_host_src

		invalid_tmpl_src := `<section><h1>{{ this.page_title }}</h1>{% call unknown_macro(this.host, "ok") %}</section>`
		g_invalid_tmpl_bytes = transmute([]byte)invalid_tmpl_src

		complex_ast_src := `<div class="{{ "active" if this.online else "offline" }}">{{ this.tags[0:2] | default("n/a") }}{% if this.online && (this.latency_ms < 50.0 || this.reqs_per_s > 1000) %}<span>{{ fmt("%s: %.2fms (%i rps)", this.host, this.latency_ms, this.reqs_per_s) }}</span>{% end %}{% let computed = (this.reqs_per_s * 2) + 1 %}</div>`
		g_complex_ast_bytes = transmute([]byte)complex_ast_src

		trace_err_leaf_src := "{% extends \"section_layout.temple.html\" %}\n{% block content %}\n\t<div>{% embed \"missing_widget.temple.html\" %}</div>\n{% end %}\n"
		g_trace_err_leaf_bytes = transmute([]byte)trace_err_leaf_src
		{
			p_err: temple_cli.Parser
			temple_cli.parser_init(&p_err, g_trace_err_leaf_bytes, context.allocator)
			g_cached_trace_err_templ = temple_cli.parse(&p_err)
		}

		g_snap_prev = make(temple_cli.Workspace_Snapshot, 32, context.allocator)
		g_snap_curr = make(temple_cli.Workspace_Snapshot, 32, context.allocator)
		for i in 0 ..< 32 {
			k := fmt.aprintf("/workspace/views/component_%02d.temple.html", i, allocator = context.allocator)
			stamp := temple_cli.File_Stamp{mtime_nsec = 1_730_000_000_000 + i64(i) * 1000, size = 1024 + i64(i) * 64}
			g_snap_prev[k] = stamp
			g_snap_curr[k] = stamp
		}
		defer {
			for k in g_snap_prev {
				delete(k)
			}
			delete(g_snap_prev)
			delete(g_snap_curr)
		}

		// Pre-resolve dashboard template once for pure transpiler codegen benchmarks (`emit_loc` on vs off)
		{
			p_dash: temple_cli.Parser
			temple_cli.parser_init(&p_dash, dash_bytes, context.allocator)
			dash_t := temple_cli.parse(&p_dash)
			init_ctx: temple_cli.Compile_Context
			init_ctx.allocator = context.allocator
			temple_cli.cache_raw_template(&init_ctx, layout_path, temple_cli.Cached_Template{
				source   = layout_bytes,
				template = g_cached_parent_templ,
			})
			g_cached_resolved_dash, _ = temple_cli.resolve_template_inheritance(&init_ctx, dash_t, dash_bytes, dash_path)
		}

		compiler_results := make([dynamic]Bench_Result)
		defer delete(compiler_results)

		append(&compiler_results, run_bench(
			"cli: stage 1 AST call-site discovery (main.odin)",
			5_000,
			len(odin_bytes),
			bench_cli_stage1_collect,
		))

		append(&compiler_results, run_bench(
			"cli: lexer tokenize (dashboard.temple.html)",
			100_000,
			len(dash_bytes),
			bench_cli_lexer,
		))

		append(&compiler_results, run_bench(
			"cli: parse + core:odin/parser expr check",
			20_000,
			len(dash_bytes),
			bench_cli_parser,
		))

		append(&compiler_results, run_bench(
			"cli: parse complex Odin AST exprs (fallback)",
			20_000,
			len(g_complex_ast_bytes),
			bench_cli_parse_complex_ast,
		))

		append(&compiler_results, run_bench(
			"cli: inheritance + block/super/macro splicing (cached layout)",
			20_000,
			len(dash_bytes) + len(layout_bytes),
			bench_cli_inheritance_resolve,
		))

		append(&compiler_results, run_bench(
			"cli: 3-level inheritance + nested super() splicing",
			20_000,
			len(g_leaf_3level_bytes) + len(section_bytes) + len(layout_bytes),
			bench_cli_3level_inheritance,
		))

		append(&compiler_results, run_bench(
			"cli: embed component + props struct synthesis",
			20_000,
			len(g_embed_host_bytes) + len(badge_bytes),
			bench_cli_embed_props_transpile,
		))

		append(&compiler_results, run_bench(
			"cli: fail-fast diagnostic error path (undefined macro)",
			50_000,
			len(g_invalid_tmpl_bytes),
			bench_cli_diagnostic_error_path,
		))

		append(&compiler_results, run_bench(
			"cli: multi-frame diagnostic + snippet trace",
			20_000,
			len(g_trace_err_leaf_bytes) + len(section_bytes) + len(layout_bytes),
			bench_cli_multiframe_diagnostic,
		))

		append(&compiler_results, run_bench(
			"cli: pure transpile codegen (emit_loc = true)",
			50_000,
			0,
			bench_cli_pure_transpile_loc_on,
		))

		append(&compiler_results, run_bench(
			"cli: pure transpile codegen (emit_loc = false)",
			50_000,
			0,
			bench_cli_pure_transpile_loc_off,
		))

		append(&compiler_results, run_bench(
			"cli: full parse + inheritance + transpile (cached layout)",
			20_000,
			len(dash_bytes) + len(layout_bytes),
			bench_cli_transpile,
		))

		append(&compiler_results, run_bench(
			"cli: batch compile 3 templates (shared warm cache)",
			10_000,
			len(dash_bytes) + len(section_bytes) + len(g_leaf_3level_bytes) + len(layout_bytes),
			bench_cli_batch_compile_3,
		))

		append(&compiler_results, run_bench(
			"cli: --watch workspace snapshot diff (32 files)",
			100_000,
			0,
			bench_cli_watch_snapshot_diff,
		))

		print_results_table("2. Compiler Pipeline Throughput (`cli/`)", compiler_results[:])
	}

	fmt.printf("\n_Verification: total bytes processed across benchmark runs = %i (approx_bytes = %i, actual rendered dashboard = %i bytes)_\n",
		sink_bytes,
		dashboard_tmpl.approx_bytes,
		g_last_dashboard_len,
	)
}

g_render_sb: ^strings.Builder
g_render_w: io.Writer
g_str_input: string
g_host_row: Host_Row
g_default_chain_ctx: Default_Chain_Ctx
g_dash_ctx: Dashboard_Ctx
g_last_dashboard_len: int
g_template_bytes: []byte
g_layout_bytes: []byte
g_section_bytes: []byte
g_badge_bytes: []byte
g_leaf_3level_bytes: []byte
g_embed_host_bytes: []byte
g_invalid_tmpl_bytes: []byte
g_complex_ast_bytes: []byte
g_trace_err_leaf_bytes: []byte
g_cached_parent_templ: temple_cli.Template
g_cached_section_templ: temple_cli.Template
g_cached_badge_templ: temple_cli.Template
g_cached_resolved_dash: temple_cli.Template
g_cached_trace_err_templ: temple_cli.Template
g_snap_prev: temple_cli.Workspace_Snapshot
g_snap_curr: temple_cli.Workspace_Snapshot
g_odin_src: string
g_dash_path: string
g_layout_path: string
g_section_path: string
g_badge_path: string
g_odin_path: string

bench_escape_string :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := temple.__temple_write_escaped_string(g_render_w, g_str_input)
	return n
}

bench_safe_url :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := temple.__temple_write_safe_url(g_render_w, g_str_input)
	return n
}

bench_url_param :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := temple.__temple_write_url_param(g_render_w, g_str_input)
	return n
}

bench_js_string :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := temple.__temple_write_js_string(g_render_w, g_str_input)
	return n
}

bench_magic_string :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := temple.__temple_write_magic_string(g_render_w, g_str_input)
	return n
}

bench_direct_type_casts :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n := 0
	w1, _ := io.write_string(g_render_w, "Order: $")
	w2, _ := temple.__temple_write_f64_prec(g_render_w, 149.95, 2)
	w3, _ := io.write_string(g_render_w, " (")
	w4, _ := temple.__temple_write_int(g_render_w, 12)
	w5, _ := io.write_string(g_render_w, " items)")
	n = w1 + w2 + w3 + w4 + w5
	return n
}

bench_direct_large_numbers :: proc() -> int {
	strings.builder_reset(g_render_sb)
	w1, _ := io.write_string(g_render_w, "ts=")
	w2, _ := temple.__temple_write_int(g_render_w, 1_730_476_800)
	w3, _ := io.write_string(g_render_w, " delta=")
	w4, _ := temple.__temple_write_f64_prec(g_render_w, -98765.4321, 4)
	return w1 + w2 + w3 + w4
}

bench_fmt_strength_reduced :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := inline_fmt_simple_tmpl.with(g_render_w, g_host_row)
	return n
}

bench_default_chained_pipe :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := inline_default_chain_tmpl.with(g_render_w, g_default_chain_ctx)
	return n
}

bench_fmt_streaming :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := temple.__temple_write_fmt_escaped(g_render_w, "%s: $%.2f (%i items)", "Order <A&B>", 149.95, 12)
	return n
}

bench_fmt_raw :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := temple.__temple_write_fmt_raw(g_render_w, "%s: $%.2f (%i items)", "Order <A&B>", 149.95, 12)
	return n
}

bench_fmt_tprintf :: proc() -> int {
	strings.builder_reset(g_render_sb)
	formatted := fmt.tprintf("%s: $%.2f (%i items)", "Order <A&B>", 149.95, 12)
	n, _ := temple.__temple_write_escaped_string(g_render_w, formatted)
	free_all(context.temp_allocator)
	return n
}

bench_component_macro :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := inline_macro_badge_tmpl.with(g_render_w, g_host_row)
	return n
}

bench_component_embed :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := inline_embed_badge_tmpl.with(g_render_w, g_host_row)
	return n
}

bench_inline_card_preallocated :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := inline_card_tmpl.with(g_render_w, g_host_row)
	return n
}

bench_inline_card_approx_bytes :: proc() -> int {
	// inline_card_tmpl.approx_bytes == 74; add 32B slack for dynamic host/latency
	sb := strings.builder_make(0, inline_card_tmpl.approx_bytes + 32, context.temp_allocator)
	n, _ := inline_card_tmpl.with(strings.to_writer(&sb), g_host_row)
	free_all(context.temp_allocator)
	return n
}

bench_inline_card_unbuffered :: proc() -> int {
	sb := strings.builder_make(0, 0, context.temp_allocator)
	n, _ := inline_card_tmpl.with(strings.to_writer(&sb), g_host_row)
	free_all(context.temp_allocator)
	return n
}

bench_dashboard_reused_buf :: proc() -> int {
	strings.builder_reset(g_render_sb)
	n, _ := dashboard_tmpl.with(g_render_w, g_dash_ctx)
	g_last_dashboard_len = n
	return n
}

bench_dashboard_approx_bytes_alloc :: proc() -> int {
	sb := strings.builder_make(0, dashboard_tmpl.approx_bytes, context.temp_allocator)
	n, _ := dashboard_tmpl.with(strings.to_writer(&sb), g_dash_ctx)
	free_all(context.temp_allocator)
	return n
}

bench_dashboard_sized_alloc :: proc() -> int {
	sb := strings.builder_make(0, 16 * 1024, context.temp_allocator)
	n, _ := dashboard_tmpl.with(strings.to_writer(&sb), g_dash_ctx)
	free_all(context.temp_allocator)
	return n
}

bench_dashboard_unbuffered_grow :: proc() -> int {
	sb := strings.builder_make(0, 0, context.temp_allocator)
	n, _ := dashboard_tmpl.with(strings.to_writer(&sb), g_dash_ctx)
	free_all(context.temp_allocator)
	return n
}

bench_cli_stage1_collect :: proc() -> int {
	prev_alloc := context.allocator
	context.allocator = context.temp_allocator
	defer {
		context.allocator = prev_alloc
		free_all(context.temp_allocator)
	}

	NO_POS :: tokenizer.Pos{}
	pkg := ast.new(ast.Package, NO_POS, NO_POS)
	pkg.fullpath = "benchmarks"

	p := odin_parser.default_parser()
	file := ast.new(ast.File, NO_POS, NO_POS)
	file.pkg = pkg
	file.src = g_odin_src
	file.fullpath = g_odin_path
	_ = odin_parser.parse_file(&p, file)

	calls := make([dynamic]temple_cli.Compile_Call, context.temp_allocator)
	seen := make(map[string]string, context.temp_allocator)
	files := [1]^ast.File{file}
	temple_cli.collect_calls_from_parsed_files("benchmarks", files[:], &calls, &seen, context.temp_allocator)
	return len(calls)
}

bench_cli_lexer :: proc() -> int {
	l: temple_cli.Lexer
	temple_cli.lexer_init(&l, g_template_bytes)
	count := 0
	for {
		tok := temple_cli.lexer_next(&l)
		count += 1
		if tok.type == .EOF || tok.type == .Illegal {
			break
		}
	}
	return count
}

bench_cli_parser :: proc() -> int {
	p: temple_cli.Parser
	temple_cli.parser_init(&p, g_template_bytes, context.temp_allocator)
	t := temple_cli.parse(&p)
	count := len(t.content)
	free_all(context.temp_allocator)
	return count
}

bench_cli_inheritance_resolve :: proc() -> int {
	p_child: temple_cli.Parser
	temple_cli.parser_init(&p_child, g_template_bytes, context.temp_allocator)
	child_t := temple_cli.parse(&p_child)

	ctx: temple_cli.Compile_Context
	ctx.allocator = context.temp_allocator
	temple_cli.cache_raw_template(&ctx, g_layout_path, temple_cli.Cached_Template{
		source   = g_layout_bytes,
		template = g_cached_parent_templ,
	})

	resolved, _ := temple_cli.resolve_template_inheritance(&ctx, child_t, g_template_bytes, g_dash_path)
	count := len(resolved.content)
	free_all(context.temp_allocator)
	return count
}

bench_cli_transpile :: proc() -> int {
	p_child: temple_cli.Parser
	temple_cli.parser_init(&p_child, g_template_bytes, context.temp_allocator)
	child_t := temple_cli.parse(&p_child)

	ctx: temple_cli.Compile_Context
	ctx.allocator = context.temp_allocator
	temple_cli.cache_raw_template(&ctx, g_layout_path, temple_cli.Cached_Template{
		source   = g_layout_bytes,
		template = g_cached_parent_templ,
	})

	resolved, _ := temple_cli.resolve_template_inheritance(&ctx, child_t, g_template_bytes, g_dash_path)
	strings.builder_reset(g_render_sb)
	temple_cli.transpile(g_render_w, "dashboard.temple.html", resolved, nil, nil, context.temp_allocator, true)
	n := strings.builder_len(g_render_sb^)
	free_all(context.temp_allocator)
	return n
}

bench_cli_3level_inheritance :: proc() -> int {
	p_leaf: temple_cli.Parser
	temple_cli.parser_init(&p_leaf, g_leaf_3level_bytes, context.temp_allocator)
	leaf_t := temple_cli.parse(&p_leaf)

	ctx: temple_cli.Compile_Context
	ctx.allocator = context.temp_allocator
	temple_cli.cache_raw_template(&ctx, g_layout_path, temple_cli.Cached_Template{
		source   = g_layout_bytes,
		template = g_cached_parent_templ,
	})
	temple_cli.cache_raw_template(&ctx, g_section_path, temple_cli.Cached_Template{
		source   = g_section_bytes,
		template = g_cached_section_templ,
	})

	resolved, _ := temple_cli.resolve_template_inheritance(&ctx, leaf_t, g_leaf_3level_bytes, g_dash_path)
	count := len(resolved.content)
	free_all(context.temp_allocator)
	return count
}

bench_cli_pure_transpile_loc_on :: proc() -> int {
	strings.builder_reset(g_render_sb)
	temple_cli.transpile(g_render_w, "dashboard.temple.html", g_cached_resolved_dash, nil, nil, context.temp_allocator, true, true)
	n := strings.builder_len(g_render_sb^)
	free_all(context.temp_allocator)
	return n
}

bench_cli_pure_transpile_loc_off :: proc() -> int {
	strings.builder_reset(g_render_sb)
	temple_cli.transpile(g_render_w, "dashboard.temple.html", g_cached_resolved_dash, nil, nil, context.temp_allocator, true, false)
	n := strings.builder_len(g_render_sb^)
	free_all(context.temp_allocator)
	return n
}

bench_cli_batch_compile_3 :: proc() -> int {
	ctx: temple_cli.Compile_Context
	ctx.allocator = context.temp_allocator
	temple_cli.cache_raw_template(&ctx, g_layout_path, temple_cli.Cached_Template{
		source   = g_layout_bytes,
		template = g_cached_parent_templ,
	})
	temple_cli.cache_raw_template(&ctx, g_section_path, temple_cli.Cached_Template{
		source   = g_section_bytes,
		template = g_cached_section_templ,
	})

	strings.builder_reset(g_render_sb)

	// 1. Compile dashboard.temple.html
	p1: temple_cli.Parser
	temple_cli.parser_init(&p1, g_template_bytes, context.temp_allocator)
	t1 := temple_cli.parse(&p1)
	r1, _ := temple_cli.resolve_template_inheritance(&ctx, t1, g_template_bytes, g_dash_path)
	temple_cli.transpile(g_render_w, "templates/dashboard.temple.html", r1, nil, nil, context.temp_allocator, true)

	// 2. Compile section_layout.temple.html
	r2, _ := temple_cli.resolve_template_inheritance(&ctx, g_cached_section_templ, g_section_bytes, g_section_path)
	temple_cli.transpile(g_render_w, "templates/section_layout.temple.html", r2, nil, nil, context.temp_allocator, true)

	// 3. Compile 3-level leaf template (hits resolved_cache for section_layout & layout)
	p3: temple_cli.Parser
	temple_cli.parser_init(&p3, g_leaf_3level_bytes, context.temp_allocator)
	t3 := temple_cli.parse(&p3)
	r3, _ := temple_cli.resolve_template_inheritance(&ctx, t3, g_leaf_3level_bytes, g_dash_path)
	temple_cli.transpile(g_render_w, "templates/leaf.temple.html", r3, nil, nil, context.temp_allocator, true)

	n := strings.builder_len(g_render_sb^)
	free_all(context.temp_allocator)
	return n
}

bench_cli_embed_props_transpile :: proc() -> int {
	p_host: temple_cli.Parser
	temple_cli.parser_init(&p_host, g_embed_host_bytes, context.temp_allocator)
	host_t := temple_cli.parse(&p_host)

	ctx: temple_cli.Compile_Context
	ctx.allocator = context.temp_allocator
	temple_cli.cache_raw_template(&ctx, g_badge_path, temple_cli.Cached_Template{
		source   = g_badge_bytes,
		template = g_cached_badge_templ,
	})

	embed_state := temple_cli.Embed_Callback_State{
		ctx          = &ctx,
		current_file = g_dash_path,
		current_src  = g_embed_host_bytes,
	}

	strings.builder_reset(g_render_sb)
	temple_cli.transpile(
		g_render_w,
		"embed_host.temple.html",
		host_t,
		temple_cli.embed_parser_with_ctx,
		&embed_state,
		context.temp_allocator,
		true,
	)
	n := strings.builder_len(g_render_sb^)
	free_all(context.temp_allocator)
	return n
}

bench_cli_diagnostic_error_path :: proc() -> int {
	p: temple_cli.Parser
	temple_cli.parser_init(&p, g_invalid_tmpl_bytes, context.temp_allocator)
	t := temple_cli.parse(&p)
	err_len := 0
	if err, has_err := t.err.?; has_err {
		err_len = len(err.msg)
	}
	free_all(context.temp_allocator)
	return err_len
}

bench_cli_parse_complex_ast :: proc() -> int {
	p: temple_cli.Parser
	temple_cli.parser_init(&p, g_complex_ast_bytes, context.temp_allocator)
	t := temple_cli.parse(&p)
	count := len(t.content)
	free_all(context.temp_allocator)
	return count
}

bench_cli_multiframe_diagnostic :: proc() -> int {
	ctx: temple_cli.Compile_Context
	ctx.allocator = context.temp_allocator
	ctx.diagnostics.allocator = context.temp_allocator
	temple_cli.cache_raw_template(&ctx, g_layout_path, temple_cli.Cached_Template{
		source   = g_layout_bytes,
		template = g_cached_parent_templ,
	})
	temple_cli.cache_raw_template(&ctx, g_section_path, temple_cli.Cached_Template{
		source   = g_section_bytes,
		template = g_cached_section_templ,
	})
	temple_cli.cache_raw_template(&ctx, g_dash_path, temple_cli.Cached_Template{
		source   = g_trace_err_leaf_bytes,
		template = g_cached_trace_err_templ,
	})

	call := temple_cli.Compile_Call{
		identifier = "templates/trace_err.temple.html",
		type = temple_cli.Call_Path{
			relpath  = "templates/trace_err.temple.html",
			fullpath = g_dash_path,
		},
		pos = tokenizer.Pos{
			file   = g_odin_path,
			line   = 112,
			column = 21,
		},
	}

	_, _ = temple_cli.compile_single_call(&ctx, call)
	trace_len := len(ctx.diagnostics[0].trace) if len(ctx.diagnostics) > 0 else 0
	free_all(context.temp_allocator)
	return trace_len
}

bench_cli_watch_snapshot_diff :: proc() -> int {
	changed := temple_cli.has_workspace_snapshot_changed(g_snap_prev, g_snap_curr)
	is_gen := temple_cli.is_generated_temple_source("/* This file was generated by temple on 2026 - DO NOT EDIT! */\npackage benchmarks\n")
	return (1 if !changed else 0) + (1 if is_gen else 0)
}
