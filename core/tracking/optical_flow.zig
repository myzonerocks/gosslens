//! Single-level Lucas-Kanade dense optical flow and a backward warp, for
//! temporal coherence: estimate how content moved between two grayscale frames,
//! then warp a previous image by that flow so a per-frame restyle blends against
//! an aligned history instead of flickering. Deterministic, no allocation.

const std = @import("std");

/// Reads channel `c` of an rgb image at fractional (x, y) by bilinear
/// interpolation, clamping to the edge. nchw selects planar over interleaved
/// layout. A non-finite coordinate reads zero, so no NaN reaches the result.
pub fn sampleBilinear(src: []const f32, side: usize, nchw: bool, channels: usize, c: usize, x: f32, y: f32) f32 {
    if (!(x == x) or !(y == y)) return 0;
    const maxf: f32 = @floatFromInt(side - 1);
    const cx = std.math.clamp(x, 0, maxf);
    const cy = std.math.clamp(y, 0, maxf);
    const x0: usize = @intFromFloat(@floor(cx));
    const y0: usize = @intFromFloat(@floor(cy));
    const x1 = @min(x0 + 1, side - 1);
    const y1 = @min(y0 + 1, side - 1);
    const fx = cx - @as(f32, @floatFromInt(x0));
    const fy = cy - @as(f32, @floatFromInt(y0));
    const p00 = at(src, side, nchw, channels, c, x0, y0);
    const p10 = at(src, side, nchw, channels, c, x1, y0);
    const p01 = at(src, side, nchw, channels, c, x0, y1);
    const p11 = at(src, side, nchw, channels, c, x1, y1);
    const top = p00 + (p10 - p00) * fx;
    const bot = p01 + (p11 - p01) * fx;
    return top + (bot - top) * fy;
}

fn at(src: []const f32, side: usize, nchw: bool, channels: usize, c: usize, x: usize, y: usize) f32 {
    const plane = side * side;
    const idx = if (nchw) c * plane + y * side + x else (y * side + x) * channels + c;
    return src[idx];
}

/// Resamples an rgb image to a grayscale grid of `dst_side`, sampling the source
/// bilinearly and folding rgb to luma. Lets flow run at the output resolution
/// even when the source square is a different size.
pub fn toGrayResampled(src: []const f32, src_side: usize, nchw: bool, channels: usize, dst_side: usize, dst_gray: []f32) void {
    if (src_side == 0 or dst_side == 0) return;
    const scale: f32 = @as(f32, @floatFromInt(src_side)) / @as(f32, @floatFromInt(dst_side));
    for (0..dst_side) |dy| {
        const sy = (@as(f32, @floatFromInt(dy)) + 0.5) * scale - 0.5;
        for (0..dst_side) |dx| {
            const sx = (@as(f32, @floatFromInt(dx)) + 0.5) * scale - 0.5;
            const r = sampleBilinear(src, src_side, nchw, channels, 0, sx, sy);
            const g = sampleBilinear(src, src_side, nchw, channels, 1, sx, sy);
            const b = sampleBilinear(src, src_side, nchw, channels, 2, sx, sy);
            dst_gray[dy * dst_side + dx] = 0.299 * r + 0.587 * g + 0.114 * b;
        }
    }
}

fn grayAt(g: []const f32, side: usize, x: usize, y: usize) f32 {
    return g[y * side + x];
}

/// Dense Lucas-Kanade flow between `prev` and `curr` (grayscale, side x side),
/// solving the 2x2 normal equations over a (2*radius+1) window per pixel. The
/// field is the backward flow: warping `prev` by it aligns it with `curr`. A
/// window below `min_det`, or a non-finite solve, yields zero flow (trust fresh).
pub fn lucasKanade(prev: []const f32, curr: []const f32, side: usize, radius: usize, min_det: f32, flow_u: []f32, flow_v: []f32) void {
    if (side == 0) return;
    const last = side - 1;
    const max_flow: f32 = @as(f32, @floatFromInt(side)) * 0.25;
    for (0..side) |y| {
        for (0..side) |x| {
            var a11: f32 = 0;
            var a12: f32 = 0;
            var a22: f32 = 0;
            var b1: f32 = 0;
            var b2: f32 = 0;
            const wy0 = if (y >= radius) y - radius else 0;
            const wy1 = @min(y + radius, last);
            const wx0 = if (x >= radius) x - radius else 0;
            const wx1 = @min(x + radius, last);
            var wy = wy0;
            while (wy <= wy1) : (wy += 1) {
                var wx = wx0;
                while (wx <= wx1) : (wx += 1) {
                    const xm = if (wx > 0) wx - 1 else wx;
                    const xp = if (wx < last) wx + 1 else wx;
                    const ym = if (wy > 0) wy - 1 else wy;
                    const yp = if (wy < last) wy + 1 else wy;
                    const ix = (grayAt(curr, side, xp, wy) - grayAt(curr, side, xm, wy)) * 0.5;
                    const iy = (grayAt(curr, side, wx, yp) - grayAt(curr, side, wx, ym)) * 0.5;
                    const it = grayAt(curr, side, wx, wy) - grayAt(prev, side, wx, wy);
                    a11 += ix * ix;
                    a12 += ix * iy;
                    a22 += iy * iy;
                    b1 += ix * it;
                    b2 += iy * it;
                }
            }
            const det = a11 * a22 - a12 * a12;
            var u: f32 = 0;
            var v: f32 = 0;
            if (det > min_det) {
                // The backward flow is the negative of the forward LK solve, so
                // warping the previous frame by it aligns it with the current.
                u = (a22 * b1 - a12 * b2) / det;
                v = (a11 * b2 - a12 * b1) / det;
                if (!(u == u) or !(v == v)) {
                    u = 0;
                    v = 0;
                } else {
                    u = std.math.clamp(u, -max_flow, max_flow);
                    v = std.math.clamp(v, -max_flow, max_flow);
                }
            }
            flow_u[y * side + x] = u;
            flow_v[y * side + x] = v;
        }
    }
}

