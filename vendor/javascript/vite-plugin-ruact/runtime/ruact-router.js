/**
 * RSC client-side router.
 *
 * Intercepts same-origin <a> clicks and <form> submits, fetches the Flight
 * payload for the new URL via ReadableStream (incremental), and:
 *   1. Calls onNavigate(tree) as soon as row 0 arrives (shows Suspense fallback)
 *   2. Resolves deferred Suspense rows as they stream in (swaps in actual content)
 *
 * Also handles popstate for browser back/forward.
 */

import {
  parseLine,
  buildTreeFromRows,
  buildTree,
  resolvePendingChunk,
  clearPendingChunks,
} from "./flight-client.js";

let _onNavigate     = null;
let _moduleRegistry = null;
let _onError        = null;
let _currentAbort   = null;

/**
 * @param {object}   opts
 * @param {function} opts.onNavigate     - called with the new React element tree
 * @param {object}   opts.moduleRegistry - passed through to flight-client
 * @param {function} [opts.onError]      - called with an Error when navigation fails
 */
export function setupRouter({ onNavigate, moduleRegistry, onError = null }) {
  _onNavigate     = onNavigate;
  _moduleRegistry = moduleRegistry;
  _onError        = onError;

  document.addEventListener("click",  handleClick,  { capture: true });
  document.addEventListener("submit", handleSubmit, { capture: true });
  window.addEventListener("popstate", handlePopstate);

  // Story 8.2 — publish the revalidate handle the runtime helper reads.
  // `push: false` so a revalidate does NOT add a history entry —
  // semantically it's a refetch-in-place, not a navigation.
  // `scroll: false` keeps the viewport stable after the React tree swap.
  // `throwOnError: true` (Story 8.2 review patch R7, 2026-05-17) makes
  // `await revalidate()` reject on a failed Flight fetch — the
  // default navigate() path swallows-and-forwards to onError, which is
  // what link clicks and form submits want, but a programmatic
  // `revalidate()` caller HAS to be able to branch on success vs.
  // failure.
  globalThis.__ruact_revalidate = (target) =>
    navigate(target ?? location.pathname + location.search, {
      push: false,
      scroll: false,
      throwOnError: true,
    });
}

export function teardownRouter() {
  document.removeEventListener("click",  handleClick,  { capture: true });
  document.removeEventListener("submit", handleSubmit, { capture: true });
  window.removeEventListener("popstate", handlePopstate);
  _onNavigate     = null;
  _moduleRegistry = null;
  _onError        = null;
  _currentAbort   = null;
  // Story 8.2 — tear down the revalidate handle so a subsequent
  // setupRouter()-less code path (e.g., SSR) fails LOUDLY at the first
  // revalidate() call instead of using a stale handle.
  if (globalThis.__ruact_revalidate) delete globalThis.__ruact_revalidate;
}

// ---------------------------------------------------------------------------
// Link interception
// ---------------------------------------------------------------------------

export function shouldIntercept(anchor) {
  if (!anchor) return false;
  if (anchor.getAttribute("data-ruact") === "false") return false;
  if (anchor.target && anchor.target !== "_self") return false;
  if (anchor.hasAttribute("download")) return false;

  const href = anchor.getAttribute("href") || "";
  if (!href || href.startsWith("#")) return false;
  if (/^(mailto:|tel:|javascript:)/i.test(href)) return false;

  try {
    const url = new URL(href, location.href);
    if (url.origin !== location.origin) return false;
  } catch {
    return false;
  }

  return true;
}

function handleClick(event) {
  if (event.defaultPrevented) return;
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  if (event.button !== 0) return;

  const anchor = event.target.closest("a[href]");
  if (!shouldIntercept(anchor)) return;

  event.preventDefault();

  const url = new URL(anchor.getAttribute("href"), location.href);
  navigate(url.pathname + url.search + url.hash);
}

// ---------------------------------------------------------------------------
// Form interception
// ---------------------------------------------------------------------------

/**
 * Returns true if the form submission should be intercepted by the RSC router.
 *
 * Story 8.2 review patches R5 + R6 (2026-05-17) + R15 (2026-05-17):
 *   - R5: `<button formAction=...>` overrides the form's `action`. Empty
 *     `formaction=""` is a VALID override (submit to current URL); only
 *     the absence of the attribute falls through to `form.action`.
 *   - R6: `<form method="dialog">` AND `<button formmethod="dialog">`
 *     are browser primitives that close the enclosing `<dialog>` — the
 *     router has no business fetching anything for either.
 *   - R15: `<button formtarget="_blank">` overrides the form's `target`.
 *     Effective method/target/action are resolved BEFORE the guard so
 *     every native override participates in the interception decision.
 */
