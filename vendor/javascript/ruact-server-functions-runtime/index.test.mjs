// Story 8.1 — vitest suite for the real server-functions runtime.
//
// Covers AC10 of Story 8.1: argument-shape branching (JSON vs FormData),
// CSRF meta-tag injection, success vs. failure response handling, and
// error wrapping. Uses `vi.fn()` to stub `fetch` — no real network.

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import {
  _makeRef,
  _makeServerFunction,
  __RUNTIME_VERSION__,
  __internals,
  RuactActionError,
  configureRuactRuntime,
  revalidate,
} from "./index.js";

let originalFetch;
let originalDocument;

beforeEach(() => {
  originalFetch = globalThis.fetch;
  originalDocument = globalThis.document;
});

afterEach(() => {
  globalThis.fetch = originalFetch;
  globalThis.document = originalDocument;
  vi.restoreAllMocks();
});

function mockFetchOk(jsonBody, { status = 200, contentType = "application/json" } = {}) {
  // Re-run-2 (2026-05-14) — parseResponse now reads `text()` first, then
  // JSON.parses if Content-Type says JSON. Default the text mock to the
  // JSON-stringified body so tests still see the structured value.
  const response = {
    ok: true,
    status,
    headers: { get: (n) => (n.toLowerCase() === "content-type" ? contentType : null) },
    json: vi.fn().mockResolvedValue(jsonBody),
    text: vi.fn().mockResolvedValue(typeof jsonBody === "string" ? jsonBody : JSON.stringify(jsonBody)),
  };
  globalThis.fetch = vi.fn().mockResolvedValue(response);
  return response;
}

function mockFetchError(status, bodyText) {
  const response = {
    ok: false,
    status,
    headers: { get: () => "text/plain" },
    text: vi.fn().mockResolvedValue(bodyText),
    json: vi.fn(),
  };
  globalThis.fetch = vi.fn().mockResolvedValue(response);
  return response;
}

function mockMetaTag(token) {
  globalThis.document = {
    querySelector: vi.fn().mockImplementation((selector) => {
      if (selector === 'meta[name="csrf-token"]' && token !== null) {
        return { getAttribute: () => token };
      }
      return null;
    }),
  };
}

describe("Story 8.1 — _makeRef", () => {
  it("exports the runtime-version sentinel (placeholder __PLACEHOLDER__ is gone)", () => {
    expect(__RUNTIME_VERSION__).toBe(1);
  });

  it("returns a callable accessor", () => {
    const ref = _makeRef("create_post");
    expect(typeof ref).toBe("function");
  });
});

