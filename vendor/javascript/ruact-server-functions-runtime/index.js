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

// Re-run-5 (2026-05-15) — module-level runtime configuration. Hosts
// in API mode (no session cookie / no CSRF meta tag) need a way to
// inject auth headers (`Authorization: Bearer …`) on every call.
// `_makeRef`'s signature is locked by the codegen so we don't widen
// it; instead, hosts call `configureRuactRuntime` once at app boot
// to register a headers-producing function. The function runs on
// every fetch so dynamic tokens (refreshed at runtime) are picked up.
const runtimeOptions = {
  defaultHeaders: null,
};
export function configureRuactRuntime(options) {
  if (options && Object.prototype.hasOwnProperty.call(options, "defaultHeaders")) {
    const value = options.defaultHeaders;
    if (value === null || typeof value === "function" || (typeof value === "object" && value !== null)) {
      runtimeOptions.defaultHeaders = value;
    } else {
      throw new TypeError(
        "configureRuactRuntime: defaultHeaders must be a plain object or a () => object function",
      );
    }
  }
}

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
 * Story 8.2 — the returned function accepts up to TWO positional
 * arguments to support React 19's `useActionState` shape:
 *
 *   useActionState(action, initialState)
 *
 * calls `action(prevState, formData)` on every submit. `_makeRef` picks
 * the FormData-typed candidate from the call and discards the prevState
 * argument silently — prev-state is a client-only concern, never
 * transmitted to the server. The single-arg shape (`fn(args)` from event
 * handlers; `<form action={fn}>` passing FormData directly) is preserved.
 *
 * Argument shape selection rules (first match wins):
 *   - 0 args                                     → JSON body, `{}`
 *   - 1 arg, FormData                            → multipart
 *   - 1 arg, plain object / null / undefined     → JSON body
 *   - 2 args, FormData in either slot            → multipart (FormData wins;
 *                                                  the other arg is discarded)
 *   - 2 args, neither FormData                   → JSON body of the SECOND arg
 *                                                  (the `useActionState` payload
 *                                                  slot); first arg discarded
 *                                                  as prev-state
 *   - 3+ args                                    → TypeError
 *
 * @param {string} name
 * @returns {(arg1?: Record<string, unknown> | FormData, arg2?: FormData | Record<string, unknown>) => Promise<unknown>}
 */
export function _makeRef(name) {
  return function ruactServerFunctionCall(...callArgs) {
    if (callArgs.length > 2) {
      throw new TypeError(
        `ruact action :${name} called with ${callArgs.length} arguments — ` +
          "expected 0, 1, or 2 (the useActionState shape)",
      );
    }
    return ruactPost(name, pickWirePayload(callArgs));
  };
}

/**
 * Story 9.3 — the route-driven (v2) accessor. The codegen emits
 * `_makeServerFunction({ method, path, segments })` for every non-GET routed
 * action on a `Ruact::Server` controller (instead of v1's `_makeRef("<sym>")`).
 * The returned callable targets the REAL Rails route + verb (e.g. `POST /posts`,
 * `PUT /posts/:id`) rather than the v1 synthetic `POST /__ruact/fn/:name`.
 *
 * It shares the exact fetch core (`ruactInvoke`) with `_makeRef` — FormData
 * branching, CSRF meta injection, text-first parsing, `RuactActionError`,
 * `redirect: "error"` — so all the salvaged 8.1/8.2 behaviors are preserved.
 * Two additions over v1:
 *   - **Path-param interpolation (D7):** dynamic `:id`-style segments are read
 *     BY NAME from the single call argument (FormData.get / object property) and
 *     substituted into the path; the full argument is still sent as the body
 *     (Rails reads `params[:id]` from the path, ignores the duplicate). The
 *     single-arg shape (8.2 `<form action>` / `useActionState`) is unchanged.
 *   - **`$redirect` follow (9.2 → 9.3):** when the Bucket-2 response is
 *     `{ "$redirect": "<path>" }`, the runtime navigates via the router handoff
 *     (`globalThis.__ruact_navigate`, `window.location.assign` fallback) and
 *     resolves `null`.
 *
 * @param {{ method: string, path: string, segments?: string[] }} descriptor
 * @returns {(arg1?: Record<string, unknown> | FormData, arg2?: FormData | Record<string, unknown>) => Promise<unknown>}
 */
export function _makeServerFunction(descriptor) {
  const { method, path, segments = [] } = descriptor || {};
  return async function ruactServerFunctionCall(...callArgs) {
    if (callArgs.length > 2) {
      throw new TypeError(
        `ruact server function ${method} ${path} called with ${callArgs.length} arguments — ` +
          "expected 0, 1, or 2 (the useActionState shape)",
      );
    }
    const args = pickWirePayload(callArgs);
    const url = interpolatePath(path, segments, args);
    const parsed = await ruactInvoke({ method, url, args, label: path });
    return followRedirectIfPresent(parsed);
  };
}

