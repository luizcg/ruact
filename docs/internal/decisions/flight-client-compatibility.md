# Flight client — keep ruact's decoder or use React's

| Field | Value |
| --- | --- |
| Date | 2026-10-04 |
| Status | Proposed — the replace/retain call is recommended below; one packaging choice is open |
| Story | 18-0 — official-client compatibility spike |
| Measured against | ruact 0.0.16 payloads; `react`, `react-dom`, `react-server-dom-webpack` **19.2.8** and **19.3.0** (current `latest`); `vite` 6.4.3 + `@vitejs/plugin-react` 4.7.0; Node 24; Chrome |
| Experiment | [`docs/internal/spikes/flight-client-compat/`](../spikes/flight-client-compat/) — every number below comes from its scripts |
| Production code changed | None |

## Question

ruact's browser runtime decodes Flight with its own parser
(`vendor/javascript/vite-plugin-ruact/runtime/flight-client.js`, 436 lines,
plus the row parser the router reuses). Most of the bugs that reached users in
17-0a, 17-0c and 17-0d lived in that decoder: a one-element array collapsing,
text rows split across chunks, children losing their keys. Can React's own
client, `react-server-dom-webpack/client`, read what ruact's Ruby side writes,
under Vite, and at what cost?

## What was run

1. **Reference payloads.** React's own server (`server.edge`, production)
   renders six cases: scalars, a long text, a host tree, a client component,
   nested client components, and Suspense with a slow child.
2. **ruact payloads.** The same six cases from the Ruby side, through
   `RenderPipeline` (ERB) and `Flight::Renderer` (data).
3. **Decode and render.** The official client (`client.edge`) decodes each
   payload and `react-dom/server` renders the result to HTML. A case passes
   when the HTML (or the decoded value, for data) matches React's own, and
   fails on any decode or render error. Run under both the production and the
   development build of the client.
4. **Streaming and errors.** A stream whose deferred row arrives 300 ms after
   the root, split mid-row and inside a multi-byte character; error rows in
   ruact's shape and in React's two shapes; ruact's redirect body; a stream cut
   before its last row.
5. **Browser.** A Vite production build of a page that fetches a payload with
   `createFromFetch` and renders it with `react-dom/client`, in Chrome.

## Results

### Payloads as ruact writes them today: 2 of 6

| Case | Official client | Why |
| --- | --- | --- |
| scalars | ✅ | Same encoding as React's (`$D`, `$n`, `$NaN`, `$undefined`, `$$`) |
| hostTree | ✅ | |
| clientComponent | ❌ | Import row is `[id, name, chunks]`; React's is `[id, chunks, name]` |
| nested | ❌ | Same import row |
| longText | ❌ | Text row referenced as `"$T<id>"`; in React `$T` means a temporary reference (server-action replies), a text row is `"$<id>"` |
| suspense | ❌ | Type `"$SS"` is not a symbol React knows, and the deferred child is an element whose type is `$L<id>` |

### With four server-side changes: 6 of 6, both client builds, both React versions

`fix.mjs` rewrites ruact's real payloads with changes 1–3. Change 4 and the
dev-only flag were checked with hand-written rows.

| # | Change on the Ruby side | Where |
| --- | --- | --- |
| 1 | Import row `[id, chunks, name]` | `Flight::Serializer` / `ClientManifest` metadata |
| 2 | Text row referenced as `"$<hex>"` | `Flight::Serializer#serialize_string` |
| 3 | Suspense: a symbol row `"$Sreact.suspense"` used as the type, deferred content as a lazy child `"children":"$L<id>"` | Serializer + `Renderer` deferred rows |
| 4 | Error row as an object `{"digest","name","message","stack":[],"env"}` | `RowEmitter.error` callers |
| 5 | *(dev only)* Element as a 7-tuple `["$",type,key,props,null,null,1]` — the last field tells the dev client the children were validated | Serializer, development only |

Without 4, the **development** client crashes on ruact's error row
(`E"Suspense timeout exceeded"` → `Cannot read properties of undefined`); the
production client accepts it but ignores the text either way. Without 5, the
development client logs React's "unique key" warning for every element with
more than one child and every ERB loop — ERB has no `key`, so ruact has to
mark its children validated, as React's own server does for static children.
Production ignores the extra fields.

| Case | 19.2.8 prod | 19.2.8 dev | 19.3.0 prod | 19.3.0 dev |
| --- | --- | --- | --- | --- |
| scalars (types checked: `Date`, `BigInt`, `NaN`, ±`Infinity`) | ✅ | ✅ | ✅ | ✅ |
| longText (600 × `é`, a `T` row) | ✅ | ✅ | ✅ | ✅ |
| hostTree | ✅ | ✅ | ✅ | ✅ |
| clientComponent | ✅ | ✅ | ✅ | ✅ |
| nested | ✅ | ✅ | ✅ | ✅ |
| suspense | ✅ | ✅ | ✅ | ✅ |
| server children inside a client component (`<Card>` with a `<p>` and a `<LikeButton>` as children; hand-written — ruact cannot emit children yet) | ✅ | ✅ | ✅ | ✅ |

### Streaming, errors, redirects

