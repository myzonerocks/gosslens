# Gosslens

A camera and AR engine with a Zig core and SDKs on top of it: Swift for
iOS, Kotlin for Android, TypeScript for the web, a full-parity C SDK any
C-FFI language can link, and the Android JNI binding under Kotlin. The
core owns the frame graph, the lens runtime, the effect pipeline,
tracking, and the portable media contract behind a single C ABI. The
platform SDKs own capture, GPU surfaces, native hardware media APIs, and
platform tracking, and nothing else.

The goal is the full surface a modern camera app expects: beauty and
makeup, multi-face, hand, and body tracking, segmentation, world
anchoring, scripted and physics-driven lenses, glTF model rendering, a
deterministic audio mixer, multi-source compositing and screen-share,
camera controls, geofilters, on-frame drawing, and capture output. All of
it on device, with no lock-in.
The build order lives in [docs/ROADMAP.md](docs/ROADMAP.md).

Everything runs on device. The core makes no network calls and carries no
analytics. A camera frame never leaves the process.

## Layout

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

The checked-out layout is authoritative. Existing subsystems stay where they
are; new work extends the nearest existing boundary.

The public architecture and dependency-license contract live in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The canonical SDK naming and
parameter contract lives in [docs/API.md](docs/API.md).

## Building

    tools/toolchain-sync
    zig build test
    zig build gate -- --tree

toolchain-sync installs the pinned Zig into .local/zig and wires the git
hooks. build.zig refuses any other compiler, so the toolchain question has
exactly one answer. Toolchain decisions are logged in
[docs/TOOLCHAIN.md](docs/TOOLCHAIN.md). The full set of local tools, from the
on-screen harness and the conformance proof to the per-device checks, is in
[CONTRIBUTING.md](CONTRIBUTING.md).

## SDKs

The C ABI in [include/gosslens.h](include/gosslens.h) is the surface every SDK
wraps. [sdk/c](sdk/c) is a full-parity package that exposes every `goss_*`
operation the header declares as a linkable `libgosslens` for any language with a C FFI. The three
platform SDKs are thin wrappers over the same functions and share one idiomatic
operation contract ([docs/API.md](docs/API.md)); the Android JNI binding exports
the same ABI to Java under Kotlin.

- C, for any language: [sdk/c](sdk/c), every op through the canonical header, built as a shared and static library by `zig build c`, with a demo and CMake
- Swift, for iOS: [sdk/swift](sdk/swift), integrated per [docs/INTEGRATION-iOS.md](docs/INTEGRATION-iOS.md)
- Kotlin, for Android: [sdk/kotlin](sdk/kotlin), integrated per [docs/INTEGRATION-ANDROID.md](docs/INTEGRATION-ANDROID.md)
- TypeScript, for the web: [sdk/ts](sdk/ts), integrated per [docs/INTEGRATION-WEB.md](docs/INTEGRATION-WEB.md)
- JNI, under Kotlin: [adapters/android/jni.zig](adapters/android/jni.zig), the ABI exported to Java and compiled into the Android library

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing code, the C ABI, an SDK,
or a dependency. Gosslens accepts permissively licensed dependencies only and
holds one public operation contract across Swift, Kotlin, and TypeScript.

Participation in the project is covered by
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

Gosslens is licensed under the Apache License 2.0. See [LICENSE.md](LICENSE.md).
Third-party components retain their own licenses, recorded per component under
`third_party/` and summarized in [NOTICE.md](NOTICE.md).
