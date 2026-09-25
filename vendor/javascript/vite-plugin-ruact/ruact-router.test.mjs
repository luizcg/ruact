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

  const metas = {};
  globalThis.document = {
    addEventListener: on("document"),
    removeEventListener: off("document"),
    querySelector: (selector) => {
      const name = selector.match(/meta\[name="([^"]+)"\]/)?.[1];
      return name && name in metas ? { content: metas[name] } : null;
    },
    createElement: (tag) => {
      const el = { tagName: tag.toUpperCase(), type: "", name: "", value: "", parent: null };
      el.remove = () => { if (el.parent) el.parent.children = el.parent.children.filter((c) => c !== el); };
      return el;
    },
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
    removeAttribute(name) { delete this.attrs[name]; }
    appendChild(node) { node.parent = this; this.children.push(node); }
    querySelector(selector) {
      const name = selector.match(/\[name="([^"]+)"\]/)?.[1];
      return this.children.find((c) => c.name === name) ?? null;
    }
    get action() { return new URL(this.attrs.action ?? globalThis.location.href, ORIGIN).href; }
    submit() {}
  }
  globalThis.HTMLFormElement = FakeForm;
  globalThis.FormData = class { constructor() { this.entries = []; } forEach() {} };

  return { listeners, FakeForm, metas };
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
    it("carries the submitter's name/value and overrides DURING the submit, and takes them back after", async () => {
      const form = new dom.FakeForm({ action: "/people", method: "post" });
      const submitter = {
        name: "op", value: "archive",
        hasAttribute: (n) => ["formAction", "formMethod", "formaction", "formmethod", "formenctype"].includes(n),
        getAttribute: (n) => ({
          formAction: "/people/archive", formaction: "/people/archive",
          formMethod: "post", formmethod: "post", formenctype: "multipart/form-data",
        })[n] ?? null,
      };
      let during;
      vi.spyOn(HTMLFormElement.prototype, "submit").mockImplementation(function () {
        during = { action: this.getAttribute("action"), enctype: this.getAttribute("enctype"), fields: this.children.map((c) => [c.name, c.value]) };
      });
      fetch.mockResolvedValue(respond({ contentType: "text/plain", boundary: "native" }));

      submit(dom.listeners, form, submitter);
      await settle();

      expect(during).toEqual({ action: "/people/archive", enctype: "multipart/form-data", fields: [["op", "archive"]] });
      // Taken back: a page that survives the submit keeps its form as it was.
      expect(form.getAttribute("action")).toBe("/people");
      expect(form.hasAttribute("enctype")).toBe(false);
      expect(form.children).toEqual([]);
    });

    // Review round 1 — a form a React component rendered has no token field;
    // the router's fetch sent it as a header, a native submit cannot.
    it("adds the CSRF token from the meta tags when the form has no token field", async () => {
      dom.metas["csrf-param"] = "authenticity_token";
      dom.metas["csrf-token"] = "tok-123";
      const form = new dom.FakeForm({ action: "/people", method: "post" });
      let fields;
      vi.spyOn(HTMLFormElement.prototype, "submit").mockImplementation(function () {
        fields = this.children.map((c) => [c.name, c.value]);
      });
      fetch.mockResolvedValue(respond({ contentType: "text/plain", boundary: "native" }));

      submit(dom.listeners, form);
      await settle();

      expect(fields).toEqual([["authenticity_token", "tok-123"]]);
    });

    // Review round 1 — a native answer at the END of a redirect the fetch
    // followed means the action already ran. Resubmitting would run it twice.
    it("loads the redirect target instead of resubmitting when the fetch was redirected", async () => {
      const form = new dom.FakeForm({ action: "/people", method: "post" });
      const nativeSubmit = vi.spyOn(HTMLFormElement.prototype, "submit");
      fetch.mockResolvedValue({ ...respond({ contentType: "text/plain", boundary: "native", url: `${ORIGIN}/people/3` }), redirected: true });

      submit(dom.listeners, form);
      await settle();

      expect(nativeSubmit).not.toHaveBeenCalled();
      expect(location.assign).toHaveBeenCalledWith(`${ORIGIN}/people/3`);
    });
  });

  describe("review round 1 — errors stay errors", () => {
    // Review round 2 — the default app passes no onError: an error page kept
    // on the error path is a console line and a dead click. Load it, so the
    // user sees it; repeating a GET is harmless.
    it("loads a GET error page (500 HTML) in full so the user sees it", async () => {
      fetch.mockResolvedValue(respond({ status: 500, contentType: "text/html", body: "<h1>oops</h1>", url: `${ORIGIN}/products/9` }));

      click(dom.listeners, "/products/9");
      await settle();

      expect(location.assign).toHaveBeenCalledWith(`${ORIGIN}/products/9`);
    });

    it("rejects revalidate() when the server says the page is not ruact's", async () => {
      fetch.mockResolvedValue(respond({ contentType: "text/plain", boundary: "native" }));

      await expect(globalThis.__ruact_revalidate()).rejects.toThrow("is not a ruact page");
      expect(location.assign).not.toHaveBeenCalled();
    });

    it("rejects revalidate() on a non-Flight answer instead of reloading", async () => {
      fetch.mockResolvedValue(respond({ contentType: "text/html", body: "<h1>html</h1>" }));

      await expect(globalThis.__ruact_revalidate()).rejects.toThrow("did not answer with a ruact response");
      expect(location.assign).not.toHaveBeenCalled();
    });

    // A 403 is a CSRF rejection: the action did NOT run, and telling the
    // developer it did (and to add data-ruact="false") points the wrong way.
    it("does not call a 403 on a form 'not a ruact page'", async () => {
      const form = new dom.FakeForm({ action: "/people", method: "post" });
      fetch.mockResolvedValue(respond({ status: 403, contentType: "text/html", body: "forbidden" }));

      submit(dom.listeners, form);
      await settle();

      expect(onError.mock.calls[0][0].message).not.toContain("data-ruact");
      expect(onError.mock.calls[0][0].message).toContain("403");
    });

    // Fetch drops the #fragment from response.url.
    it("keeps the link's #fragment on a full load", async () => {
      fetch.mockResolvedValue(respond({ contentType: "text/plain", boundary: "native", url: `${ORIGIN}/docs/guide` }));

      click(dom.listeners, "/docs/guide#install");
      await settle();

      expect(location.assign).toHaveBeenCalledWith(`${ORIGIN}/docs/guide#install`);
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
