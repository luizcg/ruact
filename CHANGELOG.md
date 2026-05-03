# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Tooling

- **Code coverage instrumentation** (Story 6.7). Added `simplecov` and `simplecov-lcov` as development dependencies; gem CI uploads coverage from the canonical matrix cell (Ruby 3.3 × Rails 7.2) to Codecov on every push and PR with the `gem` flag. **Baseline at merge: 88.30% line (581/658), 72.25% branch (239 specs).** (Corrects the earlier 87.89% figure recorded at story-merge time, which was a typo of the SimpleCov output for 567/644 = 88.04%; the current numbers reflect the post-review state after Story 6.7 review F1 refactored `html_converter.rb#convert_element` into helpers, which added a few lines and one new spec.) Coverage is informativo (not a CI gate); see Codecov PR comments for diff coverage on individual changes. Diff coverage target per project DoD: ≥ 90% line / ≥ 80% branch on new code.
- **Spec `rails_stub.rb` fix.** The previous `$LOADED_FEATURES.any? { |f| f.end_with?("/rails.rb") }` heuristic for skipping the `LOADED_FEATURES` insertion was unreliable — unrelated gems ship files at `*/rails.rb` (e.g. SimpleCov's `simplecov/profiles/rails.rb`). Replaced with an unconditional insertion guarded only by the existing `return if defined?(Rails)` early-exit, which is the correct invariant.

### Renamed

- The gem and its top-level constant were renamed from `rails_rsc` / `RailsRsc` to `ruact` / `Ruact` between v0.0.2 and v0.0.3. Host apps must update their `Gemfile` (`gem "rails_rsc"` → `gem "ruact"`) and any code referencing `RailsRsc::*` (replace with `Ruact::*`). The `rails rsc:doctor` task now detects and reports legacy constant usage in `config/initializers/` and `app/`.

### Internal

- Rake task descriptions and internal `require` statements migrated from `rails_rsc` to `ruact`. Public API is unchanged; this is a documentation and tooling rename only.
- **Render context now passed explicitly** ([Story 7.1](../_bmad-output/implementation-artifacts/7-1-refactor-componentregistry-from-thread-current-to-explicit-render-context.md)). `Ruact::ComponentRegistry` (which used `Thread.current`) has been removed; the per-render component list is now an instance of `Ruact::RenderContext` passed explicitly through `Controller#rsc_render → RenderPipeline → HtmlConverter`. The `Ruact/NoSharedState` cop now passes with no exceptions in `lib/ruact/`. **No public API change.** Note: `Ruact::Flight::*`, `Ruact::Internal::*`, and `Ruact::RenderContext` are not part of the public API and may change between minors. Hosts upgrading need no application code changes. See [decision note](../_bmad-output/decisions/2026-04-30-render-context-refactor.md) for rationale and contributor guidance.
- **`RenderPipeline` entry points consolidated** ([Story 7.2](../_bmad-output/implementation-artifacts/7-2-consolidate-renderpipeline-entry-points-into-single-coherent-api.md)). `RenderPipeline#call`, `#stream`, and `#from_html` have been removed and replaced with a single `#render(input, mode:)` entry point. `input` selects the source — `{ erb: String, binding: Binding }` for ERB templates or `{ html: String, render_context: Ruact::RenderContext }` for pre-rendered HTML; `mode:` selects the output shape — `:string` returns a `String` (deferred chunks inlined eagerly), `:stream` returns an `Enumerator` of Flight rows (deferred chunks delay). Conflicting input keys, missing siblings, and unknown modes raise `ArgumentError` with the offending input named. **No public API change** — `Ruact::Controller#rsc_render` is unchanged. Note: `Ruact::Flight::*`, `Ruact::Internal::*`, and `Ruact::RenderPipeline` are not part of the public API and may change between minors. See [decision note](../_bmad-output/decisions/2026-05-renderpipeline-entry-point-consolidation.md) for rationale and contributor guidance.

  _Migration for any external code that may have reached into `Ruact::RenderPipeline`:_ `pipeline.call(erb, binding)` → `pipeline.render({ erb: erb, binding: binding }, mode: :string)`; `pipeline.stream(erb, binding)` → `pipeline.render({ erb: erb, binding: binding }, mode: :stream)`; `pipeline.from_html(html, render_context: ctx)` → `pipeline.render({ html: html, render_context: ctx }, mode: :string)`; `pipeline.from_html(html, render_context: ctx, streaming: true)` → `pipeline.render({ html: html, render_context: ctx }, mode: :stream)`.

## [0.1.0] - 2026-03-24

### Added

- **ERB preprocessor** — PascalCase RSC component tags (`<Button />`, `<LikeButton postId={@post.id} />`) are transformed to Flight placeholders in ERB templates before Ruby evaluation.
- **`<Suspense>` support** — `<Suspense fallback="Loading...">` in ERB templates maps to React Suspense boundaries in the Flight payload.
- **React Flight wire format serializer** — Full Ruby-to-Flight protocol implementation covering: nil, booleans, integers, floats (NaN/Infinity/-0), strings (with `$` escaping), arrays, hashes, `Time`/`DateTime`, large strings (T rows), `ReactElement`, `SuspenseElement`, and `ClientReference`.
- **`Ruact::Controller` concern** — Include in `ApplicationController` to enable RSC rendering. Provides `rsc_render`, RSC request detection (`text/x-component` / `RSC-Request: 1` header), HTML shell generation with inline `__FLIGHT_DATA`, and Flight-aware `redirect_to`.
- **Streaming mode** — When `ActionController::Live` is included, Flight rows are streamed to the client as they are produced (Suspense-aware).
- **Client component resolution** — `Ruact::ClientManifest` reads `public/react-client-manifest.json` (generated by the Vite plugin) and resolves component names to `ClientReference` objects via a dual-path resolver.
- **`Ruact::Serializable` mixin** — `rsc_props` DSL for declaring safe prop attributes on Ruby model objects.
- **Install generator** — `rails generate ruact:install` scaffolds the initializer, Vite config patch, and JavaScript entry point.
- **`rsc:doctor` Rake task** — Checks manifest presence, Vite server accessibility, controller setup, and streaming mode configuration.
- **`vite-plugin-ruact`** — Vite plugin (npm package, co-versioned) that scans `"use client"` components and emits `public/react-client-manifest.json`.
- **Client-side navigation** — JavaScript `rsc-router.js` intercepts same-origin link clicks and form submissions, fetches Flight payloads, and updates the React tree without full-page reloads.
- **Error overlay** — Development-mode React error boundary with dismissible overlay for Flight parse and rendering errors.
- **RSpec test suite** — 223 examples covering all modules: Flight serializer, ERB preprocessor, HTML converter, render pipeline, controller, client manifest, serializable, install generator, and `rsc:doctor`.
- **Memory benchmark** — `rake benchmark:memory` enforces a 120% allocation regression gate against `spec/benchmarks/baseline.json`.
- **CI matrix** — GitHub Actions: RSpec across Ruby 3.2 × 3.3 × Rails 7.0 × 7.1 × 7.2 × 8.0; RuboCop; YARD docs; memory benchmark; E2E system tests against React 19.0.0 and 19.x (Capybara + Cuprite); non-blocking React@next job with auto-issue on failure.
- **E2E test app** — `e2e/` Rails app (no DB, in-memory Post model) with full CRUD system tests validating the complete request cycle.

[Unreleased]: https://github.com/luizcg/ruact/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/luizcg/ruact/releases/tag/v0.1.0
