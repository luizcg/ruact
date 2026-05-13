// Story 8.0a — minimal vitest harness for the bundled Vite plugin.
//
// Story 6.9 (vite-plugin TS modularization) will absorb this into its larger
// src/ + dist/ layout. Until then, run tests against the in-tree `.mjs` source
// directly.

import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["**/*.test.mjs", "../ruact-server-functions-runtime/*.test.mjs"],
    globals: false,
  },
});