| Case | Result |
| --- | --- |
| Deferred row 300 ms after the root, chunks split mid-row and inside `é` | ✅ root resolves at ~10 ms, the child at ~380 ms, text intact |
| Error row (React's object shape) inside Suspense | ✅ fallback stays, error reaches `onError`; dev shows the message, prod a digest |
| ruact's current error row (a JSON string) | ⚠️ prod OK, dev crashes — change 4 |
| ruact's redirect body `0:{"redirectUrl":…}` | ✅ decodes to a plain object, which the router can check before rendering |
| Stream cut before the last row | ✅ `Connection closed.` error, fallback kept |

### Browser, Vite production build

Chrome, `vite build` + `vite preview`: the server-children case renders
`<h2>`, the ERB `<p>` and the button, and the button's state works (🤍 3 →
❤️ 4); the Suspense case renders its late child. No console errors.

The client finds components through two globals webpack would define,
`__webpack_require__(id)` and `__webpack_chunk_load__(chunk)`. Under Vite a
module evaluated before the client defines them:

```js
globalThis.__webpack_require__ = (id) => MODULE_REGISTRY[id];
globalThis.__webpack_chunk_load__ = () => Promise.resolve();
```

ruact already resolves components through a static map, `virtual:ruact/registry`
(eager, generated from the same scan as the manifest), so the first global is
that map and the second has nothing to load. Module resolution does not change.

### Cost

| | ruact's decoder | Official client |
| --- | --- | --- |
| Decoder alone, minified + gzip | 2.0 kB | 8.2 kB |
| `react` + `react-dom/client` + decoder, minified + gzip | 64.5 kB | 67.7 kB (**+3.1 kB, +4.9 %**) |
| npm install in the host app | nothing extra | `react-server-dom-webpack` declares **`webpack` as a required peer**: npm installs it — 61 extra packages, 31 MB in `node_modules`. Never bundled, never run. |
| Version coupling | none | the client's peer range is the exact React minor (`^19.3.0` for 19.3.0) |

## Decision (recommended)

**Replace ruact's decoder with React's client.** Keep the Ruby side as the
only Flight writer, and make it write the subset React's client reads.

- Correctness stops being ruact's to maintain on the client. Most transport
  bugs so far were in the decoder; the official client already handles chunk
  splitting, out-of-order lazy rows, `T` rows, keys and error boundaries.
- The next two epics need exactly what the official client already does.
  ERB children (18-2) need no client work — the children case above, written
  by hand in the shape 18-2 would emit, decoded unchanged. Real streaming Suspense (Epic 19) is lazy rows arriving
  late, which the streaming case already shows.
- The cost is small and bounded: +3.1 kB gzip in the browser, five changes on
  the Ruby side, a two-line shim, and the bootstrap/router switching to
  `createFromReadableStream`/`createFromFetch`.
- The JSON boundary is untouched. Server functions stay JSON; nothing decodes
  Flight on the server (`decodeReply` is not used), so React's server-side
  advisories stay out of scope.

### Open: how the client reaches the app

| Option | For | Against |
| --- | --- | --- |
| **A. npm dependency** — the installer adds `react-server-dom-webpack` at the host's React version | Upgrades with React; React's own release | webpack's 61 packages / 31 MB in every app's `node_modules` (dev only, never bundled); a confusing name in a Vite app |
| **B. vendored** — the gem ships React's prebuilt `client.browser` files (MIT) for one React minor | No webpack, no new npm dependency | ruact must release when React's wire changes; the host's React minor must match what the gem ships |

This is Luiz's call: it trades install weight against release cadence.

## Risks

- **Flight is not a public, versioned protocol.** It matched across 19.2.8 and
  19.3.0, but React can change it in any minor. 18-1 must pin the client and
  run these fixtures in CI against it, and the supported React range must be
  stated, not implied.
- **The webpack globals are an integration point, not an API.** They are what
  React's webpack bundler integration calls; another bundler package
  (`-turbopack`, `-parcel`) or a future rename would mean a different shim.
- **Wire change is a coordinated switch.** Changes 1–3 break ruact's current
  decoder, so the Ruby side and the browser runtime switch in the same release.
- **Not measured here:** navigation through the router (form submits,
  revalidation, abort of a superseded navigation) with the official client;
  `-0` (React writes `"$-0"`, ruact does not). Both belong to 18-1's
  conformance matrix.

## What 18-1 inherits

1. Ruby: changes 1–5 above, each with a fixture decoded by the pinned official
   client in CI (dev and prod builds).
2. Browser: bootstrap reads the inline `__FLIGHT_DATA` as a stream into
   `createFromReadableStream`; the router uses `createFromFetch` inside a
   transition and checks the root value for `redirectUrl`; the shim module
   loads first.
3. Delete `flight-client.js` and the router's row parser once nothing imports
   them.
4. The packaging option (A or B) chosen above.

## How to reproduce

```sh
cd docs/internal/spikes/flight-client-compat
npm install
npm run ruact-payloads    # Ruby → payloads/ruact
npm run react-payloads    # React's server → payloads/react
npm run fixed-payloads    # changes 1–3 → payloads/ruact-fixed
npm run consume           # production client
npm run consume:dev       # development client
npm run stream            # streaming, error rows, redirect, truncation
npm run browser           # Vite build + preview on :4173, ?p=ruact-fixed/suspense
```
