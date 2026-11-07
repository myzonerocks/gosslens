<script setup lang="ts">
import { onKeyStroke } from '@vueuse/core'
import { computed, nextTick, ref, shallowRef, useTemplateRef, watch } from 'vue'
import { useRouter } from 'vue-router'
import type { Hit } from '@/lib/search'

const router = useRouter()
const open = ref(false)
const query = ref('')
const active = ref(0)
const hits = shallowRef<Hit[]>([])
const field = useTemplateRef<HTMLInputElement>('field')

// The index is a few kilobytes of words; it loads the first time it is wanted.
let find: ((query: string) => Hit[]) | null = null

function run(): void {
  hits.value = find ? find(query.value) : []
  active.value = 0
}

async function show(): Promise<void> {
  open.value = true
  await nextTick()
  field.value?.focus()
  if (find) return
  find = (await import('@/lib/search')).search
  // Someone typing while the index loaded is answered once it has.
  run()
}

function hide(): void {
  open.value = false
  query.value = ''
  hits.value = []
  active.value = 0
}

watch(query, run)

onKeyStroke(['k', 'K'], (event) => {
  if (!(event.metaKey || event.ctrlKey)) return
  event.preventDefault()
  void show()
})

// A bare slash opens search only when nobody is typing into something else.
onKeyStroke('/', (event) => {
  const focused = document.activeElement
  if (focused && focused !== document.body) return
  event.preventDefault()
  void show()
})

onKeyStroke('Escape', () => {
  if (open.value) hide()
})

function step(by: number): void {
  if (hits.value.length === 0) return
  active.value = (active.value + by + hits.value.length) % hits.value.length
}

function go(hit: Hit | undefined): void {
  if (!hit) return
  hide()
  void router.push(hit.path === '/' ? '/docs' : `/docs${hit.path}`)
}

const describedBy = computed(() => (hits.value.length > 0 ? 'search-count' : undefined))
</script>

<template>
  <button
    type="button"
    class="flex h-9 items-center gap-2 rounded-lg border border-edge-strong px-2.5 text-[0.9375rem] text-ink-muted transition-colors hover:border-iris hover:text-ink"
    aria-label="Search the documentation"
    data-testid="search-open"
    @click="show()"
  >
    <svg
      viewBox="0 0 24 24"
      class="size-4"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <circle cx="11" cy="11" r="6.5" />
      <path d="m16 16 4 4" />
    </svg>
    <span class="hidden sm:inline">Search</span>
    <kbd
      class="hidden rounded border border-edge px-1.5 py-px font-sans text-[12px] text-ink-faint sm:inline"
    >
      ⌘K
    </kbd>
  </button>

  <Teleport to="body">
    <div
      v-if="open"
      class="fixed inset-0 z-50 flex items-start justify-center bg-ground/70 px-4 pt-[12vh] backdrop-blur-sm"
      data-testid="search-overlay"
      @click.self="hide()"
    >
      <div
        class="lit w-full max-w-xl overflow-hidden rounded-card"
        role="dialog"
        aria-modal="true"
        aria-label="Search the documentation"
      >
        <div class="flex items-center gap-3 border-b border-edge px-4">
          <svg
            viewBox="0 0 24 24"
            class="size-4 shrink-0 text-ink-faint"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            aria-hidden="true"
          >
            <circle cx="11" cy="11" r="6.5" />
            <path d="m16 16 4 4" />
          </svg>
          <input
            ref="field"
            v-model="query"
            type="text"
            role="combobox"
            aria-expanded="true"
            aria-controls="search-results"
            :aria-describedby="describedBy"
            placeholder="Search the documentation"
            class="h-12 w-full bg-transparent text-[15px] text-ink outline-none placeholder:text-ink-faint"
            data-testid="search-input"
            @keydown.down.prevent="step(1)"
            @keydown.up.prevent="step(-1)"
            @keydown.enter.prevent="go(hits[active])"
          />
        </div>

        <ul
          v-if="hits.length > 0"
          id="search-results"
          class="max-h-[52vh] overflow-y-auto p-2"
          role="listbox"
        >
          <li v-for="(hit, index) in hits" :key="hit.path" role="option" :aria-selected="index === active">
            <RouterLink
              :to="hit.path === '/' ? '/docs' : `/docs${hit.path}`"
              class="block rounded-lg px-3 py-2.5 transition-colors"
              :class="index === active ? 'bg-iris/12 text-ink' : 'text-ink-muted hover:bg-raised'"
              data-testid="search-hit"
              @click="hide()"
              @mouseenter="active = index"
            >
              <span class="block text-sm font-medium text-ink">{{ hit.title }}</span>
              <span class="mt-0.5 block truncate text-xs text-ink-faint">{{ hit.excerpt }}</span>
            </RouterLink>
          </li>
        </ul>

        <!-- Nothing found and nothing typed are both drawn, never worded. -->
        <ul v-else class="p-2" aria-hidden="true" data-testid="search-ghost">
          <li v-for="row in 4" :key="row" class="px-3 py-2.5">
            <span
              class="block h-3 rounded bg-edge"
              :style="{ width: `${62 - row * 9}%`, opacity: 1 - row * 0.18 }"
            />
            <span
              class="mt-2 block h-2 rounded bg-edge"
              :style="{ width: `${84 - row * 11}%`, opacity: 0.7 - row * 0.15 }"
            />
          </li>
        </ul>

        <div
          class="flex items-center gap-4 border-t border-edge px-4 py-2.5 text-[12px] text-ink-faint"
        >
          <span class="flex items-center gap-1.5">
            <kbd class="rounded border border-edge px-1.5 py-px font-sans">&uarr;&darr;</kbd>
            move
          </span>
          <span class="flex items-center gap-1.5">
            <kbd class="rounded border border-edge px-1.5 py-px font-sans">&crarr;</kbd>
            open
          </span>
          <span class="flex items-center gap-1.5">
            <kbd class="rounded border border-edge px-1.5 py-px font-sans">esc</kbd>
            close
          </span>
        </div>

        <span v-if="hits.length > 0" id="search-count" class="sr-only">
          {{ hits.length }} results
        </span>
      </div>
    </div>
  </Teleport>
</template>
