//! The CPU reference conversion, the number the GPU path is measured against.
//! The shader consumes the same matrix through a uniform, so the two agreeing is
//! a real check on the uniform plumbing rather than on the arithmetic alone: a
//! matrix transposed on its way into the shader converts every frame wrong and no
//! test of the matrix by itself would notice.

const std = @import("std");
const types = @import("types.zig");
const color = @import("math").color;

/// One YCbCr triple, 8-bit codes, to 8-bit RGB under the frame's own metadata.
/// Saturating, because a video-range code outside 16..235 is legal in a real
/// stream and wrapping it produces a bright pixel where a dark one belongs.
pub fn yuvToRgb8(info: types.ColorInfo, y: u8, cb: u8, cr: u8) [3]u8 {
    const standard: color.Standard = switch (types.matrixStandard(info)) {
        .bt601 => .bt601,
        .bt709 => .bt709,
        .bt2020 => .bt2020,
    };
    const range: color.Range = if (types.isFullRange(info)) .full else .video;
    const conversion = color.yuvToRgb(standard, range);
    const normalized: @Vector(3, f32) = .{
        @as(f32, @floatFromInt(y)) / 255.0,
        @as(f32, @floatFromInt(cb)) / 255.0,
        @as(f32, @floatFromInt(cr)) / 255.0,
    };
    const rgb = conversion.apply(normalized);
    return .{ clamp8(rgb[0]), clamp8(rgb[1]), clamp8(rgb[2]) };
}

fn clamp8(v: f32) u8 {
    const scaled = v * 255.0;
    if (!(scaled > 0.0)) return 0;
    if (scaled > 255.0) return 255;
    return @intFromFloat(@round(scaled));
}

/// The largest per-channel difference between two images, which is what a
/// tolerance is stated against. Zero means identical.
pub fn maxChannelDelta(a: []const u8, b: []const u8) u8 {
    const n = @min(a.len, b.len);
    var worst: u8 = 0;
    for (0..n) |i| {
        const d = if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i];
        if (d > worst) worst = d;
    }
    return worst;
}

const t = std.testing;

test "video range black and white land on the ends" {
    const video: types.ColorInfo = .{};
    // Code 16 is black and code 235 is white in video range; a full-range
    // conversion of the same codes would lift black and clip nothing.
    const black = yuvToRgb8(video, 16, 128, 128);
    try t.expectEqual([3]u8{ 0, 0, 0 }, black);
    const white = yuvToRgb8(video, 235, 128, 128);
    for (white) |c| try t.expect(c >= 254);
}

test "full range black is code zero, not code sixteen" {
    const full: types.ColorInfo = .{ .range = .full };
    try t.expectEqual([3]u8{ 0, 0, 0 }, yuvToRgb8(full, 0, 128, 128));
    // The same code under a full-range map is no longer black, which is exactly
    // the mistake a wrong range flag makes on every frame.
    const lifted = yuvToRgb8(full, 16, 128, 128);
    try t.expect(lifted[0] > 0);
}

test "the standards differ where their coefficients differ" {
    const bt601: types.ColorInfo = .{ .matrix = .bt601 };
    const bt709: types.ColorInfo = .{ .matrix = .bt709 };
    // A saturated red chroma separates them: the green channel is where the
    // luma coefficients disagree most.
    const a = yuvToRgb8(bt601, 128, 90, 200);
    const b = yuvToRgb8(bt709, 128, 90, 200);
    try t.expect(a[1] != b[1]);
}

test "a code outside the video range saturates rather than wrapping" {
    const video: types.ColorInfo = .{};
    // Below 16 and above 235 are legal in a real stream. Wrapping would put a
    // bright pixel where a dark one belongs.
    try t.expectEqual(@as(u8, 0), yuvToRgb8(video, 0, 128, 128)[0]);
    try t.expectEqual(@as(u8, 255), yuvToRgb8(video, 255, 128, 128)[0]);
}

test "a neutral chroma leaves the three channels equal" {
    for ([_]types.ColorInfo{ .{}, .{ .range = .full }, .{ .matrix = .bt2020_ncl, .primaries = .bt2020 } }) |info| {
        const grey = yuvToRgb8(info, 128, 128, 128);
        try t.expectEqual(grey[0], grey[1]);
        try t.expectEqual(grey[1], grey[2]);
    }
}

test "the delta of an image with itself is zero, and a shift is the shift" {
    const a = [_]u8{ 10, 20, 30, 40 };
    try t.expectEqual(@as(u8, 0), maxChannelDelta(&a, &a));
    const b = [_]u8{ 10, 20, 37, 40 };
    try t.expectEqual(@as(u8, 7), maxChannelDelta(&a, &b));
}
