// Engine-owned bgfx diagnostics: fatal and trace route to stderr so
// driver failures and the shutdown leak report are never swallowed.
// Renderer.init installs this interface whenever the host supplies no
// callback of its own; plain C so va_list stays portable everywhere.

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

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

bgfx_callback_interface_t* goss_bgfx_callbacks(void) {
    return &goss_bgfx_iface;
}