export function shouldInterceptForm(form, submitter = null) {
  if (!form || form.tagName !== "FORM") return false;
  if (form.getAttribute("data-ruact") === "false") return false;

  // R15: resolve effective method/target/action HONORING submitter
  // overrides BEFORE the guard, so dialog/cross-origin checks see what
  // the browser would actually use.
  const { method, target, action, actionExplicitlyEmpty } = _effectiveSubmission(form, submitter);

  // R6 + R15: method="dialog" — either at the form level or via the
  // submitter's `formmethod` — closes the enclosing <dialog>; don't
  // fetch anything.
  if (method === "dialog") return false;

  // R15: native target check uses the effective target so a
  // `<button formtarget="_blank">` opt-out is honored.
  if (target && target !== "_self") return false;

  // R5 + R15: empty-string action ("") is a VALID native override
  // meaning "submit to current URL" — only the missing-attribute path
  // falls through to "submit to current URL" via the same default. A
  // truly missing action (null + no submitter override) also means
  // current-URL, so both paths return true here.
  if (action === "" || action == null) return true;
  if (actionExplicitlyEmpty) return true;

  try {
    const url = new URL(action, location.href);
    if (url.origin !== location.origin) return false;
  } catch {
    return false;
  }

  return true;
}

/**
 * R15: resolves the EFFECTIVE method / target / action of a submit
 * event, honoring submitter overrides per the browser-native algorithm.
 * Centralized so `shouldInterceptForm` and `_submitForm` see the same
 * resolution — pre-R15 they computed each piece in separate places and
 * drifted (e.g. submitter `formmethod` was used at request time but
 * not at guard time).
 *
 * `actionExplicitlyEmpty` distinguishes `formaction=""` (a valid native
 * override) from "submitter present but no formaction attribute" (fall
 * through to `form.action`). The empty-string override means "submit to
 * the current URL" regardless of what the form's `action` says.
 */
function _effectiveSubmission(form, submitter) {
  const hasAttr = (el, name) =>
    el && typeof el.hasAttribute === "function" && el.hasAttribute(name);

  const submitterHasAction = hasAttr(submitter, "formAction");
  const submitterHasMethod = hasAttr(submitter, "formMethod");
  const submitterHasTarget = hasAttr(submitter, "formTarget");
  const submitterAction = submitterHasAction ? submitter.getAttribute("formAction") : null;
  const submitterMethod = submitterHasMethod ? submitter.getAttribute("formMethod") : null;
  const submitterTarget = submitterHasTarget ? submitter.getAttribute("formTarget") : null;

  // R15: empty `formaction=""` IS a valid override (submit to current
  // URL). Use the `hasAttribute` check to disambiguate "explicit empty"
  // from "absent attribute" — only the latter falls through to
  // `form.action`.
  const action = submitterHasAction ? submitterAction : form.getAttribute("action");
  const actionExplicitlyEmpty = submitterHasAction && submitterAction === "";

  // R18 (2026-05-17): same fix for `formtarget`. A present-but-empty
  // submitter `formtarget=""` is a VALID override that resets the
  // effective target to the default (same-window, equivalent to `_self`).
  // Previously the `||` fallthrough discarded the empty submitter
  // override and let the form-level `target="_blank"` win, causing the
  // router to skip an opt-in same-window submission.
  // `formmethod=""` follows the same rule for consistency.
  const target = submitterHasTarget ? submitterTarget : form.getAttribute("target");
  const method = submitterHasMethod
    ? submitterMethod
    : form.getAttribute("method");

  return {
    method: (method || "get").toLowerCase(),
    target: target || null, // empty string normalizes to null (default same-window)
    action,
    actionExplicitlyEmpty,
  };
}

