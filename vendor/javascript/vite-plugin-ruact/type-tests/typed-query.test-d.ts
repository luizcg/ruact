// Story 13.4 (AC6) — compile-time proof that the codegen-emitted typed query
// `params` signature is ENFORCED by `tsc`. This file mirrors the accessor shape
// emitted by `renderQueryExportV2` for a query declaring `def search_users(term:,
// limit: 10)` (see the byte-exact assertion in `server-functions-codegen.test.mjs`
// → "Story 13.4 … typed query params render"). If codegen drifts, that parity
// test reddens; if the emitted type is too loose, the `@ts-expect-error` lines
// below become "unused directive" tsc errors (TS2578) — either way CI catches it.
//
// `@ts-expect-error` is self-checking: it is itself an error UNLESS the next line
// genuinely fails to compile, so a clean call MUST type-check and every illegal
// call MUST fail.

// The emitted value type for a typed query param: the FR88 wire union.
type Wire = string | number | boolean | null;

// Mirror of the emitted accessor: `term` required, `limit` optional.
declare const searchUsers: (params: {
  term: Wire;
  limit?: Wire;
}) => Promise<unknown>;

// ── Clean calls — MUST type-check ───────────────────────────────────────────
void searchUsers({ term: "ada" });
void searchUsers({ term: "ada", limit: 10 });
void searchUsers({ term: 42, limit: true });
void searchUsers({ term: null });

// ── Missing required param — MUST error ─────────────────────────────────────
// @ts-expect-error — `term` is required
void searchUsers({ limit: 10 });

// @ts-expect-error — required param object cannot be omitted entirely
void searchUsers();

// ── Unknown key — MUST error (excess property check) ────────────────────────
// @ts-expect-error — `bogus` is not a declared param
void searchUsers({ term: "ada", bogus: 1 });

// ── Wrong-typed value — MUST error (outside the wire union) ──────────────────
// @ts-expect-error — an object is not assignable to the wire union
void searchUsers({ term: { nested: true } });

// @ts-expect-error — an array is not assignable to the wire union
void searchUsers({ term: [1, 2, 3] });

// ── Wrong arity — MUST error ────────────────────────────────────────────────
// @ts-expect-error — the accessor takes exactly one argument
void searchUsers({ term: "ada" }, "extra");
