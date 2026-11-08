<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { navigation } from '@/lib/docs'

const props = defineProps<{ dense?: boolean }>()

/** The tree hangs off one hairline; the page you are on lights its segment. */
const ROW = 'doc-row'
const HERE = 'doc-row--here'
const SECTION =
  '-ml-px flex w-full items-center gap-1.5 border-l-2 border-transparent py-[7px] pl-4 pr-2 pt-5 font-mono text-[12px] uppercase tracking-[0.16em] text-ink-faint transition-colors hover:text-ink-muted'

const route = useRoute()

/** Touch wants a bigger row than a pointer does. */
const row = computed(() =>
  props.dense ? `${ROW} min-h-11 flex items-center text-[0.9375rem]` : ROW,
)
const section = computed(() => (props.dense ? `${SECTION} min-h-10 pt-6 text-[12px]` : SECTION))

/** Which document the reader is on, as the tree spells its paths. */
const here = computed(() => route.path.replace(/^\/docs/, '') || '/')

const open = ref(new Set<string>())

// A section opens because the reader is in it, and stays open until they say
// otherwise. Everything else starts closed, so the whole tree fits on a screen.
watch(
  here,
  (path) => {
    for (const item of navigation) {
      if (item.type === 'folder' && path.startsWith(`${item.path}/`)) open.value.add(item.path)
    }
  },
  { immediate: true },
)

function toggle(path: string): void {
  const next = new Set(open.value)
  if (!next.delete(path)) next.add(path)
  open.value = next
}
</script>

<template>
  <nav aria-label="Documentation">
    <ul class="border-l border-edge">
      <li v-for="item in navigation" :key="item.path">
        <a
          v-if="item.type === 'link' && item.href"
          :href="item.href"
          rel="noreferrer"
          :class="`${row} flex items-center gap-1.5`"
          data-testid="doc-external"
        >
          {{ item.title }}
          <svg
            viewBox="0 0 24 24"
            class="size-3.5 shrink-0 text-ink-faint"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            aria-hidden="true"
          >
            <path d="M8.5 15.5 15.5 8.5M9.5 8.5h6v6" />
          </svg>
        </a>
        <RouterLink
          v-else-if="item.type === 'link'"
          :to="`/docs${item.path === '/' ? '' : item.path}`"
          :class="row"
          :exact-active-class="HERE"
          data-testid="doc-link"
        >
          {{ item.title }}
        </RouterLink>
        <template v-else>
          <button
            type="button"
            :class="section"
            :aria-expanded="open.has(item.path)"
            :aria-controls="`tree-${item.path.slice(1)}`"
            data-testid="doc-section"
            @click="toggle(item.path)"
          >
            {{ item.title }}
            <svg
              viewBox="0 0 24 24"
              class="size-3 transition-transform duration-200"
              :class="open.has(item.path) ? 'rotate-90' : ''"
              fill="none"
              stroke="currentColor"
              stroke-width="2.4"
              stroke-linecap="round"
              aria-hidden="true"
            >
              <path d="m9 6 6 6-6 6" />
            </svg>
          </button>
          <ul v-show="open.has(item.path)" :id="`tree-${item.path.slice(1)}`">
            <li v-for="child in item.children" :key="child.path">
              <RouterLink
                :to="`/docs${item.path}${child.path}`"
                :class="row"
                :exact-active-class="HERE"
                data-testid="doc-link"
              >
                {{ child.title }}
              </RouterLink>
            </li>
          </ul>
        </template>
      </li>
    </ul>
  </nav>
</template>
