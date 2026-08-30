# Integrating gosslens on Android

The path from a checkout to a camera preview with a lens on it in your own
app. The [Kotlin SDK](../sdk/kotlin/README.md) is the surface; the
[demo](../sdk/kotlin/demo) is a full working reference for the frame loop.

Unlike the static-archive story on iOS, the engine ships here as one shared
library. `libgosslens.so` links the whole engine - the inference stack,
QuickJS, Jolt, everything - into itself, so there is nothing for a consumer to
resolve by hand. The one thing to get right is that the `.so` is present when
gradle packages your app.

## Build the native library

    zig build android

This writes `zig-out/android/arm64-v8a/libgosslens.so` and
`zig-out/android/x86_64/libgosslens.so`. arm64-v8a covers every current device
and the arm64 emulator an Apple-silicon machine runs by default; x86_64 covers
an Intel-host emulator. gradle picks the right one per ABI, so a device and
either emulator all link and run the engine.

## Add the SDK

The Kotlin SDK is an Android library module that packages the `.so` for you -
its gradle reads `jniLibs.srcDir("../../zig-out/android")`, so once you have run
`zig build android`, the archive it produces carries the native library.

The SDK is not published to Maven Central (or anywhere) yet, so add this
project as an included build and depend on it - gradle substitutes the module
for the coordinate, no registry involved:

    // settings.gradle.kts
    includeBuild("../gosslens/sdk/kotlin")

    // build.gradle.kts
    dependencies {
        implementation("com.myzonerocks:gosslens")
    }

Publishing an AAR to a coordinate later works the same way, as long as the
`.so` exists at publish time - so a publish step runs `zig build android`
first. A source-only service like JitPack does not run that step and would ship
an AAR with no native library, which crashes on `System.loadLibrary`; the
included build above is the only path that works today.

## The render loop

Create the engine and a session once, then submit and render per frame. Submit
and render run on the same thread.

    val engine = GossEngine.create()
    engine.initRenderer(surface, width, height)
    val session = GossSession.create(engine)

    // per camera frame
    session.submitFrameCopy(yBuffer, yStride, uvBuffer, uvStride, width, height,
                            rotationDegrees = 90, mirrored = false, timestampUs)
    engine.renderFrame(session)

`submitHardwareBuffer` is the zero-copy path for an `AHardwareBuffer`; any
non-OK status falls back to `submitFrameCopy`.
[`MainActivity`](../sdk/kotlin/demo/src/main/kotlin/com/gosslens/demo/MainActivity.kt)
is the copy-pasteable version of this, including the surface and camera wiring.

## Camera controls

The engine never drives camera hardware. It holds declarative intent you set,
normalizes it, and hands it back for you to apply through CameraX:

    session.setCameraControls(GossCameraControls(flashMode = 2, zoomFactor = 2f))

    val applied = session.cameraControls() ?: return
    cameraControl.setZoomRatio(applied.zoomFactor)

`GossCameraControls` also carries torch, focus and exposure mode and points, the
exposure bias, and the front-camera mirror-save policy. Two companions round-trip
the same way: `setRecordingPolicy`/`recordingPolicy` (clip cap, segment and loop
mode, speed preset, mic mute, save-original, stabilization) for your recorder,
and `setCaptureUi`/`captureUi` (grid, level, shutter mode, self-timer, night
mode, front-screen flash) for the capture chrome you draw. The engine validates
and clamps every field; you read it back and apply it.

## Lenses

A lens is a manifest plus its assets. Activate one on the session:

    session.activateLens(manifestJson)

A lens that reads face, hand, or pose landmarks needs the matching ML model
enabled first, or it loads and renders nothing with no error:

    session.enableFaceTracking(taskBundle, threads = 2)

The `.task` bundles (`face_landmarker.task`, `gesture_recognizer.task`,
`pose_landmarker_full.task`) are separate resources you ship with your app;
they are not part of the `.so`. Bundle the ones your lenses use.

A lens's triggers can also react to signals you already feed: `camera.zoom`,
`camera.focus` and `camera.exposure` follow the camera controls above,
`geo.in_region` follows the geofence below, and `gaze.*` and
`head.nod`/`head.shake`/`head.tilt` follow the face tracker. The full grammar is
in [the lens spec](../lenses/SPEC.md).

## Scripted lenses

`activateLens` splices a manifest's nodes in; the lens then runs on its own
clock. Tick it once per render frame with the live signals it evaluates its
triggers and script nodes against, and it drives whatever effect values, ramps,
and QuickJS logic the manifest declares:

    val signals = GossLensSignals()
    signals.set(hasFace, handsPresent, tap = false,
                worldTrackingState = 0.0, audioLevel = 0.0, blendshapes)
    session.tickLens(dtUs, signals)

