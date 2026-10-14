// How a page is opened from its Flight bytes, wherever they come from: the
// rows the document pushes onto `__FLIGHT_DATA` (the first load) or the body of
// the router's fetch (a navigation, a form, revalidate()).
//
// The bytes go to React's Flight client through ./transport.js, so a response
// cut short reaches the Suspense boundaries labelled, and a second reader
// settles when the last byte is in.
import { createFromReadableStream } from "virtual:ruact/flight-client";
import { labelledStream } from "./transport.js";

/**
 * The rows the document pushes onto `__FLIGHT_DATA`, as a byte stream that
 * stays open while the document does (Story 19-1): the rows already in the
 * queue, then each one pushed later — a page that streams pushes one script per
 * `<Suspense>` — until the document has finished loading. A row pushed before
 * this runs is in the queue, and read first.
 */
export function documentRows(queue, doc = globalThis.document) {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      let open = true;
      const read = (row) => controller.enqueue(encoder.encode(row));
      queue.forEach(read);
      queue.length = 0;
      queue.push = (...rows) => {
        if (open) rows.forEach(read);
        return 0;
      };
      const close = () => {
        open = false;
        controller.close();
      };
      if (doc?.readyState === "loading") {
        doc.addEventListener("DOMContentLoaded", close, { once: true });
      } else {
        close();
      }
    },
  });
}

/**
 * The element the page mounts into. The entry is `async` and may run before
 * the parser reaches `<div id="root">` — a layout that puts `ruact_js_assets`
 * above it — so this waits for it, and gives up (null) when the document ends
 * without one.
 */
export function whenRoot(doc = globalThis.document) {
  const found = doc.getElementById("root");
  if (found || doc.readyState !== "loading") return Promise.resolve(found);
  return new Promise((resolve) => {
    const observer = new MutationObserver(() => {
      const root = doc.getElementById("root");
      if (root) finish(root);
    });
    const finish = (root) => {
      observer.disconnect();
      doc.removeEventListener("DOMContentLoaded", atEnd);
      resolve(root);
    };
    const atEnd = () => finish(doc.getElementById("root"));
    observer.observe(doc.documentElement, { childList: true, subtree: true });
    doc.addEventListener("DOMContentLoaded", atEnd);
  });
}

/**
 * Opens a page from a byte stream.
 *
 * `root` resolves with the tree as soon as row 0 has arrived; deferred Suspense
 * rows keep streaming into it. A stream that ends without a root rejects it
 * (./transport.js labels the failure). `end` settles when the last byte is in,
 * and rejects with the stream's error; it never goes unhandled on its own.
 */
export function openPage(body) {
  const [forClient, forEnd] = body.tee();
  const end = drain(forEnd);
  end.catch(() => {});
  // React's client returns a thenable; a Promise is what callers can await,
  // chain and assert on.
  return { root: Promise.resolve(createFromReadableStream(labelledStream(forClient))), end };
}

async function drain(stream) {
  const reader = stream.getReader();
  while (!(await reader.read()).done) { /* the client has its own copy */ }
}
