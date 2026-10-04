// Official React Flight client (react-server-dom-webpack 19.2.8, client.edge)
// decoding a payload, then react-dom/server rendering what it produced.
import { createElement as h, use, Suspense } from "react";
import { createFromReadableStream } from "react-server-dom-webpack/client.edge";
import { renderToReadableStream } from "react-dom/server.edge";
import { readFileSync, readdirSync } from "node:fs";

function LikeButton({ likes }) { return h("button", null, `likes:${String(likes)}`); }
function Card({ title, children }) { return h("section", null, h("h2", null, title), children); }
globalThis.__webpack_require__ = (id) => ({ LikeButton, Card });
globalThis.__webpack_chunk_load__ = () => Promise.resolve();
const serverConsumerManifest = {
  moduleMap: {
    "/LikeButton.jsx": { LikeButton: { id: "/LikeButton.jsx", chunks: [], name: "LikeButton" } },
    "/Card.jsx": { Card: { id: "/Card.jsx", chunks: [], name: "Card" } },
  },
  serverModuleMap: null,
  moduleLoading: null,
};

// Annotate types JSON would hide (a Date's toJSON runs before any replacer).
function annotate(v) {
  if (v instanceof Date) return `Date(${v.toISOString()})`;
  if (typeof v === "bigint") return `BigInt(${v})`;
  if (typeof v === "number" && (!Number.isFinite(v) || Object.is(v, -0))) return `Number(${Object.is(v, -0) ? "-0" : v})`;
  if (v === undefined) return "undefined";
  if (Array.isArray(v)) return v.map(annotate);
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, annotate(x)]));
  return v;
}
function stringify(v) { return JSON.stringify(annotate(v)); }

async function decode(payload) {
  const stream = new Response(payload).body;
  const value = await createFromReadableStream(stream, { serverConsumerManifest });
  return value;
}

async function html(value) {
  function Root() { return h(Suspense, { fallback: "…" }, value); }
  // A render error inside the Suspense boundary still returns HTML (the
  // fallback), so collect errors and fail the case on any.
  const errors = [];
  const s = await renderToReadableStream(h(Root), { onError: (e) => { errors.push(e); } });
  await s.allReady;
  const out = await new Response(s).text();
  if (errors.length) throw errors[0];
  return out;
}

const dir = process.argv[2];
for (const file of readdirSync(dir).sort()) {
  const name = file.replace(/\.txt$/, "");
  const payload = readFileSync(`${dir}/${file}`, "utf8");
  try {
    const value = await decode(payload);
    const isTree = value && typeof value === "object" && "$$typeof" in value;
    const out = isTree ? await html(value) : stringify(value);
    console.log(`${name}: OK  ${out.slice(0, 400)}`);
  } catch (e) {
    console.log(`${name}: FAIL ${String(e?.message ?? e).split("\n")[0].slice(0, 200)}`);
  }
}
