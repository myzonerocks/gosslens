// Engine-owned bgfx diagnostics and heap accounting. Fatal and trace reach
// stderr, and every byte bgfx allocates passes the counter below, so the
// vendor heap answers the same proof physics, script and audio do. Plain C:
// no exception can arise, and c11 is for the counter's atomics.

#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bgfx/c99/bgfx.h"

static void goss_bgfx_fatal(bgfx_callback_interface_t* iface, const char* file_path,
                            uint16_t line, bgfx_fatal_t code, const char* str) {
    (void)iface;
    fprintf(stderr, "bgfx fatal %d at %s:%u: %s\n", (int)code,
            file_path != NULL ? file_path : "?", (unsigned)line, str != NULL ? str : "");
    // Debug-check traces continue per bgfx's own callback contract;
    // every other fatal code is unrecoverable and must not return.
    if (code != BGFX_FATAL_DEBUG_CHECK) abort();
}

static void goss_bgfx_trace_vargs(bgfx_callback_interface_t* iface, const char* file_path,
                                  uint16_t line, const char* format, va_list arg_list) {
    (void)iface;
    (void)file_path;
    (void)line;
    vfprintf(stderr, format, arg_list);
}

static void goss_bgfx_profiler_begin(bgfx_callback_interface_t* iface, const char* name,
                                     uint32_t abgr, const char* file_path, uint16_t line) {
    (void)iface; (void)name; (void)abgr; (void)file_path; (void)line;
}

static void goss_bgfx_profiler_begin_literal(bgfx_callback_interface_t* iface, const char* name,
                                             uint32_t abgr, const char* file_path, uint16_t line) {
    (void)iface; (void)name; (void)abgr; (void)file_path; (void)line;
}

static void goss_bgfx_profiler_end(bgfx_callback_interface_t* iface) {
    (void)iface;
}

static uint32_t goss_bgfx_cache_read_size(bgfx_callback_interface_t* iface, uint64_t id) {
    (void)iface; (void)id;
    return 0;
}

static bool goss_bgfx_cache_read(bgfx_callback_interface_t* iface, uint64_t id, void* data,
                                 uint32_t size) {
    (void)iface; (void)id; (void)data; (void)size;
    return false;
}

static void goss_bgfx_cache_write(bgfx_callback_interface_t* iface, uint64_t id,
                                  const void* data, uint32_t size) {
    (void)iface; (void)id; (void)data; (void)size;
}

// Writes the frame bgfx hands over as an uncompressed 32-bit TGA at
// the requested path plus the .tga suffix, the exact file the
// library's own default callback produced, so a requested screenshot
// always lands where the harness reads it back.
static void goss_bgfx_screen_shot(bgfx_callback_interface_t* iface, const char* file_path,
                                  uint32_t width, uint32_t height, uint32_t pitch,
                                  bgfx_texture_format_t format, const void* data,
                                  uint32_t size, bool yflip) {
    (void)iface; (void)format; (void)size;
    if (file_path == NULL || data == NULL || width == 0 || height == 0) return;
    char tga_path[1024];
    int written = snprintf(tga_path, sizeof(tga_path), "%s.tga", file_path);
    if (written < 0 || (size_t)written >= sizeof(tga_path)) return;
    FILE* out = fopen(tga_path, "wb");
    if (out == NULL) {
        fprintf(stderr, "bgfx screenshot: cannot open %s\n", tga_path);
        return;
    }
    uint8_t header[18] = {0};
    header[2] = 2;
    header[12] = (uint8_t)(width & 0xff);
    header[13] = (uint8_t)(width >> 8);
    header[14] = (uint8_t)(height & 0xff);
    header[15] = (uint8_t)(height >> 8);
    header[16] = 32;
    header[17] = yflip ? 0 : 0x20;
    fwrite(header, 1, sizeof(header), out);
    const uint8_t* rows = (const uint8_t*)data;
    for (uint32_t y = 0; y < height; ++y) {
        fwrite(rows + (size_t)y * pitch, 1, (size_t)width * 4, out);
    }
    fclose(out);
}

static void goss_bgfx_capture_begin(bgfx_callback_interface_t* iface, uint32_t width,
                                    uint32_t height, uint32_t pitch,
                                    bgfx_texture_format_t format, bool yflip) {
    (void)iface; (void)width; (void)height; (void)pitch; (void)format; (void)yflip;
}

static void goss_bgfx_capture_end(bgfx_callback_interface_t* iface) {
    (void)iface;
}

static void goss_bgfx_capture_frame(bgfx_callback_interface_t* iface, const void* data,
                                    uint32_t size) {
    (void)iface; (void)data; (void)size;
}

