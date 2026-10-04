// Streaming + error rows through the official client (client.edge).
import { createElement as h, Suspense, use } from "react";
import { createFromReadableStream } from "react-server-dom-webpack/client.edge";
import { renderToReadableStream } from "react-dom/server.edge";

globalThis.__webpack_require__ = () => ({});
globalThis.__webpack_chunk_load__ = () => Promise.resolve();
const serverConsumerManifest = { moduleMap: {}, serverModuleMap: null, moduleLoading: null };
const enc = new TextEncoder();
const t0 = Date.now();
const log = (...a) => console.log(`[${String(Date.now() - t0).padStart(4)}ms]`, ...a);

// Byte-level chunks with delays; split mid-row and mid-UTF-8 on purpose.
function streamOf(parts) {
  return new ReadableStream({
    async start(c) {
      for (const [delay, bytes] of parts) {
        if (delay) await new Promise((r) => setTimeout(r, delay));
        c.enqueue(bytes);
      }
      c.close();
    },
  });
}
function split(str, at) { const b = enc.encode(str); return [b.slice(0, at), b.slice(at)]; }

async function render(value) {
  const s = await renderToReadableStream(h(Suspense, { fallback: "FALLBACK" }, value), {
    onError(e) { log("  ssr onError:", String(e?.message ?? e).slice(0, 120), e?.digest ? `digest=${e.digest}` : ""); },
  });
  await s.allReady;
  return (await new Response(s).text()).replace(/<script[\s\S]*?<\/script>/g, "<script…>");
}

// 1. Deferred Suspense child arrives 300ms after the root; first chunk ends mid-row and mid-"é".
{
  log("case 1: streamed Suspense child");
  const head = 'ff:"$Sreact.suspense"\n0:["$","$ff",null,{"fallback":["$","p",null,{"children":"loading"}],"children":"$L1"}]\n';
  const [a, b] = split('1:["$","p",null,{"children":"laté"}]\n', 30); // byte 30 = inside é
  const value = createFromReadableStream(streamOf([[0, enc.encode(head)], [300, a], [50, b]]), { serverConsumerManifest });
  value.then(() => log("  root resolved"));
  log("  html:", await render(value));
}

// 2. ruact's current error row: E + JSON string.
for (const [label, row] of [
  ["case 2: ruact E-row (string)", '1:E"Suspense timeout exceeded"\n'],
  ["case 3: React prod E-row (object)", '1:E{"digest":"abc123"}\n'],
  ["case 4: React dev-shaped E-row", '1:E{"digest":"","name":"Error","message":"Suspense timeout exceeded","stack":[],"env":"Server"}\n'],
]) {
  log(label);
  const head = 'ff:"$Sreact.suspense"\n0:["$","$ff",null,{"fallback":["$","p",null,{"children":"loading"}],"children":"$L1"}]\n';
  const value = createFromReadableStream(streamOf([[0, enc.encode(head)], [50, enc.encode(row)]]), { serverConsumerManifest });
  try { log("  html:", await render(value)); } catch (e) { log("  threw:", e.message); }
}

// 5. ruact redirect body as a Flight response.
{
  log("case 5: ruact redirect row");
  const v = await createFromReadableStream(streamOf([[0, enc.encode('0:{"redirectUrl":"/posts/1","redirectType":"push"}\n')]]), { serverConsumerManifest });
  log("  value:", JSON.stringify(v));
}

// 6. Truncated stream (connection drops before the lazy row).
{
  log("case 6: truncated stream");
  const head = 'ff:"$Sreact.suspense"\n0:["$","$ff",null,{"fallback":["$","p",null,{"children":"loading"}],"children":"$L1"}]\n1:["$","p",nu';
  const value = createFromReadableStream(streamOf([[0, enc.encode(head)]]), { serverConsumerManifest });
  try { log("  html:", await render(value)); } catch (e) { log("  threw:", e.message); }
}