describe("Story 8.1 — JSON body branch", () => {
  it("POSTs JSON.stringify(args) with Content-Type: application/json", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag(null);

    await _makeRef("create_post")({ title: "Hi" });

    expect(globalThis.fetch).toHaveBeenCalledTimes(1);
    const [url, init] = globalThis.fetch.mock.calls[0];
    expect(url).toBe("/__ruact/fn/create_post");
    expect(init.method).toBe("POST");
    expect(init.credentials).toBe("same-origin");
    expect(init.headers["Content-Type"]).toBe("application/json");
    expect(init.body).toBe(JSON.stringify({ title: "Hi" }));
  });

  it("treats undefined args as an empty JSON object {}", async () => {
    mockFetchOk({});
    mockMetaTag(null);
    await _makeRef("categories")();

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe("{}");
  });

  it("treats null args as an empty JSON object {}", async () => {
    mockFetchOk({});
    mockMetaTag(null);
    await _makeRef("categories")(null);

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe("{}");
  });

  it("resolves with parsed JSON for application/json responses", async () => {
    mockFetchOk({ id: 7 });
    mockMetaTag(null);
    const result = await _makeRef("create_post")({ title: "x" });
    expect(result).toEqual({ id: 7 });
  });

  it("attaches Accept: application/json header (re-run-2 #8 — host respond_to branching)", async () => {
    mockFetchOk({});
    mockMetaTag(null);
    await _makeRef("create_post")({});
    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.headers.Accept).toBe("application/json");
  });

  it("resolves with raw text for non-JSON responses", async () => {
    const r = {
      ok: true,
      status: 200,
      headers: { get: () => "text/plain" },
      text: vi.fn().mockResolvedValue("hello"),
      json: vi.fn(),
    };
    globalThis.fetch = vi.fn().mockResolvedValue(r);
    mockMetaTag(null);

    const result = await _makeRef("ping")({});
    expect(result).toBe("hello");
    expect(r.text).toHaveBeenCalled();
    expect(r.json).not.toHaveBeenCalled();
  });

  it("resolves with null for non-204 empty-body responses (e.g., `head :ok`, 205) " +
    "(re-run-2 #7 — text-first parse)", async () => {
    const r = {
      ok: true,
      status: 205,
      headers: { get: (n) => (n.toLowerCase() === "content-type" ? "application/json" : null) },
      text: vi.fn().mockResolvedValue(""),
      json: vi.fn().mockRejectedValue(new SyntaxError("Unexpected end of JSON input")),
    };
    globalThis.fetch = vi.fn().mockResolvedValue(r);
    mockMetaTag(null);

    const result = await _makeRef("noop")({});
    expect(result).toBeNull();
    expect(r.json).not.toHaveBeenCalled();
  });

  it("resolves with null for 204 No Content responses", async () => {
    const r = {
      ok: true,
      status: 204,
      headers: { get: () => null },
      text: vi.fn().mockResolvedValue(""),
      json: vi.fn(),
    };
    globalThis.fetch = vi.fn().mockResolvedValue(r);
    mockMetaTag(null);

    const result = await _makeRef("noop")({});
    expect(result).toBeNull();
  });

  it("resolves with null for 204 No Content even when Content-Type says application/json " +
    "(review-batch 4 + re-run-2 — empty body → null regardless of Content-Type)", async () => {
    const r = {
      ok: true,
      status: 204,
      // Rails sends `head :no_content` with Content-Type: application/json
      // when the controller is in a JSON-context. The 204 still has no body.
      headers: { get: (n) => (n.toLowerCase() === "content-type" ? "application/json" : null) },
      text: vi.fn().mockResolvedValue(""),
      json: vi.fn().mockRejectedValue(new SyntaxError("Unexpected end of JSON input")),
    };
    globalThis.fetch = vi.fn().mockResolvedValue(r);
    mockMetaTag(null);

    const result = await _makeRef("noop")({});
    expect(result).toBeNull();
    expect(r.json).not.toHaveBeenCalled();
  });
});

describe("Story 8.1 — FormData branch", () => {
  it("POSTs the FormData as-is with NO manual Content-Type header (browser sets boundary)", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag(null);

    const fd = new FormData();
    fd.append("title", "From form");

    await _makeRef("create_post")(fd);

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe(fd);
    expect(init.headers["Content-Type"]).toBeUndefined();
  });
});

describe("Story 8.1 — CSRF header injection", () => {
  it("attaches X-CSRF-Token header when <meta name=\"csrf-token\"> is present", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag("token-abc123");

    await _makeRef("create_post")({ title: "x" });

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.headers["X-CSRF-Token"]).toBe("token-abc123");
  });

  it("omits X-CSRF-Token header when the meta tag is absent (API mode)", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag(null);

    await _makeRef("create_post")({ title: "x" });

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.headers["X-CSRF-Token"]).toBeUndefined();
  });

  it("works without document defined (Node / SSR contexts)", async () => {
    mockFetchOk({ ok: true });
    globalThis.document = undefined;

    await expect(_makeRef("create_post")({ title: "x" })).resolves.toEqual({ ok: true });
  });
});

describe("Story 8.1 — error responses", () => {
  it("rejects with a structured Error on 4xx responses", async () => {
    mockFetchError(422, "validation failed");
    mockMetaTag(null);

    await expect(_makeRef("create_post")({ title: "" })).rejects.toThrow(
      /ruact action :create_post failed: 422 validation failed/,
    );
  });

  it("rejects with a structured Error on 5xx responses", async () => {
    mockFetchError(500, "boom");
    mockMetaTag(null);

    await expect(_makeRef("create_post")({})).rejects.toThrow(
      /ruact action :create_post failed: 500 boom/,
    );
  });

  it("rejects with a structured Error on fetch network failure", async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new TypeError("Failed to fetch"));
    mockMetaTag(null);

    await expect(_makeRef("create_post")({})).rejects.toThrow(
      /ruact action :create_post request failed: Failed to fetch/,
    );
  });
});

