<script setup lang="ts">
import { usePreferredReducedMotion } from '@vueuse/core'
import { computed } from 'vue'

const motion = usePreferredReducedMotion()
const still = computed(() => motion.value === 'reduce')
</script>

<template>
  <!-- What the engine sees, drawn the way it reports it: boxes, landmarks and a
       confidence, over a frame it never copies. -->
  <figure class="viewfinder" :class="still ? 'viewfinder--still' : ''" aria-labelledby="vf-caption">
    <svg
      viewBox="0 0 640 400"
      preserveAspectRatio="xMidYMid slice"
      class="block size-full"
      role="img"
      aria-labelledby="vf-title"
    >
      <title id="vf-title">A camera frame with detected faces, hands and a plane marked on it</title>
      <defs>
        <linearGradient id="vf-sky" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="var(--vf-sky-top)" />
          <stop offset="100%" stop-color="var(--vf-sky-bottom)" />
        </linearGradient>
        <linearGradient id="vf-sweep" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0%" stop-color="var(--color-iris)" stop-opacity="0" />
          <stop offset="50%" stop-color="var(--color-iris-bright)" stop-opacity="0.85" />
          <stop offset="100%" stop-color="var(--color-iris)" stop-opacity="0" />
        </linearGradient>
        <radialGradient id="vf-subject-fill" cx="0.4" cy="0.3" r="0.9">
          <stop offset="0%" stop-color="var(--vf-subject-hot)" />
          <stop offset="100%" stop-color="var(--vf-subject)" />
        </radialGradient>
        <linearGradient id="vf-floor" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="var(--vf-plane)" />
          <stop offset="100%" stop-color="transparent" />
        </linearGradient>
        <radialGradient id="vf-vignette" cx="0.5" cy="0.45" r="0.75">
          <stop offset="55%" stop-color="transparent" />
          <stop offset="100%" stop-color="var(--vf-vignette)" />
        </radialGradient>
        <clipPath id="vf-clip">
          <rect x="0" y="0" width="640" height="400" rx="14" />
        </clipPath>
      </defs>

      <g clip-path="url(#vf-clip)">
        <rect width="640" height="400" fill="url(#vf-sky)" />

        <!-- The scene, abstract on purpose: geometry is what a detector sees. -->
        <g class="vf-scene">
          <path d="M0 262 L236 196 L640 246 L640 400 L0 400 Z" fill="url(#vf-floor)" />
          <path d="M0 262 L236 196 L640 246" fill="none" stroke="var(--vf-edge)" stroke-width="1.25" />
          <g stroke="var(--vf-edge)" stroke-width="0.6" opacity="0.5">
            <path d="M-40 400 L190 196" />
            <path d="M150 400 L252 198" />
            <path d="M360 400 L372 206" />
            <path d="M560 400 L486 216" />
            <path d="M0 316 L640 330" />
            <path d="M0 368 L640 374" />
          </g>

          <g fill="url(#vf-subject-fill)">
            <circle cx="214" cy="124" r="40" />
            <path d="M152 244 q10 -62 62 -62 q52 0 62 62 l0 38 l-124 0 Z" />
          </g>
          <path
            d="M414 198 q36 -32 64 -8 q28 24 6 52 q-24 32 -54 10 Z"
            fill="var(--vf-subject-2)"
          />

          <rect width="640" height="400" fill="url(#vf-vignette)" />
        </g>

        <!-- Everything below here is the perception record, drawn back. -->
        <g class="vf-marks">
          <g class="vf-box">
            <rect x="160" y="68" width="110" height="122" rx="3" />
            <g class="vf-corner">
              <path
                d="M160 84 V71 h13 M257 71 h13 v13 M270 174 v13 h-13 M173 187 h-13 v-13"
              />
            </g>
          </g>
          <g class="vf-chip">
            <rect x="160" y="42" width="92" height="19" rx="4" />
            <text x="169" y="55" class="vf-label">face · 0.98</text>
          </g>

          <g class="vf-box vf-box--second">
            <rect x="404" y="180" width="94" height="90" rx="3" />
            <g class="vf-corner vf-corner--second">
              <path
                d="M404 194 V183 h11 M487 183 h11 v11 M498 256 v11 h-11 M415 267 h-11 v-11"
              />
            </g>
          </g>
          <g class="vf-chip vf-chip--second">
            <rect x="404" y="154" width="94" height="19" rx="4" />
            <text x="413" y="167" class="vf-label">hand · 0.91</text>
          </g>

          <g class="vf-landmarks">
            <path d="M420 240 L440 216 L458 202 L476 208 L488 228" fill="none" />
            <circle cx="420" cy="240" r="3.2" />
            <circle cx="440" cy="216" r="3.2" />
            <circle cx="458" cy="202" r="3.2" />
            <circle cx="476" cy="208" r="3.2" />
            <circle cx="488" cy="228" r="3.2" />
          </g>

          <g class="vf-plane-mark">
            <path d="M236 196 L640 246" />
            <g class="vf-chip vf-chip--plane">
              <rect x="300" y="214" width="52" height="18" rx="4" />
              <text x="309" y="226.5" class="vf-label">plane</text>
            </g>
          </g>
        </g>

        <rect class="vf-sweep" x="-220" y="0" width="220" height="400" fill="url(#vf-sweep)" />
        <rect
          x="0.5"
          y="0.5"
          width="639"
          height="399"
          rx="14"
          fill="none"
          stroke="rgb(255 255 255 / 0.14)"
        />
      </g>
    </svg>

    <figcaption id="vf-caption" class="sr-only">
      A frame arrives as a platform texture, the core reports what is in it, and the overlay is
      composited back onto the same surface.
    </figcaption>
  </figure>
