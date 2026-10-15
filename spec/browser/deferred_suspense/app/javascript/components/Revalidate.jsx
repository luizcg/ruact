"use client";
import { useState } from "react";

// Story 19-2 (AC4) — what an island does when it calls `revalidate()`: the
// helper of ruact's runtime calls this handle, which the router installs.
export function Revalidate() {
  const [state, setState] = useState("idle");
  const run = () => {
    setState("pending");
    globalThis.__ruact_revalidate(location.pathname + location.search).then(
      () => setState("resolved"),
      (error) => setState(`rejected: ${error.message}`),
    );
  };
  return (
    <button id="revalidate" data-state={state} onClick={run}>
      revalidate: {state}
    </button>
  );
}
