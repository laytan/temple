package temple

import "core:io"

/*
A compiled template, the `with` proc will render the template into the writer using the given `this`.

Use 'Compiled.with' to render the template into the given (recommended to be buffered) writer with 'this' set to the given T in the template.
Use 'Compiled.approx_bytes' to resize your buffered writer before calling.

The returned n is the number of bytes written to the writer.
The returned err is any error that was returned by the writer.
*/
Compiled :: struct($T: typeid) {
	with:         proc(w: io.Writer, this: T) -> (n: int, err: io.Error),
	approx_bytes: int,
}

/*
Writes a string to the writer with special characters that can be used in XSS escaped.
*/
__temple_write_escaped_string :: proc(w: io.Writer, str: string) -> (n: int, err: io.Error) {
	for i in 0 ..< len(str) {
		b := str[i]
		switch b {
		case '&':
			n += io.write_string(w, "&amp;") or_return
		case '"':
			n += io.write_string(w, "&quot;") or_return
		case '\'':
			n += io.write_string(w, "&#039;") or_return
		case '<':
			n += io.write_string(w, "&lt;") or_return
		case '>':
			n += io.write_string(w, "&gt;") or_return
		case:
			io.write_byte(w, b) or_return
			n += 1
		}
	}
	return
}
