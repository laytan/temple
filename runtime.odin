package temple

import "core:fmt"
import "core:io"
import "core:strconv"

VERSION :: "1.0.0"

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

@(private = "file")
@(rodata)
HTML_ESCAPE_TABLE := [256]u8{
	'&'  = 1,
	'"'  = 2,
	'\'' = 3,
	'<'  = 4,
	'>'  = 5,
}

@(private = "file")
@(rodata)
HTML_ESCAPE_ENTITIES := [6]string{
	0 = "",
	1 = "&amp;",
	2 = "&quot;",
	3 = "&#039;",
	4 = "&lt;",
	5 = "&gt;",
}

@(private = "file")
__temple_escape_init_prefix :: #force_inline proc(
	w: io.Writer,
	buf: []byte,
	str: string,
	first_esc: int,
) -> (
	buf_len: int,
	n: int,
	err: io.Error,
) {
	if first_esc > 0 {
		if first_esc <= len(buf) / 2 {
			copy(buf, str[:first_esc])
			buf_len = first_esc
		} else {
			n = io.write_string(w, str[:first_esc]) or_return
		}
	}
	return
}

@(private = "file")
@(optimization_mode = "favor_size")
__temple_write_escaped_string_slow :: proc(w: io.Writer, str: string, first_esc: int) -> (n: int, err: io.Error) {
	esc_buf: [256]byte
	buf_len: int
	buf_len, n = __temple_escape_init_prefix(w, esc_buf[:], str, first_esc) or_return

	start := first_esc
	for start < len(str) {
		code := HTML_ESCAPE_TABLE[str[start]]
		if code != 0 {
			ent := HTML_ESCAPE_ENTITIES[code]
			if buf_len + len(ent) > len(esc_buf) {
				n += io.write_string(w, string(esc_buf[:buf_len])) or_return
				buf_len = 0
			}
			copy(esc_buf[buf_len:], ent)
			buf_len += len(ent)
			start += 1
			continue
		}

		stop := start + 1
		for stop < len(str) && HTML_ESCAPE_TABLE[str[stop]] == 0 {
			stop += 1
		}
		run := str[start:stop]
		if len(run) <= len(esc_buf) - buf_len {
			copy(esc_buf[buf_len:], run)
			buf_len += len(run)
		} else if len(run) <= len(esc_buf) / 2 {
			if buf_len > 0 {
				n += io.write_string(w, string(esc_buf[:buf_len])) or_return
				buf_len = 0
			}
			copy(esc_buf[:], run)
			buf_len = len(run)
		} else {
			if buf_len > 0 {
				n += io.write_string(w, string(esc_buf[:buf_len])) or_return
				buf_len = 0
			}
			n += io.write_string(w, run) or_return
		}
		start = stop
	}
	if buf_len > 0 {
		n += io.write_string(w, string(esc_buf[:buf_len])) or_return
	}
	return
}

/*
Writes a string to the writer with special characters that can be used in XSS escaped.
*/
__temple_write_escaped_string :: proc(w: io.Writer, str: string) -> (n: int, err: io.Error) {
	for i := 0; i < len(str); i += 1 {
		if HTML_ESCAPE_TABLE[str[i]] != 0 {
			return __temple_write_escaped_string_slow(w, str, i)
		}
	}
	return io.write_string(w, str)
}

@(private = "file")
@(rodata)
F64_POW10 := [7]f64{
	1.0,
	10.0,
	100.0,
	1000.0,
	10000.0,
	100000.0,
	1000000.0,
}

@(private = "file")
@(rodata)
U64_POW10 := [7]u64{
	1,
	10,
	100,
	1000,
	10000,
	100000,
	1000000,
}

@(private = "file")
@(rodata)
DEC_DIGITS_2 := "00010203040506070809" +
	"10111213141516171819" +
	"20212223242526272829" +
	"30313233343536373839" +
	"40414243444546474849" +
	"50515253545556575859" +
	"60616263646566676869" +
	"70717273747576777879" +
	"80818283848586878889" +
	"90919293949596979899"

