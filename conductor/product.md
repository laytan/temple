# Initial Concept

A fast, compile-time templating engine for Odin that transpiles Twig/Mustache-inspired templates directly into zero-overhead Odin code.

# Product Guide

## Vision

Temple provides Odin web and application developers with an ergonomic, safe-by-default, compile-time template engine. Templates are validated and transpiled ahead of time into idiomatic, zero-overhead Odin procedures so applications ship as a single self-contained binary with zero runtime template parsing overhead.

## Target Users

- Odin backend and full-stack web developers building server-rendered HTML, hypermedia (HTMX/Datastar), email, or text views.
- Library and framework authors seeking a type-safe, zero-allocation/buffered `io.Writer` template layer compatible with Odin's `shared:` collection.

## Core Capabilities (v1.0.0)

- Mustache/Twig-inspired output (`{{ ... }}`), conditionals (`if` / `else if` / `else`), loops (`for`), pattern matching (`switch` / `#partial switch` / `case`), and local bindings (`let`).
- AST-powered pipe filter DSL (`|`), zero-allocation streaming `fmt(...)` formatting, and `default(...)` fallbacks inside `{{ ... }}` tags.
- Layout inheritance (`extends`, `block`, `super()`), sub-template embedding (`embed ... with` and component-style named props `embed "card.html"(this.title, active = true)`), parameterized macros (`{% macro %}` / `{% call %}`), comments (`{# ... #}`), and whitespace trimming (`{{-`, `-}}`, `{%-`, `-%}`).
- Compile-time Odin AST expression validation (`core:odin/parser`) and Rust/Odin-style diagnostics with full `Call_Site -> Extends -> Embed` trace stacks.
- Batched HTML entity escaping by default with context-aware escaping (`url`, `url_param`, `js` / `json`), `raw(...)` / `| raw`, `magic(...)` / `| magic`, and explicit numeric/rune type-cast writers.
- Decoupled code generation (`-out`, `-pkg`, `-temple-import`) for Odin `shared:` collection installations alongside CLI verification (`--check`), orphan template detection (`--warn-unused`), and incremental file watch (`--watch`) modes.

## 1.0.0 Roadmap Goals

1. **Decoupled Code Generation & Shared Collection Support:** Generate compiled template code into the user's own package so `temple` can be installed once as a read-only library in Odin's `shared:` collection.
2. **Context-Aware Auto-Escaping & Safe Writers:** Add URL, attribute, and JSON/JS string escaping helpers alongside HTML escaping.
3. **Parameterized Macros / Components & Formatting Helpers:** Add reusable `{% macro %}` components and `fmt(...)` output formatting.
4. **Developer Experience & CLI Tooling:** Add `--watch` incremental rebuilds, `--check` CI verification mode, and `--warn-unused` orphan template detection.
5. **Cross-Platform Path Normalization & CI Pipeline:** Canonicalize template identifiers across OSes and enforce automated multi-OS GitHub Actions testing.
