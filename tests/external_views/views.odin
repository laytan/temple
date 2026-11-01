package external_views

import "core:strings"

Card_Props :: struct {
	title:    string,
	subtitle: string,
	price:    f64,
}

card_tmpl := compiled_inline(
	`<article><h2>{{ this.title | default("Untitled") }}</h2><p>{{ this.subtitle | magic }}</p><span>{{ this.price | fmt("$%.2f") }}</span></article>`,
	Card_Props,
)

render_card :: proc(props: Card_Props, allocator := context.temp_allocator) -> (string, bool) {
	sb := strings.builder_make(0, card_tmpl.approx_bytes, allocator)
	_, err := card_tmpl.with(strings.to_writer(&sb), props)
	return strings.to_string(sb), err == nil
}
