# Contributing

This is how to build a change, prove it, and submit it. The contracts a change
must respect live elsewhere and come first: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the structure, ownership, dependency policy, ABI, and performance model, and
[docs/API.md](docs/API.md) for the public SDK naming and parameter contract. A
feature is not complete because it compiles.

## Start here

Use the project toolchain. Do not substitute a global Zig installation.
`tools/toolchain-sync` installs the pinned Zig into `.local/zig` and wires the
git hooks. The pinned compiler lives in `.zigversion`; `build.zig` rejects a
different version, so the toolchain question has exactly one answer.

    tools/toolchain-sync
    zig build test               # all unit tests
    zig build gate -- --tree     # the source gate over tracked files
    zig build ci                 # tests, source gate, abi, vendor check, provenance

`zig build ci` is the whole local bar in one command. Green here is green
upstream, so never push and let CI find a failure the local run would have.
Regenerate the ABI baseline after an intended ABI change with
`zig build abi -- --print > tools/abi-baseline.txt` and commit it with the code.

## Watch it draw

    zig build harness              # run a lens through the real graph, drawn on screen
    zig build conformance          # run a reference lens through the ABI twice, proving bit-stable output
    zig build conformance -- --watch  # the same run, holding and labelling each proof's render on screen

The harness runs a lens through the real graph and draws it on screen, the same
pipeline the SDKs drive, the fastest way to see an effect move before a device
is involved. Conformance runs a reference lens through the real ABI twice and
proves the output is bit for bit stable. Every engine feature that touches the
ABI adds a proof here, and the run prints one PROOF line per capability it
clears. Add `--watch` to hold each proof's final frame on screen with its name
in the title bar, so the run reads as a live sequence instead of one frozen
frame; it is display only and leaves the pinned output unchanged.

## Shaders and lenses

    zig build test -Dlens-shaders=true    # compile every shader on all backends
    zig build lens-validate -- <bundle>   # validate one bundle

The shader build compiles each pass to Metal, SPIR-V, GLSL ES, and WGSL, so a
shader that only builds on one backend fails here rather than on a device. The
bundle format the validator checks against is specified in
[lenses/SPEC.md](lenses/SPEC.md).

## Per platform

Every capability ships on all three platforms or it does not ship, and
[docs/PARITY.md](docs/PARITY.md) is the table of what is proven where.

- iOS: `zig build ios` and `zig build ios-simulator`; the demo under
  `sdk/swift/demo` runs it. See [docs/INTEGRATION-iOS.md](docs/INTEGRATION-iOS.md).
- Android: `zig build android`; the demo under `sdk/kotlin/demo` runs it. See
  [docs/INTEGRATION-ANDROID.md](docs/INTEGRATION-ANDROID.md).
- Web: `zig build wasm`; the demo under `sdk/ts/demo` runs it. See
  [docs/INTEGRATION-WEB.md](docs/INTEGRATION-WEB.md).

When a capability moves from built to demonstrated on a platform, update its row
in [docs/PARITY.md](docs/PARITY.md) in the same change.

## Adding a feature

A capability is not one commit in one place. It reaches the core, the C ABI, the
baseline, all three SDKs, and a proof, or it is unfinished.

1. Build it in the boundary that already owns it (see
   [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
2. Add the C op to `include/gosslens.h`, register it in `tools/abi_dump.zig`,
   and bump the ABI minor.
3. Regenerate `tools/abi-baseline.txt`.
4. Decide the canonical operation name and parameters in
   [docs/API.md](docs/API.md) first, then wire the Swift, Kotlin, and TypeScript
   SDKs and the Android JNI binding to that one name.
5. Add a conformance proof, and a harness path when the feature draws.
6. Update [docs/PARITY.md](docs/PARITY.md) and run `zig build ci` green before
   push.

## Git

Work on a feature branch cut from current `main`. Keep one coherent feature
cluster on the branch. Keep unrelated changes out. Every commit should build.
Merge only with required gates green.

Commit messages are terse and imperative. Describe the code change, not the
process used to discover it.

Do not commit generated build output, model payloads, vendor caches, local
configuration, or anything under `docs/private/`. That directory is
intentionally local-only and gitignored. Public code and CI must never depend on
a file under `docs/private/`.

## Pull requests

A pull request should answer five things plainly:

- what capability or defect it changes
- which architectural boundary owns the change
- what ABI or API surface it changes, if any, with its `docs/API.md` entry
- what dependency it introduces, if any
- what executed proof shows the behavior works

If a change weakens the architecture, API contract, or license policy, it is not
ready for review.
