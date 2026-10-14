// Story 19-0 — Luiz's question: when a <Suspense> fails on the server, can
// development put the error over the page? The boundary already hands the error
// to the router's `onError`; this draws it.
export function installDevOverlay() {
  return function showError(error) {
    const cause = error?.cause ?? error;
    let overlay = document.getElementById("ruact-dev-overlay");
    if (!overlay) {
      overlay = document.createElement("div");
      overlay.id = "ruact-dev-overlay";
      overlay.setAttribute("role", "alertdialog");
      overlay.style.cssText =
        "position:fixed;inset:0;z-index:2147483647;background:rgba(20,0,0,.92);color:#fff;" +
        "font:14px/1.5 ui-monospace,monospace;padding:32px;overflow:auto;white-space:pre-wrap";
      overlay.addEventListener("click", () => overlay.remove());
      document.body.appendChild(overlay);
    }
    const title = document.createElement("h2");
    title.textContent = "A <Suspense> failed on the server";
    const message = document.createElement("p");
    message.dataset.overlayMessage = "";
    message.textContent = cause?.message ?? String(cause);
    const stack = document.createElement("pre");
    stack.dataset.overlayStack = "";
    stack.textContent = cause?.stack ?? "";
    overlay.replaceChildren(title, message, stack);
  };
}
