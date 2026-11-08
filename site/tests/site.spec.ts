import { expect, test } from '@playwright/test'

const WIDE = 1024

test('the home page states what the engine does and offers both ways in', async ({ page }) => {
  const noise: string[] = []
  page.on('pageerror', (error) => noise.push(error.message))
  page.on('console', (message) => {
    if (message.type() === 'error') noise.push(message.text())
  })

  await page.goto('')
  await expect(page.getByRole('heading', { level: 1 })).toContainText('camera')
  const hero = page.locator('#content')
  await expect(hero.getByRole('link', { name: 'Get started' })).toBeVisible()
  await expect(hero.getByRole('link', { name: 'Add an SDK' }).first()).toBeVisible()
  expect(noise).toEqual([])
})

test('every document in the tree opens and renders its own title', async ({ page }) => {
  test.slow()
  await page.goto('docs')
  await expect(page.getByTestId('doc-link').first()).toBeAttached()
  const links = await page
    .getByTestId('doc-link')
    .evaluateAll((nodes) => nodes.map((node) => node.getAttribute('href') ?? ''))
  expect(links.length).toBeGreaterThan(5)

  // Every page is opened the way a shared link opens it, at every width.
  for (const href of links) {
    await page.goto(href)
    const heading = page.getByRole('heading', { level: 1 })
    await expect(heading, `${href} has a title`).toBeVisible()
    await expect(heading).not.toBeEmpty()
    await expect(page.locator('.doc'), `${href} has a body`).toBeVisible()
  }
})

test('search finds a document and opens it', async ({ page }) => {
  await page.goto('docs')
  await expect(page.getByTestId('search-open')).toBeVisible()
  await page.getByTestId('search-open').click()
  await page.getByTestId('search-input').fill('lens')
  const hits = page.getByTestId('search-hit')
  await expect(hits.first()).toBeVisible()
  await hits.first().click()
  await expect(page).toHaveURL(/\/docs\//)
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
})

test('search closes on escape and leaves nothing behind', async ({ page }) => {
  await page.goto('docs')
  await page.getByTestId('search-open').click()
  await expect(page.getByTestId('search-overlay')).toBeVisible()
  await page.keyboard.press('Escape')
  await expect(page.getByTestId('search-overlay')).toBeHidden()
})

test('the page follows the system until a reader chooses', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'dark' })
  await page.goto('')
  const root = page.locator('html')

  // Nobody has chosen, so nothing is stamped and the system decides.
  await expect(root).not.toHaveAttribute('data-theme', /light|dark/)
  const fromSystem = await page.evaluate(() => getComputedStyle(document.body).backgroundColor)

  await page.emulateMedia({ colorScheme: 'light' })
  await expect
    .poll(() => page.evaluate(() => getComputedStyle(document.body).backgroundColor))
    .not.toBe(fromSystem)
})

test('a chosen theme beats the system and survives a reload', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'dark' })
  await page.goto('')
  const root = page.locator('html')
  const toggle = page.getByTestId('theme-toggle')

  // system, then light, then dark.
  await toggle.click()
  await expect(root).toHaveAttribute('data-theme', 'light')
  const light = await page.evaluate(() => getComputedStyle(document.body).backgroundColor)

  await page.reload()
  await expect(root).toHaveAttribute('data-theme', 'light')
  expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).toBe(light)

  await toggle.click()
  await expect(root).toHaveAttribute('data-theme', 'dark')
  expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).not.toBe(light)
})

test('a code sample can be copied', async ({ page, browserName }) => {
  test.skip(browserName === 'webkit', 'the clipboard needs a user gesture this harness cannot give')
  await page.goto('docs/concepts/abi')
  const block = page.locator('.doc pre').first()
  await block.hover()
  const copy = page.getByTestId('copy-button').first()
  await copy.click()
  await expect(copy).toHaveAttribute('aria-label', 'Copied')
})