describe("Story 8.1 — Re-run-4 — RuactActionError carries status/body (#6)", () => {
  it("rejects with a RuactActionError exposing status and parsed JSON body on 422", async () => {
    const r = {
      ok: false,
      status: 422,
      headers: { get: (n) => (n.toLowerCase() === "content-type" ? "application/json" : null) },
      text: vi.fn().mockResolvedValue(JSON.stringify({ errors: { title: ["can't be blank"] } })),
      json: vi.fn(),
    };
    globalThis.fetch = vi.fn().mockResolvedValue(r);
    mockMetaTag(null);

    let captured = null;
    try {
      await _makeRef("create_post")({ title: "" });
    } catch (err) {
      captured = err;
    }
    expect(captured).toBeInstanceOf(RuactActionError);
    expect(captured.status).toBe(422);
    expect(captured.actionName).toBe("create_post");
    expect(captured.body).toEqual({ errors: { title: ["can't be blank"] } });
  });

  it("RuactActionError.body holds raw text when the response is not JSON", async () => {
    mockFetchError(500, "boom");
    mockMetaTag(null);

    let captured = null;
    try {
      await _makeRef("create_post")({});
    } catch (err) {
      captured = err;
    }
    expect(captured).toBeInstanceOf(RuactActionError);
    expect(captured.status).toBe(500);
    expect(captured.body).toBe("boom");
  });
});

describe("Story 8.1 — Re-run-4 — +json structured-syntax-suffix media types (#7)", () => {
  it("parses application/problem+json as JSON (RFC 6838 §4.2.8)", async () => {
    const r = {
      ok: true,
      status: 200,
      headers: { get: (n) => (n.toLowerCase() === "content-type" ? "application/problem+json" : null) },
      text: vi.fn().mockResolvedValue(JSON.stringify({ type: "about:blank", title: "ok" })),
      json: vi.fn(),
    };
    globalThis.fetch = vi.fn().mockResolvedValue(r);
    mockMetaTag(null);

    const result = await _makeRef("noop")({});
    expect(result).toEqual({ type: "about:blank", title: "ok" });
  });

  it("parses application/vnd.api+json as JSON", async () => {
    const r = {
      ok: true,
      status: 200,
      headers: { get: (n) => (n.toLowerCase() === "content-type" ? "application/vnd.api+json" : null) },
      text: vi.fn().mockResolvedValue(JSON.stringify({ data: { id: "1" } })),
      json: vi.fn(),
    };
    globalThis.fetch = vi.fn().mockResolvedValue(r);
    mockMetaTag(null);

    const result = await _makeRef("noop")({});
    expect(result).toEqual({ data: { id: "1" } });
  });
});

describe("Story 8.1 — Re-run-3 — URL encoding of name (#6)", () => {
  it("encodeURIComponent's the name so a stray '/' cannot rewrite the path", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag(null);

    await _makeRef("../foo?x=1")({});

    const [url] = globalThis.fetch.mock.calls[0];
    expect(url).toBe("/__ruact/fn/..%2Ffoo%3Fx%3D1");
  });
});

describe("Story 8.1 — Re-run-3 — Content-Type matching is case-insensitive (#5)", () => {
  it("parses JSON when Content-Type is `Application/JSON` (RFC 9110 — case-insensitive media type)", async () => {
    const r = {
      ok: true,
      status: 200,
      headers: { get: (n) => (n.toLowerCase() === "content-type" ? "Application/JSON; charset=utf-8" : null) },
      text: vi.fn().mockResolvedValue('{"id":42}'),
      json: vi.fn(),
    };
    globalThis.fetch = vi.fn().mockResolvedValue(r);
    mockMetaTag(null);

    const result = await _makeRef("noop")({});
    expect(result).toEqual({ id: 42 });
  });
});

