# Android demo

> [!TIP]
> Building your own app? You don't need any of this. Add
> `io.github.avosa:gosslens` and follow the
> [Kotlin SDK README](../README.md) - no Zig,
> no NDK. This is an in-repo reference that builds the engine from the checkout
> so it always matches the SDK source.

An Activity with a live front-camera preview through the real ABI - CameraX
capture, zero-copy into a GLES-backed renderer via AHardwareBuffer, with the
copy path as the fallback. Layered over the preview are the shared showcase
controls:

- Beauty sliders: smooth, whiten, thin face, big eye, lipstick, blush, each 0 to
  1 driving the effect live.
- Tracking overlays with a show/hide toggle: face landmark dots and a distinct
  nose-tip marker, hand landmark dots, and pose dots.
- A tracking readout: face present, the stable face track id, the hand gesture,
  and fps.
- A lens filter picker: None, Blur, Grade, Bloom, activated from inline lens
  manifests over the camera input.
- A virtual-background toggle: stands the in-engine selfie segmenter up and
  composites a background from the person mask. If the segmenter model is not
  present at runtime the toggle disables itself with a short note.
- A capture button that renders the composited frame to a PNG and shows it.
- A front/back camera switch. The front preview is always mirrored; the back is
  never mirrored.
- A status line: capture state, fps, and degrade level.

## Prerequisites

The engine ships as a native `.so` the app packages but does not build. Build it
first, from the repo root:

    zig build android

That writes `libgosslens.so` into `zig-out/android`, where the SDK's gradle
module picks it up as a jniLib. Without it the app compiles but has no engine to
load at runtime.

Point gradle at your Android SDK. `sdk/kotlin/local.properties` holds one line:

    sdk.dir=/Users/you/Library/Android/sdk

## How the demo consumes the SDK

The demo takes the Kotlin SDK from the local path, never a published artifact.
`settings.gradle.kts` includes the root project as `:`, and the demo depends on
it with `implementation(project(":"))`, so a change to the SDK sources is picked
up on the next build with nothing to publish.

## Assets and models

The model bundles and effect resources are synced into the app's assets at build
time by copy tasks in `demo/build.gradle.kts`, pulled from the repo's fetched
`.models` set and the pinned vendor tree:

- `face_landmarker.task`, `gesture_recognizer.task`, `pose_landmarker_full.task`
  for face, hand, and pose tracking.
- `selfie_segmenter.tflite` for the virtual background.
- the beauty engine's `res` shaders and lookups, and the `beauty-baseline`
  reference lens.
- `corpus/face_frontal_b.jpg` for conformance.

If a model is missing the sync leaves it out and the matching feature degrades
rather than failing.

## Run it

Boot an emulator or connect a device first (`emulator -avd <name>`, or plug in a
device with USB debugging on). This machine runs close to full disk and has 8GB
RAM - check headroom before booting an emulator.

From `sdk/kotlin`:

    ./gradlew :demo:installDebug
    adb shell am start -n com.gosslens.demo/com.gosslens.demo.MainActivity

Grant camera permission when the app asks. Captured photos are written under the
app's external files directory and shown over the preview until tapped away.

## Proving it

    ./demo/prove-emulator.sh

Builds, installs, and launches the app in conformance mode against whatever
emulator/device adb already sees, driving the same ABI path the live preview
runs. Emulator output is a dev signal only, never proof of on-device behavior -
the emulator's own GLES support is real but not every device's.
