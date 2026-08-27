# API

Gosslens has one C ABI and three public SDKs: Swift, Kotlin, and TypeScript.
The ABI is the engine contract. This file is the public SDK naming and shape
contract built on top of it.

The ABI is also consumable directly. [sdk/c](../sdk/c) packages
[include/gosslens.h](../include/gosslens.h) as a linkable library, so any
language with a C FFI reaches the engine through the `goss_*` functions as they
are spelled here. The C surface uses those names unchanged; the naming rules
below govern the wrappers that rename them for a host language.

A developer who learns one Gosslens SDK should not have to relearn the same
operation on another platform.

## Rule

Every public `goss_*` ABI operation has one canonical SDK operation name and
one canonical parameter shape before wrappers are implemented independently.
Swift, Kotlin, and TypeScript use that operation identity rather than inventing
platform-specific names for the same engine action.

A new ABI function and its public API contract land together. A wrapper must
not ship first and be reconciled later.

## Public types

Every public ABI operation belongs to one public construct.

| Construct | Spelled | Owns |
|---|---|---|
| bootstrap | `Gosslens` | ABI bootstrap and pure stateless helpers |
| engine | `GossEngine` | engine and render-surface lifecycle |
| capture output | `GossEngine` capture methods | screenshots, pixel readback, photo/video output |
| session | `GossSession` | frame submission, tracking, beauty, segmentation, runtime control |
| events | `GossSession` pull results | per-session state and pull-based results |
| lens registry | `GossSession` lens methods | lens activation, deactivation, and ticking |

Capture output, events, and lens registry flatten onto `GossEngine` and
`GossSession` where the SDK already does so; operation names and parameter
meaning do not change.

## Type spelling

Every concrete public type is spelled with a `Goss` prefix - `GossEngine`,
`GossSession`, `GossFaceResult`, `GossStatus`, and so on - so a type name never
collides with a host app's own `Session`, `Engine`, or `Frame`. The one
exception is the bootstrap namespace, which keeps the brand name `Gosslens`
because it never collides. TypeScript's top-level constants take a `GOSS_`
prefix for the same reason; Swift and Kotlin already scope theirs inside a type
or the `Gosslens` namespace. Method names, parameters, and value semantics do
not change with the spelling.

New media work does not automatically create new public types. If a new ABI
operation cannot fit this ontology cleanly, the type model is extended here
before any SDK exposes it.

## Naming

Use one verb for one class of operation.

| Form | Meaning |
|---|---|
| `create` / `destroy` | opaque-handle lifecycle |
| `init*` / `resize` | engine or surface setup |
| `render*` | render/advance a frame |
| `request*` | deferred operation whose result arrives later |
| `capture*` | capture/read data now |
| `submit*` | submit a frame to the engine pipeline |
| `track*` | submit work to tracking |
| `enable*` / `disable*` | binary capability state |
| `activate*` / `deactivate*` | swappable lens/content lifecycle |
| `set*` | synchronous state/parameter update |
| `load*` | I/O convenience that resolves into a canonical `set*` operation |
| `tick*` | advance a time-driven subsystem |
| `report*` | one-way telemetry input |
| bare noun | pure non-boolean query |
| `is*` / `has*` | pure boolean query |
| source-to-target name | pure stateless conversion, such as `yuvToRgb` |

Do not add `get*` merely because one language commonly uses it. Pure state
queries use the rules above.

A boolean returned from an action still uses the action name. For example,
`enableBeauty()` does not become `isBeautyEnabled()` merely because the ABI
returns success/failure.

## Async shape

The operation name stays the same even when platform-native async syntax
differs.

Operations with real I/O or GPU-readback latency may use:

- TypeScript: `Promise<T>`
- Swift: `async throws -> T`
- Kotlin: `suspend fun`

Pure engine operations stay synchronous unless the underlying contract itself
changes.

## Platform idioms

Two narrow exceptions are allowed.

1. Kotlin may expose `destroy()` as `close()` when the type implements
   `AutoCloseable` and participates in `use {}`. The lifecycle semantics must
   remain identical.
2. Swift may elide the first argument label when Swift API conventions require
   it. The base method name and every remaining parameter name stay canonical.

These are language-shape exceptions, not permission to rename operations.

## Future SDKs

