# Spike 18-0 — official Flight client vs ruact payloads

Experiment behind
[`../../decisions/flight-client-compatibility.md`](../../decisions/flight-client-compatibility.md).
Nothing here is imported by the gem or shipped in it.

| File | What it does |
| --- | --- |
| `gen_ruact.rb` | Writes ruact's payloads for the six cases (`payloads/ruact/`) |
| `ref-server.mjs` | Writes React's own payloads for the same cases (`payloads/react/`) |
| `fix.mjs` | Applies the import-row, text-row and Suspense changes to ruact's payloads (`payloads/ruact-fixed/`) |
| `consume.mjs` | Decodes a directory with the official client and renders the result; any decode or render error fails the case |
| `stream.mjs` | Streaming, error rows, redirect body, truncated stream |
| `vite-app/` | Browser check: Vite production build, `createFromFetch`, webpack-globals shim |
| `payloads/extra/`, `payloads/validated/` | Hand-written rows: server children in a client component; the dev-only validated flag |

Versions are pinned in `package.json`. To rerun against another React, change
the three React packages together (the client's peer range is the exact minor).
See the decision doc for the commands.
