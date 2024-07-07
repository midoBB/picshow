import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// https://vitejs.dev/config/
export default defineConfig({
  esbuild: {
    target: "es2015", // or lower depending on your needs
  },
  build: {
    target: "es2015",
  },
  resolve: {
    alias: {
      "@": "/src",
    },
  },
  plugins: [react()],
});
