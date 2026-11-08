import { defineConfig, devices } from '@playwright/test'

const PORT = 4178
const SITE_BASE = process.env.SITE_BASE ?? '/gosslens/'
const BASE = `http://127.0.0.1:${PORT}${SITE_BASE}`

/**
 * The same three widths the web project holds itself to, with its own touch and
 * scale settings. Without isMobile a browser never applies the viewport meta,
 * so a page that a real phone shrinks to fit still passes.
 */
const WIDTHS = [
  { name: 'desktop', viewport: undefined, touch: false, scale: 1 },
  { name: 'tablet', viewport: { width: 834, height: 1112 }, touch: true, scale: 2 },
  { name: 'mobile', viewport: { width: 390, height: 844 }, touch: true, scale: 3 },
] as const

const ENGINES = [
  { name: 'chromium', device: devices['Desktop Chrome'], canEmulateMobile: true },
  // Firefox cannot emulate a mobile pointer in Playwright, so it carries touch alone.
  { name: 'firefox', device: devices['Desktop Firefox'], canEmulateMobile: false },
  { name: 'webkit', device: devices['Desktop Safari'], canEmulateMobile: true },
] as const

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  // This machine has 8 GB and webkit is the heaviest of the three. Left
  // unbounded the suite swaps, and the failures read as flaky clicks.
  workers: process.env.CI ? undefined : 4,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['github'], ['list']] : [['list']],
  use: { baseURL: BASE, trace: 'on-first-retry' },
  projects: ENGINES.flatMap((engine) =>
    WIDTHS.map((width) => ({
      name: `${engine.name}-${width.name}`,
      use: {
        ...engine.device,
        ...(width.viewport ? { viewport: width.viewport } : {}),
        ...(width.touch ? { hasTouch: true } : {}),
        ...(width.touch && engine.canEmulateMobile
          ? { isMobile: true, deviceScaleFactor: width.scale }
          : {}),
      },
    })),
  ),
  webServer: {
    command: `bun run preview --port ${PORT} --strictPort --host 127.0.0.1`,
    url: BASE,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
})
