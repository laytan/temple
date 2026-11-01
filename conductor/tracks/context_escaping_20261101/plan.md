# Implementation Plan: Context-Aware Escaping & Safe Writers

## Phase 1: Runtime Escaping Writers (`runtime.odin`)

- [x] Task: Implement `__temple_write_safe_url` and `__temple_write_url_param` in `runtime.odin`
    - [x] Write unit tests in `runtime_test.odin` covering safe/unsafe URL schemes (`javascript:`, mixed case, control chars, relative paths) and RFC 3986 percent-encoding
    - [x] Implement batched `__temple_write_safe_url` and `__temple_write_url_param`
- [x] Task: Implement `__temple_write_js_string` in `runtime.odin`
    - [x] Write unit tests in `runtime_test.odin` for `<script>` breakout (`</script>`), quotes, backslashes, control characters, and Unicode line separators
    - [x] Implement batched `__temple_write_js_string`
- [x] Task: Conductor - User Manual Verification 'Phase 1: Runtime Escaping Writers (runtime.odin)' (Protocol in workflow.md)

## Phase 2: Parser Classification & Transpiler Codegen (`cli/`)

- [x] Task: Add `Url_String`, `Url_Param_String`, and `Js_String` to `Output_Write_Kind`
    - [x] Write ATDD executable specifications in `cli/temple_spec_test.odin` for both pipe (`| url`, `| url_param`, `| js`) and call (`url(...)`, `url_param(...)`, `js(...)`) syntax (including composition with `default(...)` and invalid arg counts)
    - [x] Update `classify_output_ast` in `cli/parser.odin` and `transpile_output` in `cli/transpiler.odin`
- [x] Task: Add end-to-end rendering tests in `tests/templates_test.odin` and document in `README.md`
    - [x] Add e2e test verifying `url()`, `url_param()`, and `js()` inside an HTML template
    - [x] Document the new escaping helpers in `README.md`
- [x] Task: Conductor - User Manual Verification 'Phase 2: Parser Classification & Transpiler Codegen (cli/)' (Protocol in workflow.md)