describe("Story 8.1 — Re-run-5 — fetch redirect: 'error' (#5)", () => {
  it("sets redirect: 'error' on the fetch init so auth `redirect_to` failures surface as errors", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag(null);

    await _makeRef("create_post")({});

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.redirect).toBe("error");
  });
});

describe("Story 8.1 — Re-run-5 — configureRuactRuntime (#6)", () => {
  afterEach(() => {
    configureRuactRuntime({ defaultHeaders: null });
  });

  it("merges defaultHeaders object into every fetch init", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag(null);
    configureRuactRuntime({ defaultHeaders: { Authorization: "Bearer abc" } });

    await _makeRef("create_post")({});

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.headers.Authorization).toBe("Bearer abc");
  });

  it("calls a defaultHeaders function on every request so tokens can refresh", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag(null);
    let calls = 0;
    configureRuactRuntime({
      defaultHeaders: () => {
        calls += 1;
        return { Authorization: `Bearer t${calls}` };
      },
    });

    await _makeRef("create_post")({});
    await _makeRef("create_post")({});

    expect(globalThis.fetch.mock.calls[0][1].headers.Authorization).toBe("Bearer t1");
    expect(globalThis.fetch.mock.calls[1][1].headers.Authorization).toBe("Bearer t2");
  });

  it("does NOT let defaultHeaders override the gem's CSRF / Accept / Content-Type", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag("real-csrf");
    configureRuactRuntime({
      defaultHeaders: {
        "X-CSRF-Token": "tampered",
        Accept: "text/html",
        "Content-Type": "application/xml",
      },
    });

    await _makeRef("create_post")({});

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.headers["X-CSRF-Token"]).toBe("real-csrf");
    expect(init.headers.Accept).toBe("application/json");
    expect(init.headers["Content-Type"]).toBe("application/json");
  });

  it("rejects non-object/non-function/non-null defaultHeaders", () => {
    expect(() => configureRuactRuntime({ defaultHeaders: "Bearer abc" })).toThrow(
      /must be a plain object or a \(\) => object function/,
    );
  });

  it("strips reserved headers from defaultHeaders case-insensitively (re-run-6 #3)", async () => {
    // HTTP header names are case-insensitive (RFC 9110 §5.1). A host passing
    // `{ accept: "text/html" }` or `{ "content-type": "application/xml" }`
    // must NOT survive into the request: the gem owns these keys regardless
    // of casing.
    mockFetchOk({ ok: true });
    mockMetaTag("real-csrf");
    configureRuactRuntime({
      defaultHeaders: {
        accept: "text/html",
        "content-type": "application/xml",
        "x-csrf-token": "tampered",
        "X-Custom-Header": "kept",
      },
    });

    await _makeRef("create_post")({});

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.headers.Accept).toBe("application/json");
    expect(init.headers["Content-Type"]).toBe("application/json");
    expect(init.headers["X-CSRF-Token"]).toBe("real-csrf");
    expect(init.headers["X-Custom-Header"]).toBe("kept");
    // None of the lowercased reserved keys should leak through.
    expect(init.headers.accept).toBeUndefined();
    expect(init.headers["content-type"]).toBeUndefined();
    expect(init.headers["x-csrf-token"]).toBeUndefined();
  });

  it("does NOT let defaultHeaders set Content-Type for FormData requests (re-run-6 #3)", async () => {
    // FormData branch relies on the browser to set
    // `Content-Type: multipart/form-data; boundary=…`. A surviving
    // `Content-Type` from defaultHeaders would override that and break
    // multipart parsing on the server.
    mockFetchOk({ ok: true });
    configureRuactRuntime({
      defaultHeaders: { "content-type": "application/xml" },
    });

    const fd = new FormData();
    fd.append("title", "Hello");
    await _makeRef("upload")(fd);

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.headers["Content-Type"]).toBeUndefined();
    expect(init.headers["content-type"]).toBeUndefined();
    expect(init.body).toBe(fd);
  });
});

