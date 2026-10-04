import { registry } from "./webpack-shim.js";
import { createElement as h, useState, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { createFromFetch } from "react-server-dom-webpack/client.browser";

function LikeButton({ likes }) {
  const [on, setOn] = useState(false);
  return h("button", { onClick: () => setOn(!on) }, on ? `❤️ ${likes + 1}` : `🤍 ${likes}`);
}
function Card({ title, children }) { return h("section", null, h("h2", null, title), children); }

// The two webpack globals the client calls, mapped onto a Vite registry.
Object.assign(registry, { "/LikeButton.jsx": { LikeButton }, "/Card.jsx": { Card } });

const which = new URLSearchParams(location.search).get("p") || "ruact-fixed/nested";
const tree = createFromFetch(fetch(`/${which}.txt`));
function App() { return h(Suspense, { fallback: "loading…" }, tree); }
createRoot(document.getElementById("root")).render(h(App));
