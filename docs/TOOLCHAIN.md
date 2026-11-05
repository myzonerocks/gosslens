# Toolchain

The Zig version is pinned in .zigversion and installed by
tools/toolchain-sync, which verifies the published digest before unpacking.
build.zig refuses any other compiler.

## 2026-11-03

Pinned Zig 0.17.1, the current stable release. 0.17.0 could not build the
iOS slices at all: its standard library left the `.ios` arm of `Threaded`'s
null-file struct without a descriptor field while still reading one, and
since 0.17 keeps every mutex behind `std.Io`, one lock was enough to stop
the compile. 0.17.1 is the one-line upstream fix, so the pin skips 0.17.0.
The language and the build system both moved, and the tree moved with them
rather than around them:

Array repetition is gone, so a repeated byte array is `@splat` against a
named length. `@intFromEnum` and `@enumFromInt` are deprecated in favour of
`@backingInt` and `@fromBackingInt`, which `zig fmt` rewrites. Type
reflection answers struct-of-arrays, so a field or parameter count reads
`field_names` and `param_types` rather than `fields` and `params`.

The build system splits configure from make and keeps the configuration it
produced, so anything build.zig reads off disk while assembling the graph is
declared: files through `dependOnFileMetadata` and `dependOnFileContents`,
source listings through `dependOnDirectoryContents`. A path has to exist to
be declared, so a vendor probe that found nothing declares the nearest
directory above it instead, whose entries change the moment the vendor
arrives. Without that a `vendor-sync` followed by a build reuses a graph
that had no vendors, which is what the shadow lane hit in #196.

The nix shell no longer takes zig from nixpkgs, which carries one build per
minor and lags a patch release: `nix/zig.nix` unpacks the official release
binary by the digest the download index publishes, the same bytes
`tools/toolchain-sync` installs, keyed by `.zigversion`. Moving the pin
means adding that version's digests there, and a version with none fails
the shell rather than falling back.

Because zig is fetched that way, the nixpkgs pin itself stays where it is. A
binary built inside the shell links the shell's glibc and then runs against the
host's loader, so a nixpkgs whose glibc is newer than the CI runner's leaves
every Linux test binary refusing to start. Bumping it is a deliberate change
with the runner's glibc checked first, not a side effect of wanting a tool.

## 2026-08-14

Pinned Zig 0.16.0, the then current stable release. Code is written against
the pinned standard library from the start: std.Io for filesystem and
process work, std.process.Init for entry points. Zig also compiles the C and
C++ we vendor, so bumping the pin moves the whole native toolchain at once.

A weekly job builds everything against Zig master and files an issue when
something breaks, so a new stable release is a scheduled chore instead of a
surprise. GOSS_ALLOW_ZIG_MISMATCH=1 exists for that job alone. When a new
stable ships, the bump lands within a month with every gate green.

Platform floors are current stable Xcode, current stable Android Gradle
plugin and NDK, and evergreen browsers. They are reviewed monthly and
recorded here as the SDKs take shape.
