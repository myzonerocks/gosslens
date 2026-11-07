import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'

const routes: RouteRecordRaw[] = [
  { path: '/', name: 'home', component: () => import('@/pages/HomePage.vue') },
  {
    path: '/docs/:path(.*)*',
    name: 'docs',
    component: () => import('@/pages/DocsPage.vue'),
  },
  { path: '/:path(.*)*', name: 'not-found', component: () => import('@/pages/NotFoundPage.vue') },
]

export const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes,
  // A reader following a heading link lands on the heading; a reader opening a
  // page lands at its top; the back button returns them where they were.
  scrollBehavior(to, _from, saved) {
    if (saved) return saved
    if (to.hash) return { el: to.hash, top: 96, behavior: 'smooth' }
    return { top: 0 }
  },
})
