// Story 18-1 — the runtime's own client component around every Suspense child.
//
// The server wraps the deferred child of each <Suspense> in this boundary
// (Flight::Serializer#serialize_suspense, import id `ruact:boundary`). When the
// child's row is an error — a Suspense that ran past `suspense_timeout` — React's
// Flight client throws it during render; without a boundary React 19 unmounts
// the whole root. Here the fallback stays on screen and the error goes to the
// router's `onError`, as it did before the official client.
import { Component } from "react";
import { registerBuiltin } from "./flight-modules.js";

let reportError = (error) => console.error("[ruact]", error);

/** The router points this at its `onError`. */
export function setBoundaryErrorHandler(handler) {
  reportError = handler ?? ((error) => console.error("[ruact]", error));
}

export class SuspenseBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { failed: false };
  }

  static getDerivedStateFromError() {
    return { failed: true };
  }

  componentDidCatch(error) {
    // A navigation that was superseded aborts its stream; that is not an error
    // the page should report.
    if (error?.name === "AbortError") return;
    reportError(error);
  }

  render() {
    return this.state.failed ? (this.props.fallback ?? null) : this.props.children;
  }
}

registerBuiltin("ruact:boundary", { SuspenseBoundary });
