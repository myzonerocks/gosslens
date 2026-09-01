# Gosslens - Swift SDK

Swift SDK for [Gosslens](../../include/gosslens.h), a camera engine behind one
C ABI. Wraps it as `GossEngine`, `GossSession`, and `Gosslens`, the same names
the [Kotlin](../kotlin/README.md) and [TypeScript](../ts/README.md) SDKs use.

You write Swift and `import Gosslens`; the engine ships prebuilt inside the
package, so there is no toolchain to install and nothing to build. This SDK owns
capture ingress, GPU surface handoff, and platform tracking. The frame graph,
lens runtime, and effect pipeline live in the core. The [demo](demo/) is a full
working reference for the frame loop, and the full cross-platform capability tour
is in the [root README](../../README.md#what-you-get).

## Install

Add the SwiftPM package. Each release attaches a prebuilt, checksummed
`GosslensKit.xcframework` and pins `Package.swift` to it, so there is no Zig and
no build step:

```swift
.package(url: "https://github.com/myzonerocks/gosslens", from: "X.Y.Z")
```

```swift
.product(name: "Gosslens", package: "gosslens")
```

Set `X.Y.Z` to a released version like `0.9.0`; the latest is on the
[releases page](https://github.com/myzonerocks/gosslens/releases).

> [!TIP]
> The XCFramework carries the merged static engine and the C ABI module, and its
> checksum is pinned per release, so SwiftPM verifies the download. Nothing to
> link by hand, no search paths, no build step.

### Building from source

Prefer compiling the engine yourself, from a clone or your own fork? Build the
two slices, point SwiftPM at your checkout, and set the per-slice search paths:

```sh
zig build ios
zig build ios-simulator
```

```swift
.package(path: "../gosslens")
```

```text
LIBRARY_SEARCH_PATHS[sdk=iphoneos*]        = .../gosslens/zig-out/ios
LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*] = .../gosslens/zig-out/ios-simulator
```

Each simulator arch builds on its own (`zig build ios-simulator` for arm64,
`ios-simulator-x86` for Intel); the released XCFramework lipos both into one
universal simulator slice, so it runs on Apple-silicon and Intel Macs alike.
Build a from-source checkout with `ONLY_ACTIVE_ARCH=YES` against a concrete
simulator. Auto-link warnings for `AudioUnit`, `CoreAudioTypes`, or
`UIUtilities` at the final link are expected and benign.

## The render loop

Create the engine and a session once, then submit and render per frame. Submit
and render run on the same thread.

```swift
let engine = try GossEngine.create()
try engine.initRenderer(surface: metalLayer, width: w, height: h)
let session = try GossSession.create(engine: engine)

// per camera frame
let desc = GossFrameDesc(width: w, height: h, pixelFormat: .nv12,
                         rotationDegrees: 90, timestampUs: ts)
try session.submitFrame(desc: desc, planes: [yTextureHandle, uvTextureHandle])
try engine.renderFrame(session: session)
```

`submitFrame` takes platform texture handles for the zero-copy path;
`submitFrameCopy` is the CPU fallback from an NV12 byte buffer.
[`CameraController`](demo/Sources/CameraController.swift) and
[`PreviewViewController`](demo/Sources/PreviewViewController.swift)
are the copy-pasteable version of this, including the `CADisplayLink` loop and
the NV12 to Metal-texture handoff.

## Camera controls

The engine never drives camera hardware. It holds declarative intent you set,
normalizes it, and hands it back for you to apply to `AVCaptureDevice`:

```swift
var controls = goss_camera_controls()
controls.flash_mode = 2      // 0 off, 1 on, 2 auto
controls.zoom_factor = 2      // >= 1, clamped to the device ceiling
try session.setCameraControls(controls)

let applied = try session.cameraControls   // normalized; lock and apply
try device.lockForConfiguration()
device.videoZoomFactor = CGFloat(applied.zoom_factor)
device.unlockForConfiguration()
```

`goss_camera_controls` also carries torch, focus and exposure mode and points,
the exposure bias, and the front-camera mirror-save policy. Two companions
round-trip the same way: `setRecordingPolicy`/`recordingPolicy` (clip cap,
segment and loop mode, speed preset, mic mute, save-original, stabilization) for
your `AVAssetWriter`, and `setCaptureUi`/`captureUi` (grid, level, shutter mode,
self-timer, night mode, front-screen flash) for the capture chrome you draw. The
engine validates and clamps every field; you read it back and apply it.

## Lenses

A lens is a manifest plus its assets. Activate one on the session:

```swift
try session.activateLens(manifestJson: manifestData)
```

A lens that reads face, hand, or pose landmarks needs the matching ML model
enabled first, or it loads and renders nothing with no error. Each worker stands
up from its own task bundle and runs off the frames you already submit:

```swift
try session.enableFaceTracking(taskBundle: faceTaskData, threads: 2)
try session.enableHandTracking(taskBundle: gestureTaskData, threads: 2)
try session.enablePoseTracking(taskBundle: poseTaskData, threads: 2)
```

Hand tracking publishes up to two hands, scoring the canned gesture classes when
the bundle carries them; pose tracking publishes one 33-point body. For a selfie
framed with the legs out of shot, `setPoseUpperBody(true)` drops the lower-body
joints so the tracker is not fighting for knees and ankles it cannot see:

```swift
try session.setPoseUpperBody(true)
```

The `.task` bundles (`face_landmarker.task`, `gesture_recognizer.task`,
`pose_landmarker_full.task`) are separate resources you ship with your app;
they are not part of the engine archive. Bundle the ones your lenses use.

A lens's triggers can also react to signals you already feed: `camera.zoom`,
`camera.focus` and `camera.exposure` follow the camera controls above,
`geo.in_region` follows the geofence below, and `gaze.*` and
`head.nod`/`head.shake`/`head.tilt` follow the face tracker. The full grammar is
in [the lens spec](../../lenses/SPEC.md).

## Scripted lenses

A lens's behaviour is not baked into its render graph. Its triggers watch live
signals and its script nodes run in a sandboxed JS runtime, so one manifest can
react to a face, a tap, a beat, or an event you raise. Activating a lens from its
directory compiles a program for every `shader.pass` node it splices:

```swift
try session.activateLensFromDirectory(bundlePath: path)
```

Advance it once per frame with the elapsed time and the signals it reads.
`GossLensSignals` carries whether a face and hands are present, a tap, the world
tracking state, the audio level, and the face blendshapes; leave a field at its
default and the triggers that read it stay false:

```swift
var signals = GossLensSignals(hasFace: n > 0, handsPresent: hands,
                              tap: tapped, audioLevel: level,
                              blendshapes: face.blendshapes)
try session.tickLens(dtUs: dt, signals: signals)
```

`fireEvent` raises a named event the next tick delivers to the lens's
`event('name')` triggers for one tick, so an app moment drives an on-screen
effect; the engine knows the name, never its meaning. `parameterValue` reads a
live parameter back, including whatever a script node last wrote to it:

```swift
try session.fireEvent("celebrate")
let intensity = try session.parameterValue("intensity")
```

## Multiple faces

`enableFaceTracking` drives the single internal tracker, and a face-anchored
lens rides it. To fan that lens out across every face in frame, hand the engine
the faces you tracked this frame and it instances the anchored render across all
of them:

```swift
try session.submitFaces(results)          // up to GOSS_FACE_MAX; empty clears
let n = try session.faceCount()
for i in 0..<n { try session.faceResult(at: i, into: face) }
```

`submitBodies` is the multi-person equivalent, so a body-anchored lens reaches
every tracked figure:

```swift
try session.submitBodies(bodies)          // up to GOSS_BODY_MAX; empty clears
for i in 0..<(try session.bodyCount()) { try session.bodyResult(at: i, into: body) }
```

To pin content to a spot on the face, `faceRegion` returns the tracked point of a
named attach point - forehead, glabella, nose tip, chin, an eye, a cheek, an ear,
or a mouth corner:

```swift
let (x, y, _) = try session.faceRegion(.forehead)
```

`bodyJoint` is the body-skeleton equivalent, pinning to a shoulder, wrist, or
knee of the tracked figure:

```swift
let joint = try session.bodyJoint(.leftWrist)
```

`handJoint` is the hand equivalent, pinning to a fingertip or the wrist of the
tracked hand:

```swift
let tip = try session.handJoint(.indexTip)
```

## World tracking

For a lens anchored in the scene rather than on a face, drive world tracking
from ARKit. `GossWorldSource` is an `ARSessionDelegate` you set on your
`ARSession`; it forwards world tracking into the session so a world-anchored lens
and the AR brush stay fixed in the scene:

```swift
let world = GossWorldSource(session: session)   // ARKit, an ARSessionDelegate
arSession.delegate = world
world.start()
```

The scripted-lens `GossLensSignals` carries the world tracking state, and the
depth and intrinsics below refine the same AR frame.

## Depth

If the device reports scene depth - LiDAR, or ARKit's smoothed estimate - feed it
each frame so a depth-aware lens can occlude content behind real geometry. The
map is metres per pixel, row major, with the near and far range it spans:

```swift
let map = frame.sceneDepth?.depthMap       // ARFrame.sceneDepth
// lock the pixel buffer, copy its Float32 plane into `depth`, then:
try session.submitDepth(depth, width: w, height: h, near: 0.1, far: 5.0)
```

An empty array clears it. The engine keeps the latest map for the occlusion pass.

## Camera intrinsics

If the camera reports its calibration, feed it once so an `undistort.pass` can
straighten wide-angle lens distortion. The focal lengths and principal point are
in pixels of the submitted frame, followed by the radial coefficients (k1, k2):

```swift
let m = frame.camera.intrinsics          // ARCamera.intrinsics, column major
try session.submitCameraIntrinsics(fx: m[0][0], fy: m[1][1], cx: m[2][0], cy: m[2][1], distortion: [k1, k2])
```

An empty array clears them, leaving an `undistort.pass` inert.

## Segmentation

A lens's passes name the region they act on by one of sixteen mask channels:
`person`, `background`, `hair`, `body_skin`, `face_skin`, `clothes`, `others`,
`head`, `hand`, `lips`, `eyes`, `brows`, `iris`, `teeth`, `contour`, and
`highlight`. The `person` channel and the multiclass channels - `background`,
`hair`, `body_skin`, `face_skin`, `clothes`, `others` - ride an image segmenter
you stand up with `enableSegmentation(model:threads:)`: the model is any square
RGB segmenter's bytes and the thread count its worker parallelism, and
`disableSegmentation` tears it down. `head`, `hand`, the fine
face parts (`lips`, `eyes`, `brows`, `iris`, `teeth`), `contour`, and `highlight`
ride the face and hand trackers instead, so they resolve from the workers you
already enabled with no extra model.

For a gallery still rather than a camera frame, `submitSegmentationImage` runs
one host-provided RGBA image through the running segmenter, so a saved photo
picks up a mask the way a live frame would:

```swift
try session.submitSegmentationImage(rgba, width: w, height: h)
```

The `segmentationChannels` and `setSegmentationClassMask` controls belong to the
web SDK's analysis-producer path, where the tracking module produces masks off a
worker thread; on iOS the segmenter runs in-process, so you do not upload masks
yourself.

## Beauty and makeup

The beauty chain runs face-aware skin and reshape effects on the composited
frame. Enable it once from the directory that holds its resources - the engine
appends `res/` to the root you pass - then set each effect's strength from zero
to one:

```swift
try session.enableBeauty(resourceDir: bundleRoot)
try session.setSmooth(0.4)
try session.setWhiten(0.2)
try session.setThinFace(0.3)
```

`setBigEye`, `setLipstick`, and `setBlush` round out the set, and
`setBeauty(effect:amount:)` is the generic form the named setters wrap. A lens
that carries beauty defaults applies them through this same chain the moment you
activate it.

For makeup that matches a photo, `setMakeupReference` samples a reference face's
colour per part - you pass the reference image and its 478 landmarks - so a
`tint.pass` set to the reference source paints the live face in that colour; an
empty landmark array clears it:

```swift
try session.setMakeupReference(rgba, width: w, height: h, landmarks: refLandmarks)
```

`beautifyFrame` is the one-shot CPU path: it runs the beauty pass over a single
RGBA buffer into an output buffer you own, for a still with no renderer in the
loop. `setBeautyLut` and `setBeautyMakeupTexture` are the web SDK's
texture-upload path and throw `.unsupported` on iOS.

## Geofilters

A lens can gate on place. Feed a location fix and describe the region the lens
belongs to; the engine decides membership on-device and the fix never leaves it:

```swift
try session.submitLocation(latitude: lat, longitude: lon,
                           accuracyM: acc, timestampUs: ts)
try session.setGeofence(latitude: lat, longitude: lon, radiusM: 150)
```

`setGeofenceBBox` and `setGeofencePolygon` describe a box or a ring instead;
`setGeoAccuracy` sets the worst fix that still counts as inside, and
`clearGeofence` drops the gate. Membership drives the lens grammar's
`geo.in_region` trigger.

## Brush

Freehand strokes composite over the frame. Open a stroke, push normalized points
as the finger moves, and close it; the engine keeps the undo/redo stack and hands
back the ribbon (x, y, r, g, b, a per vertex) for your renderer:

```swift
try session.setBrushStyle(red: 1, green: 0.4, blue: 0.6, alpha: 1, width: 0.01)
try session.setBrushMode(.neon)     // pen, highlighter, marker, neon
try session.beginStroke()
try session.addStrokePoint(x: nx, y: ny)
try session.endStroke()
let ribbon = try session.brushVertices()
```

`setARBrushStyle`/`beginARStroke`/`addARStrokePoint(x:y:z:)`/`endARStroke` are the
world-anchored twin: points are pushed in the world frame world tracking reports,
so a stroke stays fixed in the scene.

## Capture and recording

Stills and video come off the engine, not the session, since they read the same
composited output `renderFrame` presents. `capturePhoto` returns deterministic
PNG bytes - the same composited pixels give the same file - and `capturePhoto(as:)`
returns a platform JPEG or HEIC instead:

```swift
let (png, w, h) = try engine.capturePhoto(session: session)
let (jpeg, _, _) = try engine.capturePhoto(session: session, as: .jpeg, quality: 90)
```

`captureStill` is the high-resolution path, decoupled from the preview swap chain
so a full-sensor still is not clamped to preview size. Its config carries the
target resolution, a supersample factor for photo-grade edges, the file format,
the colour space, and the bit depth; a still past the GPU's texture ceiling is
composited in tiles and stitched:

```swift
let config = GossEngine.StillConfig(supersample: 2, format: .heic, colorSpace: .displayP3)
let (data, _, _) = try engine.captureStill(session: session, config: config)
```

`startRecording` writes every rendered frame, effects baked in, into an MP4 (or
HEVC) until `stopRecording`. Feed `submitAudio` alongside it and the engine muxes
that PCM as the recording's audio track:

```swift
try engine.startRecording(session: session, path: url.path, hevc: true)
// render frames as usual
try engine.stopRecording()
```

`requestScreenshot` writes the next presented frame to a `.tga` file for debug
and test tooling.

## Multiple sources

The camera is the base layer, source 0, but a session can composite more: a guest
feed for a duet, a grid of callers, a shared screen. Register a named source,
upload its frames as RGBA, and pick a layout:

```swift
try session.defineSource("guest")
try session.submitSourceFrame("guest", rgba: pixels, width: w, height: h, stride: w * 4)
try session.setLayout(1)   // 0 custom, 1 side-by-side, 2 top-bottom, 3 pip, 4 grid, 5 overlay
```

`setSourceComposite` sets a source's opacity and keying - a matte from its own
alpha, or a chroma key with a colour and a match tolerance - so a green-screen
guest drops onto the camera cleanly. The name `camera` addresses the live base:

```swift
try session.setSourceComposite("guest", opacity: 1, key: 2,
                               chroma: (0, 1, 0), similarity: 0.2)
```

`defineScreenShare` registers a source whose frames letterbox to their cell
instead of stretching, for a shared screen that keeps its aspect. `removeSource`
and `clearLayout` tear the composition back down.

## Lives and calls

Publishing the lens-baked frames into a LiveKit or WebRTC call is a custom
video source fed one frame per tick. `GossLiveOutput` is the zero-copy path:
it renders the composited frame straight into an IOSurface-backed BGRA pixel
buffer - no readback - which VideoToolbox then encodes from the same surface.
Create one per broadcast on the renderer's `MTLDevice` (your `CAMetalLayer`'s):

```swift
let live = GossLiveOutput(engine: engine, device: metalLayer.device!, width: w, height: h)!

// per tick
if let buffer = live.nextFrame(session: session) {
    capturer.capture(buffer)   // publish; show the same buffer locally too
}
```

`nextFrame` renders once per call, so a broadcast source needs no separate
preview render - display the same buffer locally. It returns nil to skip a
frame while a fresh pool texture warms up bgfx's override, so just wait for
the next tick. Under the hood it calls `renderToLiveTexture`, which points the
final composite pass at your texture instead of the swap chain.

If you would rather own the pixels, `captureLiveFrame(format:)` reads the
frame back in BGRA, RGBA, or NV12 - one copy, for a software encoder or a
frame you inspect. The zero-copy `GossLiveOutput` is the broadcast default.

For audio, `submitAudio` feeds the mic in so audio-reactive lenses respond. For
the outgoing track, `mixOutputAudio` folds the lens's own sound into the mic
block you are about to publish and hands back the mixed interleaved s16 - the
engine resamples the lens sound to your track's rate and sums it in, so there
is nothing to hand-mix:

```swift
let mixed = try session.mixOutputAudio(mic: micSamples, frameCount: n,
                                       sampleRate: 48000, channels: 1)
audioTrack.send(mixed)   // publish; pass mic: nil for lens sound over silence
```

`pullAudio` still pulls the lens sound on its own for local playback with no
call in progress; in a call, `mixOutputAudio` replaces it. `GossAudioOutput`
routes that local playback to the speaker for you: `start()` it once after the
session exists and call `pump()` each frame beside `tickLens`, and lens sounds
play through an `AVAudioEngine` source it owns.

When the lens carries an `audio.infer` node with a caption binding, the engine
runs on-device ASR over the mic and `captionText` reads the decoded text by the
node's id, for the app to draw as a live subtitle:

```swift
if let line = session.captionText("caption") { subtitleLabel.text = line }
```

## Method names

The operation names match across the Swift, Kotlin, and TypeScript SDKs and are
the ones in the source: `GossEngine.create(config:)`, `GossSession.create(engine:)`,
`submitFrame`, `renderFrame`. The C SDK links the same operations under their
`goss_*` names. The full table is in [API.md](../../docs/API.md).

## Demo app

[`demo/`](demo/) is a real iOS app; see [`demo/README.md`](demo/README.md).

## Tests

Conformance runs through the demo app's `-GossConformance` launch argument and
[`harness/`](../../harness/).
