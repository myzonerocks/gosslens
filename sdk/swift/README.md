# Gosslens - Swift SDK

Swift SDK for [Gosslens](../../include/gosslens.h), a camera engine behind one
C ABI. Wraps it as `GossEngine`, `GossSession`, and `Gosslens`, the same names
the [Kotlin](../kotlin/README.md) and [TypeScript](../ts/README.md) SDKs use.

This SDK owns capture ingress, GPU surface handoff, and platform
tracking. The frame graph, lens runtime, and effect pipeline live in the
core.

[docs/INTEGRATION-iOS.md](../../docs/INTEGRATION-iOS.md) is the start-to-finish
guide: add the SwiftPM package, `import Gosslens`, and the minimal render loop.

## Install

Add the SwiftPM package. Each release attaches a checksummed XCFramework and
pins `Package.swift` to it, so there is no Zig and no build step:

```swift
.package(url: "https://github.com/myzonerocks/gosslens", from: "X.Y.Z"),
```

```swift
.product(name: "Gosslens", package: "gosslens"),
```

Set `X.Y.Z` to a released version like `0.9.0`; the latest is on the
[releases page](https://github.com/myzonerocks/gosslens/releases).

<details>
<summary>Against your own checkout (engine maintainers)</summary>

Point SwiftPM at the local package and build the slices first with
`zig build ios` / `ios-simulator`:

```swift
.package(path: "../gosslens"),
```

</details>

## Use

```swift
let engine = try GossEngine.create()
try engine.initRenderer(surface: metalLayer, width: width, height: height)

let session = try GossSession.create(engine: engine)
try session.enableBeauty(resourceDir: Bundle.main.bundlePath)

let desc = GossFrameDesc(
    width: width, height: height, pixelFormat: .nv12,
    rotationDegrees: 90, timestampUs: timestampUs
)
try session.submitFrame(desc: desc, planes: [yPlaneHandle, uvPlaneHandle])
try engine.renderFrame(session: session)

try session.setWhiten(0.6)
try session.activateLens(manifestJson: manifestData)
```

`submitFrame` wraps platform texture handles; `submitFrameCopy` is the
CPU fallback.

Capture, recording, and world tracking hang off the same engine and
session:

```swift
let photo = try engine.capturePhoto(session: session)             // preview-res PNG
let still = try engine.captureStill(session: session,             // full-res, supersampled
    config: GossEngine.StillConfig(width: 8064, height: 6048, supersample: 2))
let wide = try engine.captureStill(session: session,             // Display-P3, 16-bit PNG
    config: GossEngine.StillConfig(colorSpace: .displayP3, bitDepth: 16))
let jpeg = try engine.capturePhoto(session: session, as: .jpeg, quality: 92)

try engine.startRecording(session: session, path: outPath, hevc: true)
try engine.submitAudio(session: session, samples: pcm, frameCount: n,
                       sampleRate: 48000, channels: 1, timestampUs: ts)
try engine.stopRecording()

let world = GossWorldSource(session: session)   // ARKit, an ARSessionDelegate
arSession.delegate = world
world.start()
```

The full cross-platform capability tour is in the
[root README](../../README.md#what-you-get).

## Demo app

[`demo/`](demo/) is a real iOS app; see [`demo/README.md`](demo/README.md).

## Tests

Conformance runs through the demo app's `-GossConformance` launch argument and
[`harness/`](../../harness/).