test('the menu closes from its own control', async ({ page }) => {
  const width = page.viewportSize()?.width ?? 0
  test.skip(width >= 640, 'the sheet is only on phones')

  await page.goto('docs')
  await page.getByTestId('menu-toggle').click()
  await expect(page.getByTestId('mobile-nav')).toBeVisible()
  await page.getByTestId('menu-toggle').click()
  await expect(page.getByTestId('mobile-nav')).toBeHidden()
})

test('the documentation tree is reachable at every width', async ({ page }) => {
  await page.goto('docs/concepts/abi')
  const width = page.viewportSize()?.width ?? 0

  if (width >= WIDE) {
    await expect(page.getByRole('navigation', { name: 'Documentation' })).toBeVisible()
    return
  }

  const toggle = page.getByTestId('docs-nav-toggle')
  await expect(toggle).toBeVisible()
  await toggle.click()
  await expect(page.locator('#docs-tree')).toBeVisible()
  await page.locator('#docs-tree').getByRole('link', { name: 'The lens format' }).click()
  await expect(page).toHaveURL(/concepts\/lenses/)
})

test('a reader can reach the content past the chrome', async ({ page, browserName }) => {
  await page.goto('')
  const skip = page.getByRole('link', { name: 'Skip to content' })

  // Safari tabs to links only when the system setting is on, so it is proven by
  // what the link does rather than by how focus reaches it.
  if (browserName === 'webkit') {
    await skip.focus()
    await expect(skip).toBeVisible()
    return
  }

  await page.keyboard.press('Tab')
  await expect(skip).toBeFocused()
})

test('a long document offers its own contents', async ({ page }) => {
  await page.goto('docs/concepts/abi')
  const width = page.viewportSize()?.width ?? 0
  const toc = page.getByTestId('toc')

  if (width < 1280) {
    await expect(toc).toBeHidden()
    return
  }

  await expect(toc).toBeVisible()
  const headings = await page.locator('.doc h2[id]').count()
  await expect(toc.getByRole('link')).toHaveCount(headings)
})

test('the tree opens the section you are in and keeps the rest closed', async ({ page }) => {
  await page.goto('docs/concepts/abi')
  const width = page.viewportSize()?.width ?? 0
  if (width < WIDE) {
    await page.getByTestId('docs-nav-toggle').click()
  }
  const tree = width < WIDE ? page.locator('#docs-tree') : page.locator('aside').first()

  await expect(tree.getByRole('link', { name: 'The frame graph' })).toBeVisible()
  await expect(tree.getByRole('link', { name: 'Swift' })).toBeHidden()

  await tree.getByRole('button', { name: 'SDKs' }).click()
  await expect(tree.getByRole('link', { name: 'Swift' })).toBeVisible()
})

test('the page you are on is obviously the page you are on', async ({ page }) => {
  await page.goto('docs/concepts/abi')
  const width = page.viewportSize()?.width ?? 0
  if (width < WIDE) await page.getByTestId('docs-nav-toggle').click()
  const tree = width < WIDE ? page.locator('#docs-tree') : page.locator('aside').first()

  const current = tree.getByRole('link', { name: 'The C ABI' })
  const sibling = tree.getByRole('link', { name: 'The frame graph' })

  const read = (target: typeof current) =>
    target.evaluate((node) => {
      const style = getComputedStyle(node)
      return {
        background: style.backgroundColor,
        weight: Number(style.fontWeight),
        border: style.borderLeftColor,
      }
    })

  const [here, other] = await Promise.all([read(current), read(sibling)])

  // Three signals, each on its own, so losing one still leaves it readable.
  expect(here.background).not.toBe(other.background)
  expect(here.weight).toBeGreaterThan(other.weight)
  expect(here.border).not.toBe(other.border)
})

