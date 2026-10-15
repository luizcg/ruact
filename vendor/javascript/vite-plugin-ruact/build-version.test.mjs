// Story 19-3 — the manifest says which ruact built it. Every manifest the
// plugin writes or serves (the build, the dev server's file, its
// GET /__ruact/manifest) carries `__ruact__: { version }`, the gem's version read
// from `lib/ruact/version.rb` beside the plugin; the in-memory manifest the
// registry is generated from never does.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import ruact, { BUILD_KEY, readRuactVersion, withBuild, buildManifest, generateRegistrySource } from "./index.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const GEM_VERSION = fs
  .readFileSync(path.resolve(here, "../../../lib/ruact/version.rb"), "utf8")
  .match(/VERSION = "([^"]+)"/)[1];

let dir;
beforeEach(() => {
  dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "ruact-build-version-")));
  const file = path.join(dir, "app/javascript/components/LikeButton.jsx");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `"use client";\nexport function LikeButton() { return null; }\n`);
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

function server() {
  const middlewares = new Map();
  const handlers = {};
  return {
    middlewares: { use: (route, fn) => middlewares.set(route, fn) },
    moduleGraph: { getModuleById: () => null, invalidateModule: () => {} },
    ws: { send: () => {} },
    watcher: { add: () => {}, on: (event, fn) => (handlers[event] ||= []).push(fn) },
    get(route) {
      let body = "";
      middlewares.get(route)({ url: route, method: "GET" }, { setHeader: () => {}, end: (b) => (body = b) }, () => {});
      return JSON.parse(body);
    },
    change(file) {
      for (const fn of handlers.change) fn(file);
    },
  };
}

async function boot() {
  const warnings = [];
  const plugin = ruact();
  await plugin.configResolved({ root: dir, logger: { info: () => {}, warn: (m) => warnings.push(m) } });
  await plugin.buildStart({});
  const dev = server();
  await plugin.configureServer(dev);
  return { dev, warnings };
}

const written = () => JSON.parse(fs.readFileSync(path.join(dir, "public/react-client-manifest.json"), "utf8"));

describe("the build's version in the manifest (Story 19-3)", () => {
  it("reads the gem's version from lib/ruact/version.rb", () => {
    expect(readRuactVersion()).toBe(GEM_VERSION);
  });

  it("is null for a plugin that is not inside a gem", () => {
    expect(readRuactVersion(path.join(dir, "lib/ruact/version.rb"))).toBeNull();
    fs.mkdirSync(path.join(dir, "lib/ruact"), { recursive: true });
    fs.writeFileSync(path.join(dir, "lib/ruact/version.rb"), "module Ruact; end\n");
    expect(readRuactVersion(path.join(dir, "lib/ruact/version.rb"))).toBeNull();
  });

  it("the file buildStart writes carries it first", async () => {
    const { warnings } = await boot();
    const manifest = written();
    expect(Object.keys(manifest)).toEqual([BUILD_KEY, "LikeButton"]);
    expect(manifest[BUILD_KEY]).toEqual({ version: GEM_VERSION });
    expect(warnings).toEqual([]);
  });

  it("GET /__ruact/manifest carries it, and the file the watcher rewrites does too", async () => {
    const { dev } = await boot();
    expect(dev.get("/__ruact/manifest")[BUILD_KEY]).toEqual({ version: GEM_VERSION });

    const added = path.join(dir, "app/javascript/components/CommentBox.jsx");
    fs.writeFileSync(added, `"use client";\nexport function CommentBox() { return null; }\n`);
    dev.change(added);
    expect(Object.keys(written())).toEqual([BUILD_KEY, "CommentBox", "LikeButton"]);
    expect(Object.keys(dev.get("/__ruact/manifest"))).toEqual([BUILD_KEY, "CommentBox", "LikeButton"]);
  });

  it("never reaches the registry", () => {
    const manifest = buildManifest(path.join(dir, "app/javascript/components"));
    expect(manifest).not.toHaveProperty(BUILD_KEY);
    expect(generateRegistrySource(manifest)).not.toContain(BUILD_KEY);
  });

  it("without a version, the manifest is the components only", () => {
    const manifest = { LikeButton: { id: "/LikeButton.jsx", name: "LikeButton", chunks: [] } };
    expect(withBuild(manifest, null)).toBe(manifest);
    expect(Object.keys(withBuild(manifest, "1.2.3"))).toEqual([BUILD_KEY, "LikeButton"]);
  });
});