The canonical operation identity is language-neutral even though the current
canonical spelling is camelCase.

- camelCase languages copy the name literally.
- snake_case languages mechanically convert camelCase to snake_case.
- PascalCase APIs mechanically uppercase the first character while preserving
  the remaining word boundaries.

Parameter names transform by the same mechanical rule. A new SDK does not
reopen naming decisions.

## Canonical operations

The table below is the tracked public contract. `include/gosslens.h` and this
file must move together.

### Gosslens

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_abi_version` | `Gosslens.abiVersion()` | all SDKs |
| `goss_color_yuv_to_rgb` | `Gosslens.yuvToRgb(colorStandard, colorRange)`, returning the conversion matrix | all SDKs |
| `goss_solve_two_bone_ik` | `Gosslens.solveTwoBoneIk(root, upperLen, lowerLen, target, pole)`, analytic two-bone IK returning the mid joint and end positions; an out-of-reach target extends the limb straight at it | all SDKs |
| `goss_alloc` | ABI buffer plumbing for the wasm boundary; no public SDK operation | web internal |
| `goss_free` | ABI buffer plumbing for the wasm boundary; no public SDK operation | web internal |

### GossEngine

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_engine_create` | `GossEngine.create(config)` | all SDKs |
| `goss_engine_destroy` | `destroy()`; Kotlin may use `close()` | all SDKs |
| `goss_engine_init_renderer` | `initRenderer(surface, width, height)` | all SDKs |
| `goss_engine_resize` | `resize(width, height)` | all SDKs |
| `goss_engine_render_frame` | `renderFrame(session)` | all SDKs |

### CaptureOutput

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_engine_request_screenshot` | `requestScreenshot(path)` | debug/test where supported |
| `goss_engine_capture_frame` | `captureFrame()`, returning pixels plus the renderer's real width and height | supported SDKs |
| `goss_engine_capture_live_frame` | `captureLiveFrame(format)`, the supported per-frame composited output for a live broadcast source, in a WebRTC format (RGBA8, BGRA8, or NV12 for a hardware encoder) with no consumer conversion | supported SDKs |
| `goss_engine_render_to_live_texture` | `renderToLiveTexture(session, texture, width, height)`, the zero-copy live output rendering the composite straight into a caller's external texture; Swift's `GossLiveOutput` wraps it with a pixel-buffer pool | Apple (Metal) |
| `goss_engine_capture_photo` | `capturePhoto()`, returning deterministic PNG bytes of the composited frame, sized by a probe call | supported SDKs |
| `goss_engine_capture_photo_as` | `capturePhoto(as:quality:)`, JPEG from the engine's own encoder on every target, HEIC from the platform | all SDKs for JPEG; HEIC where the platform backend exists |
| `goss_engine_capture_still` | `captureStill(session, config)`, the composited still at its own or a requested resolution, decoupled from the preview swap chain, optionally supersampled (rendered larger then box-downsampled) for photo-grade edges; a still past the GPU's texture-size ceiling is composited in tiles and stitched. The config also carries the color space (sRGB, Display-P3, Rec2020 - tagged as PNG cHRM/gAMA or a JPEG ICC) and the bit depth (8, or a 16-bit PNG container) | all SDKs (web reaches the wasm core; the pure WebGL path has no core encoder) |
| `goss_engine_recording_start` | `startRecording(session, path, config)`, appending one video frame per rendered frame with effects baked in | Swift and Kotlin |
| `goss_engine_recording_stop` | `stopRecording()`, flushing in-flight frames and finalizing the file | same |
| `goss_session_submit_audio` | `submitAudio(session, samples, frameCount, sampleRate, channels, timestampUs)`, feeding level and beat triggers always and the recording's audio track where the backend muxes audio | Swift and Kotlin |
| `goss_session_submit_world` | `submitWorld(session, state, planes, anchors, light)`, feeding the tracking-state trigger and world-anchored content | Swift GossWorldSource on ARKit, the ARCore demo feeder, and the web SDK's GossWebXRWorldSource |

### GossSession lifecycle

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_create` | `GossSession.create(engine, config)` | all SDKs |
| `goss_session_destroy` | `destroy()`; Kotlin may use `close()` | all SDKs |

