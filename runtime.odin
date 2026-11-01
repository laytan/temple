package temple

import "core:fmt"
import "core:io"

VERSION :: "0.2.0"

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
	for start < len(str) {
		replacement := ""
		stop := start
		scan: for ; stop < len(str); stop += 1 {
			switch str[stop] {
			case '&':
				replacement = "&amp;"
				break scan
			case '"':
				replacement = "&quot;"
				break scan
			case '\'':
				replacement = "&#039;"
				break scan
			case '<':
				replacement = "&lt;"
				break scan
			case '>':
				replacement = "&gt;"
				break scan
			}
		}
		if stop > start {
			n += io.write_string(w, str[start:stop]) or_return
		}
		if len(replacement) > 0 {
			n += io.write_string(w, replacement) or_return
		}
		start = stop + 1
	}
	return
}

/*
Writes a string wrapped in `.magic-text__word` spans for each space-separated word.
*/
__temple_write_magic_string :: proc(w: io.Writer, str: string) -> (n: int, err: io.Error) {
	if len(str) == 0 do return
	start := 0
	for i in 0 ..< len(str) {
		if str[i] == ' ' {
			if i > start {
				n += io.write_string(w, `<span class="magic-text__word">`) or_return
				n += __temple_write_escaped_string(w, str[start:i]) or_return
				n += io.write_string(w, `</span> `) or_return
			} else {
				io.write_byte(w, ' ') or_return
				n += 1
			}
			start = i + 1
		}
	}
	if start < len(str) {
		n += io.write_string(w, `<span class="magic-text__word">`) or_return
		n += __temple_write_escaped_string(w, str[start:]) or_return
		n += io.write_string(w, `</span>`) or_return
	}
	return
}

@(private = "file")
__temple_format_buf_or_temp :: #force_inline proc(buf: []byte, fmt_str: string, args: ..any) -> string {
	formatted := fmt.bprintf(buf, fmt_str, ..args)
	if len(formatted) >= len(buf) - 4 {
		return fmt.tprintf(fmt_str, ..args)
	}
	return formatted
}

__temple_write_fmt_escaped :: proc(w: io.Writer, fmt_str: string, args: ..any) -> (n: int, err: io.Error) {
	buf: [512]byte
	formatted := __temple_format_buf_or_temp(buf[:], fmt_str, ..args)
	return __temple_write_escaped_string(w, formatted)
}

__temple_write_fmt_raw :: proc(w: io.Writer, fmt_str: string, args: ..any) -> (n: int, err: io.Error) {
	buf: [512]byte
	formatted := __temple_format_buf_or_temp(buf[:], fmt_str, ..args)
	return io.write_string(w, formatted)
}

__temple_default_string :: proc(val, fallback: string) -> string {
	return val if len(val) > 0 else fallback
}

__temple_default_slice :: proc(val, fallback: $S/[]$E) -> S {
	return val if len(val) > 0 else fallback
}

__temple_default_maybe :: proc(val: Maybe($T), fallback: T) -> T {
	return val.? or_else fallback
}

__temple_default :: proc {
	__temple_default_string,
	__temple_default_slice,
	__temple_default_maybe,
}

@(private = "file")
__temple_ascii_eq_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' do ca += 'a' - 'A'
		if cb >= 'A' && cb <= 'Z' do cb += 'a' - 'A'
		if ca != cb do return false
	}
	return true
}

@(private = "file")
__temple_ascii_has_prefix_fold :: proc(s, prefix: string) -> bool {
	if len(s) < len(prefix) do return false
	return __temple_ascii_eq_fold(s[:len(prefix)], prefix)
}

@(private = "file")
__temple_is_safe_url :: proc(str: string) -> bool {
	colon_idx := -1
	for i in 0 ..< len(str) {
		switch str[i] {
		case '/', '?', '#':
			return true
		case ':':
			colon_idx = i
			break
		}
		if colon_idx != -1 do break
	}
	if colon_idx == -1 {
		return true
	}

	scheme := str[:colon_idx]
	for len(scheme) > 0 && scheme[0] == ' ' {
		scheme = scheme[1:]
	}
	if __temple_ascii_eq_fold(scheme, "http") ||
	   __temple_ascii_eq_fold(scheme, "https") ||
	   __temple_ascii_eq_fold(scheme, "mailto") ||
	   __temple_ascii_eq_fold(scheme, "tel") {
		return true
	}
	if __temple_ascii_eq_fold(scheme, "data") {
		rest := str[colon_idx + 1:]
		if __temple_ascii_has_prefix_fold(rest, "image/png;") ||
		   __temple_ascii_has_prefix_fold(rest, "image/gif;") ||
		   __temple_ascii_has_prefix_fold(rest, "image/jpeg;") ||
		   __temple_ascii_has_prefix_fold(rest, "image/jpg;") ||
		   __temple_ascii_has_prefix_fold(rest, "image/webp;") {
			return true
		}
	}
	return false
}

