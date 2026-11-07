import { readFile, readdir } from 'node:fs/promises'
import { join } from 'node:path'

/**
 * Every link that leaves the site, asked whether it answers. Kept apart from
 * the documentation check because it needs the network, and a flaky network
 * should not fail a build that is otherwise correct.
 */
async function walk(dir: string, ext: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true })
  const found = await Promise.all(
    entries.map((entry) => {
      const full = join(dir, entry.name)
      if (entry.isDirectory()) return walk(full, ext)
      return Promise.resolve(entry.name.endsWith(ext) ? [full] : [])
    }),
  )
  return found.flat()
}

const files = [
  ...(await walk('docs', '.mdx')),
  ...(await walk('docs', '.json')),
  ...(await walk('src', '.vue')),
  ...(await walk('src', '.ts')),
  ...(await walk('plugins', '.ts')),
  'index.html',
]

const links = new Map<string, string[]>()
for (const file of files) {
  const text = await readFile(file, 'utf8').catch(() => '')
  for (const match of text.matchAll(/https?:\/\/[^\s"'`)<>\\]+/g)) {
    const url = (match[0] ?? '').replace(/[.,]$/, '')
    links.set(url, [...(links.get(url) ?? []), file])
  }
}

console.log(`checking ${links.size} external links`)
for (const [url, where] of links) console.log(`  ${url}  (${where.length} place${where.length === 1 ? '' : 's'})`)

const broken: string[] = []
await Promise.all(
  [...links].map(async ([url, where]) => {
    try {
      let response = await fetch(url, { method: 'HEAD', redirect: 'follow' })
      // Some hosts refuse HEAD but answer GET perfectly well.
      if (response.status === 405 || response.status === 403) {
        response = await fetch(url, { method: 'GET', redirect: 'follow' })
      }
      if (!response.ok) broken.push(`${url} answered ${response.status}  (${where.join(', ')})`)
    } catch (error) {
      broken.push(`${url} could not be reached: ${(error as Error).message}  (${where.join(', ')})`)
    }
  }),
)

// The edit link's base answering proves nothing about a document's own URL,
// which is the part that broke when this tree moved repository.
const source = /const SOURCE = '([^']+)'/.exec(await readFile('src/pages/DocsPage.vue', 'utf8'))?.[1]
if (source) {
  const raw = source.replace('https://github.com/', 'https://raw.githubusercontent.com/').replace('/edit/', '/')
  const documents = await walk('docs', '.mdx')
  console.log(`checking ${documents.length} document paths against the repository`)
  await Promise.all(
    documents.map(async (file) => {
      const route = file.replace(/^docs/, '')
      const response = await fetch(`${raw}${route}`, { method: 'HEAD', redirect: 'follow' })
      if (!response.ok) broken.push(`${raw}${route} answered ${response.status}, so its edit link is dead`)
    }),
  )
}

if (broken.length > 0) {
  console.error(broken.map((line) => `  ${line}`).join('\n'))
  console.error(`links: ${broken.length} broken`)
  process.exit(1)
}
console.log('links: every external link answers')
