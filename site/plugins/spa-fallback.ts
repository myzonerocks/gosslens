import { copyFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { Plugin } from 'vite'

/**
 * Static hosts answer an unknown path with 404.html rather than rewriting to
 * the app, so a shared link to a document needs that file to be the app.
 */
export function spaFallback(): Plugin {
  let outDir = 'dist'
  return {
    name: 'gosslens:spa-fallback',
    apply: 'build',
    configResolved(config) {
      outDir = config.build.outDir
    },
    async closeBundle() {
      await copyFile(join(outDir, 'index.html'), join(outDir, '404.html'))
    },
  }
}
