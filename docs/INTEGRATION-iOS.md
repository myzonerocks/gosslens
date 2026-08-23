# Integrating gosslens on iOS

This is the path from a checkout to a camera preview with a lens on it in
your own app. The [Swift SDK](../sdk/swift/README.md) is the surface; the
[demo](../sdk/swift/demo) is a full working reference for the frame loop.

## Build the engine slices

The SDK is thin Swift over a static engine. Build the engine for the slices
you target; the output lands in `zig-out`.

    zig build ios
    zig build ios-simulator

On a Mac with Xcode both steps find their SDK through `xcrun` on their own;
pass `-Dios-sdk`/`-Dios-simulator-sdk` (or `--sysroot`) only to point at a
specific one. Each step writes `libgosslens.a` and the vendored archives
(bgfx, the inference stack, ANGLE, QuickJS, Jolt) into `zig-out/ios` and
`zig-out/ios-simulator`, all aligned and ready to link.

The simulator slice is arm64 only. On an Apple-silicon Mac build with
`ONLY_ACTIVE_ARCH=YES` against a concrete simulator, not a universal
destination that would also ask for an x86_64 half.

At the app's final link you may see auto-link warnings for `AudioUnit`,
`CoreAudioTypes`, or `UIUtilities`. They are expected and benign - those
umbrella frameworks are not standalone link targets on iOS, the requests come
from inside the vendored libraries, and the engine links what it actually needs
explicitly. Nothing is missing; the app links and runs.

## Add the package

Point SwiftPM at the repository, either as a local path while you develop or
as a git dependency:

    .package(path: "../gosslens")
    .package(url: "https://github.com/myzonerocks/gosslens", branch: "main")

The `Gosslens` product carries the whole `-l` list and the frameworks it needs
in its own linker settings, so you do not copy them by hand. It cannot know
where you put `zig-out`, so set the two search paths on your app target, one
per slice:

    LIBRARY_SEARCH_PATHS[sdk=iphoneos*]        = .../gosslens/zig-out/ios
    LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*] = .../gosslens/zig-out/ios-simulator

That is the whole build setup. The header comes from the package's C module,
so there is nothing else to wire.

## The render loop

Create the engine and a session once, then submit and render per frame. Submit
and render run on the same thread.

    let engine = try GossEngine.create()
    try engine.initRenderer(surface: metalLayer, width: w, height: h)
    let session = try GossSession.create(engine: engine)

    // per camera frame
    let desc = GossFrameDesc(width: w, height: h, pixelFormat: .nv12,
                             rotationDegrees: 90, timestampUs: ts)
    try session.submitFrame(desc: desc, planes: [yTextureHandle, uvTextureHandle])
    try engine.renderFrame(session: session)

`submitFrame` takes platform texture handles for the zero-copy path;
`submitFrameCopy` is the CPU fallback from an NV12 byte buffer.
[`CameraController`](../sdk/swift/demo/Sources/CameraController.swift) and
[`PreviewViewController`](../sdk/swift/demo/Sources/PreviewViewController.swift)
are the copy-pasteable version of this, including the `CADisplayLink` loop and
the NV12 to Metal-texture handoff.

## Camera controls

The engine never drives camera hardware. It holds declarative intent you set,
normalizes it, and hands it back for you to apply to `AVCaptureDevice`:

    var controls = goss_camera_controls()
    controls.flash_mode = 2      // 0 off, 1 on, 2 auto
    controls.zoom_factor = 2      // >= 1, clamped to the device ceiling
    try session.setCameraControls(controls)

    let applied = try session.cameraControls   // normalized; lock and apply
    try device.lockForConfiguration()
    device.videoZoomFactor = CGFloat(applied.zoom_factor)
    device.unlockForConfiguration()

`goss_camera_controls` also carries torch, focus and exposure mode and points,
the exposure bias, and the front-camera mirror-save policy. Two companions
round-trip the same way: `setRecordingPolicy`/`recordingPolicy` (clip cap,
segment and loop mode, speed preset, mic mute, save-original, stabilization) for
your `AVAssetWriter`, and `setCaptureUi`/`captureUi` (grid, level, shutter mode,
self-timer, night mode, front-screen flash) for the capture chrome you draw. The
engine validates and clamps every field; you read it back and apply it.

## Lenses

A lens is a manifest plus its assets. Activate one on the session:

    try session.activateLens(manifestJson: manifestData)