static const bgfx_callback_vtbl_t goss_bgfx_vtbl = {
    .fatal = goss_bgfx_fatal,
    .trace_vargs = goss_bgfx_trace_vargs,
    .profiler_begin = goss_bgfx_profiler_begin,
    .profiler_begin_literal = goss_bgfx_profiler_begin_literal,
    .profiler_end = goss_bgfx_profiler_end,
    .cache_read_size = goss_bgfx_cache_read_size,
    .cache_read = goss_bgfx_cache_read,
    .cache_write = goss_bgfx_cache_write,
    .screen_shot = goss_bgfx_screen_shot,
    .capture_begin = goss_bgfx_capture_begin,
    .capture_end = goss_bgfx_capture_end,
    .capture_frame = goss_bgfx_capture_frame,
};

static bgfx_callback_interface_t goss_bgfx_iface = { .vtbl = &goss_bgfx_vtbl };

// bgfx allocates through one realloc entry point, invisible to the zig gate.
// A prefix header carries size and malloc base so free subtracts exactly what
// alloc added. bgfx requires a thread-safe allocator, so the counters are
// atomic.
static atomic_size_t goss_bgfx_live = 0;
static atomic_size_t goss_bgfx_calls = 0;
// Bytes ever handed out, not bytes held. A per-frame gate reads this to tell a
// payload copy from a bare header: bgfx allocates a small fixed header per
// upload no matter what, so the call count alone cannot see whether the pixels
// were copied through it or referenced in place.
static atomic_size_t goss_bgfx_total = 0;

// bgfx hands its own __FILE__ and __LINE__ to every allocator call, so a
// failing gate names the code rather than printing a number. Keyed on the
// literal's pointer, since bgfx passes static strings.
#define GOSS_BGFX_SITE_CAP 128
typedef struct goss_bgfx_site {
    const char* file;
    uint32_t line;
    size_t calls;
    size_t bytes;
} goss_bgfx_site;

static goss_bgfx_site goss_bgfx_sites[GOSS_BGFX_SITE_CAP];
static size_t goss_bgfx_live_sites = 0;
static size_t goss_bgfx_sites_dropped = 0;

static size_t goss_bgfx_site_count_value(void) {
    return goss_bgfx_live_sites;
}

static void goss_bgfx_record_site(const char* file, uint32_t line, size_t size) {
    for (size_t i = 0; i < goss_bgfx_live_sites; ++i) {
        if (goss_bgfx_sites[i].file == file && goss_bgfx_sites[i].line == line) {
            goss_bgfx_sites[i].calls += 1;
            goss_bgfx_sites[i].bytes += size;
            return;
        }
    }
    if (goss_bgfx_live_sites == GOSS_BGFX_SITE_CAP) {
        goss_bgfx_sites_dropped += 1;
        return;
    }
    goss_bgfx_sites[goss_bgfx_live_sites].file = file;
    goss_bgfx_sites[goss_bgfx_live_sites].line = line;
    goss_bgfx_sites[goss_bgfx_live_sites].calls = 1;
    goss_bgfx_sites[goss_bgfx_live_sites].bytes = size;
    goss_bgfx_live_sites += 1;
}

typedef struct goss_bgfx_block {
    void* base;
    size_t size;
} goss_bgfx_block;

static void* goss_bgfx_counted_alloc(size_t size, size_t align) {
    if (align < sizeof(void*)) align = sizeof(void*);
    const size_t total = sizeof(goss_bgfx_block) + align + size;
    if (total < size) return NULL; /* the add wrapped: refuse rather than under-allocate */
    void* base = malloc(total);
    if (base == NULL) return NULL;
    const uintptr_t raw = (uintptr_t)base + sizeof(goss_bgfx_block);
    const uintptr_t user = (raw + (align - 1)) & ~(uintptr_t)(align - 1);
    goss_bgfx_block* block = (goss_bgfx_block*)user - 1;
    block->base = base;
    block->size = size;
    atomic_fetch_add_explicit(&goss_bgfx_live, size, memory_order_relaxed);
    atomic_fetch_add_explicit(&goss_bgfx_calls, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&goss_bgfx_total, size, memory_order_relaxed);
    return (void*)user;
}

static void goss_bgfx_counted_free(void* ptr) {
    if (ptr == NULL) return;
    goss_bgfx_block* block = (goss_bgfx_block*)ptr - 1;
    atomic_fetch_sub_explicit(&goss_bgfx_live, block->size, memory_order_relaxed);
    free(block->base);
}

