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
