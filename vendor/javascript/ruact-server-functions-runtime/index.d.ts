// Story 8.1 — TypeScript declarations for the real server-functions runtime.
// Mirrors the JS exports in `index.js` so the generated module's
// `import { _makeRef } from "ruact/server-functions-runtime"` resolves under
// `tsc --noEmit` (AC10's import guarantee).
//
// The generated module's per-export signature is
// `(args?: Record<string, unknown>) => Promise<unknown>` per the 8.0a
// codegen contract; the runtime accepts a wider `FormData` argument too
// (Story 8.2 owns the codegen signature widening if it picks the FormData
// path). Devs writing call sites against the 8.0a-emitted module continue
// to see the conservative Record<string, unknown> signature; the FormData
// branch only fires through Story 8.2's `<form action={fn}>` wiring.

/**
 * Re-run-3 (2026-05-15), refined Re-run-4 (2026-05-15) — local alias
 * for the FormData INSTANCE type that does NOT require `lib: ["dom"]`
 * in the consumer's tsconfig.
 *
 * Re-run-4 fix: pre-batch this inferred `F = typeof FormData` (the
 * constructor), so DOM consumers passing `new FormData()` were typed
 * against the constructor signature and `tsc` would reject the call.
 * The conditional below now extracts the INSTANCE type from the
 * constructor (`new (...args) => I`) when DOM lib is loaded, and
 * falls back to a minimal structural shape in non-DOM targets.
 */
type RuactFormData = typeof globalThis extends { FormData: new (...args: never[]) => infer Instance }
  ? Instance
  : { append(name: string, value: unknown): void };

/**
 * Re-run-4 (2026-05-15) — same conditional-typeof pattern for the
 * fetch `Response` type so the declaration compiles without DOM lib.
 */
type RuactResponse = typeof globalThis extends { Response: new (...args: never[]) => infer Instance }
  ? Instance
  : unknown;

/**
 * Returns a callable accessor for a server function registered with the
 * given Ruby symbol name. The accessor, when invoked, POSTs the args to
 * `/__ruact/fn/${name}`.
 *
 * Story 8.2 (refined 2026-05-17 per review patch R1) — the return type
 * is an intersection of FOUR call signatures so the same exported
 * reference is usable from every call site:
 *
 *   1. `()` / `(args)` / `(prevState, formData)` — direct callers and
 *      `useActionState`'s two-arg invocation; returns `Promise<unknown>`.
 *   2. `(formData: FormData)` — assignable to React 19's `<form action>`
 *      prop, which is typed as `(formData: FormData) => void | Promise<void>`.
 *      Promise generics are invariant in TS, so `Promise<unknown>` is
 *      NOT assignable to `Promise<void>` even via the void-discard rule;
 *      the intersection lets `<form action={createPost}>` typecheck
 *      DIRECTLY against the emitted module without a call-site cast.
 *
 * Runtime behavior is unchanged — `_makeRef` always resolves with the
 * JSON-decoded value. The `Promise<void>` overload is a TYPE-ONLY
 * surface: when React invokes the function from a `<form action>` prop,
 * the return value is discarded by React anyway.
 */
export function _makeRef(
  name: string,
): ((
  arg1?: Record<string, unknown> | RuactFormData,
  arg2?: RuactFormData | Record<string, unknown>,
) => Promise<unknown>) &
  ((formData: RuactFormData) => Promise<void>);

/**
 * Story 9.3 — the route-driven (v2) accessor. The codegen emits
 * `_makeServerFunction({ method, path, segments })` for every non-GET routed
 * action on a `Ruact::Server` controller. The returned callable targets the
 * REAL Rails route + verb (e.g. `POST /posts`, `PUT /posts/:id`), interpolating
 * dynamic path segments by name from the single call argument, and follows a
 * Bucket-2 `{ "$redirect": "<path>" }` response client-side.
 *
 * Shares the same intersection call-signature contract as {@link _makeRef} so
 * `<form action={createPost}>` and `useActionState` keep type-checking.
 */