/// Backward-warps `src` by the flow into `dst`: each destination pixel samples
/// the source at its own position plus the flow there, so a previous frame lands
/// aligned with the current one. Every channel is warped by the same field.
pub fn warp(src: []const f32, side: usize, nchw: bool, channels: usize, flow_u: []const f32, flow_v: []const f32, dst: []f32) void {
    if (side == 0) return;
    for (0..side) |y| {
        for (0..side) |x| {
            const u = flow_u[y * side + x];
            const v = flow_v[y * side + x];
            const sx = @as(f32, @floatFromInt(x)) + u;
            const sy = @as(f32, @floatFromInt(y)) + v;
            for (0..channels) |c| {
                const value = sampleBilinear(src, side, nchw, channels, c, sx, sy);
                const idx = if (nchw) c * side * side + y * side + x else (y * side + x) * channels + c;
                dst[idx] = value;
            }
        }
    }
}

/// Mixes the freshly decoded image toward the warped history by `coherence`
/// (0 keeps the fresh frame, 1 holds the warped history), writing the blended
/// result back over `fresh`. This is the temporal filter the warp feeds.
pub fn blend(fresh: []f32, warped: []const f32, coherence: f32) void {
    const k = std.math.clamp(coherence, 0, 1);
    for (fresh, warped) |*f, w| f.* = f.* * (1 - k) + w * k;
}

const testing = std.testing;

test "warp inverts a whole-frame shift" {
    const side = 8;
    var src: [side * side]f32 = undefined;
    for (0..side) |y| for (0..side) |x| {
        src[y * side + x] = @floatFromInt(x);
    };
    // A constant flow of +1 in x pulls each pixel from one column to the right.
    var fu: [side * side]f32 = @splat(1.0);
    var fv: [side * side]f32 = @splat(0.0);
    var dst: [side * side]f32 = undefined;
    warp(&src, side, false, 1, &fu, &fv, &dst);
    // Interior columns now read the value one to their right.
    try testing.expectApproxEqAbs(@as(f32, 3.0), dst[2 * side + 2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5.0), dst[2 * side + 4], 1e-5);
}

fn ramp2d(x: f32, y: f32) f32 {
    // A pattern textured in both axes, so a window is full rank (no aperture
    // problem) and the solve can recover a shift.
    return @sin(x * 0.5) + 0.7 * @sin(y * 0.6);
}

test "lucas-kanade recovers a horizontal shift" {
    const side = 16;
    var prev: [side * side]f32 = undefined;
    var curr: [side * side]f32 = undefined;
    // The pattern shifted one column right between frames: curr(x,y)=prev(x-1,y).
    for (0..side) |y| for (0..side) |x| {
        const xf: f32 = @floatFromInt(x);
        const yf: f32 = @floatFromInt(y);
        prev[y * side + x] = ramp2d(xf, yf);
        curr[y * side + x] = ramp2d(xf - 1.0, yf);
    };
    var fu: [side * side]f32 = undefined;
    var fv: [side * side]f32 = undefined;
    lucasKanade(&prev, &curr, side, 2, 1e-4, &fu, &fv);
    // Content moved one column right, so the backward flow points left (~-1),
    // which is what warps the previous frame forward into alignment.
    try testing.expect(fu[8 * side + 8] < -0.5);
    try testing.expect(@abs(fv[8 * side + 8]) < 0.5);
}

test "blend holds the history at full coherence" {
    var fresh = [_]f32{ 0, 0, 0, 0 };
    const warped = [_]f32{ 1, 2, 3, 4 };
    blend(&fresh, &warped, 1.0);
    try testing.expectEqualSlices(f32, &warped, &fresh);
}

test "flat frames produce zero flow" {
    const side = 8;
    const flat: [side * side]f32 = @splat(0.5);
    var fu: [side * side]f32 = undefined;
    var fv: [side * side]f32 = undefined;
    lucasKanade(&flat, &flat, side, 2, 1e-4, &fu, &fv);
    for (fu) |u| try testing.expectEqual(@as(f32, 0), u);
    for (fv) |v| try testing.expectEqual(@as(f32, 0), v);
}
