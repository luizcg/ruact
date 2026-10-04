// Story 18-1 — the runtime's own client component around every Suspense child.
//
// The server wraps the deferred child of each <Suspense> in this boundary
// (Flight::Serializer#serialize_suspense, import id `ruact:boundary`). When the
// child's row is an error — a Suspense that ran past `suspense_timeout` — React's
// Flight client throws it during render; without a boundary React 19 unmounts
// the whole root. Here the fallback stays on screen and the error goes to the
// router's `onError`, as it did before the official client.
//
// It catches only what the transport produced: an error row (React's client
// gives those a `digest`), a stream cut short (labelled by ./transport.js), a
// navigation that was superseded. A crash in the app's own components passes through to the app's
// error boundaries, or to the root's.
import { Component } from "react";
import { registerBuiltin } from "./flight-modules.js";

const defaultReport = (error) => console.error(error);
let reportError = defaultReport;

/** The router points this at its `onError`. */
export function setBoundaryErrorHandler(handler) {
  reportError = handler ?? defaultReport;
}

// What the server writes in an error row's `digest`, which React's production
// client keeps (it drops the message). Mirrors Ruact::Flight::RowEmitter.
// runtime/transport.js labels a response cut short the same way.
const DIGEST_MESSAGES = {
  "ruact:suspense-timeout": "Suspense timeout exceeded",
  "ruact:connection-closed": "the response ended before the whole page arrived",
};

/** A superseded navigation aborts its stream: not something to report. */
export function isAbort(error) {
  return error?.name === "AbortError";
}

// An error row (React's client gives it a `digest`), a response cut short
// (runtime/transport.js gives it one too), or a superseded navigation. An
// AbortError thrown by the app's own code in a deferred child (an aborted fetch
// handed to `use()`) is treated as a navigation's too: the fallback stays.
function isTransportError(error) {
  if (error == null || typeof error !== "object") return false;
  return "digest" in error || isAbort(error);
}

/** The error to hand the app: the server's message, in production too. */
export function serverError(error) {
  const message = DIGEST_MESSAGES[error?.digest] ?? error?.message ?? String(error);
  return new Error(`[ruact] Server error: ${message}`, { cause: error });
}

export class SuspenseBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { failed: false, appError: null, children: props.children };
  }

  // A new response brings a new lazy child (the router, revalidate()). React
  // keeps this instance when the page keeps its shape, so a failure must not
  // outlive the child that failed.
  static getDerivedStateFromProps(props, state) {
    if (props.children === state.children) return null;
    return { failed: false, appError: null, children: props.children };
  }

  static getDerivedStateFromError(error) {
    return isTransportError(error) ? { failed: true } : { appError: error };
  }

  componentDidCatch(error) {
    if (!isTransportError(error) || isAbort(error)) return;
    reportError(serverError(error));
  }

  render() {
    // Not ours to handle: rethrown to the boundaries above.
    if (this.state.appError) throw this.state.appError;
    return this.state.failed ? (this.props.fallback ?? null) : this.props.children;
  }
}

registerBuiltin("ruact:boundary", { SuspenseBoundary });
