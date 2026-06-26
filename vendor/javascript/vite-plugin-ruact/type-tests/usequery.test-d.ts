// Story 13.4 (AC3 / Task 6) — proves a codegen-emitted TYPED query accessor is
// accepted by `useQuery` without a cast (the dev⇄Codex round-1 regression: the
// pre-13.4 `useQuery` `reference` param was `(params?: Record<string, unknown>)`,
// which a typed `(params: { term: Wire }) => Promise<unknown>` accessor is NOT
// assignable to under `strict`). Also confirms the no-kwargs accessor and the
// return-type generic still work.

import { useQuery } from "ruact/server-functions-runtime";

type Wire = string | number | boolean | null;

// Mirror of the emitted accessors:
declare const searchUsers: (params: { term: Wire; limit?: Wire }) => Promise<unknown>;
declare const categories: () => Promise<unknown>;

// Typed query ref + params — MUST type-check.
void useQuery(searchUsers, { term: "ada" });
void useQuery(searchUsers, { term: "ada", limit: 25 });

// No-kwargs query ref — MUST type-check (with and without the return generic).
void useQuery(categories);
void useQuery<{ id: number }[]>(categories);

// Return-type generic still flows.
const r = useQuery<{ id: number }[]>(searchUsers, { term: "ada" });
void r.data;
