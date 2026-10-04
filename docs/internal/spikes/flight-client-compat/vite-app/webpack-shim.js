// Must evaluate before react-server-dom-webpack/client.browser, which reads the
// webpack globals when it loads. The registry is filled by main.jsx.
export const registry = {};
globalThis.__webpack_require__ = (id) => registry[id];
globalThis.__webpack_chunk_load__ = () => Promise.resolve();
