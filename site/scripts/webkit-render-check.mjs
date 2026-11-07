import { webkit } from '@playwright/test'
const b = await webkit.launch()
const problems = []
for (const [w, h, name] of [[1440, 900, 'desktop'], [834, 1112, 'tablet'], [390, 844, 'mobile']]) {
  const ctx = await b.newContext({ viewport: { width: w, height: h } })
  const p = await ctx.newPage()
  p.on('pageerror', (e) => problems.push(`${name}: ${e.message}`))
  p.on('console', (m) => { if (m.type() === 'error') problems.push(`${name}: ${m.text()}`) })

  for (const path of ['/', '/docs', '/docs/build/models', '/docs/binding/writing-an-sdk']) {
    await p.goto(`http://localhost:5180${path}`, { waitUntil: 'networkidle' })
    const h1 = await p.locator('h1').first().innerText().catch(() => '')
    if (!h1) problems.push(`${name} ${path}: no heading`)
    const overflow = await p.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)
    if (overflow) problems.push(`${name} ${path}: scrolls sideways`)
    const theme = await p.evaluate(() => document.documentElement.getAttribute('data-theme'))
    if (theme !== 'dark') problems.push(`${name} ${path}: theme is ${theme}`)
  }
  await ctx.close()
}
console.log(problems.length ? problems.slice(0, 8).join('\n') : 'webkit renders every page at every width, dark, no sideways scroll')
await b.close()
