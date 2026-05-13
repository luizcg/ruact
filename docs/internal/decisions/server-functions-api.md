# Server Functions API — React-side accessor shape

| Field | Value |
| --- | --- |
| Date | 2026-05-12 |
| Status | Accepted |
| Story | 8.0 — Server functions API design spike (planning artifact in the workspace monorepo at `_bmad-output/implementation-artifacts/8-0-server-functions-api-design-spike.md` — link omitted because this file ships in the published gem and the planning path is workspace-only) |
| Inspected | `react@19.2.0` (latest 19.x line; gem pins `react ^19.0.0` per Story 8.0 AC1's `react@19.0.0` floor), `next@15.4.0-canary`, `eslint-plugin-react-hooks@v6` (the v5 → v6 bump landed in 2026-05; AC1 specified `5.x` at story-creation time — the upgrade was a no-op for the rule-of-hooks behaviour the spike inspected, but flagged here for honesty), `vite@6.x` |
| Locks | Stories 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 9.1, 9.2, 9.3, 9.4, 9.5 |
| Append-only | Yes — see "When to revisit" below |

## Context

Epic 8 (`ruact_action`) and Epic 9 (`ruact_query`) both need a way for a React
component to obtain a reference to a server-side function declared in a Rails
controller. Before this decision, the placeholder phrase "exposed to the view
(`server_actions[:create_post]` or equivalent — exact API to be finalized in this
story)" appeared in Story 8.1's AC1 and was implicitly carried by every downstream
story that needs the same reference.

A symmetric, ergonomic accessor must be picked once, shared by actions and
queries, and locked before implementation begins so that 11 downstream stories
consume a stable contract instead of re-litigating the API in each PR.

## Decision

**Option C — Named imports from a generated TypeScript module.**

A bundled extension to `vite-plugin-ruact` reads `Ruact.action_registry` and
`Ruact.query_registry` at Rails boot, and emits one virtual module:
`app/javascript/.ruact/server-functions.ts`. React components import each
function by name. Each export carries a per-function TypeScript signature
derived from the Ruby declaration.

```ts
// app/javascript/.ruact/server-functions.ts (auto-generated)
export declare function createPost(args: { title: string; body: string }):
  Promise<{ id: number; slug: string }>;
export declare function categories():
  Promise<Array<{ id: number; name: string }>>;
```

```tsx
// app/javascript/components/PostForm.tsx (hand-written)
import { createPost, categories } from "@/.ruact/server-functions";

export function PostForm() {
  return <form action={createPost}>...</form>;
}
```

Same accessor mechanics for actions and queries. No hook. No context provider.
No prop drilling. The import IS the accessor.

> **Note (2026-05-13, append-only):** the `export declare function` sketch
> above is superseded. The real codegen (Story 8.0a) emits runtime exports
> via `_makeRef("<symbol>")` with conservative TypeScript signatures
> (actions: `(args?: Record<string, unknown>) => Promise<unknown>`; queries:
> `() => Promise<unknown>`), not `export declare`. The `<form action={fn}>`
> sketch above also under-specifies the React-form path: when React invokes
> a server reference via `<form action>`, it passes a single `FormData`
> argument — Story 8.1 / 8.2 own how that `FormData` is unwrapped into Rails
> `params`. Query transport is POST (not GET); `useQuery(ref, params?)`
> returns `{ data, loading, error }` (not Suspense-only). See the Decision
> log entries from 2026-05-13 for the full resolutions.

## Alternatives considered

The decision was driven by a scoring matrix built in Task 2 of the spike
across nine axes: TypeScript support, bundle size, ESLint friction, hook-
rule compliance, nested-layout future-readiness, regeneration triggers,
debugging clarity, Rails-dev-learning-React curve, React-dev-learning-
ruact curve. The matrix lived in a scratch file (`/tmp/8-0-matrix.md`)
that was not committed to version control — the Task 2 checklist in the
Story 8.0 spike artifact (workspace-only path `_bmad-output/implementation-artifacts/8-0-server-functions-api-design-spike.md`)
records the axes; the per-option summary below preserves the qualitative
outcome. If the decision is ever re-litigated, rebuild the matrix from
scratch — do not trust a recovered scratch file. Each rejected option
below cites at least one pitfall from the spike's Context Bundle.

### Option A — Prop drilling from layout

Layout receives `server_actions` / `server_queries` from a gem-injected helper
and passes them as props down the tree.

```tsx
function App({ server_actions }) {
  return <PostForm createPost={server_actions.createPost} />;
}
```

**Pros:** zero codegen; no hooks; props are the most universal React idiom.
**Cons:** every nested layout has to re-inject; refactoring a system function's
location through a tree is the textbook "props vs context" anti-pattern; per-call
TypeScript types degrade as drilling depth grows.
**Rejected** citing pitfall #4 (the accessor shape constrains the rendering model).
Phase 3's nested layouts would force a re-design.

### Option B — `useServerActions()` / `useServerQueries()` hooks

The gem installs a Context Provider at the root of the layout; components call a
hook to retrieve the reference object.

```tsx
function PostForm() {
  const actions = useServerActions();
  return <form action={actions.createPost}>...</form>;
}
```

**Pros:** survives nested layouts via Context inheritance; no codegen; hot reload
trivially correct.
**Cons:** Rule of Hooks (`eslint-plugin-react-hooks` v6) requires top-level call,
so invoking from an event handler needs the two-line dance
(`const actions = useServerActions(); ...; <button onClick={() => actions.x()} />`);
hook returns one shared `actions` object whose typed shape is computed from a
single declaration, weakening per-function type inference.
**Rejected** citing pitfall #2 (hook-rule friction) and pitfall #3 (weaker per-function
type safety than C).

