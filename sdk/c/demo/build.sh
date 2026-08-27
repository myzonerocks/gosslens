#!/bin/sh
set -eu
# Stage the C SDK, then compile and run the example against it. It
# links the shared library, so the system compiler needs nothing on the link
# line but -lgosslens. Set CC to pick a compiler, ZIG for a specific zig.

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
sdk="$root/zig-out/c"

if [ -n "${ZIG:-}" ]; then
    zig="$ZIG"
elif [ -x "$root/.local/zig/current/zig" ]; then
    zig="$root/.local/zig/current/zig"
else
    zig="zig"
fi
cc="${CC:-cc}"

# Stage libgosslens (static + shared) and the header under zig-out/c.
( cd "$root" && "$zig" build c )

# Compile and link. The binary goes next to the staged library under zig-out,
# which is not part of the tracked tree. -rpath lets it find the shared library
# at its staged location without an install step.
"$cc" "$here/main.c" \
    -std=c11 \
    -I"$sdk/include" \
    -L"$sdk/lib" -lgosslens \
    -Wl,-rpath,"$sdk/lib" \
    -o "$sdk/main"

exec "$sdk/main"
