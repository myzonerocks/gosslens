<script setup lang="ts">
import Mark from '@/components/Mark.vue'
import { reading } from '@/lib/docs'

const start = reading[0]
</script>

<template>
  <footer class="border-t border-edge">
    <div class="mx-auto grid max-w-7xl gap-10 px-6 py-14 sm:grid-cols-2 lg:grid-cols-4">
      <div class="sm:col-span-2 lg:col-span-1">
        <div class="flex items-center gap-2.5 font-semibold tracking-tight">
          <Mark :size="24" />
          gosslens
        </div>
        <p class="mt-3 max-w-xs text-[0.9375rem] leading-relaxed text-ink-faint">
          A real-time visual engine with one Zig core and one frozen C ABI.
        </p>
      </div>

      <div>
        <p class="font-mono text-[12px] uppercase tracking-widest text-ink-faint">Start</p>
        <ul class="mt-3 space-y-2 text-[0.9375rem]">
          <li>
            <RouterLink class="text-ink-muted transition-colors hover:text-ink" to="/docs">
              {{ start?.title ?? 'Introduction' }}
            </RouterLink>
          </li>
          <li>
            <RouterLink
              class="text-ink-muted transition-colors hover:text-ink"
              to="/docs/install/sdks"
            >
              Add an SDK
            </RouterLink>
          </li>
          <li>
            <RouterLink
              class="text-ink-muted transition-colors hover:text-ink"
              to="/docs/install/build"
            >
              Build from source
            </RouterLink>
          </li>
        </ul>
      </div>

      <div>
        <p class="font-mono text-[12px] uppercase tracking-widest text-ink-faint">Reach it from</p>
        <ul class="mt-3 space-y-2 text-[0.9375rem]">
          <li
            v-for="sdk in [
              { slug: 'swift', name: 'Swift' },
              { slug: 'kotlin', name: 'Kotlin' },
              { slug: 'typescript', name: 'TypeScript' },
              { slug: 'c', name: 'C' },
            ]"
            :key="sdk.slug"
          >
            <RouterLink
              class="text-ink-muted transition-colors hover:text-ink"
              :to="`/docs/sdk/${sdk.slug}`"
            >
              {{ sdk.name }}
            </RouterLink>
          </li>
        </ul>
      </div>

      <div>
        <p class="font-mono text-[12px] uppercase tracking-widest text-ink-faint">Project</p>
        <ul class="mt-3 space-y-2 text-[0.9375rem]">
          <li>
            <a
              class="text-ink-muted transition-colors hover:text-ink"
              href="https://github.com/myzonerocks/gosslens"
              rel="noreferrer"
            >
              Source
            </a>
          </li>
          <li>
            <a
              class="text-ink-muted transition-colors hover:text-ink"
              href="https://github.com/myzonerocks/gosslens/releases"
              rel="noreferrer"
            >
              Releases
            </a>
          </li>
          <li>
            <RouterLink class="text-ink-muted transition-colors hover:text-ink" to="/docs/agents">
              For agents
            </RouterLink>
          </li>
        </ul>
      </div>
    </div>
  </footer>
</template>
