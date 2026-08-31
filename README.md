<div align="center">

# Gosslens

**An open camera and AR engine with a Zig core and one C ABI, wrapped by Swift, Kotlin, TypeScript, and C SDKs.**

[![gates](https://github.com/myzonerocks/gosslens/actions/workflows/gates.yml/badge.svg)](https://github.com/myzonerocks/gosslens/actions/workflows/gates.yml)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE.md)
[![platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android%20%7C%20Web%20%7C%20C-informational.svg)](#sdks)
[![on device](https://img.shields.io/badge/runs-100%25%20on%20device-success.svg)](#gosslens)

</div>

The core owns the frame graph, the lens runtime, the effect pipeline, tracking,
and the portable media contract behind a single C ABI. The platform SDKs own
capture, GPU surfaces, native hardware media APIs, and platform tracking, and
nothing else.

The goal is the full surface a modern camera app expects: beauty and makeup,
multi-face, hand, and body tracking, segmentation, world anchoring, scripted and
physics-driven lenses, glTF model rendering, a deterministic audio mixer,
multi-source compositing and screen-share, camera controls, geofilters, on-frame
drawing, and capture output. All of it on device, with no lock-in. The build
order lives in [docs/ROADMAP.md](docs/ROADMAP.md).

> [!NOTE]
> Everything runs on device. The core makes no network calls and carries no
> analytics. A camera frame never leaves the process.

## Layout

```text
build.zig  build.zig.zon    one build system for Zig, C, and C++, all targets
.zigversion                 the pinned Zig version
include/gosslens.h          the C ABI
core/                       frame graph, lens runtime, tracking, media, math
adapters/                   native/vendor backends behind engine boundaries
sdk/                        c, swift, kotlin, ts packages and demo apps
lenses/                     the .glens format: spec, validator, reference lenses
harness/                    headless conformance runner
third_party/                pinned vendor dependencies
tools/                      toolchain bootstrap and the source gate
```

The checked-out layout is authoritative. Existing subsystems stay where they
are; new work extends the nearest existing boundary.

The public architecture and dependency-license contract live in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The canonical SDK naming and
parameter contract lives in [docs/API.md](docs/API.md). The lens file format,
published as a forkable standard, is [docs/LENS-FORMAT.md](docs/LENS-FORMAT.md).

## Building

```sh
tools/toolchain-sync
zig build test
zig build gate -- --tree
```

`toolchain-sync` installs the pinned Zig into `.local/zig` and wires the git
hooks. `build.zig` refuses any other compiler, so the toolchain question has
exactly one answer. Toolchain decisions are logged in
[docs/TOOLCHAIN.md](docs/TOOLCHAIN.md). The full set of local tools, from the
on-screen harness and the conformance proof to the per-device checks, is in
[CONTRIBUTING.md](CONTRIBUTING.md).

## SDKs

The C ABI in [include/gosslens.h](include/gosslens.h) is the surface every SDK
wraps. The three platform SDKs are thin wrappers over the same functions and
share one idiomatic operation contract ([docs/API.md](docs/API.md)); the Android
JNI binding exports the same ABI to Java under Kotlin.

| SDK | For | Package | Integration guide |
|---|---|---|---|
| **Swift** | iOS | XCFramework via a SwiftPM `binaryTarget` | [INTEGRATION-iOS.md](docs/INTEGRATION-iOS.md) |
| **Kotlin** | Android | AAR with the prebuilt `.so`, on Maven Central or JitPack | [INTEGRATION-ANDROID.md](docs/INTEGRATION-ANDROID.md) |
| **TypeScript** | Web | npm package with the `.wasm` inside | [INTEGRATION-WEB.md](docs/INTEGRATION-WEB.md) |
| **C** | Any C-FFI language | `libgosslens` static + shared, from `zig build c` | [sdk/c](sdk/c) |
| **JNI** | Java under Kotlin | the ABI exported to Java, compiled into the Android library | [adapters/android/jni.zig](adapters/android/jni.zig) |

> [!TIP]
> An app developer never installs Zig. Each SDK ships the compiled core as an
> opaque native artifact: a `.so` in the AAR, a static XCFramework, a `.wasm` in
> the npm package. Add one coordinate and no toolchain. See
> [docs/LENS-FORMAT.md](docs/LENS-FORMAT.md) for authoring lenses on top.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing code, the C ABI, an SDK,
or a dependency. Gosslens accepts permissively licensed dependencies only and
holds one public operation contract across Swift, Kotlin, and TypeScript.
Participation is covered by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

Gosslens is licensed under the Apache License 2.0. See [LICENSE.md](LICENSE.md).
Third-party components retain their own licenses, recorded per component under
`third_party/` and summarized in [NOTICE.md](NOTICE.md).
