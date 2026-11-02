# Product Guidelines

## Design Principles

1. **Compile-Time Safety Over Runtime Failure:** Catch syntax, expression, inheritance, and call-site errors in `temple_cli` with exact file/line/column diagnostics and source snippets before the Odin compiler runs.
2. **Zero Runtime Overhead:** Transpile templates into direct `core:io` writer calls with pre-calculated `approx_bytes` capacity hints and zero unnecessary heap allocations during rendering.
3. **Safe by Default, Explicit Opt-Out:** Escape untrusted output by default and provide explicit, auditable pseudo-functions (`raw(...)`, `url(...)`, `js(...)`, `json(...)`, `fmt(...)`) for specialized output contexts.
4. **Allocator Discipline:** Use arena/temp allocators explicitly in the CLI and keep runtime rendering procedures allocation-free on top of `core:io.Writer`.

## Code & Testing Standards

- Follow idiomatic Odin conventions (`Snake_Case` types, `snake_case` procedures/variables, `SCREAMING_SNAKE_CASE` constants).
- Every new lexer, parser, transpiler, or runtime capability must include in-memory unit/regression tests in `cli/` or `runtime_test.odin` and pass `odin test` with the tracking allocator reporting zero memory leaks.
