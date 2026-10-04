// Story 18-1 — what the page shows when rendering the tree throws.
//
// React's Flight client looks a client component up when React renders it, so
// a component missing from the registry (no "use client", a stale build) throws
// during render. With nothing to catch it, React 19 removes the whole page. The
// old decoder failed while parsing, and the bootstrap printed the error in
// #root; this keeps that: the error, visibly, in place of the page. The next
// navigation brings a new tree and clears it.
import { Component, createElement } from "react";
import { isAbort, SuspenseBoundary } from "./suspense-boundary.js";

export class RootBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { error: null, tree: props.tree };
  }

  static getDerivedStateFromProps(props, state) {
    if (props.tree === state.tree) return null;
    return { error: null, tree: props.tree };
  }

  static getDerivedStateFromError(error) {
    return { error };
  }

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    return createElement("div", { role: "alert", "data-ruact-error": "" }, `[ruact] Error: ${error.message}`);
  }
}

// createRoot's onCaughtError, for every boundary on the page. The Suspense
// boundary reports what it catches itself (to the router's onError), and a
// superseded navigation's AbortError is not an error; everything else is
// logged as React would, with its component stack.
export function onCaughtError(error, errorInfo) {
  if (isAbort(error) || errorInfo?.errorBoundary instanceof SuspenseBoundary) return;
  console.error(error, errorInfo?.componentStack ?? "");
}
