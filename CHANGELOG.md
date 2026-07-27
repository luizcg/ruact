# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> ruact is pre-1.0 and the API is still moving. Entries marked **⚠️ Breaking**
> require a change on your side; everything else is safe to take.

## [Unreleased]

## [0.0.8] - 2026-07-11

Focused on making ruact legible to coding agents — and, as it turns out, to
humans reading an unfamiliar codebase.

### Added

- **`rails generate ruact:install` now writes an `AGENTS.md`.** ruact is too new
  to be in any model's training data, so a fresh app ships the conventions,
  the common mistakes and the verification commands in-repo. Re-running install
  is zero-diff, and an `AGENTS.md` you already wrote is appended to, never
  overwritten. The same reference is served at
  [ruact.dev/llms.txt](https://ruact.dev/llms.txt).
- **Test helpers for asserting what a page rendered.** `expect(response).to
  have_ruact_component("PostList")`, optionally `.with_props(...)`, checks the
  decoded component tree instead of string-matching the wire bytes. Requires
  `require "ruact/testing"` in your `spec_helper` — it is not loaded by
  `require "ruact"`, so production carries no RSpec dependency.
- **JSON output for the diagnostic tasks.** `bin/rails ruact:doctor -- --json`
  and the new `bin/rails ruact:routes -- --json` emit machine-readable
  documents, so CI and agents no longer parse terminal prose. Marked
  experimental (`schema_version: 0`) — gate on that field, the shape may change.
- **Opt-in auto-revalidate.** A mutation whose result appears elsewhere on the
  page needed two calls, and forgetting the second left a stale page that looks
  like a bug. Now `configureRuactRuntime({ autoRevalidate: true })` app-wide, or
  `await withRefresh(createPost)(fd)` per call, folds the refresh in. Default
  behaviour is unchanged.
- **`ruact_props` now works on ActiveRecord models.** Declaring
  `ruact_props :id, :title` on a model used to fail at boot with
  `method 'title' is not defined`, even for a real column, because ActiveRecord
  defines attribute readers lazily. A typo still raises the same clear error —
  only the timing moved, to the model's first render.

### Changed

- **Putting children inside a component tag now fails loudly.** ruact component
  tags are self-closing; a component takes props, never a child tree. Writing
  `<Card>Hello</Card>` out of JSX habit used to degrade in silence — the text
  leaked into the surrounding HTML and the closing tag passed through as
  garbage. It now raises with the file, the line and the fix.
- **Development-only log naming the response shape.** The same controller
  action answers different body shapes depending on the request's `Accept`
  header and verb. In development, ruact prints one line per request saying
  which shape it chose and why. The responses themselves do not change.
- **`ManifestError` is now in English** (it was Portuguese). Same class, same
  raise site, same diagnostic content.

## [0.0.7] - 2026-06-30

### Fixed

- **⚠️ First request in a new app no longer 500s.** Rails read the client
  manifest once at boot — usually *before* the Vite dev server had written it —
  and never re-read it, so the first page containing a component died with a
  cryptic `NoMethodError`. In development the manifest is now fetched from the
  Vite dev server over HTTP, falling back to the file on disk, and failing with
  an actionable message ("run `bin/dev`") instead of a nil crash. Production is
  untouched. **If you hit this, upgrading is the fix** — no code change needed.

## [0.0.6] - 2026-06-30

The largest release so far: server functions settled into their final shape,
`ruact:scaffold` arrived, and a new app became installable in one command.

### Removed

- **⚠️ Breaking: the `ruact_action` DSL and the `POST /__ruact/fn/:name`
  endpoint are gone**, along with standalone server actions
  (`extend Ruact::ServerAction`, `app/server_actions/`). They shipped in 0.0.3
  and are replaced by the route-driven model below. **If you are on 0.0.3–0.0.5
  and used `ruact_action`, this release will break you.** The migration: a
  mutation is now a normal controller action on a controller that does
  `include Ruact::Server`, reached at its real Rails route. Routing goes back to
  Rails — `rails routes` shows every server function.

### Added

- **`rails generate ruact:scaffold Post title:string body:text`** generates a
  complete CRUD resource with a React interface: model, migration, route and
  test stubs (by delegating to Rails' own `resource` generator), plus the
  controller, views, list/form/delete components and a live-search query. The
  generated components are plain React with no design-system dependency;
  `--shadcn` opts into shadcn/ui components instead.
- **One-command install.** `rails generate ruact:install` now also writes
  `package.json`, `Procfile.dev` and `bin/dev`, and runs `npm install`, so
  `bin/dev` boots both Rails and Vite on a fresh app.
- **Validation errors round-trip to the client.** Call `ruact_errors(record)` in
  the failure branch and the client receives them keyed by attribute, surviving
  the redirect on a form post.
- **Record references can cross the wire signed.** `Ruact.signed_global_id` and
  `Ruact.locate_signed` give you a tamper-proof handle instead of a raw id.
  Both require an explicit purpose — omitting it raises rather than defaulting.
- **TypeScript types for query results**, emitted alongside the generated
  accessors, and a **component contract** (`export const __ruactContract`) that
  turns a misspelled prop into a build-time error with a "did you mean?"
  suggestion instead of a silent `undefined` at runtime.
- **`ruact:doctor` checks the serialize-only invariant** and warns when
  configuration could let non-serializable data reach the wire.

## [0.0.5] - 2026-06-10

### Added

- **`useQuery` de-duplicates in-flight requests.** Several components asking for
  the same data at the same time now share one request instead of racing.

## [0.0.4] - 2026-06-10

### Added

- **Server queries reach React through generated accessors.** Query classes are
  emitted into the generated module and called through `useQuery`, with keyword
  arguments sanitized on the way in.

## [0.0.3] - 2026-06-10

### Changed

- **⚠️ Breaking: every `rsc_*` name became `ruact_*`.** A clean cut with no
  aliases: `ruact_render`, `ruact_request?`, `ruact_props`, `ruact_serialize`,
  the `Ruact-Request` header, the `ruact:doctor` task, and the
  `data-ruact` DOM attribute. **Rename them in your app when upgrading** — the
  old names are simply gone.

### Added

- **Server functions, first iteration.** Mutations declared with `ruact_action`,
  invoked from React through a generated accessor, with file uploads and a
  size guard. *Superseded in 0.0.6 — see that release before adopting.*
- **Structured error payloads** for failed server calls, surfaced in the
  development error overlay.

### Fixed

- **Render context is no longer thread-global**, so nested and concurrent
  renders cannot leak into each other.
- **Configuration is frozen after boot**, turning a late `Ruact.configure` from
  a silent no-op into a clear error.
- **`render_to_string` sees the controller's instance variables**, fixing a 500
  on pages rendered that way.

## [0.0.2] - 2026-04-19

### Fixed

- Corrected the vendored asset paths in the gemspec — 0.0.1 shipped without the
  JavaScript runtime it needs. Added the license file.

## [0.0.1] - 2026-04-19

First public release. React Server Components for Rails, with no Node runtime
in production.

### Added

- **ERB as the server component.** PascalCase self-closing tags in ERB
  (`<LikeButton postId={@post.id} />`) become React elements. `<Suspense
  fallback="...">` maps to a real React Suspense boundary.
- **`Ruact::Controller`** — include it and your actions render React. Detects
  RSC requests, emits the HTML shell, and makes `redirect_to` work across the
  Flight protocol. With `ActionController::Live`, rows stream as they are
  produced.
- **`Ruact::Serializable`** — the `ruact_props` allowlist declaring exactly
  which attributes may cross the wire.
- **Client components** resolved from a manifest produced by the companion
  `vite-plugin-ruact` npm package, which scans your `"use client"` files.
- **Client-side navigation** — same-origin links and form submissions are
  intercepted and swapped in place, without a full page reload.
- **`rails generate ruact:install`** and **`rails ruact:doctor`** for setup and
  diagnosis.
- **Development error overlay** for Flight parse and render failures.

[Unreleased]: https://github.com/luizcg/ruact/compare/v0.0.8...HEAD
[0.0.8]: https://github.com/luizcg/ruact/releases/tag/v0.0.8
[0.0.7]: https://github.com/luizcg/ruact/releases/tag/v0.0.7
[0.0.6]: https://github.com/luizcg/ruact/releases/tag/v0.0.6
[0.0.5]: https://github.com/luizcg/ruact/releases/tag/v0.0.5
[0.0.4]: https://github.com/luizcg/ruact/releases/tag/v0.0.4
[0.0.3]: https://github.com/luizcg/ruact/releases/tag/v0.0.3
[0.0.2]: https://github.com/luizcg/ruact/releases/tag/v0.0.2
[0.0.1]: https://github.com/luizcg/ruact/releases/tag/v0.0.1
