// Story 15.6 (FR110) — type-level test for the auto-revalidate opt-in surface.
// Proves (a) `configureRuactRuntime` accepts the new `autoRevalidate?: boolean`
// key alongside `defaultHeaders`, and (b) `withRefresh` preserves the wrapped
// accessor's call signature (so `withRefresh(createPost)` is callable exactly
// like `createPost`). Runtime-only: this surface is NOT emitted by the codegen,
// so there is no byte-parity fixture to regenerate.

import { _makeServerFunction, configureRuactRuntime, withRefresh } from "ruact/server-functions-runtime";

// (a) the app-wide default key type-checks (and stays optional).
configureRuactRuntime({ autoRevalidate: true });
configureRuactRuntime({ autoRevalidate: false, defaultHeaders: { Authorization: "Bearer x" } });
configureRuactRuntime({ defaultHeaders: null });

// A non-boolean autoRevalidate is a type error.
// @ts-expect-error autoRevalidate must be a boolean
configureRuactRuntime({ autoRevalidate: "yes" });

// (b) withRefresh preserves the accessor call signature.
const createPost = _makeServerFunction({ method: "POST", path: "/posts", segments: [] });
const createPostRefreshing = withRefresh(createPost);

// Callable at the same shapes as the underlying accessor.
void createPostRefreshing({ title: "x" });
void createPostRefreshing();
