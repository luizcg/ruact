// Story 18-1 — how React's Flight client finds ruact's client components.
//
// The client asks for a module by the id in an import row (`I` row) and, under
// webpack, would load that module's chunks first. ruact registers every client
// component eagerly (`virtual:ruact/registry`, generated from the same scan as
// the manifest), so there is nothing to load: the server sends `chunks: []`
// and the lookup is a map read.
//
// The vendored client (./vendor/react-server-dom-webpack/) calls these
// directly. An app that installs `react-server-dom-webpack` itself gets that
// client instead, which reads webpack's globals — ./flight-webpack-globals.js
// defines them over the same functions.

let registry = Object.create(null);

// The runtime's own client components, always present: the boundary the server
// wraps each Suspense child in (Flight::Serializer#serialize_suspense).
const BUILTINS = Object.create(null);

export function registerBuiltin(id, moduleExports) {
  BUILTINS[id] = moduleExports;
}

export function setModuleRegistry(moduleRegistry) {
  registry = moduleRegistry ?? Object.create(null);
}

export function requireModule(id) {
  const mod = BUILTINS[id] ?? registry[id];
  if (!mod) throw new Error(`[ruact] Module not registered: ${id}`);
  return mod;
}

export function loadChunk() {
  return Promise.resolve();
}
