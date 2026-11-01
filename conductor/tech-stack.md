# Technology Stack

## Language & Runtime
- **Language:** Odin (`dev-2026-09`+)
- **Standard Library Dependencies:**
  - Runtime (`package temple`): `core:io` (plus `core:fmt` / `core:encoding` as needed for escaping/formatting helpers)
  - Compiler CLI (`package temple_cli`): `core:odin/ast`, `core:odin/parser`, `core:odin/tokenizer`, `core:os`, `core:path/filepath`, `core:mem`, `core:strings`, `core:strconv`, `core:slice`, `core:sync`, `core:thread`, `core:time`, `core:fmt`, `core:io`

## Architecture
- **`runtime.odin` (`package temple`):** Lightweight runtime descriptor (`Compiled($T)`), batched XSS HTML escaper (`__temple_write_escaped_string`), word-span writer (`__temple_write_magic_string`), and context-specific escaping helpers.
- **`cli/` (`package temple_cli`):**
  - `lexer.odin`: Zero-copy template tokenizer with whitespace trimming and quote-aware expression scanning.
  - `parser.odin`: Recursive-descent template AST parser with embedded `core:odin/parser` snippet validation.
  - `transpiler.odin`: Code generator emitting `core:io` writer calls and computing `approx_bytes`.
  - `main.odin`: Odin AST call collector (`temple.compiled` / `temple.compiled_inline`), multi-level layout inheritance resolver, parallel worker pool, and diagnostic reporter.

## Testing
- `odin test cli` — Unit, regression, and deterministic fuzzing suite (`cli/cli_test.odin`, `cli/regression_test.odin`)
- `odin test .` — Runtime unit suite (`runtime_test.odin`)
- `odin test tests` — End-to-end compiled template integration suite (`tests/templates_test.odin`)