function handleSubmit(event) {
  if (event.defaultPrevented) return;

  const form = event.target;
  // R5: pass `event.submitter` so the guard inspects the button's
  // `formAction` override when one was clicked. React 19 sets
  // `event.submitter.formAction` to its `javascript:throw` placeholder
  // for function-action buttons; the URL-origin check in
  // `shouldInterceptForm` rejects it cleanly, preventing a double-fire
  // when the form's own `action` is still a parseable same-origin URL.
  if (!shouldInterceptForm(form, event.submitter)) return;

  event.preventDefault();
  // R11: forward the submitter to `_submitForm` so the actual fetch
  // honors the submitter's `formaction` / `formmethod` overrides AND
  // includes the submitter's name/value in the FormData payload — the
  // browser's default form-submit behaviour. Without this, a same-
  // origin `<button formaction="/other">` would pass interception but
  // the router would still fetch the form's own `action`, and a
  // `<button name="op" value="delete">` clicked submitter would be
  // dropped from the body.
  _submitForm(form, event.submitter);
}

// R11 + R15: resolves the EFFECTIVE submission action/method for the
// REQUEST (separate from `_effectiveSubmission` which is the resolver
// used by `shouldInterceptForm`). The two are aligned but the request
// resolver normalizes against `form.action` (absolute URL from the IDL
// property when both submitter and attribute are absent) and uppercases
// the method for the dispatch switch.
function _resolveSubmission(form, submitter) {
  const eff = _effectiveSubmission(form, submitter);
  // R15: an explicit empty action ("") means "submit to the current
  // URL" — translate to location.href so the fetch has a valid URL.
  // Same for an absent action: the IDL property `form.action` reflects
  // the page URL when the attribute is missing.
  const action =
    eff.action == null
      ? form.action || location.href
      : eff.action === ""
        ? location.href
        : eff.action;
  return {
    action,
    method: eff.method.toUpperCase(),
  };
}

// R11: builds the FormData payload that mirrors what a native browser
// submit would send. `new FormData(form, submitter)` is the second-
// argument shape standardised in 2021 — it includes the submitter's
// `name=value` pair so a `<button name="op" value="delete">` round-
// trips correctly. Falls back to single-arg construction if the
// browser doesn't accept the submitter parameter (older test
// environments / jsdom < 22).
function _buildFormData(form, submitter) {
  try {
    return submitter ? new FormData(form, submitter) : new FormData(form);
  } catch {
    return new FormData(form);
  }
}

async function _submitForm(form, submitter = null) {
  clearPendingChunks();

  // R11: resolve the effective action and method from the submitter's
  // overrides before falling back to the form's attributes. The
  // previous implementation always read `form.action` and the form's
  // `method`, ignoring `<button formaction>` / `<button formmethod>`.
  const { action, method: htmlMethod } = _resolveSubmission(form, submitter);

  if (htmlMethod === "GET") {
    // Serialize form fields to query string and navigate as GET.
    // R11: also pull the submitter's name/value into the query string
    // via `new FormData(form, submitter)` so the navigated URL
    // matches what a native browser submit would produce.
    const url = new URL(action, location.href);
    _buildFormData(form, submitter).forEach((v, k) =>
      url.searchParams.append(k, String(v)),
    );
    navigate(url.pathname + url.search + url.hash);
    return;
  }

  // POST/PUT/PATCH/DELETE: always send as POST.
  // Rails _method hidden field is included in FormData automatically;
  // Rack::MethodOverride reads it and routes to the correct action.
  _currentAbort?.abort();
  const controller = (_currentAbort = new AbortController());

  const headers = { Accept: "text/x-component", "Ruact-Request": "1" };
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
  if (csrfToken) headers["X-CSRF-Token"] = csrfToken;

  try {
    const response = await fetch(action, {
      method:  "POST",
      // R11: include the submitter's name/value in the payload (browser
      // default for native submits). Single-arg fallback if the
      // environment doesn't accept the submitter parameter.
      body:    _buildFormData(form, submitter),
      headers,
      signal:  controller.signal,
    });
    await _processFlightResponse(response, { push: true, targetUrl: action });
  } catch (err) {
    if (err.name === "AbortError") return;
    console.error("[ruact-router] Form submission error:", err);
    _onError?.(err);
  }
}

// ---------------------------------------------------------------------------
// Popstate (Back / Forward)
// ---------------------------------------------------------------------------

