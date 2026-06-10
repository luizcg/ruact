// Story 8.0a — minimal vitest harness for the bundled Vite plugin.
//
// Story 6.9 (vite-plugin TS modularization) will absorb this into its larger
// src/ + dist/ layout. Until then, run tests against the in-tree `.mjs` source
// directly.

import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    // The runtime's `index.test.mjs` is node-environment + dependency-free, so
    // it rides along here for a single parity-plus-runtime run. Its jsdom +
    // React hook tests (`usequery.test.mjs`, Story 9.5) need
    // `@testing-library/react` from the runtime package's own node_modules and
    // run via that package's `npm test` — they are intentionally NOT globbed
    // in here (a `*.test.mjs` glob would pull them in and fail to resolve).
    include: ["**/*.test.mjs", "../ruact-server-functions-runtime/index.test.mjs"],
    globals: false,
  },
});
