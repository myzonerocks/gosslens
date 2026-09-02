<div align="center">

# Gosslens

**A camera and AR engine that runs real-time beauty, tracking and AR effects on
device, and lets any app or model draw into the live camera view.**

[![gates](https://github.com/myzonerocks/gosslens/actions/workflows/gates.yml/badge.svg)](https://github.com/myzonerocks/gosslens/actions/workflows/gates.yml)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE.md)
[![platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android%20%7C%20Web-informational.svg)](#sdks)
[![on device](https://img.shields.io/badge/runs-100%25%20on%20device-success.svg)](#on-device)

[Install](#install) &nbsp;&middot;&nbsp; [What you get](#what-you-get) &nbsp;&middot;&nbsp; [SDKs](#sdks) &nbsp;&middot;&nbsp; [Contributing](CONTRIBUTING.md)

</div>

Retouching and makeup, face, hand and body tracking, background removal, AR
effects, and capture, on iOS, Android and the web. It hands you each frame and
composites what you draw back, ships compiled, and makes no network calls.

## Install

iOS and Android carry the compiled engine inside the package - an XCFramework, a
`.so` - so you add a coordinate and never run a build step. On web you add the
wrapper and host the prebuilt wasm engine from the release. Either way there is
no toolchain.

**iOS - Swift**

In Xcode, File > Add Package Dependencies, and paste the repository URL:

```
https://github.com/myzonerocks/gosslens
```

Xcode fills in the newest release for you. In a `Package.swift`, ask for the
same thing by naming the oldest version you support; SwiftPM resolves forward
to the newest release on its own:

```swift
// Package.swift
.package(url: "https://github.com/myzonerocks/gosslens", from: "0.11.1")
```

**Android - Kotlin**

```kotlin
// build.gradle.kts
implementation("io.github.avosa:gosslens:0.11.1")
```

**Web - TypeScript**

```sh
bun add @myzonerocks/gosslens
```

Then wire the render loop with the guide for your platform:
[iOS](sdk/swift/README.md), [Android](sdk/kotlin/README.md), [Web](sdk/ts/README.md),
or the [C SDK](sdk/c/README.md) for any other language with a C FFI.

## What you get

- **Beauty and makeup** - smooth, whiten, reshape, lipstick, and blush, each a live 0-to-1 control.
- **Tracking** - multi-face, hands with gestures, and full-body pose, plus selfie segmentation for virtual backgrounds.
- **Lenses** - the `.glens` format: scripted triggers, shader passes, glTF models, and physics, authored once and run on every platform.
- **Your own models** - a lens bundles a TFLite or ONNX net and binds its outputs to parameters, masks, depth, or a drawn image; the host stages models in memory and reads tensors back.
- **World and AR** - anchor content in space from ARKit, ARCore, or WebXR frames, and raycast a tap onto a scanned world mesh.
- **Capture** - photos, video, and multi-source compositing through each platform's native media APIs.

Every capability targets all three platforms; [docs/PARITY.md](docs/PARITY.md)
is the honest table of what is proven where.

## SDKs

| SDK | For | Package |
|---|---|---|
| **Swift** | iOS | SwiftPM, a checksummed XCFramework |
| **Kotlin** | Android | Maven Central `io.github.avosa:gosslens` |
| **TypeScript** | Web | npm `@myzonerocks/gosslens` |
| **C** | any language with a C FFI | `libgosslens`, static and shared |

The platform SDKs are thin wrappers over the same C ABI and share one operation
contract, so an effect behaves identically everywhere. Full install and
render-loop steps live in each platform's guide above.

## On device

> [!NOTE]
> Everything runs on device. The engine makes no network calls and carries no
> analytics. A camera frame never leaves the process.

## License

Apache 2.0. See [LICENSE.md](LICENSE.md). Third-party components retain their own
licenses, recorded per component under `third_party/` and summarized in
[NOTICE.md](NOTICE.md).
