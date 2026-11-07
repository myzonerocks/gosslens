import { readdir, readFile } from 'node:fs/promises'
import { extname, join } from 'node:path'
import { createHighlighter } from 'shiki'
import type { Plugin } from 'vite'

const MODULE_ID = 'virtual:gosslens/snippets'

const LANGS: Record<string, string> = {
  '.swift': 'swift',
  '.kt': 'kotlin',
  '.ts': 'typescript',
  '.c': 'c',
  '.zig': 'zig',
  '.sh': 'bash',
  '.json': 'json',
}

const LABELS: Record<string, string> = {
  swift: 'Swift',
  kotlin: 'Kotlin',
  typescript: 'TypeScript',
  c: 'C',
  zig: 'Zig',
  bash: 'Shell',
  json: 'JSON',
}

export interface Snippet {
  name: string
  lang: string
  label: string
  /** Highlighted once, in both themes, so switching costs nothing. */
  html: string
}

/**
 * Highlights the sample programs at build time. Dropping a file into
 * src/snippets is the whole of adding one.
 */
export function snippets(root: string): Plugin {
  let compiled: Snippet[] = []

  async function collect(): Promise<void> {
    const highlighter = await createHighlighter({
      themes: ['vitesse-light', 'vitesse-dark'],
      langs: Object.values(LANGS),
    })
    const files = (await readdir(root)).filter((file) => LANGS[extname(file)] !== undefined)
    compiled = await Promise.all(
      files.sort().map(async (file) => {
        const lang = LANGS[extname(file)] ?? 'text'
        const code = (await readFile(join(root, file), 'utf8')).trimEnd()
        return {
          name: file.replace(extname(file), ''),
          lang,
          label: LABELS[lang] ?? lang,
          html: highlighter.codeToHtml(code, {
            lang,
            themes: { light: 'vitesse-light', dark: 'vitesse-dark' },
            defaultColor: false,
          }),
        }
      }),
    )
    highlighter.dispose()
  }

  return {
    name: 'gosslens:snippets',
    async buildStart() {
      await collect()
    },
    resolveId(id) {
      return id === MODULE_ID ? `\0${MODULE_ID}` : null
    },
    load(id) {
      if (id !== `\0${MODULE_ID}`) return null
      return `export const snippets = ${JSON.stringify(compiled)}\n`
    },
    configureServer(server) {
      server.watcher.add(`${root}/**`)
      server.watcher.on('all', async (_event, file) => {
        if (LANGS[extname(file)] === undefined || !file.startsWith(root)) return
        await collect()
        const mod = server.moduleGraph.getModuleById(`\0${MODULE_ID}`)
        if (mod) server.reloadModule(mod)
      })
    },
  }
}
