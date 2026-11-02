# Temple Benchmarks & Optimization Architecture

This directory contains the benchmark suite for **Temple**, measuring both **runtime rendering & context-aware escaping** (`runtime.odin`) and the **3-stage CLI compiler pipeline** (`cli/`).

---

## Running the Benchmarks

 Always compile and run the benchmark suite with `-o:speed`:

```sh
# Optional: regenerate benchmarks/templates_gen.odin and verify no unused templates exist
odin run cli -- --warn-unused benchmarks -out:benchmarks/templates_gen.odin -pkg:benchmarks -temple-import:..

# Verify generated templates are up-to-date (used in CI)
odin run cli -- --check --warn-unused benchmarks -out:benchmarks/templates_gen.odin -pkg:benchmarks -temple-import:..

# Run the benchmark suite
odin run benchmarks -o:speed
```

### Harness Methodology (`benchmarks/main.odin`)

* **Dual Allocator Tracking (`Allocs/op` & `Alloc B/op`):** Every benchmark wraps both `context.allocator` and `context.temp_allocator` in `mem.Tracking_Allocator` instances. Any hidden heap or temporary allocation is captured and reported per operation.
* **Warmup & Dead-Code Prevention:** Each benchmark executes warmup iterations (`clamp(iterations / 20, 10, 1000)`) before starting `time.Stopwatch` and accumulates returned byte/node counts into a package-level `sink_bytes` counter.
* **Isolated Buffer Modes:** Runtime benchmarks test both a pre-allocated 128 KB `strings.Builder` (measuring pure template execution and verifying `0 allocs/op`) and per-render buffer allocations using `Compiled.approx_bytes` vs unbuffered dynamic growth.

---

## Benchmark Results (`-o:speed`)

### 1. Runtime Escaping & Template Rendering

| Benchmark | Iterations | Time (ns/op) | Throughput (MB/s) | Output / Input B/op | Allocs/op | Alloc B/op |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `html_escape (clean ASCII 70B)` | 1,000,000 | 26.2 ns | 2,543.6 MB/s | 70 B | 0 | 0 B |
| `html_escape (dense XSS 88B)` | 500,000 | 145.2 ns | 578.0 MB/s | 88 B | 0 | 0 B |
| `html_escape (clean 64KB doc)` | 20,000 | 16,286.2 ns | 3,837.6 MB/s | 65,536 B | 0 | 0 B |
| `html_escape (mixed XSS 64KB doc)` | 5,000 | 68,638.0 ns | 910.6 MB/s | 65,536 B | 0 | 0 B |
| `safe_url (relative path fast-path)` | 1,000,000 | 31.1 ns | 919.1 MB/s | 30 B | 0 | 0 B |
| `safe_url (valid https URL)` | 1,000,000 | 37.7 ns | 1,038.0 MB/s | 41 B | 0 | 0 B |
| `safe_url (data:image/png MIME check)` | 1,000,000 | 30.3 ns | 1,575.3 MB/s | 50 B | 0 | 0 B |
| `safe_url (blocked javascript:)` | 1,000,000 | 17.4 ns | 1,428.2 MB/s | 26 B | 0 | 0 B |
| `url_param (unreserved fast-path)` | 1,000,000 | 24.0 ns | 1,192.2 MB/s | 30 B | 0 | 0 B |
| `url_param (percent-encoded query)` | 500,000 | 39.0 ns | 684.7 MB/s | 28 B | 0 | 0 B |
| `js_string (script & quote escape)` | 500,000 | 94.2 ns | 485.8 MB/s | 48 B | 0 | 0 B |
| `magic_string (8-word span splitter)` | 500,000 | 110.1 ns | 432.9 MB/s | 50 B | 0 | 0 B |
| `write_int + write_f64_prec (direct fast writers)` | 500,000 | 38.3 ns | 622.1 MB/s | 25 B | 0 | 0 B |
| `write_int(10-digit) + write_f64_prec(4-dec neg)` | 500,000 | 42.4 ns | 697.8 MB/s | 31 B | 0 | 0 B |
| `fmt("%s" / "%i") (compile-time strength reduced)` | 500,000 | 37.2 ns | 1,563.5 MB/s | 61 B | 0 | 0 B |
| `default(Maybe/slice/str) + chained pipe` | 500,000 | 66.1 ns | 533.9 MB/s | 37 B | 0 | 0 B |
| `fmt_escaped (streaming 0-alloc)` | 500,000 | 280.5 ns | 139.4 MB/s | 41 B | 0 | 0 B |
| `fmt_raw (direct multi-arg fmt.wprintf)` | 500,000 | 250.5 ns | 118.0 MB/s | 31 B | 0 | 0 B |
| `fmt.tprintf + write_escaped` | 500,000 | 484.9 ns | 80.6 MB/s | 41 B | 3 | 109 B |
| `component: {% call badge(...) %} (macro proc)` | 1,000,000 | 47.5 ns | 1,265.2 MB/s | 63 B | 0 | 0 B |
| `component: {% embed "..."(...) %} (inline props)` | 1,000,000 | 54.2 ns | 1,127.1 MB/s | 64 B | 0 | 0 B |
| `compiled_inline (card, reused buf)` | 500,000 | 50.7 ns | 1,653.9 MB/s | 88 B | 0 | 0 B |
| `compiled_inline (card, approx_bytes alloc)` | 500,000 | 150.4 ns | 557.9 MB/s | 88 B | 1 | 109 B |
| `compiled_inline (card, unbuffered grow)` | 500,000 | 245.3 ns | 342.1 MB/s | 88 B | 3 | 280 B |
| `compiled (50-row dashboard, reused buf)` | 50,000 | 10,987.2 ns | 1,325.9 MB/s | 15,276 B | 0 | 0 B |
| `compiled (50-row dashboard, approx_bytes alloc)` | 50,000 | 11,215.6 ns | 1,298.9 MB/s | 15,276 B | 1 | 15,973 B |
| `compiled (50-row dashboard, sized 16KB alloc)` | 50,000 | 11,144.0 ns | 1,307.3 MB/s | 15,276 B | 1 | 16,384 B |
| `compiled (50-row dashboard, unbuffered grow)` | 50,000 | 11,550.0 ns | 1,261.3 MB/s | 15,276 B | 8 | 37,155 B |