### Option C — Named imports from a generated module — **CHOSEN**

See "Decision" above. Validated end-to-end in `/tmp/8-0-sandbox/` (V1–V4):
codegen + `tsc --noEmit` + typo-detection + naming-bridge edge cases all pass.

**Pros:** strongest per-function TypeScript surface of any option (each
export is independently typed; rename triggers `TS2724` with a suggestion
across every call site); zero hook-rule friction (it's a plain import,
callable from event handlers, top-level, or anywhere); tree-shakable
(unused functions are dead-code-eliminated by Vite); jump-to-definition
works in any TS-aware editor; refactoring a Ruby symbol surfaces at
typecheck and at module-resolve time (not silently at runtime).
**Cons:** requires a codegen step (Story 8.0a — Vite plugin + Railtie
hook + rake task; the implementation surface is non-trivial and adds a
second source of truth that the Ruby↔JS parity test must keep aligned);
generated module is build-time state, so it has a regeneration-trigger
matrix (`config.to_prepare` in dev; rake task in CI/prod) that the spike
had to design explicitly; introduces a new file path (`app/javascript/.ruact/`)
that host apps must gitignore.
**Chosen** citing pitfall #3 (type safety) and pitfall #4 (nested-layout
future-readiness) — the codegen cost is paid up-front, in one place, by
the gem maintainer, in exchange for the strongest ergonomic + TS surface
across all eleven downstream stories.

### Option D — `useServerFunction("name")`

A single hook keyed by symbolic name.

```tsx
function PostForm() {
  const createPost = useServerFunction("createPost");
  return <form action={createPost}>...</form>;
}
```

**Pros:** simpler than B (one hook, no two-flavor split for actions vs queries);
no codegen.
**Cons:** string-keyed lookup defeats TypeScript almost completely (no per-function
parameter or return types without per-name overload tables); typos surface only at
runtime; jump-to-definition does not work; refactoring a Ruby symbol silently
breaks call sites.
**Rejected** citing pitfall #3 (type safety cuts both ways). The simplicity
argument does not compensate for the TS regression — and the entire reason ruact
ships TS support in Phase 2 (Story 6.1) is to make this kind of shape possible.

### Option E — Global `window.__ruactServerActions`

Considered and discarded immediately: pollutes global scope, not tree-shakable,
no TypeScript surface, conflates accessor with serialization, breaks SSR/test
isolation. One sentence and out.
**Rejected** citing pitfall #3 (type safety) and pitfall #4 (the global
accessor binds to a specific layout/runtime instance, fragmenting if
Phase 3 introduces nested layouts or per-route shells — same future-
coupling cost that disqualified Option A, only worse since `window`
mutations cannot be partitioned per shell).

## Applied

### Action use case (Story 8.2 — "Create Post" form)

```ruby
# app/controllers/posts_controller.rb
class PostsController < ApplicationController
  ruact_action :create_post do |params|
    Post.create!(title: params[:title], body: params[:body])
  end
end
```

```tsx
// app/javascript/components/PostForm.tsx
import { createPost } from "@/.ruact/server-functions";
import { useActionState } from "react";

export function PostForm() {
  const [state, formAction, pending] = useActionState(createPost, { message: "" });
  return (
    <form action={formAction}>
      <input name="title" required />
      <textarea name="body" required />
      <button disabled={pending}>Create</button>
      {state.message && <p>{state.message}</p>}
    </form>
  );
}
```

### Query use case (Story 9.2 — "populate dropdown")