// bgfx folds alloc, free and resize into this one call: a null pointer
// with a size allocates, a pointer with no size frees, and both present
// resizes. Growing copies through a fresh block because the prefix header
// cannot move under the caller.
static void* goss_bgfx_realloc(bgfx_allocator_interface_t* iface, void* ptr, size_t size, size_t align,
                               const char* file_path, uint32_t line) {
    (void)iface;
    if (ptr == NULL) {
        if (size == 0) return NULL;
        goss_bgfx_record_site(file_path, line, size);
        return goss_bgfx_counted_alloc(size, align);
    }
    if (size == 0) {
        goss_bgfx_counted_free(ptr);
        return NULL;
    }
    goss_bgfx_block* block = (goss_bgfx_block*)ptr - 1;
    const size_t old_size = block->size;
    if (old_size == size) return ptr;
    goss_bgfx_record_site(file_path, line, size);
    void* fresh = goss_bgfx_counted_alloc(size, align);
    if (fresh == NULL) return NULL;
    memcpy(fresh, ptr, old_size < size ? old_size : size);
    goss_bgfx_counted_free(ptr);
    return fresh;
}

static const bgfx_allocator_vtbl_t goss_bgfx_allocator_vtbl = {
    .realloc = goss_bgfx_realloc,
};

static bgfx_allocator_interface_t goss_bgfx_allocator_iface = { .vtbl = &goss_bgfx_allocator_vtbl };

bgfx_allocator_interface_t* goss_bgfx_allocator(void) {
    return &goss_bgfx_allocator_iface;
}

// Live bytes held on the bgfx heap right now, and the total allocation
// calls made so far. The vendor-heap proof reads the first between
// lifecycles and the per-frame gate diffs the second across a steady
// window. Internal to the harness, not part of the public C ABI.
size_t goss_bgfx_live_bytes(void) {
    return atomic_load_explicit(&goss_bgfx_live, memory_order_relaxed);
}

size_t goss_bgfx_alloc_calls(void) {
    return atomic_load_explicit(&goss_bgfx_calls, memory_order_relaxed);
}

size_t goss_bgfx_alloc_bytes(void) {
    return atomic_load_explicit(&goss_bgfx_total, memory_order_relaxed);
}

// The tally as data, so a gate can hold a policy over it rather than reading
// printed lines: how many distinct sites allocated in the window, and for each
// the bgfx source file and line, the call count and the bytes.
size_t goss_bgfx_site_count(void) {
    return goss_bgfx_site_count_value();
}

const char* goss_bgfx_site_file(size_t index) {
    if (index >= goss_bgfx_site_count_value()) return NULL;
    return goss_bgfx_sites[index].file;
}

uint32_t goss_bgfx_site_line(size_t index) {
    if (index >= goss_bgfx_site_count_value()) return 0;
    return goss_bgfx_sites[index].line;
}

size_t goss_bgfx_site_calls(size_t index) {
    if (index >= goss_bgfx_site_count_value()) return 0;
    return goss_bgfx_sites[index].calls;
}

size_t goss_bgfx_site_bytes(size_t index) {
    if (index >= goss_bgfx_site_count_value()) return 0;
    return goss_bgfx_sites[index].bytes;
}

// Calls from sites the table could not hold. A gate treats a non-zero value as
// a failure to measure rather than as a clean window.
size_t goss_bgfx_sites_overflowed(void) {
    return goss_bgfx_sites_dropped;
}

// Clears the per-site tally so a measurement window starts from nothing.
void goss_bgfx_reset_sites(void) {
    for (size_t i = 0; i < goss_bgfx_live_sites; ++i) {
        goss_bgfx_sites[i].calls = 0;
        goss_bgfx_sites[i].bytes = 0;
    }
    goss_bgfx_sites_dropped = 0;
}

// Prints the busiest call sites in the window to stderr, most calls first, so
// a failing gate says which bgfx code to go and read. Limit caps the lines.
void goss_bgfx_report_sites(uint32_t limit) {
    size_t shown = 0;
    while (shown < limit) {
        size_t best = GOSS_BGFX_SITE_CAP;
        size_t best_calls = 0;
        for (size_t i = 0; i < goss_bgfx_live_sites; ++i) {
            if (goss_bgfx_sites[i].calls > best_calls) {
                best_calls = goss_bgfx_sites[i].calls;
                best = i;
            }
        }
        if (best == GOSS_BGFX_SITE_CAP) break;
        fprintf(stderr, "  bgfx alloc site: %s:%u  %zu calls  %zu bytes\n",
                goss_bgfx_sites[best].file != NULL ? goss_bgfx_sites[best].file : "?",
                (unsigned)goss_bgfx_sites[best].line,
                goss_bgfx_sites[best].calls,
                goss_bgfx_sites[best].bytes);
        goss_bgfx_sites[best].calls = 0;
        shown += 1;
    }
    if (goss_bgfx_sites_dropped != 0) {
        fprintf(stderr, "  bgfx alloc sites: %zu calls from sites past the table cap\n", goss_bgfx_sites_dropped);
    }
}

bgfx_callback_interface_t* goss_bgfx_callbacks(void) {
    return &goss_bgfx_iface;
}
