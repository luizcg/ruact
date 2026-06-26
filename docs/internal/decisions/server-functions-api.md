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

### 2026-05-23 — Story 8.5 — file uploads + `max_upload_bytes` guard

**Context.** Story 8.1 (controller-hosted dispatch) and Story 8.3 (standalone dispatcher) both already routed `multipart/form-data` bodies through `request.request_parameters`; React 19's `<form action={fn}>` auto-FormData (Story 8.2) already includes `<input type="file">` entries in the FormData; the runtime's `pickWirePayload` / `buildFetchInit` (Story 8.1) already POST FormData as `multipart/form-data` with the browser-set boundary. So the "wire path for file uploads" was, on paper, already in place. Story 8.5 closes FR84 by (a) pinning the round-trip behavior with explicit gem-side specs so a future refactor can't silently regress UploadedFile delivery, and (b) introducing a controller-boundary size guard so an oversized request gets the Story 8.4 structured 413 instead of timing out at the multipart parser.

**Decision.**

**(a) No accessor surface change.** The Story 8.0 ADR lock is intact. The React side continues to import `{ createPost } from "@/.ruact/server-functions"` and pass FormData; nothing new is exported. The runtime is unmodified — `pickWirePayload` already routes FormData to the multipart branch, `buildFetchInit` already lets the browser set the boundary header. This story's delta lives ENTIRELY on the Ruby side.

