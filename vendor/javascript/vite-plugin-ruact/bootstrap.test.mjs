// Story 14.2 (FR104) — the bootstrap virtual module.
//
// ruact's React entry is no longer a `app/javascript/application.jsx` file in
// the user's tree; it is served as the virtual module `virtual:ruact/bootstrap`
// from gem-shipped source (`runtime/bootstrap.jsx`), mirroring the existing
// `virtual:ruact/registry` pattern. This file covers the plugin contract:
//
//   1. resolveId maps the public id → the `\0`-prefixed resolved id.
//   2. load serves the bootstrap source, importing `virtual:ruact/registry` +
//      React (from the app root → single React instance) + the runtime modules
//      via ABSOLUTE fs specifiers (relative imports do not resolve from a
//      `\0virtual:` id).
//   3. generateBootstrapSource rewrites ONLY the import specifiers (not prose
//      mentions in comments) and emits no JSX (loads via Vite's default loader).

import { describe, it, expect } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import ruact, {
  BOOTSTRAP_VIRTUAL_ID,
  REGISTRY_VIRTUAL_ID,
  generateBootstrapSource,
} from "./index.js";

const RESOLVED = "\0" + BOOTSTRAP_VIRTUAL_ID;

describe("virtual:ruact/bootstrap — resolveId (Story 14.2)", () => {
  it("resolves the public id to the \\0-prefixed resolved id", () => {
    const plugin = ruact();
    expect(plugin.resolveId(BOOTSTRAP_VIRTUAL_ID)).toBe(RESOLVED);
  });

  it("returns null for unrelated ids (and leaves the registry id intact)", () => {
    const plugin = ruact();
    expect(plugin.resolveId("react")).toBeNull();
    // The bootstrap branch must not regress the registry branch.
    expect(plugin.resolveId(REGISTRY_VIRTUAL_ID)).toBe("\0" + REGISTRY_VIRTUAL_ID);
  });
});

describe("virtual:ruact/bootstrap — load (Story 14.2)", () => {
  const plugin = ruact();
  const src = plugin.load(RESOLVED);

  it("imports virtual:ruact/registry (10.1b auto-registry preserved)", () => {
    expect(src).toContain("from 'virtual:ruact/registry'");
  });

  it("imports React and react-dom/client as BARE specifiers (single React from app root)", () => {
    expect(src).toMatch(/from 'react'/);
    expect(src).toContain("from 'react-dom/client'");
  });

  it("imports the runtime modules via ABSOLUTE fs specifiers, not relative", () => {
    expect(src).toMatch(/from '\/.*\/runtime\/flight-client\.js'/);
    expect(src).toMatch(/from '\/.*\/runtime\/ruact-router\.js'/);
    // No `\0virtual:`-unresolvable relative import survives.
    expect(src).not.toMatch(/from\s+['"]\.\/flight-client\.js['"]/);
    expect(src).not.toMatch(/from\s+['"]\.\/ruact-router\.js['"]/);
  });

  it("contains no JSX syntax (loads via the default loader like the registry)", () => {
    expect(src).not.toContain("<App");
    expect(src).toContain("createElement(App)");
  });

  it("returns null for the registry id via the same load hook (no cross-wiring)", () => {
    // The registry load still works; the bootstrap branch is additive.
    expect(plugin.load("\0" + REGISTRY_VIRTUAL_ID)).toContain("MODULE_REGISTRY");
  });
});

describe("generateBootstrapSource — rewrites imports only (Story 14.2)", () => {
  it("rewrites the runtime import specifiers but leaves a prose mention untouched", () => {
    const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "ruact-boot-")));
    // A bootstrap whose COMMENT mentions ./flight-client.js and whose IMPORT
    // uses it — only the import specifier must be rewritten.
    fs.writeFileSync(
      path.join(dir, "bootstrap.jsx"),
      [
        "// reads ./flight-client.js at boot",
        "import { createFromFlightPayload } from './flight-client.js';",
        "import { setupRouter } from './ruact-router.js';",
        "export const ok = true;",
      ].join("\n"),
    );
    const out = generateBootstrapSource(dir);
    const fc = path.join(dir, "flight-client.js").replace(/\\/g, "/");
    expect(out).toContain(`from '${fc}'`);
    // The comment's bare mention is preserved (not a `from '...'` import).
    expect(out).toContain("// reads ./flight-client.js at boot");
    expect(out).not.toMatch(/from\s+['"]\.\/flight-client\.js['"]/);
    fs.rmSync(dir, { recursive: true, force: true });
  });
});
