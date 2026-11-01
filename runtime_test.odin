package temple

import "core:strings"
import "core:testing"

@(test)
test_write_escaped_string :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&sb)

	n, err := __temple_write_escaped_string(w, `<script attr="a" b='c'>x & y</script>`)
	testing.expect_value(t, err, nil)
	expected := `&lt;script attr=&quot;a&quot; b=&#039;c&#039;&gt;x &amp; y&lt;/script&gt;`
	testing.expect_value(t, strings.to_string(sb), expected)
	testing.expect_value(t, n, len(expected))
}

@(test)
test_write_magic_string_boundaries :: proc(t: ^testing.T) {
	// 1. Empty string writes 0 bytes and no empty <span>
	{
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_magic_string(strings.to_writer(&sb), "")
		testing.expect_value(t, err, nil)
		testing.expect_value(t, n, 0)
		testing.expect_value(t, strings.to_string(sb), "")
	}

	// 2. Leading, trailing, and consecutive spaces do not emit empty <span> tags
	{
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_magic_string(strings.to_writer(&sb), "  hello  <b>world</b> ")
		testing.expect_value(t, err, nil)
		expected := `  <span class="magic-text__word">hello</span>  <span class="magic-text__word">&lt;b&gt;world&lt;/b&gt;</span> `
		testing.expect_value(t, strings.to_string(sb), expected)
		testing.expect_value(t, n, len(expected))
	}
}

@(test)
test_write_fmt_escaped_and_raw :: proc(t: ^testing.T) {
	{
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_fmt_escaped(strings.to_writer(&sb), "%s: $%.2f", "<Item & Co>", 19.5)
		testing.expect_value(t, err, nil)
		expected := `&lt;Item &amp; Co&gt;: $19.50`
		testing.expect_value(t, strings.to_string(sb), expected)
		testing.expect_value(t, n, len(expected))
	}

	{
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_fmt_raw(strings.to_writer(&sb), "<b>%s</b> (%i)", "raw", 42)
		testing.expect_value(t, err, nil)
		expected := `<b>raw</b> (42)`
		testing.expect_value(t, strings.to_string(sb), expected)
		testing.expect_value(t, n, len(expected))
	}
}

@(test)
test_write_fmt_utf8_boundary_overflow :: proc(t: ^testing.T) {
	// 510 ASCII bytes + 4-byte UTF-8 rune ("🚀") = 514 bytes.
	// A 512-byte stack buffer cannot fit the 4-byte rune at index 510, so `fmt.bprintf`
	// returns a 510-byte slice (`len(formatted) == 510`). Verify fallback to `fmt.tprintf`
	// preserves the multi-byte UTF-8 rune without truncation.
	prefix := strings.repeat("a", 510, context.temp_allocator)

	{
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_fmt_escaped(strings.to_writer(&sb), "%s%s", prefix, "🚀<>")
		testing.expect_value(t, err, nil)
		expected := strings.concatenate({prefix, "🚀&lt;&gt;"}, context.temp_allocator)
		testing.expect_value(t, strings.to_string(sb), expected)
		testing.expect_value(t, n, len(expected))
	}

	{
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_fmt_raw(strings.to_writer(&sb), "%s%s", prefix, "🚀<b>ok</b>")
		testing.expect_value(t, err, nil)
		expected := strings.concatenate({prefix, "🚀<b>ok</b>"}, context.temp_allocator)
		testing.expect_value(t, strings.to_string(sb), expected)
		testing.expect_value(t, n, len(expected))
	}
}

@(test)
test_write_safe_url_allows_safe_schemes_and_relative_paths :: proc(t: ^testing.T) {
	Safe_Case :: struct {
		input:    string,
		expected: string,
	}

	cases := []Safe_Case{
		{input = "",                                          expected = ""},
		{input = "https://example.com/search?q=odin&lang=en", expected = "https://example.com/search?q=odin&amp;lang=en"},
		{input = `HTTP://EXAMPLE.COM/path?a="1"&b='2'`,       expected = "HTTP://EXAMPLE.COM/path?a=&quot;1&quot;&amp;b=&#039;2&#039;"},
		{input = "mailto:dev@example.com?subject=Hi&body=Yo", expected = "mailto:dev@example.com?subject=Hi&amp;body=Yo"},
		{input = "tel:+1-800-555-0199",                       expected = "tel:+1-800-555-0199"},
		{input = "/relative/path?x=1&y=2",                    expected = "/relative/path?x=1&amp;y=2"},
		{input = "//cdn.example.com/app.js",                  expected = "//cdn.example.com/app.js"},
		{input = "#section:1",                                expected = "#section:1"},
		{input = "?redirect=http://example.com&a=1",          expected = "?redirect=http://example.com&amp;a=1"},
		{input = "/wiki/Category:Odin",                       expected = "/wiki/Category:Odin"},
		{input = "page.html",                                 expected = "page.html"},
		{input = "  https://example.com/padded?a=1&b=2",      expected = "  https://example.com/padded?a=1&amp;b=2"},
		{input = "data:image/png;base64,iVBORw0KGgo=",        expected = "data:image/png;base64,iVBORw0KGgo="},
		{input = "DATA:IMAGE/WEBP;base64,UklGRg==",           expected = "DATA:IMAGE/WEBP;base64,UklGRg=="},
	}

	for c in cases {
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_safe_url(strings.to_writer(&sb), c.input)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, strings.to_string(sb), c.expected)
		testing.expect_value(t, n, len(c.expected))
	}
}

