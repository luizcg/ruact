// How a page is opened from its Flight bytes, wherever they come from: the
// rows the document inlined in `__FLIGHT_DATA` (the first load) or the body of
// the router's fetch (a navigation, a form, revalidate()).
//
// The bytes go to React's Flight client through ./transport.js, so a response
// cut short reaches the Suspense boundaries labelled, and a second reader
// settles when the last byte is in.
import { createFromReadableStream } from "virtual:ruact/flight-client";
import { labelledStream } from "./transport.js";

/** The rows the document pushed onto `__FLIGHT_DATA`, as one byte stream. */
export function inlineRows(queue) {
  const bytes = new TextEncoder().encode(queue.join(""));
  return new ReadableStream({
    start(controller) {
      controller.enqueue(bytes);
      controller.close();
    },
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