### 2. Compiler Pipeline Throughput (`cli/`)

| Benchmark | Iterations | Time (ns/op) | Throughput (MB/s) | Output / Input B/op | Allocs/op | Alloc B/op |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `cli: stage 1 AST call-site discovery (main.odin)` | 5,000 | 946,233.6 ns | 33.2 MB/s | 32,908 B | 5,484 | 834,901 B |
| `cli: lexer tokenize (dashboard.temple.html)` | 100,000 | 2,584.3 ns | 447.6 MB/s | 1,213 B | 0 | 0 B |
| `cli: parse + core:odin/parser expr check` | 20,000 | 7,782.5 ns | 148.6 MB/s | 1,213 B | 13 | 7,235 B |
| `cli: parse complex Odin AST exprs (fallback)` | 20,000 | 10,850.7 ns | 28.1 MB/s | 320 B | 69 | 13,345 B |
| `cli: inheritance + block/super/macro splicing (cached layout)` | 20,000 | 10,851.2 ns | 164.7 MB/s | 1,874 B | 32 | 11,948 B |
| `cli: 3-level inheritance + nested super() splicing` | 20,000 | 5,284.2 ns | 193.5 MB/s | 1,072 B | 35 | 7,666 B |
| `cli: embed component + props struct synthesis` | 20,000 | 2,383.7 ns | 73.6 MB/s | 184 B | 5 | 1,016 B |
| `cli: fail-fast diagnostic error path (undefined macro)` | 50,000 | 1,486.5 ns | 57.7 MB/s | 90 B | 7 | 1,101 B |
| `cli: multi-frame diagnostic + snippet trace` | 20,000 | 8,733.2 ns | 111.5 MB/s | 1,021 B | 38 | 10,894 B |
| `cli: pure transpile codegen (emit_loc = true)` | 50,000 | 3,859.9 ns | 1,356.7 MB/s | 5,491 B | 0 | 0 B |
| `cli: pure transpile codegen (emit_loc = false)` | 50,000 | 3,261.0 ns | 1,290.3 MB/s | 4,412 B | 0 | 0 B |
| `cli: full parse + inheritance + transpile (cached layout)` | 20,000 | 14,827.7 ns | 120.5 MB/s | 1,874 B | 32 | 11,948 B |
| `cli: batch compile 3 templates (shared warm cache)` | 10,000 | 21,809.1 ns | 99.9 MB/s | 2,285 B | 66 | 18,590 B |
| `cli: --watch workspace snapshot diff (32 files)` | 100,000 | 856.7 ns | 2.2 MB/s | 2 B | 0 | 0 B |

---

## Runtime Optimization Deep Dive (`runtime.odin`)

### 1. Lookup-Table Fast Paths & Stack-Batched Cold Escapers
`__temple_write_escaped_string`, `__temple_write_url_param`, and `__temple_write_js_string` are split into a small, inlinable hot fast-path and a `@(optimization_mode = "favor_size")` cold slow-path:

* **`@(rodata)` 256-Byte Lookup Tables:** Each escaper indexes a constant 256-entry table (`HTML_ESCAPE_TABLE`, `URL_UNRESERVED_TABLE`, `JS_ESCAPE_TABLE`) in a tight loop. When an input string requires no escaping (the common case in HTML rendering), the fast path completes the scan and issues a single `io.write_string(w, str)` call (`~3.84 GB/s` on 64 KB clean HTML, `26.2 ns` on 70B ASCII).
* **256-Byte Stack-Buffered Batching:** When the fast scan encounters the first byte requiring escaping at index `first_esc`, it delegates to the slow path (`__temple_write_escaped_string_slow`, `__temple_write_url_param_slow`, `__temple_write_js_string_slow`) passing `first_esc` so prefix bytes are never rescanned. Instead of calling `io.write_string` for every entity and 1–3 byte run between special characters, the slow path coalesces prefixes, entity replacements, and contiguous unescaped runs into a `[256]byte` stack buffer before flushing to `w`.

### 2. Early-Exit URL Sanitizer (`__temple_write_safe_url`)
* **Relative URL Fast-Path:** Scans for `/`, `?`, `#`, or `:`. Any URL that hits `/`, `?`, or `#` before `:` (or contains no `:`) is immediately recognized as a safe relative URL without scheme parsing (`31.1 ns`).
* **Zero-Allocation Case-Insensitive Scheme Validation:** Uses allocation-free ASCII folding (`__temple_ascii_eq_fold`, `__temple_ascii_has_prefix_fold`) to allow `http`, `https`, `mailto`, `tel`, and safe non-SVG `data:image/{png,gif,jpeg,jpg,webp};` URIs while neutralizing obfuscated `javascript:` / `vbscript:` / `data:text/html` payloads to `#ZgotmplZ` in `17.4 ns`.

### 3. Direct Base-10 Integer & Fixed-Point Float Writers
Using `fmt.wprintf` for simple numeric fields incurs format-string parsing and `any` reflection overhead. Temple provides two specialized stack-buffered writers in `runtime.odin`:

* **`__temple_write_int`:** Uses a `@(rodata)` 200-byte two-digit lookup table (`DEC_DIGITS_2 = "000102...99"`). Single-digit (`0..9`) and two-digit (`10..99`) non-negative integers slice directly into `DEC_DIGITS_2` without a loop or stack copy; larger 64-bit signed integers are formatted two digits per division into a `[24]byte` stack buffer.
* **`__temple_write_f64_prec`:** Formats `f64` values with a fixed decimal precision (`0..6` decimal places, `|val| < 1e12`) using precomputed power-of-10 tables (`F64_POW10`, `U64_POW10`), round-half-to-even (banker's rounding matching `strconv.write_float` / `fmt.wprintf`), and `DEC_DIGITS_2` into a `[64]byte` stack buffer. Writing both a price (`$149.95`) and item count (`12`) with surrounding text takes **`38.3 ns` (`0 allocs`)** vs **`280.5 ns`** for `fmt.wprintf`.

### 4. Zero-Allocation Streaming `fmt` Adapter
For multi-argument format strings like `{{ fmt("%s: $%.2f (%i items)", this.title, this.price, this.count) }}`, Temple avoids `fmt.tprintf` (which allocates on `context.temp_allocator`). Instead, `__temple_write_fmt_escaped` and `__temple_write_fmt_raw` wrap the destination `io.Writer` in a stack-allocated `__Temple_Fmt_Writer` carrying a `[256]byte` stack buffer (`stack_buf`) and invoke `fmt.wprintf(..., flush = false)`. Small formatted outputs accumulate in `stack_buf` and flush in a single pass—running **1.7x faster** than `fmt.tprintf` with **0 allocations** (vs 3 allocations / 109 B per op).

### 5. Precomputed `approx_bytes` & Adaptive Loop Estimation
Every compiled template exposes `approx_bytes: int`:
* Static text nodes add their exact byte length.
* `if`/`elseif`/`else` and `switch`/`case` blocks add the maximum `approx_bytes` across branches.
* Hoisted `{% macro %}` declarations pre-calculate their body size so `{% call %}` sites add the target macro's estimated output size.
* `for` loops use an adaptive multiplier (`8x` for small inline loops; `60x` when the loop body is `>= 128` bytes, typical of table/grid rows).

For the 50-row dashboard benchmark (`15,276 B` actual rendered HTML), `dashboard_tmpl.approx_bytes` is `15,973 B`—allowing `strings.builder_make(0, dashboard_tmpl.approx_bytes)` to render the entire page in **1 allocation** instead of **8 reallocations (`37,155 B` allocated)** with an unbuffered builder.

---

## Compiler Pipeline Optimization Deep Dive (`cli/`)

### 1. Stage 1: Source Pre-Filtering & Copy-on-Write Scope Resolution
* **Fast Source Pre-Filter:** Before invoking `core:odin/parser` on a package directory, `collect_compile_calls` scans raw `.odin` source strings for `"temple"` or `"::"` constant declarations. During AST traversal, top-level procedure literals (`^ast.Proc_Lit`) whose source span does not contain `"compiled"`, `"::"`, or a known `temple` alias are skipped without walking their statement trees.
* **Copy-on-Write Lexical Scopes:** `File_Collect_Ctx` shares package-level constant and procedure-alias maps across procedures and blocks, cloning them (`ensure_owned_proc_aliases`, `ensure_owned_string_consts`) only when a local scope actually declares or shadows a constant or variable.

### 2. Stage 2: Slice Lexer, Unified AST Slab & Fast Expression Classifiers
* **Slice-Scanning Lexer (`447.6 MB/s`, `0 allocs/op`):** `lexer_consume_text_until_tag` and `lexer_consume_tag_expr` advance over raw HTML text and unquoted tag expressions in tight inner loops, slicing directly into the source buffer without per-token heap allocations.
* **Unified Parser & Inheritance Slab Allocators:** `Parser` (`alloc_parser_node`) and `Compile_Context` (`alloc_ctx_node`) bump-allocate AST nodes (`Node_Text`, `Node_Output`, `Node_If`, `Node_For`, `Node_Switch`, `Node_Case`, `Node_Let`, `Node_Block`, `Node_Call`, etc.) from a contiguous byte slab instead of issuing separate heap allocations per AST node.
* **Fast-Path Expression Classifiers:** Before spinning up `core:odin/parser`, the template parser checks lightweight classifiers (`try_fast_classify_output_expr`, `validate_if_condition_expr`, `validate_for_clause_expr`, `validate_case_expr`, `validate_let_assignment_expr`) that validate and classify common selectors (`this.host`), simple binary arithmetic (`idx + 1`), `len(...)`, type casts, single/two-stage pipe chains (`this.host | default("unknown")`, `this.latency_ms | fmt("%.2f ms")`), enum cases (`.Healthy`), and `for row, idx in this.rows` clauses with zero allocations. Complex Odin expressions transparently fall back to `core:odin/parser` using a `[512]byte` stack buffer for synthetic statement wrapping.
* **Compile-Time `fmt` Strength Reduction & Text Coalescing:** During parsing and layout flattening, `try_parse_simple_fmt_literal` detects single-argument `fmt` strings with `%s`, `%i`, `%d`, `%f`, or `%.Nf`. Static prefix and suffix literals are split out (and HTML-escaped at compile time unless piped to `| raw`) and merged with adjacent `Node_Text` nodes so surrounding HTML and format prefixes/suffixes emit as a single `io.write_string` call.
* **Inline Splicing Caches:** `Compile_Context` keeps 8-slot inline arrays (`inline_raw`, `inline_resolved`, `inline_stack`) for raw parsed templates, resolved layouts, and diagnostic trace frames so typical 2- and 3-level layout inheritance chains never allocate hash maps or dynamic trace arrays.

### 3. Stage 3: Zero-Allocation Codegen & Content-Diffed Output
* **Zero-Allocation Transpiler (`1,356.7 MB/s`, `0 allocs/op`):** `transpile` emits 5,491 bytes of formatted Odin code for `dashboard.temple.html` in `3.86 µs` (`3.26 µs` with `emit_loc = false`) with **0 heap or temp allocations**:
  * `write_quoted_fast` quotes clean and common escaped string literals using stack buffers (`[256]byte` / `[512]byte`) instead of `io.write_quoted_string`.
  * `transpile_loc` and `write_fast_uint` format `/* line:col in template */` comments and integer literals into a `[48]byte` stack buffer via `append_uint_digits`.
  * `write_newline` and `write_indent` slice into a constant `NEWLINE_TABS` string to emit `\n` plus up to 16 `\t` indentation levels in a single `io.write_string` call.
  * `Transpiler` tracks up to 8 in-file macros in fixed arrays (`macro_names: [8]string`, `macro_bytes: [8]int`) before falling back to a map.
* **No-Op Write Skipping:** At the end of compilation, `transpile_calls` compares the newly generated Odin body against the existing output file on disk (ignoring the timestamp header) and skips writing to disk when unchanged, avoiding unnecessary file-watcher triggers and downstream Odin rebuilds.
