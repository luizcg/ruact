// AUTO-GENERATED contract surface for Story 8.0a.
//
// This is a PLACEHOLDER runtime. It exists so:
//   - `import { _makeRef } from "ruact/server-functions-runtime"` resolves at
//     build time (the Vite plugin aliases the import path to this file).
//   - `tsc --noEmit` accepts the import.
//   - Calling a generated server-function (`createPost({...})`) fails LOUDLY
//     at call time rather than silently doing nothing — so the absence of a
//     real Story 8.1 implementation cannot ship to production by accident.
//
// Story 8.1 (`ruact_action`) REPLACES this file with the real implementation:
//   POST to `/__ruact/fn/:name` with CSRF token, multipart/formdata support,
//   Suspense-aware promise handling. The export surface (`_makeRef`) and the
//   import path (`"ruact/server-functions-runtime"`) are part of the locked
//   API — DO NOT change without coordinated codegen + Vite-plugin updates.

const NOT_IMPLEMENTED_MESSAGE =
  "ruact: server functions runtime not implemented yet — install Story 8.1";

/**
 * Returns a callable that, when invoked, rejects with a Story-8.1-not-yet-here
 * error. The argument `name` is the Ruby symbol (snake_case) the generated
 * accessor was registered as; the real Story 8.1 runtime will POST to
 * `/__ruact/fn/:name` using this value.
 *
 * @param {string} name
 * @returns {(...args: unknown[]) => Promise<unknown>}
 */
export function _makeRef(name) {
  return function ruactServerFunctionPlaceholder() {
    return Promise.reject(
      new Error(`${NOT_IMPLEMENTED_MESSAGE} (called: ${name})`),
    );
  };
}

export const __PLACEHOLDER__ = true;
