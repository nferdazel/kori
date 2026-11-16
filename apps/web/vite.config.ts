import { defineConfig } from "vite";

// Four server-rendered pages, no client router: every page is its own HTML entry and the shared
// module is bundled once. Inputs are relative to this folder, so no Node path helpers are needed.
export default defineConfig({
  base: "/",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: {
        index: "index.html",
        requests: "requests.html",
        routes: "routes.html",
        config: "config.html",
      },
    },
  },
  server: {
    proxy: {
      "/admin": "http://127.0.0.1:4019",
      "/healthz": "http://127.0.0.1:4019",
    },
  },
});
