import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { visualizer } from "rollup-plugin-visualizer";

const analyze = process.env.ANALYZE === "1";

// Heuristic chunk splitter — keeps heavy third-party libraries in their own
// chunks so the initial app code chunk stays small. Mermaid is already lazy
// (dynamic-imported in src/App.tsx), so its chunks split automatically; we
// only need to group the remaining eagerly-imported vendors.
function manualChunks(id: string) {
  if (!id.includes("node_modules")) return undefined;
  if (id.includes("/react/") || id.includes("/react-dom/") || id.includes("/scheduler/")) {
    return "vendor-react";
  }
  if (id.includes("/@tiptap/") || id.includes("/prosemirror-") || id.includes("/lowlight/") || id.includes("/highlight.js/")) {
    return "vendor-editor";
  }
  if (
    id.includes("/react-markdown/") ||
    id.includes("/remark-") ||
    id.includes("/rehype-") ||
    id.includes("/react-syntax-highlighter/") ||
    id.includes("/refractor/") ||
    id.includes("/prismjs/")
  ) {
    return "vendor-markdown";
  }
  if (id.includes("/framer-motion/") || id.includes("/motion-utils/") || id.includes("/motion-dom/")) {
    return "vendor-motion";
  }
  if (id.includes("/lucide-react/")) {
    return "vendor-icons";
  }
  if (id.includes("/@liquid-dom/")) {
    return "vendor-liquid";
  }
  return undefined;
}

export default defineConfig({
  plugins: [
    react(),
    ...(analyze
      ? [
          visualizer({
            filename: "verification/bundle-stats.html",
            template: "treemap",
            gzipSize: true,
            brotliSize: true,
            open: false
          })
        ]
      : [])
  ],
  base: "./",
  server: {
    watch: {
      ignored: ["**/out/**", "**/out-unpacked/**", "**/dist-electron/**"]
    }
  },
  build: {
    outDir: "dist-renderer",
    emptyOutDir: true,
    chunkSizeWarningLimit: 800,
    rollupOptions: {
      output: {
        manualChunks
      }
    }
  }
});
