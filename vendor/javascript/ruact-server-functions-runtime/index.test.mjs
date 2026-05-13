// Placeholder runtime smoke test (Story 8.0a Task 5.4).
//
// Confirms two contracts that the codegen relies on:
//   1. `_makeRef(name)` is callable and returns a function.
//   2. The returned function rejects with a clear "Story 8.1 not installed"
//      message at call time.
//
// Story 8.1 swaps the implementation behind these tests; the assertions here
// must be migrated together with the implementation, not removed.

import { describe, it, expect } from "vitest";
import { _makeRef, __PLACEHOLDER__ } from "./index.js";

describe("placeholder server-functions runtime (Story 8.0a)", () => {
  it("exports a sentinel that confirms the placeholder is in use", () => {
    expect(__PLACEHOLDER__).toBe(true);
  });

  it("_makeRef returns a callable accessor", () => {
    const ref = _makeRef("create_post");
    expect(typeof ref).toBe("function");
  });

  it("calling the accessor rejects with a Story-8.1-pointer error", async () => {
    const ref = _makeRef("create_post");
    await expect(ref({ title: "x" })).rejects.toThrow(
      /server functions runtime not implemented yet/,
    );
  });

  it("the rejection message includes the registered symbol name", async () => {
    const ref = _makeRef("my_demo");
    await expect(ref()).rejects.toThrow(/my_demo/);
  });
});
