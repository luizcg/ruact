import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
// The payload directories are served as-is: /ruact-fixed/suspense.txt, /extra/childrenIntoClient.txt.
export default defineConfig({ plugins: [react()], publicDir: "../payloads" });