/*
Writes a URL string to the writer after validating its scheme (allowing http, https, mailto, tel,
safe data:image/... types, and relative URLs) and HTML-escaping the output. Unsafe schemes are
replaced with `#ZgotmplZ`.
*/
__temple_write_safe_url :: proc(w: io.Writer, str: string) -> (n: int, err: io.Error) {
	if !__temple_is_safe_url(str) {
		return io.write_string(w, "#ZgotmplZ")
	}
	return __temple_write_escaped_string(w, str)
}

@(private = "file")
__temple_is_unreserved_url_byte :: #force_inline proc(c: byte) -> bool {
	return (c >= 'A' && c <= 'Z') ||
		(c >= 'a' && c <= 'z') ||
		(c >= '0' && c <= '9') ||
		c == '-' || c == '.' || c == '_' || c == '~'
}

/*
Writes a string to the writer with all non-RFC 3986 unreserved bytes percent-encoded (%XX).
*/
__temple_write_url_param :: proc(w: io.Writer, str: string) -> (n: int, err: io.Error) {
	hex := "0123456789ABCDEF"
	start := 0
	for start < len(str) {
		stop := start
		for stop < len(str) && __temple_is_unreserved_url_byte(str[stop]) {
			stop += 1
		}
		if stop > start {
			n += io.write_string(w, str[start:stop]) or_return
		}
		if stop < len(str) {
			b := str[stop]
			pct := [3]byte{'%', hex[b >> 4], hex[b & 0x0F]}
			n += io.write_string(w, string(pct[:])) or_return
		}
		start = stop + 1
	}
	return
}

/*
Writes a string to the writer escaped for safe interpolation inside JavaScript/JSON string literals
and inline <script> blocks (preventing </script> breakout, quote breakout, and line-separator injection).
*/
__temple_write_js_string :: proc(w: io.Writer, str: string) -> (n: int, err: io.Error) {
	hex_lower := "0123456789abcdef"
	start := 0
	for start < len(str) {
		replacement := ""
		u_buf: [6]byte
		skip := 1
		stop := start
		scan: for ; stop < len(str); stop += 1 {
			c := str[stop]
			switch c {
			case '\\':
				replacement = `\\`
				break scan
			case '"':
				replacement = `\"`
				break scan
			case '\'':
				replacement = `\'`
				break scan
			case '\n':
				replacement = `\n`
				break scan
			case '\r':
				replacement = `\r`
				break scan
			case '\t':
				replacement = `\t`
				break scan
			case '\b':
				replacement = `\b`
				break scan
			case '\f':
				replacement = `\f`
				break scan
			case '/':
				replacement = `\/`
				break scan
			case '<':
				replacement = `\u003c`
				break scan
			case '>':
				replacement = `\u003e`
				break scan
			case '&':
				replacement = `\u0026`
				break scan
			case 0xE2:
				if stop + 2 < len(str) && str[stop + 1] == 0x80 {
					if str[stop + 2] == 0xA8 {
						replacement = `\u2028`
						skip = 3
						break scan
					} else if str[stop + 2] == 0xA9 {
						replacement = `\u2029`
						skip = 3
						break scan
					}
				}
			case:
				if c < 0x20 || c == 0x7F {
					u_buf = {'\\', 'u', '0', '0', hex_lower[c >> 4], hex_lower[c & 0x0F]}
					replacement = string(u_buf[:])
					break scan
				}
			}
		}
		if stop > start {
			n += io.write_string(w, str[start:stop]) or_return
		}
		if len(replacement) > 0 {
			n += io.write_string(w, replacement) or_return
		}
		start = stop + skip
	}
	return
}