describe("Story 8.1 — __internals (test-only surface)", () => {
  it("exposes buildFetchInit, resolveCsrfToken, parseResponse for granular asserts", () => {
    expect(typeof __internals.buildFetchInit).toBe("function");
    expect(typeof __internals.resolveCsrfToken).toBe("function");
    expect(typeof __internals.parseResponse).toBe("function");
  });

  it("Story 8.2 — exposes pickWirePayload (the two-arg shape-detection helper)", () => {
    expect(typeof __internals.pickWirePayload).toBe("function");
  });
});

// =============================================================================
// Story 8.2 — useActionState two-arg invocation
// =============================================================================

describe("Story 8.2 — _makeRef call-shape detection", () => {
  it("fn() — zero args sends an empty JSON body (parity with Story 8.1 fn() shape)", async () => {
    mockFetchOk({});
    mockMetaTag(null);

    await _makeRef("noop")();

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe("{}");
    expect(init.headers["Content-Type"]).toBe("application/json");
  });

  it("fn(obj) — single plain-object arg sends JSON body (Story 8.1 baseline)", async () => {
    mockFetchOk({});
    mockMetaTag(null);

    await _makeRef("create_post")({ title: "Hi" });

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe(JSON.stringify({ title: "Hi" }));
  });

  it("fn(formData) — single FormData arg sends multipart (Story 8.1 baseline)", async () => {
    mockFetchOk({});
    mockMetaTag(null);

    const fd = new FormData();
    fd.append("title", "Hi");
    await _makeRef("create_post")(fd);

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe(fd);
    expect(init.headers["Content-Type"]).toBeUndefined();
  });

  it("fn(prevState, formData) — useActionState shape; FormData wins, prevState " +
    "is silently discarded (the wire request is IDENTICAL to fn(formData))", async () => {
    mockFetchOk({});
    mockMetaTag(null);

    const fd = new FormData();
    fd.append("title", "From form");
    await _makeRef("create_post")({ message: "previous state" }, fd);

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe(fd);
    expect(init.headers["Content-Type"]).toBeUndefined();
  });

  it("fn(prevState, obj) — both non-FormData (defensive case); the SECOND arg " +
    "is the payload (useActionState ordering), the first is discarded", async () => {
    mockFetchOk({});
    mockMetaTag(null);

    await _makeRef("create_post")({ message: "previous state" }, { title: "Hi" });

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe(JSON.stringify({ title: "Hi" }));
    expect(init.headers["Content-Type"]).toBe("application/json");
  });

  it("fn(formData, obj) — FormData in slot 0 still wins (defensive; not the " +
    "useActionState shape but exercised for completeness)", async () => {
    mockFetchOk({});
    mockMetaTag(null);

    const fd = new FormData();
    fd.append("title", "FD");
    await _makeRef("create_post")(fd, { title: "obj" });

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe(fd);
  });

  it("fn(a, b, c) — three or more args throws TypeError with a descriptive message", () => {
    expect(() => _makeRef("create_post")(1, 2, 3)).toThrow(TypeError);
    expect(() => _makeRef("create_post")(1, 2, 3)).toThrow(
      /ruact action :create_post called with 3 arguments — expected 0, 1, or 2/,
    );
  });

  it("prev-state shape is never serialized to the wire — even when it contains " +
    "non-serializable values (Pitfall #4 — Date / Map / circular refs)", async () => {
    mockFetchOk({});
    mockMetaTag(null);

    const circular = {};
    circular.self = circular;
    const fd = new FormData();
    fd.append("title", "Hi");
    // Pre-Story-8.2 this would have thrown on JSON.stringify(circular). The
    // wire path never sees prevState, so circular references are harmless.
    await expect(
      _makeRef("create_post")(circular, fd),
    ).resolves.not.toThrow();

    const [, init] = globalThis.fetch.mock.calls[0];
    expect(init.body).toBe(fd);
  });
});

// =============================================================================
// Story 8.2 — revalidate() runtime helper
// =============================================================================

