import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { resolve } from "node:path";

// Two pages: the landing page at / and the flasher at /flash/.
export default defineConfig({
  plugins: [svelte()],
  build: {
    target: "es2022",
    // fonts and images stay files: the CSP allows them only from this origin
    assetsInlineLimit: 0,
    rollupOptions: {
      input: {
        landing: resolve(import.meta.dirname, "index.html"),
        flash: resolve(import.meta.dirname, "flash/index.html"),
      },
    },
  },
});
