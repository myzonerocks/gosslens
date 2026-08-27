//! PNG decode on targets without libc/lodepng compiled in (wasm32-
//! freestanding has neither): decode always refuses. Nothing here ever
//! reads the bytes it's handed.

const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,
};

pub const DecodeError = error{Unsupported};

pub fn decode(gpa: std.mem.Allocator, png_bytes: []const u8) DecodeError!Image {
    _ = gpa;
    _ = png_bytes;
    return error.Unsupported;
}

pub const ConvertError = error{ OutOfMemory, ConversionFailed };

pub fn downsampleBox(src: []const u8, src_width: u32, src_height: u32, dst: []u8, dst_width: u32, dst_height: u32) ConvertError!void {
    _ = src;
    _ = src_width;
    _ = src_height;
    _ = dst;
    _ = dst_width;
    _ = dst_height;
    return error.ConversionFailed;
}

// The real backend is libyuv; targets that lack it (freestanding wasm)
// still carry the same surface. The NV12 matrix path has no libyuv here
// and its capture/segmentation callers are stubbed off on these targets,
// so it refuses; the pure byte moves keep working for the web upload path.
pub const Standard = enum { bt601, bt709, bt2020 };
pub const Range = enum { video, full };
pub const Rotation = enum(i32) { none = 0, cw90 = 90, half = 180, cw270 = 270 };

pub fn argbToNv12(rgba: []const u8, width: u32, height: u32, standard: Standard, range: Range, y_out: []u8, uv_out: []u8) ConvertError!void {
    _ = rgba;
    _ = width;
    _ = height;
    _ = standard;
    _ = range;
    _ = y_out;
    _ = uv_out;
    return error.ConversionFailed;
}

pub fn swapRedBlue(pixels: []u8) ConvertError!void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const red = pixels[i];
        pixels[i] = pixels[i + 2];
        pixels[i + 2] = red;
    }
}

pub fn argbRotate(src: [*]const u8, src_stride: u32, dst: [*]u8, dst_stride: u32, width: u32, height: u32, rotation: Rotation) ConvertError!void {
    switch (rotation) {
        .none => for (0..height) |row| {
            const src_row = src[row * src_stride ..];
            const dst_row = dst[row * dst_stride ..];
            @memcpy(dst_row[0 .. width * 4], src_row[0 .. width * 4]);
        },
        .half => for (0..height) |row| {
            const src_row = src[(height - 1 - row) * src_stride ..];
            const dst_row = dst[row * dst_stride ..];
            for (0..width) |col| {
                @memcpy(dst_row[col * 4 ..][0..4], src_row[(width - 1 - col) * 4 ..][0..4]);
            }
        },
        else => return error.ConversionFailed,
    }
}

pub fn argbMirror(src: [*]const u8, src_stride: u32, dst: [*]u8, dst_stride: u32, width: u32, height: u32) ConvertError!void {
    for (0..height) |row| {
        const src_row = src[row * src_stride ..];
        const dst_row = dst[row * dst_stride ..];
        for (0..width) |col| {
            @memcpy(dst_row[col * 4 ..][0..4], src_row[(width - 1 - col) * 4 ..][0..4]);
        }
    }
}

pub fn bgraToRgb(src: [*]const u8, src_stride: u32, dst: [*]u8, dst_stride: u32, width: u32, height: u32, flip: bool) ConvertError!void {
    for (0..height) |row| {
        const source_row = if (flip) height - 1 - row else row;
        const src_row = src[source_row * src_stride ..];
        const dst_row = dst[row * dst_stride ..];
        for (0..width) |col| {
            dst_row[col * 3] = src_row[col * 4 + 2];
            dst_row[col * 3 + 1] = src_row[col * 4 + 1];
            dst_row[col * 3 + 2] = src_row[col * 4];
        }
    }
}
