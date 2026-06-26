// Story 13.4 (AC3 / Task 6) — proves the emitted typed-`params` `export const`
// type-checks against the runtime `_makeQuery` declaration WITHOUT a cast (so the
// runtime `.d.ts` needs no widening). This is a faithful copy of what
// `renderQueryExportV2` emits for a kwargs query: the typed signature annotation
// on the `const`, assigned the `_makeQuery({ path, kind })` factory result.

import { _makeQuery } from "ruact/server-functions-runtime";

// Emitted verbatim by the codegen (no cast, no `any`):
export const searchUsers: (params: {
  term: string | number | boolean | null;
  limit?: string | number | boolean | null;
}) => Promise<unknown> = _makeQuery({ path: "/q/searchUsers", kind: "query" });

// And the no-kwargs shape:
export const categories: () => Promise<unknown> = _makeQuery({
  path: "/q/categories",
  kind: "query",
});

// The emitted accessors are callable at their declared shapes.
void searchUsers({ term: "ada", limit: 10 });
void categories();
