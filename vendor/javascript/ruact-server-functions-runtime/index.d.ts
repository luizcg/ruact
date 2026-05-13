// Story 8.0a — TypeScript declarations for the placeholder server-functions
// runtime. Mirrors the JS exports in `index.js` so the generated module's
// `import { _makeRef } from "ruact/server-functions-runtime"` resolves under
// `tsc --noEmit` (AC10's import guarantee).
//
// Story 8.1 replaces `index.js` with the real implementation; the signature
// here may need to evolve in lockstep (e.g., if Story 8.2 decides to widen
// the action signature to accept `FormData`).

/**
 * Returns a callable accessor for a server function registered with the given
 * Ruby symbol name. The current placeholder rejects on call with a "Story 8.1
 * not installed yet" error; the real implementation will POST to
 * `/__ruact/fn/:name` with CSRF + multipart support.
 */
export function _makeRef(
  name: string,
): (args?: Record<string, unknown>) => Promise<unknown>;

/**
 * Sentinel that downstream tooling can read to confirm the placeholder is in
 * effect (rather than the real Story 8.1 runtime).
 */
export const __PLACEHOLDER__: true;
