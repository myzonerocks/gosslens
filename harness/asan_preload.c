// Keeps the sanitizer runtime's load command, and makes the dependency
// explicit rather than relying on the linker not pruning an unreferenced
// dylib. The real __asan_init is idempotent and has already run by the time a
// main-image constructor fires; this exists for the reference.
void __asan_init(void);

__attribute__((constructor)) static void goss_asan_present(void) {
    __asan_init();
}
