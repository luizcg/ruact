// Story 18-1 — what the page shows when rendering the tree throws.
//
// React's Flight client looks a client component up when React renders it, so
// a component missing from the registry (no "use client", a stale build) throws
// during render. With nothing to catch it, React 19 removes the whole page. The
// old decoder failed while parsing, and the bootstrap printed the error in
// #root; this keeps that: the error, visibly, in place of the page. The next
// navigation brings a new tree and clears it.
import { Component, createElement } from "react";
import { isAbort } from "./suspense-boundary.js";

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

// createRoot's onCaughtError: React logs every error a boundary catches; a
// superseded navigation's AbortError is not one to log.
export function onCaughtError(error) {
  if (isAbort(error)) return;
  console.error(error);
}
