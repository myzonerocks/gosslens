<script setup lang="ts">
import { snippets } from 'virtual:gosslens/snippets'
import { computed } from 'vue'

const record = computed(() => snippets.find((entry) => entry.name === 'record'))
</script>

<template>
  <div class="flex h-full flex-col">
    <div class="flex items-center gap-2 border-b border-edge px-4 py-2.5">
      <span class="size-1.5 rounded-full bg-lime" aria-hidden="true" />
      <span class="font-mono text-[14px] tracking-wider text-ink-faint">
        perception record
      </span>
    </div>
    <!-- Highlighted at build time, so the page ships no parser to show it. -->
    <div
      v-if="record"
      class="record-pane flex-1 overflow-auto p-4 text-[14px] leading-[1.65]"
      v-html="record.html"
    />
  </div>
</template>

<style scoped>
.record-pane :deep(pre) {
  margin: 0;
}
</style>