```ruby
# app/controllers/posts_controller.rb
class PostsController < ApplicationController
  ruact_query :categories do
    Category.all
  end
end
```

```tsx
// app/javascript/components/CategoryPicker.tsx
import { useQuery } from "ruact";
import { categories } from "@/.ruact/server-functions";

export function CategoryPicker() {
  const items = useQuery(categories);  // suspends; throws Ruact.SuspenseError on stale read
  return (
    <select>
      {items.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
    </select>
  );
}
```

> **Note (2026-05-13, append-only):** the `useQuery(categories)` sketch
> above is the Suspense-based shape the spike originally drafted. Per
> the 2026-05-13 Review-patch clarifications (see Decision log), Story
> 9.2's hook signature is `useQuery(reference, params?) → { data, loading,
> error }`. The corrected sketch is:
>
> ```tsx
> const { data: items, loading, error } = useQuery(categories);
> if (loading) return <Spinner />;
> if (error) return <p>Could not load categories: {error.message}</p>;
> return <select>{items.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select>;
> ```
>
> Suspense-aware queries (`use(promise)` + `<Suspense>` boundaries) are
> reserved for a Phase 3 ADR addendum once React 19's stable `use()`
> semantics + adoption signal land.

The accessor mechanics are identical (one named import, no hook on the
import path, one type per function). Actions integrate with native React
`<form action>` + `useActionState`; queries integrate with ruact's
`useQuery` (Story 9.2). The symmetric-coverage invariant is preserved.

## Implementation surface

| # | Machinery | Owning story | "Done" signal |
|---|---|---|---|
| 1 | `Ruact.action_registry` + `Ruact.query_registry` (Ruby) — empty storage stubs + module-level accessors | **Storage: Implemented in Story 8.0a** (empty `Ruact::ServerFunctions::Registry` instances, `register` / `entries` / `clear!` + collision detection); **Population: Story 8.1 (actions) + Story 9.1 (queries)** — the DSL macros write into the storage 8.0a defined | `Ruact.action_registry # => Ruact::ServerFunctions::Registry` (empty at 8.0a merge); after Story 8.1's `ruact_action` evaluates, `Ruact.action_registry.entries[:create_post]` returns a populated `RegistryEntry` |
| 2 | DSL macros `ruact_action :name do |params| ... end` and `ruact_query :name do ... end` | Story 8.1 + 9.1 | Defining a macro at controller-class load time both registers the symbol and defines the matching method (visibility and CSRF rules per Story 8.2 / 9.4) |
| 3 | Server-function endpoint (single Rails route mounted by the gem; resolves by symbolic name from registries 1+2; no per-function entries in `routes.rb`) | Story 8.1 | `POST /__ruact/fn/:name` returns the action result; `GET /__ruact/fn/:name?args=...` returns the query result; both reuse `Ruact::Controller` security/CSRF |
| 4 | `vite-plugin-ruact` extension that emits `app/javascript/.ruact/server-functions.ts` from a Rails-side dump (JSON written by a Railtie initializer) | **Implemented in Story 8.0a** | Generated file present, `tsc --noEmit` green on a freshly-installed playground |
| 5 | Rails `config.to_prepare` hook that triggers regeneration of #4 in dev | **Implemented in Story 8.0a** | `bin/rails server`, edit a controller's `ruact_action`, file at `app/javascript/.ruact/server-functions.ts` updates without restart |
| 6 | `bin/rails ruact:server_functions:generate` rake task (manual + CI/production hook) | **Implemented in Story 8.0a** | Task succeeds on a clean checkout; file is byte-identical to dev-mode output |
| 7 | `rails generate ruact:install` updates: add `app/javascript/.ruact/.gitkeep`, add `app/javascript/.ruact/server-functions.ts` to `.gitignore`, run the generate rake task once | **Implemented in Story 8.0a** (originally tagged Story 8.1; landed early because the codegen surface lives in 8.0a) | Fresh `rails new` + `rails generate ruact:install` results in a working playground that can call a stub action without further setup |
| 8 | Naming-bridge implementation in #4 (Ruby → JS identifier) | **Implemented in Story 8.0a** | The 6 edge cases enumerated in "Naming bridge" below all behave per spec |
| 9 | `useQuery(reference, params?)` hook (consumes the named import) | Story 9.2 | `const { data, loading, error } = useQuery(categories)` works inside any function component; see Decision-log entry "2026-05-13 — Review-patch clarifications" for the supersession of the original Suspense-only sketch |

Every machinery item has a story assignment. As of 2026-05-13, rows #1
(storage layer), #4–#8 are **implemented in Story 8.0a** (`gem` commit
`862f07c`); rows #2, #3, #9 remain assigned to Stories 8.1 / 9.1 / 9.2.
Empty registries from row #1 are populated by the DSL macros in row #2.

