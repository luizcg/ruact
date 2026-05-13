# `gem/docs/internal/`

Architecture Decision Records (ADRs) and design notes about the **internals**
of the ruact gem — authoritative for contributors changing gem code, distinct
from user-facing API docs (in `website/`) and workspace planning artifacts
(`_bmad-output/`, monorepo-only).

- [`decisions/`](./decisions) — ADR-style decisions, one file per decision,
  **append-only**: revisit dated addenda at the bottom, never rewrite the body.

Write a new decision here when a story locks an API or mechanism that
downstream consumers will rely on.
