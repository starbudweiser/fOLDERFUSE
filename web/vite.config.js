import { defineConfig } from "vite";

// Socle est lu directement depuis sa copie locale : la preview suit ses mises à jour.
const SOCLE = "/Volumes/SKYRIM/TOOLS/DESIGN/Socle";

export default defineConfig({
  resolve: { alias: { "@socle": SOCLE } },
  server: { port: Number(process.env.PORT) || 5174, strictPort: Boolean(process.env.PORT), fs: { allow: [".", SOCLE] } },
});
