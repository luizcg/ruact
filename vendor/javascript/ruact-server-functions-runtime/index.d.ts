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
 */
export function _makeRef(
  name: string,
): (args?: Record<string, unknown> | RuactFormData) => Promise<unknown>;

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
