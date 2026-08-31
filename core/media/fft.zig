//! In-language radix-2 FFT over a comptime power-of-two size. A real signal feeds
//! in with a zero imaginary part; a forward then inverse is the identity. Shared
//! by the voice formant shifter and the music fingerprinter, so both stay
//! allocation-free and build the same on every target, freestanding wasm too.
const std = @import("std");

/// In-place complex FFT of `N` samples. `inverse` runs the conjugate transform
/// and scales by 1/N. `N` must be a power of two, checked at comptime.
pub fn transform(comptime N: usize, re: *[N]f32, im: *[N]f32, inverse: bool) void {
    comptime std.debug.assert(N > 0 and (N & (N - 1)) == 0);
    // Bit-reversal permutation.
    var j: usize = 0;
    for (0..N) |i| {
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
        var m = N >> 1;
        while (m >= 1 and j >= m) : (m >>= 1) j -= m;
        j += m;
    }
    var len: usize = 2;
    while (len <= N) : (len <<= 1) {
        const ang = (if (inverse) @as(f32, 2.0) else -2.0) * std.math.pi / @as(f32, @floatFromInt(len));
        const step_r = @cos(ang);
        const step_i = @sin(ang);
        var base: usize = 0;
        while (base < N) : (base += len) {
            var wr: f32 = 1;
            var wi: f32 = 0;
            const h = len >> 1;
            for (0..h) |k| {
                const a = base + k;
                const b = a + h;
                const tr = wr * re[b] - wi * im[b];
                const ti = wr * im[b] + wi * re[b];
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
                const nwr = wr * step_r - wi * step_i;
                wi = wr * step_i + wi * step_r;
                wr = nwr;
            }
        }
    }
    if (inverse) {
        const inv: f32 = 1.0 / @as(f32, @floatFromInt(N));
        for (0..N) |i| {
            re[i] *= inv;
            im[i] *= inv;
        }
    }
}

const t = std.testing;

test "a forward then inverse transform is the identity" {
    const N = 256;
    var re: [N]f32 = undefined;
    var im: [N]f32 = @splat(0);
    for (0..N) |i| re[i] = @sin(@as(f32, @floatFromInt(i)) * 0.3) + 0.5 * @cos(@as(f32, @floatFromInt(i)) * 0.11);
    const re0 = re;
    transform(N, &re, &im, false);
    transform(N, &re, &im, true);
    for (0..N) |i| try t.expectApproxEqAbs(re0[i], re[i], 1e-3);
}

test "a pure tone shows a single spectral line" {
    const N = 64;
    var re: [N]f32 = undefined;
    var im: [N]f32 = @splat(0);
    // Exactly four cycles across the window lands all energy in bin 4.
    for (0..N) |i| re[i] = @cos(2.0 * std.math.pi * 4.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N)));
    transform(N, &re, &im, false);
    var arg: usize = 0;
    var best: f32 = -1;
    for (0..N / 2 + 1) |k| {
        const mag = re[k] * re[k] + im[k] * im[k];
        if (mag > best) {
            best = mag;
            arg = k;
        }
    }
    try t.expectEqual(@as(usize, 4), arg);
}
