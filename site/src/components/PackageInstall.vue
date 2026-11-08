<script setup lang="ts">
import { computed, ref } from 'vue'
import CopyButton from '@/components/CopyButton.vue'

const props = defineProps<{ name: string; dev?: boolean }>()

const MANAGERS = [
  { id: 'bun', label: 'bun', verb: (p: string, dev: boolean) => `bun add ${dev ? '-d ' : ''}${p}` },
  {
    id: 'npm',
    label: 'npm',
    verb: (p: string, dev: boolean) => `npm install ${dev ? '--save-dev ' : ''}${p}`,
  },
  {
    id: 'pnpm',
    label: 'pnpm',
    verb: (p: string, dev: boolean) => `pnpm add ${dev ? '-D ' : ''}${p}`,
  },
  {
    id: 'yarn',
    label: 'yarn',
    verb: (p: string, dev: boolean) => `yarn add ${dev ? '--dev ' : ''}${p}`,
  },
  { id: 'deno', label: 'deno', verb: (p: string) => `deno add npm:${p}` },
] as const

const STORAGE_KEY = 'gosslens:package-manager'

function remembered(): string {
  try {
    const saved = localStorage.getItem(STORAGE_KEY)
    return MANAGERS.some((m) => m.id === saved) ? (saved as string) : 'npm'
  } catch {
    return 'npm'
  }
}

// One choice across every install block on the site, so a reader picks once.
const chosen = ref(remembered())

function choose(id: string): void {
  chosen.value = id
  try {
    localStorage.setItem(STORAGE_KEY, id)
  } catch {
    // A browser that refuses storage still gets the right command.
  }
}

const command = computed(() => {
  const manager = MANAGERS.find((m) => m.id === chosen.value) ?? MANAGERS[1]
  return manager.verb(props.name, props.dev ?? false)
})
</script>

<template>
  <div class="lit doc-code mt-6 overflow-hidden rounded-card">
    <div class="flex items-center gap-1 border-b border-edge px-2 py-1.5" role="tablist">
      <button
        v-for="manager in MANAGERS"
        :key="manager.id"
        type="button"
        role="tab"
        :aria-selected="manager.id === chosen"
        class="rounded-md px-3 py-1.5 text-[0.875rem] font-medium transition-colors"
        :class="
          manager.id === chosen
            ? 'bg-iris/15 text-ink'
            : 'text-ink-faint hover:bg-raised hover:text-ink-muted'
        "
        data-testid="package-manager"
        @click="choose(manager.id)"
      >
        {{ manager.label }}
      </button>
      <div class="ml-auto pr-1">
        <CopyButton :text="command" label="Copy the install command" />
      </div>
    </div>
    <p class="overflow-x-auto px-4 py-3.5 font-mono text-[0.9375rem] text-ink" data-testid="install-command">
      {{ command }}
    </p>
  </div>
</template>
