import { fileURLToPath, URL } from 'node:url'
import mdx from '@mdx-js/rollup'
import rehypeShiki from '@shikijs/rehype'
import tailwind from '@tailwindcss/vite'
import vue from '@vitejs/plugin-vue'
import rehypeAutolinkHeadings from 'rehype-autolink-headings'
import rehypeSlug from 'rehype-slug'
import remarkFrontmatter from 'remark-frontmatter'
import remarkGfm from 'remark-gfm'
import { defineConfig } from 'vite'
import { docsIndex } from './plugins/docs-index.ts'
import { snippets } from './plugins/snippets.ts'
import { spaFallback } from './plugins/spa-fallback.ts'

const docsRoot = fileURLToPath(new URL('./docs', import.meta.url))
const snippetRoot = fileURLToPath(new URL('./src/snippets', import.meta.url))

export default defineConfig({
  // GitHub Pages serves the repository at /gosslens/.
  base: process.env.SITE_BASE ?? '/gosslens/',
  plugins: [
    // MDX compiles to the Vue runtime, so a document can reach for a component
    // the same way a page does and the two share one set of primitives.
    {
      ...mdx({
        jsxImportSource: 'vue',
        providerImportSource: '@mdx-js/vue',
        remarkPlugins: [remarkFrontmatter, remarkGfm],
        rehypePlugins: [
          rehypeSlug,
          [rehypeAutolinkHeadings, { behavior: 'wrap' }],
          // Both themes are written into every token as custom properties, so
          // switching theme costs no re-highlight and no second payload.
          [
            rehypeShiki,
            {
              themes: { light: 'vitesse-light', dark: 'vitesse-dark' },
              defaultColor: false,
              langs: ['zig', 'swift', 'kotlin', 'typescript', 'c', 'bash', 'json', 'html', 'vue'],
            },
          ],
        ],
      }),
      enforce: 'pre',
    },
    vue(),
    tailwind(),
    docsIndex(docsRoot),
    snippets(snippetRoot),
    spaFallback(),
  ],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  build: { target: 'es2023', cssMinify: 'lightningcss', sourcemap: true },
})
