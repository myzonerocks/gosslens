import { Gosslens } from '@gosslens/sdk'

// The engine refuses a caller from another ABI major before anything is built.
const goss = await Gosslens.load(canvas, wasmUrl)
const session = await goss.createSession({ frameBudgetUs: 8_000 })

await session.activateLens(manifestJson)

session.submitFrameRgbaCopy(pixels, canvas.width * 4, canvas.width, canvas.height)
const record = session.perceptionJson()