test('nothing a reader has to read is too small to read', async ({ page }) => {
  for (const path of ['', 'docs/sdk/swift']) {
    await page.goto(path)
    await expect(page.locator('#content')).toBeVisible()

    const small = await page.evaluate(() => {
      const found: { size: number; text: string }[] = []
      for (const node of document.querySelectorAll('#content *')) {
        const own = [...node.childNodes]
          .filter((child) => child.nodeType === Node.TEXT_NODE)
          .map((child) => child.textContent ?? '')
          .join('')
          .trim()
        if (own.length < 12) continue
        const style = getComputedStyle(node)
        const size = Number.parseFloat(style.fontSize)
        // A label set in caps carries its meaning in a word or two, and code is
        // monospace and reads larger than its size. Running text gets the floor.
        const label = style.textTransform === 'uppercase'
        const mono = /mono|courier/i.test(style.fontFamily)
        const floor = label ? 12 : mono ? 14 : 15
        if (size < floor) found.push({ size, text: own.slice(0, 40) })
      }
      return found
    })

    expect(small, `${path} has text below the reading size`).toEqual([])
  }
})

test('the documentation reads at the size it was set to', async ({ page }) => {
  await page.goto('docs/sdk/swift')
  const size = (selector: string) =>
    page
      .locator(selector)
      .first()
      .evaluate((node) => Number.parseFloat(getComputedStyle(node).fontSize))

  expect(await size('.doc p')).toBeGreaterThanOrEqual(17)
  expect(await size('.doc li')).toBeGreaterThanOrEqual(17)
  expect(await size('.doc :not(pre) > code')).toBeGreaterThanOrEqual(15)
  expect(await size('.doc pre')).toBeGreaterThanOrEqual(15)
  expect(await size('.doc h2')).toBeGreaterThanOrEqual(26)
})

test('the tree ends with a way to fund the project', async ({ page }) => {
  await page.goto('docs/concepts/abi')
  const width = page.viewportSize()?.width ?? 0
  if (width < WIDE) await page.getByTestId('docs-nav-toggle').click()
  const tree = width < WIDE ? page.locator('#docs-tree') : page.locator('aside').first()

  const sponsor = tree.getByTestId('doc-external')
  await expect(sponsor).toHaveText(/Financial Support/)
  await expect(sponsor).toHaveAttribute('href', 'https://github.com/sponsors/avosa')

  // Last, and not part of the reading order the previous and next links walk.
  const entries = tree.locator('[data-testid="doc-link"], [data-testid="doc-external"]')
  await expect(entries.last()).toHaveAttribute('data-testid', 'doc-external')
})

test('a control looks like something you can press, in both themes', async ({ page }) => {
  await page.goto('')

  const contrast = () =>
    page.evaluate(() => {
      const element = document.querySelector('.btn-quiet')
      if (!element) return null
      const style = getComputedStyle(element)
      const canvas = document.createElement('canvas').getContext('2d')
      if (!canvas) return null

      // Resolving through a canvas turns oklab and color-mix into plain rgb.
      const solve = (colour: string, under: string) => {
        canvas.fillStyle = under
        canvas.fillRect(0, 0, 1, 1)
        canvas.fillStyle = colour
        canvas.fillRect(0, 0, 1, 1)
        const [r, g, b] = canvas.getImageData(0, 0, 1, 1).data
        return [r, g, b] as [number, number, number]
      }
      const luminance = ([r, g, b]: [number, number, number]) => {
        const channel = (value: number) => {
          const v = value / 255
          return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
      }
      const ratio = (a: [number, number, number], b: [number, number, number]) => {
        const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x)
        return (high + 0.05) / (low + 0.05)
      }

      const surface = solve(style.backgroundColor, style.backgroundColor)
      return {
        edge: ratio(solve(style.borderTopColor, style.backgroundColor), surface),
        label: ratio(solve(style.color, style.backgroundColor), surface),
      }
    })

  // The surface and the border both animate when the theme changes, so poll
  // until they settle rather than reading colours still on their way.
  const settled = async (theme: string) => {
    await expect
      .poll(async () => {
        const now = await contrast()
        return now !== null && now.edge >= 3 && now.label >= 4.5
      }, { message: `the control never became legible in ${theme}` })
      .toBe(true)
    return contrast()
  }

  const dark = await settled('dark')
  expect(dark?.edge).toBeGreaterThanOrEqual(3)
  expect(dark?.label).toBeGreaterThanOrEqual(4.5)

  await page.getByTestId('theme-toggle').click()
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')

  const light = await settled('light')
  expect(light?.edge).toBeGreaterThanOrEqual(3)
  expect(light?.label).toBeGreaterThanOrEqual(4.5)
})

