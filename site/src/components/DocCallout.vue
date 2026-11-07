<script setup lang="ts">
import { computed } from 'vue'

const props = withDefaults(
  defineProps<{ kind?: 'note' | 'tip' | 'important' | 'warning' | 'caution' }>(),
  {
    kind: 'note',
  },
)

const tone = computed(
  () =>
    ({
      note: 'border-l-iris text-ink-muted',
      tip: 'border-l-lime text-ink-muted',
      important: 'border-l-iris-bright text-ink-muted',
      warning: 'border-l-amber-400 text-ink-muted',
      caution: 'border-l-rose-400 text-ink-muted',
    })[props.kind],
)
</script>

<template>
  <aside class="my-6 rounded-r-lg border-l-2 bg-surface/60 px-5 py-4" :class="tone">
    <p class="mb-1 text-xs font-semibold uppercase tracking-widest text-ink-faint">{{ kind }}</p>
    <slot />
  </aside>
</template>
