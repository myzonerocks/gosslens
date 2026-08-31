# Gosslens - TypeScript SDK

TypeScript SDK for [Gosslens](../../include/gosslens.h), a camera engine
with a Zig core behind one C ABI, compiled to `wasm32`. Wraps it as
`GossEngine`, `GossSession`, and `Gosslens`, the same names the
[Swift](../swift/README.md) and [Kotlin](../kotlin/README.md) SDKs use.

This SDK owns camera capture through `getUserMedia`, the render loop,
and decoding the PNGs the core has no decoder for. The frame graph, lens
runtime, and effect pipeline live in the core.

[docs/INTEGRATION-WEB.md](../../docs/INTEGRATION-WEB.md) is the start-to-finish
guide: build and host the wasm and model assets, the render loop, and the
tracking worker.

## Install

```
bun add @myzonerocks/gosslens
```

Inside this monorepo, consume it from the workspace instead:

```json
{ "dependencies": { "@myzonerocks/gosslens": "workspace:*" } }
```

`bun run build` compiles `src/` to `dist/src/` (the package points `main`
and `types` there); run it once so `dist/` exists before a workspace
consumer resolves it.

This package is the JS wrapper only. `zig build wasm-emscripten` builds
the WebGL2 `gosslens_web.js`/`.wasm` pair; `zig build
wasm-emscripten-webgpu` builds the WebGPU pair. `pickEngineUrl` picks
between them at load, so `wasmJsUrl` points at whichever one it selects.
They are separate artifacts, not bundled.

## Use

```ts
import { Gosslens, GossEngine, GossSession, GossPreviewSession } from "@myzonerocks/gosslens";

const gosslens = await Gosslens.load(canvas, wasmJsUrl);
const engine = GossEngine.create(gosslens);
await engine.initRenderer(canvas);
const session = GossSession.create(engine);

session.submitFrameRgbaCopy(rgba, width * 4, width, height);
engine.renderFrame(session);

session.setWhiten(0.6);
session.activateLens(manifestJson);
```

`GossPreviewSession.create(canvas, wasmJsUrl, events)` does all three setup
steps and owns the capture loop too; most app code wants this one.

WebGPU and WebGL2 are two separate build artifacts, not a runtime
toggle; `pickEngineUrl` picks the right one after confirming a real
adapter.

Capture reads a PNG back, and world tracking feeds WebXR frames in:

```ts
import { GossWebXRWorldSource } from "@myzonerocks/gosslens";

const png = await engine.captureFrame(session);   // data URL

const world = new GossWebXRWorldSource(session);
// in the XR animation loop:
world.onFrame(xrFrame, referenceSpace, timestampUs);
```

On web, recording and photo capture run through the browser, used by both
this SDK and the demo: `captureFrame()` exports a PNG off the composited
canvas, and `captureStream()` drives a `MediaRecorder` with the
engine-normalized recording policy. The engine's own hardware encoder and
the platform-native HEIC format stay native-only, since the browser owns
encoding on web; see [docs/PARITY.md](../../docs/PARITY.md). The
cross-platform SDK overview is in the [root README](../../README.md).

## Demo app

[`demo/`](demo/) is a real web page; see [`demo/README.md`](demo/README.md).

## Tests

`bun test` runs the unit suite in [`test/`](test) - the frozen-layout result
parsers and the WebGPU/WebGL2 pick. The browser end-to-end proofs live in
[`demo/prove.ts`](demo/prove.ts) and [`demo/track-prove.ts`](demo/track-prove.ts),
with the host conformance in [`harness/`](../../harness/).

## TODO

- Publish `@myzonerocks/gosslens` to npm; until then `bun add` resolves
  only inside the workspace.
