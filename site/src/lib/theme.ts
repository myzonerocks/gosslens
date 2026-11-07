import { ref, watchEffect } from 'vue'

export type ThemeChoice = 'system' | 'light' | 'dark'

const STORAGE_KEY = 'gosslens:theme'
const ORDER: readonly ThemeChoice[] = ['system', 'light', 'dark']

function stored(): ThemeChoice {
  try {
    const saved = localStorage.getItem(STORAGE_KEY)
    return saved === 'light' || saved === 'dark' ? saved : 'system'
  } catch {
    return 'system'
  }
}

/** The reader's own setting wins; otherwise the system decides. */
export const theme = ref<ThemeChoice>(stored())

/** What is actually on screen, which `system` alone cannot tell you. */
export const resolved = ref<'light' | 'dark'>('dark')

const night = window.matchMedia('(prefers-color-scheme: dark)')

function apply(choice: ThemeChoice): void {
  const root = document.documentElement
  if (choice === 'system') root.removeAttribute('data-theme')
  else root.setAttribute('data-theme', choice)

  resolved.value = choice === 'system' ? (night.matches ? 'dark' : 'light') : choice
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute('content', resolved.value === 'dark' ? '#0b0a11' : '#f6f6fa')
}

night.addEventListener('change', () => {
  if (theme.value === 'system') apply('system')
})

watchEffect(() => {
  apply(theme.value)
  try {
    if (theme.value === 'system') localStorage.removeItem(STORAGE_KEY)
    else localStorage.setItem(STORAGE_KEY, theme.value)
  } catch {
    // A browser that refuses storage still gets the right page, just no memory.
  }
})

/** One control, three states, in the order a reader expects. */
export function cycleTheme(): void {
  const next = ORDER[(ORDER.indexOf(theme.value) + 1) % ORDER.length]
  if (next) theme.value = next
}
