import { readFile, readdir } from 'node:fs/promises'
import { join, relative, sep } from 'node:path'

/**
 * Every engine symbol a document names has to exist in the header, and no page
 * may use a dash the house style forbids. A wrong symbol in documentation is a
 * bug a reader finds at their keyboard.
 */
const HEADER = process.env.GOSSLENS_HEADER ?? '../include/gosslens.h'
const BUILD = process.env.GOSSLENS_BUILD ?? '../build.zig'
const MCP = process.env.GOSSLENS_MCP ?? '../tools/mcp/server.zig'
const SDK_ROOT = process.env.GOSSLENS_SDK ?? '../sdk'

/** Which SDK source a page's code blocks are checked against. */
/** Language built-ins a page may call that no SDK defines. */
const BUILTIN = new Set([
  'contains', 'append', 'forEach', 'map', 'filter', 'reduce', 'count', 'first',
  'last', 'joined', 'split', 'replacingOccurrences', 'withUnsafeBytes', 'init',
  'collect', 'toList', 'toString', 'let', 'also', 'apply', 'run', 'push',
  'then', 'catch', 'slice', 'json', 'text', 'getElementById', 'querySelector',
])

const SDKS = [
  { page: 'sdk/swift', dir: 'swift/Sources/Gosslens', fence: 'swift' },
  { page: 'sdk/kotlin', dir: 'kotlin/src/main/kotlin/com/gosslens', fence: 'kotlin' },
  { page: 'sdk/typescript', dir: 'ts/src', fence: 'ts' },
]
const DOCS = 'docs'

async function walk(dir: string, ext = '.mdx'): Promise<string[]> {
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

const problems: string[] = []

/**
 * A page git never took is a page the site ships a dead link to. Ignore rules
 * are easy to inherit and impossible to see, so this asks git directly.
 */
async function untracked(): Promise<string[]> {
  const git = Bun.spawnSync(['git', 'ls-files', '--others', '--ignored', '--exclude-standard', DOCS])
  if (git.exitCode !== 0) return []
  return new TextDecoder().decode(git.stdout).split('\n').filter(Boolean)
}

/**
 * The edit link is built from one constant, and nothing fails when it points
 * at a repository that moved. Ask git where this checkout actually lives.
 */
async function editLink(): Promise<void> {
  const page = await readFile('src/pages/DocsPage.vue', 'utf8').catch(() => '')
  const link = /const SOURCE = '([^']+)'/.exec(page)?.[1]
  if (!link) {
    problems.push('DocsPage has no SOURCE constant, so the edit link cannot be checked')
    return
  }

  const git = Bun.spawnSync(['git', 'remote', 'get-url', 'origin'])
  const remote = new TextDecoder().decode(git.stdout).trim()
  const slug = /github\.com[:/]([^/]+\/[^/.]+)/.exec(remote)?.[1]
  if (!slug) return

  const expected = `https://github.com/${slug}/edit/main/`
  if (!link.startsWith(expected)) {
    problems.push(`the edit link points at ${link}, but this checkout is ${slug}`)
    return
  }

  // The tail has to be where the documents really are, from the repository root.
  const root = new TextDecoder()
    .decode(Bun.spawnSync(['git', 'rev-parse', '--show-prefix']).stdout)
    .trim()
  const want = `${expected}${root}${DOCS}`
  if (link !== want) problems.push(`the edit link should end at ${root}${DOCS}, not ${link.slice(expected.length)}`)
}

await editLink()

/**
 * Every internal link has to land on a document that exists. A link written by
 * hand in prose is the easiest thing in this repository to get wrong, and
 * nothing else notices until a reader clicks it.
 */
