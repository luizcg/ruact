// Story 8.1 — vitest suite for the real server-functions runtime.
//
// Covers AC10 of Story 8.1: argument-shape branching (JSON vs FormData),
// CSRF meta-tag injection, success vs. failure response handling, and
// error wrapping. Uses `vi.fn()` to stub `fetch` — no real network.

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { _makeRef, __RUNTIME_VERSION__, __internals } from "./index.js";

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

describe("Story 8.1 — __internals (test-only surface)", () => {
  it("exposes buildFetchInit, resolveCsrfToken, parseResponse for granular asserts", () => {
    expect(typeof __internals.buildFetchInit).toBe("function");
    expect(typeof __internals.resolveCsrfToken).toBe("function");
    expect(typeof __internals.parseResponse).toBe("function");
  });
});
