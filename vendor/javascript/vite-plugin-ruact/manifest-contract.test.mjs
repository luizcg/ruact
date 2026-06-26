// Story 13.5 (FR100) — buildManifest contract extraction.
//
// A component opts into a call-site contract by exporting `__ruactContract`.
// The scanner extracts it NAMES-ONLY into an optional `contract` field on the
// manifest entry. A component without the export emits NO `contract` field
// (byte-additive). A malformed declaration is warned + skipped (fail open).

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { buildManifest, extractContract } from "./index.js";

let dir;
beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "ruact-13-5-"));
});
afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

function writeComponent(name, body) {
  fs.writeFileSync(path.join(dir, name), body);
}

describe("buildManifest — contract extraction (Story 13.5)", () => {
  it("attaches a `contract` field when the component exports __ruactContract", () => {
    writeComponent(
      "LikeButton.tsx",
      [
        '"use client";',
        "export const __ruactContract = {",
        '  props: { postId: "required", initialCount: "optional" },',
        "};",
        "export function LikeButton() { return null; }",
      ].join("\n")
    );

    const manifest = buildManifest(dir);

    expect(manifest.LikeButton.contract).toEqual({
      props: { postId: "required", initialCount: "optional" },
    });
    // The base entry shape is untouched.
    expect(manifest.LikeButton.id).toBe("/LikeButton.tsx");
    expect(manifest.LikeButton.name).toBe("LikeButton");
  });

  it("emits NO `contract` field when the component declares none (byte-additive)", () => {
    writeComponent(
      "Plain.tsx",
      ['"use client";', "export function Plain() { return null; }"].join("\n")
    );

    const manifest = buildManifest(dir);

    expect(manifest.Plain).toBeDefined();
    expect("contract" in manifest.Plain).toBe(false);
  });

  it("extracts slots (object form) and passthrough", () => {
    writeComponent(
      "Card.tsx",
      [
        '"use client";',
        "export const __ruactContract = {",
        '  props: { title: "required" },',
        '  slots: { header: "optional", footer: "required" },',
        "  passthrough: true,",
        "};",
        "export const Card = () => null;",
      ].join("\n")
    );

    const manifest = buildManifest(dir);

    expect(manifest.Card.contract).toEqual({
      props: { title: "required" },
      slots: { header: "optional", footer: "required" },
      passthrough: true,
    });
  });

  it("extracts slots in array form (all optional)", () => {
    const c = extractContract(
      [
        "export const __ruactContract = {",
        '  props: { title: "required" },',
        '  slots: ["header", "footer"],',
        "};",
      ].join("\n"),
      "Card.tsx"
    );
    expect(c).toEqual({
      props: { title: "required" },
      slots: { header: "optional", footer: "optional" },
    });
  });

  it("handles nested braces in prop values without breaking balance", () => {
    const c = extractContract(
      [
        "export const __ruactContract = {",
        "  props: { a: { required: true }, b: { required: false } },",
        "};",
      ].join("\n"),
      "Nested.tsx"
    );
    expect(c).toEqual({ props: { a: "required", b: "optional" } });
  });

  it("warns and skips a malformed declaration (unbalanced braces) → null", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const c = extractContract(
      "export const __ruactContract = { props: { a: 'required' ",
      "Broken.tsx"
    );
    expect(c).toBeNull();
    expect(warn).toHaveBeenCalledOnce();
    warn.mockRestore();
  });

  it("warns and skips an information-less declaration → null", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const c = extractContract("export const __ruactContract = {};", "Empty.tsx");
    expect(c).toBeNull();
    warn.mockRestore();
  });

  it("returns null when there is no __ruactContract export", () => {
    expect(extractContract("export const Foo = 1;", "None.tsx")).toBeNull();
  });

  it("does not treat __ruactContract itself as a component export", () => {
    writeComponent(
      "Widget.tsx",
      [
        '"use client";',
        'export const __ruactContract = { props: { x: "required" } };',
        "export function Widget() { return null; }",
      ].join("\n")
    );
    const manifest = buildManifest(dir);
    expect(Object.keys(manifest)).toEqual(["Widget"]);
  });
});
