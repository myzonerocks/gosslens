# Web demo

A browser page with a live camera preview, real-time face tracking, the six
beauty sliders, post-effect filter lenses, a photo capture, and a virtual
background driven by the selfie segmenter. It runs the wasm core through a
real bgfx renderer (WebGPU when the browser has a working adapter, WebGL2
otherwise). No framework, no bundler beyond a single `bun build`.

The page imports the SDK straight from its source next door
(`../src/index.ts` and `../src/tracking.ts`), never a published package, so
whatever is in `src/` is exactly what the demo runs.

## What's on screen

- Live front-camera preview, always mirrored.
- Beauty sliders: smooth, whiten, thin face, big eye, lipstick, blush.
- Filter lenses activated from inline JSON: none, blur, grade, bloom, ember.
- Tracking overlay with a show/hide toggle: face dots, a nose-tip attach
  marker, and hand and body dots when those results are present.
- A one-line tracking readout: face presence, the stable face track id, the
  hand's canned gesture, and the live fps.
- Virtual background: turns the selfie segmenter on and composites a blurred
  background from the person mask. With no segmenter model present the toggle
  disables itself with a short note.
- Capture Photo: writes the composited frame to a PNG and shows it.

## One-time setup

From the repo root:

    zig build wasm-emscripten
    zig build wasm-emscripten-webgpu
    zig build tracking-wasm
    zig build fetch-models
    cp zig-out/wasm/gosslens_tracking.wasm sdk/ts/demo/
    cp .models/face_landmarker.task .models/selfie_multiclass.tflite sdk/ts/demo/
    cp .models/corpus/face_frontal_b.jpg .models/corpus/no_face_control.jpg sdk/ts/demo/
    cd sdk/ts/demo
    bun build ./tracking-worker.ts --outfile=./tracking-worker.js --format=esm
    bun build ./segmenter-worker.ts --outfile=./segmenter-worker.js --format=esm

`selfie_multiclass.tflite` is what the virtual background loads; leave it out
and the page still runs, with the toggle disabled and a note. The two worker
bundles host the tracking and segmentation wasm off the main thread; rebuild
them whenever those source files change.

`wasm-emscripten` and `wasm-emscripten-webgpu` each copy their own
`gosslens_web.js`/`.wasm` straight into `sdk/ts/demo/` (WebGL2) and
`sdk/ts/demo/webgpu/` (WebGPU) as part of the build, so there's no separate
copy step for those two and no way to silently keep testing a stale binary
after a source change. `main.ts` picks between the two directories at load
time based on whether the browser has a working WebGPU adapter. Everything
else copied in above is a gitignored fetch/build output. Re-run the step that
produced it whenever the tracking module or the pinned models change.

## Run it

    bun build ./main.ts --outfile=./dist.js --format=esm
    python3 -m http.server 8932

Then open http://localhost:8932/. Grant camera access when the browser asks.
Use `bun build`, not `bun index.html --port=N` - the latter is a bundler dev
server that serves the same HTML for every path, not a static file server.

If your camera hands the browser frames pre-rotated, check "camera upside
down" in the controls bar; it's remembered across reloads.

## Proving it

    bun run prove.ts

Drives the real page in headless Chrome (fake capture device) and checks real
frame deltas for whiten/smooth/reshape/makeup. It then activates the
beauty-baseline reference lens and checks its render is non-empty and
byte-identical across two frames, and confirms live face tracking against a
corpus portrait. The run only passes if every one of these passes. Same
headless-Chrome technique the demo's browser testing uses throughout this
repo.

## Proving the tracking modules

Face, pose, hand and segmentation each run in a real browser over a corpus
still, not the live camera. From the repo root, copy the extra bundles the
proof reads:

    cp .models/pose_landmarker_full.task .models/gesture_recognizer.task sdk/ts/demo/
    cp .models/corpus/body_standing.jpg .models/corpus/hand_raised.jpg sdk/ts/demo/

The face and segmentation bundles the setup above already copied are reused
here. Then build the worker and page and run the proof:

    cd sdk/ts/demo
    bun build ./track-worker.ts --outfile=./track-worker.js --format=esm
    bun build ./track-page.ts --outfile=./track.js --format=esm
    bun run track-prove.ts

It stands each pipeline up in turn, runs inference over its still, and prints
a PASS line with the landmark counts, the detected hand and gesture, and the
segmentation class count and mask coverage. `track-prove` only materializes
assets: it copies the tracking wasm from the build output plus the model
bundles and corpus stills from `.models`, then serves the page. Build the page
and worker bundles first with the two `bun build` commands above and the wasm
with `zig build tracking-wasm`.
