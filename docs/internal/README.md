# `gem/docs/internal/`

Architecture Decision Records (ADRs) and design notes about the **internals** of the
ruact gem. These documents are authoritative for contributors implementing changes
to the gem itself; they are NOT user-facing API documentation (which lives in the
`website/` repo / VitePress site) and they are NOT planning artifacts (which live
in the planning monorepo's `_bmad-output/`).

## Contents

- [`decisions/`](./decisions) — ADR-style decisions about gem internals. Each file
  documents a single decision, lists the alternatives that were considered, names
  the chosen option, and is **append-only**: when the decision is revisited, a
  dated addendum is added at the bottom of the file rather than rewriting the
  original.

## Audience

Contributors adding code to `gem/lib/`, `gem/spec/`, or `gem/vendor/`. Read the
relevant decision before making a change that could deviate from it.

## When to write a new decision here

When implementing a story (or independent change) that locks an API or
mechanism downstream consumers will rely on. If the decision could be made
differently and the choice will outlive the PR that introduces it, write a one-page
ADR here and reference it from the story / PR description.
