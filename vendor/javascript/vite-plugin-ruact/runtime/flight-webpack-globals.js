// Story 18-1 — only when the app installs `react-server-dom-webpack` itself.
//
// That copy of React's Flight client reads `__webpack_require__` and
// `__webpack_chunk_load__` as globals, and assigns `__webpack_require__.u`
// while it evaluates — so this module must run before it (the
// `virtual:ruact/flight-client` module imports it first). The vendored client
// needs none of this: its copies are module-local.
import { requireModule, loadChunk } from "./flight-modules.js";

if (typeof globalThis.__webpack_require__ !== "function") {
  globalThis.__webpack_require__ = (id) => requireModule(id);
}
if (typeof globalThis.__webpack_chunk_load__ !== "function") {
  globalThis.__webpack_chunk_load__ = (chunkId) => loadChunk(chunkId);
}
