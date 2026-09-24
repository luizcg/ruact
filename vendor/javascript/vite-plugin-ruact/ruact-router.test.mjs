// Story 17.0f — the navigation boundary, from the router's side.
//
// ruact-router.js had no tests at all. It runs in a browser; this file runs in
// vitest's node environment with the smallest fakes of `document`, `window`,
// `location`, `history` and `HTMLFormElement` the router actually touches — no
// jsdom, which this package does not depend on. `fetch` is stubbed per test.
//
// What is pinned: a response the server marks `Ruact-Boundary: native` is handed
// to the browser (a full load, or a NATIVE form submit — the action never ran,
// so resubmitting is safe); a non-Flight response that escaped the server's
// classifier is never a silent no-op; and a Flight response still renders.

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { setupRouter, teardownRouter } from "./runtime/ruact-router.js";

const ORIGIN = "http://localhost:3000";

function fakeLocation(path) {
  let url = new URL(path, ORIGIN);
  return {
    get href() { return url.href; },
    get origin() { return url.origin; },
    get pathname() { return url.pathname; },
    get search() { return url.search; },
    get hash() { return url.hash; },
    assign: vi.fn(),
    replace: vi.fn(),
    _set(next) { url = new URL(next, ORIGIN); },
  };
}

function installDom(path = "/products/1") {
  const listeners = { document: {}, window: {} };
  const on = (bucket) => (type, fn) => { (listeners[bucket][type] ||= []).push(fn); };
  const off = (bucket) => (type, fn) => {
    listeners[bucket][type] = (listeners[bucket][type] || []).filter((f) => f !== fn);
  };

  globalThis.document = {
    addEventListener: on("document"),
    removeEventListener: off("document"),
    querySelector: () => null,
    createElement: (tag) => ({ tagName: tag.toUpperCase(), type: "", name: "", value: "" }),
  };
  globalThis.window = {
    addEventListener: on("window"),
    removeEventListener: off("window"),
    scrollTo: vi.fn(),
  };
  globalThis.location = fakeLocation(path);
  globalThis.history = { pushState: vi.fn((_s, _t, next) => globalThis.location._set(next)) };

  class FakeForm {
    constructor(attrs) {
      this.tagName = "FORM";
      this.attrs = { ...attrs };
      this.children = [];
    }
    getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; }
    hasAttribute(name) { return name in this.attrs; }
    setAttribute(name, value) { this.attrs[name] = value; }
    appendChild(node) { this.children.push(node); }
    get action() { return new URL(this.attrs.action ?? globalThis.location.href, ORIGIN).href; }
    submit() {}
  }
  globalThis.HTMLFormElement = FakeForm;
  globalThis.FormData = class { constructor() { this.entries = []; } forEach() {} };

  return { listeners, FakeForm };
}

function flightBody(text) {
  return new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(text));
      controller.close();
    },
  });
}