## Naming bridge

### Rule

Ruby symbol → JS identifier:

```ruby
def to_js_identifier(symbol)
  s = symbol.to_s
  raise Ruact::ConfigurationError,
    "ruact_action / ruact_query symbol :#{symbol} must match /^[a-z_][a-z0-9_]*$/" \
    unless s.match?(/\A[a-z_][a-z0-9_]*\z/)
  leading_underscore = s.start_with?("_")
  body = leading_underscore ? s[1..] : s
  camel = body.gsub(/_+(.)/) { $1.upcase }
  leading_underscore ? "_#{camel}" : camel
end
```

The rule is implementable in 5 lines (above; the validation guard adds 2). Failure
mode is loud: invalid symbols raise `Ruact::ConfigurationError` at controller-class
load time (boot), not at runtime, not silently.

### Edge cases (validated in `/tmp/8-0-sandbox/`)

| Ruby symbol | JS identifier | Notes |
|---|---|---|
| `:create_post` | `createPost` | Standard snake_case → camelCase |
| `:categories` | `categories` | Single word — pass-through |
| `:_internal_dump` | `_internalDump` | Leading underscore preserved |
| `:foo__bar` | `fooBar` | Consecutive underscores collapse |
| `:RECALCULATE` | (rejected at boot) | `Ruact::ConfigurationError` — SCREAMING_SNAKE not allowed |
| `:CreatePost` | (rejected at boot) | `Ruact::ConfigurationError` — must start with lowercase letter or underscore |
| `:_` / `:__` | (rejected at boot) | `Ruact::ConfigurationError` — underscore-only symbols carry no semantic content (added 2026-05-13 via Story 8.0 review patch) |
| `:class` / `:export` / `:await` | (rejected at boot) | `Ruact::ConfigurationError` — the translated JS identifier collides with an ES2020+ reserved word (added 2026-05-13 via Story 8.0 review patch). Escape hatch: prefix with underscore (`:_class` → `"_class"`, accepted). |

The "rejected at boot" choice (vs silent normalization) is deliberate: ruby_symbol
→ JS-identifier conversion is one-way, so accepting `:CreatePost` and emitting
`createPost` would create two co-equal Ruby names for the same JS symbol —
collision-prone, hard to reverse-engineer in stack traces. The cost of the
strict rule is one early failure for the 1% of devs who use unusual casing,
which is the right trade.

The 2026-05-13 reserved-word + underscore-only additions follow the same
principle: a symbol that would produce JS that fails `tsc --noEmit` or trips
common ESLint configurations fails LOUDLY at controller-class load time
instead of silently shipping. The implementation lives in
`gem/lib/ruact/server_functions/name_bridge.rb` — `RESERVED_JS_IDENTIFIERS`
is the canonical list (ES2020+ keyword set + strict-mode reserved +
contextual reserved at module top level: `await`, `async`).

### Identifier collision

If two different Ruby symbols map to the same JS identifier (e.g., `:foo_bar`
and `:foo__bar` both → `fooBar`), the codegen step raises
`Ruact::ConfigurationError` listing both controllers. Validated in the spike
sandbox.

## When to revisit

This decision is **append-only**. When revisiting, add a dated addendum below
"Decision log"; do not rewrite the original.

Revisit if any of:

1. **React introduces an official `useServerReference` hook** (or equivalent
   accessor in the React core) in a stable release.
   *Action:* revisit, log a new ADR addendum, decide whether to migrate (or to
   provide both shapes during a transition).
2. **The Server Components specification adds new ergonomics** (e.g., the React
   team standardizes a reference-passing mechanism beyond `'use server'` import).
   *Action:* same as #1.
3. **≥ 3 external issues** (post-v0.1.0) request a different ergonomic from
   real users.
   *Action:* revisit; the threshold-of-3 is the bar to avoid one-voice
   over-rotation.
4. **A Phase 3 epic explicitly addresses ergonomics revisit** (e.g., a planned
   "ruact 1.0 ergonomics polish" epic).
   *Action:* this ADR is a required input to that epic.

Deviation from the chosen shape during Epic 8/9 implementation requires an ADR
addendum in this same file before the deviating PR is merged. The file is
append-only, never rewritten — so the history of the contract is preserved
even if the contract itself evolves.

## Decision log

### 2026-05-12 — Initial decision (Option C)