function handlePopstate() {
  navigate(location.pathname + location.search + location.hash, { push: false, scroll: false });
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

/**
 * Story 8.2 review patch R7 (2026-05-17) — `throwOnError` opts a caller
 * out of the swallow-and-forward error mode. The default (false) is the
 * Phase 1 contract: navigation errors are logged + forwarded to the
 * onError callback, then the promise resolves. The opt-in (true) is
 * used by the `revalidate()` runtime helper so `await revalidate()`
 * REJECTS on a failed Flight fetch — without this, callers cannot
 * branch on success vs. failure of a programmatic refetch.
 */
async function navigate(url, { push = true, scroll = true, throwOnError = false } = {}) {
  // Clear stale lazy refs from any previous streaming navigation
  clearPendingChunks();

  // Abort any in-flight fetch so we don't apply a stale response
  _currentAbort?.abort();
  const controller = (_currentAbort = new AbortController());

  try {
    const response = await fetch(url, {
      headers: { Accept: "text/x-component", "Ruact-Request": "1" },
      signal:  controller.signal,
    });
    await _processFlightResponse(response, {
      push,
      targetUrl: url,
      scroll,
      throwOnError,
    });
  } catch (err) {
    if (err.name === "AbortError") {
      if (throwOnError) throw err;
      return;
    }
    console.error("[ruact-router] Navigation error:", err);
    _onError?.(err);
    if (throwOnError) throw err;
  }
}

// ---------------------------------------------------------------------------
// Shared Flight response processor (used by navigate + _submitForm)
// ---------------------------------------------------------------------------

async function _processFlightResponse(response, { push, targetUrl, scroll = true, throwOnError = false }) {
  if (!response.ok) {
    const msg = `[ruact] Request failed: ${response.status} ${response.statusText}`;
    console.error(msg);
    const err = new Error(msg);
    _onError?.(err);
    // R7: surface non-ok responses to revalidate()'s awaiter so callers
    // can branch on failure instead of seeing a silently-resolved promise.
    if (throwOnError) throw err;
    return;
  }

  // Use final URL after any redirects (response.url is the resolved URL).
  const finalPath = response.url
    ? (() => { const u = new URL(response.url); return u.pathname + u.search + u.hash; })()
    : targetUrl;

  const rows           = new Map();
  let   initialTreeSet = false;
  let   redirected     = false;

  const processLine = (line) => {
    const parsed = parseLine(line);
    if (!parsed) return;

    rows.set(parsed.id, parsed.row);

    if (!initialTreeSet && rows.has(0)) {
      const rootRow = rows.get(0);
      // Flight redirect instruction — delegate to navigate() and bail out.
      if (rootRow.kind === "model" && rootRow.value != null && rootRow.value.redirectUrl) {
        // Validate redirect is same-origin before following
        try {
          const rurl = new URL(rootRow.value.redirectUrl, location.href);
          if (rurl.origin !== location.origin) return;
        } catch { return; }
        redirected = true;
        navigate(rootRow.value.redirectUrl, { push: rootRow.value.redirectType !== "replace" });
        return;
      }
      // Normal case: build tree and render immediately.
      const tree = buildTreeFromRows(rows, _moduleRegistry);
      if (push) history.pushState(null, "", finalPath);
      _onNavigate(tree);
      if (scroll) window.scrollTo(0, 0);
      initialTreeSet = true;
      return;
    }

    if (initialTreeSet && parsed.id !== 0) {
      if (parsed.row.kind === "error") {
        // Deferred error row — propagate via onError callback
        _onError?.(new Error(`[ruact] Server error: ${parsed.row.message}`));
        return;
      }
      if (parsed.row.kind === "model") {
        // Deferred content row — resolve pending lazy chunk.
        const element = buildTree(parsed.row.value, rows, _moduleRegistry);
        resolvePendingChunk(parsed.id, element);
      }
    }
  };

  const reader  = response.body.getReader();
  const decoder = new TextDecoder();
  let   buffer  = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });

    let newlineIdx;
    while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
      processLine(buffer.slice(0, newlineIdx));
      buffer = buffer.slice(newlineIdx + 1);
    }
  }

  // Handle any remaining content without a trailing newline
  if (buffer.trim()) processLine(buffer);

  // Fallback: if row 0 never triggered (shouldn't happen with valid server)
  if (!initialTreeSet && !redirected && rows.has(0)) {
    const tree = buildTreeFromRows(rows, _moduleRegistry);
    if (push) history.pushState(null, "", finalPath);
    _onNavigate(tree);
    if (scroll) window.scrollTo(0, 0);
  }
}
