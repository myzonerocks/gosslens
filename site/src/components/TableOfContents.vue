<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue'

const props = defineProps<{ within: HTMLElement | null; signature?: string }>()

interface Entry {
  id: string
  text: string
  depth: number
}

const entries = ref<Entry[]>([])
const active = ref('')
let spy: IntersectionObserver | null = null
let changes: MutationObserver | null = null
let queued = 0

function collect(): void {
  spy?.disconnect()
  const root = props.within
  if (!root) {
    entries.value = []
    return
  }
  const found = [...root.querySelectorAll<HTMLElement>('h2[id], h3[id]')]
  entries.value = found.map((node) => ({
    id: node.id,
    text: node.textContent?.trim() ?? '',
    depth: node.tagName === 'H3' ? 3 : 2,
  }))
  if (found.length === 0) return
  active.value = found[0]?.id ?? ''

  // The heading nearest the top that has passed it is the one being read.
  spy = new IntersectionObserver(
    (records) => {
      const hit = records.filter((record) => record.isIntersecting).at(0)
      if (hit?.target.id) active.value = hit.target.id
    },
    { rootMargin: '-80px 0px -70% 0px', threshold: 0 },
  )
  for (const node of found) spy.observe(node)
}

/** A document arrives asynchronously, so the headings are watched for, not awaited. */
function watchContainer(): void {
  changes?.disconnect()
  collect()
  const root = props.within
  if (!root) return
  changes = new MutationObserver(() => {
    cancelAnimationFrame(queued)
    queued = requestAnimationFrame(collect)
  })
  changes.observe(root, { childList: true, subtree: true })
}

watch(() => [props.within, props.signature], watchContainer, { flush: 'post', immediate: true })

onBeforeUnmount(() => {
  cancelAnimationFrame(queued)
  spy?.disconnect()
  changes?.disconnect()
})
</script>

<template>
  <nav v-if="entries.length > 1" aria-label="On this page" data-testid="toc">
    <p class="font-mono text-[12px] uppercase tracking-widest text-ink-faint">On this page</p>
    <ul class="mt-3 space-y-1 border-l border-edge">
      <li v-for="entry in entries" :key="entry.id">
        <a
          :href="`#${entry.id}`"
          class="-ml-px block border-l py-1.5 text-[0.9375rem] leading-snug transition-colors"
          :class="[
            entry.depth === 3 ? 'pl-6' : 'pl-3',
            entry.id === active
              ? 'border-iris text-ink'
              : 'border-transparent text-ink-faint hover:text-ink-muted',
          ]"
        >
          {{ entry.text }}
        </a>
      </li>
    </ul>
  </nav>
</template>