**(b) New `Ruact.config.max_upload_bytes` attribute.** Integer (bytes). Default `10 * 1024 * 1024` (10 MB). Set to `nil` to disable the gem-side guard (the host's reverse proxy / middleware then owns the operational cap). Carries the standard `Ruact::Configuration` seal contract (Story 7.3) — direct post-boot mutation raises `Ruact::ConfigurationError`.

**(c) New `Ruact::UploadTooLargeError` exception class.** Inherits from `Ruact::Error` so the Story 8.4 `rescue_from StandardError` chain on `EndpointController` catches it cleanly. Carries `received_bytes` and `limit_bytes` attr_readers so the structured payload can surface both numbers without re-parsing the message string. The class lives in the gem's public namespace (`lib/ruact/errors.rb` next to `ActionError`/`CurrentUserNotConfiguredError`) because docs reference it by name and the `ErrorSuggestion::SUGGESTIONS` table gets a new keyed entry.

**(d) Pre-parse `Content-Length` guard.** `EndpointController` gains `prepend_before_action :__ruact_enforce_upload_limit!` ABOVE the existing `:resolve_ruact_entry!` callback (so the guard fires FIRST in the chain). The check uses `request.content_length` — NOT body inspection — so it fires BEFORE Rack's multipart parser runs. That's the cheapest possible reject: a 100 MB upload's headers are parsed and we 413 it without touching the body. Short-circuits: `max_upload_bytes = nil`; content type not `multipart/form-data` / `application/x-www-form-urlencoded`; `Content-Length` absent (chunked transfer). The dispatch-independence of the guard is why it lives as a callback, not inside `dispatch_action`.

**(e) Why `Content-Length`, not body inspection?** Body inspection (e.g., `Rack::Request#tempfile_for_each_part`) would defeat the purpose of "reject before parsing" — the parser would already be buffering bytes to disk. `Content-Length` is the cheapest pre-parse reject; the cost is two carve-outs: (1) chunked-transfer clients bypass the guard because `Content-Length` is absent (rare for browsers, common for some HTTP libraries), and (2) the reported `received_bytes` is the wire Content-Length including multipart boundary overhead, NOT the parsed file size. A 9.5 MB file uploaded via multipart reports `received_bytes ≈ 9.7 MB`. The 10 MB default has headroom for the boundary overhead in the common case; docs call out the edge.

**(f) Operational cap belongs to the reverse proxy.** `max_upload_bytes` is a controller-level "fail fast at the boundary" knob, NOT a memory-safety guarantee. Rack's multipart parser will still buffer bodies up to its own limits before the controller callback could possibly run on a request without a `Content-Length` header. The docs page (`website/docs/api/server-actions.md` "File uploads" section) explicitly recommends `client_max_body_size` in nginx / `LimitRequestBody` in Apache for the operational cap, plus Active Storage Direct Upload / presigned S3 URLs for large files. The `max_upload_bytes` knob is the "polite reject for the common case", not the load-balancer.

**(g) Status code mapping extends Story 8.4's table.**

| Exception | HTTP status |
| --- | --- |
| `ActiveRecord::RecordInvalid` | `422` |
| `ActionController::InvalidAuthenticityToken` | `403` |
| `Ruact::UploadTooLargeError` | `413` (new in 8.5) |
| any other `StandardError` | `500` |

**(h) `ErrorPayload.build` gains a dev-only `upload_limit` block.** When `error.class.name == "Ruact::UploadTooLargeError"` AND `mode == :development`, the payload includes `upload_limit: { received_bytes: <int>, limit_bytes: <int> }` alongside the four baseline keys and the existing dev-mode fields (`app_frames`, `gem_frames`, `suggestion`). The production-mode payload is unchanged (still the four baseline keys only) — `upload_limit` is gated the same way as `app_frames` / `suggestion`. The `_ruact_server_action_error: true` discriminator is preserved.

**(i) `ErrorSuggestion::SUGGESTIONS` gains one entry.** `"Ruact::UploadTooLargeError" => "Upload exceeded the configured size limit. Increase Ruact.config.max_upload_bytes or use Active Storage Direct Upload / a presigned S3 URL for large files."` — the table is frozen at class-load time; runtime mutation continues to be unsupported per the Story 8.4 surface decision.

**(j) Guard fires BEFORE CSRF (standalone branch).** Because `prepend_before_action :__ruact_enforce_upload_limit!` is added LAST among the prepend_before_action calls in the source, it lands at the FRONT of the chain — running before `:resolve_ruact_entry!` AND before the conditional `verify_authenticity_token` callback. An oversized standalone request without a CSRF token returns 413, not 403. This is correct (cheaper reject; the attacker learns nothing about CSRF state from a 413) and pinned by `endpoint_controller_upload_spec.rb`'s Pitfall #4 example.

**(k) `__ruact_render_action_error` action_name fallback.** Because the upload guard runs BEFORE `:resolve_ruact_entry!`, `@__ruact_name_sym` is nil when a 413 fires. The renderer falls back to `request.path_parameters[:name]` so the structured payload's `action_name` still carries the URL-routed name (`"upload_post"`) instead of `"(unknown)"`.

**Append-only invariant preserved.** The Story 8.0 accessor lock is untouched. The runtime is unchanged (no new exports, no signature changes to `RuactActionError`, no new helper on `pickWirePayload` / `buildFetchInit`). The new wire surface is a refinement of what the existing `body` field can carry (one new optional dev-only key, `upload_limit`), gated by a discriminator pre-existing callers do not read.

**Playground demo carve-out.** The playground demo + Active Storage end-to-end exercise (epic AC2/AC6) are deferred to Story 8.5a — a dedicated `rails new`-generated playground at `playgrounds/epic-8-server-actions/`. The existing `playgrounds/demo/` has no ActiveRecord / SQLite / `config/database.yml`, and retrofitting the DB layer would obscure this story's actual delta. The gem-side request-cycle specs in `endpoint_controller_upload_spec.rb` (controller-hosted + standalone branches, AC1/AC3/AC4 + Pitfalls #1/#4/#12) provide the empirical proof for the gem boundary; the Active Storage attach round-trip lives in 8.5a.

### 2026-06-02 — Story 9-0 — Server Functions API redesign (route-driven) — supersedes the authoring + dispatch layers

**Trigger.** Correct Course run, 2026-06-02 (workspace artifact:
`_bmad-output/planning-artifacts/sprint-change-proposal-2026-06-02.md`). Story 9.1's
seven re-run review rounds — nearly all spent on cross-registry collision /
rollback / atomicity machinery — exposed that the block-DSL + synthetic-endpoint
substrate fights itself, and that `POST /__ruact/fn/:name` is a parallel routing
mechanism that contradicts the project thesis ("Rails routes are the single
source of truth"). Approved scope: **Major**. Epic 9 was repurposed as "Server
Functions (route-driven redesign)" (Scheme A — Epic 8 stays `done` as the
historical record of the v1 design; no downstream epic renumber). This addendum
is the Story 9-0 re-spike deliverable: it locks the v2 contract the redesigned
Epic 9 stories implement. Per the append-only rule, the superseded sections
below remain in the body for history.

**What survives (reaffirmed).**

- **Option C accessor — UNCHANGED.** Named imports from the generated module:
  `import { createPost, categories } from "@/.ruact/server-functions"`. The
  entire React-side import surface is untouched; everything in this addendum is
  about the Ruby authoring layer and the wire dispatch layer.
- **NameBridge** snake_case → camelCase rule + reserved-word guards — now applied
  to route-derived action names and query-method names instead of DSL symbols.
- **`useQuery(reference, params?) → { data, loading, error }`** (the Story 9.2
  shape from clarification #4) — consumes query-class references unchanged.
- **Salvaged subsystems** (migrate, do not rewrite): structured error payload +
  `ErrorSuggestion` table + `BacktraceCleaner` (Story 8.4); `max_upload_bytes`
  guard + `UploadTooLargeError` + 413 mapping (Story 8.5); the runtime fetch
  core (`_makeRef`'s FormData branching, CSRF meta-tag injection, text-first
  parsing, `RuactActionError`, `redirect: "error"` handling); `revalidate()`;
  serialization via `ruact_props` / `Ruact::Serializable`.

**What is superseded.**

- The `ruact_action` / `ruact_query` controller block-DSL macros (Stories 8.1 /
  9.1). Implementation Surface row #2 is void.
- The gem-mounted synthetic endpoint `POST /__ruact/fn/:name` (Implementation
  Surface row #3) AND the 2026-05-13 clarification #3 ("POST for everything").
  Mutations ride real REST routes; queries ride explicitly mounted GET routes
  (Decision 2). Queries regain HTTP GET semantics; reads no longer carry CSRF.
- The dual `Ruact.action_registry` / `Ruact.query_registry` and the
  cross-registry collision detector (`Snapshot.functions_payload`'s
  cross-registry branch, `__ruact_check_cross_dsl_clobber!`). Single-namespace
  validation moves into codegen, over the route table + query classes.
- **Standalone actions (Story 8.3, PRD FR63) — DROPPED from the v0.1.0 MVP.**
  Mutations belong to controllers; the standalone module host loses its
  rationale (its `current_user_resolver` pattern is also superseded by
  Decision 2's host-controller dispatch). Revisit post-signal (≥ 1 external
  issue requesting it). `Ruact::ServerAction`, `StandaloneDispatcher`,
  `StandaloneContext`, `current_user_resolver` are removed with it.

**Decision 1 — Mutations are normal controller actions.**

```ruby
class PostsController < ApplicationController
  include Ruact::Server          # the ONLY marker — no per-action declaration

  def new;  end                  # GET → page (implicit render via default_render)
  def show; @post = Post.find(params[:id]); end   # GET → page

  def create                     # non-GET routed action → callable server function
    @post = Post.create!(title: params[:title])
    @post.cover.attach(params[:cover]) if params[:cover].present?
    redirect_to @post
  end
end
```

- **Verb rule, no per-action marker:** on a controller that includes
  `Ruact::Server`, every **non-GET routed** action (POST/PATCH/PUT/DELETE,
  RESTful or custom member/collection routes) is exposed as a callable server
  function in codegen. GET routes are pages, reached by navigation — never
  emitted as callables.
- **`routes.rb` carries nothing ruact-specific for mutations.** Standard
  `resources :posts`. The Rails route table is the single source of truth.
- **Data flows via instance variables** — standard Rails. No `render json:`
  required, no `respond_to`, no block params.
- **The full host controller chain runs natively** (`before_action`,
  `rescue_from`, Pundit, `protect_from_forgery`) because these ARE controller
  actions. The Story 8.4 structured-error rendering and the Story 8.5 upload
  guard migrate from `EndpointController` into the `Ruact::Server` concern
  (`rescue_from` + `prepend_before_action`), preserving the wire contract
  (discriminator, status table, dev/prod payload split) byte-for-byte where
  possible.

**Decision 2 — Queries are classes under `app/queries/`, mounted explicitly, dispatched through a host controller.**

```ruby
# app/queries/catalog_query.rb
class CatalogQuery < ApplicationQuery        # ApplicationQuery < Ruact::Query
  def categories
    Category.active.pluck(:id, :name).map { |id, name| { value: id, label: name } }
  end

  def my_categories
    current_user.categories.pluck(:id, :name)
  end

  def search_users(q:, limit: 10)
    User.search(q).limit(limit)
  end
end
```

```ruby
# config/routes.rb — explicit mount (decision A = option b)
Rails.application.routes.draw do
  ruact_queries CatalogQuery                 # draws named GET routes, visible in `rails routes`
  resources :posts
end
```

- **Authoring:** plain public `def` methods on a `Ruact::Query` subclass — each
  method is one query. No block DSL, no mandatory unused params. Method keyword
  args are the query's parameters (consumed by the Story 9.3 sanitization
  contract).
- **Transport (A = b):** the `ruact_queries` router macro draws one **named GET
  route per public method** (default path scheme `GET /q/<jsIdentifier>`,
  prefix configurable) pointing at the gem's internal dispatch controller. The
  route table knows every query — thesis-aligned, no hidden endpoint.
- **Security context (B = ii):** the internal dispatch controller **inherits
  from the host's parent controller** (`Ruact.config.query_parent_controller`,
  default `"ApplicationController"` — the Devise `parent_controller` pattern).
  The request therefore runs the host's REAL callback chain
  (`authenticate_user!`, tenant scoping, Pundit) **before** the gem
  instantiates the query class and injects the context. The dev never sees this
  controller. This replaces old Story 9.4's controller-hosted-block contract
  AND Story 8.3's resolver-lambda pattern.
- **Context injection:** `Ruact::Query#initialize(context)` receives a context
  object exposing `current_user`, `params`, `request`, `session` — delegating
  to the dispatching controller instance. Queries are unit-testable as
  `CatalogQuery.new(fake_context).categories` with no Rails boot.
- **Per-request instance** (like controllers) → thread-safe (NFR8).

**Decision 3 — Dual-bucket response negotiation on the same action.**

One mutation action serves both interaction models, discriminated by how it was
called, reading the same instance variables:

| Bucket | Caller | `Accept` | Response |
| --- | --- | --- | --- |
| 1 — form / navigation | `<form>` submit, link navigation | `text/x-component` | Flight re-render or Flight redirect — **the existing Story 3.3 / 3.4 mechanism, unchanged** |
| 2 — imperative | `await createPost(formData)` via the generated ref | `application/json` | Exposed ivars serialized (Decision 5); `redirect_to` surfaces as `{ "$redirect": "<path>" }` for the caller to follow (precedent: Story 8.1's `redirect: "error"` runtime handling) |

Bucket 1 requires no new code — it is Phase 1 behavior. Bucket 2 is the genuine
Epic-8 delta and is what the generated refs target (real route + verb instead of
`/__ruact/fn/:name`).

**Decision 4 — Codegen reads the route table + query classes.**

- **Sources:** (a) `Rails.application.routes` filtered to non-GET routes whose
  controller includes `Ruact::Server`; (b) `Ruact::Query` subclasses under
  `app/queries/` (their public instance methods). The JSON bridge →
  `server-functions.ts` pipeline (Story 8.0a) survives with its sources swapped;
  write-if-changed and `config.to_prepare` regeneration are retained.
- **Naming (decision D):** action names derive from the route —
  `posts#create` → `createPost` (action verb + singularized resource;
  collection routes keep the resource plural where natural, e.g.
  `posts#publish_all` → `publishAllPosts`). Query names derive from the method
  name via NameBridge (`search_users` → `searchUsers`). Any collision in the
  merged JS namespace fails codegen loudly at boot (same failure mode as
  today's collision detector) and requires an explicit per-action/per-method
  rename via an override macro (exact macro name owned by the implementing
  story; the override is the escape hatch, not the default).
- **Signatures:** actions keep the Story 8.2 intersection type (FormData +
  args-object callable); queries keep `() => Promise<unknown>` /
  `(params) => Promise<unknown>`. Per-function return-type precision remains a
  Phase 3 candidate (unchanged from clarification #1).

**Decision 5 — Bucket-2 return payload (decision C).**

The imperative response body serializes **all exposed instance variables**
(everything not `@_`-prefixed, the same filter Rails uses for view assigns) as
a JSON object keyed by ivar name without the `@` (`{ "post": {...} }`),
each value serialized through the existing `ruact_props` /
`Ruact::Serializable` / `strict_serialization` rules. No single-ivar magic
unwrap — predictable over clever. An action that sets no ivars and does not
redirect returns `204 No Content` → the ref resolves `null` (matching the
runtime's existing empty-body contract from Story 8.1).

**Open items the implementing stories must resolve (not contract-level).**

1. Per-query callback opt-out (e.g. a public query on an app whose
   `ApplicationController` forces `authenticate_user!`) — sketch: class-level
   macro on `Ruact::Query` forwarded to the internal controller's
   `skip_before_action`. Owned by the query-dispatch story.
2. Query route path scheme + prefix configuration default (`/q/...` proposed).
3. The exact rename-override macro name for JS-identifier collisions
   (Decision 4).
4. Whether `include Ruact::Server` is implied by `ruact_render` usage or always
   explicit (explicit proposed — one line, no magic).

**Append-only invariant preserved.** The Option C accessor lock (named imports
from `app/javascript/.ruact/server-functions.ts`) is untouched — React code
written against Epics 8/9 imports does not change its import statements. The
superseded body sections and prior decision-log entries remain verbatim above;
where they conflict with this addendum, this addendum governs. Deviations
during the redesigned Epic 9 implementation require a further dated addendum
here before merge.


### 2026-06-05 — Story 9.1 — `Ruact::Server` concern lands (Phase A salvage transplant) — in-story decisions

**Scope.** Implements the Phase A salvage transplant from the 2026-06-02
addendum: the `Ruact::Server` concern (`gem/lib/ruact/server.rb`, loaded by
the Railtie's `ruact.load_controller` initializer alongside
`Ruact::Controller`) becomes the v2 home of the Story 8.4 structured-error
chain and the Story 8.5 upload guard, installed on the host controller's own
callback chain. The v1 `EndpointController` stays alive untouched as the
strangler-fig safety net (removed in Story 9.9). At this story the concern is
a pure marker + salvage host: it registers nothing, emits nothing to codegen
(Story 9.3), and performs no dual-bucket response negotiation (Story 9.2).

**Shared core.** Both homes include
`Ruact::ServerFunctions::ErrorRendering` — the extracted 8.4/8.5 bodies
(structured renderer, status mapping, payload-mode resolution, logging,
upload guard). Behavioral differences are expressed ONLY through three
private hooks (`__ruact_error_action_name`,
`__ruact_render_structured_error?`, `__ruact_upload_guard_applicable?`),
whose defaults preserve v1 endpoint semantics. The wire contract is therefore
byte-for-byte identical across both homes by construction. Story 9.9 deletes
the endpoint home; the module survives as the concern's implementation.

**Decisions taken in this story (delegated by the epic / 2026-06-02 addendum):**

1. **Predicate name + semantics (AC2).** The function-call discrimination
   point is the private helper **`Ruact::Server#__ruact_function_call?`**:
   true iff the raw `Accept` request header contains `application/json`
   (the exact shape the 8.1 runtime sends on every `_makeRef` fetch).
   Deliberately NOT `request.format` — Rails' format negotiation is
   influenced by path extensions (`/posts.json`) and `params[:format]`,
   neither of which may flip the bucket. Story 9.2 MUST reuse this helper
   verbatim as the dual-bucket discriminator; it lives in one place only.
2. **D1 — structured-render gating.** The concern's rescue handler renders
   the structured payload only when `__ruact_function_call?` is true;
   otherwise it re-raises, so non-function-call requests keep stock Rails
   error behavior (AC1 byte-for-byte). ONE documented exception:
   `Ruact::UploadTooLargeError` renders the structured 413 for EVERY request
   shape — the guard only exists on requests that opted into the concern,
   and a meaningful 413 beats a re-raised 500 for native multipart form
   submits. Pinned by `server_upload_request_spec.rb` ("D1 — a native form
   submit…").
3. **D2 — upload-guard verb gate.** On host controllers the guard skips
   GET/HEAD requests (`__ruact_upload_guard_applicable?`); the v1 endpoint
   was POST-only so this carve-out is new surface, required by the AC1
   byte-for-byte rule for page actions. All non-GET actions are guarded
   regardless of bucket (AC4 says "non-GET action", not "function call").
4. **Open item 4 (2026-06-02 addendum) — RESOLVED: explicit include.**
   `include Ruact::Server` is always explicit — one line, no magic, never
   implied by `ruact_render` usage. The concern is also independent of
   `Ruact::Controller` (neither includes the other); hosts include both.

**Spec re-anchoring.** The 8.4/8.5 behavior matrix moved to
`spec/ruact/server_spec.rb` + `server_rescue_request_spec.rb` +
`server_upload_request_spec.rb` (tagged `:story_9_1`), mounted on REAL host
routes on the shared Story-7.9 Rails app — no `/__ruact/fn/` anywhere, no
dependency on the v1 spec files that Story 9.9 demolishes. The superseded
`endpoint_controller_rescue_spec.rb` / `endpoint_controller_upload_spec.rb`
were removed in the same commit; the v1 endpoint's observable contract
remains covered by `dispatch_request_spec.rb` / `csrf_request_spec.rb` until
9.9.

### 2026-06-07 — Story 9.1 — code-review patches (D1 verb gate, inherited precedence, standalone load path)

Three patches from the Story 9.1 code review (gem PR #2), amending the
2026-06-05 in-story decisions. All three were resolved with Luiz on
2026-06-06; spec-pinned and landed on the same PR as follow-up commits
(GitHub Flow — no amend/force-push).

1. **D1 amended — GET/HEAD excluded from structured error rendering.**
   `__ruact_render_structured_error?` now requires a non-GET/HEAD verb in
   addition to the function-call predicate. Function calls are non-GET by
   the verb rule (epic contract decision #1), so a GET/HEAD carrying
   `Accept: application/json` (a `fetch()` against a page action, an API
   probe) is NOT a function call — an error there keeps stock Rails
   behavior instead of being swallowed into the structured payload.
   **`__ruact_function_call?` itself is UNCHANGED** (raw `Accept` header,
   verb-agnostic) — Story 9.2 still reuses it verbatim as the dual-bucket
   discriminator; the verb gate lives only in the error-rendering scope.
   The `UploadTooLargeError` exception is unaffected (the guard already
   skips GET/HEAD per D2, so the combination is unreachable).
2. **Inherited host `rescue_from` precedence.** The 2026-06-05 "host wins"
   claim only held for handlers declared in the host's own class body AFTER
   the include — handlers inherited from a parent class sat EARLIER in
   `rescue_handlers` and lost Rails' most-recently-registered walk to the
   concern's `StandardError` entry. The concern now moves its two entries to
   the FRONT of the array at include time
   (`self.rescue_handlers = (rescue_handlers - inherited) + inherited`), so
   every host handler — inherited or declared after the include — stays more
   recent and keeps precedence. The concern-internal Pitfall #1 order
   (StandardError before InvalidAuthenticityToken) is preserved; the parent
   class's own registry is untouched (class_attribute write lands on the
   child). Idempotent under repeated include along an inheritance chain.
3. **Standalone load path.** `lib/ruact/server.rb` now does
   `require_relative "../ruact"` so a direct `require "ruact/server"`
   resolves everything the salvaged chains touch at request time
   (`Ruact.config` is defined in `ruact.rb`, not `configuration.rb`;
   `Ruact::UploadTooLargeError`; the ErrorPayload pipeline). Acyclic by
   construction: the gem root never requires `server.rb` back (the bare
   `require "ruact"` path stays ActionController-free; the Railtie loads the
   concern). Pinned by a subprocess spec (`ruby -I lib -e 'require
   "ruact/server"'`).

### 2026-06-08 — Story 9.1 — code-review patches, round 2 (predicate split, GET/HEAD upload-error gate, CSRF-ordering invariant)

Three further patches from the Story 9.1 code review (gem PR #2), refining the
2026-06-07 round. Spec-pinned (red→green), landed as a follow-up commit on the
same PR (GitHub Flow — no amend/force-push).

1. **Predicate split — raw header vs. semantic function-call.** The 2026-06-07
   round left `__ruact_function_call?` keyed purely on the raw `Accept` header
   (verb-agnostic) while the verb gate lived only inside
   `__ruact_render_structured_error?`. But the addendum also designated
   `__ruact_function_call?` as THE helper Story 9.2 reuses — so the helper
   encoded the wrong contract (a GET carrying `Accept: application/json` would
   read as a function call). Now split in two:
   - `__ruact_json_accept?` — the raw, verb-agnostic header check.
   - `__ruact_function_call?` — the SEMANTIC predicate:
     `__ruact_json_accept? && !(request.get? || request.head?)`.
   The verb rule (function calls are non-GET, epic contract decision #1) now
   lives in ONE place — the predicate itself — so Story 9.2 inherits the
   correct contract verbatim. This SUPERSEDES the 2026-06-07 note that
   "`__ruact_function_call?` itself is UNCHANGED"; the raw check survives under
   its new name.
2. **GET/HEAD upload-error gate.** `__ruact_render_structured_error?` now checks
   the verb FIRST (`return false if request.get? || request.head?`), so the
   `UploadTooLargeError` exception to the re-raise rule is also verb-gated. The
   guard never produces that error on a GET/HEAD (it skips them — D2), so the
   only way one reaches the handler on a GET is a manual `raise` inside a page
   action — which must keep stock Rails behavior (AC1 byte-for-byte), not be
   swallowed into a structured 413. The non-GET case is unchanged: a
   `UploadTooLargeError` from a native multipart form submit (Bucket 1, no JSON
   Accept) still renders a meaningful 413.
3. **CSRF-ordering invariant made executable (AC4 / Pitfall #4).** The upload
   guard is `prepend_before_action`, so it normally beats
   `verify_authenticity_token`. But a host can re-order CSRF ahead of it with
   `protect_from_forgery prepend: true`, after which an oversized tokenless
   multipart request is 403'd before the intended 413 — silently breaking AC4.
   Rather than document this as the host's responsibility, the concern now
   detects the inversion in the compiled callback chain
   (`__ruact_csrf_precedes_upload_guard?` — pure, unit-testable inspection) and
   fails loudly with a `Ruact::ConfigurationError` from
   `__ruact_verify_upload_guard_precedence!` (a new no-op hook on
   `ErrorRendering`, overridden by the concern, invoked before the guard's
   verb short-circuit). Because CSRF verification is a no-op for GET/HEAD, the
   guard still runs on page loads, so a misordered controller fails on its
   first request in development. Note the limit: an oversized tokenless POST to
   an already-misordered controller is still 403'd at request time (CSRF runs
   first; the guard cannot run) — the detection makes the misconfiguration
   impossible to ship unnoticed, it does not silently repair the ordering.

### 2026-06-08 — Story 9.1 — code-review patches, round 3 (ordering invariant on the POST path, ConfigurationError stays loud, conditional-CSRF detector, Accept parsing)

Five further patches from the Story 9.1 code review (gem PR #2), refining the
round-2 work. Spec-pinned (red→green), landed as a follow-up commit on the same
PR (GitHub Flow — no amend/force-push).

1. **Ordering invariant now covers the oversized tokenless POST.** Round 2
   detected the `protect_from_forgery prepend: true` inversion from inside the
   upload guard, which only runs when reachable — so the exact broken shape
   (an oversized multipart POST without a CSRF token) still 403'd before the
   413, because CSRF runs first and aborts the chain before the guard.
   `__ruact_verify_upload_guard_precedence!` is now ALSO invoked at the top of
   `ErrorRendering#__ruact_render_action_error`, so the rescue chain
   re-asserts the invariant on the request shape the guard never sees. Net
   effect: an inverted controller fails loudly (`Ruact::ConfigurationError`)
   on EVERY request — GET page loads (guard runs, CSRF no-ops), tokenless
   POSTs (CSRF raises → rescue re-checks), and valid-token POSTs (guard runs)
   alike. The misconfiguration can serve no request, which supersedes the
   round-2 note that "an oversized tokenless POST … is still 403'd at request
   time". Pinned by a request spec for an oversized tokenless POST on the
   inverted host.
2. **`Ruact::ConfigurationError` is never rendered as a structured error.**
   With the ordering verifier raising `Ruact::ConfigurationError` and the
   concern's `rescue_from StandardError` chain rendering structured JSON for
   JSON function calls, a valid-token `Accept: application/json` POST on an
   inverted host could fold the configuration failure into an ordinary
   `_ruact_server_action_error` 500. `__ruact_render_structured_error?` now
   returns false for `Ruact::ConfigurationError` (any source), so configuration
   invariants stay loud setup failures. Pinned by a non-GET JSON request spec.
3. **Detector narrowed to UNCONDITIONAL CSRF callbacks.**
   `__ruact_csrf_precedes_upload_guard?` reduced callbacks to raw filter names
   and ignored `if`/`unless`/`only`/`except`, so
   `protect_from_forgery prepend: true, if: -> { false }` (CSRF can never run)
   still raised. The detector now inspects the compiled before-callback's
   `@if`/`@unless` arrays (Rails compiles `only:`/`except:` into these) and
   only flags an unconditional CSRF callback. The genuine misconfig is
   unconditional, so it is still caught; false positives on conditional CSRF
   are eliminated. Pinned by `if: -> { false }` and `only:` specs.
4. **`Accept` header parsed into media ranges.** `__ruact_json_accept?` used
   `include?("application/json")`, which matched `application/jsonp` and
   `application/json;q=0` and was case-sensitive. It now parses comma-separated
   media ranges, matches `application/json` case-insensitively on token
   boundaries, and requires a positive q-value. This matters because
   `__ruact_function_call?` feeds Story 9.2's discriminator — a loose match
   would route ordinary requests into Ruact's structured payload. Pinned by
   `application/jsonp`, `application/json;q=0`, `Application/JSON`, and
   `application/json;q=0.5` specs.
5. **CHANGELOG corrected.** The `[Unreleased]` `Ruact::Server` note now states
   that function calls are non-GET/HEAD JSON-Accept requests and that the
   structured 413 applies to non-GET guarded requests (not "every caller
   shape"), matching the verb-gated round-2/round-3 behavior.

### 2026-06-08 — Story 9.1 — code-review patches, round 4 (applicability-aware CSRF detector, nil-limit no-op, stricter Accept parser, v1 smoke spec)

Four further patches from the Story 9.1 code review (gem PR #2), refining the
round-3 work. Spec-pinned (red→green), landed as a follow-up commit on the same
PR (GitHub Flow — no amend/force-push).

1. **CSRF-order detector evaluates applicability (supersedes round 3's
   "unconditional only").** Round 3 narrowed `__ruact_csrf_precedes_upload_guard?`
   to UNCONDITIONAL CSRF callbacks to kill false positives, but that created a
   false NEGATIVE: `protect_from_forgery with: :exception, prepend: true,
   only: [:create]` (on `create`) or `if: -> { true }` still runs CSRF ahead of
   the guard yet went unflagged. The detector now evaluates the CSRF callback's
   compiled `@if`/`@unless` conditions against the controller for the current
   request/action (`__ruact_callback_applies?` / `__ruact_condition_met?` —
   Symbol → `send`, Proc → arity-aware `instance_exec`, `ActionFilter` →
   `match?(self)`). An ACTIVE condition is caught; an inactive one
   (`only: [:other]`, `if: -> { false }`) is not. The detector is no longer
   purely static (it reads `action_name` / request-derived state), but both
   call sites — the guard and the rescue path — run inside a live request.
   Pinned: `only: [:create]` on `create` (flagged) vs on `index` (not flagged),
   `if: -> { true }` (flagged), plus the round-3 inactive cases.
2. **Ordering verifier is a no-op when `max_upload_bytes` is `nil`.** A nil cap
   is the documented carve-out that disables the gem-side guard, so there is no
   413-before-CSRF invariant to enforce — failing an inverted host that has
   intentionally opted out is wrong. `__ruact_verify_upload_guard_precedence!`
   now returns early when `Ruact.config.max_upload_bytes.nil?`. Pinned: a GET
   page load on an inverted host with `max_upload_bytes = nil` renders normally
   instead of raising `Ruact::ConfigurationError`.
3. **Stricter, quote-aware Accept parser.** The round-3 parser still accepted
   out-of-range q-values (`q=2`, `q=1.5`) and split on commas without respecting
   quoted-strings (`application/json;note="a,b";q=0` split before the q-value
   and defaulted to 1.0). The q-value must now lie within `0.0 < q <= 1.0`, and
   media ranges / parameters are split with a quote-aware tokenizer
   (`__ruact_split_unquoted`). This matters because `__ruact_function_call?`
   feeds Story 9.2's discriminator — a malformed or explicitly-refused JSON
   Accept must not misclassify a request. Pinned: `q=2`, `q=1.5`, and a quoted
   comma before `q=0` (all rejected); quoted comma with `q=0.9` (accepted).
4. **v1 endpoint upload-limit smoke spec.** The v1 endpoint stays alive as the
   strangler-fig safety net until Story 9.9 and still shares the salvaged upload
   guard, but the deep upload matrix was re-anchored on the v2 concern (and
   `endpoint_controller_upload_spec.rb` removed). A minimal observable-contract
   smoke spec now pins the v1 413 path (oversized multipart
   `POST /__ruact/fn/:name` → 413 + `_ruact_server_action_error` +
   `upload_limit`) in `dispatch_request_spec.rb`, so the safety net cannot
   regress before demolition. Not the old implementation-coupled matrix — just
   the wire-visible contract.

### 2026-06-08 — Story 9.1 — code-review patches, round 5 (escape-aware Accept tokenizer, strict qvalue grammar, GET/HEAD verifier no-op)

Three further patches from the Story 9.1 code review (gem PR #2), refining the
round-4 work. Spec-pinned (red→green), landed as a follow-up commit on the same
PR (GitHub Flow — no amend/force-push).

1. **Escape-aware Accept tokenizer + unterminated-range rejection.** Round 4's
   quote-aware split toggled quote state on every `"` and ignored HTTP
   quoted-pair (`\"`) escaping and unterminated quoted strings:
   `application/json;note="a\",b";q=0` read as JSON-acceptable (the escaped
   quote ended the quoted-string early, the comma split the range, and the
   `q=0` was lost → default 1.0). `__ruact_split_unquoted` now honors backslash
   escapes inside quoted spans, and `__ruact_json_media_range?` rejects a range
   whose quotes are unbalanced (`__ruact_balanced_quotes?`) rather than parsing
   it as default-quality JSON. Pinned: escaped quote before `q=0` (rejected),
   escaped quote with positive q (accepted), unterminated quote hiding `q=0`
   (rejected).
2. **Strict RFC 7231 qvalue grammar.** Round 4's `Float`-range check accepted
   malformed q-values (`q=.5`, `q=01`, `q=1e-1`, `q=0.1234`). The value is now
   validated against the qvalue grammar (`QVALUE_FORMAT` — `0` / `0.`+≤3 digits
   / `1` / `1.`+≤3 zeros) before conversion; anything else is a rejecting 0.0.
   Pinned: leading-dot, leading-zero, exponent, and over-precision values (all
   rejected).
3. **Ordering verifier is a no-op on GET/HEAD (supersedes round-2 GET
   surfacing).** D2 says the upload guard never fires on GET/HEAD, and AC1 says
   GET page behavior stays byte-for-byte — but the round-2/3 verifier still ran
   on those verbs, so `protect_from_forgery prepend: true, only: [:index]` on a
   GET `index` raised `Ruact::ConfigurationError` even though no upload guard
   could fire. `__ruact_verify_upload_guard_precedence!` now returns early when
   `__ruact_upload_guard_applicable?` is false. The loud failure is preserved
   for guarded (non-GET) requests — including the oversized tokenless POST via
   the rescue path (round 3) — so the misordering still cannot ship unnoticed;
   it simply surfaces on the first NON-GET (function-call) request instead of
   on a page load. This SUPERSEDES the round-2 note that GET page loads fail
   immediately on a misordered host. Pinned: GET on an unconditionally-inverted
   host renders (200); GET whose CSRF is scoped to the GET action (`only:`)
   renders (200); non-GET inverted specs still fail loudly; unit GET/HEAD
   no-raise + nil-limit non-GET no-raise.

### 2026-06-08 — Story 9.1 — contract simplification after review round 5

The repeated review loop on Story 9.1 exposed two over-engineered edges:
request-time callback-order introspection for the upload guard, and a hand-
rolled Accept parser that kept accreting RFC 7231 edge handling. The final
decision is to simplify both contracts rather than keep patching them.

1. **Accept is now exact.** The v2 concern treats only `Accept: application/json`
   as a JSON-Accept request. Exact header match, no qvalue parsing, no media-
   range splitting, no quoted-string handling. This matches the generated
   runtime shape and removes the parser surface entirely.
2. **Upload-order verification is documented, not enforced at runtime.** The
   concern still installs the upload guard, but it no longer introspects the
   callback chain to detect `protect_from_forgery prepend: true`. Hosts are
   expected to include `Ruact::Server` after `protect_from_forgery`; the order
   is documented in the changelog and story file instead of being enforced via
   request-time callback inspection.

Pinned by the simplified round-6 follow-up specs: exact `Accept:
application/json` is the only function-call discriminator, and the upload guard
still works on correctly ordered hosts while the misordered-host behavior is no
longer special-cased.

### 2026-06-09 — Story 9.2 — dual-bucket response negotiation on the same controller action

Phase B's contract story: one non-GET `Ruact::Server` action serves both
form/navigation submits (Bucket 1) and imperative `await fn()` calls (Bucket 2),
discriminated by `__ruact_function_call?` (locked in 9.1 — `Accept: application/json`,
non-GET). 9.1 built the predicate; 9.2 builds the response side.

**D1 — Bucket-2 success seam (`default_render`).** `Ruact::Server` overrides
`default_render`: `return super unless __ruact_function_call?` — so Bucket 1
falls through to the host's `Ruact::Controller#default_render` (Flight re-render)
and Rails, byte-for-byte unchanged. On Bucket 2 it serializes the action's
exposed ivars as a JSON object (or `head :no_content`). The two concerns are
siblings composed on the host; the super-chain works because `Ruact::Server` is
included on the action's controller (subclass) while `Ruact::Controller` sits on
a parent (`ApplicationController`), so `Server#default_render` precedes
`Controller#default_render` in the ancestry and `super` reaches it. Documented
include-order assumption: `include Ruact::Server` AFTER (or below in the
ancestry) `Ruact::Controller`.

**Exposed ivars = Rails `view_assigns`, VERBATIM (decided with Luiz 2026-06-09 —
"closest to how Rails does it").** No custom exclusion list. An early probe
suggested `@marked_for_same_origin_verification` leaks, but that was a probe
error: Rails 8.1.3 sets the PROTECTED `@_marked_for_same_origin_verification`
(`request_forgery_protection.rb:447`, in `base.rb:322` protected ivars), so a
real request's `view_assigns` is already clean. What remains is exactly what the
action assigned — including `@current_user` IF the action calls the memoized
helper (dev-controlled; same mental model as "what the view sees"). Keyed by
ivar name without `@`; a single ivar stays keyed (no magic unwrap, decision C).

**Bucket-2 value serialization — `Ruact::ServerFunctions::BucketTwoPayload`
(pure).** Mirrors the policy of `Flight::Serializer#serialize_unknown`
(`Ruact::Serializable` → `ruact_props` only; under `strict_serialization` a
non-Serializable domain object raises `Ruact::SerializationError`; otherwise a
vetted `as_json` fallback with self-/raise-guards), but emits PLAIN JSON-ready
values (Hash/Array/scalar) — `render json:` does the encoding, so JSON
primitives incl. Time/Date pass through (not Flight-encoded). Pure function: the
caller passes the resolved `strict` flag (= `Ruact.config.strict_serialization`),
mirroring the `ErrorPayload` caller/builder split (NFR26 / `Ruact/NoIoInFlight`
untouched). Policy MIRRORED (not extracted from `flight/serializer.rb`) to avoid
refactoring the Flight hot path; the Flight serializer remains the canonical
policy reference.

**D2 — `redirect_to` → `$redirect`.** `Ruact::Server` overrides `redirect_to`:
`return super unless __ruact_function_call?` (Bucket 1 → Controller's Flight
redirect row / Rails 302, unchanged). On Bucket 2 it renders
`json: { "$redirect" => <path> }`. Same-origin targets collapse to a path
(mirroring `Ruact::Controller#redirect_to`); external origins keep the absolute
URL. **Server-only: the runtime does NOT follow `$redirect` today** — emitting it
is 9.2; the client following it (and the route/verb re-target away from
`/__ruact/fn/:name`) is Story 9.3's runtime work.

**D3 — `Vary: Accept` (the ADR had NOT specified it — 9.2 owns it).** A
`prepend_before_action :__ruact_set_vary_on_accept!` appends `Accept` to `Vary`
for non-GET requests (idempotent, preserves host-set `Vary`). It is prepended
BEFORE the upload guard in source so the guard still lands first (Story 8.5
"guard wins the race" invariant preserved). Consequence: `Vary` is present on
the 200 ivar-JSON, 204, `$redirect`, Bucket-1 Flight, structured-500, and
403-CSRF shapes — the cacheable dual-representations — but NOT on the 413 upload
rejection (the guard aborts the chain before the Vary callback). Acceptable: the
413 is a non-cacheable error, not a dual representation.

**Error routing (AC5).** A `Ruact::SerializationError` raised inside
`default_render`'s Bucket-2 serialization propagates to the 9.1
`__ruact_render_action_error` chain → `__ruact_render_structured_error?` is true
(non-GET function call) → 500 structured payload. No new `rescue_from`.

**CSRF (AC7 / NFR27).** Entirely the host's `protect_from_forgery` — valid token
→ success; missing/invalid → 403 via the 9.1 chain; API-mode (forgery off) →
accepted. No gem-side CSRF.

#### 2026-06-09 — Story 9.2 review (round 3) — Vary callback limitation accepted

The `Vary: Accept` mechanism is callback-based (`before_action` +
`after_action`, see D3 / review rounds 1–2). One residual gap was identified
and ACCEPTED (Luiz) rather than patched further: a host `before_action` that
BOTH reassigns `Vary` AND performs the response in the same callback (e.g.
`response.headers["Vary"] = "Cookie"; redirect_to "/login"`) yields a final
response without `Accept` (Ruact's before-action set it, the host clobbered it,
and Rails skips after-actions on a before-halt). Rationale: the combination is
contrived (real auth callbacks redirect without reassigning `Vary`); a callback
cannot unconditionally guarantee the final header, and a Rack-level mechanism
was judged not worth the complexity for this edge. This mirrors the Story 9.1
lesson — stop patching the edges of a mechanism once the remaining cases stop
earning their complexity.

#### 2026-06-09 — Story 9.3 — Route-driven codegen for mutations + runtime re-target

Phase B. The codegen SOURCE swaps from the v1 registries to the Rails route
table, and the runtime SWAPS from the synthetic `POST /__ruact/fn/:name` to real
REST routes + verbs. Resolves the ADR open items left by Story 9-0 (namespace
scheme, rename-override macro) and the `$redirect` client-follow 9.2 deferred.

**Source (AC1).** `Ruact::ServerFunctions::RouteSource.collect(route_set)` reads
`Rails.application.routes`, keeps only non-GET/HEAD verbs (POST/PUT/PATCH/DELETE)
whose controller `include Ruact::Server`, and emits version-2 snapshot entries:
`{ js_identifier, kind: "action", http_method, path, segments, controller, action }`.
GET routes are pages — never callables. The `update` PATCH/PUT pair collapses to
one entry (`http_method: "PATCH"`, Rails' primary). Pure: the host predicate +
override lookup are injected (default = constant resolution) so the derivation
table is unit-testable without booting controllers.

**Naming derivation table (AC3 — LOCKED).**
`js_identifier = lowerCamel(action) + Namespace*(Pascal) + Resource(Pascal)`,
where `lowerCamel` is the existing `NameBridge` camelization (leading underscore
preserved). Resource word: SINGULAR for the RESTful writes
(`create`/`update`/`destroy`) and for any member route (path carries `:id`);
PLURAL for a custom collection route.

| Route (`verb controller#action`) | js_identifier |
|---|---|
| `POST posts#create` | `createPost` |
| `PATCH/PUT posts#update` | `updatePost` (PATCH) |
| `DELETE posts#destroy` | `destroyPost` |
| `GET posts#index/show/new/edit` | — (skipped; pages) |
| `POST posts#publish` (member) | `publishPost` |
| `POST posts#publish_all` (collection) | `publishAllPosts` |
| `POST session#create` (`resource :session`) | `createSession` |
| `DELETE account#destroy` (singular) | `destroyAccount` |
| `POST admin/posts#create` (namespaced) | `createAdminPost` |
| `POST admin/reports/posts#create` | `createAdminReportsPost` |

**Namespace = PREFIX, not flat (D3 — resolves 9-0 open item #2).** Namespace
segments are PascalCased and inserted between verb and resource. Rationale:
flattening guarantees `admin/posts#create` and `posts#create` collide on
`createPost`, forcing rename-overrides for the common admin case; prefixing keeps
the merged JS namespace collision-free by construction.

**Rename-override macro (D4 — resolves 9-0 open item #3).**
`ruact_function_name :action, as: "jsIdentifier"` — a class macro on the
`Ruact::Server` host (`Ruact::Server::ClassMethods`). Populates a per-controller
`__ruact_function_name_overrides` map (action name → js identifier) that
`RouteSource` consults before collision detection. The target is validated at
class-load time against the JS-identifier shape + reserved-word /
`RESERVED_BY_RUACT` rules (a bad override fails at boot, never at codegen).

**Collision detection (AC4).** Two distinct routes mapping to the same
js_identifier (after overrides) raise `Ruact::ConfigurationError` at boot naming
BOTH origins (`posts#create and comments#create both map to JS identifier
"createPost"`), mirroring the v1 cross-registry collision raise.

**Transparency (AC2).** `Ruact::ServerFunctions.write_v2_snapshot!` always logs
`[ruact] codegen: exposing <comma-list>` — a routed non-GET action never becomes
a callable silently (the verb-rule's mitigation, epic Decision #1).

**Runtime re-target (AC7, D6).** New runtime export `_makeServerFunction({ method,
path, segments })` for v2; v1 `_makeRef(name)` is BYTE-BEHAVIOR-IDENTICAL (still
POSTs `/__ruact/fn/:name`). Both factor through a shared `ruactInvoke({ method,
url, args, label })` core — same FormData branching, CSRF meta injection,
`credentials: "same-origin"`, `redirect: "error"`, text-first parsing,
`RuactActionError`. Adding a NEW export (not widening `_makeRef`) is what makes
AC6 "no shared-runtime leak" true by construction: the v1 path consumes
`_makeRef`, the v2 path consumes `_makeServerFunction`.

**Path-param interpolation (D7).** Member/`:id` routes need the id in the URL
(the v1 synthetic endpoint never did). The descriptor carries the path template
+ segment names; at call time the runtime reads each segment BY NAME from the
single FormData/object argument (`FormData.get("id")` / `args.id`),
URL-encodes it, and substitutes into the path — the full argument is still sent
as the body (Rails reads `params[:id]` from the path; the duplicate is ignored).
The single-arg shape (8.2 `<form action>` / `useActionState`) is unchanged. A
missing required segment throws a clear `TypeError` before any fetch.

**`$redirect` client-follow (D2 / AC8 — resolves the 9.2 deferral).** When a
Bucket-2 mutation returns `{ "$redirect": "<path>" }`, the v2 runtime navigates
via `globalThis.__ruact_navigate` (the same global handoff `revalidate()` uses),
falling back to `window.location.assign(path)` when no router is installed, and
resolves `null`. Applied ONLY on the v2 path — the v1 endpoint never emits
`$redirect`, so `_makeRef` is unaffected. Publishing `__ruact_navigate` from
`ruact-router.js#setupRouter` is playground wiring → Story 9.8.

**Codegen render (Ruby + JS byte-identical).** `Codegen.render` dispatches on
`snapshot.version`: version 1 → the untouched v1 renderer; version 2 →
`Codegen::V2.render` (separate module so the v1 singleton class stays within its
size budget), emitting `_makeServerFunction({ method, path, segments })` with the
SAME Story-8.2 intersection signature on every action. The JS-side `renderV2`
mirrors it; the parity vitest ("Story 9.3 — route-driven (v2) render + parity")
asserts byte equality against the Ruby renderer.

**Single-writer / `.next` parallel target (AC5).** The v2 codegen writes to a
PARALLEL bridge `tmp/cache/ruact/server-functions.next.json` →
`app/javascript/.ruact/server-functions.next.ts`, rendered by the Ruby codegen
(Vite does not watch `.next`). Per AC5 this target is for parity tests +
inspection ONLY — never imported by application code — so the real
`server-functions.ts` (v1, rendered by Vite from the v1 bridge) is untouched
(AC6). **Scoping decision (refines create-time D5):** in Story 9.3 the v2 codegen
ALWAYS writes the parallel target — it never takes over the real file. The
Decision-#6 ownership flip (an app with ZERO v1 declarations → route-driven
codegen takes over the real `server-functions.ts`) is Story 9.8's job; the
`Snapshot.v1_declarations?` primitive is provided + tested here for 9.8 to
consume. This is the literal reading of AC5's "writes to a parallel target …
never imported," and is strangler-safe (no cross-app behavior change in 9.3).

**Strangler invariant.** The v1 `POST /__ruact/fn/:name` endpoint, registries,
`ruact_action`/`ruact_query` DSL, and v1 codegen all stay fully alive and
untouched. Demolition is Story 9.9; playground migration is Story 9.8.


### 2026-06-09 — Story 9.4 — `Ruact::Query` base class + `ruact_queries` route macro — in-story decisions

**Scope.** Implements the v2 QUERY DISPATCH layer locked by the 2026-06-02
addendum (Decision 2): `Ruact::Query` base class, the `ruact_queries` mapper
macro, the internal per-query-class dispatch controller, constructor context
injection, the per-query callback opt-out, and the two new configuration
attributes. Resolves 2026-06-02 **open item 1** (callback opt-out) and **open
item 2** (route prefix). Codegen of query entries, the `useQuery` hook, and the
strict FR88 kwargs sanitization are Story 9.5; dedup is 9.6. The v1
`Ruact.query_registry` is untouched (legacy, removed by 9.9) — the v2 class
model never reads or populates it.

**Decisions taken in this story (delegated by the epic / 2026-06-02 addendum):**

1. **Open item 1 — RESOLVED: `ruact_skip_before_action` (D1, AC4).** Class
   macro on `Ruact::Query` subclasses mirroring Rails' `skip_before_action`
   signature (`ruact_skip_before_action :authenticate_user!, only: :categories,
   raise: false`). Recorded per-class (NOT inherited — a skip describes the
   declaring class's own queries) and applied verbatim to that class's
   generated dispatch controller at route-draw time. Scoping is structural:
   each query class gets its OWN controller (decision 2 below), so a skip can
   never leak to sibling query classes; `only:`/`except:` further scope to
   individual query methods (one action per method). Unknown callbacks raise at
   route-draw unless `raise: false` — stock Rails semantics.

2. **Dispatch-controller shape (D2): one generated controller subclass PER
   query class.** Built lazily by the routing macro (when `ruact_queries`
   runs inside `routes.draw`, the host's constants exist), inheriting
   `Ruact.config.query_parent_controller.constantize`, named under
   `Ruact::ServerFunctions::QueryDispatch` (e.g. `…::CatalogQueryController`)
   so string route targets and `rails routes` stay legible — the dev never
   sees it. One action per public query method (what makes per-action
   `skip_before_action` possible). Regeneration is idempotent
   (`remove_const` + rebuild on every draw) and the query class is
   re-constantized per request, so dev-mode code reloading never serves a
   stale class. The single-shared-controller alternative (query identity in a
   route default + conditional skips) was rejected: more complex, less
   Rails-idiomatic, and per-action callback scoping degrades.

   **Namespace preservation (code-review round 4 refinement).** The generated
   controller's constant path MIRRORS the query class's namespace rather than
   flattening it: `Admin::CatalogQuery` →
   `Ruact::ServerFunctions::QueryDispatch::Admin::CatalogQueryController`
   (route target `…/query_dispatch/admin/catalog_query`). The controller
   constant is therefore an injective function of the query class's
   fully-qualified name, so two distinct query classes can never map to the
   same generated constant — a const overwrite / route cross-wire is
   impossible by construction, across any number of RouteSets or mounted
   engines sharing the global dispatch module. (The initial implementation
   flattened `::` out and tried to detect the resulting collisions; three
   review rounds of detection patches converged on removing the flattening
   instead — no collision to detect.)

3. **Context source (D3): delegate to the dispatching controller, not a
   resolver lambda.** `Ruact::ServerFunctions::QueryContext` wraps the
   controller instance; `current_user` resolves through the controller's own
   method — public OR private (hand-rolled hosts commonly define it private)
   — because the controller inherits the host parent, that IS the host's
   Devise/Pundit/hand-rolled method (FR89). A host chain with no
   `current_user` raises a `NoMethodError` naming `query_parent_controller`
   and the fix. Mirrors `StandaloneContext`'s SHAPE (plain accessors,
   per-request instance, NFR8); the Story-8.3 `current_user_resolver` lambda
   plays no part (it is superseded with the standalone path).

4. **Route path derivation (D4) + open item 2 — RESOLVED: `/q` prefix.** Path
   = `"#{Ruact.config.query_route_prefix}/#{NameBridge.to_js_identifier(method)}"`
   (`search_users` → `GET /q/searchUsers`), route name
   `:"ruact_query_<jsIdentifier>"` — every query visible in `rails routes`.
   New config attrs (both under the 7.3 freeze contract):
   `query_route_prefix` (String, default `"/q"`, must start with `/`, no
   trailing slash — validated at writer time) and `query_parent_controller`
   (non-empty String, default `"ApplicationController"`, constantized lazily
   at route-draw — never at configure time, when the constant may not exist).
   NameBridge reserved-word/shape failures and duplicate route names across
   query classes both fail loudly at route-draw.

5. **GET error-chain gate (D5, AC5).** The generated controller includes the
   salvaged `ErrorRendering` chain with the same handler front-loading as
   `Ruact::Server` (host/parent `rescue_from` keeps precedence) and overrides
   `__ruact_render_structured_error?`: the mutation concern's gate returns
   false for GET/HEAD (GET *pages* keep stock Rails errors), but every query
   dispatch request is a GET *function call* — the override renders the
   structured 8.4 payload (same 422/403/413/500 mapping) for everything
   except `Ruact::ConfigurationError`, which still re-raises (a
   misconfiguration stays a loud setup failure). No upload guard callback is
   registered (GET bodies) and no `skip_forgery_protection` is added (Rails
   never CSRF-verifies GET — confirmed by spec, not by dead code).

6. **Return-value serialization (D6): `BucketTwoPayload.serialize_value`.**
   The per-value branch of the Bucket-2 policy was extracted as a public
   `serialize_value(value, strict:)` and is now the single policy for BOTH
   the 9.2 ivar hash and the 9.4 query return value (`ruact_props` /
   `Serializable` / `strict_serialization`, primitives pass through,
   Hash/Array recursion). The controller resolves `strict_serialization` and
   passes it in (serializer stays pure, NFR26). The response body is encoded
   explicitly (`ActiveSupport::JSON.encode`) so scalar String and `nil`
   returns render valid JSON — **`nil` → `null` with 200** (not 204): simpler
   for a read; the 9.5 `useQuery` hook treats `data: null` as "no rows".

7. **Param passing boundary (D7).** 9.4 passes GET query params as the
   keyword arguments the query method declares, by name, best-effort (values
   arrive as Strings). The strict FR88 sanitization contract
   (string/number/boolean/null allowlist, reject objects, 400 on invalid) is
   **Story 9.5's**, coupled to the `useQuery` wire format.

8. **Install mechanism (D8).** `Ruact::Routing` is included into
   `ActionDispatch::Routing::Mapper` at require time (`ruact/routing`,
   required by the Railtie's `ruact.load_controller` initializer — before the
   host's routes file loads). This is a NEW mechanism for the gem: a Mapper
   *extension* the host calls explicitly, not a mounted route like the v1
   `app.routes.prepend` endpoint — decision A (explicit mount) made flesh.

**Deferred (noted, not ACs here):** install-generator scaffolding for
`app/queries/application_query.rb`; codegen + `useQuery` + FR88 kwargs (9.5);
dedup (9.6); docs rewrite (9.7); playground migration (9.8).

---

## 2026-06-10 — Story 9.5 — Queries in codegen, `useQuery` re-pointed, kwargs sanitized

Closes the read-side of the route-driven redesign: queries now appear in the
v2 codegen module, `useQuery` issues a real `GET /q/<jsId>`, and the FR88
kwargs contract is enforced server-side. Append-only addendum to the
2026-06-02 (route-driven) and 2026-06-09 (Story 9.4) entries.

1. **Query codegen source = the drawn route table (route-truth), not the set
   of `Ruact::Query` subclasses (AC1).** `Ruact::ServerFunctions::QuerySource`
   enumerates drawn GET routes whose controller path is under
   `ruact/server_functions/query_dispatch/` (the generated dispatch
   controllers from Story 9.4) and emits one v2 query entry each. This is the
   sibling of `RouteSource` (mutations) and was chosen over enumerating
   `Ruact::Query.subclasses` deliberately: a host exposes a query ONLY by
   mounting it with `ruact_queries` in `routes.rb`, so the route table is the
   single source of truth. Reading subclasses would over-expose query classes
   that are defined but never mounted (and `useQuery` would 404 on their
   non-existent routes). **Consequence:** the "force-load `app/queries/` at
   `config.to_prepare`" gap flagged in the story is *moot* — mounting a class
   in `routes.rb` already autoloads it, so no force-load was added (avoiding
   the over-exposure a blind force-load-then-enumerate would cause). `QuerySource`
   is pure: the route set + a `query_class_for` resolver are injected (the
   railtie passes the real `__ruact_query_class` lookup; specs inject a lambda).

2. **Entry shape carries `accepts_params` for the TS signature (AC1).** A query
   entry is `{ js_identifier, kind: "query", http_method: "GET", path,
   segments: [], accepts_params, controller, action }`. `accepts_params` is
   true iff the query method declares any keyword argument
   (`:key`/`:keyreq`/`:keyrest`) and drives the emitted signature:
   `(params: Record<string, unknown>) => Promise<unknown>` when true,
   `() => Promise<unknown>` when false. `NameBridge.to_js_identifier` is reused
   verbatim (single source of truth for snake→camel), so the codegen jsId is
   byte-identical to the route the `ruact_queries` macro drew.

3. **Merged JS namespace + collision detection (AC1, Task 2).** Action entries
   (`RouteSource`) and query entries (`QuerySource`) share ONE namespace.
   `RouteSource` rejects action×action and `QuerySource` rejects query×query
   intra-kind; `ServerFunctions.detect_merged_namespace_collisions!` (run at
   the `write_v2_snapshot!` combine point) rejects route×query. All three name
   BOTH origins (`posts#categories and CatalogQuery#categories`). **Escape
   hatch:** the `ruact_function_name :<action>, as: "<id>"` rename macro on the
   *mutation controller* (Story 9.3) resolves a route×query clash; a
   query×query clash is resolved by renaming a query method. The query side has
   no rename macro because `routing.rb#draw_query_routes` derives the jsId
   purely from the method name via `NameBridge` (kept read-only this story) —
   renaming the method is the single, consistent lever, and keeps the route the
   macro draws and the codegen jsId in lockstep by construction.

4. **`useQuery` issues `GET /q/<jsId>` — the stale `POST /__ruact/fn/:id`
   mechanism is VOIDED (AC2).** The 2026-05-13 ADR clarification #5 ("hook reads
   `$$id`, POSTs `/__ruact/fn/:id`") is dead: Story 9.4 mounts queries as real
   named GET routes and the 2026-06-02 addendum restored HTTP GET semantics for
   reads (CSRF-free). The codegen emits `export const <id> = _makeQuery({ path,
   kind: "query" })`; `useQuery(reference, params?) → { data, loading, error }`
   invokes that reference inside a `useEffect`, tracking state and dropping a
   superseded in-flight response (params changed / unmounted). The reference is
   also directly callable for imperative use. `useQuery` and `_makeQuery` are
   re-exported from `@/.ruact/server-functions` by the codegen — `useQuery` only
   when the snapshot has ≥1 query entry, which keeps action-only and empty v2
   modules **byte-identical to Story 9.3** (minimal-churn import list:
   `_makeServerFunction` and/or `_makeQuery` are imported only when used).

5. **`useQuery` wire format = primitives in the query string; server validation
   is authoritative (AC3, FR88).** The client serializes `params` into the GET
   query string: `string`/`number`/`boolean` → `key=value`, `null` → `key=`
   (empty), and arrays/objects throw a client-side `TypeError` for immediate
   feedback. The SERVER is the authority: `query_dispatch.rb#__ruact_query_kwargs`
   reads `request.query_parameters` (the raw client params — NOT `params`, which
   carries Rails' `controller`/`action`/`format` defaults that must not count as
   "unknown") and enforces, in order: (a) **allowlist** — a value Rack parsed as
   an Array (`?q[]=`) or Hash (`?q[k]=`) is rejected (a scalar arrives as a
   String, the only non-`nil` primitive on the wire); (b) **unknown param** — a
   key matching no declared kwarg (and no `**rest`) is rejected, not dropped;
   (c) **missing required** — a `keyreq` the client omitted. All three raise the
   new `Ruact::BadRequestError` (`< Ruact::Error`) → **HTTP 400** via a new case
   in `__ruact_status_for`, rendered through the same Story 8.4 structured
   payload (`_ruact_server_action_error: true`, `error_class`, `message` naming
   the offending key + allowlist). Values are delivered to the query method as
   Strings (GET semantics, unchanged from 9.4's best-effort) — FR88 governs the
   *shape* on the wire, not type coercion, which stays the method's concern.

6. **React becomes a `peerDependency` of the runtime package.** `useQuery` is
   the runtime's first React import (`useState`/`useEffect`). React is declared
   as a `peerDependency` (`">=18"`) — every host already has it; the runtime
   never bundles its own copy. The mutation path (`_makeRef` /
   `_makeServerFunction`) stays React-free. Package version `0.2.0` → `0.3.0`.
   The hook is covered by jsdom + `@testing-library/react` vitest
   (`usequery.test.mjs`); those dev-only deps live in the runtime package and
   run via its own `npm test` (the vite-plugin parity run globs only the
   node-environment `index.test.mjs`).

7. **Scope guards (unchanged from the story plan).** 9.5 writes ONLY the
   parallel `.next` codegen target (the ownership flip to the real
   `server-functions.ts` is 9.8). Request de-duplication for `useQuery` is 9.6
   (the hook fetches once per mount; a `useSyncExternalStore` refactor can layer
   dedup later). The v1 substrate is untouched (demolition is 9.9).

### 2026-06-25 — Story 13.1 — Serialize-only invariant (FR97)

Epic 13 ("Server-Function Contract & Safety") opens by turning a *happy accident
of architecture* into a **defended invariant**. The 2026-06-15 technical research
report established that ruact is **serialize-only**: its Ruby side *emits* React
Flight (`text/x-component`) but has **no inbound Flight deserializer**, so it sits
structurally **outside** the React2Shell / **CVE-2025-55182** class — a Flight-
deserialization RCE (CVSS 10, Dec 2025) in which an attacker-supplied Flight
payload is deserialized into live server objects. Append-only addendum; supersedes
nothing.

1. **The invariant (the rule).** ruact **may emit** Flight (`text/x-component`)
   from the Ruby server, but must **never deserialize externally-supplied Flight
   into live Ruby objects.** No inbound `*Deserializer`, no `parse_flight` /
   `from_flight` / `deserialize_flight` / `decode_flight` reading a request body,
   no Ruby call to a React Flight reader (`createFromNodeStream` /
   `createFromReadableStream` / `createFromFetch`). Reads stay GET-with-primitives (FR88); writes stay
   form/JSON over the host's own CSRF — neither path parses Flight inbound.

2. **Out of scope — the client `createFromFlightPayload`.** The generated
   client entry (`lib/generators/ruact/install/templates/application.jsx.tt`)
   calls `createFromFlightPayload` to deserialize the server's **own trusted**
   payload in the **browser**. That is normal RSC on the client — not the Ruby
   server, not attacker-controlled inbound Flight — and is explicitly **outside**
   this invariant. The tripwire scans Ruby source only and excludes the
   generators' client-side templates.

3. **Enforcement — a `Ruact::Doctor` tripwire, not a parser.** `check_serialize_only`
   greps ruact's own `lib/**/*.rb` (default root `Ruact.gem_path/lib`, injectable
   for specs) for a curated list of structural inbound-deserialization signals and
   **fails** on any unannotated hit, naming `file:line` + this invariant. The raw
   `text/x-component` token is deliberately **not** a signal — the gem legitimately
   *emits* that media type (`controller.rb` / `server.rb`), so matching it would
   false-fail the (invariant-holding) current tree. Today the check **passes
   silently**. AST parsing was rejected as over-engineering for a tripwire whose
   job is to *stay at zero* (consistent with the single-dependency / "make invalid
   states unconstructible, simply" discipline). The signal literals are assembled
   from fragments via `Array#join` and `doctor.rb` is excluded from its own scan
   by exact file path — not basename, so a differently-located future namesake is
   still scanned (mirrors the Story 5.1 F4 self-reference lesson).

4. **Escape hatch — `# ruact:allow-flight-deserialization <reason>`.** A line
   carrying that annotation is treated as guarded, so a deliberate, reviewed
   deserializer is allowed without failing. This is what makes the check a
   **guard** rather than a blanket ban.

5. **Middleware warn (non-failing).** `check_flight_middleware` introduces a new
   `:warn` doctor status (rendered `⚠`; a `:warn` does **not** flip the run to
   failure — the pass computation moved from `status == :pass` to an allowlist,
   `SUCCESS_STATUSES = %i[pass warn]`, so a `:warn` passes while any unexpected
   status fails loudly rather than being silently treated as a pass).
   It warns when a response-transforming middleware (`Rack::Deflater` + a small
   curated list) is mounted, since recompressing/mutating a streamed
   `text/x-component` body breaks the Flight wire contract / streaming
   (React-on-Rails ops lesson). Rack middleware is app-global, not per-route, so
   the warn cannot be scoped precisely to Flight routes — it points the operator
   at the remedy (exclude `text/x-component` from compression).

6. **Where it earns its keep.** The primary venue is the gem's own CI (the
   `:story_13_1` spec runs the tripwire against a fixture tree). In a host app,
   `rails ruact:doctor` scanning `Ruact.gem_path/lib` is defense-in-depth — a
   released gem won't contain a deserializer, so it passes; its value there is
   catching a hand-patched/vendored gem.

7. **Scope guards.** This story ships ONLY the ADR addendum + the two doctor
   checks + specs. No SignedGlobalID (13.2 / FR96), no error round-trip (13.3 /
   FR98), no TS emission (13.4 / FR99), no component contract (13.5 / FR100), no
   playground (13.6). The client-side React deserialization path is untouched.

### 2026-06-26 — Story 13.2 — SignedGlobalID record references (FR96)

The inbound-safety counterpart to the serialize-only invariant (13.1). The
serialize-only guard keeps ruact from *deserializing* hostile Flight; this story
keeps a controller from handing the client a *forgeable* record reference in the
first place. Decisions:

1. **The canonical record-reference primitive is a SignedGlobalID, opt-in via an
   explicit helper.** `Ruact.signed_global_id(record, for:, expires_in:)` returns
   `record.to_sgid(for:, expires_in:).to_s` (a plain `String` → the Flight
   serializer carries it unchanged, no serializer branch). `Ruact.locate_signed(
   token, for:)` wraps `GlobalID::Locator.locate_signed`. Chosen over (a)
   hand-rolled `to_sgid` (no loud-omission guard, no symmetry) and (c)
   auto-serializing every `ActiveRecord::Base` (magic; conflicts with the
   `ruact_props` explicit-allowlist grain; can't carry a per-site `for:`). The
   opt-in is "the developer reaches for the helper," surfaced in docs as the
   canonical pattern.

2. **Inbound resolution is explicit, never automatic.** The action/query calls
   `Ruact.locate_signed` itself; the strict param allowlist (`query_dispatch.rb`)
   is untouched — no auto-detect-and-resolve of token-shaped strings (a param may
   legitimately be a string that merely looks like a token; auto-resolution would
   couple the param layer to ActiveRecord and surprise developers).

3. **Loud-omission invariant — never a silent insecure default.** Purpose and
   expiry resolve call-arg → config default → **raise** `Ruact::Error`. Purpose
   is always required (an unscoped token is never acceptable, so even an explicit
   `for: nil` raises). Expiry distinguishes *omission* from a deliberate choice
   via a private `UNSET` sentinel: pure omission with no configured default
   raises; an explicit `expires_in: nil` is honored as a reviewed non-expiring
   token. `expires_in:` must be an `ActiveSupport::Duration` (globalid calls
   `#from_now`).

4. **Tampered/expired/wrong-purpose → clean 400.** `locate_signed` returns `nil`
   on any verification failure; the helper raises `Ruact::InvalidSignedGlobalIDError`,
   mapped to **400** in `__ruact_status_for` (alongside `BadRequestError`). 400
   over 404 because the token is an invalid client *credential*, not a missing
   record — and verification fails before any DB lookup, so record existence is
   never revealed either way. No `ActiveRecord::RecordNotFound` leak; the
   rejection message never echoes the raw token.

5. **Single-dependency discipline preserved.** `globalid` ships with every Rails
   app but is not a gemspec dependency (only `nokogiri` is). It is **lazily
   required** inside the helpers on first call (mirroring the class-name-string
   matching in `ErrorRendering` that avoids requiring ActiveRecord at load), so
   the gem stays loadable in pure-Ruby contexts and the gemspec is unchanged.

6. **Scope guards.** This story ships ONLY the two helpers + the error class +
   400 mapping + two config keys + security docs + specs. No error round-trip
   (13.3 / FR98), no TS emission (13.4 / FR99), no component contract (13.5 /
   FR100), no playground (13.6). The Epic 10 scaffold generator does not exist
   yet — the docs worked-example is the canonical pattern it will later emit.

#### 2026-06-26 — Story 13.2 review patch (dev⇄Codex)

Three findings, all resolved before merge:
- **(Patch)** `InvalidSignedGlobalIDError`'s YARD comment was inserted between
  `UploadTooLargeError`'s doc block and its class, detaching the upload docs →
  moved the new error + comment to sit right after `BadRequestError`.
- **(Patch)** the production-mode no-leak spec asserted `not_to have_key("backtrace")`,
  but the dev-only payload keys are `app_frames` / `gem_frames` / `suggestion` →
  the spec now asserts the response is exactly the four baseline keys.
- **(Decision, Luiz)** a **valid** token whose record was since **deleted** is
  out of AC2's three rejection cases (tampered/expired/wrong-purpose, which never
  reach the finder). **Resolved: do NOT normalize.** The finder's
  `ActiveRecord::RecordNotFound` propagates as the host's ordinary not-found
  concern (identical to a raw `Model.find`); the primitive owns only signature/
  expiry/purpose verification. Documented on `InvalidSignedGlobalIDError` and
  pinned by a spec.
- YARD `{Ruact.signed_global_id}` / `{Ruact.locate_signed}` cross-references are
  unresolvable (the methods are mixed onto `Ruact`'s singleton via `extend`), so
  they are written as plain code spans, not doc links.
