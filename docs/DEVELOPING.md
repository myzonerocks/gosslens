# Developing

This is the working guide for building a feature and proving it. Read
[CONTRIBUTING.md](../CONTRIBUTING.md) for what a change must preserve, and
[docs/API.md](API.md) for the operation contract the three SDKs share. This doc
is about the tools: how to run what CI runs, watch the engine draw, and check a
capability on each platform.

## Setup

    tools/toolchain-sync

This installs the pinned Zig into `.local/zig` and wires the git hooks.
`build.zig` refuses any other compiler, so every command below runs through that
one Zig with no global install involved. Toolchain decisions are logged in
[docs/TOOLCHAIN.md](TOOLCHAIN.md).

## The local gate

Run the same checks CI runs, before every push.

    zig build test                 all unit tests
    zig build gate -- --tree       the source gate over tracked files
    zig build abi                  the C ABI against tools/abi-baseline.txt
    zig build ci                   tests, source gate, abi, vendor check, provenance

`zig build ci` is the whole bar in one command. Green here is green upstream, so
never push and let CI find a failure the local run would have. After an intended
ABI change, regenerate the baseline with
`zig build abi -- --print > tools/abi-baseline.txt` and commit it with the code.

## Watch it draw

    zig build harness

The harness runs a lens through the real graph and draws it on screen, the same
pipeline the SDKs drive. It is the fastest way to see an effect move before any
device is involved.

    zig build conformance

Conformance runs a reference lens through the real ABI twice and proves the
output is bit for bit stable. Every engine feature that touches the ABI adds a
proof here, and the run prints one PROOF line per capability it clears.

## Shaders and lenses

    zig build test -Dlens-shaders=true      compile every shader on all backends
    zig build lens-validate -- <bundle>     validate one bundle
    zig build lens-validate-reference       validate every reference bundle

The shader build compiles each pass to Metal, SPIR-V, GLSL ES, and WGSL, so a
shader that only builds on one backend fails here rather than on a device.

## Per platform

Every capability ships on all three platforms or it does not ship.
[docs/PARITY.md](PARITY.md) is the table of what is proven where, and the
conformance harness keeps it honest. To check a capability on a platform:

- iOS: `zig build ios` builds the device libraries and `zig build ios-simulator`
  the simulator ones. The demo under `sdk/swift/demo` runs it. Steps are in
  [docs/INTEGRATION-iOS.md](INTEGRATION-iOS.md).
- Android: `zig build android` builds `libgosslens.so` for arm64 and x86_64. The
  demo under `sdk/kotlin/demo` runs it on an emulator or device. Steps are in
  [docs/INTEGRATION-ANDROID.md](INTEGRATION-ANDROID.md).
- Web: `zig build wasm` builds the core for the browser. The demo under
  `sdk/ts/demo` runs it. Steps are in [docs/INTEGRATION-WEB.md](INTEGRATION-WEB.md).

When a capability moves from built to demonstrated on a platform, update its row
in [docs/PARITY.md](PARITY.md) in the same change.

## Adding a feature

A capability is not one commit in one place. It reaches the core, the C ABI, the
baseline, all three SDKs, and a proof, or it is unfinished.

1. Build it in the boundary that already owns it (see CONTRIBUTING.md).
2. Add the C op to `include/gosslens.h`, register it in `tools/abi_dump.zig`,
   and bump the ABI minor.
3. Regenerate `tools/abi-baseline.txt`.
4. Wire the Swift, Kotlin, and TypeScript SDKs and the Android JNI binding, one
   name per operation across all three ([docs/API.md](API.md)).
5. Add a conformance proof, and a harness path when the feature draws.
6. Update [docs/PARITY.md](PARITY.md) and run `zig build ci` green before push.
