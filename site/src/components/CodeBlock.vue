<script setup lang="ts">
import { onMounted, ref, useTemplateRef } from 'vue'
import CopyButton from '@/components/CopyButton.vue'

defineOptions({ inheritAttrs: false })

const block = useTemplateRef<HTMLPreElement>('block')
const text = ref('')

// Highlighted markup arrives as markup, so the plain text is read back off it.
onMounted(() => {
  text.value = block.value?.innerText.replace(/\n$/, '') ?? ''
})
</script>

<template>
  <div class="doc-code group/code relative">
    <pre ref="block" v-bind="$attrs"><slot /></pre>
    <div
      class="absolute right-3 top-3 opacity-0 transition-opacity group-hover/code:opacity-100 focus-within:opacity-100"
    >
      <CopyButton :text="text" label="Copy this code" />
    </div>
  </div>
</template>
