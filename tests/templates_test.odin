package temple_tests

import "core:strings"
import "core:testing"
import temple "../"

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