@(private = "file")
format_u64_backward :: #force_inline proc(buf: []byte, pos: int, val: u64) -> int {
	pos := pos
	u := val
	for u >= 100 {
		rem := (u % 100) * 2
		u /= 100
		pos -= 2
		buf[pos + 0] = DEC_DIGITS_2[rem + 0]
		buf[pos + 1] = DEC_DIGITS_2[rem + 1]
	}
	if u < 10 {
		pos -= 1
		buf[pos] = byte('0' + u)
	} else {
		rem := u * 2
		pos -= 2
		buf[pos + 0] = DEC_DIGITS_2[rem + 0]
		buf[pos + 1] = DEC_DIGITS_2[rem + 1]
	}
	return pos
}

/*
Writes a signed integer in base-10 directly using a 24-byte stack buffer and a 2-digit lookup table.
*/
__temple_write_int :: proc(w: io.Writer, val: int) -> (n: int, err: io.Error) {
	if val >= 0 && val < 10 {
		idx := val * 2 + 1
		return io.write_string(w, DEC_DIGITS_2[idx : idx + 1])
	}
	if val >= 10 && val < 100 {
		idx := val * 2
		return io.write_string(w, DEC_DIGITS_2[idx : idx + 2])
	}

	buf: [24]byte
	neg := val < 0
	u: u64 = 0 - u64(val) if neg else u64(val)
	pos := format_u64_backward(buf[:], len(buf), u)
	if neg {
		pos -= 1
		buf[pos] = '-'
	}
	return io.write_string(w, string(buf[pos:]))
}

/*
Writes a float64 formatted with a fixed decimal precision (e.g. `%.2f`) directly using a stack buffer
without invoking `fmt.wprintf` or HTML escaping.
*/
__temple_write_f64_prec :: proc(w: io.Writer, val: f64, prec: int) -> (n: int, err: io.Error) {
	buf: [64]byte
	// Fast fixed-point path for normal finite numbers with 0..6 decimal places
	if prec >= 0 && prec <= 6 && val == val && val > -1e12 && val < 1e12 {
		bits := transmute(u64)val
		neg := (bits >> 63) != 0
		abs_val := -val if neg else val
		scale := F64_POW10[prec]
		scaled_f := abs_val * scale
		floor_u := u64(scaled_f)
		rem := scaled_f - f64(floor_u)
		// Round half to even (banker's rounding) to match `strconv.write_float` / `fmt.wprintf`
		scaled_u := floor_u
		if rem > 0.5 || (rem == 0.5 && (floor_u & 1) != 0) {
			scaled_u += 1
		}

		u_scale := U64_POW10[prec]
		int_part := scaled_u / u_scale
		frac_part := scaled_u % u_scale

		pos := len(buf)
		if prec == 2 {
			rem := frac_part * 2
			pos -= 3
			buf[pos + 0] = '.'
			buf[pos + 1] = DEC_DIGITS_2[rem + 0]
			buf[pos + 2] = DEC_DIGITS_2[rem + 1]
		} else if prec > 0 {
			for _ in 0 ..< prec {
				pos -= 1
				buf[pos] = byte('0' + (frac_part % 10))
				frac_part /= 10
			}
			pos -= 1
			buf[pos] = '.'
		}
		pos = format_u64_backward(buf[:], pos, int_part)
		if neg {
			pos -= 1
			buf[pos] = '-'
		}
		return io.write_string(w, string(buf[pos:]))
	}

	formatted := strconv.write_float(buf[:], val, 'f', prec, 64)
	if len(formatted) > 0 && formatted[0] == '+' {
		formatted = formatted[1:]
	}
	return io.write_string(w, formatted)
}

