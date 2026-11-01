# Implementation Plan: Context-Aware Escaping & Safe Writers

## Phase 1: Runtime Escaping Writers (`runtime.odin`)

- [ ] Task: Implement `__temple_write_safe_url` and `__temple_write_url_param` in `runtime.odin`
    - [ ] Write unit tests in `runtime_test.odin` covering safe/unsafe URL schemes (`javascript:`, mixed case, control chars, relative paths) and RFC 3986 percent-encoding
    - [ ] Implement batched `__temple_write_safe_url` and `__temple_write_url_param`
- [ ] Task: Implement `__temple_write_js_string` in `runtime.odin`
    - [ ] Write unit tests in `runtime_test.odin` for `<script>` breakout (`</script>`), quotes, backslashes, control characters, and Unicode line separators
    - [ ] Implement batched `__temple_write_js_string`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Runtime Escaping Writers (runtime.odin)' (Protocol in workflow.md)

## Phase 2: Parser Classification & Transpiler Codegen (`cli/`)

- [ ] Task: Add `Url_String`, `Url_Param_String`, and `Js_String` to `Output_Write_Kind`
    - [ ] Write parser and transpiler tests in `cli/regression_test.odin` for `{{ url(...) }}`, `{{ url_param(...) }}`, and `{{ js(...) }}` (including nested calls and invalid arg counts)
    - [ ] Update `validate_and_classify_output_expr` in `cli/parser.odin` and `transpile_output` in `cli/transpiler.odin`
- [ ] Task: Add end-to-end rendering tests in `tests/templates_test.odin` and document in `README.md`
    - [ ] Add e2e test verifying `url()`, `url_param()`, and `js()` inside an HTML template
    - [ ] Document the new escaping helpers in `README.md`
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Parser Classification & Transpiler Codegen (cli/)' (Protocol in workflow.md)
