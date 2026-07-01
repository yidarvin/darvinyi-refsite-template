import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import mdx from "@mdx-js/rollup";

// MDX is compiled to React components. providerImportSource wires every chapter's
// markdown elements (h1, p, code, ...) through the <MDXProvider> in App.tsx, so the
// house style lives in one place (src/components/mdxComponents.tsx).
export default defineConfig({
  plugins: [
    { enforce: "pre", ...mdx({ providerImportSource: "@mdx-js/react" }) },
    react({ include: /\.(jsx|tsx|js|ts|mdx?)$/ }),
  ],
});