</template>

<style scoped>
/* A frame is a photograph, not chrome: it keeps its own light in both themes,
   the way a viewfinder does. Only the marks drawn over it belong to the UI. */
.viewfinder {
  --vf-sky-top: #221f36;
  --vf-sky-bottom: #0d0b14;
  --vf-plane: rgb(124 108 240 / 0.22);
  --vf-edge: rgb(226 224 240 / 0.26);
  --vf-subject: rgb(226 224 240 / 0.12);
  --vf-subject-hot: rgb(226 224 240 / 0.3);
  --vf-subject-2: rgb(226 224 240 / 0.1);
  --vf-vignette: rgb(8 7 14 / 0.75);
  --vf-ink: #eceaf6;
  --vf-chip: rgb(10 9 16 / 0.72);

  position: relative;
  overflow: hidden;
  height: 100%;
  min-height: 15rem;
  border-radius: calc(var(--radius-card) + 2px);
  box-shadow:
    0 0 0 1px color-mix(in oklab, var(--color-edge) 90%, transparent),
    0 24px 60px -32px rgb(14 10 40 / 0.55);
}

.vf-box rect {
  fill: none;
  stroke: var(--color-iris-bright);
  stroke-width: 1.5;
  stroke-dasharray: 5 4;
  animation: vf-trace 9s linear infinite;
}

.vf-corner path {
  fill: none;
  stroke: var(--color-iris-bright);
  stroke-width: 2.5;
  stroke-linecap: square;
}

.vf-corner--second path {
  stroke: var(--color-lime);
}

.vf-box--second rect {
  stroke: var(--color-lime);
  animation-delay: -3s;
}

.vf-chip rect {
  fill: var(--vf-chip);
  stroke: color-mix(in oklab, var(--color-iris-bright) 45%, transparent);
  stroke-width: 0.75;
}

.vf-chip--second rect {
  stroke: color-mix(in oklab, var(--color-lime) 50%, transparent);
}

.vf-chip--plane rect {
  stroke: color-mix(in oklab, var(--color-iris) 45%, transparent);
}

.vf-label {
  fill: var(--vf-ink);
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: 0.04em;
}

.vf-landmarks circle {
  fill: var(--color-lime);
}

.vf-landmarks path {
  stroke: var(--color-lime);
  stroke-width: 1.25;
  opacity: 0.7;
}

.vf-plane-mark path {
  stroke: var(--color-iris);
  stroke-width: 1.25;
  stroke-dasharray: 2 6;
  opacity: 0.8;
}

/* One pass of the sensor, slow enough to read as measurement, not decoration. */
.vf-sweep {
  animation: vf-pass 7s cubic-bezier(0.37, 0, 0.63, 1) infinite;
  opacity: 0.5;
}

@keyframes vf-pass {
  0% {
    transform: translateX(0);
  }
  65%,
  100% {
    transform: translateX(860px);
  }
}

@keyframes vf-trace {
  to {
    stroke-dashoffset: -36;
  }
}

.viewfinder--still .vf-sweep {
  display: none;
}

.viewfinder--still .vf-box rect {
  animation: none;
}
</style>
