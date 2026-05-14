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
 * Returns a callable accessor for a server function registered with the
 * given Ruby symbol name. The accessor, when invoked, POSTs the args to
 * `/__ruact/fn/${name}`.
 */
export function _makeRef(
  name: string,
): (args?: Record<string, unknown> | FormData) => Promise<unknown>;

/** Numeric sentinel downstream tooling can read to confirm the real
 * runtime is in place (the Story 8.0a placeholder exported
 * `__PLACEHOLDER__: true`; that export is removed in Story 8.1). */
export const __RUNTIME_VERSION__: number;
