import { defineConfig, fontProviders } from "astro/config";

// Vercel exposes the production domain to every build, including previews, so
// canonical and Open Graph URLs always point at the public site.
const productionHost = process.env.VERCEL_PROJECT_PRODUCTION_URL;

export default defineConfig({
  site: productionHost ? `https://${productionHost}` : "http://localhost:4321",
  trailingSlash: "never",
  fonts: [
    {
      provider: fontProviders.local(),
      name: "Archivo",
      cssVariable: "--font-archivo",
      fallbacks: ["Helvetica Neue", "Arial", "sans-serif"],
      options: {
        variants: [
          {
            src: ["@fontsource-variable/archivo/files/archivo-latin-wdth-normal.woff2"],
            weight: "100 900",
            stretch: "62% 125%",
            style: "normal",
            display: "swap",
          },
        ],
      },
    },
    {
      provider: fontProviders.local(),
      name: "Martian Mono",
      cssVariable: "--font-martian",
      fallbacks: ["SFMono-Regular", "Menlo", "monospace"],
      options: {
        variants: [
          {
            src: ["@fontsource-variable/martian-mono/files/martian-mono-latin-wdth-normal.woff2"],
            weight: "100 800",
            stretch: "75% 112.5%",
            style: "normal",
            display: "swap",
          },
        ],
      },
    },
  ],
});
