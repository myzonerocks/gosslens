/// <reference types="vite/client" />

declare module '*.vue' {
  import type { DefineComponent } from 'vue'

  const component: DefineComponent<Record<string, unknown>, Record<string, unknown>, unknown>
  export default component
}

declare module '*.mdx' {
  import type { Component } from 'vue'

  const component: Component
  export default component
  export const frontmatter: { title: string; description?: string }
}

declare module 'virtual:gosslens/docs-index' {
  export const records: readonly {
    path: string
    title: string
    description: string
    headings: string[]
    text: string
  }[]
}

declare module 'virtual:gosslens/snippets' {
  export const snippets: readonly {
    name: string
    lang: string
    label: string
    html: string
  }[]
}
