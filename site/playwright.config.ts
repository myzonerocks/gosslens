import { defineConfig, devices } from '@playwright/test'

const PORT = 4178
const SITE_BASE = process.env.SITE_BASE ?? '/gosslens/'
const BASE = `http://127.0.0.1:${PORT}${SITE_BASE}`

/** Three widths, each styled on purpose, in all three engines. */
const widths = [
  { name: 'desktop', viewport: { width: 1440, height: 900 } },
  { name: 'tablet', viewport: { width: 834, height: 1112 } },
  { name: 'mobile', viewport: { width: 390, height: 844 } },
]

const engines = [
  { name: 'chromium', use: devices['Desktop Chrome'] },
  { name: 'firefox', use: devices['Desktop Firefox'] },
  { name: 'webkit', use: devices['Desktop Safari'] },
]

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
  projects: engines.flatMap((engine) =>
    widths.map((width) => ({
      name: `${engine.name}-${width.name}`,
      use: { ...engine.use, viewport: width.viewport },
    })),
  ),
  webServer: {
    command: `bun run preview --port ${PORT} --strictPort --host 127.0.0.1`,
    url: BASE,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
})
