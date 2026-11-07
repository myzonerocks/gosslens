import { records } from 'virtual:gosslens/docs-index'
import type { Component } from 'vue'
import nav from '../../docs/nav.json'

export interface NavLink {
  type: 'link'
  path: string
  title: string
  /** Set when the entry leaves the site, as the sponsor link does. */
  href?: string
}

export interface NavFolder {
  type: 'folder'
  path: string
  title: string
  children: NavLink[]
}

export type NavItem = NavLink | NavFolder

export interface DocPage {
  /** The route path, always leading-slash and never trailing. */
  path: string
  title: string
  description: string
  component: () => Promise<{ default: Component }>
}

export const navigation = nav.items as readonly NavItem[]

/** The flat reading order, so previous and next agree with the tree. */
export const reading: readonly NavLink[] = navigation
  .flatMap((item) =>
    item.type === 'folder'
      ? item.children.map((child) => ({ ...child, path: item.path + child.path }))
      : [item],
  )
  .filter((entry) => entry.href === undefined)

/** Frontmatter is read at build time, so a title never costs a request. */
const modules = import.meta.glob<{ default: Component }>('../../docs/**/*.mdx')

const written = new Map(records.map((record) => [record.path, record]))

function routeFor(file: string): string {
  const path = file
    .replace('../../docs', '')
    .replace(/\.mdx$/, '')
    .replace(/\/index$/, '')
  return path === '' ? '/' : path
}

function titleFor(path: string): string {
  const front = written.get(path)?.title
  if (front && front !== path) return front
  const listed = reading.find((entry) => entry.path === path)
  if (listed) return listed.title
  const last = path.split('/').filter(Boolean).at(-1) ?? 'Documentation'
  return last.charAt(0).toUpperCase() + last.slice(1)
}

/** Every document, keyed by the route it answers on. */
export const pages: ReadonlyMap<string, DocPage> = new Map(
  Object.entries(modules).map(([file, load]) => {
    const path = routeFor(file)
    return [
      path,
      {
        path,
        title: titleFor(path),
        description: written.get(path)?.description ?? '',
        component: load,
      },
    ]
  }),
)

/** Where a page sits, for the crumb trail. */
export function trailFor(path: string): NavLink[] {
  for (const item of navigation) {
    if (item.type === 'folder') {
      const child = item.children.find((entry) => item.path + entry.path === path)
      if (child) {
        return [
          { type: 'link', path: item.path, title: item.title },
          { ...child, path },
        ]
      }
    } else if (item.path === path) {
      return [item]
    }
  }
  return []
}

/** The pages either side of this one in reading order. */
export function neighbours(path: string): { previous?: NavLink; next?: NavLink } {
  const index = reading.findIndex((entry) => entry.path === path)
  if (index < 0) return {}
  return { previous: reading[index - 1], next: reading[index + 1] }
}
