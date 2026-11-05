// The vendored container internals include the bmi2 intrinsics header directly, which this
// compiler only accepts by way of immintrin. Force-included for the x86 targets rather than
// patching the vendored trees, and named by a path under the build root so the build cache
// can resolve it: a bare header name is found by the compiler but not by the cache.
#include <immintrin.h>
