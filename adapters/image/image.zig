//! PNG decode for lens assets: a thin binding over the kit's own
//! vendored lodepng, the same decoder the desktop harness already
//! proves against with a real texture upload. Always decodes to
//! tightly packed RGBA8, since that is the one format every consumer
//! here wants - the kit's own texture creation paths already assume it.

const std = @import("std");

const c = @cImport({
    @cInclude("lodepng.h");
});

// libyuv's own header drags in libc headers zig's C translator cannot
// digest on every target sysroot; these two are plain C signatures,
// declared directly against the linked library.
extern fn ABGRToJ420(src_abgr: [*]const u8, src_stride_abgr: c_int, dst_y: [*]u8, dst_stride_y: c_int, dst_u: [*]u8, dst_stride_u: c_int, dst_v: [*]u8, dst_stride_v: c_int, width: c_int, height: c_int) c_int;
extern fn I420ToNV12(src_y: [*]const u8, src_stride_y: c_int, src_u: [*]const u8, src_stride_u: c_int, src_v: [*]const u8, src_stride_v: c_int, dst_y: [*]u8, dst_stride_y: c_int, dst_uv: [*]u8, dst_stride_uv: c_int, width: c_int, height: c_int) c_int;
extern fn ARGBScale(src: [*]const u8, src_stride: c_int, src_w: c_int, src_h: c_int, dst: [*]u8, dst_stride: c_int, dst_w: c_int, dst_h: c_int, filtering: c_int) c_int;
extern fn ARGBToNV12Matrix(src_argb: [*]const u8, src_stride: c_int, dst_y: [*]u8, dst_stride_y: c_int, dst_uv: [*]u8, dst_stride_uv: c_int, argb: *const ArgbConstants, width: c_int, height: c_int) c_int;
extern fn ABGRToARGB(src: [*]const u8, src_stride: c_int, dst: [*]u8, dst_stride: c_int, width: c_int, height: c_int) c_int;
extern fn ARGBRotate(src: [*]const u8, src_stride: c_int, dst: [*]u8, dst_stride: c_int, src_width: c_int, src_height: c_int, mode: c_int) c_int;
extern fn ARGBMirror(src: [*]const u8, src_stride: c_int, dst: [*]u8, dst_stride: c_int, width: c_int, height: c_int) c_int;
extern fn ARGBToRAW(src_argb: [*]const u8, src_stride: c_int, dst_raw: [*]u8, dst_stride: c_int, width: c_int, height: c_int) c_int;
extern fn NV12ToARGB(src_y: [*]const u8, src_stride_y: c_int, src_uv: [*]const u8, src_stride_uv: c_int, dst_argb: [*]u8, dst_stride: c_int, width: c_int, height: c_int) c_int;
extern fn NV21ToARGB(src_y: [*]const u8, src_stride_y: c_int, src_vu: [*]const u8, src_stride_vu: c_int, dst_argb: [*]u8, dst_stride: c_int, width: c_int, height: c_int) c_int;
extern fn I420ToARGB(src_y: [*]const u8, src_stride_y: c_int, src_u: [*]const u8, src_stride_u: c_int, src_v: [*]const u8, src_stride_v: c_int, dst_argb: [*]u8, dst_stride: c_int, width: c_int, height: c_int) c_int;

// libyuv's RGB-to-YUV coefficient tables, C-linkage globals picked by
// standard and range. We only pass their address; the layout mirrors
// libyuv's own struct so the pointer is well typed.
const ArgbConstants = extern struct {
    rgb_to_y: [32]u8,
    rgb_to_u: [32]i8,
    rgb_to_v: [32]i8,
    add_y: [16]u16,
    add_uv: [16]u16,
};
extern const kAbgrI601Constants: ArgbConstants;
extern const kAbgrJPEGConstants: ArgbConstants;
extern const kAbgrH709Constants: ArgbConstants;
extern const kAbgrF709Constants: ArgbConstants;
extern const kAbgrU2020Constants: ArgbConstants;
extern const kAbgrV2020Constants: ArgbConstants;

pub const Image = struct {
    width: u32,
    height: u32,
    /// width * height * 4 bytes, RGBA8, row-major, tightly packed.
    rgba: []u8,
};

pub const DecodeError = error{ OutOfMemory, InvalidPng };

