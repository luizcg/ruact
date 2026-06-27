// Story 10.1b (component auto-registry) — the build emits MODULE_REGISTRY.
//
// vite-plugin-ruact exposes a virtual module (`virtual:ruact/registry`) whose
// default export is `{ [manifest id]: moduleExports }`, derived from the SAME
// scan that writes react-client-manifest.json. This file covers:
//
//   1. generateRegistrySource — the pure renderer (keys == manifest ids,
//      one import per source file, membership == manifest membership).
//   2. dev id-match — registry keys equal the manifest `id` the gem serializes
//      as the Flight moduleId (source-relative in dev).
//   3. prod id-match (LOAD-BEARING, AC2/NFR16) — a REAL `vite build` through the
//      plugin: the emitted manifest ids equal the built registry keys, proving
//      dev/prod parity (the eager registry inlines components, so the
//      hashed-URL rewrite never fires and the id stays source-relative in prod).

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { build } from "vite";
import {
  buildManifest,
  generateRegistrySource,
  REGISTRY_VIRTUAL_ID,
} from "./index.js";
import ruact from "./index.js";

let dir;
beforeEach(() => {
  // realpath so the dir matches Rollup's symlink-resolved `facadeModuleId`
  // (macOS /tmp → /private/tmp); the build's id-rewrite match keys off it.
  dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "ruact-10-1b-")));
});
afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

function write(rel, body) {
  const full = path.join(dir, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, body);
}

const USE_CLIENT = '"use client";';

describe("generateRegistrySource (Story 10.1b)", () => {
  it("keys the registry on the manifest `id` and imports the source file", () => {
    write("PostList.jsx", [USE_CLIENT, "export function PostList() { return null; }"].join("\n"));
    const manifest = buildManifest(dir);
    const src = generateRegistrySource(manifest);

    // Key == the manifest id the gem serializes as the Flight moduleId.
    expect(manifest.PostList.id).toBe("/PostList.jsx");
    expect(src).toContain('"/PostList.jsx":');
    // Imports the absolute source file (forward-slashed specifier).
    expect(src).toContain(`import * as __ruact_m0 from "${path.join(dir, "PostList.jsx").replace(/\\/g, "/")}"`);
    expect(src).toContain("export default MODULE_REGISTRY;");
  });

  it("emits exactly one import per source file even with multiple exports", () => {
    write(
      "Pair.jsx",
      [USE_CLIENT, "export function Primary() { return null; }", "export function Secondary() { return null; }"].join("\n")
    );
    const src = generateRegistrySource(buildManifest(dir));
    // Both exports share the same id ("/Pair.jsx") → one import, one entry.
    expect((src.match(/import \* as/g) || []).length).toBe(1);
    expect((src.match(/"\/Pair\.jsx":/g) || []).length).toBe(1);
  });

  it("registry membership equals manifest membership (use-client only, .jsx/.tsx, nested)", () => {
    write("Client.jsx", [USE_CLIENT, "export function Client() { return null; }"].join("\n"));
    write("Typed.tsx", [USE_CLIENT, "export function Typed() { return null; }"].join("\n"));
    write("ui/Button.jsx", [USE_CLIENT, "export function Button() { return null; }"].join("\n"));
    // NOT registered: no "use client" directive.
    write("ServerOnly.jsx", ["export function ServerOnly() { return null; }"].join("\n"));

    const manifest = buildManifest(dir);
    const src = generateRegistrySource(manifest);

    expect(src).toContain('"/Client.jsx":');
    expect(src).toContain('"/Typed.tsx":');
    expect(src).toContain('"/ui/Button.jsx":'); // nested path preserved
    expect(src).not.toContain("ServerOnly");
    // Exactly the manifest ids, nothing more.
    const ids = new Set(Object.values(manifest).map((e) => e.id));
    for (const id of ids) expect(src).toContain(`${JSON.stringify(id)}:`);
  });

  it("renders an empty registry for a manifest with no components", () => {
    const src = generateRegistrySource({});
    expect(src).toContain("const MODULE_REGISTRY = {");
    expect(src).toContain("export default MODULE_REGISTRY;");
    expect(src).not.toContain("import * as");
  });
});

