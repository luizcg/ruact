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
 * Re-run-3 (2026-05-15) — local alias for the FormData type that does
 * NOT require `lib: ["dom"]` to be in the consumer's tsconfig. In DOM
 * targets, `globalThis.FormData` is the real class and the union widens
 * to accept it; in non-DOM targets (`lib: ["es2022"]`-only Node, Deno,
 * SSR-only projects), the conditional resolves to a minimal structural
 * type so the declaration still compiles cleanly under `tsc --noEmit`.
 */
type RuactFormData = typeof globalThis extends { FormData: infer F }
  ? F
  : { append(name: string, value: unknown): void };

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