Tick every frame even when no new tracking result landed, so the lens's own
animation ramps advance at display rate rather than tracking cadence.
`fireEvent(name)` hands the lens an app moment its `event('name')` triggers see
for one tick; `parameterValue(name)` reads a live parameter back, including
whatever a script node last wrote. `activateLensFromDirectory(path)` activates a
packaged `.glens` bundle instead of raw JSON, compiling each shader pass for the
running backend, and `deactivateLens` unsplices whatever is active.

## Multiple faces

`enableFaceTracking` drives the single internal tracker, and a face-anchored
lens rides it. To fan that lens out across every face in frame, hand the engine
the faces you tracked this frame:

    session.submitFaces(results)              // up to FACE_MAX; empty clears
    for (i in 0 until session.faceCount()) session.faceResultAt(i, face)

`submitBodies` is the multi-person equivalent, reaching every tracked figure:

    session.submitBodies(bodies)              // up to BODY_MAX; empty clears
    for (i in 0 until session.bodyCount()) session.bodyResultAt(i, body)

To pin content to a spot on the face, `faceRegion` returns the tracked point of a
named attach point - forehead, glabella, nose tip, chin, an eye, a cheek, an ear,
or a mouth corner:

    val p = session.faceRegion(Gosslens.FACE_REGION_FOREHEAD) ?: return

`bodyJoint` is the body-skeleton equivalent, pinning to a shoulder, wrist, or
knee of the tracked figure:

    val joint = session.bodyJoint(Gosslens.BODY_JOINT_LEFT_WRIST) ?: return

`handJoint` is the hand equivalent, pinning to a fingertip or the wrist of the
tracked hand:

    val tip = session.handJoint(Gosslens.HAND_JOINT_INDEX_TIP) ?: return

## Hands and pose

`enableFaceTracking` has hand and pose twins. Each stands its own worker up from
a `.task` bundle and publishes a reusable result you read back per frame:

    session.enableHandTracking(handTask, threads = 2)
    session.enablePoseTracking(poseTask, threads = 2)

    val hands = GossHandResult()
    if (session.handResult(hands)) { /* hands.handCount, landmarks, gestures */ }

    val pose = GossPoseResult()
    if (session.poseResult(pose)) { /* pose.landmarkCount, pose.landmarks */ }

A `gesture_recognizer.task` bundle additionally scores each hand's canned gesture
into `hands.gestures` - open palm, fist, victory, and the rest; a plain hand
landmarker leaves them `GESTURE_NONE`. `setPoseUpperBody(true)` trims the pose to
the upper body when the legs sit out of frame. `disableHandTracking` and
`disablePoseTracking` tear each worker down.

## Segmentation

A pass paints only the region of a named mask channel. Sixteen are addressable:
person, background, hair, body_skin, face_skin, clothes and others come from the
segmentation model; head, hand, lips, eyes, brows, iris and teeth ride the face
and hand landmarks the trackers publish; contour and highlight cluster face
landmarks for makeup shading. The manifest names the channel each pass acts on.

To run the segmenter over a still you hold rather than the live camera frame,
hand it in as RGBA8 and its mask reaches the active lens the way a camera
frame's would:

    session.submitSegmentationImage(rgba, width, height)

## Beauty and makeup

The beauty chain is a separate effect stack you stand up from a directory of its
shader and image assets, then drive one effect at a time:

    session.enableBeauty(resourceDir)
    session.setSmooth(0.6f)
    session.setLipstick(0.4f)

`setSmooth`, `setWhiten`, `setThinFace`, `setBigEye`, `setLipstick` and
`setBlush` each clamp to zero and one and are the named face of
`setBeauty(effect, amount)`. A lens applies its own default beauty values on
activation and animates them as its triggers fire, so a manifest and hand-set
values drive the same chain.

`setMakeupReference` samples a reference photo's makeup color per face part: the
lips, eyes, brows, and a cheek-and-forehead skin patch, so a tint.pass with a
"reference" source paints the live face in that color and a foundation over
`face_skin` matches the reference's skin tone. Pass the photo as RGBA8 with its
own 478-point face landmarks; an empty array clears it:

    session.setMakeupReference(rgba, width, height, referenceLandmarks)

`beautifyFrame` runs the whole chain over one RGBA frame on the calling thread,
the CPU path for a still you hold outside the render loop.

## Depth

If the device supports the ARCore Depth API, feed the depth image each frame so a
depth-aware lens can occlude content behind real geometry. The map is metres per
pixel, row major, with the near and far range it spans:

    val image = frame.acquireDepthImage16Bits()   // millimetres; convert to metres
    // copy into a FloatArray, then:
    session.submitDepth(depth, w, h, 0.1f, 5.0f)

An empty array clears it. The engine keeps the latest map for the occlusion pass.

## Camera intrinsics