describe("dev id-match invariant (Story 10.1b AC2)", () => {
  it("registry keys equal the source-relative manifest ids (dev form)", () => {
    write("PostList.jsx", [USE_CLIENT, "export function PostList() { return null; }"].join("\n"));
    write("ui/Button.tsx", [USE_CLIENT, "export function Button() { return null; }"].join("\n"));
    const manifest = buildManifest(dir);
    const src = generateRegistrySource(manifest);

    for (const entry of Object.values(manifest)) {
      // entry.id is what client_manifest.rb serializes as moduleId; the registry
      // MUST carry that exact key so moduleRegistry[moduleId] resolves.
      expect(src).toContain(`${JSON.stringify(entry.id)}:`);
    }
    expect(manifest.PostList.id).toBe("/PostList.jsx");
    expect(manifest.Button.id).toBe("/ui/Button.tsx");
  });
});

describe("prod id-match invariant — real vite build (Story 10.1b AC2, LOAD-BEARING)", () => {
  it("a built bundle resolves every manifest id through the emitted registry", async () => {
    // Plain-JS components (no JSX/react) so the built bundle is self-contained
    // and importable in node — the invariant under test is id↔key parity, not
    // rendering. The eager registry inlines these into the entry chunk.
    write("components/PostList.js", [USE_CLIENT, "export function PostList() { return 'PostList'; }"].join("\n"));
    write("components/PostForm.js", [USE_CLIENT, "export function PostForm() { return 'PostForm'; }"].join("\n"));
    write("components/ui/Button.js", [USE_CLIENT, "export function Button() { return 'Button'; }"].join("\n"));
    // Entry re-exports the auto-registry so we can inspect it post-build.
    write("entry.js", `export { default as registry } from ${JSON.stringify(REGISTRY_VIRTUAL_ID)};`);

    await build({
      root: dir,
      logLevel: "silent",
      plugins: [ruact({ componentsDir: "components" })],
      build: {
        outDir: "dist",
        write: true,
        minify: false,
        rollupOptions: {
          input: path.join(dir, "entry.js"),
          // Keep the entry's `registry` export (a Vite app build otherwise
          // tree-shakes unused entry exports, emptying the chunk).
          preserveEntrySignatures: "strict",
          output: { entryFileNames: "entry.js", format: "es" },
        },
      },
    });

    // The manifest the gem will read (ids === Flight moduleIds).
    const manifest = JSON.parse(
      fs.readFileSync(path.join(dir, "public/react-client-manifest.json"), "utf8")
    );
    const manifestIds = new Set(Object.values(manifest).map((e) => e.id));

    // Prod ids stay source-relative (eager-inlined components → no facade chunk
    // → generateBundle's hashed-URL rewrite never fires). This is the dev/prod
    // parity guarantee (NFR16).
    expect(manifestIds).toEqual(new Set(["/PostList.js", "/PostForm.js", "/ui/Button.js"]));

    // The built registry's keys equal the manifest ids exactly, and each value
    // exposes the component export the Flight client looks up (mod[exportName]).
    const built = await import(pathToFileURL(path.join(dir, "dist/entry.js")).href);
    const registry = built.registry;
    expect(new Set(Object.keys(registry))).toEqual(manifestIds);
    for (const [name, entry] of Object.entries(manifest)) {
      // moduleRegistry[moduleId][exportName] must be defined for every manifest entry.
      expect(registry[entry.id][entry.name]).toBeTypeOf("function");
      expect(registry[entry.id][entry.name]()).toBe(name);
    }
  }, 30000);

  it("FAILS the build loudly if a component becomes a hashed facade chunk (no silent miss)", async () => {
    // The hazardous branch: a component is ALSO a Rollup entry → it gets its own
    // hashed facade chunk → generateBundle would rewrite its manifest id to the
    // hashed URL while the registry still keys it by source path. The id-match
    // guard must turn that into a build error, not a silent prod hydration miss.
    write("components/PostList.js", [USE_CLIENT, "export function PostList() { return 'PostList'; }"].join("\n"));
    write("entry.js", `export { default as registry } from ${JSON.stringify(REGISTRY_VIRTUAL_ID)};`);

    await expect(
      build({
        root: dir,
        logLevel: "silent",
        plugins: [ruact({ componentsDir: "components" })],
        build: {
          outDir: "dist",
          write: false,
          minify: false,
          rollupOptions: {
            // Force the component to be its own entry → hashed facade chunk.
            input: {
              entry: path.join(dir, "entry.js"),
              PostList: path.join(dir, "components/PostList.js"),
            },
            preserveEntrySignatures: "strict",
            // Hashed names mirror a real prod build (the rewrite the guard catches).
            output: { entryFileNames: "[name]-[hash].js", format: "es" },
          },
        },
      })
    ).rejects.toThrow(/silent hydration miss|standalone .* chunks/i);
  }, 30000);
});