describe("Story 8.2 — revalidate()", () => {
  let originalRevalidate;
  let originalLocation;

  beforeEach(() => {
    originalRevalidate = globalThis.__ruact_revalidate;
    originalLocation = globalThis.location;
  });

  afterEach(() => {
    if (originalRevalidate === undefined) delete globalThis.__ruact_revalidate;
    else globalThis.__ruact_revalidate = originalRevalidate;
    if (originalLocation === undefined) {
      // jsdom / browser env — leave the real `location` alone
    } else {
      globalThis.location = originalLocation;
    }
  });

  it("invokes the published handle with location.pathname + location.search when " +
    "no path is provided", async () => {
    const spy = vi.fn().mockResolvedValue(undefined);
    globalThis.__ruact_revalidate = spy;
    globalThis.location = { pathname: "/posts", search: "?page=2" };

    await revalidate();
    expect(spy).toHaveBeenCalledWith("/posts?page=2");
  });

  it("invokes the published handle with the explicit path when one is supplied", async () => {
    const spy = vi.fn().mockResolvedValue(undefined);
    globalThis.__ruact_revalidate = spy;

    await revalidate("/posts");
    expect(spy).toHaveBeenCalledWith("/posts");
  });

  it("invokes the handle with the path even when it does not match location (the " +
    "router decides whether to push history)", async () => {
    const spy = vi.fn().mockResolvedValue(undefined);
    globalThis.__ruact_revalidate = spy;

    await revalidate("/elsewhere?x=1");
    expect(spy).toHaveBeenCalledWith("/elsewhere?x=1");
  });

  it("throws a descriptive error when no router is installed (the published handle " +
    "is missing) — fails loudly instead of silently no-op'ing", async () => {
    if ("__ruact_revalidate" in globalThis) delete globalThis.__ruact_revalidate;

    await expect(revalidate()).rejects.toThrow(
      /ruact: revalidate\(\) called but no router is installed/,
    );
  });

  it("propagates the resolved value (whatever the router returns) so callers can " +
    "`await revalidate()` and then continue", async () => {
    const spy = vi.fn().mockResolvedValue("ok");
    globalThis.__ruact_revalidate = spy;
    globalThis.location = { pathname: "/", search: "" };

    const result = await revalidate();
    expect(result).toBe("ok");
  });

  it("propagates rejections from the router so callers can catch network failures", async () => {
    const error = new Error("Failed to fetch");
    const spy = vi.fn().mockRejectedValue(error);
    globalThis.__ruact_revalidate = spy;
    globalThis.location = { pathname: "/", search: "" };

    await expect(revalidate()).rejects.toThrow("Failed to fetch");
  });
});