A lens that reads face, hand, or pose landmarks needs the matching ML model
enabled first, or it loads and renders nothing with no error:

    try session.enableFaceTracking(taskBundle: faceTaskData, threads: 2)

The `.task` bundles (`face_landmarker.task`, `gesture_recognizer.task`,
`pose_landmarker_full.task`) are separate resources you ship with your app;
they are not part of the engine archive. Bundle the ones your lenses use.

A lens's triggers can also react to signals you already feed: `camera.zoom`,
`camera.focus` and `camera.exposure` follow the camera controls above,
`geo.in_region` follows the geofence below, and `gaze.*` and
`head.nod`/`head.shake`/`head.tilt` follow the face tracker. The full grammar is
in [the lens spec](../lenses/SPEC.md).

## Multiple faces

`enableFaceTracking` drives the single internal tracker, and a face-anchored
lens rides it. To fan that lens out across every face in frame, hand the engine
the faces you tracked this frame and it instances the anchored render across all
of them:

    try session.submitFaces(results)          // up to GOSS_FACE_MAX; empty clears
    let n = try session.faceCount()
    for i in 0..<n { try session.faceResult(at: i, into: face) }

To pin content to a spot on the face, `faceRegion` returns the tracked point of a
named attach point - forehead, glabella, nose tip, chin, an eye, a cheek, an ear,
or a mouth corner:

    let (x, y, _) = try session.faceRegion(.forehead)

`bodyJoint` is the body-skeleton equivalent, pinning to a shoulder, wrist, or
knee of the tracked figure:

    let joint = try session.bodyJoint(.leftWrist)

`handJoint` is the hand equivalent, pinning to a fingertip or the wrist of the
tracked hand:

    let tip = try session.handJoint(.indexTip)

## Geofilters

A lens can gate on place. Feed a location fix and describe the region the lens
belongs to; the engine decides membership on-device and the fix never leaves it:

    try session.submitLocation(latitude: lat, longitude: lon,
                               accuracyM: acc, timestampUs: ts)
    try session.setGeofence(latitude: lat, longitude: lon, radiusM: 150)

`setGeofenceBBox` and `setGeofencePolygon` describe a box or a ring instead;
`setGeoAccuracy` sets the worst fix that still counts as inside, and
`clearGeofence` drops the gate. Membership drives the lens grammar's
`geo.in_region` trigger.

## Brush

Freehand strokes composite over the frame. Open a stroke, push normalized points
as the finger moves, and close it; the engine keeps the undo/redo stack and hands
back the ribbon (x, y, r, g, b, a per vertex) for your renderer:

    try session.setBrushStyle(red: 1, green: 0.4, blue: 0.6, alpha: 1, width: 0.01)
    try session.setBrushMode(.neon)     // pen, highlighter, marker, neon
    try session.beginStroke()
    try session.addStrokePoint(x: nx, y: ny)
    try session.endStroke()
    let ribbon = try session.brushVertices()

`setARBrushStyle`/`beginARStroke`/`addARStrokePoint(x:y:z:)`/`endARStroke` are the
world-anchored twin: points are pushed in the world frame world tracking reports,
so a stroke stays fixed in the scene.

## Lives and calls

Publishing the lens-baked frames into a LiveKit or WebRTC call is a custom
video source fed one frame per tick. `GossLiveOutput` is the zero-copy path:
it renders the composited frame straight into an IOSurface-backed BGRA pixel
buffer - no readback - which VideoToolbox then encodes from the same surface.
Create one per broadcast on the renderer's `MTLDevice` (your `CAMetalLayer`'s):

    let live = GossLiveOutput(engine: engine, device: metalLayer.device!, width: w, height: h)!

    // per tick
    if let buffer = live.nextFrame(session: session) {
        capturer.capture(buffer)   // publish; show the same buffer locally too
    }

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

    let mixed = try session.mixOutputAudio(mic: micSamples, frameCount: n,
                                           sampleRate: 48000, channels: 1)
    audioTrack.send(mixed)   // publish; pass mic: nil for lens sound over silence

`pullAudio` still pulls the lens sound on its own for local playback with no
call in progress; in a call, `mixOutputAudio` replaces it.

## Method names

The operation names are the same across all three SDKs and are the ones in the
source: `GossEngine.create(config:)`, `GossSession.create(engine:)`,
`submitFrame`, `renderFrame`. The full table is in [API.md](API.md).
