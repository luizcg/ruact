// Story 19-0 — the bootstrap, reading `__FLIGHT_DATA` as a stream.
//
// The released bootstrap joins whatever the array holds when it runs and
// closes the stream. Here the array is drained and its `push` replaced, so the
// rows the document pushes later reach React's client as they arrive; the
// stream ends when the document does.
import { createRoot } from "react-dom/client";
import { createElement, useState, useEffect } from "react";
import { createFromReadableStream } from "virtual:ruact/flight-client";
import MODULE_REGISTRY from "virtual:ruact/registry";
import { setModuleRegistry } from "@ruact-runtime/flight-modules.js";
import { setBoundaryErrorHandler } from "@ruact-runtime/suspense-boundary.js";
import { RootBoundary, onCaughtError } from "@ruact-runtime/root-boundary.js";
import { labelledStream } from "@ruact-runtime/transport.js";
import { setupRouter, teardownRouter } from "@ruact-runtime/ruact-router.js";
import { installDevOverlay } from "./dev-overlay.js";

setModuleRegistry(MODULE_REGISTRY);

const queue = (globalThis.__FLIGHT_DATA ||= []);
const encoder = new TextEncoder();

const stream = new ReadableStream({
  start(controller) {
    const push = (rows) => {
      controller.enqueue(encoder.encode(rows));
      return 0;
    };
    queue.forEach(push);
    queue.length = 0;
    queue.push = push;

    const close = () => controller.close();
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", close, { once: true });
    } else {
      close();
    }
  },
});

const onError = import.meta.env.DEV ? installDevOverlay() : undefined;

// The router installs its error handler in an effect, after the first commit.
// A row that is already an error when the page mounts is caught during that
// commit, before the effect: the handler has to be there first.
setBoundaryErrorHandler((error) => {
  console.error(error.message);
  onError?.(error);
});

createFromReadableStream(labelledStream(stream)).then((tree) => {
  function App() {
    const [current, setCurrent] = useState(() => tree);

    useEffect(() => {
      setupRouter({ onNavigate: setCurrent, onError });
      globalThis.__SPIKE_ROUTER_READY = true;
      return () => teardownRouter();
    }, []);

    return createElement(RootBoundary, { tree: current }, current);
  }

  globalThis.__SPIKE_MOUNTED_WHILE_LOADING = document.readyState === "loading";
  createRoot(document.getElementById("root"), { onCaughtError }).render(createElement(App));
});
