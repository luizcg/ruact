// Story 8.0a — minimal vitest harness for the bundled Vite plugin.
//
// Story 6.9 (vite-plugin TS modularization) will absorb this into its larger
// src/ + dist/ layout. Until then, run tests against the in-tree `.mjs` source
// directly.

import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// Story 18-1 — the runtime imports React's Flight client through a virtual id
// the plugin answers; under vitest it is the vendored copy. FLIGHT_CLIENT_MODE
// picks the build (the conformance suite runs both).
const flightClient = fileURLToPath(
  new URL(
    `./runtime/vendor/react-server-dom-webpack/client.browser.${process.env.FLIGHT_CLIENT_MODE || "development"}.js`,
    import.meta.url,
  ),
);

export default defineConfig({
  resolve: {
    alias: { "virtual:ruact/flight-client": flightClient },
  },
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
