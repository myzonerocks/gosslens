<script setup lang="ts">
import { computed } from 'vue'
import { cycleTheme, theme } from '@/lib/theme'

const label = computed(() => `Theme: ${theme.value}. Change it.`)
</script>

<template>
  <button
    type="button"
    class="grid size-9 place-items-center rounded-lg text-ink-muted transition-colors hover:bg-raised hover:text-ink"
    :aria-label="label"
    :title="label"
    data-testid="theme-toggle"
    @click="cycleTheme()"
  >
    <!-- Sun, moon and a dial for system: the state is the glyph, never a word. -->
    <svg
      v-if="theme === 'system'"
      viewBox="0 0 24 24"
      class="size-[18px]"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="8.2" />
      <path d="M12 3.8v16.4" />
      <path d="M12 20.2a8.2 8.2 0 0 0 0-16.4Z" fill="currentColor" stroke="none" />
    </svg>
    <svg
      v-else-if="theme === 'dark'"
      viewBox="0 0 24 24"
      class="size-[18px]"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <path d="M20 14.2A8.2 8.2 0 1 1 9.8 4a6.6 6.6 0 0 0 10.2 10.2Z" />
    </svg>
    <svg
      v-else
      viewBox="0 0 24 24"
      class="size-[18px]"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="4.2" />
      <path
        d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M18.4 5.6L17 7M7 17l-1.4 1.4"
      />
    </svg>
  </button>
</template>
