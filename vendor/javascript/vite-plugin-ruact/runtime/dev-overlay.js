// Story 19-1 (ADR D5) — in development, a `<Suspense>` whose content failed on
// the server is shown over the page: what failed, and where in the templates.
// Production shows nothing of the error; the boundary keeps its fallback.
//
// The boundary hands the error to the handler ./suspense-boundary.js was given
// (the bootstrap installs one before the first render, the router keeps it).
// React's development client rebuilds the server's backtrace into the error's
// `stack`.

const OVERLAY_ID = "ruact-dev-overlay";

/** Shows +error+ over the page; a click closes it. */
export function showDevOverlay(error, doc = globalThis.document) {
  const cause = error?.cause ?? error;
  let overlay = doc.getElementById(OVERLAY_ID);
  if (!overlay) {
    overlay = doc.createElement("div");
    overlay.id = OVERLAY_ID;
    overlay.setAttribute("role", "alertdialog");
    overlay.setAttribute("aria-label", "A <Suspense> failed on the server");
    overlay.style.cssText =
      "position:fixed;inset:0;z-index:2147483647;background:rgba(24,6,6,.94);color:#fff;" +
      "font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;padding:32px;overflow:auto;" +
      "white-space:pre-wrap;cursor:pointer";
    overlay.addEventListener("click", () => overlay.remove());
    (doc.body ?? doc.documentElement).appendChild(overlay);
  }
  const title = doc.createElement("h2");
  title.textContent = "[ruact] A <Suspense> failed on the server";
  const message = doc.createElement("p");
  message.dataset.overlayMessage = "";
  message.textContent = cause?.message ?? String(cause);
  const stack = doc.createElement("pre");
  stack.dataset.overlayStack = "";
  stack.textContent = cause?.stack ?? "";
  const hint = doc.createElement("p");
  hint.textContent = "Development only. Click to close.";
  overlay.replaceChildren(title, message, stack, hint);
}