function respond({ status = 200, contentType = "text/x-component", boundary = null, body = "", url = "" } = {}) {
  const headers = new Headers({ "content-type": contentType });
  if (boundary) headers.set("ruact-boundary", boundary);
  return { ok: status >= 200 && status < 300, status, statusText: String(status), url, headers, body: flightBody(body) };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function settle() {
  for (let i = 0; i < 5; i += 1) await flush();
}

function anchor(href) {
  const el = {
    getAttribute: (name) => (name === "href" ? href : null),
    hasAttribute: () => false,
    target: "",
  };
  el.closest = () => el;
  return el;
}

function click(listeners, href) {
  const event = {
    defaultPrevented: false, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false, button: 0,
    target: anchor(href),
    preventDefault() { this.defaultPrevented = true; },
  };
  listeners.document.click.forEach((fn) => fn(event));
  return event;
}

function submit(listeners, form, submitter = null) {
  const event = { defaultPrevented: false, target: form, submitter, preventDefault() { this.defaultPrevented = true; } };
  listeners.document.submit.forEach((fn) => fn(event));
  return event;
}

describe("ruact-router — the navigation boundary (Story 17.0f)", () => {
  let dom;
  let onNavigate;
  let onError;

  beforeEach(() => {
    dom = installDom();
    onNavigate = vi.fn();
    onError = vi.fn();
    globalThis.fetch = vi.fn();
    vi.spyOn(console, "error").mockImplementation(() => {});
    setupRouter({ onNavigate, moduleRegistry: {}, onError });
  });

  afterEach(() => {
    teardownRouter();
    vi.restoreAllMocks();
  });

  describe("a link the server marks Ruact-Boundary: native", () => {
    it("is handed to the browser as a full load — no render, no pushState", async () => {
      fetch.mockResolvedValue(respond({ contentType: "text/plain", boundary: "native", url: `${ORIGIN}/people/1` }));

      click(dom.listeners, "/people/1");
      await settle();

      expect(location.assign).toHaveBeenCalledWith(`${ORIGIN}/people/1`);
      expect(onNavigate).not.toHaveBeenCalled();
      expect(history.pushState).not.toHaveBeenCalled();
      expect(onError).not.toHaveBeenCalled();
    });

    // Back/forward: `assign` would push a NEW entry in the middle of the history
    // the user is walking through.
    it("uses location.replace when it came from popstate", async () => {
      fetch.mockResolvedValue(respond({ contentType: "text/plain", boundary: "native", url: `${ORIGIN}/people/1` }));
      location._set("/people/1");

      dom.listeners.window.popstate.forEach((fn) => fn({}));
      await settle();

      expect(location.replace).toHaveBeenCalledWith(`${ORIGIN}/people/1`);
      expect(location.assign).not.toHaveBeenCalled();
    });
  });

  describe("a non-Flight answer that escaped the server's classifier", () => {
    // The 2026-09-12 spike's S2: a Rails controller answers 200 text/html, the
    // line parser returns null for every HTML line, nothing renders, the URL does
    // not change, and nothing reports an error. A dead click.
    it("on a GET, becomes a full load instead of a dead click", async () => {
      fetch.mockResolvedValue(respond({ contentType: "text/html; charset=utf-8", body: "<h1>person</h1>\n", url: `${ORIGIN}/people/1` }));

      click(dom.listeners, "/people/1");
      await settle();

      expect(location.assign).toHaveBeenCalledWith(`${ORIGIN}/people/1`);
      expect(onNavigate).not.toHaveBeenCalled();
    });

    // The action already ran: resubmitting would run it twice. Say so instead.
    it("on a non-GET form, reports an error naming the form and the fix — never silent, never resubmitted", async () => {
      const form = new dom.FakeForm({ action: "/people", method: "post" });
      const nativeSubmit = vi.spyOn(HTMLFormElement.prototype, "submit");
      fetch.mockResolvedValue(respond({ status: 422, contentType: "text/html", body: "<p>invalid</p>" }));

      submit(dom.listeners, form);
      await settle();

      expect(onError).toHaveBeenCalledTimes(1);
      const message = onError.mock.calls[0][0].message;
      expect(message).toContain("POST /people");
      expect(message).toContain("422");
      expect(message).toContain('data-ruact="false"');
      expect(nativeSubmit).not.toHaveBeenCalled();
      expect(location.assign).not.toHaveBeenCalled();
    });
  });

  describe("a form the server marks Ruact-Boundary: native", () => {
    it("is submitted NATIVELY — the action never ran, so this is its one run", async () => {
      const form = new dom.FakeForm({ action: "/people", method: "post" });
      const nativeSubmit = vi.spyOn(HTMLFormElement.prototype, "submit");
      fetch.mockResolvedValue(respond({ contentType: "text/plain", boundary: "native" }));

      submit(dom.listeners, form);
      await settle();

      expect(nativeSubmit).toHaveBeenCalledTimes(1);
      expect(nativeSubmit.mock.contexts[0]).toBe(form);
      expect(fetch).toHaveBeenCalledTimes(1);
      expect(onError).not.toHaveBeenCalled();
    });

    // A native submit loses the submitter unless it is carried over: the
    // browser only includes `name=value` of the button that was clicked.
    it("carries the submitter's name/value and its formaction/formmethod overrides", async () => {
      const form = new dom.FakeForm({ action: "/people", method: "post" });
      const submitter = {
        name: "op", value: "archive",
        hasAttribute: (n) => ["formAction", "formMethod", "formaction", "formmethod"].includes(n),
        getAttribute: (n) => ({ formAction: "/people/archive", formaction: "/people/archive", formMethod: "post", formmethod: "post" })[n] ?? null,
      };
      vi.spyOn(HTMLFormElement.prototype, "submit");
      fetch.mockResolvedValue(respond({ contentType: "text/plain", boundary: "native" }));

      submit(dom.listeners, form, submitter);
      await settle();

      expect(form.getAttribute("action")).toBe("/people/archive");
      expect(form.children).toContainEqual(expect.objectContaining({ name: "op", value: "archive" }));
    });
  });

  describe("a Flight answer", () => {
    it("still renders in place, as before", async () => {
      fetch.mockResolvedValue(respond({ body: '0:["$","h1",null,{"children":"hi"}]\n', url: `${ORIGIN}/products/2` }));

      click(dom.listeners, "/products/2");
      await settle();

      expect(onNavigate).toHaveBeenCalledTimes(1);
      expect(history.pushState).toHaveBeenCalled();
      expect(location.assign).not.toHaveBeenCalled();
    });
  });
});