// Story 8.2 — picks the argument the wire request should serialize from
// `_makeRef`'s call-args, following the rules documented in the JSDoc
// above. Exported through `__internals` for the vitest suite (AC10) — it
// is intentionally NOT part of the public runtime surface.
function pickWirePayload(callArgs) {
  const isFD = (v) => typeof FormData !== "undefined" && v instanceof FormData;
  if (callArgs.length === 0) return undefined;
  if (callArgs.length === 1) return callArgs[0];
  // 2 args. Prefer a FormData candidate regardless of position.
  if (isFD(callArgs[1])) return callArgs[1];
  if (isFD(callArgs[0])) return callArgs[0];
  // Defensive: useActionState's normal payload is in slot 1 (slot 0 is
  // prev-state); echo that ordering for the non-FormData case too. The
  // prevState shape is opaque (any React-state value) — never sent to
  // the server.
  return callArgs[1];
}

export const __RUNTIME_VERSION__ = RUNTIME_VERSION;

/**
 * Story 8.2 — issues a Flight refetch of the supplied path (or the
 * current URL when omitted) and swaps the React tree in place. The
 * runtime side is intentionally thin: it reads a globally-published
 * handle (`globalThis.__ruact_revalidate`) that `ruact-router.js`'s
 * `setupRouter()` registers at app boot, and delegates the actual
 * refetch to the router's existing `navigate()` machinery (push: false,
 * scroll: false — semantically: refetch in place, no history entry).
 *
 * Why globalThis instead of a direct import: the runtime ships inside
 * the gem (`gem/vendor/javascript/...`) and the router lives inside the
 * host app (`app/javascript/ruact-router.js`). Direct imports would
 * couple the two packages and force the router into the gem; the
 * globalThis handoff keeps the runtime portable.
 *
 * Throws when called without an installed router so a misconfigured
 * app fails LOUDLY at the first call rather than silently no-op'ing.
 *
 * @param {string} [path] Optional path to refetch. Defaults to the
 *   current `location.pathname + location.search`.
 * @returns {Promise<void>}
 */
export async function revalidate(path) {
  const handle = typeof globalThis !== "undefined" ? globalThis.__ruact_revalidate : undefined;
  if (typeof handle !== "function") {
    throw new Error(
      "ruact: revalidate() called but no router is installed — wire setupRouter() in your application.jsx",
    );
  }
  const target =
    path != null
      ? path
      : typeof location !== "undefined"
        ? location.pathname + location.search
        : "/";
  return handle(target);
}

// Exported for tests; intentionally NOT part of the public API surface
// the codegen consumes. The vitest suite stubs `globalThis.fetch` and
// asserts the request shape — exporting these helpers keeps the tests
// honest without leaking surface to host apps.
export const __internals = {
  buildFetchInit,
  resolveCsrfToken,
  parseResponse,
  pickWirePayload,
  interpolatePath,
  followRedirectIfPresent,
};

// v1 (Story 8.1) — POST to the synthetic endpoint. A thin wrapper over the
// shared `ruactInvoke` core; the URL, verb, and error label are exactly what
// 8.1 used so the v1 path stays byte-behavior-identical (Story 9.3 AC6).
//
// Re-run-3 (2026-05-15) — `encodeURIComponent(name)` so a stray `/`, `?`, or
// `#` in a name (only reachable through direct/buggy `_makeRef` calls — the
// gem-side route constraint and the codegen validator both refuse
// non-identifier characters) cannot rewrite the path or hijack the
// query/fragment of the request URL.
function ruactPost(name, args) {
  return ruactInvoke({
    method: "POST",
    url: `/__ruact/fn/${encodeURIComponent(name)}`,
    args,
    label: name,
  });
}

// Story 9.3 — the shared fetch core for BOTH v1 (`_makeRef`) and v2
// (`_makeServerFunction`). Extracted verbatim from the original `ruactPost` so
// neither path drifts: same FormData branching, CSRF injection, `redirect:
// "error"`, text-first parsing, and structured `RuactActionError`. The only
// parameters are the verb + URL + the wire payload + a human label for errors.
async function ruactInvoke({ method, url, args, label }) {
  const init = buildFetchInit(args, method);
  let response;
  try {
    response = await fetch(url, init);
  } catch (err) {
    throw new Error(
      `ruact action :${label} request failed: ${err?.message ?? err}`,
    );
  }
  if (!response.ok) {
    // Re-run-4 (2026-05-15) — throw a structured `RuactActionError` so
    // callers can branch on `status` / `body` instead of scraping the
    // message string. We parse the body the same way as a successful
    // response (JSON when CT says so, otherwise text) so the shape is
    // consistent across the success and failure paths.
    const body = await safeParseBody(response);
    throw new RuactActionError({ name: label, status: response.status, body, response });
  }
  return parseResponse(response);
}

