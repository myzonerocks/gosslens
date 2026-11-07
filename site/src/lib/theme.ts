import { ref, watchEffect } from 'vue'

export type ThemeChoice = 'dark' | 'light'

const STORAGE_KEY = 'gosslens:theme'

function stored(): ThemeChoice {
  try {
    return localStorage.getItem(STORAGE_KEY) === 'light' ? 'light' : 'dark'
  } catch {
    return 'dark'
  }
}

/** Dark unless a reader has said otherwise, on every screen. */
export const theme = ref<ThemeChoice>(stored())

watchEffect(() => {
  document.documentElement.setAttribute('data-theme', theme.value)
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute('content', theme.value === 'light' ? '#f6f6fa' : '#0b0a11')
  try {
    localStorage.setItem(STORAGE_KEY, theme.value)
  } catch {
    // A browser that refuses storage still gets the right page, just not the memory.
  }
})

export function cycleTheme(): void {
  theme.value = theme.value === 'dark' ? 'light' : 'dark'
}
