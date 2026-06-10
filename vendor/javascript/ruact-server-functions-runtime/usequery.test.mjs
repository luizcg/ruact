// @vitest-environment jsdom
//
// Story 9.5 — vitest coverage for the read-side runtime: the `useQuery` React
// hook (loading/data/error transitions, param passing, value-stable refetch)
// and the `_makeQuery` GET wire format (query-string encoding, FR88 primitive
// allowlist, CSRF-free init). Runs under jsdom so `@testing-library/react`'s
// `renderHook` can drive the hook through React's effect lifecycle.

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";

import { useQuery, _makeQuery, RuactActionError, __internals } from "./index.js";

let originalFetch;

beforeEach(() => {
  originalFetch = globalThis.fetch;
});

afterEach(() => {
  globalThis.fetch = originalFetch;
  vi.restoreAllMocks();
});

function mockFetchOk(jsonBody, { status = 200, contentType = "application/json" } = {}) {
  const response = {
    ok: true,
    status,
    headers: { get: (n) => (n.toLowerCase() === "content-type" ? contentType : null) },
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
  };
  globalThis.fetch = vi.fn().mockResolvedValue(response);
  return response;
}

describe("Story 9.5 — useQuery hook contract", () => {
  it("starts loading, then resolves to { data, loading: false, error: null }", async () => {
    const ref = vi.fn().mockResolvedValue({ items: [1, 2] });
    const { result } = renderHook(() => useQuery(ref));

    expect(result.current.loading).toBe(true);
    expect(result.current.data).toBeUndefined();

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.data).toEqual({ items: [1, 2] });
    expect(result.current.error).toBe(null);
  });

  it("transitions loading → error on a rejected reference", async () => {
    const err = new RuactActionError({ name: "/q/categories", status: 500, body: "boom", response: {} });
    const ref = vi.fn().mockRejectedValue(err);
    const { result } = renderHook(() => useQuery(ref));

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.error).toBe(err);
    expect(result.current.data).toBeUndefined();
  });

  it("passes params to the query reference", async () => {
    const ref = vi.fn().mockResolvedValue("ok");
    const params = { q: "ruby", limit: 5 };
    renderHook(() => useQuery(ref, params));

    await waitFor(() => expect(ref).toHaveBeenCalledTimes(1));
    expect(ref).toHaveBeenCalledWith(params);
  });

  it("does not refetch when params are value-equal across renders", async () => {
    const ref = vi.fn().mockResolvedValue("ok");
    const { rerender } = renderHook(({ p }) => useQuery(ref, p), {
      initialProps: { p: { q: "a" } },
    });
    await waitFor(() => expect(ref).toHaveBeenCalledTimes(1));

    rerender({ p: { q: "a" } }); // fresh object literal, identical value
    await Promise.resolve();
    expect(ref).toHaveBeenCalledTimes(1);
  });

  it("refetches when params change by value", async () => {
    const ref = vi.fn().mockResolvedValue("ok");
    const { rerender } = renderHook(({ p }) => useQuery(ref, p), {
      initialProps: { p: { q: "a" } },
    });
    await waitFor(() => expect(ref).toHaveBeenCalledTimes(1));

    rerender({ p: { q: "b" } });
    await waitFor(() => expect(ref).toHaveBeenCalledTimes(2));
    expect(ref).toHaveBeenLastCalledWith({ q: "b" });
  });

  it("surfaces a synchronous throw from the reference as an error (not an unhandled rejection)", async () => {
    const ref = () => {
      throw new TypeError("params must be a plain object");
    };
    const { result } = renderHook(() => useQuery(ref, [1, 2]));
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.error).toBeInstanceOf(TypeError);
  });
});

describe("Story 9.5 — useQuery against _makeQuery end-to-end (GET wire)", () => {
  it("issues GET /q/<id>?<params> and resolves the JSON body through the hook", async () => {
    mockFetchOk([{ value: 1, label: "Books" }]);
    const categories = _makeQuery({ path: "/q/categories", kind: "query" });

    const { result } = renderHook(() => useQuery(categories, { q: "bo" }));
    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(globalThis.fetch).toHaveBeenCalledTimes(1);
    const [url, init] = globalThis.fetch.mock.calls[0];
    expect(url).toBe("/q/categories?q=bo");
    expect(init.method).toBe("GET");
    expect(result.current.data).toEqual([{ value: 1, label: "Books" }]);
  });

  it("carries the structured RuactActionError into the hook's error on a 4xx", async () => {
    mockFetchError(400, "bad");
    const search = _makeQuery({ path: "/q/search", kind: "query" });

    const { result } = renderHook(() => useQuery(search));
    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.error).toBeInstanceOf(RuactActionError);
    expect(result.current.error.status).toBe(400);
  });
});

describe("Story 9.5 — _makeQuery / buildQueryUrl wire format (FR88)", () => {
  const { buildQueryUrl, buildQueryFetchInit } = __internals;

  it("omits the query string entirely when no params are given", () => {
    expect(buildQueryUrl("/q/categories", undefined)).toBe("/q/categories");
    expect(buildQueryUrl("/q/categories", null)).toBe("/q/categories");
    expect(buildQueryUrl("/q/categories", {})).toBe("/q/categories");
  });

  it("encodes string / number / boolean primitives", () => {
    expect(buildQueryUrl("/q/search", { q: "a b", limit: 5, active: true })).toBe(
      "/q/search?q=a+b&limit=5&active=true",
    );
  });

  it("encodes null as a BARE key (Rack parses `?q` as nil, distinct from `?q=` empty string)", () => {
    expect(buildQueryUrl("/q/search", { q: null })).toBe("/q/search?q");
    // value-bearing params keep `key=value`; a null alongside is a bare key
    expect(buildQueryUrl("/q/search", { limit: 5, q: null })).toBe("/q/search?limit=5&q");
  });

  it("rejects an array value (FR88 — arrays are not primitives)", () => {
    expect(() => buildQueryUrl("/q/search", { q: [1, 2] })).toThrow(/arrays and objects are rejected/);
  });

  it("rejects an object value", () => {
    expect(() => buildQueryUrl("/q/search", { q: { deep: 1 } })).toThrow(/arrays and objects are rejected/);
  });

  it("rejects a top-level array of params", () => {
    expect(() => buildQueryUrl("/q/search", [1, 2])).toThrow(/plain object/);
  });

  it("builds a GET init with Accept JSON, no body, no CSRF, redirect: error", () => {
    const init = buildQueryFetchInit();
    expect(init.method).toBe("GET");
    expect(init.body).toBeUndefined();
    expect(init.headers.Accept).toBe("application/json");
    expect(init.headers["X-CSRF-Token"]).toBeUndefined();
    expect(init.redirect).toBe("error");
  });
});