Chosen via the matrix in Task 2 of Story 8.0. Validated in
`/tmp/8-0-sandbox/` (Task 3): codegen + `tsc --noEmit` + typo-detection +
all 6 naming-bridge edge cases pass. Implementation surface enumerated; new
Story 8.0a created for the Vite plugin extension that emits the generated
module. No deviation from the spike's draft personal-opinion candidate, but
the matrix scoring is what locked the decision (not the gut feel).

### 2026-05-13 — Implementation (Story 8.0a)

Implementation surface rows #4, #5, #6, and #8 landed (plus #7's install-
generator extension, which was originally scoped to Story 8.1 but the
codegen scaffolding belongs alongside the rest of the 8.0a surface).
Ruby-side modules live under `gem/lib/ruact/server_functions/` (`NameBridge`,
`Registry`, `RegistryEntry`, `Snapshot`, `SnapshotWriter`, `Codegen`); the
Vite-plugin sidecar is `gem/vendor/javascript/vite-plugin-ruact/server-functions-codegen.mjs`
with a vitest harness alongside; the placeholder runtime at
`gem/vendor/javascript/ruact-server-functions-runtime/` ships an
intentionally-failing `_makeRef` so absent Story 8.1 wiring fails loudly at
call time. The JSON bridge lands at `tmp/cache/ruact/server-functions.json`,
the TS module at `app/javascript/.ruact/server-functions.ts`; both are
write-if-changed and gitignored. Cross-implementation parity (Ruby ↔ JS
codegens emit byte-identical output) is enforced by a vitest test that
shells out to `ruby -Ilib -rruact/server_functions/codegen -e ...` on a
literal fixture (`server-functions-codegen.test.mjs` → "Story 8.0a — Ruby
parity"). Empty registries are valid: 8.0a merges them as `[]` and Stories
8.1 / 9.1 populate them later. **No deviation from the locked contract**:
the import specifier remains `"ruact/server-functions-runtime"`; the
runtime alias is auto-registered by the Vite plugin's `config` hook against
the bundled placeholder package. See
Story 8.0a (workspace-only path `_bmad-output/implementation-artifacts/8-0a-vite-plugin-server-functions-codegen.md`)
for the full task breakdown and AC mapping.

### 2026-05-13 — Review-patch clarifications (Story 8.0 review pass)

The Story 8.0 code-review surfaced four patch findings that target stale
sketches in the ADR body. These clarifications are append-only — the body
sketches stay so the history of the contract is preserved, but the
following points override them where they disagree:

1. **Runtime/type contract (supersedes `## Decision` sketch lines 35–41).**
   The codegen emits **runtime** exports, not `export declare function`.
   Each entry is `export const <jsId>: <signature> = _makeRef("<rubySym>");`.
   The default signatures are conservative:
   - Actions: `(args?: Record<string, unknown>) => Promise<unknown>`
   - Queries: `() => Promise<unknown>`
   Per-function precision (e.g. `(args: { title: string }) => Promise<{ id: number }>`)
   is **not** generated from the Ruby DSL in Phase 2 — devs annotate manually
   if they want stronger types. Evolution to Ruby-side type metadata is
   reserved for a Phase 3 ADR addendum.

2. **`<form action={fn}>` semantics + FormData → Rails params.** React
   invokes a server reference passed to `<form action>` with a single
   `FormData` argument, not the `args: { title, body }` shape the body
   sketch implies. Story 8.1 owns the controller-side unwrapping
   (`FormData` → `params`); Story 8.2 owns the React-side path with
   `useActionState` and the error overlay. The conservative TS signature
   above (`(args?: Record<string, unknown>) => Promise<unknown>`) is wide
   enough to accept either the `FormData` invocation path or a hand-shaped
   POJO call from JS event handlers.

3. **Query transport is POST for everything (supersedes Implementation
   Surface row #3's `GET /__ruact/fn/:name?args=...`).** Both actions and
   queries POST to `/__ruact/fn/:name` with params in the request body —
   CSRF symmetric, no URL-replay, no intermediate caching. Trade-off
   accepted: queries lose HTTP-level cacheability, which is irrelevant for
   the internal RPC use case.

4. **`useQuery` shape (supersedes Implementation Surface row #9's "Suspense-
   only" wording).** Story 9.2's hook signature is
   `useQuery(reference, params?) → { data, loading, error }`. Suspense-aware
   queries (`use(promise)` + `<Suspense>` boundaries) are reserved for a
   Phase 3 ADR addendum once React 19's stable `use()` semantics + adoption
   signal land.

These clarifications were registered through Story 8.0's Review Findings
section (the four `[Review][Patch]` items referencing this file). The
Decision log is append-only — do not rewrite the body sketches above. If a
future story conflicts with these clarifications, add a new dated entry
here.
