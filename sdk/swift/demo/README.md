# iOS demo

A UIKit app with a live camera preview through the real ABI - AVFoundation
capture, zero-copy into a Metal-backed renderer. It shows the full showcase
every platform carries: the front camera preview (always mirrored), beauty
sliders, face/hand/pose overlays with a show-hide toggle, a one-line tracking
readout, a lens filter picker, a virtual-background toggle, photo capture, and
the front/back switch.

## What it consumes

The app links the SDK from this repo, not a published package. `project.yml`
points at the local Swift package one level up:

    packages:
      Gosslens:
        path: ..

The `Gosslens` product carries the engine's whole `-l` list and the frameworks
it needs; the target inherits them by depending on the package. The only paths
the package cannot know stay in `project.yml`: the header search path and the
per-slice `LIBRARY_SEARCH_PATHS` that point at the static archives `zig build`
writes.

## Prerequisites

From the repo root, fetch the tracking models and build the static archives for
the slice you are running. The build writes `libgosslens.a` and the vendored
archives into `zig-out/ios` (device) or `zig-out/ios-simulator`, which the
`LIBRARY_SEARCH_PATHS` in `project.yml` already name:

    zig build fetch-models
    zig build ios -Dios-sdk="$(xcrun --sdk iphoneos --show-sdk-path)"

`fetch-models` verifies and unpacks the resources the demo bundles: the
`face_landmarker.task`, `gesture_recognizer.task`, and `pose_landmarker_full.task`
tracking bundles, the `selfie_segmenter.tflite` the virtual background needs, the
`beauty-baseline`, `background-swap`, and `shader-tint` lens folders, and the
`gpupixel` beauty resources. Every one is an optional resource in `project.yml`,
so a missing file drops that one feature (the beauty context, a tracker, or the
virtual background) rather than breaking the build. The virtual-background toggle
disables itself with a short note when the selfie model is absent.

## Run on a device

From `sdk/swift/demo`:

    xcodegen generate
    open GosslensDemo.xcodeproj

Pick your connected iPhone as the run destination and hit Run. Signing is
automatic (team 9ZCMLRAW4V) once your Apple ID is added under Xcode Settings >
Accounts - a free personal team is enough for a dev install. Re-run `xcodegen
generate` after any change to `project.yml`.

## Run in the Simulator

Build the simulator slice instead, then generate and open the same way:

    zig build ios-simulator -Dios-simulator-sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    cd sdk/swift/demo
    xcodegen generate
    open GosslensDemo.xcodeproj

The Simulator has no real camera and no GLES-backed beauty context, so this
proves capture plumbing and tracking, not beauty effects - a known Simulator
limitation, not a bug (bgfx, tracking, and lens activation all report success;
beauty correctly reports unsupported). The Simulator's own synthetic camera feed
can also die mid-session (`FigCaptureSourceSimulator`/`FigCaptureSessionSimulator`
errors, capture state flips to failed after rendering fine for a while) - also a
Simulator-side limitation, not a regression. Simulator output is a dev signal
only, never proof of on-device behavior.

## Proving it

    ./prove-simulator.sh

Builds, installs, and launches the app in conformance mode (the `-GossConformance`
launch argument, handled by `ConformanceRunner`) on a real Simulator, driving the
same ABI path the live preview runs and checking the reported determinism proof.
