// @vitest-environment jsdom
//
// Story 18-1 — React's Flight client (the copy vendored in the gem) reads what
// the Ruby side writes. Every payload here is the serializer's own output,
// written and guarded against drift by spec/ruact/flight/*_fixtures_spec.rb.
//
// The suite runs once per client build: FLIGHT_CLIENT_MODE=development (the
// default) and =production (`npm test` runs both). CI also runs it against the
// lowest React the gem supports.
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { act, createElement as h, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { createFromReadableStream } from "virtual:ruact/flight-client";
import { setModuleRegistry } from "./runtime/flight-modules.js";
import { setBoundaryErrorHandler } from "./runtime/suspense-boundary.js";
import { RootBoundary } from "./runtime/root-boundary.js";
import { labelledStream } from "./runtime/transport.js";

const MODE = process.env.FLIGHT_CLIENT_MODE || "development";
const FIXTURES = path.join(import.meta.dirname, "../../../spec/fixtures/flight");
const read = (name) => new Uint8Array(fs.readFileSync(path.join(FIXTURES, name)));
const readJSON = (name) => JSON.parse(fs.readFileSync(path.join(FIXTURES, name), "utf8"));

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

function Bad() {
  throw new Error("boom");
}

function LikeButton({ likes, tags }) {
  return h("button", null, `${likes}:${Array.isArray(tags) ? `[${tags.join(",")}]` : String(tags)}`);
}
setModuleRegistry({ "/LikeButton.jsx": { LikeButton }, "/Bad.jsx": { Bad } });

function streamOf(chunks) {
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
}

// As the runtime reads a response: through ./runtime/transport.js. React's
// client returns a thenable, not a Promise; wrap it so `rejects` really checks.
const decode = (chunks) => Promise.resolve(createFromReadableStream(labelledStream(streamOf(chunks))));

async function mount(value) {
  const container = document.createElement("div");
  const root = createRoot(container);
  await act(async () => {
    root.render(h(Suspense, { fallback: "…" }, value));
  });
  return { container, root };
}

let consoleError;
beforeEach(() => {
  consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
  consoleError.mockRestore();
  setBoundaryErrorHandler(null);
});

describe(`React's Flight client (${MODE}) reads a page the Ruby side rendered`, () => {
  // The development wire carries the slots React's development client reads.
  const fixture = MODE === "development" ? "conformance_tree_dev.txt" : "conformance_tree.txt";
  const html =
    "<main><h1>Posts</h1>" +
    "<article><button>1:[only]</button></article>" +
    "<article><button>2:[only]</button></article>" +
    "<article><button>3:[only]</button></article>" +
    "<p>late</p><p>after</p></main>";

  // FIRST render in this file on purpose: React reports a missing key once per
  // location, so a later test would see nothing even on the wrong wire.
  it("renders host elements, an ERB loop of client components and a Suspense child — and logs nothing", async () => {
    const { container, root } = await mount(decode([read(fixture)]));
    expect(container.innerHTML).toBe(html);
    // The development build reports a missing key after the commit, on a later
    // task; wait for it before concluding there is none.
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(consoleError).not.toHaveBeenCalled();
    act(() => root.unmount());
  });

  it("keeps a one-element array prop a one-element array (Story 17.0a)", async () => {
    const tree = await decode([read(fixture)]);
    const article = tree.props.children[1];
    expect(article.props.children.props.tags).toEqual(["only"]);
  });

  it("does not depend on where the network splits the bytes", async () => {
    const bytes = read(fixture);
    for (let cut = 1; cut < bytes.length; cut += 37) {
      const { container, root } = await mount(decode([bytes.subarray(0, cut), bytes.subarray(cut)]));
      expect(container.innerHTML).toBe(html);
      act(() => root.unmount());
    }
  });
});

describe(`text rows (${MODE}) — Story 17-0d`, () => {
  const expected = readJSON("text_framing_expected.json");

  it("decodes every value the serializer framed, byte for byte", async () => {
    expect(await decode([read("text_framing.txt")])).toEqual(expected);
  });

  it("decodes the same split at every byte, including inside lengths and code points", async () => {
    const bytes = read("text_framing.txt");
    for (let cut = 1; cut < bytes.length; cut += 1) {
      expect(await decode([bytes.subarray(0, cut), bytes.subarray(cut)])).toEqual(expected);
    }
  });

  it("decodes one byte at a time", async () => {
    const bytes = read("text_framing.txt");
    expect(await decode([...bytes].map((b) => Uint8Array.of(b)))).toEqual(expected);
  });

  it("puts long text inside Suspense content where the deferred row points", async () => {
    const { container, root } = await mount(decode([read("text_framing_suspense.txt")]));
    expect(container.querySelector("p").textContent).toBe(expected.multibyte);
    act(() => root.unmount());
  });

  it("rejects a stream cut inside a text row instead of rendering part of it", async () => {
    const bytes = read("text_framing.txt");
    const cut = Buffer.from(bytes).indexOf(":T") + 10;
    await expect(decode([bytes.subarray(0, cut)])).rejects.toThrow(/the response ended before the whole page arrived/);
  });
});

describe(`dates and big integers (${MODE}) — Story 17-0c`, () => {
  // Expected JSON tags what JSON cannot hold: { date: ISO } and { bigint: "…" }.
  const revive = (value) => {
    if (Array.isArray(value)) return value.map(revive);
    if (value && typeof value === "object") {
      if ("date" in value) return new Date(value.date);
      if ("bigint" in value) return BigInt(value.bigint);
      return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, revive(v)]));
    }
    return value;
  };

  it("rebuilds every value with its JS type, nested ones included", async () => {
    expect(await decode([read("scalar_round_trip.txt")])).toEqual(revive(readJSON("scalar_round_trip_expected.json")));
  });

  it("keeps a literal string that starts with $D a string", async () => {
    expect((await decode([read("scalar_round_trip.txt")])).literal).toBe("$D2026-01-01 is a string");
  });

  it("reads NaN, ±Infinity, undefined and an escaped $", async () => {
    const value = await decode([new TextEncoder().encode(
      '0:{"nan":"$NaN","inf":"$Infinity","ninf":"$-Infinity","negz":"$-0","und":"$undefined","cash":"$$5"}\n',
    )]);
    expect(Number.isNaN(value.nan)).toBe(true);
    expect(value.inf).toBe(Infinity);
    expect(value.ninf).toBe(-Infinity);
    expect(Object.is(value.negz, -0)).toBe(true);
    expect(value.und).toBeUndefined();
    expect(value.cash).toBe("$5");
  });
});

