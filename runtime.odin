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
    start := 0
    for ; start < len(str); {
        replacement := ""
        stop := start
        for ; stop < len(str); stop += 1 {
            switch str[stop] {
            case '&':
                replacement = "&amp;"
                break
            case '"':
                replacement = "&quot;"
                break
            case '\'':
                replacement = "&#039;"
                break
            case '<':
                replacement = "&lt;"
                break
            case '>':
                replacement = "&gt;"
                break
            }
        }
        n += io.write_string(w, str[start:stop]) or_return
        n += io.write_string(w, replacement) or_return
        start = stop + 1
    }
	return
}