async function internalLinks(): Promise<void> {
  const files = await walk(DOCS)
  const routes = new Set<string>()
  for (const file of files) {
    const route = `/${relative(DOCS, file).split(sep).join('/')}`
      .replace(/\.mdx$/, '')
      .replace(/\/index$/, '')
    routes.add(`/docs${route === '/' ? '' : route}`)
  }
  routes.add('/docs')
  routes.add('/')

  const sources = [...files, ...(await walk('src', '.vue')), ...(await walk('src', '.ts'))]
  for (const file of sources) {
    const text = await readFile(file, 'utf8')
    const found = [
      ...[...text.matchAll(/\]\((\/[^)\s#]*)[^)]*\)/g)].map((m) => m[1] ?? ''),
      ...[...text.matchAll(/to="(\/[^"#]*)"/g)].map((m) => m[1] ?? ''),
      ...[...text.matchAll(/to:\s*'(\/[^']*)'/g)].map((m) => m[1] ?? ''),
    ]
    for (const link of found) {
      const path = link.replace(/\/$/, '') || '/'
      if (!routes.has(path)) problems.push(`${file} links to ${link}, which is not a page`)
    }
  }
}

await internalLinks()

/**
 * An interpolated route is invisible to the check above, which is how four dead
 * SDK links shipped in a footer. The tree builds its own from checked nav data.
 */
const NAV_DRIVEN = ['DocsNav.vue', 'DocsPage.vue']

async function noComputedDocLinks(): Promise<void> {
  for (const file of [...(await walk('src', '.vue')), ...(await walk('src', '.ts'))]) {
    if (NAV_DRIVEN.some((name) => file.endsWith(name))) continue
    const text = await readFile(file, 'utf8')
    for (const match of text.matchAll(/:to="`(\/docs[^`]*)`"/g)) {
      problems.push(`${file} builds the link ${match[1]} by interpolation; write it out so it can be checked`)
    }
  }
}

await noComputedDocLinks()

/**
 * A site scaffolded from a sibling keeps that sibling's illustration until
 * somebody notices. These words belong to other projects, never to this one.
 */
const FOREIGN: Record<string, string[]> = {
  gossveil: ['sealed envelope', 'ratchet', 'whisper'],
  gossmark: ['staff badge', 'revocation', 'capability grants'],
  rank: ['momentum', 'for you feed'],
  music: ['attribution', 'isrc'],
  pact: ['corridor', 'pay-out leg'],
  quid: ['payout ledger'],
}

async function noForeignVocabulary(): Promise<void> {
  for (const file of [...(await walk('src', '.vue')), ...(await walk('src', '.ts'))]) {
    const text = (await readFile(file, 'utf8')).toLowerCase()
    for (const [project, words] of Object.entries(FOREIGN)) {
      for (const word of words) {
        if (text.includes(word)) {
          problems.push(`${file} says "${word}", which belongs to ${project}, not to this site`)
        }
      }
    }
  }
}

await noForeignVocabulary()

/**
 * index.html names its icon and its mark; a site scaffolded without public/
 * serves a blank tab and nothing fails. Ask the filesystem for each one.
 */
async function pageAssets(): Promise<void> {
  const html = await readFile('index.html', 'utf8').catch(() => '')
  for (const match of html.matchAll(/(?:href|src)="\/([^"?#]+)(?:\?[^"]*)?"/g)) {
    const asset = match[1] ?? ''
    if (asset.startsWith('src/')) continue
    const found = await readFile(join('public', asset), 'utf8').catch(() => null)
    if (found === null) problems.push(`index.html asks for /${asset}, which public/ does not hold`)
  }
}

await pageAssets()

/**
 * A shell block with two commands in it hands a reader both when they wanted
 * one. Each command gets its own block so the copy button copies the command
 * they came for.
 */
async function oneCommandPerBlock(): Promise<void> {
  const runnable = /^\s*(zig|bun|npm|pnpm|yarn|deno|git|make|cargo|gradle|mvn|xcodebuild|adb|tools\/|\.\/)/
  for (const file of await walk(DOCS)) {
    const text = await readFile(file, 'utf8')
    for (const block of text.matchAll(/```[a-z]*\n([\s\S]*?)```/g)) {
      const commands = (block[1] ?? '')
        .split('\n')
        .filter((line) => line.trim() && !line.trim().startsWith('#'))
        .filter((line) => runnable.test(line))
      if (commands.length > 1) {
        problems.push(`${file} has ${commands.length} commands in one block: "${commands[0]?.trim()}" and more`)
      }
    }
  }
}

await oneCommandPerBlock()

for (const file of await untracked()) {
  problems.push(`${file} is ignored by a gitignore rule, so it would never ship`)
}

/**
 * Step names reach build.zig two ways: as a literal, and through a config
 * struct. A check that knows only the literal form reports real steps missing.
 */
async function buildSteps(): Promise<Set<string>> {
  try {
    const source = await readFile(BUILD, 'utf8')
    const literal = [...source.matchAll(/b\.step\(\s*"([a-zA-Z0-9_-]+)"/g)].map((m) => m[1] ?? '')
    const configured = [...source.matchAll(/\.step_name\s*=\s*"([a-zA-Z0-9_-]+)"/g)].map(
      (m) => m[1] ?? '',
    )
    return new Set([...literal, ...configured])
  } catch {
    return new Set()
  }
}

/**
 * Everything the agent server says, tool names and the answers it gives alike.
 * A name in the agent page that is not in here is a name nobody will find.
 */
async function mcpVocabulary(): Promise<Set<string>> {
  try {
    const source = await readFile(MCP, 'utf8')
    return new Set([...source.matchAll(/"([a-z_]+)"/g)].map((m) => m[1] ?? ''))
  } catch {
    return new Set()
  }
}

/**
 * Every identifier an SDK's own sources contain. A name used in that SDK's
 * page that is absent here is a name a reader cannot call.
 */
async function sdkWords(dir: string, ext: string): Promise<Set<string>> {
  try {
    const files = await walk(join(SDK_ROOT, dir), ext)
    const words = new Set<string>()
    for (const file of files) {
      for (const word of (await readFile(file, 'utf8')).match(/[A-Za-z_][A-Za-z0-9_]*/g) ?? []) {
        words.add(word)
      }
    }
    return words
  } catch {
    return new Set()
  }
}

const tools = await mcpVocabulary()
const steps = await buildSteps()
if (steps.size === 0) console.log(`docs: build.zig not found at ${BUILD}, step check skipped`)

let header = ''
try {
  header = await readFile(HEADER, 'utf8')
} catch {
  console.log(`docs: header not found at ${HEADER}, symbol check skipped`)
}

const known = new Set([
  ...(header.match(/\bgoss_[a-z0-9_]+/g) ?? []),
  ...(header.match(/\bGOSS_[A-Z0-9_]+/g) ?? []),
])

for (const file of await walk(DOCS)) {
  const text = await readFile(file, 'utf8')

  text.split('\n').forEach((line, index) => {
    if (/[–—]/.test(line)) {
      problems.push(`${file}:${index + 1} uses an em or en dash`)
    }
  })

  // A json example a reader pastes has to parse. Typos here cost an afternoon.
  for (const block of text.matchAll(/```json\n([\s\S]*?)```/g)) {
    try {
      JSON.parse(block[1] ?? '')
    } catch (error) {
      problems.push(`${file} has a json block that does not parse: ${(error as Error).message}`)
    }
  }

  // A colon inside an unquoted frontmatter value is a build failure, and the
  // message names a yaml loader rather than the page that broke.
  const front = /^---\n([\s\S]*?)\n---/.exec(text)?.[1] ?? ''
  for (const line of front.split('\n')) {
    const value = /^(title|description):\s*(.*)$/.exec(line)
    if (!value) continue
    const body = value[2] ?? ''
    if (!/^["']/.test(body) && /:\s/.test(body)) {
      problems.push(`${file} has an unquoted ${value[1]} containing a colon`)
    }
  }

  // Calls made on an SDK object have to exist in that SDK's sources. Platform
  // and standard-library calls are somebody else's to verify.
  for (const sdk of SDKS) {
    if (!file.includes(sdk.page)) continue
    const known = await sdkWords(sdk.dir, sdk.fence === 'kotlin' ? '.kt' : `.${sdk.fence}`)
    if (known.size === 0) continue
    const fenced = new RegExp(`\`\`\`${sdk.fence}\\n([\\s\\S]*?)\`\`\``, 'g')
    for (const block of text.matchAll(fenced)) {
      const body = (block[1] ?? '').replace(/\/\/.*$/gm, '')
      const calls = body.matchAll(/\b(session|engine|world|output|mic|goss|preview)\.([a-zA-Z][A-Za-z0-9_]*)/g)
      for (const call of calls) {
        const name = call[2] ?? ''
        if (!BUILTIN.has(name) && !known.has(name)) {
          problems.push(`${file} calls ${call[1]}.${name}, which the ${sdk.fence} SDK does not define`)
        }
      }
    }
  }

  // Tool names and status words appear as inline code in the agent page.
  if (tools.size > 0 && file.includes('agents')) {
    for (const match of text.matchAll(/`([a-z_]{4,})`/g)) {
      const name = match[1] ?? ''
      if (name.includes('_') && !tools.has(name) && !name.startsWith('goss')) {
        problems.push(`${file} names ${name}, which the agent server never says`)
      }
    }
  }

  if (steps.size > 0) {
    for (const match of text.matchAll(/zig build ([a-z0-9-]+)/g)) {
      const step = match[1] ?? ''
      if (!steps.has(step)) problems.push(`${file} says "zig build ${step}", which build.zig has no step for`)
    }
  }

  if (known.size === 0) continue

  // An SDK page may name that SDK's own constants, which the header never had.
  const sdk = SDKS.find((entry) => file.includes(entry.page))
  const extra = sdk ? await sdkWords(sdk.dir, sdk.fence === 'kotlin' ? '.kt' : `.${sdk.fence}`) : null

  const named = new Set([
    ...(text.match(/\bgoss_[a-z0-9_]+/g) ?? []),
    ...(text.match(/\bGOSS_[A-Z0-9_]+/g) ?? []),
  ])
  for (const symbol of named) {
    if (known.has(symbol) || extra?.has(symbol)) continue
    problems.push(`${file} names ${symbol}, which neither the header nor its SDK defines`)
  }
}

if (problems.length > 0) {
  console.error(problems.map((line) => `  ${line}`).join('\n'))
  console.error(`docs: ${problems.length} problems`)
  process.exit(1)
}
console.log('docs: symbols, build steps and json examples all check out')
