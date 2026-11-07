<script setup lang="ts">
import CodeTabs from '@/components/CodeTabs.vue'
import PipelineStage from '@/components/PipelineStage.vue'
import RecordPanel from '@/components/RecordPanel.vue'
import Viewfinder from '@/components/Viewfinder.vue'

const sdks = [
  {
    name: 'Swift',
    path: '/docs/sdk/swift',
    line: 'AVFoundation in, Metal out, async/await at the surface.',
  },
  {
    name: 'Kotlin',
    path: '/docs/sdk/kotlin',
    line: 'CameraX in, coroutines and Flow at the surface.',
  },
  {
    name: 'TypeScript',
    path: '/docs/sdk/typescript',
    line: 'The same core as wasm, WebGL2 or WebGPU behind it.',
  },
  { name: 'C', path: '/docs/sdk/c', line: 'The boundary itself, with nothing on top of it.' },
]

const guarantees = [
  {
    head: 'One core',
    line: 'Scheduling, pools, triggers, colour policy and the degradation ladder live in Zig. An SDK that implements a feature of its own is a defect.',
  },
  {
    head: 'One frozen ABI',
    line: 'A versioned C boundary. Structs are extern with explicit padding, and a field is added only at the end of a struct behind a size field.',
  },
  {
    head: 'Nothing leaves the device',
    line: 'There is no network path in the core. A frame cannot be uploaded by a part of the engine you did not call.',
  },
]
</script>