/*
Writes a string wrapped in `.magic-text__word` spans for each space-separated word.
*/
__temple_write_magic_string :: proc(w: io.Writer, str: string) -> (n: int, err: io.Error) {
	if len(str) == 0 do return
	MAGIC_OPEN  :: `<span class="magic-text__word">`
	MAGIC_CLOSE :: `</span>`

	buf: [512]byte
	b_len := 0

	i := 0
	for i < len(str) {
		if str[i] == ' ' {
			space_start := i
			for i < len(str) && str[i] == ' ' {
				i += 1
			}
			spaces := str[space_start:i]
			if b_len + len(spaces) <= len(buf) {
				copy(buf[b_len:], spaces)
				b_len += len(spaces)
			} else {
				if b_len > 0 {
					n += io.write_string(w, string(buf[:b_len])) or_return
					b_len = 0
				}
				n += io.write_string(w, spaces) or_return
			}
		} else {
			word_start := i
			has_esc := false
			for i < len(str) && str[i] != ' ' {
				if HTML_ESCAPE_TABLE[str[i]] != 0 {
					has_esc = true
				}
				i += 1
			}
			word := str[word_start:i]
			trailing_space := i < len(str) && str[i] == ' '
			if trailing_space {
				i += 1
			}
			close_tag := `</span> ` if trailing_space else MAGIC_CLOSE

			if !has_esc {
				needed := len(MAGIC_OPEN) + len(word) + len(close_tag)
				if b_len + needed > len(buf) && b_len > 0 {
					n += io.write_string(w, string(buf[:b_len])) or_return
					b_len = 0
				}
				if needed <= len(buf) {
					copy(buf[b_len:], MAGIC_OPEN)
					b_len += len(MAGIC_OPEN)
					copy(buf[b_len:], word)
					b_len += len(word)
					copy(buf[b_len:], close_tag)
					b_len += len(close_tag)
					continue
				}
			} else if len(word) <= 64 {
				max_needed := len(MAGIC_OPEN) + len(word) * 6 + len(close_tag)
				if b_len + max_needed > len(buf) && b_len > 0 {
					n += io.write_string(w, string(buf[:b_len])) or_return
					b_len = 0
				}
				if max_needed <= len(buf) {
					copy(buf[b_len:], MAGIC_OPEN)
					b_len += len(MAGIC_OPEN)
					for c_idx in 0 ..< len(word) {
						ch := word[c_idx]
						code := HTML_ESCAPE_TABLE[ch]
						if code == 0 {
							buf[b_len] = ch
							b_len += 1
						} else {
							ent := HTML_ESCAPE_ENTITIES[code]
							copy(buf[b_len:], ent)
							b_len += len(ent)
						}
					}
					copy(buf[b_len:], close_tag)
					b_len += len(close_tag)
					continue
				}
			}

			if b_len > 0 {
				n += io.write_string(w, string(buf[:b_len])) or_return
				b_len = 0
			}
			n += io.write_string(w, MAGIC_OPEN) or_return
			if has_esc {
				n += __temple_write_escaped_string(w, word) or_return
			} else {
				n += io.write_string(w, word) or_return
			}
			n += io.write_string(w, close_tag) or_return
		}
	}
	if b_len > 0 {
		n += io.write_string(w, string(buf[:b_len])) or_return
	}
	return
}

@(private = "file")
__TEMPLE_FMT_STACK_CAP :: 256

@(private = "file")
__Temple_Fmt_Writer :: struct {
	inner:     io.Writer,
	escape:    bool,
	flushed:   bool,
	buf_len:   int,
	n:         int,
	err:       io.Error,
	stack_buf: [__TEMPLE_FMT_STACK_CAP]byte,
}

@(private = "file")
__temple_fmt_flush_stack :: proc(state: ^__Temple_Fmt_Writer) -> bool {
	if state.buf_len == 0 {
		return true
	}
	written: int
	if state.escape {
		written, state.err = __temple_write_escaped_string(state.inner, string(state.stack_buf[:state.buf_len]))
	} else {
		written, state.err = io.write(state.inner, state.stack_buf[:state.buf_len])
	}
	state.n += written
	state.buf_len = 0
	state.flushed = true
	return state.err == nil
}

