import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const here = path.dirname(fileURLToPath(import.meta.url));
const gem = path.resolve(here, "../../..");
// Story 19-2 (AC22) — HARNESS_PLUGIN_DIR: build with another release's plugin
// (`./run skew` extracts 0.0.19's), so the browser runs that release's bootstrap.
const pluginDir = process.env.HARNESS_PLUGIN_DIR || path.join(gem, "vendor/javascript/vite-plugin-ruact");
const { default: ruact } = await import(path.join(pluginDir, "index.js"));

export default defineConfig({
  plugins: [react(), ruact()],
  build: {
    outDir: "public/assets",
    manifest: true,
    rollupOptions: { input: ["virtual:ruact/bootstrap"] },
  },
  server: {
    port: Number(process.env.VITE_PORT ?? 5199),
    strictPort: true,
    origin: `http://localhost:${process.env.VITE_PORT ?? 5199}`,
    fs: { allow: [gem, pluginDir] },
  },
});
