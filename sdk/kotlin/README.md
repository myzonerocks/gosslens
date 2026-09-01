# Gosslens - Kotlin SDK

Kotlin SDK for [Gosslens](../../include/gosslens.h), a camera engine behind one
C ABI. Wraps it as `GossEngine`, `GossSession`, and `Gosslens`, the same names
the [Swift](../swift/README.md) and [TypeScript](../ts/README.md) SDKs use.

This SDK owns capture ingress, GPU surface handoff, and platform
tracking. The frame graph, lens runtime, and effect pipeline live in the
core.

[docs/INTEGRATION-ANDROID.md](../../docs/INTEGRATION-ANDROID.md) is the
start-to-finish guide: add the coordinate and run the minimal render loop.

## Install

Add the Maven Central coordinate. The AAR carries the prebuilt `.so`, so there
is no Zig and no NDK:

```kotlin
dependencies {
    implementation("io.github.avosa:gosslens:X.Y.Z")
}
```

Set `X.Y.Z` to a released version like `0.9.0`; the latest is on the
[releases page](https://github.com/myzonerocks/gosslens/releases).

<details>
<summary>JitPack, or a local checkout (engine maintainers)</summary>

[JitPack](https://jitpack.io) builds the AAR from a tag (heavier, from source):

```kotlin
repositories { maven { url = uri("https://jitpack.io") } }
dependencies {
    implementation("com.github.myzonerocks:gosslens:vX.Y.Z")
}
```

Against your own checkout, after `zig build android`:

```kotlin
dependencies {
    implementation(project(":"))
}
```

</details>

## Use

```kotlin
val engine = GossEngine.create()
engine.initRenderer(surface, width, height)

val session = GossSession.create(engine)
session.enableBeauty(resourceDir)

session.submitFrameCopy(yBuffer, yStride, uvBuffer, uvStride, width, height, rotationDegrees = 90, mirrored = false, timestampUs = timestampUs)
engine.renderFrame(session)

session.setWhiten(0.6f)
session.activateLens(manifestJson)
```

`submitHardwareBuffer` is the zero-copy path for an `AHardwareBuffer`;
any non-OK status falls back to `submitFrameCopy`.

Photo capture, recording, and audio hang off the same engine and session:

```kotlin
val png: ByteArray? = engine.capturePhoto(session)

engine.startRecording(session, outPath, hevc = true)
engine.submitAudio(session, pcm, frameCount, sampleRate = 48000, channels = 1, timestampUs)
engine.stopRecording()
```

World tracking feeds ARCore frames in through the demo's
[`WorldFeeder`](demo/src/main/kotlin/com/gosslens/demo/WorldFeeder.kt).
Full-resolution stills and platform photo formats are iOS-first for now;
see [docs/PARITY.md](../../docs/PARITY.md). The full cross-platform
capability tour is in the [root README](../../README.md#what-you-get).

## Demo app

[`demo/`](demo/) is a real Android app; see [`demo/README.md`](demo/README.md).

## Tests

Conformance runs through the demo app's `ConformanceRunner` and
[`harness/`](../../harness/).
