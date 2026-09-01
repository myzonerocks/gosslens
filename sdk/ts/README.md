# Gosslens - TypeScript SDK

TypeScript SDK for [Gosslens](../../include/gosslens.h), a camera engine behind
one C ABI, compiled to `wasm32`. It wraps the engine as `GossEngine`,
`GossSession`, and `Gosslens`, the same names the [Swift](../swift/README.md) and
[Kotlin](../kotlin/README.md) SDKs use.

This SDK owns camera capture through `getUserMedia`, the render loop, and
decoding the PNGs the core has no decoder for. The frame graph, lens runtime, and
effect pipeline live in the core. You write TypeScript; the engine is a prebuilt
WebAssembly build you host and hand the SDK. The [demo](demo/) is a full working
page, and the cross-platform SDK overview is in the [root README](../../README.md).

## Install

The npm package is the JavaScript wrapper you add with bun and write TypeScript
against. It does not carry the engine. The engine it drives is the emscripten
`gosslens_web.js`/`.wasm` (a WebGL2 build and a WebGPU build) plus
`gosslens_tracking.wasm`, which you host next to your app.

```sh
bun add @myzonerocks/gosslens
```

Because the browser cannot fetch a `.wasm` out of `node_modules` the way a native
app links an archive, you serve the prebuilt engine files from your own static
host and hand the SDK their URLs. The SDK never guesses a path. Every release
attaches `gosslens-web-engine.zip` - the two `gosslens_web` builds (WebGPU and
WebGL2 are separate artifacts, not a runtime toggle) and the tracking wasm - so
unzip it into your static assets. Grab it from the
[releases page](https://github.com/myzonerocks/gosslens/releases). `pickEngineUrl`
picks the WebGL2 or WebGPU build at load time from the URLs you point it at, after
confirming a real WebGPU adapter.

<details>
<summary>Building the engine and the SDK from source (engine maintainers only)</summary>

You only need this if you are changing the engine or the SDK itself. Build the
engine artifacts:

```sh
zig build wasm-emscripten
zig build wasm-emscripten-webgpu
zig build tracking-wasm
zig build fetch-models
```

Inside this monorepo, consume the SDK as a workspace dependency instead of the
published package:

```json
{ "dependencies": { "@myzonerocks/gosslens": "workspace:*" } }
```

`bun run build` compiles `src/` to `dist/src/` (the package points `main` and
`types` there); run it once in `sdk/ts` so `dist/` exists before a workspace
consumer resolves it.

</details>

## The render loop

`GossPreviewSession` does the engine, renderer, session, and capture loop in one
call - most apps want this:

```typescript
import { GossPreviewSession, pickEngineUrl } from "@myzonerocks/gosslens";

const wasmJsUrl = await pickEngineUrl(webgpuUrl, webgl2Url);
const preview = await GossPreviewSession.create(canvas, wasmJsUrl);
preview.activateLens(manifestJson);
```

`pickEngineUrl` confirms a real WebGPU adapter before choosing, and falls back to
the WebGL2 URL. `create` takes an optional third `events` argument for the
capture-loop callbacks. If you drive the loop yourself, the pieces are public too:

```typescript
import { Gosslens, GossEngine, GossSession } from "@myzonerocks/gosslens";

const gosslens = await Gosslens.load(canvas, wasmJsUrl);
const engine = GossEngine.create(gosslens);
await engine.initRenderer(canvas);
const session = GossSession.create(engine);

session.submitFrameRgbaCopy(rgba, width * 4, width, height);
engine.renderFrame(session);
```

## Camera controls

The engine never touches the camera. It holds declarative intent you set,
normalizes it, and hands it back for you to apply as getUserMedia track
constraints. The controls live on `GossSession`, so reach them through
`preview.session` if you took the `GossPreviewSession` path:

```typescript
session.setCameraControls({ ...session.cameraControls(), flashMode: 2, zoomFactor: 2 });

const applied = session.cameraControls();
await track.applyConstraints({ advanced: [{ zoom: applied.zoomFactor,
                                             torch: applied.torch === 1 }] });
```

`GossCameraControls` also carries focus and exposure mode and points, the
exposure bias, and the front-camera mirror-save policy. `setRecordingPolicy`/
`recordingPolicy` (clip cap, segment and loop mode, speed preset, mic mute,
save-original, stabilization) round-trips for your `MediaRecorder`, and
`setCaptureUi`/`captureUi` (grid, level, shutter mode, self-timer, night mode,
front-screen flash) for the capture chrome you draw. The engine validates and
clamps every field; you read it back and apply it.

## Lenses

A lens is a manifest plus its assets. Activate one from its manifest JSON, and
drop it again with `deactivateLens`:

```typescript
session.activateLens(manifestJson);
session.deactivateLens();
```

The web build activates from the manifest JSON directly. The directory-bundle
path the native SDKs also take is not wired here: a wasm target has no file IO,
and the `shader.pass`, `lut.pass`, and `blend.pass` nodes it would carry need
compiled resources this SDK has no way to hand over yet. A lens built entirely
from `beauty.*` nodes (the beauty-baseline lens, say) activates and runs for real
regardless, through the same beauty chain the effects below drive.

A lens that reads face, hand, pose, or segmentation data renders nothing until
you feed the matching tracker result each frame (see Tracking); it stays silent,
with no error. A lens's triggers also react to signals you already feed:
`camera.zoom`, `camera.focus` and `camera.exposure` follow the camera controls
above, `geo.in_region` follows the geofence below, and `gaze.*` and
`head.nod`/`head.shake`/`head.tilt` follow the face tracker. The full grammar is
in [the lens spec](../../lenses/SPEC.md).

Advance the lens's own clock, triggers, and script nodes once per display frame
with `tickLens`, passing the live signals this tick evaluates against:

```typescript
session.tickLens(dtUs, {
  hasFace: result.presence >= 0.5,
  blendshapes: result.blendshapes,
});
```

Omitted signal fields read as false or zero, so a bare `tickLens(dtUs)` only
advances triggers with no `when` gate. `fireEvent(name)` delivers a named event
to the lens's `event('name')` triggers for the next tick, and
`parameterValue(name)` reads a live lens parameter back, including whatever a
script node last wrote.

## Beauty and makeup

The beauty effects are direct session calls, each an amount in 0..1:

```typescript
session.setSmooth(0.6);
session.setWhiten(0.5);
session.setThinFace(0.3);
session.setBigEye(0.2);
session.setLipstick(0.7);
session.setBlush(0.4);
```

Whiten reads four lookup textures, and lipstick and blush their own source
images, none of which the core decodes. Load them once after setup; the SDK
decodes the PNGs, and until they resolve the matching setter stays a no-op:

```typescript
await session.loadWhitenLuts(new URL("./res/", baseUrl));     // the four lookup_*.png
await session.loadMakeupTextures(new URL("./res/", baseUrl)); // mouth.png, blusher.png
```

`setMakeupReference` samples a reference photo's makeup color per face part: the
lips, eyes, brows, and a cheek-and-forehead skin patch, so a lens's `tint.pass`
with a reference source paints the live face in that color and a foundation over
`face_skin` matches the reference's skin tone. Pass the reference RGBA and its
478-point face landmarks; an empty landmarks array clears it:

```typescript
session.setMakeupReference(refRgba, refWidth, refHeight, refLandmarks);
```

## Tracking

Face, hand, pose, and segmentation run in the `gosslens_tracking.wasm` module,
off the main thread in a Worker. Each pipeline is a class that takes the module
bytes and a model bundle and runs inference synchronously inside the worker:

```typescript
// tracking-worker.ts
import { GossFaceTracker, GossHandTracker, GossPoseTracker } from "@myzonerocks/gosslens";

const moduleBytes = await (await fetch(trackingWasmUrl)).arrayBuffer();
const face = await GossFaceTracker.create(moduleBytes, faceTaskBytes);
const hands = await GossHandTracker.create(moduleBytes, gestureTaskBytes);
const pose = await GossPoseTracker.create(moduleBytes, poseTaskBytes);
// per frame, on RGBA pixels from the camera canvas:
const faceResult = face.process(rgba, width, height, timestampUs);
const handResult = hands.process(rgba, width, height, timestampUs);
const poseResult = pose.process(rgba, width, height, timestampUs);
```

Standing a tracker up is the web equivalent of the native SDKs' enable calls:
this build runs no internal engine tracker, so you run the pipeline you need and
feed its result back. `GossHandTracker` returns up to two hands, each with 21
landmarks, a handedness score, and a canned gesture when the gesture bundle is
loaded; `GossPoseTracker` returns the 33-point skeleton.
[`demo/tracking-worker.ts`](demo/tracking-worker.ts) is the reference worker, and
[`demo/track-worker.ts`](demo/track-worker.ts) stands all four pipelines up over
still images.

The `.task`/`.tflite` bundles (`face_landmarker.task`, `gesture_recognizer.task`,
`pose_landmarker_full.task`, `selfie_multiclass.tflite`) are the ones
`fetch-models` writes; host and fetch the ones your lenses use.

Feed the tracked results back to the session for a lens to anchor to. The
single-face path is `setFaceLandmarks`. To fan a face-anchored lens out across
every face in frame, hand the engine the faces you tracked this frame:

```typescript
session.submitFaces(faces);      // GossFaceInput[], up to GOSS_FACE_MAX; [] clears
for (let i = 0; i < session.faceCount(); i++) {
  const face = session.faceResultAt(i);
}
```

`submitBodies` is the multi-person equivalent, reaching every tracked figure;
`setPoseUpperBody(true)` drops the skeleton's legs (knees down) for selfie
framing where they are out of shot:

```typescript
session.submitBodies(bodies);    // GossPoseInput[], up to GOSS_BODY_MAX; [] clears
for (let i = 0; i < session.bodyCount(); i++) {
  const body = session.bodyResultAt(i);
}
```

`faceRegion` returns the tracked point of a named attach point for pinning
content - forehead, glabella, nose tip, chin, an eye, a cheek, an ear, or a mouth
corner - reading the face landmarks you last submitted:

```typescript
const p = session.faceRegion(GossFaceRegion.Forehead);
```

For a body or hand joint, read the point off the tracker result directly: the
pose result carries all 33 landmarks, each hand its 21. The `bodyJoint` and
`handJoint` session pins read the engine's own internal trackers, which this
build does not stand up, so they stay empty here; on native they return the named
joint's point.

The face tracker also drives the `gaze.*` and `head.nod`/`head.shake`/`head.tilt`
lens triggers; `camera.*` follow the camera controls and `geo.in_region` the
geofence below. The full grammar is in [the lens spec](../../lenses/SPEC.md).

## Segmentation

`GossSegmenter` runs a single `.tflite` model through the same tracking module
and returns a subject mask, `GOSS_SEGMENTATION_MASK_SIDE` squared floats, plus the
model's own class channels. Feed the subject mask back as the texture the lens's
blend and mask channels sample:

```typescript
const segmenter = await GossSegmenter.create(moduleBytes, selfieMulticlassBytes);
const subject = segmenter.process(rgba, width, height);
session.setSegmentationMask(subject);      // null clears it
```

`selfie_multiclass.tflite` publishes the seven channels in
`GOSS_SEGMENTATION_CHANNELS` (person, background, hair, body_skin, face_skin,
clothes, others); `hair_segmenter.tflite` and `deeplab_v3.tflite` are the other
shipped models, a single hair mask and another multiclass label set. A lens that
names class channels reports them as a bitmask from `segmentationChannels`; upload
exactly those each frame with `setSegmentationClassMask`, after the subject mask,
since setting the subject clears the classes:

```typescript
const wanted = session.segmentationChannels();
for (let channel = 1; channel < GOSS_SEGMENTATION_CHANNELS.length; channel++) {
  if (wanted & (1 << channel)) {
    session.setSegmentationClassMask(channel, segmenter.classMask(channel - 1));
  }
}
```

## World and AR

`GossWebXRWorldSource` feeds WebXR frames into the session's world tracker, so a
world-anchored lens or AR brush stroke stays fixed in the scene. Drive it from the
XR animation loop:

```typescript
import { GossWebXRWorldSource } from "@myzonerocks/gosslens";

const world = new GossWebXRWorldSource(session);
// in the XR animation loop:
world.onFrame(xrFrame, referenceSpace, timestampUs);
```

## Depth

If the XR session was granted `depth-sensing`, feed each frame's depth so a
depth-aware lens can occlude content behind real geometry. The map is metres per
pixel, row major, with the near and far range it spans:

```typescript
const info = frame.getDepthInformation(view);   // WebXR depth-sensing
// read info into a Float32Array of metres, then:
session.submitDepth(depth, info.width, info.height, 0.1, 5.0);
```

An empty array clears it. The engine keeps the latest map for the occlusion pass.

## Camera intrinsics

If the camera reports its calibration, feed it once so an `undistort.pass` can
straighten wide-angle lens distortion. The focal lengths and principal point are
in pixels of the submitted frame, followed by the radial coefficients (k1, k2):

```typescript
// fx, fy, cx, cy from the platform's camera calibration, then:
session.submitCameraIntrinsics(fx, fy, cx, cy, new Float32Array([k1, k2]));
```

An empty array clears them, leaving an `undistort.pass` inert.

## Geofilters

A lens can gate on place. Feed a location fix from the Geolocation API and
describe the region the lens belongs to; the engine decides membership in wasm
and the fix never leaves the page:

```typescript
navigator.geolocation.watchPosition((pos) => {
  session.submitLocation(pos.coords.latitude, pos.coords.longitude,
                         pos.coords.accuracy, pos.timestamp * 1000);
});
session.setGeofence(lat, lon, 150);
```

`setGeofenceBBox` and `setGeofencePolygon` describe a box or a ring instead;
`setGeoAccuracy` sets the worst fix that still counts as inside, and
`clearGeofence` drops the gate. Membership drives the lens grammar's
`geo.in_region` trigger.

## Brush

Freehand strokes composite over the frame. Open a stroke, push normalized points,
and close it; the engine keeps the undo/redo stack and hands back the ribbon
(x, y, r, g, b, a per vertex):

```typescript
session.setBrushStyle(1, 0.4, 0.6, 1, 0.01);
session.setBrushMode(3);              // 0 pen, 1 highlighter, 2 marker, 3 neon
session.beginStroke();
session.addStrokePoint(nx, ny);
session.endStroke();
const ribbon = session.brushVertices();
```

`setARBrushStyle`/`beginARStroke`/`addARStrokePoint(x, y, z)`/`endARStroke` are the
world-anchored twin: points are pushed in the world frame world tracking reports,
so a stroke stays fixed in the scene.

## Capture and recording

The browser owns encoding on the web, so photo and video capture run through it.
`captureFrame` reads the composited canvas back and returns a PNG data URL:

```typescript
const png = await engine.captureFrame(session);   // or preview.captureFrame()
```

`captureStill` is the high-resolution path, decoupled from the preview size: it
renders the composite at its own or a requested resolution, supersamples, and
returns the encoded bytes with the format, gamut, and bit depth you tag. It needs
the wasm renderer, so it is a no-op on the pure WebGL2 fallback:

```typescript
const jpeg = await engine.captureStill(session, { width: 4032, height: 3024, format: 1, quality: 90 });
```

For video, drive a `MediaRecorder` off `canvas.captureStream()` yourself.
`setRecordingPolicy`/`recordingPolicy` round-trips the clip cap, segment and loop
mode, speed preset, mic mute, save-original, and stabilization the engine
normalizes, so the recorder and chrome you build read one validated policy. The
still encoder is the core's own (PNG and JPEG, wide-gamut and 16-bit PNG tagged);
the live video encoder stays native-only, which is why recording runs through the
browser. See [PARITY.md](../../docs/PARITY.md).

## Compositing

Beyond the camera, a session composites named RGBA sources into one frame, for a
duet, a stitch, or a live grid. The camera is the implicit source 0; define others
by name and push a frame into each:

```typescript
session.defineSource("guest");
session.submitSourceFrameRgba("guest", rgba, width, height, width * 4);
session.setLayout(3);   // 0 custom, 1 side-by-side, 2 top-bottom, 3 pip, 4 grid, 5 overlay
```

`setSourceComposite` sets a source's opacity and key mode (none, matte, or a
chroma key with its color and similarity), so a keyed guest drops onto the base:

```typescript
session.setSourceComposite("guest", 1, 2, [0, 1, 0], 0.4);   // chroma-key green
```

`defineScreenShare` registers a source whose frame letterboxes to fit its cell,
`removeSource` drops one, and `clearLayout` returns to the camera alone.

## Lives and calls

The web is the easy case: the rendered canvas is already a live video source.
`canvas.captureStream()` hands you a `MediaStreamTrack` of the composited,
lens-baked output with no readback and no copy - publish it straight to LiveKit or
any WebRTC peer:

```typescript
const track = canvas.captureStream(30).getVideoTracks()[0];
// publish `track` through your LiveKit room or RTCPeerConnection
```

Keep the render loop running (`renderFrame` per frame) and the track carries every
composited frame. Reach for `captureLiveFrame` only when you need the raw pixels
(BGRA by default) rather than a track. For audio, `mixOutputAudio` folds the
lens's own sound into the mic block you are about to publish and returns the mixed
interleaved s16 for your outgoing WebRTC audio track: it resamples the lens sound
to your track's rate and sums it in, so there is nothing to hand-mix (pass `null`
for the mic to send the lens sound over silence). `pullAudio` still pulls the lens
sound alone for local WebAudio playback with no call in progress; `GossAudioOutput`
wraps that playback (an `AudioWorklet` it owns, `start()` from a gesture, `pump()`
each frame beside `tickLens`). `GossMicInput` captures the microphone into
`submitAudio` so level and beat triggers fire in the browser, and
`GossVideoTexture` plays an MP4 through the browser's decoder into a named
source a lens composites.

When the lens carries an `audio.infer` node with a caption binding, the engine
runs on-device ASR over the mic and `captionText` reads the decoded text by the
node's id, for the page to draw as a live subtitle:

```typescript
const line = session.captionText("caption");
if (line) subtitleEl.textContent = line;
```

## Method names

The operation names match the other SDKs: `GossEngine.create(gosslens)`,
`GossSession.create(engine)`, `submitFrameRgbaCopy`, `renderFrame`. The full table
is in [API.md](../../docs/API.md).

## Demo app

[`demo/`](demo/) is a real web page; see [`demo/README.md`](demo/README.md).

## Tests

`bun test` runs the unit suite in [`test/`](test) - the frozen-layout result
parsers and the WebGPU/WebGL2 pick. The browser end-to-end proofs live in
[`demo/prove.ts`](demo/prove.ts) and [`demo/track-prove.ts`](demo/track-prove.ts),
with the host conformance in [`harness/`](../../harness/).
