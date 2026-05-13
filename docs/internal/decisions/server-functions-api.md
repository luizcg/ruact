# Server Functions API — React-side accessor shape

| Field | Value |
| --- | --- |
| Date | 2026-05-12 |
| Status | Accepted |
| Story | [8.0 — Server functions API design spike](../../../../_bmad-output/implementation-artifacts/8-0-server-functions-api-design-spike.md) |
| Inspected | `react@19.2.0`, `next@15.4.0-canary`, `eslint-plugin-react-hooks@v6`, `vite@6.x` |
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

## Alternatives considered

The full scoring matrix lives in
[`/tmp/8-0-matrix.md`](../../../../_bmad-output/implementation-artifacts/8-0-server-functions-api-design-spike.md)
(captured in Task 2 of the spike); the summary is below. Each rejected option
cites at least one pitfall from the spike's Context Bundle.

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

The accessor mechanics are identical (one named import, no hook, one type per
function). Actions integrate with native React `<form action>` + `useActionState`;
queries integrate with ruact's `useQuery` (Story 9.2). The symmetric-coverage
invariant is preserved.

## Implementation surface

| # | Machinery | Owning story | "Done" signal |
|---|---|---|---|
| 1 | `Ruact.action_registry` + `Ruact.query_registry` (Ruby) | Story 8.1 (actions) + Story 9.1 (queries) | `Ruact.action_registry[:create_post] # => RuactAction(controller:, params:, returns:)` after the Ruby DSL macro evaluates |
| 2 | DSL macros `ruact_action :name do |params| ... end` and `ruact_query :name do ... end` | Story 8.1 + 9.1 | Defining a macro at controller-class load time both registers the symbol and defines the matching method (visibility and CSRF rules per Story 8.2 / 9.4) |
| 3 | Server-function endpoint (single Rails route mounted by the gem; resolves by symbolic name from registries 1+2; no per-function entries in `routes.rb`) | Story 8.1 | `POST /__ruact/fn/:name` returns the action result; `GET /__ruact/fn/:name?args=...` returns the query result; both reuse `Ruact::Controller` security/CSRF |
| 4 | `vite-plugin-ruact` extension that emits `app/javascript/.ruact/server-functions.ts` from a Rails-side dump (JSON written by a Railtie initializer) | **Implemented in Story 8.0a** | Generated file present, `tsc --noEmit` green on a freshly-installed playground |
| 5 | Rails `config.to_prepare` hook that triggers regeneration of #4 in dev | **Implemented in Story 8.0a** | `bin/rails server`, edit a controller's `ruact_action`, file at `app/javascript/.ruact/server-functions.ts` updates without restart |
| 6 | `bin/rails ruact:server_functions:generate` rake task (manual + CI/production hook) | **Implemented in Story 8.0a** | Task succeeds on a clean checkout; file is byte-identical to dev-mode output |
| 7 | `rails generate ruact:install` updates: add `app/javascript/.ruact/.gitkeep`, add `app/javascript/.ruact/server-functions.ts` to `.gitignore`, run the generate rake task once | **Implemented in Story 8.0a** (originally tagged Story 8.1; landed early because the codegen surface lives in 8.0a) | Fresh `rails new` + `rails generate ruact:install` results in a working playground that can call a stub action without further setup |
| 8 | Naming-bridge implementation in #4 (Ruby → JS identifier) | **Implemented in Story 8.0a** | The 6 edge cases enumerated in "Naming bridge" below all behave per spec |
| 9 | `useQuery(reference)` hook (consumes the named import; integrates with React Suspense) | Story 9.2 | `useQuery(categories)` suspends, then resolves; works inside `<Suspense>` boundary; cache key is the reference's `$$id` |

Every machinery item has a story assignment. The new Story 8.0a (Vite plugin
extension + naming bridge + dev-reload hook + rake task) is added to
`epics-phase-2.md` and `sprint-status.yaml` in the same PR that lands this ADR.

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

The "rejected at boot" choice (vs silent normalization) is deliberate: ruby_symbol
→ JS-identifier conversion is one-way, so accepting `:CreatePost` and emitting
`createPost` would create two co-equal Ruby names for the same JS symbol —
collision-prone, hard to reverse-engineer in stack traces. The cost of the
strict rule is one early failure for the 1% of devs who use unusual casing,
which is the right trade.

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
[Story 8.0a](../../../../_bmad-output/implementation-artifacts/8-0a-vite-plugin-server-functions-codegen.md)
for the full task breakdown and AC mapping.
