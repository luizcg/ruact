// Ruact bootstrap entry — served to the app as the virtual module
// `virtual:ruact/bootstrap` (Story 14.2, FR104). This source ships INSIDE the
// gem so it never sits in the user's `app/javascript/` tree; the bundled
// vite-plugin's resolveId/load serve it (mirroring `virtual:ruact/registry`).
//
// IMPORTANT — this file is loaded as VIRTUAL-MODULE TEXT, not from disk, so its
// resolved id is `\0virtual:ruact/bootstrap`, which is NOT a filesystem path:
//   • Relative imports (`./flight-client.js`) do NOT resolve from a `\0virtual:`
//     id. The plugin's `load` hook rewrites the two runtime imports below to
//     ABSOLUTE fs specifiers into the gem `runtime/` dir before serving them
//     (see `generateBootstrapSource` in index.js).
//   • Bare specifiers (`react`, `react-dom/client`) and the `virtual:` id DO
//     resolve — Vite resolves them from the APP ROOT, so React/react-dom come
//     from the USER's node_modules (a single React instance — non-negotiable).
//   • No JSX syntax is used here (the inner App is built with `createElement`)
//     so the virtual module loads through Vite's default loader exactly like
//     `virtual:ruact/registry`, with no dependency on @vitejs/plugin-react
//     transforming a `\0virtual:` id.
import { createRoot } from 'react-dom/client';
import { createElement, useState, useEffect } from 'react';
import { createFromFlightPayload } from './flight-client.js';
import { setupRouter, teardownRouter } from './ruact-router.js';

// MODULE_REGISTRY maps react-client-manifest "id" values to component exports.
// It is auto-derived by vite-plugin-ruact from the SAME scan that emits
// public/react-client-manifest.json — every "use client" component under
// app/javascript/components/ is registered automatically, so adding or removing
// one needs ZERO edits here. (To opt a component out, place it outside
// app/javascript/components/ or drop its "use client" directive.)
import MODULE_REGISTRY from 'virtual:ruact/registry';

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
const flightData = globalThis.__FLIGHT_DATA;

if (!flightData || flightData.length === 0) {
  // Non-RSC page or Rails server not running — skip hydration.
  const root = document.getElementById('root');
  if (root && root.childNodes.length === 0) {
    root.textContent = '[ruact] No Flight data found — is the Rails server running?';
  }
} else {
  const payload = flightData.join('');

  let initialTree;
  try {
    initialTree = createFromFlightPayload(payload, MODULE_REGISTRY);
  } catch (err) {
    console.error('[ruact] Failed to parse Flight payload:', err);
    const root = document.getElementById('root');
    if (root) root.textContent = '[ruact] Error: ' + err.message;
    throw err;
  }

  function App() {
    const [tree, setTree] = useState(() => initialTree);

    useEffect(() => {
      setupRouter({ onNavigate: setTree, moduleRegistry: MODULE_REGISTRY });
      return () => teardownRouter();
    }, []);

    return tree;
  }

  createRoot(document.getElementById('root')).render(createElement(App));
}