/// Decodes one complete PNG file's bytes into RGBA8. The returned
/// image's rgba slice is gpa-owned; free it with gpa.free.
pub fn decode(gpa: std.mem.Allocator, png_bytes: []const u8) DecodeError!Image {
    var decoded: [*c]u8 = null;
    var width: c_uint = 0;
    var height: c_uint = 0;
    const err = c.lodepng_decode32(&decoded, &width, &height, png_bytes.ptr, png_bytes.len);
    if (err != 0) return error.InvalidPng;
    defer std.c.free(decoded);

    // A dimension past the u16 texture bound (a 100000x1 strip fits the
    // compressed byte limits) is refused here, the one decode choke point,
    // so no consumer's u16 cast can trap on untrusted content.
    if (width == 0 or width > 65535 or height == 0 or height > 65535) return error.InvalidPng;
    const byte_count = @as(usize, width) * height * 4;
    const owned = try gpa.alloc(u8, byte_count);
    @memcpy(owned, decoded[0..byte_count]);
    return .{ .width = width, .height = height, .rgba = owned };
}

pub const ConvertError = error{ OutOfMemory, ConversionFailed };

/// Converts tightly packed RGBA8 (libyuv's ABGR word order) to
/// full-range BT.601 NV12 through libyuv, the kit's one CPU
/// conversion authority. y_out holds width * height bytes, uv_out the
/// interleaved half-rounded-up chroma plane.
pub fn rgbaToNv12(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, y_out: []u8, uv_out: []u8) ConvertError!void {
    const w: usize = width;
    const h: usize = height;
    const half_w = (w + 1) / 2;
    const half_h = (h + 1) / 2;
    if (rgba.len < w * h * 4 or y_out.len < w * h or uv_out.len < half_w * 2 * half_h) return error.ConversionFailed;

    const u_plane = try gpa.alloc(u8, half_w * half_h);
    defer gpa.free(u_plane);
    const v_plane = try gpa.alloc(u8, half_w * half_h);
    defer gpa.free(v_plane);

    if (ABGRToJ420(rgba.ptr, @intCast(w * 4), y_out.ptr, @intCast(w), u_plane.ptr, @intCast(half_w), v_plane.ptr, @intCast(half_w), @intCast(width), @intCast(height)) != 0) {
        return error.ConversionFailed;
    }
    if (I420ToNV12(y_out.ptr, @intCast(w), u_plane.ptr, @intCast(half_w), v_plane.ptr, @intCast(half_w), y_out.ptr, @intCast(w), uv_out.ptr, @intCast(half_w * 2), @intCast(width), @intCast(height)) != 0) {
        return error.ConversionFailed;
    }
}

/// The camera color standard and range the frame descriptor carries, the
/// two axes that pick the RGB-to-YUV matrix. The GPU path selects the
/// matching shader constants; this is the CPU side of the same choice.
pub const Standard = enum { bt601, bt709, bt2020 };
pub const Range = enum { video, full };

fn argbConstantsFor(standard: Standard, range: Range) *const ArgbConstants {
    return switch (standard) {
        .bt601 => switch (range) {
            .video => &kAbgrI601Constants,
            .full => &kAbgrJPEGConstants,
        },
        .bt709 => switch (range) {
            .video => &kAbgrH709Constants,
            .full => &kAbgrF709Constants,
        },
        .bt2020 => switch (range) {
            .video => &kAbgrU2020Constants,
            .full => &kAbgrV2020Constants,
        },
    };
}

/// Converts tightly packed RGBA8 to NV12 for the caller's standard and
/// range, straight through libyuv with no scratch plane. y_out holds
/// width*height bytes, uv_out the interleaved half-resolution chroma.
pub fn argbToNv12(rgba: []const u8, width: u32, height: u32, standard: Standard, range: Range, y_out: []u8, uv_out: []u8) ConvertError!void {
    const w: usize = width;
    const h: usize = height;
    const half_w = (w + 1) / 2;
    const half_h = (h + 1) / 2;
    if (rgba.len < w * h * 4 or y_out.len < w * h or uv_out.len < half_w * 2 * half_h) return error.ConversionFailed;
    if (ARGBToNV12Matrix(rgba.ptr, @intCast(w * 4), y_out.ptr, @intCast(w), uv_out.ptr, @intCast(half_w * 2), argbConstantsFor(standard, range), @intCast(width), @intCast(height)) != 0) {
        return error.ConversionFailed;
    }
}

const t = std.testing;

