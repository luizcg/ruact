// @vitest-environment jsdom
//
// Story 19-1 — the entry is `async`: it can run before the parser reaches the
// page's `<div id="root">`, and a <Suspense> that failed on the server is shown
// over the page in development.
import { describe, it, expect } from "vitest";
import { whenRoot } from "./runtime/page-stream.js";
import { showDevOverlay } from "./runtime/dev-overlay.js";

function loadingDocument() {
  const doc = document.implementation.createHTMLDocument("page");
  Object.defineProperty(doc, "readyState", { value: "loading", configurable: true });
  return doc;
}

describe("whenRoot", () => {
  it("gives the root at once when it is there", async () => {
    const doc = document.implementation.createHTMLDocument("page");
    doc.body.innerHTML = '<div id="root"></div>';
    await expect(whenRoot(doc)).resolves.toBe(doc.getElementById("root"));
  });

  it("waits for a root the parser has not reached yet", async () => {
    const doc = loadingDocument();
    let found = null;
    const waiting = whenRoot(doc).then((root) => { found = root; });
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(found).toBeNull();

    const root = doc.createElement("div");
    root.id = "root";
    doc.body.appendChild(root);
    await waiting;
    expect(found).toBe(root);
  });

  it("gives up with null when the document ends without one", async () => {
    const doc = loadingDocument();
    const waiting = whenRoot(doc);
    doc.dispatchEvent(new Event("DOMContentLoaded"));
    await expect(waiting).resolves.toBeNull();
  });
});

describe("showDevOverlay", () => {
  it("shows the server's error over the page, and closes on a click", () => {
    const cause = new Error("ArgumentError: boom in a block");
    cause.stack = "ArgumentError: boom in a block\n    at app/views/posts/show.html.erb:4";
    showDevOverlay(new Error("[ruact] Server error: ArgumentError: boom in a block", { cause }));

    const overlay = document.getElementById("ruact-dev-overlay");
    expect(overlay.querySelector("[data-overlay-message]").textContent).toBe("ArgumentError: boom in a block");
    expect(overlay.querySelector("[data-overlay-stack]").textContent).toContain("show.html.erb:4");

    overlay.click();
    expect(document.getElementById("ruact-dev-overlay")).toBeNull();
  });

  it("shows the latest failure in the one overlay", () => {
    showDevOverlay(new Error("first"));
    showDevOverlay(new Error("second"));
    const overlays = document.querySelectorAll("#ruact-dev-overlay");
    expect(overlays).toHaveLength(1);
    expect(overlays[0].querySelector("[data-overlay-message]").textContent).toBe("second");
    overlays[0].click();
  });
});
