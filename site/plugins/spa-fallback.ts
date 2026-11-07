import { copyFile, mkdir, readdir } from 'node:fs/promises'
import { join, relative, sep } from 'node:path'
import type { Plugin } from 'vite'

async function walk(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true })
  const found = await Promise.all(
    entries.map((entry) => {
      const full = join(dir, entry.name)
      if (entry.isDirectory()) return walk(full)
      return Promise.resolve(entry.name.endsWith('.mdx') ? [full] : [])
    }),
  )
  return found.flat()
}

/** The route a document answers on, the same way the site derives it. */
function routeFor(file: string, root: string): string {
  const path = `/${relative(root, file).split(sep).join('/')}`
    .replace(/\.mdx$/, '')
    .replace(/\/index$/, '')
  return path === '' ? '' : path
}

/**
 * A static host has no rewrite rules, so every page the site can serve gets a
 * real file. Without this a shared link to a document answers 404, which
 * renders correctly and still tells crawlers and link previews it is missing.
 */
export function staticRoutes(docsRoot: string): Plugin {
  let outDir = 'dist'
  return {
    name: 'gosslens:static-routes',
    apply: 'build',
    configResolved(config) {
      outDir = config.build.outDir
    },
    async closeBundle() {
      const index = join(outDir, 'index.html')

      // Anything the site does not know about still reaches the app.
      await copyFile(index, join(outDir, '404.html'))

      const routes = [
        '/docs',
        ...(await walk(docsRoot)).map((file) => `/docs${routeFor(file, docsRoot)}`),
      ]
      const written = new Set<string>()
      for (const route of routes) {
        if (written.has(route)) continue
        written.add(route)
        const dir = join(outDir, ...route.split('/').filter(Boolean))
        await mkdir(dir, { recursive: true })
        await copyFile(index, join(dir, 'index.html'))
      }
      this.info(`wrote ${written.size} route files beside 404.html`)
    },
  }
}
