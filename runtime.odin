package temple

import "core:io"

/*
A compiled template, the `with` proc will render the template into the writer using the given `this`.

Use 'Compiled.with' to render the template into the given (recommended to be buffered) writer with 'this' set to the given T in the template.
Use 'Compiled.approx_bytes' to resize your buffered writer before calling.
*/
Compiled :: struct($T: typeid) {
	with:         proc(w: io.Writer, this: T),
	approx_bytes: int,
}

write_escaped_string :: proc(w: io.Writer, str: string) {
	for i in 0 ..< len(str) {
		b := str[i]
		switch b {
		case '&':
			io.write_string(w, "&amp;")
		case '"':
			io.write_string(w, "&quot;")
		case '\'':
			io.write_string(w, "&#039;")
		case '<':
			io.write_string(w, "&lt;")
		case '>':
			io.write_string(w, "&gt;")
		case:
			io.write_byte(w, b)
		}
	}
}