### Frame submission

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_submit_frame` | `submitFrame(desc, planes)` | native zero-copy-capable SDKs |
| `goss_session_submit_frame_copy` | `submitFrameCopy(y, yStride, uv, uvStride, width, height, rotationDegrees, mirrored, colorStandard, colorRange, timestampUs)` | platforms that expose this copy path |
| `goss_session_submit_hardware_buffer` | `submitHardwareBuffer(buffer, width, height, rotationDegrees, mirrored, timestampUs)` | Android |
| `goss_session_submit_frame_rgba_copy` | `submitFrameRgbaCopy(rgba, stride, width, height, pixelFormat, rotationDegrees, mirrored, timestampUs)` | copy-path SDKs |

### Events and degradation

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_report_frame` | `reportFrame(frameTimeUs, thermal)` | all SDKs |
| `goss_session_degrade_level` | `degradeLevel()` | all SDKs |

### Face tracking

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_enable_face_tracking` | `enableFaceTracking(taskBundle, threads)` | native tracking path |
| `goss_session_disable_face_tracking` | `disableFaceTracking()` | native tracking path |
| `goss_session_enable_hand_tracking` | `enableHandTracking(taskBundle, threads)` | native tracking path |
| `goss_session_disable_hand_tracking` | `disableHandTracking()` | native tracking path |
| `goss_session_enable_pose_tracking` | `enablePoseTracking(taskBundle, threads)` | native tracking path |
| `goss_session_disable_pose_tracking` | `disablePoseTracking()` | native tracking path |
| `goss_session_set_pose_upper_body` | `setPoseUpperBody(enabled)`, upper-body mode; the tracked pose reports only the upper body, the lower-body joints (knees down) read absent | native tracking path |
| `goss_session_track_frame` | `trackFrame(y, yStride, uv, uvStride, width, height, colorStandard, colorRange, timestampUs)`; feeds every enabled tracking worker | native tracking path |
| `goss_session_face_result` | `faceResult(result)` | native tracking path |
| `goss_session_hand_result` | `handResult(result)` | native tracking path |
| `goss_session_hand_joint` | `handJoint(joint, handIndex)`, the handIndex-th tracked hand's named joint point (x, y in frame pixels, z in the same scale) so a lens pins content to a fingertip or the wrist; see the `GOSS_HAND_JOINT_*` points (palm is the middle knuckle) | native tracking path |
| `goss_session_pose_result` | `poseResult(result)` | native tracking path |
| `goss_session_body_joint` | `bodyJoint(joint)`, the tracked body's named skeleton joint point (x, y in frame pixels, z in the same scale) so a lens pins content to a shoulder, a wrist, or a knee; see the `GOSS_BODY_JOINT_*` points (head, left/right shoulder, elbow, wrist, hip, knee, ankle) | native tracking path |
| `goss_session_face_pose` | `facePose(matrix)`, filling a caller-owned 16-float column-major array | native tracking path |
| `goss_session_submit_faces` | `submitFaces(faces, count)`, submits the faces tracked this frame for the multi-face path; count past `GOSS_FACE_MAX` clamps, zero clears back to the single tracker, and a face-anchored model fans out to every submitted face | native tracking path |
| `goss_session_face_count` | `faceCount()`, how many faces the last `submitFaces` kept, zero to `GOSS_FACE_MAX`; zero also means no multi-face path this frame | native tracking path |
| `goss_session_face_result_at` | `faceResultAt(index, result)`, reads the index-th submitted face; a caller loops zero to the count to visit every face | native tracking path |
| `goss_session_submit_bodies` | `submitBodies(bodies, count)`, submits the bodies tracked this frame for the multi-person path; count past `GOSS_BODY_MAX` clamps, zero clears the path, and a body below the tracked presence or with no landmarks drops | native tracking path |
| `goss_session_body_count` | `bodyCount()`, how many bodies the last `submitBodies` kept, zero to `GOSS_BODY_MAX` | native tracking path |
| `goss_session_body_result_at` | `bodyResultAt(index, result)`, reads the index-th submitted body; a caller loops zero to the count to visit every body | native tracking path |
| `goss_session_submit_depth` | `submitDepth(depth, width, height, near, far)`, submits one frame's depth map (metres per pixel, row major) from the host AR backend (ARKit scene depth, ARCore Depth API, WebXR depth-sensing); an empty map clears it, kept for depth occlusion | native + web depth path |
| `goss_session_submit_segmentation_image` | `submitSegmentationImage(rgba, width, height)`, segments a host-provided still RGBA image (row major) through the running segmenter, so a gallery photo gets a mask without a camera frame; again with no segmenter enabled | native + web segmentation |
| `goss_session_face_region` | `faceRegion(region, outXyz)`, the newest tracked face's named attach point (x, y in frame pixels, z in the same scale) so a lens pins content to the forehead, glabella, nose tip, chin, an eye, a cheek, an ear, or the mouth centre/corner; see the `GOSS_FACE_REGION_*` points | native tracking path |
| `goss_session_set_face_landmarks` | `setFaceLandmarks(points)`; web adds `sourceWidth, sourceHeight` since its analysis resolution is decoupled from the rendered frame's | Web analysis-producer path |
| `goss_session_set_segmentation_mask` | `setSegmentationMask(mask)`, a mask_side x mask_side float mask the web tracking module produced, uploaded as the subject texture | Web analysis-producer path |
| `goss_session_segmentation_channels` | `segmentationChannels()`, a bitmask over the mask channels the active lens samples | Web analysis-producer path |
| `goss_session_set_segmentation_class_mask` | `setSegmentationClassMask(channel, mask)`, one class channel's mask uploaded as the texture that channel's passes sample | Web analysis-producer path |

### Segmentation

`goss_session_enable_segmentation` exists at the ABI level, but its public
parameter contract is not frozen yet. **No SDK may invent and ship a public
`enableSegmentation(...)` signature until this section is updated with the
complete parameter list.**

The in-engine core reads each model's own tensor dimensions, so the bytes
handed to it can be any square RGB segmenter with any output resolution and
up to 32 classes. It resamples the model's native mask onto the canonical
`mask_side x mask_side` grid, covering the portrait segmenters and scene
segmenters like the 21-class deeplab model alike. `segmentationChannels()`
then reports the loaded model's class count.

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_enable_segmentation` | `enableSegmentation(...)` (reserved, parameters not yet frozen) | pending contract |
| `goss_session_disable_segmentation` | `disableSegmentation()` | all SDKs once exposed |

