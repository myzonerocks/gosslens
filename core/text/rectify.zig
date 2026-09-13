//! Unwarping a detected quadrilateral to an upright crop. The recogniser reads
//! one, and so does an agent handed the region directly, so this is the single
//! place a perspective is undone rather than each caller doing it again.

const std = @import("std");
const region = @import("region.zig");

const Point = region.Point;
const Quad = region.Quad;

/// The projective map from the unit square to a quadrilateral. Eight
/// coefficients, solved once per region, then every output pixel is two
/// multiplies and a divide.
pub const Homography = struct {
    m: [8]f32,

    /// Maps (u, v) in the unit square to the frame, which is the direction the
    /// sampler needs: it walks the output and reads the input.
    pub fn apply(hg: Homography, u: f32, v: f32) Point {
        const d = hg.m[6] * u + hg.m[7] * v + 1;
        if (d == 0) return .{ .x = 0, .y = 0 };
        return .{
            .x = (hg.m[0] * u + hg.m[1] * v + hg.m[2]) / d,
            .y = (hg.m[3] * u + hg.m[4] * v + hg.m[5]) / d,
        };
    }

    /// Solves for the map taking the unit square's corners to the quad's, in
    /// reading order. A degenerate quad gives an affine fallback rather than a
    /// divide by zero, so a collapsed detection still produces a readable crop.
    pub fn toQuad(q: Quad) Homography {
        const p0 = q.corners[0];
        const p1 = q.corners[1];
        const p2 = q.corners[2];
        const p3 = q.corners[3];

        const dx1 = p1.x - p2.x;
        const dx2 = p3.x - p2.x;
        const dy1 = p1.y - p2.y;
        const dy2 = p3.y - p2.y;
        const sx = p0.x - p1.x + p2.x - p3.x;
        const sy = p0.y - p1.y + p2.y - p3.y;

        const den = dx1 * dy2 - dx2 * dy1;
        var g: f32 = 0;
        var hcoef: f32 = 0;
        if (@abs(den) > 1e-12) {
            g = (sx * dy2 - dx2 * sy) / den;
            hcoef = (dx1 * sy - sx * dy1) / den;
        }
        return .{ .m = .{
            p1.x - p0.x + g * p1.x,
            p3.x - p0.x + hcoef * p3.x,
            p0.x,
            p1.y - p0.y + g * p1.y,
            p3.y - p0.y + hcoef * p3.y,
            p0.y,
            g,
            hcoef,
        } };
    }
};

pub const Plane = struct {
    pixels: []const u8,
    width: usize,
    height: usize,
    /// Bytes per pixel: 1 for luminance, 4 for RGBA.
    channels: usize,
    stride: usize,
};

/// Writes the quad's content into an upright crop of out_w by out_h, sampling
/// bilinearly. The crop is the recogniser's input and the agent's thumbnail,
/// and it allocates nothing: the caller owns both buffers.
pub fn rectify(src: Plane, quad: Quad, out: []u8, out_w: usize, out_h: usize) void {
    if (out_w == 0 or out_h == 0 or src.channels == 0) return;
    if (out.len < out_w * out_h * src.channels) return;
    const hg = Homography.toQuad(quad);
    const fw: f32 = @floatFromInt(src.width);
    const fh: f32 = @floatFromInt(src.height);

    for (0..out_h) |y| {
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(out_h));
        for (0..out_w) |x| {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(out_w));
            const p = hg.apply(u, v);
            // The quad is in normalized frame space, so the sample lands in
            // pixels only here, at the one place that knows the plane's size.
            const sx = p.x * fw - 0.5;
            const sy = p.y * fh - 0.5;
            const dst = (y * out_w + x) * src.channels;
            sampleBilinear(src, sx, sy, out[dst..][0..src.channels]);
        }
    }
}

fn sampleBilinear(src: Plane, sx: f32, sy: f32, out: []u8) void {
    const x0f = @floor(sx);
    const y0f = @floor(sy);
    const tx = sx - x0f;
    const ty = sy - y0f;
    const x0 = clampIndex(x0f, src.width);
    const y0 = clampIndex(y0f, src.height);
    const x1 = clampIndex(x0f + 1, src.width);
    const y1 = clampIndex(y0f + 1, src.height);

    for (out, 0..) |*channel, c| {
        const v00: f32 = @floatFromInt(src.pixels[y0 * src.stride + x0 * src.channels + c]);
        const v10: f32 = @floatFromInt(src.pixels[y0 * src.stride + x1 * src.channels + c]);
        const v01: f32 = @floatFromInt(src.pixels[y1 * src.stride + x0 * src.channels + c]);
        const v11: f32 = @floatFromInt(src.pixels[y1 * src.stride + x1 * src.channels + c]);
        const top = v00 * (1 - tx) + v10 * tx;
        const bottom = v01 * (1 - tx) + v11 * tx;
        channel.* = @intFromFloat(@max(0, @min(255, @round(top * (1 - ty) + bottom * ty))));
    }
}

fn clampIndex(v: f32, extent: usize) usize {
    if (v <= 0) return 0;
    const i: usize = @intFromFloat(v);
    return @min(i, extent - 1);
}

/// A content hash of a rectified crop, so a region whose pixels have not moved
/// skips recognition. Watching a static sign should cost nothing, and this is
/// what makes that true.
pub fn contentHash(crop: []const u8) u64 {
    return std.hash.Wyhash.hash(0x7e47, crop);
}

const testing = std.testing;

test "an axis-aligned quad rectifies to the pixels under it" {
    // A 4x4 luminance ramp; the top-left 2x2 quad must come back as those four.
    const pixels = [_]u8{
        10,  20,  30,  40,
        50,  60,  70,  80,
        90,  100, 110, 120,
        130, 140, 150, 160,
    };
    const src: Plane = .{ .pixels = &pixels, .width = 4, .height = 4, .channels = 1, .stride = 4 };
    const q: Quad = .{ .corners = .{
        .{ .x = 0, .y = 0 },
        .{ .x = 0.5, .y = 0 },
        .{ .x = 0.5, .y = 0.5 },
        .{ .x = 0, .y = 0.5 },
    } };
    var out: [4]u8 = undefined;
    rectify(src, q, &out, 2, 2);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 50, 60 }, &out);
}

test "a rotated quad comes back upright" {
    // A 5x5 plane with a bright diagonal; a quad along that diagonal rectifies
    // to a crop that is bright all the way across its middle row.
    var pixels: [25]u8 = @splat(0);
    for (0..5) |i| pixels[i * 5 + i] = 255;
    const src: Plane = .{ .pixels = &pixels, .width = 5, .height = 5, .channels = 1, .stride = 5 };
    const q: Quad = .{ .corners = .{
        .{ .x = 0.02, .y = 0.14 },
        .{ .x = 0.86, .y = 0.98 },
        .{ .x = 0.98, .y = 0.86 },
        .{ .x = 0.14, .y = 0.02 },
    } };
    var out: [3 * 9]u8 = undefined;
    rectify(src, q, &out, 9, 3);
    var bright: usize = 0;
    for (out[9..18]) |v| {
        if (v > 120) bright += 1;
    }
    try testing.expect(bright >= 7);
}

test "the content hash changes only when the crop does" {
    const a = [_]u8{ 1, 2, 3, 4, 5 };
    const b = [_]u8{ 1, 2, 3, 4, 5 };
    const c = [_]u8{ 1, 2, 3, 4, 6 };
    try testing.expectEqual(contentHash(&a), contentHash(&b));
    try testing.expect(contentHash(&a) != contentHash(&c));
}
