package temple_tests

import "core:strings"
import "core:testing"
import temple "../"
import external_views "./external_views"

Status :: enum {
	Idle,
	Loading,
	Ready,
	Error,
}

Payload :: union {
	int,
	string,
}

Page_Ctx :: struct {
	title:      string,
	raw_banner: string,
	status:     Status,
	payload:    Payload,
	items:      []string,
}

// Verify `temple.compiled` / `temple.compiled_inline` can be called from a `"contextless"` proc
get_contextless_template :: proc "contextless" () -> temple.Compiled(Page_Ctx) {
	return temple.compiled_inline("<h1>{{ this.title }}</h1>", Page_Ctx)
}

@(test)
test_contextless_compiled_call :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	tmpl := get_contextless_template()
	sb := strings.builder_make(0, tmpl.approx_bytes)
	w := strings.to_writer(&sb)

	_, err := tmpl.with(w, Page_Ctx{title = "Hello <Odin>"})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, strings.to_string(sb), "<h1>Hello &lt;Odin&gt;</h1>")
}

@(test)
test_raw_output_vs_escaped_output :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	tmpl := temple.compiled_inline(
		`escaped={{ this.raw_banner }}|raw={{ raw(this.raw_banner) }}`,
		Page_Ctx,
	)

	sb := strings.builder_make(0, tmpl.approx_bytes)
	_, err := tmpl.with(strings.to_writer(&sb), Page_Ctx{
		raw_banner = "<b>Notice & Alert</b>",
	})

	testing.expect_value(t, err, nil)
	testing.expect_value(
		t,
		strings.to_string(sb),
		"escaped=&lt;b&gt;Notice &amp; Alert&lt;/b&gt;|raw=<b>Notice & Alert</b>",
	)
}

@(test)
test_switch_let_and_whitespace_trimming_e2e :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	tmpl := temple.compiled_inline(
		`
		{%- let count = len(this.items) -%}
		<div data-count="{{ int(count) }}">
		  {%- #partial switch this.status -%}
		    {%- case .Loading -%}
		      <span>Loading...</span>
		    {%- case .Ready -%}
		      {%- switch v in this.payload -%}
		        {%- case int -%}
		          <span>Code: {{ int(v) }}</span>
		        {%- case string -%}
		          <span>Msg: {{ v }}</span>
		        {%- case -%}
		          <span>Empty</span>
		      {%- end -%}
		    {%- case -%}
		      <span>Other</span>
		  {%- end -%}
		</div>`,
		Page_Ctx,
	)

	// 1. Test `.Ready` + `string` union variant with tight whitespace trimming
	{
		sb := strings.builder_make(0, tmpl.approx_bytes)
		_, err := tmpl.with(strings.to_writer(&sb), Page_Ctx{
			status  = .Ready,
			payload = "All systems go",
			items   = {"a", "b", "c"},
		})
		testing.expect_value(t, err, nil)
		testing.expect_value(
			t,
			strings.to_string(sb),
			`<div data-count="3"><span>Msg: All systems go</span></div>`,
		)
	}

	// 2. Test `.Loading` branch
	{
		sb := strings.builder_make(0, tmpl.approx_bytes)
		_, err := tmpl.with(strings.to_writer(&sb), Page_Ctx{
			status = .Loading,
		})
		testing.expect_value(t, err, nil)
		testing.expect_value(
			t,
			strings.to_string(sb),
			`<div data-count="0"><span>Loading...</span></div>`,
		)
	}
}

@(test)
test_batched_escaped_string :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	sb := strings.builder_make()
	w := strings.to_writer(&sb)

	n, err := temple.__temple_write_escaped_string(w, `<script attr="1" & '2'>Hello, 世界!</script>`)
	testing.expect_value(t, err, nil)
	expected := "&lt;script attr=&quot;1&quot; &amp; &#039;2&#039;&gt;Hello, 世界!&lt;/script&gt;"
	testing.expect_value(t, n, len(expected))
	testing.expect_value(t, strings.to_string(sb), expected)

	// Verify `__temple_write_magic_string` handles empty strings and consecutive/leading/trailing spaces without empty spans
	strings.builder_reset(&sb)
	n_empty, err_empty := temple.__temple_write_magic_string(w, "")
	testing.expect_value(t, err_empty, nil)
	testing.expect_value(t, n_empty, 0)
	testing.expect_value(t, strings.to_string(sb), "")

	strings.builder_reset(&sb)
	n_magic, err_magic := temple.__temple_write_magic_string(w, " a  <b> ")
	testing.expect_value(t, err_magic, nil)
	expected_magic := ` <span class="magic-text__word">a</span>  <span class="magic-text__word">&lt;b&gt;</span> `
	testing.expect_value(t, n_magic, len(expected_magic))
	testing.expect_value(t, strings.to_string(sb), expected_magic)
}

