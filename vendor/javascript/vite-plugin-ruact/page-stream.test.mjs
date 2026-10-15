// The two ways a page is opened read the same way: the rows a document inlined
// in `__FLIGHT_DATA`, and a fetch body that may end early.
import { describe, it, expect } from "vitest";
import { LEAVE_EVENT, documentRows, openPage } from "./runtime/page-stream.js";

const encoder = new TextEncoder();

function bodyOf(chunks, { error } = {}) {
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      if (error) controller.error(error);
      else controller.close();
    },
  });
}

describe("openPage", () => {
  it("opens the rows a document inlined, joined in the order they were pushed", async () => {
    const page = openPage(documentRows(['1:"wor', 'ld"\n0:["hello","$1"]\n'], { readyState: "complete" }));
    expect(await page.root).toEqual(["hello", "world"]);
    await expect(page.end).resolves.toBeUndefined();
  });

  it("resolves the root at row 0, before a deferred row has arrived", async () => {
    let push;
    const body = new ReadableStream({
      start(controller) {
        controller.enqueue(encoder.encode('0:{"later":"$@1"}\n'));
        push = (row) => {
          controller.enqueue(encoder.encode(row));
          controller.close();
        };
      },
    });
    const page = openPage(body);
    const root = await page.root;
    expect(root.later).toBeInstanceOf(Promise);

    push('1:"arrived"\n');
    await expect(root.later).resolves.toBe("arrived");
    await expect(page.end).resolves.toBeUndefined();
  });

  it("labels a body that ends before the root as the transport's failure, and rejects the end", async () => {
    const page = openPage(bodyOf([], { error: new TypeError("network down") }));
    await expect(page.root).rejects.toMatchObject({ digest: "ruact:connection-closed" });
    await expect(page.end).rejects.toThrow("network down");
  });
});

// Story 19-1 — a page that streams: the document is still open when the
// bootstrap runs, and pushes each <Suspense>'s rows as they are ready.
describe("documentRows", () => {
  function openDocument() {
    const listeners = {};
    return {
      readyState: "loading",
      addEventListener(type, listener) { listeners[type] = listener; },
      removeEventListener(type) { delete listeners[type]; },
      finish(state = "interactive") {
        this.readyState = state;
        listeners.readystatechange?.();
      },
      leave() {
        listeners[LEAVE_EVENT]?.();
        this.finish("complete");
      },
    };
  }

  it("reads what the queue holds, then each row pushed later, until the document ends", async () => {
    const doc = openDocument();
    const queue = ['0:{"later":"$@1"}\n'];
    const page = openPage(documentRows(queue, doc));
    const root = await page.root;
    expect(root.later).toBeInstanceOf(Promise);

    queue.push('1:"arrived"\n');
    await expect(root.later).resolves.toBe("arrived");
    expect(queue).toHaveLength(0);

    doc.finish();
    await expect(page.end).resolves.toBeUndefined();
  });

  it("keeps the stream open while the document loads, and closes it when the document ends", async () => {
    const doc = openDocument();
    const stream = documentRows(['0:"shell"\n'], doc);
    const reader = stream.getReader();
    await reader.read();
    let closed = false;
    const next = reader.read().then((result) => { closed = result.done; });
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(closed).toBe(false);
    doc.finish();
    await next;
    expect(closed).toBe(true);
  });

  // Story 19-2 — the router stops a document it leaves while it still loads.
  it("closes when the document is stopped while loading", async () => {
    const doc = openDocument();
    const reader = documentRows(['0:"x"\n'], doc).getReader();
    await reader.read();
    doc.finish("complete");
    await expect(reader.read()).resolves.toMatchObject({ done: true });
  });

  // Story 19-2 — the router leaving it: the page being left reports nothing,
  // as for a superseded navigation.
  it("ends as an aborted navigation when the router leaves the document", async () => {
    const doc = openDocument();
    const page = openPage(documentRows(['0:{"later":"$@1"}\n'], doc));
    const root = await page.root;
    doc.leave();
    await expect(root.later).rejects.toMatchObject({ name: "AbortError" });
    await expect(page.end).rejects.toMatchObject({ name: "AbortError" });
  });

  it("closes at once when the document has already ended", async () => {
    const reader = documentRows(['0:"x"\n'], { readyState: "complete" }).getReader();
    await reader.read();
    await expect(reader.read()).resolves.toMatchObject({ done: true });
  });

  it("ignores a row pushed after the document ended instead of throwing", () => {
    const queue = [];
    documentRows(queue, { readyState: "complete" });
    expect(() => queue.push('9:"late"\n')).not.toThrow();
  });
});