// Story 9.3 (D7) — substitute dynamic path segments (`:id`, …) from the single
// call argument. Values are read BY NAME (FormData.get / object property); the
// argument is still sent as the body. A missing required segment fails loudly
// rather than silently POSTing to a malformed URL.
function interpolatePath(path, segments, args) {
  let url = path;
  for (const seg of segments) {
    const value = readSegment(args, seg);
    if (value == null || value === "") {
      throw new TypeError(
        `ruact server function for ${path} requires path segment ":${seg}", ` +
          "but it was missing from the call argument",
      );
    }
    url = url.replace(`:${seg}`, encodeURIComponent(String(value)));
  }
  return url;
}

function readSegment(args, seg) {
  if (typeof FormData !== "undefined" && args instanceof FormData) return args.get(seg);
  if (args && typeof args === "object") return args[seg];
  return undefined;
}

// Story 9.3 (AC8 / D2) — the client half of the `$redirect` contract 9.2
// deferred. A Bucket-2 mutation that `redirect_to`s returns
// `{ "$redirect": "<path>" }`; follow it via the router handoff and resolve
// `null` (consistent with the 204→null contract). Only applied on the v2 path
// — the v1 endpoint never emits `$redirect`, so `_makeRef` is unaffected (AC6).
function followRedirectIfPresent(parsed) {
  if (
    parsed &&
    typeof parsed === "object" &&
    !Array.isArray(parsed) &&
    typeof parsed.$redirect === "string"
  ) {
    navigateTo(parsed.$redirect);
    return null;
  }
  return parsed;
}

function navigateTo(target) {
  const nav = typeof globalThis !== "undefined" ? globalThis.__ruact_navigate : undefined;
  if (typeof nav === "function") {
    nav(target);
    return;
  }
  // No router installed — hard-navigate so the redirect is never silently
  // dropped (mirrors `revalidate()`'s loud-by-default stance, but a redirect
  // CAN fall back to a full page load where a refetch cannot).
  if (typeof window !== "undefined" && window.location && typeof window.location.assign === "function") {
    window.location.assign(target);
  }
}

function buildFetchInit(args, method = "POST") {
  // Re-run-2 (2026-05-14) — `Accept: application/json` so the host's
  // `respond_to` / `before_action` / `rescue_from` logic sees a JSON
  // request format. Without it, Rails' default for a POST to an HTML
  // controller would select the HTML branch — surprising in actions
  // expected to return structured JSON.
  // Re-run-5 — start the headers map with defaultHeaders (so the gem's
  // own keys, set below, OVERRIDE them) and then layer the gem's own
  // keys on top. `Accept`, `Content-Type`, and `X-CSRF-Token` are the
  // gem's responsibility — `configureRuactRuntime({ defaultHeaders })`
  // can't silently downgrade CSRF or swap the response negotiation.
  // Re-run-6 (2026-05-15) — match header names case-insensitively when
  // filtering reserved keys from the caller-provided `defaultHeaders`.
  // HTTP header names are case-insensitive (RFC 9110 §5.1), so a host
  // passing `{ accept: "text/html" }` or `{ "content-type": "..." }`
  // would otherwise survive the gem's own assignment (object keys are
  // case-sensitive in JS) and either downgrade the Accept negotiation
  // or — for the FormData branch — kill the multipart boundary the
  // browser sets automatically.
  const RESERVED = new Set(["accept", "content-type", "x-csrf-token"]);
  const extra = typeof runtimeOptions.defaultHeaders === "function"
    ? runtimeOptions.defaultHeaders()
    : runtimeOptions.defaultHeaders;
  const headers = {};
  if (extra && typeof extra === "object") {
    for (const [key, value] of Object.entries(extra)) {
      if (!RESERVED.has(key.toLowerCase())) headers[key] = value;
    }
  }
  headers.Accept = "application/json";
  const csrf = resolveCsrfToken();
  if (csrf) headers["X-CSRF-Token"] = csrf;

  let body;
  if (typeof FormData !== "undefined" && args instanceof FormData) {
    // Let the browser set the `Content-Type: multipart/form-data; boundary=...`
    // header — don't set it manually. The case-insensitive filter above
    // already stripped any `Content-Type` from defaultHeaders, so the
    // browser is in control here.
    body = args;
  } else {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(args ?? {});
  }

  return {
    method,
    credentials: "same-origin",
    // Re-run-5 (2026-05-15) — `redirect: "error"` so the runtime
    // FAILS LOUDLY when a host `before_action` `redirect_to "/login"`
    // (auth filter) issues a 302. Default fetch follows redirects
    // silently and would resolve with the eventual HTML login page
    // body — masking auth failures from the caller. The structured
    // `RuactActionError` path is the right surface for "not allowed".
    redirect: "error",
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