@(test)
test_macros_pipes_fmt_and_default_e2e :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	tmpl := temple.compiled_inline(
		`{%- macro badge(label: string, active := false) -%}` +
		`<span class="{% if active %}active{% else %}inactive{% end %}">{{ label | default("Untitled") }}</span>` +
		`{%- end -%}` +
		`{%- macro sep() -%}|{%- end -%}` +
		`{%- call badge(this.title, true) -%}` +
		`{%- call sep() -%}` +
		`{%- call badge("Draft") -%}` +
		`{%- call sep() -%}` +
		`{{ len(this.items) | fmt("items=%i") }}`,
		Page_Ctx,
	)

	sb := strings.builder_make(0, tmpl.approx_bytes)
	_, err := tmpl.with(strings.to_writer(&sb), Page_Ctx{
		title = "",
		items = {"x", "y"},
	})
	testing.expect_value(t, err, nil)
	testing.expect_value(
		t,
		strings.to_string(sb),
		`<span class="active">Untitled</span>|<span class="inactive">Draft</span>|items=2`,
	)
}

@(test)
test_decoupled_external_package_codegen_e2e :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	rendered, ok := external_views.render_card({
		title    = "",
		subtitle = "fast & safe",
		price    = 19.5,
	})
	testing.expect(t, ok)
	testing.expect_value(
		t,
		rendered,
		`<article><h2>Untitled</h2><p><span class="magic-text__word">fast</span> <span class="magic-text__word">&amp;</span> <span class="magic-text__word">safe</span></p><span>$19.50</span></article>`,
	)
}

Escaping_Ctx :: struct {
	href:       string,
	search:     string,
	js_payload: string,
}

@(test)
test_context_aware_escaping_url_url_param_and_js_e2e :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	tmpl := temple.compiled_inline(
		`<a href="{{ this.href | default("/home") | url }}?q={{ url_param(this.search) }}">Link</a><script>const msg = "{{ this.js_payload | js }}";</script>`,
		Escaping_Ctx,
	)

	// 1. Valid https URL + reserved query characters + </script> breakout attempt
	{
		sb := strings.builder_make(0, tmpl.approx_bytes)
		_, err := tmpl.with(strings.to_writer(&sb), Escaping_Ctx{
			href       = "https://example.com/go",
			search     = "hello & world=1",
			js_payload = `</script><script>alert("xss" & '1')</script>`,
		})
		testing.expect_value(t, err, nil)
		testing.expect_value(
			t,
			strings.to_string(sb),
			`<a href="https://example.com/go?q=hello%20%26%20world%3D1">Link</a><script>const msg = "\u003c\/script\u003e\u003cscript\u003ealert(\"xss\" \u0026 \'1\')\u003c\/script\u003e";</script>`,
		)
	}

	// 2. Dangerous obfuscated javascript: URL neutralized to #ZgotmplZ + Unicode line separator in JS
	{
		sb := strings.builder_make(0, tmpl.approx_bytes)
		_, err := tmpl.with(strings.to_writer(&sb), Escaping_Ctx{
			href       = "   JaVaScRiPt:alert(1)",
			search     = "Odin 1.0",
			js_payload = "line1\nline2\u2028sep",
		})
		testing.expect_value(t, err, nil)
		testing.expect_value(
			t,
			strings.to_string(sb),
			`<a href="#ZgotmplZ?q=Odin%201.0">Link</a><script>const msg = "line1\nline2\u2028sep";</script>`,
		)
	}
}
