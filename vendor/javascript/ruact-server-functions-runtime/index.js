// Story 8.1 — real server-functions runtime.
//
// Replaces the Story 8.0a placeholder. Each export of the generated module
// `app/javascript/.ruact/server-functions.ts` calls `_makeRef("<symbol>")`
// and gets back a function that, when invoked, POSTs to
// `/__ruact/fn/<symbol>` with the args serialized as JSON or FormData.
//
// Wire contract (locked by Story 8.0 ADR Decision-log clarification of
// 2026-05-13, items 2–3): POST for everything (actions AND queries),
// request body carries the args, response is JSON. CSRF symmetric — the
// runtime forwards the `<meta name="csrf-token">` value as `X-CSRF-Token`
// if the meta tag is present in the document (the gem does not impose its
// own CSRF; the host's `protect_from_forgery` is what enforces).
//
// The `_makeRef` export surface and the `"ruact/server-functions-runtime"`
// import path are part of the locked API — do NOT change without coordinated
// codegen + Vite-plugin updates.

const RUNTIME_VERSION = 1;

/**
 * Returns a callable accessor for a server function registered with the
 * given Ruby symbol name. The accessor, when invoked, POSTs the args to
 * `/__ruact/fn/${name}` and resolves with the response (JSON-decoded for
 * application/json responses, text for everything else).
 *
 * The argument is type-checked at call time:
 *   - `undefined` / `null` / plain object → `Content-Type: application/json`,
 *     body = `JSON.stringify(args ?? {})`
 *   - `FormData` → multipart/form-data, body = the FormData (the browser
 *     sets the boundary header automatically)
 *
 * @param {string} name
 * @returns {(args?: Record<string, unknown> | FormData) => Promise<unknown>}
 */
export function _makeRef(name) {
  return function ruactServerFunctionCall(args) {
    return ruactPost(name, args);
  };
}

export const __RUNTIME_VERSION__ = RUNTIME_VERSION;

// Exported for tests; intentionally NOT part of the public API surface
// the codegen consumes. The vitest suite stubs `globalThis.fetch` and
// asserts the request shape — exporting these helpers keeps the tests
// honest without leaking surface to host apps.
export const __internals = {
  buildFetchInit,
  resolveCsrfToken,
  parseResponse,
};

async function ruactPost(name, args) {
  const url = `/__ruact/fn/${name}`;
  const init = buildFetchInit(args);
  let response;
  try {
    response = await fetch(url, init);
  } catch (err) {
    throw new Error(
      `ruact action :${name} request failed: ${err?.message ?? err}`,
    );
  }
  if (!response.ok) {
    const body = await safeReadText(response);
    throw new Error(
      `ruact action :${name} failed: ${response.status} ${body}`,
    );
  }
  return parseResponse(response);
}

function buildFetchInit(args) {
  // Re-run-2 (2026-05-14) — `Accept: application/json` so the host's
  // `respond_to` / `before_action` / `rescue_from` logic sees a JSON
  // request format. Without it, Rails' default for a POST to an HTML
  // controller would select the HTML branch — surprising in actions
  // expected to return structured JSON.
  const headers = { Accept: "application/json" };
  const csrf = resolveCsrfToken();
  if (csrf) headers["X-CSRF-Token"] = csrf;

  let body;
  if (typeof FormData !== "undefined" && args instanceof FormData) {
    // Let the browser set the `Content-Type: multipart/form-data; boundary=...`
    // header — don't set it manually.
    body = args;
  } else {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(args ?? {});
  }

  return {
    method: "POST",
    credentials: "same-origin",
    headers,
    body,
  };
}

function resolveCsrfToken() {
  if (typeof document === "undefined") return null;
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta?.getAttribute("content") || null;
}

async function parseResponse(response) {
  // Re-run-2 (2026-05-14) — read the response as TEXT first, then attempt
  // JSON parse if the body is non-empty AND the Content-Type indicates
  // JSON. This handles ALL empty-body cases (`head :no_content` (204),
  // `head :ok` (200 + empty body), `head :reset_content` (205), etc.)
  // uniformly: empty body → null, regardless of Content-Type. Earlier
  // versions parsed JSON eagerly and failed `SyntaxError` on these.
  const text = await response.text();
  if (text.length === 0) return null;
  const contentType = response.headers.get("Content-Type") || "";
  if (contentType.includes("application/json")) {
    return JSON.parse(text);
  }
  return text;
}

async function safeReadText(response) {
  try {
    return await response.text();
  } catch {
    return "<unreadable body>";
  }
}