describe("Story 9.3 — _makeServerFunction (route-driven, real path+verb)", () => {
  let originalNavigate;
  let originalWindow;

  beforeEach(() => {
    originalNavigate = globalThis.__ruact_navigate;
    originalWindow = globalThis.window;
  });

  afterEach(() => {
    globalThis.__ruact_navigate = originalNavigate;
    globalThis.window = originalWindow;
  });

  it("targets the real path + verb (POST /posts) — not the v1 synthetic endpoint", async () => {
    mockFetchOk({ post: { id: 1 } });
    const createPost = _makeServerFunction({ method: "POST", path: "/posts", segments: [] });

    const result = await createPost({ title: "Hi" });

    const [url, init] = globalThis.fetch.mock.calls[0];
    expect(url).toBe("/posts");
    expect(init.method).toBe("POST");
    expect(init.redirect).toBe("error");
    expect(JSON.parse(init.body)).toEqual({ title: "Hi" });
    expect(result).toEqual({ post: { id: 1 } });
  });

  it("interpolates a :id segment from an object argument into the URL (PUT /posts/5)", async () => {
    mockFetchOk(null, { status: 204, contentType: "text/plain" });
    const updatePost = _makeServerFunction({ method: "PATCH", path: "/posts/:id", segments: ["id"] });

    await updatePost({ id: 5, title: "Edited" });

    const [url, init] = globalThis.fetch.mock.calls[0];
    expect(url).toBe("/posts/5");
    expect(init.method).toBe("PATCH");
    // The id stays in the body too — Rails reads it from the path; harmless dup.
    expect(JSON.parse(init.body)).toEqual({ id: 5, title: "Edited" });
  });

  it("interpolates a :id segment read from FormData and keeps the multipart body", async () => {
    mockFetchOk({ ok: true });
    const fd = new FormData();
    fd.append("id", "42");
    fd.append("title", "x");
    const updatePost = _makeServerFunction({ method: "PATCH", path: "/posts/:id", segments: ["id"] });

    await updatePost(fd);

    const [url, init] = globalThis.fetch.mock.calls[0];
    expect(url).toBe("/posts/42");
    expect(init.body).toBe(fd); // FormData passed through (browser sets multipart boundary)
    expect(init.headers["Content-Type"]).toBeUndefined();
  });

  it("URL-encodes interpolated segment values", async () => {
    mockFetchOk({ ok: true });
    const showThing = _makeServerFunction({ method: "DELETE", path: "/things/:slug", segments: ["slug"] });

    await showThing({ slug: "a/b c" });

    expect(globalThis.fetch.mock.calls[0][0]).toBe("/things/a%2Fb%20c");
  });

  it("throws a clear TypeError when a required segment is missing", async () => {
    mockFetchOk({ ok: true });
    const updatePost = _makeServerFunction({ method: "PATCH", path: "/posts/:id", segments: ["id"] });

    await expect(updatePost({ title: "no id here" })).rejects.toThrow(/path segment ":id"/);
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it("injects the CSRF meta-tag token as X-CSRF-Token (NFR27 preserved)", async () => {
    mockFetchOk({ ok: true });
    mockMetaTag("tok-9-3");
    const createPost = _makeServerFunction({ method: "POST", path: "/posts", segments: [] });

    await createPost({ title: "x" });

    expect(globalThis.fetch.mock.calls[0][1].headers["X-CSRF-Token"]).toBe("tok-9-3");
  });

  it("wraps a non-2xx response in RuactActionError (status + body preserved)", async () => {
    mockFetchError(422, JSON.stringify({ error: "invalid" }));
    const createPost = _makeServerFunction({ method: "POST", path: "/posts", segments: [] });

    await expect(createPost({ title: "" })).rejects.toMatchObject({
      name: "RuactActionError",
      status: 422,
    });
  });

  it("resolves null on an empty (204) body (matches the v1 empty-body contract)", async () => {
    mockFetchOk("", { status: 204, contentType: "text/plain" });
    const createPost = _makeServerFunction({ method: "POST", path: "/posts", segments: [] });

    await expect(createPost({})).resolves.toBeNull();
  });

  it("follows a { $redirect } response via globalThis.__ruact_navigate and resolves null (AC8)", async () => {
    mockFetchOk({ $redirect: "/posts/1" });
    const navSpy = vi.fn();
    globalThis.__ruact_navigate = navSpy;
    const createPost = _makeServerFunction({ method: "POST", path: "/posts", segments: [] });

    const result = await createPost({ title: "x" });

    expect(navSpy).toHaveBeenCalledWith("/posts/1");
    expect(result).toBeNull();
  });

  it("falls back to window.location.assign for $redirect when no router is installed", async () => {
    mockFetchOk({ $redirect: "/posts/2" });
    globalThis.__ruact_navigate = undefined;
    const assignSpy = vi.fn();
    globalThis.window = { location: { assign: assignSpy } };
    const createPost = _makeServerFunction({ method: "POST", path: "/posts", segments: [] });

    const result = await createPost({ title: "x" });

    expect(assignSpy).toHaveBeenCalledWith("/posts/2");
    expect(result).toBeNull();
  });

  it("does NOT treat an ordinary object body with no $redirect as a redirect", async () => {
    mockFetchOk({ post: { id: 1 }, $redirect: 42 }); // $redirect not a string → ignored
    const navSpy = vi.fn();
    globalThis.__ruact_navigate = navSpy;
    const createPost = _makeServerFunction({ method: "POST", path: "/posts", segments: [] });

    const result = await createPost({});

    expect(navSpy).not.toHaveBeenCalled();
    expect(result).toEqual({ post: { id: 1 }, $redirect: 42 });
  });
});
