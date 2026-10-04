// Run with: node --conditions=react-server ref-server.mjs
import { createElement as h, Suspense } from "react";
import { renderToReadableStream, registerClientReference } from "react-server-dom-webpack/server.edge";

const LikeButton = registerClientReference(function () { throw new Error("client"); }, "/LikeButton.jsx", "LikeButton");
const webpackMap = { "/LikeButton.jsx#LikeButton": { id: "/LikeButton.jsx", chunks: ["/LikeButton.jsx"], name: "LikeButton" } };

async function wire(model) {
  const stream = renderToReadableStream(model, webpackMap, { onError: (e) => String(e?.message ?? e) });
  return await new Response(stream).text();
}

async function Slow() { await new Promise((r) => setTimeout(r, 20)); return h("p", null, "late"); }

const cases = {
  scalars: { s: "hi", dollar: "$5 plan", i: 42, f: 3.14, t: true, n: null, nan: NaN, inf: Infinity, ninf: -Infinity, negz: -0, und: undefined, date: new Date("2026-09-08T12:30:45.123Z"), big: 9007199254740993n },
  longText: { body: "é".repeat(600) },
  hostTree: h("div", null, h("h1", null, "Hello"), h("p", { className: "x" }, "World")),
  clientComponent: h(LikeButton, { likes: 12 }),
  nested: h("ul", null, [1, 2].map((i) => h("li", { key: i }, h(LikeButton, { likes: i })))),
  suspense: h(Suspense, { fallback: h("span", null, "loading") }, h(Slow)),
};

import { writeFileSync } from "node:fs";
for (const [name, model] of Object.entries(cases)) {
  const w = await wire(model);
  writeFileSync(`payloads/react/${name}.txt`, w);
  console.log(`=== ${name}\n${w}`);
}
