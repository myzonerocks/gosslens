// A link stub standing in for the platform address sanitizer runtime.

// Apple ships it only as a dylib whose arm64 slice carries a maccatalyst
// LC_BUILD_VERSION; zig's linker refuses the file, vtool will not strip the
// extra version, and there is no static archive. So this stub carries the real
// runtime's install name and nothing else.

// dyld resolves that name through the rpath to the real runtime, whose
// initialisers run before the main image's, which is what lets the sanitizer own
// malloc from the start. Injection cannot: the inference stack allocates in its
// static initialisers, and a block taken first trips ASan's own assertion.
void __asan_init(void);
void __asan_init(void) {}
