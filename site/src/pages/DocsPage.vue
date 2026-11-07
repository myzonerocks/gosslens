<script setup lang="ts">
import { MDXProvider } from '@mdx-js/vue'
import { computed, defineAsyncComponent, h, ref, useTemplateRef, watch } from 'vue'
import { useRoute } from 'vue-router'
import CodeBlock from '@/components/CodeBlock.vue'
import DocCallout from '@/components/DocCallout.vue'
import DocsNav from '@/components/DocsNav.vue'
import TableOfContents from '@/components/TableOfContents.vue'
import { neighbours, pages, trailFor } from '@/lib/docs'

const SOURCE = 'https://github.com/myzonerocks/gosslens-site/edit/main/docs'

const route = useRoute()
const article = useTemplateRef<HTMLElement>('article')
const body = ref<HTMLElement | null>(null)

/** The document route, with /docs stripped and no trailing slash. */
const path = computed(() => {
  const raw = Array.isArray(route.params.path)
    ? route.params.path.join('/')
    : (route.params.path ?? '')
  const cleaned = String(raw).replace(/\/$/, '')
  return cleaned === '' ? '/' : `/${cleaned}`
})

const page = computed(() => pages.get(path.value))
const trail = computed(() => trailFor(path.value))
const around = computed(() => neighbours(path.value))
const file = computed(() => (path.value === '/' ? '/index' : path.value))

const Document = computed(() =>
  page.value ? defineAsyncComponent(page.value.component) : undefined,
)

watch(
  () => [article.value, path.value],
  () => {
    body.value = article.value ?? null
  },
  { flush: 'post' },
)

const navOpen = ref(false)
watch(path, () => {
  navOpen.value = false
})

/** Markdown reaches for the same primitives a page does. */
const components = {
  pre: (props: Record<string, unknown>, { slots }: { slots: Record<string, () => unknown> }) =>
    h(CodeBlock, props, { default: () => slots.default?.() }),
  Note: (_: unknown, { slots }: { slots: Record<string, () => unknown> }) =>
    h(DocCallout, { kind: 'note' }, slots),
  Tip: (_: unknown, { slots }: { slots: Record<string, () => unknown> }) =>
    h(DocCallout, { kind: 'tip' }, slots),
  Important: (_: unknown, { slots }: { slots: Record<string, () => unknown> }) =>
    h(DocCallout, { kind: 'important' }, slots),
  Warning: (_: unknown, { slots }: { slots: Record<string, () => unknown> }) =>
    h(DocCallout, { kind: 'warning' }, slots),
  Caution: (_: unknown, { slots }: { slots: Record<string, () => unknown> }) =>
    h(DocCallout, { kind: 'caution' }, slots),
}
</script>

<template>
  <div class="flex min-h-[70vh] justify-center">
    <!-- The tree keeps its own scroll so a long page never moves it. -->
    <aside
      class="sticky top-16 hidden h-[calc(100vh-4rem)] w-72 shrink-0 overflow-y-auto border-r border-edge px-4 py-8 lg:block"
    >
      <DocsNav />
    </aside>

    <div class="flex min-w-0 flex-1 justify-center">
      <article ref="article" class="min-w-0 flex-1 px-5 py-8 sm:px-8 lg:max-w-3xl lg:py-10">
        <button
          type="button"
          class="mb-6 flex w-full items-center justify-between rounded-xl border border-edge-strong px-4 py-3 text-[0.9375rem] text-ink-muted transition-colors hover:text-ink lg:hidden"
          :aria-expanded="navOpen"
          aria-controls="docs-tree"
          data-testid="docs-nav-toggle"
          @click="navOpen = !navOpen"
        >
          All documentation
          <svg
            viewBox="0 0 24 24"
            class="size-4 transition-transform"
            :class="navOpen ? 'rotate-180' : ''"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            aria-hidden="true"
          >
            <path d="m6 9.5 6 6 6-6" />
          </svg>
        </button>
        <div v-if="navOpen" id="docs-tree" class="lit mb-8 rounded-card p-3 lg:hidden">
          <DocsNav />
        </div>

        <nav
          v-if="trail.length"
          class="flex flex-wrap items-center gap-2 text-[0.8125rem] text-ink-faint"
          aria-label="Breadcrumb"
        >
          <RouterLink to="/docs" class="transition-colors hover:text-ink-muted">Docs</RouterLink>
          <template v-for="crumb in trail" :key="crumb.path">
            <span aria-hidden="true">/</span>
            <span>{{ crumb.title }}</span>
          </template>
        </nav>

        <header v-if="page" class="border-b border-edge pb-7 pt-5">
          <h1 class="text-pretty text-[2.375rem] font-bold leading-[1.1] tracking-tight">
            {{ page.title }}
          </h1>
          <p v-if="page.description" class="mt-3 max-w-2xl text-[1.0625rem] leading-relaxed text-ink-muted">
            {{ page.description }}
          </p>
        </header>

        <div v-if="Document" class="doc mt-8">
          <MDXProvider :components="components">
            <component :is="Document" />
          </MDXProvider>
        </div>
        <p v-else class="mt-8 text-ink-muted">That page is not here.</p>

        <nav
          v-if="around.previous || around.next"
          class="mt-14 grid gap-3 border-t border-edge pt-8 sm:grid-cols-2"
          aria-label="Nearby pages"
        >
          <RouterLink
            v-if="around.previous"
            :to="`/docs${around.previous.path === '/' ? '' : around.previous.path}`"
            class="group/near flex items-center gap-3 rounded-card border border-edge-strong p-4 transition-colors hover:border-iris"
          >
            <span
              class="text-ink-faint transition-transform group-hover/near:-translate-x-0.5 group-hover/near:text-iris"
              aria-hidden="true"
            >
              &larr;
            </span>
            <span class="min-w-0">
              <span class="block font-mono text-[12px] uppercase tracking-widest text-ink-faint">
                Previous
              </span>
              <span class="mt-0.5 block truncate text-[0.9375rem] font-semibold">
                {{ around.previous.title }}
              </span>
            </span>
          </RouterLink>
          <RouterLink
            v-if="around.next"
            :to="`/docs${around.next.path === '/' ? '' : around.next.path}`"
            class="group/near flex items-center justify-end gap-3 rounded-card border border-edge-strong p-4 text-right transition-colors hover:border-iris sm:col-start-2"
          >
            <span class="min-w-0">
              <span class="block font-mono text-[12px] uppercase tracking-widest text-ink-faint">
                Next
              </span>
              <span class="mt-0.5 block truncate text-[0.9375rem] font-semibold">
                {{ around.next.title }}
              </span>
            </span>
            <span
              class="text-ink-faint transition-transform group-hover/near:translate-x-0.5 group-hover/near:text-iris"
              aria-hidden="true"
            >
              &rarr;
            </span>
          </RouterLink>
        </nav>

        <p class="mt-8 text-[0.9375rem]">
          <a
            :href="`${SOURCE}${file}.mdx`"
            rel="noreferrer"
            class="text-ink-faint transition-colors hover:text-ink"
          >
            Edit this page on GitHub
          </a>
        </p>
      </article>

      <aside class="sticky top-16 hidden h-fit w-60 shrink-0 py-12 pr-8 xl:block">
        <TableOfContents :within="body" :signature="path" />
      </aside>
    </div>
  </div>
</template>
