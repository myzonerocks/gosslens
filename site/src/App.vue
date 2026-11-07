<script setup lang="ts">
import SiteFooter from '@/components/SiteFooter.vue'
import SiteNav from '@/components/SiteNav.vue'
</script>

<template>
  <a
    href="#content"
    class="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:rounded-lg focus:bg-iris focus:px-4 focus:py-2 focus:text-white"
  >
    Skip to content
  </a>
  <SiteNav />
  <main id="content">
    <RouterView v-slot="{ Component }">
      <Suspense>
        <div>
          <component :is="Component" />
        </div>
        <template #fallback>
          <div class="mx-auto h-[60vh] max-w-5xl px-6" />
        </template>
      </Suspense>
    </RouterView>
  </main>
  <SiteFooter />
</template>
