import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const here = path.dirname(fileURLToPath(import.meta.url));
const gem = path.resolve(here, "../../../..");
const plugin = path.join(gem, "vendor/javascript/vite-plugin-ruact");
const { default: ruact } = await import(path.join(plugin, "index.js"));

export default defineConfig({
  plugins: [react(), ruact()],
  resolve: {
    alias: { "@ruact-runtime": path.join(plugin, "runtime") },
  },
  build: {
    outDir: "public/assets",
    manifest: true,
    rollupOptions: {
      // The released bootstrap (baseline) and the prototype's entry.
      input: ["virtual:ruact/bootstrap", "app/javascript/entry.js"],
    },
  },
  server: {
    port: Number(process.env.VITE_PORT ?? 5173),
    strictPort: true,
    origin: `http://localhost:${process.env.VITE_PORT ?? 5173}`,
    fs: { allow: [gem] },
  },
});
