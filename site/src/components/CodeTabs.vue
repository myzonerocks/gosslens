<script setup lang="ts">
import { snippets } from 'virtual:gosslens/snippets'
import { computed, ref } from 'vue'
import CopyButton from '@/components/CopyButton.vue'

const ORDER = ['swift', 'kotlin', 'typescript', 'c']
const SHOWN = new Set(ORDER)

const shown = computed(() =>
  snippets
    .filter((entry) => SHOWN.has(entry.name))
    .sort((a, b) => ORDER.indexOf(a.name) - ORDER.indexOf(b.name)),
)
const active = ref(shown.value[0]?.name ?? '')
const current = computed(() => shown.value.find((entry) => entry.name === active.value))

/** The highlighted markup is for the eye; the clipboard gets the program. */
const plain = computed(() =>
  (current.value?.html ?? '')
    .replace(/<[^>]+>/g, '')
    .replace(/&#x3C;/g, '<')
    .replace(/&amp;/g, '&')
    .trimEnd(),
)
</script>

<template>
  <div class="lit overflow-hidden rounded-card">
    <div class="flex items-center gap-1 border-b border-edge px-2 py-1.5">
      <div class="flex items-center gap-1" role="tablist">
      <button
        v-for="entry in shown"
        :key="entry.name"
        type="button"
        role="tab"
        :aria-selected="entry.name === active"
        :class="
          entry.name === active
            ? 'bg-iris/12 text-ink'
            : 'text-ink-faint hover:bg-raised hover:text-ink-muted'
        "
        class="rounded-md px-3 py-1.5 text-xs font-medium transition-colors"
        data-testid="code-tab"
        @click="active = entry.name"
      >
        {{ entry.label }}
      </button>
      </div>
      <div class="ml-auto pr-1">
        <CopyButton :text="plain" label="Copy this program" />
      </div>
    </div>
    <!-- Highlighted at build time, so no parser ships to the reader. -->
    <div
      v-if="current"
      :key="current.name"
      class="code-pane overflow-x-auto p-4 text-[14px] leading-relaxed"
      data-testid="code-pane"
      v-html="current.html"
    />
  </div>
</template>

<style scoped>
.code-pane :deep(pre) {
  margin: 0;
}
</style>
