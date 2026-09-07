import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Dev proxy target: the control-plane backend. The parent start script
// launches the backend on 8090 before Vite; production does not use Vite —
// the backend serves ../dist directly.
const apiUrl = process.env.BUILDER_API_URL ?? "http://127.0.0.1:8090";

export default defineConfig({
  root: "frontend",
  plugins: [react()],
  publicDir: false,
  build: {
    outDir: "../dist",
    emptyOutDir: true,
  },
  server: {
    host: "127.0.0.1",
    port: Number(process.env.FLCKD_UI_PORT ?? 8642),
    strictPort: true,
    proxy: {
      "/api": { target: apiUrl, changeOrigin: false },
      "/health": { target: apiUrl, changeOrigin: false },
      "/logo.png": { target: apiUrl, changeOrigin: false },
    },
  },
});