<template>
  <!-- The hero is the product: a frame goes in on the left, and the record the
       engine made of it comes out on the right. -->
  <section class="relative overflow-hidden border-b border-edge">
    <div class="home-glow" aria-hidden="true" />
    <div class="relative mx-auto max-w-6xl px-6 pb-16 pt-20 lg:pt-28">
      <div class="mx-auto max-w-3xl text-center">
        <h1
          class="text-balance text-[2.1rem] font-bold leading-[1.07] tracking-tight sm:text-[2.9rem] lg:text-[3.4rem]"
        >
          A real-time vision engine for camera apps
        </h1>
        <p class="mx-auto mt-5 max-w-2xl text-balance text-[1.0625rem] leading-relaxed text-ink-muted sm:text-[1.1875rem]">
          gosslens reads every camera frame and tells your app what's in it: faces, hands,
          planes, depth, text. Then you draw straight back onto the frame. It all runs on
          the device, and your iOS, Android and web apps use the same engine.
        </p>

        <div class="mt-9 flex flex-col items-center gap-3 sm:flex-row sm:justify-center">
          <RouterLink to="/docs/start/quickstart" class="btn btn-primary">Get started</RouterLink>
          <RouterLink to="/docs/install/sdks" class="btn btn-quiet">Add an SDK</RouterLink>
        </div>
      </div>

      <div
        class="mt-14 grid items-stretch gap-4 lg:h-[27rem] lg:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)] lg:gap-5"
      >
        <Viewfinder class="max-h-[20rem] lg:max-h-none" />
        <div class="lit max-h-[22rem] overflow-hidden rounded-card lg:max-h-none">
          <RecordPanel />
        </div>
      </div>

      <dl
        class="mx-auto mt-12 grid max-w-3xl grid-cols-2 gap-6 border-t border-edge pt-6 sm:grid-cols-4"
      >
        <div>
          <dt class="font-mono text-[12px] uppercase tracking-widest text-ink-faint">Core</dt>
          <dd class="mt-1 text-[0.9375rem] font-semibold">Zig</dd>
        </div>
        <div>
          <dt class="font-mono text-[12px] uppercase tracking-widest text-ink-faint">Frames</dt>
          <dd class="mt-1 text-[0.9375rem] font-semibold">zero-copy</dd>
        </div>
        <div>
          <dt class="font-mono text-[12px] uppercase tracking-widest text-ink-faint">Budget</dt>
          <dd class="mt-1 text-[0.9375rem] font-semibold">per frame</dd>
        </div>
        <div>
          <dt class="font-mono text-[12px] uppercase tracking-widest text-ink-faint">Runs</dt>
          <dd class="mt-1 text-[0.9375rem] font-semibold">on device</dd>
        </div>
      </dl>
    </div>
  </section>

  <section class="border-b border-edge">
    <div class="mx-auto grid max-w-7xl gap-px bg-edge px-0 sm:grid-cols-3">
      <div v-for="item in guarantees" :key="item.head" class="bg-ground px-6 py-8 lg:px-8 lg:py-10">
        <h2 class="text-[1.0625rem] font-semibold">{{ item.head }}</h2>
        <p class="mt-2 text-[0.9375rem] leading-relaxed text-ink-muted">{{ item.line }}</p>
      </div>
    </div>
  </section>

  <section class="border-b border-edge">
    <div class="mx-auto max-w-7xl px-6 py-14 lg:py-20">
      <div class="grid gap-10 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)] lg:gap-16">
        <div>
          <p class="font-mono text-[12px] uppercase tracking-[0.2em] text-ink-faint">
            One program, four languages
          </p>
          <h2 class="mt-3 text-[1.75rem] font-bold tracking-tight sm:text-3xl">
            The same code everywhere
          </h2>
          <p class="mt-4 max-w-md text-[1.0625rem] leading-relaxed text-ink-muted">
            Open an engine, make a session, activate a lens, read the record. The names change with
            the language and nothing else does, because every SDK is a thin skin over the same C
            calls.
          </p>
          <RouterLink
            to="/docs/concepts/abi"
            class="mt-6 inline-flex items-center gap-1.5 text-[1rem] font-semibold text-link"
          >
            How the ABI works
            <span aria-hidden="true">&rarr;</span>
          </RouterLink>
        </div>
        <CodeTabs />
      </div>
    </div>
  </section>

  <section class="border-b border-edge">
    <div class="mx-auto max-w-7xl px-6 py-14 lg:py-20">
      <p class="font-mono text-[12px] uppercase tracking-[0.2em] text-ink-faint">
        The pipeline
      </p>
      <h2 class="mt-3 max-w-2xl text-[1.75rem] font-bold leading-tight tracking-tight sm:text-3xl">
        What happens to a frame
      </h2>
      <PipelineStage class="mt-12" />
    </div>
  </section>

  <section class="border-b border-edge">
    <div class="mx-auto max-w-7xl px-6 py-14 lg:py-20">
      <p class="font-mono text-[12px] uppercase tracking-[0.2em] text-ink-faint">Reach it from</p>
      <div class="mt-8 grid gap-px bg-edge sm:grid-cols-2 lg:grid-cols-4">
        <RouterLink
          v-for="sdk in sdks"
          :key="sdk.name"
          :to="sdk.path"
          class="group bg-ground p-6 transition-colors hover:bg-surface"
        >
          <span class="flex items-center justify-between text-[1.0625rem] font-semibold">
            {{ sdk.name }}
            <span
              class="text-ink-faint transition-transform group-hover:translate-x-0.5 group-hover:text-iris"
              aria-hidden="true"
            >
              &rarr;
            </span>
          </span>
          <span class="mt-2 block text-[0.9375rem] leading-relaxed text-ink-muted">{{ sdk.line }}</span>
        </RouterLink>
      </div>
    </div>
  </section>

  <section>
    <div class="mx-auto max-w-7xl px-6 py-16 lg:py-20">
      <div class="lit flex flex-col gap-6 rounded-card p-8 lg:flex-row lg:items-center lg:p-10">
        <div class="max-w-xl">
          <h2 class="text-[1.5rem] font-bold tracking-tight">Not one of those four languages?</h2>
          <p class="mt-3 text-[1.0625rem] leading-relaxed text-ink-muted">
            The header is plain C99, and the rules are short: check the version, read the
            capability bits, keep to one thread, generate your structs from the header.
            Most of a binding is an afternoon's work, and there's a test suite you can run
            to check yours agrees with the ones we ship.
          </p>
        </div>
        <RouterLink
          to="/docs/binding/writing-an-sdk"
          class="btn btn-quiet shrink-0 lg:ml-auto"
        >
          Write your own SDK
        </RouterLink>
      </div>
    </div>
  </section>
</template>

<style scoped>
/* One light above the hero, strongest at the top edge and gone by the fold. */
.home-glow {
  position: absolute;
  inset: -40% 0 auto 0;
  height: 620px;
  background: radial-gradient(
    60% 50% at 50% 50%,
    color-mix(in oklab, var(--color-iris) calc(var(--glow) * 100%), transparent),
    transparent 70%
  );
  pointer-events: none;
}
</style>