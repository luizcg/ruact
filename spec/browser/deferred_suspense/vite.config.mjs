import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const here = path.dirname(fileURLToPath(import.meta.url));
const gem = path.resolve(here, "../../..");
const { default: ruact } = await import(path.join(gem, "vendor/javascript/vite-plugin-ruact/index.js"));

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
    fs: { allow: [gem] },
  },
});