### Beauty

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_enable_beauty` | `enableBeauty(resourceDir)` | supported SDKs |
| `goss_session_disable_beauty` | `disableBeauty()` | supported SDKs |
| `goss_session_set_beauty` | `setBeauty(effect, amount)` | supported SDKs |
| convenience | `setWhiten(amount)` | supported SDKs |
| convenience | `setSmooth(amount)` | supported SDKs |
| convenience | `setThinFace(amount)` | supported SDKs |
| convenience | `setBigEye(amount)` | supported SDKs |
| convenience | `setLipstick(amount)` | supported SDKs |
| convenience | `setBlush(amount)` | supported SDKs |
| `goss_session_set_beauty_lut` | `setBeautyLut(slot, rgba, width, height)` | Web ABI path; `loadWhitenLuts(url)` may exist as I/O sugar |
| `goss_session_set_beauty_makeup_texture` | `setBeautyMakeupTexture(effect, rgba, width, height)` | Web ABI path; `loadMakeupTextures(url)` may exist as I/O sugar |
| `goss_session_beautify_frame` | `beautifyFrame(rgbaIn, rgbaOut, width, height)` | supported SDKs |

### LensRegistry

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_activate_lens` | `activateLens(manifestJson)` | all SDKs |
| `goss_session_activate_lens_from_directory` | `activateLensFromDirectory(bundlePath)` | native SDKs |
| `goss_session_deactivate_lens` | `deactivateLens()` | all SDKs |
| `goss_session_tick_lens` | `tickLens(dtUs, signals)` | all SDKs |
| `goss_session_fire_event` | `fireEvent(name)`, fires a named event the next `tickLens` delivers to the lens's `event('name')` triggers for exactly one tick, then clears - drives an on-screen effect from an app-level moment (a reaction, an arriving gift); the engine knows the name, never its meaning. Buffered without allocation | all SDKs |
| `goss_session_define_source` / `_remove_source` | `defineSource(name)` / `removeSource(name)`, register or drop a named RGBA source for multi-source composition; the camera is the implicit source 0 | all SDKs |
| `goss_session_submit_source_frame_rgba_copy` | `submitSourceFrame(name, rgba, ...)`, uploads one RGBA/BGRA frame into a named source's own texture | all SDKs |
| `goss_session_set_layout` / `_clear_layout` | `setLayout(arrangement)` / `clearLayout()`, composites the camera and named sources side-by-side, top-bottom, picture-in-picture, or in a grid (Duet, Stitch, live grids); clear returns to a single camera | all SDKs |
| `goss_session_set_source_composite` | `setSourceComposite(name, opacity, keyMode, keyR, keyG, keyB, similarity)`, a per-source blend: opacity, `keyMode` 1 mattes from source alpha, 2 chroma-keys against (keyR,keyG,keyB) within a similarity threshold; the name "camera" addresses the base | all SDKs |
| `goss_session_define_screen_share` | `defineScreenShare(name)`, a source that letterboxes to fit its cell instead of stretching | all SDKs |
| `goss_session_submit_location` | `submitLocation(lat, lon, accuracy, ts)`, feeds a location fix; the engine computes `geo.in_region` on-device and the location never crosses back over the ABI | all SDKs |
| `goss_session_set_geofence` / `_clear_geofence` | `setGeofence(lat, lon, radius)` / `clearGeofence()`, sets the circle a geofilter lens is active within, derived by the app from the lens's intended place | all SDKs |
| `goss_session_set_geofence_bbox` / `_set_geofence_polygon` | `setGeofenceBbox(minLat, minLon, maxLat, maxLon)` / `setGeofencePolygon(coords, vertexCount)`, an axis-aligned box or a polygon ring (three to 64 lat/lon vertices) the geofilter lens is active within | all SDKs |
| `goss_session_set_geo_accuracy` | `setGeoAccuracy(maxAccuracyM)`, refuses a fix vaguer than this so a lens does not fire on an uncertain location; zero clears the gate | all SDKs |
| `goss_session_parameter_value` | `parameterValue(name)`, reads a live lens parameter by name, including whatever a script node last wrote | all SDKs |
| `goss_session_pull_audio` | `pullAudio(out, frames)`, the next block of mixed lens audio (interleaved s16) a play_sound trigger produced, for the SDK to route to platform audio out; silence when no lens sound is active | all SDKs |
| `goss_session_mix_output_audio` | `mixOutputAudio(mic, frameCount, sampleRate, channels)`, folds the lens sound into the caller's outgoing call/live audio track and returns the mixed interleaved s16 - the lens mixer's 48 kHz mono resampled to the track's rate and summed with saturation into every channel; a null mic mixes the lens sound over silence. Advances the lens mixer once, so it replaces `pullAudio` on the call path | all SDKs |

