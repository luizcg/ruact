// Fix (manifest-over-HTTP) — the dev server exposes the live in-memory manifest
// at GET /__ruact/manifest so the Rails gem can resolve components without
// racing the on-disk react-client-manifest.json write at boot. This file
// covers the configureServer middleware:
//
//   1. responds with the current manifest (no internal `_sourceFile` field);
//   2. reflects a rebuild when a "use client" component is added/changed.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import ruact from "./index.js";

let dir;
beforeEach(() => {
  dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "ruact-manifest-http-")));
});
afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

function write(rel, body) {
  const full = path.join(dir, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, body);
  return full;
}

const COMPONENT = (name) =>
  `"use client";\nexport function ${name}() { return null; }\n`;

// A minimal connect-style server harness: captures the path-mounted middleware
// and the watcher callbacks the plugin registers in configureServer.
function makeServer() {
  const middlewares = new Map();
  const watcherHandlers = { change: [], add: [], unlink: [] };
  return {
    middlewares: { use: (route, fn) => middlewares.set(route, fn) },
    moduleGraph: { getModuleById: () => null, invalidateModule: () => {} },
    ws: { send: () => {} },
    watcher: {
      add: () => {},
      on: (event, fn) => {
        (watcherHandlers[event] ||= []).push(fn);
      },
    },
    _invokeMiddleware(route, method = "GET") {
      const fn = middlewares.get(route);
      let body = "";
      let nextCalled = false;
      const headers = {};
      const res = {
        setHeader: (k, v) => {
          headers[k] = v;
        },
        end: (chunk) => {
          body = chunk;
        },
      };
      fn({ url: route, method }, res, () => {
        nextCalled = true;
      });
      return { body, headers, nextCalled };
    },
    _fireChange(file) {
      for (const fn of watcherHandlers.change) fn(file);
    },
  };
}

async function bootPlugin() {
  const plugin = ruact();
  await plugin.configResolved({ root: dir });
  await plugin.buildStart({});
  const server = makeServer();
  await plugin.configureServer(server);
  return server;
}

describe("GET /__ruact/manifest (dev server middleware)", () => {
  it("serves the current manifest as JSON without the internal _sourceFile field", async () => {
    write("app/javascript/components/LikeButton.jsx", COMPONENT("LikeButton"));
    const server = await bootPlugin();

    const { body, headers } = server._invokeMiddleware("/__ruact/manifest");
    expect(headers["Content-Type"]).toBe("application/json");

    const manifest = JSON.parse(body);
    expect(manifest).toHaveProperty("LikeButton");
    expect(manifest.LikeButton).toMatchObject({
      id: "/LikeButton.jsx",
      name: "LikeButton",
      chunks: ["/LikeButton.jsx"],
    });
    // The internal field used only during the prod build must never go on the wire.
    expect(manifest.LikeButton).not.toHaveProperty("_sourceFile");
  });

  it("reflects a rebuild when a new component is added", async () => {
    write("app/javascript/components/LikeButton.jsx", COMPONENT("LikeButton"));
    const server = await bootPlugin();

    expect(JSON.parse(server._invokeMiddleware("/__ruact/manifest").body)).not.toHaveProperty(
      "CommentBox"
    );

    const added = write("app/javascript/components/CommentBox.jsx", COMPONENT("CommentBox"));
    server._fireChange(added);

    const manifest = JSON.parse(server._invokeMiddleware("/__ruact/manifest").body);
    expect(manifest).toHaveProperty("LikeButton");
    expect(manifest).toHaveProperty("CommentBox");
    expect(manifest.CommentBox).not.toHaveProperty("_sourceFile");
  });

  it("falls through (calls next) for non-GET methods", async () => {
    write("app/javascript/components/LikeButton.jsx", COMPONENT("LikeButton"));
    const server = await bootPlugin();

    const { body, nextCalled } = server._invokeMiddleware("/__ruact/manifest", "POST");
    expect(nextCalled).toBe(true);
    expect(body).toBe("");
  });
});
