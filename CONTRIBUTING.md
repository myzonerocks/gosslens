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

```sh
tools/toolchain-sync
zig build test               # all unit tests
zig build gate -- --tree     # the source gate over tracked files
zig build ci                 # tests, source gate, abi, vendor check, provenance
```

`zig build ci` is the whole local bar in one command. Green here is green
upstream, so never push and let CI find a failure the local run would have.
After an intended ABI change run `zig build abi-update`: it regenerates
`tools/abi-baseline.txt` and stamps `GOSS_ABI_MINOR` in the header from the
surface, so the version is never bumped by hand. The pre-commit hook runs it
for you when a commit touches the surface; `zig build abi` verifies both match.

### On Windows

Run the commands above from the bash git installs, not from cmd or PowerShell.
`tools/toolchain-sync` is a shell script, the hooks are shell scripts, and both
resolve the pinned compiler as `zig.exe`. The toolchain lands in the same
`.local/zig/current`, as a directory junction rather than a symlink, so no
elevation or developer mode is needed.

The portable bar runs here: `zig build test`, `gate -- --tree`, `abi`,
`vendor-sync -- --check`, `fetch-models -- --check`, `shaderc`, and
`lens-validate-reference`. The on-screen `harness` and `conformance` runners
are macOS-only, so `zig build ci` is not the local bar on a Windows host; a
change still has to clear it on macOS or Linux before it merges. Building the
Android library needs the pinned NDK (`ndk_version` in `build.zig`) named in
`ANDROID_NDK_ROOT` or installed under `%LOCALAPPDATA%\Android\Sdk\ndk`. Android
Studio's SDK Manager installs the newest NDK, which is not the pin and may be a
beta; tick "Show Package Details" and take the pinned version.

`shaderc` compiles glslang and tint, and one clang per core on a 12-thread
machine wants more memory than an 8 GB host has; it dies with `LLVM ERROR: out
of memory`. Pass `-j4` there on a machine that small.

## Repository layout

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
are; new work extends the nearest existing boundary. The lens file format,
published as a forkable standard, is [docs/LENS-FORMAT.md](docs/LENS-FORMAT.md);
toolchain decisions are logged in [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md).

## Watch it draw

```sh
zig build harness              # run a lens through the real graph, drawn on screen
zig build conformance          # run a reference lens through the ABI twice, proving bit-stable output
zig build conformance -- --watch  # the same run, holding and labelling each proof's render on screen
zig build conformance -- --golden # print the cross-target golden signature for lenses/cross-target-golden.txt
```

The harness runs a lens through the real graph and draws it on screen, the same
pipeline the SDKs drive, the fastest way to see an effect move before a device
is involved. Conformance runs a reference lens through the real ABI twice and
proves the output is bit for bit stable. Every engine feature that touches the
ABI adds a proof here, and the run prints one PROOF line per capability it
clears. Add `--watch` to hold each proof's final frame on screen with its name
in the title bar, so the run reads as a live sequence instead of one frozen
frame; it is display only and leaves the pinned output unchanged.

`--golden` answers a different question: not whether this backend is stable
against itself, but whether another one draws the same colour. It renders one
fixed synthetic frame through one fixed grade and prints an 8x8 grid of RGB
block means, pinned at `lenses/cross-target-golden.txt`. A client builds the
same frame from the same integer arithmetic - no fixture ships - and holds
itself to that file within 8/255. Block means rather than pixels, because a
per-pixel compare across two backends measures rasterisation and the question
here is colour. Regenerate the file only for an intended change to the grade
math, and say so in review.

## Shaders and lenses

```sh
zig build test -Dlens-shaders=true    # compile every shader on all backends
zig build lens-validate -- <bundle>   # validate one bundle
```

The shader build compiles each pass to Metal, SPIR-V, GLSL ES, and WGSL, so a
shader that only builds on one backend fails here rather than on a device. The
bundle format the validator checks against is specified in
[lenses/SPEC.md](lenses/SPEC.md).

## Per platform

Every capability ships on all three platforms or it does not ship, and
[docs/PARITY.md](docs/PARITY.md) is the table of what is proven where.

- iOS: `zig build ios` and `zig build ios-simulator`; the demo under
  `sdk/swift/demo` runs it. See [sdk/swift/README.md](sdk/swift/README.md).
- Android: `zig build android`; the demo under `sdk/kotlin/demo` runs it. See
  [sdk/kotlin/README.md](sdk/kotlin/README.md).
- Web: `zig build wasm`; the demo under `sdk/ts/demo` runs it. See
  [sdk/ts/README.md](sdk/ts/README.md).

When a capability moves from built to demonstrated on a platform, update its row
in [docs/PARITY.md](docs/PARITY.md) in the same change.

## Adding a feature

A capability is not one commit in one place. It reaches the core, the C ABI, the
baseline, the SDKs, and a proof, or it is unfinished.

1. Build it in the boundary that already owns it (see
   [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
2. Add the C op to `include/gosslens.h` and its signature to `abi_functions`
   in `core/abi/abi.zig`. The ABI minor is derived from that list, so nothing
   to bump.
3. Run `zig build abi-update` (or just commit; the hook syncs the baseline and
   header for you).
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
