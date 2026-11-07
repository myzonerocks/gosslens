<script setup lang="ts">
withDefaults(defineProps<{ size?: number }>(), { size: 26 })
</script>

<template>
  <!-- A focus reticle around a lens: what the engine does, at any size. The
       brackets take the text colour, so the mark belongs to whatever it sits on. -->
  <svg
    :width="size"
    :height="size"
    viewBox="0 0 32 32"
    fill="none"
    class="shrink-0"
    aria-hidden="true"
  >
    <g
      stroke="currentColor"
      stroke-width="2.4"
      stroke-linecap="round"
      stroke-linejoin="round"
      opacity="0.92"
    >
      <path d="M4 10.8V6.8A2.8 2.8 0 0 1 6.8 4h4" />
      <path d="M21.2 4h4A2.8 2.8 0 0 1 28 6.8v4" />
      <path d="M28 21.2v4a2.8 2.8 0 0 1-2.8 2.8h-4" />
      <path d="M10.8 28h-4A2.8 2.8 0 0 1 4 25.2v-4" />
    </g>
    <circle cx="16" cy="16" r="5.4" fill="var(--color-iris)" />
    <circle cx="14.1" cy="14.1" r="1.5" fill="var(--color-ground)" opacity="0.55" />
  </svg>
</template>