describe(`a Suspense child whose row is an error (${MODE})`, () => {
  const timeout = () => read("conformance_suspense_timeout.txt");
  // The same page, its Suspense row now content: the timeout fixture with the
  // error row replaced.
  const recovered = () => new TextEncoder().encode(
    new TextDecoder().decode(timeout()).replace(/^1:E.*$/m, '1:["$","p",null,{"children":"late"}]'),
  );

  it("keeps the fallback on screen and reports the server's message, in production too", async () => {
    const reported = [];
    setBoundaryErrorHandler((error) => reported.push(error));
    const { container, root } = await mount(decode([timeout()]));

    expect(container.innerHTML).toBe("<span>loading</span>");
    expect(reported.map((e) => e.message)).toEqual(["[ruact] Server error: Suspense timeout exceeded"]);
    act(() => root.unmount());
  });

  it("keeps the fallback when the response ends before the Suspense row, in production too", async () => {
    const reported = [];
    setBoundaryErrorHandler((error) => reported.push(error));
    const cut = new TextDecoder().decode(timeout()).replace(/^1:E.*\n?/m, "");
    const tree = await decode([new TextEncoder().encode(cut)]);
    const container = document.createElement("div");
    const root = createRoot(container);
    await act(async () => {
      root.render(h(RootBoundary, { tree }, h(Suspense, { fallback: "…" }, tree)));
    });
    expect(container.innerHTML).toBe("<span>loading</span>");
    expect(reported.map((e) => e.message)).toEqual([
      "[ruact] Server error: the response ended before the whole page arrived",
    ]);
    act(() => root.unmount());
  });

  it("keeps the fallback when the network fails mid-response", async () => {
    const reported = [];
    setBoundaryErrorHandler((error) => reported.push(error));
    const head = new TextDecoder().decode(timeout()).replace(/^1:E.*\n?/m, "");
    const failing = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(head));
        setTimeout(() => controller.error(new TypeError("network error")), 0);
      },
    });
    const tree = await createFromReadableStream(labelledStream(failing));
    const container = document.createElement("div");
    const root = createRoot(container);
    await act(async () => {
      root.render(h(RootBoundary, { tree }, h(Suspense, { fallback: "…" }, tree)));
      await new Promise((resolve) => setTimeout(resolve, 10));
    });
    expect(container.innerHTML).toBe("<span>loading</span>");
    expect(reported).toHaveLength(1);
    act(() => root.unmount());
  });

  it("does not stay failed: the next response for the same page renders", async () => {
    setBoundaryErrorHandler(() => {});
    const { container, root } = await mount(decode([timeout()]));
    expect(container.innerHTML).toBe("<span>loading</span>");

    // What revalidate() or a navigation to a page of the same shape does.
    const next = decode([recovered()]);
    await act(async () => {
      root.render(h(Suspense, { fallback: "…" }, next));
    });
    expect(container.innerHTML).toBe("<p>late</p>");
    act(() => root.unmount());
  });

  it("lets a crash in the app's own component through, to the root's boundary", async () => {
    const reported = [];
    setBoundaryErrorHandler((error) => reported.push(error));
    const wire = new TextDecoder().decode(timeout())
      .replace(/^1:E.*$/m, '1:["$","$L5",null,{}]')
      .replace(/^/, '5:I["/Bad.jsx",[],"Bad"]\n');
    const tree = await decode([new TextEncoder().encode(wire)]);
    const container = document.createElement("div");
    const root = createRoot(container);
    await act(async () => {
      root.render(h(RootBoundary, { tree }, tree));
    });
    expect(container.textContent).toBe("[ruact] Error: boom");
    expect(reported).toEqual([]);
    act(() => root.unmount());
  });
});

describe(`a component missing from the registry (${MODE})`, () => {
  it("shows an error in place of the page instead of removing it", async () => {
    const tree = await decode([new TextEncoder().encode('1:I["/Gone.jsx",[],"Gone"]\n0:["$","$L1",null,{}]\n')]);
    const container = document.createElement("div");
    const root = createRoot(container);
    await act(async () => {
      root.render(h(RootBoundary, { tree }, tree));
    });
    expect(container.textContent).toBe(
      '[ruact] Error: client component not registered: /Gone.jsx — is it under app/javascript/components/ with "use client" at the top?',
    );
    act(() => root.unmount());
  });
});

describe(`responses the router reads (${MODE})`, () => {
  it("decodes a redirect body to the object the router checks", async () => {
    // redirect_row.txt is what Ruact::Controller#redirect_to writes (controller_spec guards it).
    expect(await decode([read("redirect_row.txt")])).toEqual({ redirectUrl: "/posts/1", redirectType: "push" });
  });

  it("rejects a stream that ends before its root row", async () => {
    await expect(decode([new TextEncoder().encode('1:["$","p",null,{}]\n')])).rejects.toThrow(
      /the response ended before the whole page arrived/,
    );
  });
});
