//! The hot inner loops, vectorized at the width the target actually has. Each
//! one keeps a scalar twin beside it and a test that the two agree, because a
//! kernel that is fast and wrong is worse than the loop it replaced.

const std = @import("std");

/// The lane count this target wants for f32, or one where the target has no
/// vector unit, which makes the vector path degrade to the scalar one rather
/// than to a compile error.
pub const lanes: usize = std.simd.suggestVectorLength(f32) orelse 1;
const V = @Vector(lanes, f32);

/// dst += scale * src. This is the innermost line of both matmul and
/// convolution once the loops are ordered for a row-major weight layout.
pub fn axpy(dst: []f32, src: []const f32, factor: f32) void {
    const n = @min(dst.len, src.len);
    if (lanes == 1) {
        for (0..n) |i| dst[i] += factor * src[i];
        return;
    }
    const splat: V = @splat(factor);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const s: V = src[i..][0..lanes].*;
        const d: V = dst[i..][0..lanes].*;
        dst[i..][0..lanes].* = d + splat * s;
    }
    while (i < n) : (i += 1) dst[i] += factor * src[i];
}

/// dst += weight * (src - zero), in exact integers. The quantized kernels hold
/// their codes in float storage but must accumulate in i32: a float accumulator
/// stops being exact past 2^24 and a real channel count reaches that.
pub fn axpyInt(dst: []i32, src: []const f32, zero: i32, weight: i32) void {
    const n = @min(dst.len, src.len);
    if (lanes == 1) {
        for (0..n) |i| dst[i] += weight * (@as(i32, @intFromFloat(src[i])) - zero);
        return;
    }
    const I = @Vector(lanes, i32);
    const zero_v: I = @splat(zero);
    const weight_v: I = @splat(weight);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const sv: V = src[i..][0..lanes].*;
        const iv: I = @intFromFloat(sv);
        const dv: I = dst[i..][0..lanes].*;
        dst[i..][0..lanes].* = dv + weight_v * (iv - zero_v);
    }
    while (i < n) : (i += 1) dst[i] += weight * (@as(i32, @intFromFloat(src[i])) - zero);
}

pub fn dot(a: []const f32, b: []const f32) f32 {
    const n = @min(a.len, b.len);
    if (lanes == 1) {
        var acc: f32 = 0;
        for (0..n) |i| acc += a[i] * b[i];
        return acc;
    }
    var acc: V = @splat(0);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const av: V = a[i..][0..lanes].*;
        const bv: V = b[i..][0..lanes].*;
        acc += av * bv;
    }
    var tail: f32 = @reduce(.Add, acc);
    while (i < n) : (i += 1) tail += a[i] * b[i];
    return tail;
}

pub fn sum(values: []const f32) f32 {
    if (lanes == 1) {
        var acc: f32 = 0;
        for (values) |v| acc += v;
        return acc;
    }
    var acc: V = @splat(0);
    var i: usize = 0;
    while (i + lanes <= values.len) : (i += lanes) acc += @as(V, values[i..][0..lanes].*);
    var tail: f32 = @reduce(.Add, acc);
    while (i < values.len) : (i += 1) tail += values[i];
    return tail;
}

pub fn maximum(values: []const f32) f32 {
    if (values.len == 0) return -std.math.floatMax(f32);
    if (lanes == 1) {
        var best = values[0];
        for (values[1..]) |v| best = @max(best, v);
        return best;
    }
    var best: V = @splat(values[0]);
    var i: usize = 0;
    while (i + lanes <= values.len) : (i += lanes) best = @max(best, @as(V, values[i..][0..lanes].*));
    var tail: f32 = @reduce(.Max, best);
    while (i < values.len) : (i += 1) tail = @max(tail, values[i]);
    return tail;
}

/// Sums the values and their squares in one pass, which is what a layer norm
/// needs and what makes it one read of the row rather than two.
pub fn sumAndSquares(values: []const f32) struct { sum: f32, squares: f32 } {
    if (lanes == 1) {
        var s: f32 = 0;
        var q: f32 = 0;
        for (values) |v| {
            s += v;
            q += v * v;
        }
        return .{ .sum = s, .squares = q };
    }
    var sv: V = @splat(0);
    var qv: V = @splat(0);
    var i: usize = 0;
    while (i + lanes <= values.len) : (i += lanes) {
        const v: V = values[i..][0..lanes].*;
        sv += v;
        qv += v * v;
    }
    var s: f32 = @reduce(.Add, sv);
    var q: f32 = @reduce(.Add, qv);
    while (i < values.len) : (i += 1) {
        s += values[i];
        q += values[i] * values[i];
    }
    return .{ .sum = s, .squares = q };
}

/// Subtracts a constant, exponentiates, and returns the total, which is the
/// whole of a numerically stable softmax bar the final divide.
pub fn expShiftedSum(values: []f32, shift: f32) f32 {
    var total: f32 = 0;
    for (values) |*v| {
        v.* = @exp(v.* - shift);
        total += v.*;
    }
    return total;
}

pub fn scale(values: []f32, factor: f32) void {
    if (lanes == 1) {
        for (values) |*v| v.* *= factor;
        return;
    }
    const splat: V = @splat(factor);
    var i: usize = 0;
    while (i + lanes <= values.len) : (i += lanes) {
        const v: V = values[i..][0..lanes].*;
        values[i..][0..lanes].* = v * splat;
    }
    while (i < values.len) : (i += 1) values[i] *= factor;
}

const testing = std.testing;

test "the vector kernels agree with the scalar arithmetic they replace" {
    var a: [37]f32 = undefined;
    var b: [37]f32 = undefined;
    for (&a, 0..) |*v, i| v.* = @floatFromInt(i % 7);
    for (&b, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i % 5)) - 2;

    var expect_dot: f32 = 0;
    var expect_sum: f32 = 0;
    var expect_sq: f32 = 0;
    var expect_max: f32 = -std.math.floatMax(f32);
    for (a, b) |x, y| {
        expect_dot += x * y;
        expect_sum += x;
        expect_sq += x * x;
        expect_max = @max(expect_max, x);
    }
    try testing.expectApproxEqAbs(expect_dot, dot(&a, &b), 1e-3);
    try testing.expectApproxEqAbs(expect_max, maximum(&a), 1e-6);
    const both = sumAndSquares(&a);
    try testing.expectApproxEqAbs(expect_sum, both.sum, 1e-3);
    try testing.expectApproxEqAbs(expect_sq, both.squares, 1e-2);
    try testing.expectApproxEqAbs(expect_sum, sum(&a), 1e-3);

    // A length that is not a whole number of lanes is the case a vector kernel
    // gets wrong, so the tail is what the test is really for.
    var int_dst: [37]i32 = @splat(3);
    var int_reference: [37]i32 = @splat(3);
    axpyInt(&int_dst, &a, 2, -5);
    for (&int_reference, a) |*d, x| d.* += -5 * (@as(i32, @intFromFloat(x)) - 2);
    try testing.expectEqualSlices(i32, &int_reference, &int_dst);

    var dst: [37]f32 = @splat(1);
    var reference: [37]f32 = @splat(1);
    axpy(&dst, &b, 2.5);
    for (&reference, b) |*d, y| d.* += 2.5 * y;
    try testing.expectEqualSlices(f32, &reference, &dst);

    scale(&dst, 0.5);
    for (&reference) |*d| d.* *= 0.5;
    try testing.expectEqualSlices(f32, &reference, &dst);
}