@(private = "file")
__temple_fmt_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	state := (^__Temple_Fmt_Writer)(stream_data)
	#partial switch mode {
	case .Write:
		if state.err != nil {
			return 0, state.err
		}
		if !state.flushed && state.buf_len + len(p) <= __TEMPLE_FMT_STACK_CAP {
			copy(state.stack_buf[state.buf_len:], p)
			state.buf_len += len(p)
			return i64(len(p)), nil
		}
		if !__temple_fmt_flush_stack(state) {
			return 0, state.err
		}
		written: int
		if state.escape {
			written, state.err = __temple_write_escaped_string(state.inner, string(p))
		} else {
			written, state.err = io.write(state.inner, p)
		}
		state.n += written
		if state.err != nil {
			return i64(written), state.err
		}
		return i64(len(p)), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}

@(private = "file")
__temple_write_fmt :: proc(w: io.Writer, escape: bool, fmt_str: string, args: ..any) -> (n: int, err: io.Error) {
	state := __Temple_Fmt_Writer{inner = w, escape = escape}
	fmt.wprintf(io.Writer{procedure = __temple_fmt_stream_proc, data = &state}, fmt_str, ..args, flush = false)
	if state.err == nil && state.buf_len > 0 {
		_ = __temple_fmt_flush_stack(&state)
	}
	return state.n, state.err
}

__temple_write_fmt_escaped :: proc(w: io.Writer, fmt_str: string, args: ..any) -> (n: int, err: io.Error) {
	return __temple_write_fmt(w, true, fmt_str, ..args)
}