// The same 8x8 checker PNG the desktop harness already proves through a
// real texture upload: alternating 4x4 white and red squares, fully
// opaque.
const checker_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x08, 0x06, 0x00, 0x00, 0x00, 0xc4, 0x0f, 0xbe,
    0x8b, 0x00, 0x00, 0x00, 0x19, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0x8f, 0x0e, 0x18,
    0x18, 0x50, 0x30, 0x03, 0x3d, 0x14, 0xa0, 0x09, 0x60, 0xa8, 0xa7, 0xbd, 0x02, 0x00, 0xa3, 0xc6,
    0xbf, 0x41, 0x50, 0xd7, 0xe9, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
    0x60, 0x82,
};

test "decodes a real PNG to the expected dimensions and its two solid colors" {
    const image = try decode(t.allocator, &checker_png);
    defer t.allocator.free(image.rgba);
    try t.expectEqual(@as(u32, 8), image.width);
    try t.expectEqual(@as(u32, 8), image.height);
    try t.expectEqual(@as(usize, 8 * 8 * 4), image.rgba.len);

    var saw_white = false;
    var saw_red = false;
    for (0..8) |row| {
        for (0..8) |col| {
            const px = image.rgba[(row * 8 + col) * 4 ..][0..4];
            try t.expectEqual(@as(u8, 255), px[3]);
            if (px[0] == 255 and px[1] == 255 and px[2] == 255) saw_white = true;
            if (px[0] == 255 and px[1] == 0 and px[2] == 0) saw_red = true;
        }
    }
    try t.expect(saw_white);
    try t.expect(saw_red);
}

test "rejects bytes that are not a valid PNG" {
    try t.expectError(error.InvalidPng, decode(t.allocator, "not a png"));
}

test "a solid color survives the round trip to NV12" {
    // Pure white, full range: Y saturates at 255 and both chroma
    // channels sit at the 128 midpoint.
    const w = 4;
    const h = 4;
    var rgba: [w * h * 4]u8 = @splat(255);
    var y_plane: [w * h]u8 = undefined;
    var uv_plane: [(w / 2) * 2 * (h / 2)]u8 = undefined;
    try rgbaToNv12(t.allocator, &rgba, w, h, &y_plane, &uv_plane);
    for (y_plane) |value| try t.expectEqual(@as(u8, 255), value);
    for (uv_plane) |value| try t.expectEqual(@as(u8, 128), value);
}

test "undersized planes refuse" {
    var rgba: [16]u8 = @splat(0);
    var y_plane: [1]u8 = undefined;
    var uv_plane: [2]u8 = undefined;
    try t.expectError(error.ConversionFailed, rgbaToNv12(t.allocator, &rgba, 2, 2, &y_plane, &uv_plane));
}

test "swapRedBlue turns rgba into bgra" {
    var pixels = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    try swapRedBlue(&pixels);
    try t.expectEqualSlices(u8, &.{ 30, 20, 10, 40, 70, 60, 50, 80 }, &pixels);
}

test "argbToNv12 encodes bt709 video-range anchors" {
    // Solid white lands near video-range luma 235, neutral chroma 128.
    const white = [_]u8{ 255, 255, 255, 255 } ** 4;
    var y: [4]u8 = undefined;
    var uv: [2]u8 = undefined;
    try argbToNv12(&white, 2, 2, .bt709, .video, &y, &uv);
    for (y) |v| try t.expect(@abs(@as(i32, v) - 235) <= 1);
    try t.expect(@abs(@as(i32, uv[0]) - 128) <= 1);
    try t.expect(@abs(@as(i32, uv[1]) - 128) <= 1);
}

test "argbRotate half turn reverses both axes" {
    // A 2x1 pair of distinct pixels comes back swapped after a half turn.
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dst: [8]u8 = undefined;
    try argbRotate(&src, 8, &dst, 8, 2, 1, .half);
    try t.expectEqualSlices(u8, &.{ 5, 6, 7, 8, 1, 2, 3, 4 }, &dst);
}

test "bgraToRgb drops alpha and reorders to rgb" {
    // One BGRA pixel (B=1,G=2,R=3,A=4) packs to RGB (3,2,1).
    const src = [_]u8{ 1, 2, 3, 4 };
    var dst: [3]u8 = undefined;
    try bgraToRgb(&src, 4, &dst, 3, 1, 1, false);
    try t.expectEqualSlices(u8, &.{ 3, 2, 1 }, &dst);
}