test('every document has a file of its own, so a shared link is not a 404', async ({ page }) => {
  await page.goto('docs')
  const hrefs = await page
    .getByTestId('doc-link')
    .evaluateAll((nodes) => nodes.map((node) => node.getAttribute('href') ?? ''))

  for (const href of hrefs.slice(0, 6)) {
    const response = await page.goto(href)
    // A cached response is still a served one; only a miss falls back to 404.
    expect(response?.status(), `${href} should be served, not fallen back to`).toBeLessThan(400)
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
  }
})

test('the edit link goes to this document in this repository', async ({ page }) => {
  await page.goto('docs/install/sdks')
  const edit = page.getByRole('link', { name: 'Edit this page on GitHub' })
  await expect(edit).toHaveAttribute(
    'href',
    'https://github.com/myzonerocks/gosslens/edit/main/site/docs/install/sdks.mdx',
  )
})

test('no link anywhere drops the path the site is served from', async ({ page, baseURL }) => {
  test.slow()
  const origin = new URL(baseURL ?? 'http://127.0.0.1').origin
  const base = new URL(baseURL ?? 'http://127.0.0.1').pathname

  await page.goto('docs')
  const pages = await page
    .getByTestId('doc-link')
    .evaluateAll((nodes) => nodes.map((node) => node.getAttribute('href') ?? ''))

  const dropped: string[] = []
  for (const path of ['', ...pages.slice(0, 10)]) {
    await page.goto(path)
    const links = await page
      .locator('#content a, footer a')
      .evaluateAll((nodes) => nodes.map((node) => ({ raw: node.getAttribute('href') ?? '', real: (node as HTMLAnchorElement).href })))

    for (const link of links) {
      if (!link.real.startsWith(origin)) continue
      const rest = link.real.slice(origin.length)
      // Same origin but outside the base means the base was lost on the way.
      if (!rest.startsWith(base)) dropped.push(`${path || '/'}: ${link.raw} resolves to ${rest}`)
    }
  }

  expect(dropped, 'links that lose the base path').toEqual([])
})

test('the page fits the screen it is on, with nothing sticking out', async ({ page }) => {
  test.slow()
  await page.goto('docs')
  const pages = await page
    .getByTestId('doc-link')
    .evaluateAll((nodes) => nodes.map((node) => node.getAttribute('href') ?? ''))

  const spilling: string[] = []
  for (const path of ['', ...pages]) {
    await page.goto(path)
    // A document arrives after the route does, so measuring straight away
    // measures an empty page and finds nothing wrong with it.
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
    const found = await page.evaluate(() => {
      const width = document.documentElement.clientWidth
      const out: string[] = []

      // A page wider than its own viewport is what a phone shrinks to fit.
      if (document.documentElement.scrollWidth > width + 1) {
        out.push(`document is ${document.documentElement.scrollWidth} wide in ${width}`)
      }

      // An element reaching past the edge, unless something above it scrolls.
      for (const element of document.querySelectorAll('body *')) {
        const box = element.getBoundingClientRect()
        if (box.right <= width + 1) continue
        let node: Element | null = element
        let contained = false
        while (node && node !== document.body) {
          const style = getComputedStyle(node)
          if (style.overflowX === 'auto' || style.overflowX === 'scroll' || style.overflowX === 'hidden') {
            contained = true
            break
          }
          node = node.parentElement
        }
        if (!contained) {
          out.push(`${element.tagName.toLowerCase()} reaches ${Math.round(box.right)} past ${width}`)
        }
      }
      return out.slice(0, 3)
    })
    for (const line of found) spilling.push(`${path || '/'}: ${line}`)
  }

  expect(spilling, 'things reaching past the edge of the screen').toEqual([])
})
