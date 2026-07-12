import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://tryopenalarm.com',
  integrations: [sitemap()],
  build: {
    // Inline all CSS into the HTML so styles arrive with the first response —
    // a flash of unstyled content is structurally impossible.
    inlineStylesheets: 'always',
  },
});