/// Box-filter downscales tightly packed RGBA8 to the output size - the
/// anti-aliasing pass for high-quality still capture. The box filter
/// averages each channel independently, so RGBA vs libyuv's ABGR word
/// order is irrelevant for a downscale. Deterministic.
pub fn downsampleBox(src: []const u8, src_width: u32, src_height: u32, dst: []u8, dst_width: u32, dst_height: u32) ConvertError!void {
    if (src.len < @as(usize, src_width) * src_height * 4 or dst.len < @as(usize, dst_width) * dst_height * 4) return error.ConversionFailed;
    // filtering 3 = kFilterBox (highest quality downscale).
    if (ARGBScale(src.ptr, @intCast(src_width * 4), @intCast(src_width), @intCast(src_height), dst.ptr, @intCast(dst_width * 4), @intCast(dst_width), @intCast(dst_height), 3) != 0) {
        return error.ConversionFailed;
    }
}

/// Swaps the red and blue channels of a packed 8-bit-per-channel image in
/// place - RGBA to BGRA and back, the one reorder a WebRTC source needs.
/// libyuv's ABGRToARGB is exactly that swizzle and is safe with src == dst.
pub fn swapRedBlue(pixels: []u8) ConvertError!void {
    const count: usize = pixels.len / 4;
    if (count == 0) return;
    if (ABGRToARGB(pixels.ptr, @intCast(count * 4), pixels.ptr, @intCast(count * 4), @intCast(count), 1) != 0) return error.ConversionFailed;
}

/// The rotations libyuv can apply while copying 4-byte-per-pixel data.
pub const Rotation = enum(c_int) { none = 0, cw90 = 90, half = 180, cw270 = 270 };

/// Rotates a packed 4-byte-per-pixel image into the caller's destination,
/// no allocation. A half turn is the both-axes flip the live upload paths
/// need to match a backend that samples the last texel as (0,0).
pub fn argbRotate(src: [*]const u8, src_stride: u32, dst: [*]u8, dst_stride: u32, width: u32, height: u32, rotation: Rotation) ConvertError!void {
    if (ARGBRotate(src, @intCast(src_stride), dst, @intCast(dst_stride), @intCast(width), @intCast(height), @intFromEnum(rotation)) != 0) return error.ConversionFailed;
}

/// Mirrors a packed 4-byte-per-pixel image horizontally into dst.
pub fn argbMirror(src: [*]const u8, src_stride: u32, dst: [*]u8, dst_stride: u32, width: u32, height: u32) ConvertError!void {
    if (ARGBMirror(src, @intCast(src_stride), dst, @intCast(dst_stride), @intCast(width), @intCast(height)) != 0) return error.ConversionFailed;
}

/// Packs BGRA8 into tightly interleaved 24-bit RGB, dropping alpha and
/// optionally flipping top-to-bottom - the screenshot writer's one pixel
/// step. A negative height is libyuv's own bottom-up-source convention.
pub fn bgraToRgb(src: [*]const u8, src_stride: u32, dst: [*]u8, dst_stride: u32, width: u32, height: u32, flip: bool) ConvertError!void {
    const h: c_int = if (flip) -@as(c_int, @intCast(height)) else @intCast(height);
    if (ARGBToRAW(src, @intCast(src_stride), dst, @intCast(dst_stride), @intCast(width), h) != 0) return error.ConversionFailed;
}

/// The chroma layout a decoder's YUV420 output carries: NV12 interleaves
/// UV, NV21 interleaves VU, I420 keeps three planes. A codec reports which.
pub const Yuv420 = enum { nv12, nv21, i420 };

/// Converts a decoder's YUV420 frame to tightly packed BGRA (libyuv ARGB
/// byte order), the pixel order the video texture uploads. `src_stride_y`
/// and `src_stride_uv` are the codec's own plane strides; for I420 the U
/// and V planes follow Y at half stride. BT.601, the camera/video default.
pub fn yuv420ToBgra(kind: Yuv420, y: [*]const u8, src_stride_y: u32, uv: [*]const u8, src_stride_uv: u32, dst: [*]u8, dst_stride: u32, width: u32, height: u32) ConvertError!void {
    const w: c_int = @intCast(width);
    const h: c_int = @intCast(height);
    const sy: c_int = @intCast(src_stride_y);
    const suv: c_int = @intCast(src_stride_uv);
    const ds: c_int = @intCast(dst_stride);
    const rc = switch (kind) {
        .nv12 => NV12ToARGB(y, sy, uv, suv, dst, ds, w, h),
        .nv21 => NV21ToARGB(y, sy, uv, suv, dst, ds, w, h),
        .i420 => blk: {
            // I420's U and V are separate half-height planes packed after Y.
            const u = y + (src_stride_y * height);
            const v = u + (src_stride_uv * ((height + 1) / 2));
            break :blk I420ToARGB(y, sy, u, suv, v, suv, dst, ds, w, h);
        },
    };
    if (rc != 0) return error.ConversionFailed;
}