### Capture controls

Declarative hardware and chrome intent the engine validates, normalizes, and
stores; the SDK reads it back and drives the platform camera, recorder, and
capture UI. The engine never touches camera hardware.

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_set_camera_controls` | `setCameraControls(controls)`, stores camera-hardware intent (flash/torch, focus mode + point, exposure mode + bias, zoom, mirror-save policy) after the engine validates and normalizes every field | all SDKs |
| `goss_session_camera_controls` | `cameraControls()`, reads the normalized controls back for the SDK to apply to AVFoundation / CameraX / getUserMedia | all SDKs |
| `goss_session_set_recording_policy` | `setRecordingPolicy(policy)`, stores how the SDK should record (clip cap, min clip, single/multi-clip segments, loop, speed preset, mic mute, save-original, stabilization); the engine never drives the recorder | all SDKs |
| `goss_session_recording_policy` | `recordingPolicy()`, reads the normalized policy back for the SDK to apply to the platform recorder | all SDKs |
| `goss_session_set_capture_ui` | `setCaptureUi(ui)`, stores the capture chrome the app draws (grid, level, shutter mode, self-timer, night mode, front-screen flash); the front-screen flash is a fill the app draws, never baked into the captured frame | all SDKs |
| `goss_session_capture_ui` | `captureUi()`, reads the normalized capture-UI intent back | all SDKs |

### Brush

Screen and world-anchored freehand drawing. The engine owns stroke state and
the undo/redo stacks; the app feeds points and pulls the finished triangle
ribbon for the renderer to draw.

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_brush_set_style` | `brushSetStyle(r, g, b, a, width)`, colour and width for the next stroke | all SDKs |
| `goss_session_brush_set_mode` | `brushSetMode(mode)`, preset for the next stroke: 0 pen, 1 highlighter, 2 marker, 3 neon (additive) | all SDKs |
| `goss_session_brush_begin` / `_point` / `_end` | `brushBegin()` / `brushPoint(x, y)` / `brushEnd()`, a stroke in normalized screen space | all SDKs |
| `goss_session_brush_undo` / `_redo` / `_clear` | `brushUndo()` / `brushRedo()` / `brushClear()`, the stroke stacks | all SDKs |
| `goss_session_brush_erase_at` | `brushEraseAt(x, y, radius)`, removes committed strokes within radius of a point (refused mid-stroke), returning the count | all SDKs |
| `goss_session_brush_vertices` | `brushVertices(out, capacityFloats)`, pulls the triangle ribbon (x, y, r, g, b, a per vertex); a null out reports the float count to size for | all SDKs |
| `goss_session_ar_brush_set_style` / `_set_mode` | `arBrushSetStyle(r, g, b, a, width)` / `arBrushSetMode(mode)`, the world-anchored brush's style and preset | world-tracking SDKs |
| `goss_session_ar_brush_begin` / `_point` / `_end` | `arBrushBegin()` / `arBrushPoint(x, y, z)` / `arBrushEnd()`, a stroke in the world frame the platform reports poses in; nothing draws without live world tracking | world-tracking SDKs |
| `goss_session_ar_brush_undo` / `_clear` | `arBrushUndo()` / `arBrushClear()`, the world-brush stacks | world-tracking SDKs |
| `goss_session_grab` / `_release` | `grab(x, y, z)` grabs the nearest dynamic physics body to a world point and drags it there, driving it kinematically so it gathers throw velocity; `release()` lets it fly off dynamic again | all SDKs |
| `goss_session_add_collider` / `_erase_collider` | `addCollider(x, y, z)` drops a static sphere collider at a world point that content lands on live; `eraseCollider(x, y, z, radius)` removes every live collider within radius - drawing and erasing a 2D collider world | all SDKs |

