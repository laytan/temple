# Specification: Context-Aware Escaping & Safe Writers (`url`, `js`, `json`)

## Overview

HTML entity escaping (`__temple_write_escaped_string`) protects HTML text nodes and quoted attribute values, but URLs (`href`, `src`, query parameters) and inline `<script>` / JSON contexts require specialized escaping. This track adds zero-allocation, batched runtime writers and compiler pseudo-cast support for `{{ url(...) }}`, `{{ url_param(...) }}`, and `{{ js(...) }}` / `{{ json(...) }}`.

## Functional Requirements

1. **URL Sanitization & Query Parameter Encoding (`runtime.odin`):**
   - `__temple_write_safe_url(w, str)`: Rejects dangerous schemes (`javascript:`, `vbscript:`, `data:` except safe image types if applicable; allows `http:`, `https:`, `mailto:`, `tel:`, relative paths `/`, `#`, `?`) and HTML-escapes the result, writing `#ZgotmplZ` (or `about:blank`) when unsafe.
   - `__temple_write_url_param(w, str)`: Percent-encodes RFC 3986 unreserved characters in batches for safe query parameter interpolation (`?q={{ url_param(this.search) }}`).
2. **JavaScript String Escaping (`runtime.odin`):**
   - `__temple_write_js_string(w, str)`: Escapes `\`, `"`, `'`, `\n`, `\r`, `\t`, `<`, `>`, `&`, `/`, and U+2028/U+2029 so strings can be safely interpolated inside `<script>` string literals without `</script>` breakout.
3. **Parser & Transpiler Classification (`cli/parser.odin`, `cli/transpiler.odin`):**
   - Extend `Output_Write_Kind` and `classify_output_ast` to recognize `url`, `url_param`, and `js` in both pipe syntax (`{{ this.link | url }}`, `{{ this.q | url_param }}`, `{{ this.payload | js }}`) and call syntax (`{{ url(this.link) }}`, `{{ url_param(this.q) }}`, `{{ js(this.payload) }}`) with 1-argument validation and delimiter-preserving inner expression slicing.

## Acceptance Criteria

- `{{ url(this.link) }}` neutralizes `javascript:alert(1)` payloads (including whitespace/control-char obfuscation and mixed case) while preserving valid relative and `https://` URLs.
- `{{ url_param(this.q) }}` percent-encodes reserved URI characters in contiguous chunks.
- `{{ js(this.payload) }}` prevents `</script>` and quote breakout inside `<script>` blocks.
- Unit and integration tests cover all runtime writers and transpiler output kinds.