If the camera reports its calibration, feed it once so an `undistort.pass` can
straighten wide-angle lens distortion. The focal lengths and principal point are
in pixels of the submitted frame, followed by the radial coefficients (k1, k2):

    val i = frame.camera.imageIntrinsics       // CameraIntrinsics
    session.submitCameraIntrinsics(i.focalLength[0], i.focalLength[1], i.principalPoint[0], i.principalPoint[1], floatArrayOf(k1, k2))

An empty array clears them, leaving an `undistort.pass` inert.

## Geofilters

A lens can gate on place. Feed a location fix and describe the region the lens
belongs to; the engine decides membership on-device and the fix never leaves it:

    session.submitLocation(latitude, longitude, accuracyM, timestampUs)
    session.setGeofence(latitude, longitude, radiusM = 150.0)

`setGeofenceBBox` and `setGeofencePolygon` describe a box or a ring instead;
`setGeoAccuracy` sets the worst fix that still counts as inside, and
`clearGeofence` drops the gate. Membership drives the lens grammar's
`geo.in_region` trigger.

## Brush

Freehand strokes composite over the frame. Open a stroke, push normalized points,
and close it; the engine keeps the undo/redo stack and hands back the ribbon
(x, y, r, g, b, a per vertex):

    session.setBrushStyle(1f, 0.4f, 0.6f, 1f, 0.01f)
    session.setBrushMode(GossSession.BrushMode.NEON)
    session.beginStroke()
    session.addStrokePoint(nx, ny)
    session.endStroke()
    val ribbon = session.brushVertices()

`setARBrushStyle`/`beginARStroke`/`addARStrokePoint(x, y, z)`/`endARStroke` are the
world-anchored twin: points are pushed in the world frame world tracking reports,
so a stroke stays fixed in the scene.

## Compositing

The camera is the base layer; register more RGBA sources and arrange them into a
split, grid, or picture-in-picture. Define a source, push frames into it, and
set the layout:

    session.defineSource("guest")
    session.submitSourceFrameRgba("guest", rgba, width, height, stride)
    session.setLayout(3)   // 0 custom, 1 side-by-side, 2 top-bottom, 3 pip, 4 grid, 5 overlay

`setSourceComposite` gives a source its own blend: opacity, a matte from its
alpha (key mode 1), or a chroma key against a color within a similarity
threshold (key mode 2); the name "camera" addresses the base:

    session.setSourceComposite("guest", opacity = 0.9f, keyMode = 2,
                               keyG = 1f, similarity = 0.3f)

`defineScreenShare` registers a source that letterboxes to fit its cell instead
of stretching. `removeSource` drops one, and `clearLayout` returns to the camera
alone.

## Capture and recording

`capturePhoto` renders the composited frame and returns it as PNG bytes,
deterministic - the same pixels give the same bytes - for a share sheet or a
saved still:

    val png = engine.capturePhoto(session) ?: return

`captureStill` is the high-resolution path: the frame at its own or a requested
size, encoded PNG, JPEG or HEIC, with a color-space tag and an optional 16-bit
PNG. `startRecording` opens an MP4 the renderer appends each rendered frame to,
effects baked in, until `stopRecording`:

    engine.startRecording(session, path, hevc = true)
    // render frames as usual...
    engine.stopRecording()

`GossRecordingPolicy` and `GossCaptureUi` from Camera controls carry the clip
cap, timer, night mode and the rest for your recorder and capture chrome; the
engine stores the intent and you read it back and apply it.

## Lives and calls

Publishing the lens-baked frames into a LiveKit or WebRTC call is a custom
video source fed one frame per tick. `captureLiveFrame` renders the composited
frame and returns it in a WebRTC format (BGRA by default), so you build a
`VideoFrame` for the source with no channel swizzle of your own:

    val frame = engine.captureLiveFrame(session, width, height) ?: return
    // wrap frame (BGRA, width x height) in a VideoFrame and hand it to the
    // custom VideoSource you publish; show the same frame locally too

It renders once per call, so a broadcast source needs no separate preview
render. For audio, `submitAudio` feeds the mic in so audio-reactive lenses
respond. For the outgoing track, `mixOutputAudio` folds the lens's own sound
into the mic block you are about to publish and hands back the mixed interleaved
s16 - the engine resamples the lens sound to your track's rate and sums it in,
so there is nothing to hand-mix (pass a null mic buffer for lens sound over
silence). `pullAudio` still pulls the lens sound alone for local playback with
no call; in a call, `mixOutputAudio` replaces it.

When the lens carries an `audio.infer` node with a caption binding, the engine
runs on-device ASR over the mic and `captionText` reads the decoded text by the
node's id, for the app to draw as a live subtitle:

    session.captionText("caption")?.let { subtitle.text = it }

## Method names

The operation names match the other SDKs: `GossEngine.create(config)`,
`GossSession.create(engine)`, `submitFrameCopy`, `renderFrame`. The full table
is in [API.md](API.md).
