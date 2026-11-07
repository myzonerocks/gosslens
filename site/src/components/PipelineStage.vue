<script setup lang="ts">
import { useIntervalFn, usePreferredReducedMotion } from '@vueuse/core'
import { computed, ref } from 'vue'

/** What the engine does to a frame, in the order it does it. */
const stages = [
  { key: 'capture', label: 'frame', detail: 'a platform texture, never a copy' },
  { key: 'track', label: 'perceive', detail: 'faces, hands, planes, text, depth' },
  { key: 'lens', label: 'compose', detail: 'the active lens draws' },
  { key: 'present', label: 'present', detail: 'back to the surface it came from' },
] as const

const active = ref(0)
const motion = usePreferredReducedMotion()
const still = computed(() => motion.value === 'reduce')

// The loop is the illustration. A reader who asked for less motion gets the
// whole pipeline at rest, with nothing moving on its own.
useIntervalFn(() => {
  if (!still.value) active.value = (active.value + 1) % stages.length
}, 2000)
</script>

<template>
  <ol class="rail" aria-label="The frame pipeline">
    <li v-for="(stage, index) in stages" :key="stage.key" class="rail__stage">
      <div class="rail__track" aria-hidden="true">
        <span class="rail__line" :class="index === 0 ? 'rail__line--first' : ''" />
        <span class="rail__dot" :class="!still && index === active ? 'rail__dot--live' : ''" />
        <span
          v-if="index < stages.length - 1"
          class="rail__line rail__line--after"
          :class="!still && index < active ? 'rail__line--passed' : ''"
        />
      </div>
      <p class="mt-4 font-mono text-[12px] tracking-widest text-ink-faint">
        {{ String(index + 1).padStart(2, '0') }}
      </p>
      <p class="mt-1 text-[1.125rem] font-semibold tracking-tight">{{ stage.label }}</p>
      <p class="mt-1.5 text-[0.9375rem] leading-relaxed text-ink-muted">{{ stage.detail }}</p>
    </li>
  </ol>
</template>

<style scoped>
.rail {
  display: grid;
  gap: 2rem 1.5rem;
  grid-template-columns: 1fr;
}

@media (min-width: 640px) {
  .rail {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

@media (min-width: 1024px) {
  .rail {
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 0 1.5rem;
  }
}

.rail__track {
  position: relative;
  display: flex;
  align-items: center;
  height: 9px;
}

.rail__line {
  flex: 1;
  height: 1px;
  background: var(--color-edge);
}

.rail__line--first {
  flex: 0 0 0;
}

.rail__line--after {
  background: linear-gradient(90deg, var(--color-edge), var(--color-edge));
}

/* A stage the frame has already left keeps the brand in its line. */
.rail__line--passed {
  background: linear-gradient(
    90deg,
    color-mix(in oklab, var(--color-iris) 70%, transparent),
    var(--color-edge)
  );
}

.rail__dot {
  position: relative;
  width: 9px;
  height: 9px;
  flex: 0 0 9px;
  border-radius: 999px;
  background: var(--color-edge);
  transition: background 400ms var(--ease-liquid);
}

.rail__dot--live {
  background: var(--color-iris);
}

.rail__dot--live::after {
  content: "";
  position: absolute;
  inset: -4px;
  border-radius: inherit;
  border: 1px solid var(--color-iris);
  animation: rail-ping 2s var(--ease-liquid) infinite;
}

@keyframes rail-ping {
  0% {
    opacity: 0.85;
    transform: scale(0.85);
  }
  70%,
  100% {
    opacity: 0;
    transform: scale(1.9);
  }
}
</style>