__temple_write_fmt_raw :: proc(w: io.Writer, fmt_str: string, args: ..any) -> (n: int, err: io.Error) {
	return __temple_write_fmt(w, false, fmt_str, ..args)
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
		case '\\':
			return false
		case '/':
			return !(i + 1 < len(str) && str[i + 1] == '\\')
		case '?', '#':
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
	for len(scheme) > 0 {
		switch scheme[0] {
		case ' ', '\t', '\n', '\r', '\f':
			scheme = scheme[1:]
			continue
		}
		break
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
@(rodata)
URL_UNRESERVED_TABLE := [256]bool{
	'A' ..= 'Z' = true,
	'a' ..= 'z' = true,
	'0' ..= '9' = true,
	'-' = true,
	'.' = true,
	'_' = true,
	'~' = true,
}

@(private = "file")
@(optimization_mode = "favor_size")
__temple_write_url_param_slow :: proc(w: io.Writer, str: string, first_esc: int) -> (n: int, err: io.Error) {
	hex := "0123456789ABCDEF"
	pct_buf: [256]byte
	buf_len: int
	buf_len, n = __temple_escape_init_prefix(w, pct_buf[:], str, first_esc) or_return

	for i := first_esc; i < len(str); i += 1 {
		b := str[i]
		if URL_UNRESERVED_TABLE[b] {
			if buf_len + 1 > len(pct_buf) {
				n += io.write_string(w, string(pct_buf[:buf_len])) or_return
				buf_len = 0
			}
			pct_buf[buf_len] = b
			buf_len += 1
		} else {
			if buf_len + 3 > len(pct_buf) {
				n += io.write_string(w, string(pct_buf[:buf_len])) or_return
				buf_len = 0
			}
			pct_buf[buf_len + 0] = '%'
			pct_buf[buf_len + 1] = hex[b >> 4]
			pct_buf[buf_len + 2] = hex[b & 0x0F]
			buf_len += 3
		}
	}
	if buf_len > 0 {
		n += io.write_string(w, string(pct_buf[:buf_len])) or_return
	}
	return
}

/*
Writes a string to the writer with all non-RFC 3986 unreserved bytes percent-encoded (%XX).
*/
__temple_write_url_param :: proc(w: io.Writer, str: string) -> (n: int, err: io.Error) {
	for i := 0; i < len(str); i += 1 {
		if !URL_UNRESERVED_TABLE[str[i]] {
			return __temple_write_url_param_slow(w, str, i)
		}
	}
	return io.write_string(w, str)
}

@(private = "file")
@(rodata)
JS_ESCAPE_TABLE := [256]u8{
	0x00 ..= 0x07 = 13,
	'\b'          = 7,
	'\t'          = 6,
	'\n'          = 4,
	0x0B          = 13,
	'\f'          = 8,
	'\r'          = 5,
	0x0E ..= 0x1F = 13,
	'"'           = 2,
	'&'           = 12,
	'\''          = 3,
	'/'           = 9,
	'<'           = 10,
	'>'           = 11,
	'\\'          = 1,
	0x7F          = 13,
	0xE2          = 14,
}

@(private = "file")
@(rodata)
JS_ESCAPE_ENTITIES := [13]string{
	0  = "",
	1  = `\\`,
	2  = `\"`,
	3  = `\'`,
	4  = `\n`,
	5  = `\r`,
	6  = `\t`,
	7  = `\b`,
	8  = `\f`,
	9  = `\/`,
	10 = `\u003c`,
	11 = `\u003e`,
	12 = `\u0026`,
}

@(private = "file")
@(optimization_mode = "favor_size")
__temple_write_js_string_slow :: proc(w: io.Writer, str: string, first_esc: int) -> (n: int, err: io.Error) {
	hex_lower := "0123456789abcdef"
	js_buf: [256]byte
	buf_len: int
	buf_len, n = __temple_escape_init_prefix(w, js_buf[:], str, first_esc) or_return

	i := first_esc
	for i < len(str) {
		c := str[i]
		code := JS_ESCAPE_TABLE[c]
		if code == 0 {
			if buf_len + 1 > len(js_buf) {
				n += io.write_string(w, string(js_buf[:buf_len])) or_return
				buf_len = 0
			}
			js_buf[buf_len] = c
			buf_len += 1
			i += 1
			continue
		}
		if code <= 12 {
			ent := JS_ESCAPE_ENTITIES[code]
			if buf_len + len(ent) > len(js_buf) {
				n += io.write_string(w, string(js_buf[:buf_len])) or_return
				buf_len = 0
			}
			copy(js_buf[buf_len:], ent)
			buf_len += len(ent)
			i += 1
			continue
		}
		if code == 13 {
			if buf_len + 6 > len(js_buf) {
				n += io.write_string(w, string(js_buf[:buf_len])) or_return
				buf_len = 0
			}
			js_buf[buf_len + 0] = '\\'
			js_buf[buf_len + 1] = 'u'
			js_buf[buf_len + 2] = '0'
			js_buf[buf_len + 3] = '0'
			js_buf[buf_len + 4] = hex_lower[c >> 4]
			js_buf[buf_len + 5] = hex_lower[c & 0x0F]
			buf_len += 6
			i += 1
			continue
		}
		// code == 14 (0xE2): check for UTF-8 U+2028 (E2 80 A8) or U+2029 (E2 80 A9)
		if i + 2 < len(str) && str[i + 1] == 0x80 && (str[i + 2] == 0xA8 || str[i + 2] == 0xA9) {
			if buf_len + 6 > len(js_buf) {
				n += io.write_string(w, string(js_buf[:buf_len])) or_return
				buf_len = 0
			}
			rep := `\u2028` if str[i + 2] == 0xA8 else `\u2029`
			copy(js_buf[buf_len:], rep)
			buf_len += 6
			i += 3
			continue
		}
		if buf_len + 1 > len(js_buf) {
			n += io.write_string(w, string(js_buf[:buf_len])) or_return
			buf_len = 0
		}
		js_buf[buf_len] = c
		buf_len += 1
		i += 1
	}
	if buf_len > 0 {
		n += io.write_string(w, string(js_buf[:buf_len])) or_return
	}
	return
}

/*
Writes a string to the writer escaped for safe interpolation inside JavaScript/JSON string literals
and inline <script> blocks (preventing </script> breakout, quote breakout, and line-separator injection).
*/
__temple_write_js_string :: proc(w: io.Writer, str: string) -> (n: int, err: io.Error) {
	for i := 0; i < len(str); i += 1 {
		c := str[i]
		code := JS_ESCAPE_TABLE[c]
		if code != 0 {
			if code != 14 || (i + 2 < len(str) && str[i + 1] == 0x80 && (str[i + 2] == 0xA8 || str[i + 2] == 0xA9)) {
				return __temple_write_js_string_slow(w, str, i)
			}
		}
	}
	return io.write_string(w, str)
}


