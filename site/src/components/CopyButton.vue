<script setup lang="ts">
import { useClipboard, useTimeoutFn } from '@vueuse/core'
import { ref } from 'vue'

const props = defineProps<{ text: string; label?: string }>()

const { copy, isSupported } = useClipboard({ legacy: true })
const done = ref(false)
const { start } = useTimeoutFn(
  () => {
    done.value = false
  },
  1600,
  { immediate: false },
)

async function run(): Promise<void> {
  await copy(props.text)
  done.value = true
  start()
}
</script>

<template>
  <button
    v-if="isSupported"
    type="button"
    class="copy"
    :class="done ? 'copy--done' : ''"
    :aria-label="done ? 'Copied' : (label ?? 'Copy to clipboard')"
    data-testid="copy-button"
    @click="run()"
  >
    <span class="copy__icons" aria-hidden="true">
      <svg
        class="copy__mark"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <rect x="9" y="9" width="11" height="11" rx="2.5" />
        <path d="M5.5 15H5a1.5 1.5 0 0 1-1.5-1.5V5A1.5 1.5 0 0 1 5 3.5h8.5A1.5 1.5 0 0 1 15 5v.5" />
      </svg>
      <svg
        class="copy__tick"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2.1"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="m5 12.5 4.5 4.5L19 7.5" />
      </svg>
    </span>
    <span class="sr-only" role="status" aria-live="polite">{{ done ? 'Copied' : '' }}</span>
  </button>
</template>

<style scoped>
.copy {
  position: relative;
  display: grid;
  place-items: center;
  width: 2rem;
  height: 2rem;
  border: 1px solid var(--color-edge-strong);
  border-radius: 0.5rem;
  background: color-mix(in oklab, var(--color-surface) 80%, transparent);
  color: var(--color-ink-faint);
  backdrop-filter: blur(6px);
  transition:
    color 160ms var(--ease-liquid),
    border-color 160ms var(--ease-liquid),
    transform 160ms var(--ease-liquid);
}

.copy:hover {
  color: var(--color-ink);
  border-color: color-mix(in oklab, var(--color-iris) 60%, var(--color-edge));
}

.copy:active {
  transform: scale(0.94);
}

.copy__icons {
  position: relative;
  width: 1rem;
  height: 1rem;
}

.copy__icons svg {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  transition:
    opacity 180ms var(--ease-liquid),
    transform 220ms cubic-bezier(0.2, 1.4, 0.4, 1);
}

.copy__tick {
  opacity: 0;
  transform: scale(0.5) rotate(-12deg);
  color: var(--color-lime);
}

.copy--done {
  color: var(--color-lime);
  border-color: color-mix(in oklab, var(--color-lime) 55%, var(--color-edge));
}

.copy--done .copy__mark {
  opacity: 0;
  transform: scale(0.5) rotate(10deg);
}

.copy--done .copy__tick {
  opacity: 1;
  transform: scale(1) rotate(0deg);
}

/* The ring that confirms the copy, once, from the button's own edge. */
.copy--done::after {
  content: "";
  position: absolute;
  inset: -1px;
  border-radius: inherit;
  border: 1px solid var(--color-lime);
  animation: copy-ring 620ms var(--ease-liquid) forwards;
}

@keyframes copy-ring {
  from {
    opacity: 0.9;
    transform: scale(1);
  }
  to {
    opacity: 0;
    transform: scale(1.35);
  }
}

@media (prefers-reduced-motion: reduce) {
  .copy--done::after {
    display: none;
  }
}
</style>