## Web tracking module

The web SDK's face tracking runs in a separate wasm module
(`gosslens_tracking.wasm`, built by `zig build tracking-wasm`), not through
the frozen C ABI - wasm has no threads here, so the main engine module
can't host the tracking worker the native targets run in-process. Its
exports are their own small contract, wrapped only by the web SDK's
`FaceTracker`:

| Export | Contract |
|---|---|
| `goss_tracking_alloc(size)` / `goss_tracking_free(ptr, size)` | module-heap staging for the buffers below |
| `goss_tracking_result_size()` | byte size of the result struct, `goss_face_result`'s frozen layout |
| `goss_tracking_create(taskPtr, taskLen)` | instance from task-bundle bytes; zero on rejection |
| `goss_tracking_destroy(instance)` | releases the instance |
| `goss_tracking_process(instance, rgba, width, height, timestampUs)` | synchronous inference over one RGBA frame; nonzero refuses the frame |
| `goss_tracking_result(instance, out)` | copies the newest published result; nonzero until one exists |

These names stay `goss_tracking_*`, never gain platform variants, and a
change here is an ABI change with the same review bar as
`include/gosslens.h`.

## Media additions

GossMedia follows the same rule. A new encoder, decoder, muxer, demuxer,
recording, import, metadata, audio, or capture-output ABI function is not
special because it is new infrastructure.

Before an SDK wrapper lands:

1. the `goss_*` ABI operation exists in `include/gosslens.h`;
2. its owning public type is settled;
3. its canonical operation name and full parameter shape are added here;
4. platform scope and capability/degradation behavior are stated;
5. Swift, Kotlin, and TypeScript implementations use that contract.

Do not expose vendor vocabulary such as FFmpeg/libav contexts, codec-library
handles, VideoToolbox objects, `MediaCodec` objects, WebCodecs objects, or
vendor packet/frame types in this contract.

## Gate

CI should mechanically compare the public ABI function list against this
contract and reject a new public `goss_*` operation with no API entry.
SDK wrapper lint should compare each wrapper's operation name and parameter
shape against this file.

An API mismatch is a failed change, not an SDK-specific style preference.
