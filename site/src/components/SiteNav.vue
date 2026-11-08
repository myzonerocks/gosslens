<script setup lang="ts">
import { onClickOutside, useScrollLock } from '@vueuse/core'
import { ref, useTemplateRef, watch } from 'vue'
import { useRoute } from 'vue-router'
import BrandMark from '@/components/BrandMark.vue'
import DocsNav from '@/components/DocsNav.vue'
import SearchPalette from '@/components/SearchPalette.vue'
import ThemeToggle from '@/components/ThemeToggle.vue'

const route = useRoute()
const open = ref(false)
const sheet = useTemplateRef<HTMLElement>('sheet')
const trigger = useTemplateRef<HTMLButtonElement>('trigger')
const locked = useScrollLock(document.body)

watch(open, (next) => {
  locked.value = next
})
watch(
  () => route.fullPath,
  () => {
    open.value = false
  },
)
// The control that opens the sheet lives outside it, so a tap on it would
// otherwise close and reopen in the same gesture.
onClickOutside(
  sheet,
  () => {
    open.value = false
  },
  { ignore: [trigger] },
)
</script>

<template>
  <header class="sticky top-0 z-40 border-b border-edge bg-ground/85 backdrop-blur-xl">
    <nav class="flex h-16 items-center gap-3 px-4 sm:px-6" aria-label="Main">
      <RouterLink
        to="/"
        class="flex shrink-0 items-center gap-2.5 text-[15px] font-semibold tracking-tight"
      >
        <BrandMark :size="26" />
        <span>gosslens</span>
      </RouterLink>

      <span class="ml-1 hidden rounded-full border border-edge px-2 py-0.5 font-mono text-[10px] tracking-wider text-ink-faint sm:inline">
        v0.14
      </span>

      <div class="ml-auto flex items-center gap-1">
        <RouterLink
          to="/docs"
          class="hidden rounded-lg px-3 py-2 text-[0.9375rem] text-ink-muted transition-colors hover:bg-raised hover:text-ink sm:block"
          active-class="text-ink"
        >
          Documentation
        </RouterLink>
        <SearchPalette />
        <a
          href="https://github.com/myzonerocks/gosslens"
          rel="noreferrer"
          aria-label="Source on GitHub"
          class="grid size-9 place-items-center rounded-lg text-ink-muted transition-colors hover:bg-raised hover:text-ink"
        >
          <svg viewBox="0 0 16 16" class="size-[18px]" fill="currentColor" aria-hidden="true">
            <path
              d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"
            />
          </svg>
        </a>
        <ThemeToggle />
        <button
          type="button"
          class="grid size-9 place-items-center rounded-lg text-ink-muted transition-colors hover:bg-raised hover:text-ink sm:hidden"
          :aria-expanded="open"
          aria-controls="mobile-nav"
          aria-label="Menu"
          ref="trigger"
          data-testid="menu-toggle"
          @click="open = !open"
        >
          <svg
            viewBox="0 0 24 24"
            class="size-5"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            aria-hidden="true"
          >
            <path v-if="!open" d="M4 7h16M4 12h16M4 17h16" />
            <path v-else d="M6 6l12 12M18 6L6 18" />
          </svg>
        </button>
      </div>
    </nav>

    <div
      v-if="open"
      id="mobile-nav"
      ref="sheet"
      class="max-h-[calc(100dvh-4rem)] overflow-y-auto border-t border-edge bg-ground px-4 pb-10 pt-2 sm:hidden"
      data-testid="mobile-nav"
    >
      <DocsNav dense />
      <RouterLink
        to="/docs"
        class="mt-6 flex min-h-11 items-center justify-between rounded-xl border border-edge-strong px-4 text-[0.9375rem] font-medium"
      >
        All documentation
        <span aria-hidden="true">&rarr;</span>
      </RouterLink>
    </div>
  </header>
</template>
