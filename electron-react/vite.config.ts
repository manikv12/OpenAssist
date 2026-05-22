import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "./",
  server: {
    watch: {
      ignored: ["**/out/**", "**/out-unpacked/**", "**/dist-electron/**"]
    }
  },
  build: {
    outDir: "dist-renderer",
    emptyOutDir: true
  }
});
