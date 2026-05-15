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
 * Re-run-4 (2026-05-15) — structured error class for 4xx/5xx responses.
 *
 * Pre-batch the runtime threw a plain `Error` whose message embedded
 * the status + body. Callers wanting to branch on status (`error.status
 * === 422`) or parse the body had to scrape the message — fragile and
 * not the AC4/AC10 contract. `RuactActionError` exposes the structured
 * fields directly while still carrying a human-readable `message`.
 *
 * The constructor accepts the parsed body (already JSON-decoded if the
 * Content-Type said so) so callers don't re-parse.
 */
export class RuactActionError extends Error {
  constructor({ name, status, body, response }) {
    const bodyForMessage = typeof body === "string" ? body : JSON.stringify(body);
    super(`ruact action :${name} failed: ${status} ${bodyForMessage}`);
    this.name = "RuactActionError";
    this.actionName = name;
    this.status = status;
    this.body = body;
    this.response = response;
  }
}

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
  // Re-run-3 (2026-05-15) — `encodeURIComponent(name)` so a stray `/`,
  // `?`, or `#` in a name (only reachable through direct/buggy
  // `_makeRef` calls — the gem-side route constraint and the codegen
  // validator both refuse non-identifier characters) cannot rewrite the
  // path or hijack the query/fragment of the request URL.
  const url = `/__ruact/fn/${encodeURIComponent(name)}`;
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
    // Re-run-4 (2026-05-15) — throw a structured `RuactActionError` so
    // callers can branch on `status` / `body` instead of scraping the
    // message string. We parse the body the same way as a successful
    // response (JSON when CT says so, otherwise text) so the shape is
    // consistent across the success and failure paths.
    const body = await safeParseBody(response);
    throw new RuactActionError({ name, status: response.status, body, response });
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
  // Re-run-3 (2026-05-15) — Content-Type matching is case-insensitive
  // per RFC 9110 §8.3.1 (`Application/JSON` and `application/json` are
  // the same media type).
  // Re-run-4 (2026-05-15) — also accept structured-syntax-suffix JSON
  // types per RFC 6838 §4.2.8: `application/problem+json`,
  // `application/vnd.api+json`, etc. The regex matches the literal
  // `application/json` and any `+json` suffix.
  const contentType = (response.headers.get("Content-Type") || "").toLowerCase();
  if (/^application\/(json|.*\+json)\b/.test(contentType)) {
    return JSON.parse(text);
  }
  return text;
}

async function safeParseBody(response) {
  // Mirror `parseResponse`'s logic but never let a parse failure crash
  // the error path — if the JSON parse fails we fall back to the raw
  // text. The error path is already a sad path; surfacing a second
  // exception inside it would hide the real failure from the caller.
  let text;
  try {
    text = await response.text();
  } catch {
    return "<unreadable body>";
  }
  if (text.length === 0) return null;
  const contentType = (response.headers.get("Content-Type") || "").toLowerCase();
  if (/^application\/(json|.*\+json)\b/.test(contentType)) {
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }
  return text;
}
