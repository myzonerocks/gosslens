<div align="center">

# Gosslens

**A camera and AR engine you add to your app in one line.**
Beauty, tracking, lenses, world anchoring, and capture - every frame on the device.

[![gates](https://github.com/myzonerocks/gosslens/actions/workflows/gates.yml/badge.svg)](https://github.com/myzonerocks/gosslens/actions/workflows/gates.yml)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE.md)
[![platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android%20%7C%20Web-informational.svg)](#sdks)
[![on device](https://img.shields.io/badge/runs-100%25%20on%20device-success.svg)](#on-device)

[Install](#install) &nbsp;&middot;&nbsp; [What you get](#what-you-get) &nbsp;&middot;&nbsp; [SDKs](#sdks) &nbsp;&middot;&nbsp; [Contributing](CONTRIBUTING.md)

</div>

Add one dependency, write Swift, Kotlin, or TypeScript, and your app has the
camera surface people expect: beauty and makeup, face, hand, and body tracking,
segmentation, world anchoring, scripted and physics-driven lenses, and capture.
The engine ships prebuilt inside each SDK, so there is no toolchain to install,
and nothing a camera sees ever leaves the device.

## Install

Each SDK carries the compiled engine as a native artifact - a `.so`, an
XCFramework, a `.wasm` - so you add a coordinate and never run a build step.

**iOS - Swift**

```swift
// Package.swift
.package(url: "https://github.com/myzonerocks/gosslens", from: "X.Y.Z")
```

**Android - Kotlin**

```kotlin
// build.gradle.kts
implementation("io.github.avosa:gosslens:X.Y.Z")
```

**Web - TypeScript**

```sh
bun add @myzonerocks/gosslens
```

Set `X.Y.Z` to the latest [release](https://github.com/myzonerocks/gosslens/releases).
Then wire the render loop with the integration guide for your platform:
[iOS](docs/INTEGRATION-iOS.md), [Android](docs/INTEGRATION-ANDROID.md),
[Web](docs/INTEGRATION-WEB.md).

## What you get

- **Beauty and makeup** - smooth, whiten, reshape, lipstick, and blush, each a live 0-to-1 control.
- **Tracking** - multi-face, hands with gestures, and full-body pose, plus selfie segmentation for virtual backgrounds.
- **Lenses** - the `.glens` format: scripted triggers, shader passes, glTF models, and physics, authored once and run on every platform.
- **World and AR** - anchor content in space from ARKit, ARCore, or WebXR frames, and raycast a tap onto a scanned world mesh.
- **Capture** - photos, video, and multi-source compositing through each platform's native media APIs.

Every capability ships on all three platforms or it does not ship. The proof
table is [docs/PARITY.md](docs/PARITY.md).

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
