// The two ways a page is opened read the same way: the rows a document inlined
// in `__FLIGHT_DATA`, and a fetch body that may end early.
import { describe, it, expect } from "vitest";
import { inlineRows, openPage } from "./runtime/page-stream.js";

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
    const page = openPage(inlineRows(['1:"wor', 'ld"\n0:["hello","$1"]\n']));
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
