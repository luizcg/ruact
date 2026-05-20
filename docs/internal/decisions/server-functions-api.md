# Server Functions API — React-side accessor shape

| Field | Value |
| --- | --- |
| Date | 2026-05-12 |
| Status | Accepted |
| Story | 8.0 — Server functions API design spike (planning artifact in the workspace monorepo at `_bmad-output/implementation-artifacts/8-0-server-functions-api-design-spike.md` — link omitted because this file ships in the published gem and the planning path is workspace-only) |
| Inspected | `react@19.2.0` (latest 19.x line; gem pins `react ^19.0.0` per Story 8.0 AC1's `react@19.0.0` floor), `next@15.4.0-canary`, `eslint-plugin-react-hooks@v6` (the v5 → v6 bump landed in 2026-05; AC1 specified `5.x` at story-creation time — the upgrade was a no-op for the rule-of-hooks behaviour the spike inspected), `vite@6.x`. **AC1 floor versions (`react@19.0.0`, `hooks@5.x`) were NOT separately re-inspected on a side-by-side basis;** the spike accepts the drift because the inspected behaviour (named-import resolution, rule-of-hooks compliance, `<form action>` semantics) is stable across the 19.0.0 ↔ 19.2.0 patch range and across the hooks v5 ↔ v6 release (per the React + plugin changelogs). Re-inspect if a future regression contradicts this assumption. |
| Locks | Stories 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 9.1, 9.2, 9.3, 9.4, 9.5 |
| Append-only | Yes — see "When to revisit" below |

## Context

Epic 8 (`ruact_action`) and Epic 9 (`ruact_query`) both need a way for a React
component to obtain a reference to a server-side function declared in a Rails
controller. Before this decision, Story 8.1's AC1 carried a placeholder for the
accessor surface (a deferred `server_actions[:create_post]`-style indexed
lookup with the call shape left undetermined) which was implicitly inherited by
every downstream story that needs the same reference.

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
//
// SUPERSEDED — see the 2026-05-16 + 2026-05-17 addenda below. The
// direct `useActionState(createPost, …)` shape does NOT typecheck
// against the codegen-emitted intersection signature under React 19's
// strict types. The canonical pattern is the explicit wrapper that
// forwards FormData to the action and shapes the resulting state.
import { createPost } from "@/.ruact/server-functions";
import { useActionState } from "react";

type PostState = { id: number; slug: string } | null;

async function postAction(_prev: PostState, formData: FormData): Promise<PostState> {
  return (await createPost(formData)) as PostState;
}

export function PostForm() {
  const [state, formAction, pending] = useActionState<PostState, FormData>(
    postAction,
    null,
  );
  return (
    <form action={formAction}>
      <input name="title" required />
      <textarea name="body" required />
      <button disabled={pending}>Create</button>
      {state && <p>Created post #{state.id} (slug: {state.slug})</p>}
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
| 3 | Server-function endpoint (single Rails route mounted by the gem; resolves by symbolic name from registries 1+2; no per-function entries in `routes.rb`) | Story 8.1 | `POST /__ruact/fn/:name` returns the action OR query result (POST-for-everything per 2026-05-13 Decision-log clarification #3 — supersedes the original GET/POST split sketched in this row); both reuse `Ruact::Controller` security/CSRF |
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
   The default signatures locked by Story 8.0a are:
   - Actions: `(args?: Record<string, unknown>) => Promise<unknown>`
   - Queries: `() => Promise<unknown>`
   These are the **direct-callable surface** — they describe how the ref
   appears to JS event handlers and to `await someRef(args)` call sites.
   Per-function precision (e.g. `(args: { title: string }) => Promise<{ id: number }>`)
   is **not** generated from the Ruby DSL in Phase 2 — devs annotate manually
   if they want stronger types. Evolution to Ruby-side type metadata is
   reserved for a Phase 3 ADR addendum.

2. **`<form action={fn}>` semantics + FormData → Rails params.** React
   invokes a server reference passed to `<form action>` with a single
   `FormData` argument, not the `args: { title, body }` shape the body
   sketch implies. Story 8.1 owns the controller-side unwrapping
   (`FormData` → `params`); Story 8.2 owns the React-side path with
   `useActionState` and the error overlay. **Open design decision deferred
   to Story 8.2:** the conservative `Record<string, unknown>` signature
   above is NOT structurally compatible with `FormData` in TypeScript —
   `<form action={createPost}>` will fail `tsc --noEmit` against the
   8.0a-emitted module as-is. Story 8.2 decides whether to (a) widen the
   codegen signature to `(args?: FormData | Record<string, unknown>) =>
   Promise<unknown>`, (b) export a sibling `.formAction` method on each
   ref typed `(formData: FormData) => Promise<unknown>`, or (c) require
   an explicit cast at the form's call site (`<form action={createPost
   as (fd: FormData) => Promise<unknown>}>`). 8.0a does not pre-commit
   to one — picking it here would lock the 8.2 design without the
   implementation context that disambiguates the trade-offs.

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

5. **Query params contract.** The hook accepts `useQuery(ref, params?)`
   while the 8.0a-emitted query ref's direct-callable signature is
   `() => Promise<unknown>` (no params on the callable surface). The two
   shapes coexist because **the hook does NOT invoke the ref as a
   function**; it reads the ref's `$$id` metadata and POSTs to
   `/__ruact/fn/:id` with `params` in the request body itself. The ref
   stays callable for parity with action refs (so devtools / tooling can
   treat both uniformly), but for queries the canonical access path is
   the hook, not the call. **Open design decision deferred to Story 9.2:**
   whether to (a) keep the no-args callable signature and have `useQuery`
   read `$$id` (current intent), (b) widen the callable to
   `(args?: Record<string, unknown>) => Promise<unknown>` and have
   `useQuery` invoke the ref directly (symmetric with actions, simpler
   runtime), or (c) introduce a typed `ServerRef<TParams, TResult>`
   metadata wrapper. 8.0a's codegen does not pre-commit; option (b)
   would require widening the emitted signature and is the most likely
   pick if symmetry wins, but 9.2's implementation context will decide.

These clarifications were registered through Story 8.0's Review Findings
section (the original four `[Review][Patch]` items + the 2026-05-13 Re-run
batch). The Decision log is append-only — do not rewrite the body sketches
above. If a future story conflicts with these clarifications, add a new
dated entry here.

### 2026-05-16 — Story 8.2 — codegen signature widening for `<form action>`

**Resolves:** the 2026-05-13 clarification #2 "Open design decision deferred
to Story 8.2" (FormData wire shape vs. action signature). Story 8.2 picks
**option (a) — widen the codegen-emitted action signature** to accept
either a `FormData` instance or a plain `Record<string, unknown>` argument.

**New action signature (Ruby + JS codegens in lockstep):**

```ts
export const createPost: (args?: FormData | Record<string, unknown>) => Promise<unknown> =
  _makeRef("create_post");
```

Query signatures are UNCHANGED — `() => Promise<unknown>`. The widening
applies to actions only because only actions are reachable via
`<form action={fn}>`; queries are read-only and reach the wire through
`useQuery` (Story 9.2), not a `<form>`.

**Why option (a) over (b) — sibling `.formAction` property:**

| Axis | (a) widen primary export | (b) sibling `.formAction` |
| --- | --- | --- |
| Call-site ceremony | None — `<form action={createPost}>` works | Two import shapes (`createPost.formAction` for forms; `createPost` for direct calls) |
| TS type surface | One signature, one accepted-types union | Two signatures must stay in sync per ref |
| Codegen complexity | Single ternary update | Per-ref dual export (doubles emitted line count) |
| Discoverability | Auto-complete suggests one symbol | Auto-complete branches on `.formAction` |
| Failure mode | Direct caller passing a plain object — narrowed at runtime by `instanceof FormData` | Passing `.formAction(plainObj)` typechecks but breaks at runtime |

The two TS-friendliness concerns option (b) was meant to mitigate — call
sites that pass plain objects shouldn't be widened to accept FormData —
were judged less load-bearing than the codegen + import + auto-complete
duplication cost of option (b). Direct callers retain the option of
explicit narrowing at the call site (`createPost(args as Record<string, unknown>)`)
if they want stricter typing inside their own code.

**Why not option (c) — explicit cast at the form site:**

Rejected as documented in the body. The whole point of the codegen layer
is to eliminate call-site ceremony; a project-wide `<form action={createPost as (fd: FormData) => Promise<void>}>`
convention defeats the design.

**`useActionState` integration:**

React 19's `useActionState(action, initialState)` calls the action as
`(prevState, formData) => state`. The widened single-arg signature does
NOT structurally match this two-arg shape. The runtime supports the
two-arg invocation (Story 8.2 AC3 — `_makeRef` accepts up to two
positional args and picks the FormData-typed candidate) so a wrapper is
not required at runtime, but TypeScript-strict consumers must wrap when
binding to `useActionState`:

```tsx
import { createPost } from "@/.ruact/server-functions";
import { useActionState } from "react";

export function PostForm() {
  const [state, formAction, pending] = useActionState(
    (_prevState, formData: FormData) => createPost(formData),
    null,
  );
  return (
    <form action={formAction}>
      <input name="title" />
      <button disabled={pending}>Create</button>
    </form>
  );
}
```

The wrap-per-call pattern is the documented contract. If a future React
release converges `<form action>` and `useActionState` on a single call
shape, this addendum should be revisited. The codegen is not generating
overload signatures for the two-arg shape in Phase 2; that's reserved
for a future iteration if call-site friction becomes load-bearing.

**Worked typecheck example (SUPERSEDED — see 2026-05-17 R1 addendum):**

> **2026-05-17 update:** the single-signature widening below does NOT
> actually let `<form action={createPost}>` typecheck — `Promise<unknown>`
> is invariant to `Promise<void>` so React 19's `(formData: FormData) =>
> void | Promise<void>` prop rejects the assignment. The 2026-05-17 R1
> addendum below refines to a TypeScript intersection that satisfies
> both call sites. The block below stays as historical record.

```tsx
// @/.ruact/server-functions emits (pre-R1 — STALE):
//   export const createPost: (args?: FormData | Record<string, unknown>) => Promise<unknown>
//
// 1. Direct call with a plain object (event handler) — STILL typechecks.
await createPost({ title: "Hi" });

// 2. Direct call with FormData — STILL typechecks.
const fd = new FormData();
fd.append("title", "Hi");
await createPost(fd);

// 3. <form action={createPost}> — REJECTED by tsc under strict mode
//    because Promise<unknown> is not assignable to Promise<void>. See
//    the 2026-05-17 R1 addendum below for the intersection refinement
//    that makes this site typecheck.
```

**`revalidate()` re-export (new in Story 8.2):**

The codegen now appends a fixed re-export AFTER all per-function exports
(also emitted when the registry is empty — the helper is unconditional):

```ts
export { revalidate } from "ruact/server-functions-runtime";
```

`revalidate(path?)` is implemented in the runtime; it reads
`globalThis.__ruact_revalidate` (published by `ruact-router.js#setupRouter`)
and triggers a Flight refetch of the supplied path or the current URL.
See the Story 8.2 file for the runtime API spec and the docs page for
end-user-facing documentation.

**Impact on Story 9.x:**

Open clarification #5 ("Query params contract") is unaffected. The
action-side widening here does NOT pre-commit Story 9.2 to one option
or the other for queries — query signatures remain narrow
(`() => Promise<unknown>`) until Story 9.2 picks (a) / (b) / (c) in its
own ADR addendum. The byte-parity tests track action and query branches
independently.

### 2026-05-17 — Story 8.2 code-review patch R1 — intersection-type refinement

**Resolves:** option (a) as documented in the 2026-05-16 addendum above
was wrong on the typecheck side. `(args?: FormData | Record<string, unknown>)
=> Promise<unknown>` is NOT structurally assignable to React 19's
`<form action>` prop type `(formData: FormData) => void | Promise<void>`
— Promise generics are invariant, so `Promise<unknown>` is not
assignable to `Promise<void>` even via the void-discard rule. Empirical
typecheck probe (`playgrounds/demo/spec/typecheck/form-action-direct.tsx`)
surfaced the error:

```
Type 'Promise<unknown>' is not assignable to type 'Promise<void>'.
  Type 'unknown' is not assignable to type 'void'.
```

The original 2026-05-16 decision shipped without a direct
`<form action={createPost}>` typecheck site in the playground (only the
`useActionState` wrapper pattern was tested, which sidesteps the issue
by routing through a closure with a `void` return). Code review caught
this gap and asked for a real `<form action={createPost}>` site that
typechecks WITHOUT a cast.

**Refined option (a) → (a′) — intersection type.** The codegen now emits:

```ts
export const createPost:
  ((args?: FormData | Record<string, unknown>) => Promise<unknown>)
  & ((formData: FormData) => Promise<void>) =
  _makeRef("create_post");
```

The intersection's first call signature satisfies direct callers (event
handlers, `useActionState` wrappers); the second satisfies React 19's
`<form action>` prop. Same export, both call sites typecheck. Runtime
behavior is unchanged — `_makeRef` always resolves with the JSON-decoded
value at runtime; the `Promise<void>` overload is a TYPE-ONLY surface,
selected only when React invokes the function from a `<form action>`
prop (where React discards the return value anyway).

**`_makeRef` declaration follows the intersection.** The `_makeRef`
return type in `gem/vendor/javascript/ruact-server-functions-runtime/index.d.ts`
is now also an intersection so the codegen's emitted annotation is
satisfied by the RHS without a cast. Declaration-only; the JS
implementation is untouched.

**Why not function overloads?** TypeScript supports declaration-style
function overloads (`function foo(x): Y; function foo(): Z;`) but NOT
on `export const` bindings. Intersection of two call signatures on a
type literal is the idiomatic TS equivalent and is what every
production-grade overloaded-callable library (Lodash, Ramda, etc.) emits
under its types.

**Reserved-name protection (review patch R2, same date).** With
`revalidate` now unconditionally re-exported by the codegen from BOTH
the empty-registry and populated-registry branches, a controller
declaring `ruact_action :revalidate` would emit a duplicate `export
const revalidate` next to the helper re-export and crash at module
load. `NameBridge.RESERVED_BY_RUACT = %w[revalidate].to_set` rejects
the symbol at controller-class load time with a clear error message.
Escape hatches: `:revalidate_post` (suffix) and `:_revalidate`
(leading underscore) both pass.

**`<form action={...}>` empirical validation steps (replicable):**

1. `cd playgrounds/demo && npx tsc --noEmit -p tsconfig.json`
2. The probe at `spec/typecheck/form-action-direct.tsx` declares three
   patterns:
   - `<form action={demoEcho}>` directly (no cast, no wrapper)
   - `await demoEcho({ message: "Hi" })` direct call returning `unknown`
   - `useActionState<unknown, FormData>((_prev, fd) => demoEcho(fd), null)`
3. All three patterns typecheck under `strict: true`. If any single
   pattern fails, the codegen's intersection emission has regressed.

The 2026-05-16 addendum body (option (a) narrative + worked example)
stays as the historical record — replace any direct `(args?: ...)`
quotation in future stories with the intersection form. The
`useActionState` wrapper pattern documented in 2026-05-16 remains the
canonical approach for `useActionState` because the intersection's
single-arg signature is NOT structurally compatible with the two-arg
shape React's hook expects.

### 2026-05-17 — Story 8.3 — standalone host execution context

**Status:** Resolved (Story 8.3 landed standalone host shape + dispatcher branch + CSRF policy + `current_user_resolver` config).

**Scope:** Closes 2026-05-13 clarification #4 ("Standalone host execution context — deferred to Story 8.3"). Captures (a) the `Ruact::ServerAction` extend pattern + why it was chosen over `class << self`-style or `include`-style; (b) the `StandaloneContext` attribute set + why `render`/`redirect_to`/`head` are excluded; (c) the `current_user_resolver` lambda contract; (d) why the registry's `controller` field name was kept despite the semantic widening; (e) the CSRF policy migration to the gem side for the standalone branch.

**No code-shape changes to the locked accessor.** `import { createPost } from "@/.ruact/server-functions"` still works identically; the codegen output is byte-identical regardless of host shape. The 2026-05-16/17 intersection signature still applies. The only new piece on the Ruby side is `Ruact::ServerAction` (an extend module) + `StandaloneDispatcher` (a branch inside `EndpointController#dispatch_action`).

**(a) Why `extend Ruact::ServerAction`?**

```ruby
module CreatePost
  extend Ruact::ServerAction

  ruact_action :create_post do |params|
    ...
  end
end
```

Considered alternatives:

1. `class << self; extend Ruact::ServerAction; ...; end` — verbose, idiomatically used for adding class methods to a class, not for marking a top-level module as a server-action host.
2. `include Ruact::ServerAction` — would put `ruact_action` on instances; standalone modules don't have instances (no `.new` semantics, the block runs against a per-request `StandaloneContext`). Confusing.
3. `Ruact::ServerAction.declare(MyModule) { ... }` — declarative API outside the module body. Loses the parallel with `Ruact::Controller`'s `include`-then-`ruact_action`-in-class-body shape that controllers use.
4. **Chosen:** `extend Ruact::ServerAction` puts the `ruact_action` macro on the module's singleton class. The DSL inside the module body reads naturally; the `ruact_action` registration call sees `self == TheModule` and registers `controller: self`.

The `extend` choice also lets the `EndpointController.standalone_host?(host)` predicate use a positive check: `host.is_a?(Module) && !host.is_a?(Class) && host.singleton_class.include?(Ruact::ServerAction)`. The check is robust against a host that happens to be `extend`ed by both `Ruact::ServerAction` AND some other module — order doesn't matter; what matters is that `Ruact::ServerAction` is in the singleton ancestry.

**(b) `StandaloneContext` attribute set:**

Exposed: `params`, `current_user` (resolver-backed, memoized), `session`, `cookies`, `headers`, `request`.

Excluded — `render` / `redirect_to` / `head` raise `NoMethodError` with a documented hint. Reasoning: those are controller-context methods. A dev who writes `render(json: ..., status: ...)` inside a standalone block has a wrong mental model — the standalone path's response contract is "return a value, or raise `Ruact::ActionError(status:, body:)`". Letting `render` partially work (e.g. write to `response`) would create a second response-shape source-of-truth inside the dispatcher; the loud `NoMethodError` makes the contract unambiguous. The error message names the alternatives so the fix is immediate.

`StandaloneContext` is NOT a `Data.define` — it carries lazy/memoized state (`current_user`'s resolution flag, the read-tracking flag for the dev-only "unread current_user" warning) that doesn't fit Data's immutability contract.

**(c) `current_user_resolver` lambda contract:**

- **Argument:** receives `request.env` (Hash). Documented contract — the lambda MUST NOT receive the full `ActionDispatch::Request` (would let the dev mutate request state in ways the dispatcher can't track).
- **Return:** the authenticated user (any Ruby object) or `nil`.
- **Lookup precedence:** (1) `request.env['ruact.current_user']` if the key is PRESENT (even if `nil`); (2) the configured lambda. The env-key path is for hosts that set the current user via upstream Rack middleware (Devise's Warden uses `env['warden'].user`; the resolver can read it OR the dev can set `env['ruact.current_user']` from a custom middleware to bypass the resolver entirely).
- **Memoization:** the `StandaloneContext` caches the first `current_user` call for the duration of one dispatch; repeated reads don't re-invoke the resolver. Documented in YARD.
- **Failure mode:** when neither path produces a value AND the block actually reads `current_user`, raises `Ruact::CurrentUserNotConfiguredError` at dispatch time (NOT at boot — only fires for blocks that actually depend on `current_user`). The error message names both worked examples (Devise + hand-rolled) so the dev fixes the configuration without leaving the stack trace.

**(d) Registry `controller` field name retained:**

`Ruact::ServerFunctions::RegistryEntry.controller` was `controller:` (a Class) pre-Story-8.3. Story 8.3 widens the SEMANTIC: the field now stores either a Class (controller host) or a Module (standalone host). The FIELD NAME stays `:controller` for two reasons:

1. **Back-compat with existing specs / fixtures.** `RegistryEntry`'s `Data.define(:ruby_symbol, :js_identifier, :kind, :controller, :block)` is referenced by name in `Snapshot.functions_payload`, `Snapshot.read_for_codegen`, and dozens of spec assertions. Renaming would be a churn-heavy mechanical migration with no behavioural benefit.
2. **Snapshot output is unchanged.** The JSON snapshot reads `js_identifier` / `ruby_symbol` / `kind` from each entry; it does NOT serialize `controller`. The codegen output is byte-identical regardless of host shape — so the field name choice is invisible outside the gem's own code.

Future stories that need to disambiguate may add an explicit `host_kind: :class | :module` field; that's an additive change, not a rename. For now, "host" is the semantic concept and `controller` is the field that stores it.

**(e) CSRF policy migration to the gem side for the standalone branch:**

Story 8.1 deliberately skipped `verify_authenticity_token` on `EndpointController` (the gem-mounted controller backing `POST /__ruact/fn/:name`) precisely because the host controller's `protect_from_forgery` would re-enforce it inside `host_class.dispatch`. For standalone actions there is no host chain. The dispatcher must enforce CSRF itself OR explicitly opt out per-app.

**Decision:** enforce by default. The gem's `EndpointController` carries a `protect_from_forgery with: :exception, if: :dispatching_standalone?` declaration. This installs:

- The forgery_protection_strategy = :exception (idiomatic Rails wiring; using a bare `before_action :verify_authenticity_token` would crash because the strategy class is otherwise nil).
- A conditional `before_action :verify_authenticity_token` that fires only when `dispatching_standalone?` returns true (the resolved entry's host is a Module extending `Ruact::ServerAction`).

The condition is resolved EARLY via a `prepend_before_action :resolve_ruact_entry!` that runs before the conditional CSRF callback. The controller-action branch keeps `skip_forgery_protection`-equivalent behavior (the `if:` condition is false, the callback skips, and the host controller's own `protect_from_forgery` handles CSRF as before).

Rails' `verified_request?` short-circuits when `allow_forgery_protection = false` globally, so API-mode hosts accept standalone POSTs without a token — same observable behavior as controller-hosted actions in API mode.

**Why not handle CSRF inside `StandaloneDispatcher`?** Doing it as a Rails callback lets the framework's existing instrumentation, exception classes, and logging all participate. `ActionController::InvalidAuthenticityToken` is the canonical exception class; raising it inline from a custom dispatcher would lose that. The conditional `before_action` is the smallest possible change to the gem's request-cycle wiring that preserves user-visible parity with the controller-hosted matrix.

**Append-only invariant preserved.** No code-shape changes to the locked accessor. The Story 8.0 ADR's "single accessor mechanism" decision is intact; this addendum adds a second host shape that funnels through the same accessor.

### 2026-05-18 — Story 8.4 — structured server-action error payload

**Context.** Story 8.1 (controller-hosted dispatch), Story 8.2 (`<form action={fn}>` runtime), and Story 8.3 (standalone dispatcher) all let a raised exception bubble back to Rails' default `ActionDispatch::ShowExceptions` middleware on the unhappy path — producing an HTML error page that the runtime received as `RuactActionError({ status, body: "<html>..." })`. Story 8.4 closes NFR30 by introducing a structured wire body so the dev overlay can render a meaningful diagnostic view AND the production React component can render its own UI from the same shape.

**Decision.** Add an OUTERMOST `rescue_from StandardError` (and explicit `rescue_from ActionController::InvalidAuthenticityToken`) on `EndpointController` that renders a JSON Hash with a `_ruact_server_action_error: true` discriminator. The Story 8.0 accessor lock is UNTOUCHED; the new wire surface lives entirely in the `body` field of the existing `RuactActionError`, which the runtime treats as opaque JSON.

**(a) Wire shape — backward-compatible body refinement.**

| Field | Dev mode | Prod mode |
| --- | --- | --- |
| `_ruact_server_action_error` (bool) | ✅ | ✅ |
| `action_name` (string) | ✅ | ✅ |
| `error_class` (string) | ✅ | ✅ |
| `message` (string) | ✅ | ✅ |
| `app_frames` (array of string) | ✅ | absent (key not present) |
| `gem_frames` (array of string) | ✅ | absent |
| `suggestion` (string \| null) | ✅ | absent |
| `validation_errors` (array of string) | only for `ActiveRecord::RecordInvalid` | absent |

The discriminator field (`_ruact_server_action_error: true`) is the load-bearing piece: the React overlay uses it to decide whether to render the structured branch or fall back to the existing `<pre>{error.message}</pre>` rendering. Existing callers that read `body.error` (the Story 8.3 malformed-JSON case) or treat the body as opaque keep working — no field rename, no key removal.

The dev/prod gate is `Ruact.config.dev_error_payload_enabled`, default `nil` (the endpoint resolves nil to `Rails.env.development? || Rails.env.test?`). Setting `c.dev_error_payload_enabled = false` inside `Ruact.configure` forces production-shape errors locally — useful for verifying what the React component receives in prod.

**(b) Host `rescue_from` precedence rule.**

The endpoint's `rescue_from StandardError` is the OUTERMOST catch — it only fires for exceptions the host did NOT handle. A host that declares `rescue_from ActiveRecord::RecordInvalid, with: :handle_record_invalid` continues to render its own response unchanged. The structured payload is the FALLBACK, not the override. This invariant is what lets hosts opt into the gem's diagnostics for unhandled classes while keeping their own error UI for owned domain errors.

**(c) Suggestion table is a gem-published surface.**

`Ruact::ServerFunctions::ErrorSuggestion::SUGGESTIONS` is a frozen Hash keyed by error-class-name strings. Today it carries the two NFR30 mandated mappings (`ActiveRecord::RecordInvalid`, `ActionController::InvalidAuthenticityToken`). The table is NOT host-configurable for now: extending it requires an ADR amendment + a constant update. Rationale: making it runtime-configurable would require a Configuration knob that lives in the seal contract (Story 7.3), expanding the public surface for a feature without a cross-host demand signal. A future story that adds (e.g.) `ActiveRecord::StaleObjectError` opens this paragraph.

**(d) Status code mapping.**

| Exception | HTTP status |
| --- | --- |
| `ActiveRecord::RecordInvalid` | `422` |
| `ActionController::InvalidAuthenticityToken` | `403` |
| any other `StandardError` | `500` |

**Breaking change vs Story 8.3 R2:** standalone CSRF rejections previously returned `422` (Rails' default `InvalidAuthenticityToken` → 422 mapping in `ShowExceptions`); they now return `403`. The change is intentional — 403 Forbidden is semantically the right code for "you are not authorised to make this request" (CSRF mismatch == missing/invalid credentials), while 422 is reserved for "the request was syntactically valid but the entity could not be processed" (validation errors). The Story 8.3 R2 spec assertion is updated in lockstep; production hosts that branched on the 422 status for CSRF-specific handling MUST migrate to either the 403 status or the `error_class === "ActionController::InvalidAuthenticityToken"` field on the structured body.

**(e) `BacktraceCleaner.split` semantics.**

`Ruact::ServerFunctions::BacktraceCleaner.split(error.backtrace)` returns `{ app: [...], gem: [...] }` by classifying each frame on a prefix match against `Ruact.gem_path` (a memoised gem-root accessor added to `lib/ruact.rb`). The implementation is ~10 LoC with zero ActiveSupport dependency — `ActiveSupport::BacktraceCleaner`'s silencer/filter API was deemed heavyweight for the single-purpose need; the lean implementation also loads cleanly in AR-less specs. The app/gem split is what powers the overlay's "App backtrace shown by default, gem frames behind a toggle" UX (NFR30). Frame caps (`MAX_FRAMES_PER_BUCKET = 25`) keep the wire payload bounded; the full backtrace is in `Rails.logger.error` regardless.

**(f) Pure-function ErrorPayload module.**

`Ruact::ServerFunctions::ErrorPayload.build(action_name:, error:, mode:)` has zero I/O — no `Rails.env` read, no `Ruact.config` read. The caller (`EndpointController#__ruact_render_action_error`) resolves `mode` and passes it in. That keeps the module trivially unit-testable without stubbing Rails env, and isolates "what the wire shape is" from "what env are we in". Same design choice as the standalone dispatcher's `Result` value object (Story 8.3).

**Append-only invariant preserved.** The Story 8.0 accessor lock is untouched. The `RuactActionError` constructor signature on the runtime side is untouched (still `{ name, status, body, response }`). The new wire surface is entirely a refinement of what `body` can contain, gated by a discriminator that pre-existing callers do not read.