@(test)
test_write_safe_url_neutralizes_dangerous_and_obfuscated_schemes :: proc(t: ^testing.T) {
	unsafe_urls := []string{
		"javascript:alert(1)",
		"JaVaScRiPt:alert('xss')",
		"   javascript:alert(1)",
		"\t\r\njavascript:alert(1)",
		"java\tscript:alert(1)",
		"java\nscript:alert(1)",
		"\x00javascript:alert(1)",
		"\x00https://example.com",
		"javascript:alert('https://example.com')",
		"vbscript:msgbox(\"xss\")",
		"data:text/html,<script>alert(1)</script>",
		"data:image/svg+xml;base64,PHN2Zz4=",
		"file:///etc/passwd",
		"ftp://files.example.com/pub",
	}

	for u in unsafe_urls {
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_safe_url(strings.to_writer(&sb), u)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, strings.to_string(sb), "#ZgotmplZ")
		testing.expect_value(t, n, len("#ZgotmplZ"))
	}
}

@(test)
test_write_url_param_rfc3986_encoding :: proc(t: ^testing.T) {
	Param_Case :: struct {
		input:    string,
		expected: string,
	}

	unreserved := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
	cases := []Param_Case{
		{input = "",                   expected = ""},
		{input = unreserved,           expected = unreserved},
		{input = "hello world & Co=1", expected = "hello%20world%20%26%20Co%3D1"},
		{input = `a+b?c#d/e:f"g'h<i>%`, expected = "a%2Bb%3Fc%23d%2Fe%3Af%22g%27h%3Ci%3E%25"},
		{input = "Odin 🚀",            expected = "Odin%20%F0%9F%9A%80"},
	}

	for c in cases {
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_url_param(strings.to_writer(&sb), c.input)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, strings.to_string(sb), c.expected)
		testing.expect_value(t, n, len(c.expected))
	}
}

@(test)
test_write_js_string_prevents_script_breakout_and_escapes_specials :: proc(t: ^testing.T) {
	Js_Case :: struct {
		input:    string,
		expected: string,
	}

	cases := []Js_Case{
		{input = "",                                  expected = ""},
		{input = "plain_ascii_123",                   expected = "plain_ascii_123"},
		{input = `</script><script>alert(1)</script>`, expected = `\u003c\/script\u003e\u003cscript\u003ealert(1)\u003c\/script\u003e`},
		{input = "a\"b'c\\d/e&f<g>h",                 expected = `a\"b\'c\\d\/e\u0026f\u003cg\u003eh`},
		{input = "line1\nline2\r\t\b\f\x00\x1f\x7f",  expected = `line1\nline2\r\t\b\f\u0000\u001f\u007f`},
		{input = "sep1\u2028sep2\u2029end",           expected = `sep1\u2028sep2\u2029end`},
	}

	for c in cases {
		sb := strings.builder_make(context.temp_allocator)
		n, err := __temple_write_js_string(strings.to_writer(&sb), c.input)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, strings.to_string(sb), c.expected)
		testing.expect_value(t, n, len(c.expected))
	}
}

@(test)
test_default_overloads_for_string_slice_and_maybe :: proc(t: ^testing.T) {
	// 1. string
	testing.expect_value(t, __temple_default("", "Anon"), "Anon")
	testing.expect_value(t, __temple_default("Ada", "Anon"), "Ada")

	// 2. []T slice
	empty_items: []string = {}
	fallback_items := []string{"default_a", "default_b"}
	non_empty_items := []string{"custom"}
	res_empty := __temple_default(empty_items, fallback_items)
	res_non_empty := __temple_default(non_empty_items, fallback_items)
	testing.expect_value(t, len(res_empty), 2)
	testing.expect_value(t, len(res_non_empty), 1)
	testing.expect_value(t, res_non_empty[0], "custom")

	// 3. Maybe(T)
	none_str: Maybe(string) = nil
	some_str: Maybe(string) = "Present"
	testing.expect_value(t, __temple_default(none_str, "Missing"), "Missing")
	testing.expect_value(t, __temple_default(some_str, "Missing"), "Present")

	none_int: Maybe(int) = nil
	some_int: Maybe(int) = 99
	testing.expect_value(t, __temple_default(none_int, 42), 42)
	testing.expect_value(t, __temple_default(some_int, 42), 99)
}
