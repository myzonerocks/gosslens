import { records } from 'virtual:gosslens/docs-index'
import MiniSearch from 'minisearch'

export interface Hit {
  path: string
  title: string
  description: string
  /** The sentence the match sits in, so a reader can judge a hit on sight. */
  excerpt: string
}

const index = new MiniSearch<(typeof records)[number]>({
  fields: ['title', 'headings', 'description', 'text'],
  storeFields: ['path', 'title', 'description', 'text'],
  idField: 'path',
  extractField: (document, field) =>
    field === 'headings' ? document.headings.join(' ') : String(document[field as 'text'] ?? ''),
  searchOptions: {
    prefix: true,
    fuzzy: 0.15,
    boost: { title: 4, headings: 2, description: 1.5 },
  },
})

index.addAll(records as (typeof records)[number][])

const WINDOW = 140

function excerptFor(text: string, terms: readonly string[]): string {
  const lower = text.toLowerCase()
  const at = terms.reduce<number>((best, term) => {
    const found = lower.indexOf(term.toLowerCase())
    return found >= 0 && (best < 0 || found < best) ? found : best
  }, -1)
  if (at < 0) return text.slice(0, WINDOW)
  const start = Math.max(0, at - 40)
  return `${start > 0 ? '…' : ''}${text.slice(start, start + WINDOW).trim()}…`
}

/** Ranked documents for a query, capped because nobody reads a long list. */
export function search(query: string, limit = 8): Hit[] {
  const trimmed = query.trim()
  if (trimmed.length === 0) return []
  // A single letter is a prefix, never a fuzzy match: one keystroke should
  // narrow the set rather than return everything that rhymes with it.
  const options =
    trimmed.length === 1 ? { prefix: true, fuzzy: false, combineWith: 'AND' as const } : {}
  return index
    .search(trimmed, options)
    .slice(0, limit)
    .map((result) => ({
      path: String(result.path),
      title: String(result.title),
      description: String(result.description),
      excerpt: excerptFor(String(result.text ?? ''), result.terms),
    }))
}
