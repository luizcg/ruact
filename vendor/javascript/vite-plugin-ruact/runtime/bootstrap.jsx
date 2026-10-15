// Ruact bootstrap entry — served to the app as the virtual module
// `virtual:ruact/bootstrap` (Story 14.2, FR104). This source ships INSIDE the
// gem so it never sits in the user's `app/javascript/` tree; the bundled
// vite-plugin's resolveId/load serve it (mirroring `virtual:ruact/registry`).
//
// IMPORTANT — this file is loaded as VIRTUAL-MODULE TEXT, not from disk, so its
// resolved id is `\0virtual:ruact/bootstrap`, which is NOT a filesystem path:
//   • Relative imports (`./ruact-router.js`) do NOT resolve from a `\0virtual:`
//     id. The plugin's `load` hook rewrites the runtime imports below to
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
import { setModuleRegistry } from './flight-modules.js';
// Registers the boundary the server wraps each Suspense child in.
import { setBoundaryErrorHandler } from './suspense-boundary.js';
import { RootBoundary, onCaughtError } from './root-boundary.js';
// The page, opened from its Flight bytes with React's own Flight client (the
// copy vendored in the gem, or the app's `react-server-dom-webpack` when it
// declares one: the plugin decides).
import { documentRows, openPage, whenRoot } from './page-stream.js';
import { setupRouter, teardownRouter } from './ruact-router.js';
import { showDevOverlay } from './dev-overlay.js';

// MODULE_REGISTRY maps react-client-manifest "id" values to component exports.
// It is auto-derived by vite-plugin-ruact from the SAME scan that emits
// public/react-client-manifest.json — every "use client" component under
// app/javascript/components/ is registered automatically, so adding or removing
// one needs ZERO edits here. (To opt a component out, place it outside
// app/javascript/components/ or drop its "use client" directive.)
import MODULE_REGISTRY from 'virtual:ruact/registry';

setModuleRegistry(MODULE_REGISTRY);

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
const flightData = globalThis.__FLIGHT_DATA;

function showBootError(err) {
  console.error('[ruact] Failed to parse Flight payload:', err);
  const root = document.getElementById('root');
  if (root) root.textContent = '[ruact] Error: ' + err.message;
}

if (!flightData || flightData.length === 0) {
  // Non-RSC page or Rails server not running — skip hydration.
  const root = document.getElementById('root');
  if (root && root.childNodes.length === 0) {
    root.textContent = '[ruact] No Flight data found — is the Rails server running?';
  }
} else {
  // Story 19-1 — in development a <Suspense> that failed on the server is shown
  // over the page. The handler is in place before anything renders: a row that
  // is already an error when the page mounts is caught during that first
  // commit, before the router's effect would install one.
  const onBoundaryError = import.meta.env?.DEV ? (error) => showDevOverlay(error) : null;
  setBoundaryErrorHandler((error) => {
    console.error(error.message);
    onBoundaryError?.(error);
  });

  // The document's rows, as the stream the client reads — open while the
  // document is: a page that streams pushes each <Suspense>'s rows as they are
  // ready. The root is mounted once the tree resolves, so the first paint is
  // the page with its fallbacks.
  let initialTree;
  try {
    initialTree = openPage(documentRows(flightData)).root;
  } catch (err) {
    showBootError(err);
    throw err;
  }

  Promise.all([initialTree, whenRoot()]).then(
    ([tree, container]) => {
      function App() {
        const [current, setCurrent] = useState(() => tree);

        useEffect(() => {
          setupRouter({ onNavigate: setCurrent, onBoundaryError });
          return () => teardownRouter();
        }, []);

        // A render error shows in place of the page instead of removing it.
        return createElement(RootBoundary, { tree: current }, current);
      }

      createRoot(container, { onCaughtError }).render(createElement(App));
    },
    (err) => {
      showBootError(err);
    },
  );
}