export function _makeServerFunction(descriptor: {
  method: string;
  path: string;
  segments?: string[];
}): ((
  arg1?: Record<string, unknown> | RuactFormData,
  arg2?: RuactFormData | Record<string, unknown>,
) => Promise<unknown>) &
  ((formData: RuactFormData) => Promise<void>);

/**
 * Story 9.5 — the read-side (query) accessor. The codegen emits
 * `_makeQuery({ path, kind: "query" })` for every method on a mounted
 * `Ruact::Query` subclass. The returned callable issues a GET to the named
 * query route (`GET /q/<jsId>`), serializing `params` into the query string
 * (FR88: string / number / boolean / null only). Reads are CSRF-free: no
 * body, no `X-CSRF-Token`.
 *
 * Usually consumed through {@link useQuery}, but callable directly in
 * imperative code. The emitted module narrows the param surface per query
 * (`() => Promise<unknown>` when the Ruby method declares no kwargs;
 * `(params: Record<string, unknown>) => Promise<unknown>` when it does).
 */
export function _makeQuery(descriptor: {
  path: string;
  kind?: string;
}): (params?: Record<string, unknown>) => Promise<unknown>;

/**
 * Story 9.5 — React hook for reading a server query. Pass a query reference
 * (the codegen-emitted `_makeQuery` accessor) and optional params; issues
 * `GET /q/<jsId>` on mount (and whenever the serialized params change) and
 * returns `{ data, loading, error }`. `loading` is true until the first
 * resolution; `error` carries the structured {@link RuactActionError} on
 * failure. A superseded in-flight response is dropped.
 *
 * Story 9.6 — identical concurrent calls (same reference + same params,
 * order-independent) share ONE in-flight request. Dedup is in-flight only:
 * once a request settles the shared entry is dropped, so a fresh mount
 * refetches (no TTL cache, no stale-while-revalidate).
 */
export function useQuery<T = unknown>(
  reference: (params?: Record<string, unknown>) => Promise<unknown>,
  params?: Record<string, unknown>,
): { data: T | undefined; loading: boolean; error: unknown };

/**
 * Story 8.2 — issues a Flight refetch of the supplied path (or the
 * current URL when omitted) and swaps the React tree in place. Mirrors
 * Next.js' `revalidatePath` ergonomic: call it after a server action
 * settles when local React state is not enough to reflect the server
 * mutation.
 *
 * Requires the ruact router to be installed (`setupRouter()` publishes
 * `globalThis.__ruact_revalidate`). Throws a descriptive error when
 * called without an installed router so the failure mode is loud rather
 * than a silent no-op.
 */
export function revalidate(path?: string): Promise<void>;

/** Numeric sentinel downstream tooling can read to confirm the real
 * runtime is in place (the Story 8.0a placeholder exported
 * `__PLACEHOLDER__: true`; that export is removed in Story 8.1). */
export const __RUNTIME_VERSION__: number;

/**
 * Re-run-5 (2026-05-15) — app-wide runtime configuration. Hosts in
 * API mode (no CSRF meta tag) call this once at boot to register a
 * default-headers function that supplies the `Authorization: Bearer …`
 * (or similar) header on every server-function call.
 *
 * `defaultHeaders` accepts:
 *   - a plain object → merged on every call
 *   - a `() => object` function → called on every call (for tokens
 *     that may refresh at runtime)
 *   - `null` → clears any previously-registered default
 *
 * The gem's own headers (`Accept`, `Content-Type`, `X-CSRF-Token`)
 * win over `defaultHeaders` — CSRF cannot be silently overridden.
 */
export function configureRuactRuntime(options: {
  defaultHeaders?: Record<string, string> | (() => Record<string, string>) | null;
}): void;

/**
 * Re-run-4 (2026-05-15) — structured error thrown for 4xx/5xx responses.
 * Callers can branch on `status` and inspect `body` (already
 * JSON-decoded if the server's Content-Type indicated JSON) instead
 * of scraping the `message` string.
 */
export class RuactActionError extends Error {
  readonly actionName: string;
  readonly status: number;
  readonly body: unknown;
  readonly response: RuactResponse;
}
