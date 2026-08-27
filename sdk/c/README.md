# Gosslens - C SDK

The C ABI at [`include/gosslens.h`](../../include/gosslens.h), packaged as a
library any language with a C FFI can link. This is the direct surface: the
[Swift](../swift/README.md), [Kotlin](../kotlin/README.md), and
[TypeScript](../ts/README.md) SDKs are thin wrappers over the same `goss_*`
functions, so a Python, Rust, Go, or C++ host reaches the engine through this
header instead of a hand-written wrapper.

There is no separate C header to drift from the ABI. `zig build c` stages
the one in `include/` next to the library, and building the library is the same
check a consumer runs: if the frozen ABI ever stopped linking, this step fails
first.

## Build

```
zig build c
```

stages, under `zig-out/c/`:

    include/gosslens.h        the frozen C ABI, copied from include/
    lib/libgosslens.dylib     the shared library (.so on Linux)
    lib/libgosslens.a         the static archive of the engine's own objects

The shared library is self-contained: the CPU image path (libyuv), physics
(Jolt), scripting (QuickJS), audio mixing (miniaudio), and the platform media
frameworks are linked into it, so a C program links it with nothing on the line
but `-lgosslens`. The static archive is the engine objects alone; a static link
also provides those vendored libraries and the platform frameworks, which is
why most consumers link the shared library or build a platform archive set with
`zig build ios` / `android` / `wasm`.

## Link

```c
#include <gosslens.h>
```

```
cc app.c \
    -I zig-out/c/include \
    -L zig-out/c/lib -lgosslens \
    -Wl,-rpath,zig-out/c/lib \
    -o app
```

`goss_abi_version` is the first call to make; a mismatch in its high 16 bits
against `GOSS_ABI_MAJOR` means the header and the library are different major
versions and the program must refuse to run. An engine and its sessions stay on
the thread that created them, except for the few functions the header marks
any-thread.

## What the host library carries

The library `c` stages is the host build, and it does not bring up a GPU
renderer or the in-engine inference stack. `goss_engine_init_renderer` reports
`GOSS_ERROR_RENDERER_UNAVAILABLE`, so the calls that need a surface - frame
submission, `goss_engine_render_frame`, and the capture paths - report the same;
`goss_session_enable_face_tracking` and the other in-engine workers report
`GOSS_ERROR_UNSUPPORTED`, and beauty reports it too. The render backend and the
inference runtime link in through the platform builds, `zig build ios`,
`android`, and `wasm`.

What the host library does run is everything that does not need a graphics
surface: engine and session lifecycle, the lens runtime (activation and ticking
against triggers), camera-control and recording-policy intent read back, the
app-tracked multi-face and multi-body paths, the brush, the geofence signal, the
degradation policy, and the pure helpers. That is enough to link the library and
exercise the ABI from C without a window, which is what the example does.

## Example

[`demo/main.c`](demo/main.c) drives that slice end to end and is
the fastest way to confirm the library links and runs:

```
sdk/c/demo/build.sh
```

builds `c`, compiles the example against the shared library, and runs it.

External projects that build with CMake can consume the staged library through
[`CMakeLists.txt`](CMakeLists.txt), which imports it rather than rebuilding the
engine.

## TODO

- Tag a release so a consumer can pin a versioned `libgosslens` rather than
  building it from a checkout.
