import { readdir, readFile } from 'node:fs/promises'
import { join, relative, sep } from 'node:path'
import matter from 'gray-matter'
import type { Plugin } from 'vite'

export interface DocRecord {
  /** The route this document answers on, leading slash and no extension. */
  path: string
  title: string
  description: string
  headings: string[]
  text: string
}

const MODULE_ID = 'virtual:gosslens/docs-index'

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

function routeFor(file: string, root: string): string {
  const path = `/${relative(root, file).split(sep).join('/')}`
    .replace(/\.mdx$/, '')
    .replace(/\/index$/, '')
  return path === '' ? '/' : path
}

/** Headings carry most of a document's meaning, so they are indexed apart. */
function headingsOf(body: string): string[] {
  return [...body.matchAll(/^#{1,4}\s+(.+)$/gm)].map((match) => match[1]?.trim() ?? '')
}

/** Reduce MDX to the words a reader would see, so a search hit is a real hit. */
function plainTextOf(body: string): string {
  return body
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/!\[[^\]]*]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]*)]\([^)]*\)/g, '$1')
    .replace(/[#>*_`|-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

/**
 * Reads every document once at build time and hands the site a ready index, so
 * the browser never parses markdown to answer a keystroke.
 */
export function docsIndex(root: string): Plugin {
  let records: DocRecord[] = []

  async function collect(): Promise<void> {
    const files = (await walk(root)).sort()
    records = await Promise.all(
      files.map(async (file) => {
        const raw = await readFile(file, 'utf8')
        const { data, content } = matter(raw)
        const path = routeFor(file, root)
        return {
          path,
          title: typeof data.title === 'string' ? data.title : path,
          description: typeof data.description === 'string' ? data.description : '',
          headings: headingsOf(content),
          text: plainTextOf(content),
        }
      }),
    )
  }

  return {
    name: 'gosslens:docs-index',
    async buildStart() {
      await collect()
    },
    resolveId(id) {
      return id === MODULE_ID ? `\0${MODULE_ID}` : null
    },
    load(id) {
      if (id !== `\0${MODULE_ID}`) return null
      return `export const records = ${JSON.stringify(records)}\n`
    },
    configureServer(server) {
      const watched = `${root}/**/*.mdx`
      server.watcher.add(watched)
      server.watcher.on('all', async (_event, file) => {
        if (!file.endsWith('.mdx')) return
        await collect()
        const mod = server.moduleGraph.getModuleById(`\0${MODULE_ID}`)
        if (mod) server.reloadModule(mod)
      })
    },
  }
}
