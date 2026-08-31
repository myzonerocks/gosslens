//! Real-time formant shifter: warps a voice's spectral envelope by a ratio
//! without moving its pitch. A short-time cepstrum splits each block into a
//! smooth envelope (the formants) and the pitch harmonics, warps the envelope,
//! then resynthesises with the harmonics and phase intact - pure, in-language FFT.
const std = @import("std");

/// Analysis/synthesis block and hop. A 512-tap block at 48 kHz resolves formants
/// to ~94 Hz bins with ~11 ms latency; a quarter-block hop gives the Hann pair a
/// constant overlap-add sum, so the reconstruction is flat when the ratio is one.
pub const block: usize = 512;
pub const hop: usize = 128;
const half: usize = block / 2;

/// Cepstral cutoff: quefrency below this is the spectral envelope (the formants),
/// above it the pitch harmonics. It sits well under a voiced period (a 150 Hz
/// voice peaks near quefrency 320), so the split keeps pitch out of the envelope.
const lifter: usize = 48;

/// Per-channel streaming state: the input ring the sliding block reads, the
/// overlap-add accumulator, and the output queue that holds the one-block latency.
pub const Channel = struct {
    ring: [block]f32 = @splat(0),
    w: usize = 0,
    since: usize = 0,
    ola: [block]f32 = @splat(0),
    out_q: [block]f32 = @splat(0),
    out_head: usize = 0,
    out_len: usize = 0,
    primed: bool = false,

    pub fn reset(self: *Channel) void {
        self.* = .{};
    }
};

/// The periodic Hann window, used for both analysis and synthesis so a
/// quarter-block hop overlaps to a constant. Built once at comptime.
const hann: [block]f32 = blk: {
    @setEvalBranchQuota(20000);
    var w: [block]f32 = undefined;
    for (&w, 0..) |*v, i| {
        const p = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(block));
        v.* = @floatCast(0.5 - 0.5 * @cos(p));
    }
    break :blk w;
};

/// The overlap-add sum of the squared Hann across a quarter-block hop. Dividing
/// the resynthesised block by this makes a ratio-of-one pass through unchanged.
const wola_norm: f32 = blk: {
    @setEvalBranchQuota(20000);
    var acc: f64 = 0;
    const overlaps: isize = @intCast(block / hop);
    var m: isize = -overlaps;
    while (m <= overlaps) : (m += 1) {
        const idx = @as(isize, @intCast(half)) + m * @as(isize, @intCast(hop));
        if (idx >= 0 and idx < block) {
            const wv: f64 = hann[@intCast(idx)];
            acc += wv * wv;
        }
    }
    break :blk @floatCast(acc);
};

/// In-place iterative radix-2 FFT of a power-of-two block. `inverse` runs the
/// conjugate transform and scales by 1/N, so a forward then inverse is identity.
fn fft(re: *[block]f32, im: *[block]f32, inverse: bool) void {
    // Bit-reversal permutation.
    var j: usize = 0;
    for (0..block) |i| {
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
        var m = half;
        while (m >= 1 and j >= m) : (m >>= 1) j -= m;
        j += m;
    }
    var len: usize = 2;
    while (len <= block) : (len <<= 1) {
        const ang = (if (inverse) @as(f32, 2.0) else -2.0) * std.math.pi / @as(f32, @floatFromInt(len));
        const step_r = @cos(ang);
        const step_i = @sin(ang);
        var base: usize = 0;
        while (base < block) : (base += len) {
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
        const inv: f32 = 1.0 / @as(f32, @floatFromInt(block));
        for (0..block) |i| {
            re[i] *= inv;
            im[i] *= inv;
        }
    }
}

/// Resamples the log-envelope's lower half (bins 0..=half) by `ratio`: bin k
/// reads the source envelope at k/ratio, so a ratio above one lifts the formants
/// toward higher frequencies and below one lowers them. Out-of-range reads clamp
/// to the band edge, holding the envelope flat past where it is defined.
pub fn warpEnvelope(env: []const f32, out: []f32, ratio: f32) void {
    const top = env.len - 1;
    for (out, 0..) |*o, k| {
        const src = @as(f32, @floatFromInt(k)) / ratio;
        if (src <= 0) {
            o.* = env[0];
        } else if (src >= @as(f32, @floatFromInt(top))) {
            o.* = env[top];
        } else {
            const i: usize = @intFromFloat(src);
            const frac = src - @as(f32, @floatFromInt(i));
            o.* = env[i] * (1.0 - frac) + env[i + 1] * frac;
        }
    }
}

/// Transforms one block: window, FFT, split the log-magnitude into a liftered
/// envelope and a residual, warp the envelope by `ratio`, and reapply it as a
/// per-bin gain that keeps the original phase. Returns the resynthesis-windowed
/// time block for overlap-add. All scratch is on the stack.
fn transformBlock(frame: *const [block]f32, ratio: f32, out: *[block]f32) void {
    var re: [block]f32 = undefined;
    var im: [block]f32 = @splat(0);
    for (0..block) |i| re[i] = frame[i] * hann[i];
    fft(&re, &im, false);

    // Log-magnitude across the full symmetric spectrum.
    var lm: [block]f32 = undefined;
    const eps: f32 = 1e-9;
    for (0..block) |k| lm[k] = 0.5 * @log(re[k] * re[k] + im[k] * im[k] + eps);

    // Real cepstrum, then a rectangular low-quefrency lifter isolates the envelope.
    var cre: [block]f32 = lm;
    var cim: [block]f32 = @splat(0);
    fft(&cre, &cim, true);
    for (lifter..block - lifter + 1) |q| {
        cre[q] = 0;
        cim[q] = 0;
    }
    fft(&cre, &cim, false);

    // The smoothed log-envelope over the lower half, warped by the ratio.
    var env: [half + 1]f32 = undefined;
    for (0..half + 1) |k| env[k] = cre[k];
    var warped: [half + 1]f32 = undefined;
    warpEnvelope(&env, &warped, ratio);

    // Reapply as a gain that moves the formants but keeps the harmonic residual
    // and each bin's phase; mirror the gain onto the conjugate upper half.
    for (0..half + 1) |k| {
        const g = @exp(warped[k] - env[k]);
        re[k] *= g;
        im[k] *= g;
        if (k > 0 and k < half) {
            const mk = block - k;
            re[mk] *= g;
            im[mk] *= g;
        }
    }
    fft(&re, &im, true);
    const norm = 1.0 / wola_norm;
    for (0..block) |i| out[i] = re[i] * hann[i] * norm;
}

/// Runs the block whose newest sample just landed: it reads the last `block`
/// inputs from the ring, transforms them, overlaps the result into the
/// accumulator, and moves the finished hop into the output queue.
fn runBlock(ch: *Channel, ratio: f32) void {
    var frame: [block]f32 = undefined;
    for (0..block) |i| frame[i] = ch.ring[(ch.w + i) % block];
    var out: [block]f32 = undefined;
    transformBlock(&frame, ratio, &out);
    for (0..block) |i| ch.ola[i] += out[i];

    // The oldest hop is complete: queue it, then slide the accumulator down.
    for (0..hop) |i| {
        const slot = (ch.out_head + ch.out_len + i) % block;
        ch.out_q[slot] = ch.ola[i];
    }
    ch.out_len += hop;
    for (0..block - hop) |i| ch.ola[i] = ch.ola[i + hop];
    for (block - hop..block) |i| ch.ola[i] = 0;
    ch.primed = true;
}

/// Streams one sample through the shifter, returning the shifted sample delayed
/// by one block. Before the first block fills, the dry sample passes through so
/// the effect ramps in rather than opening on silence.
pub fn processSample(ch: *Channel, x: f32, ratio: f32) f32 {
    ch.ring[ch.w] = x;
    ch.w = (ch.w + 1) % block;
    ch.since += 1;
    if (ch.since == hop) {
        ch.since = 0;
        runBlock(ch, ratio);
    }
    if (!ch.primed or ch.out_len == 0) return x;
    const y = ch.out_q[ch.out_head];
    ch.out_head = (ch.out_head + 1) % block;
    ch.out_len -= 1;
    return y;
}

const t = std.testing;

test "the overlap-add reconstructs a tone unchanged at a ratio of one" {
    var ch = Channel{};
    const sr: f32 = 48000;
    const freq: f32 = 300;
    const n = block * 8;
    var dry: [block * 8]f32 = undefined;
    var wet: [block * 8]f32 = undefined;
    for (0..n) |i| {
        const s = @sin(2.0 * std.math.pi * freq * @as(f32, @floatFromInt(i)) / sr);
        dry[i] = s;
        wet[i] = processSample(&ch, s, 1.0);
    }
    // A ratio of one is a spectral identity, so the wet output is the input
    // delayed by the pipeline's latency. Find the delay that lines them up and
    // assert the residual is tiny, over a steady region past the priming ramp.
    var best_err: f32 = 1e9;
    for (block - hop..block + hop) |d| {
        var m: f32 = 0;
        for (block * 3..n) |i| {
            const e = @abs(wet[i] - dry[i - d]);
            if (e > m) m = e;
        }
        if (m < best_err) best_err = m;
    }
    try t.expect(best_err < 0.02);
}

test "warping the envelope moves a formant peak by the ratio" {
    // A triangular bump standing in for a formant, peaking at bin 40.
    var env: [half + 1]f32 = @splat(0);
    const peak: usize = 40;
    for (0..half + 1) |k| {
        const d: f32 = @abs(@as(f32, @floatFromInt(@as(i32, @intCast(k)))) - @as(f32, @floatFromInt(peak)));
        env[k] = @max(0.0, 20.0 - d);
    }
    var warped: [half + 1]f32 = undefined;
    warpEnvelope(&env, &warped, 1.5);

    // The peak should now sit near bin 60 (40 * 1.5).
    var arg: usize = 0;
    var best: f32 = -1e9;
    for (warped, 0..) |v, k| {
        if (v > best) {
            best = v;
            arg = k;
        }
    }
    try t.expect(arg >= 58 and arg <= 62);
}

test "a ratio of one leaves the warped envelope identical" {
    var env: [half + 1]f32 = undefined;
    for (0..half + 1) |k| env[k] = @sin(@as(f32, @floatFromInt(k)) * 0.1);
    var warped: [half + 1]f32 = undefined;
    warpEnvelope(&env, &warped, 1.0);
    for (0..half + 1) |k| try t.expectApproxEqAbs(env[k], warped[k], 1e-5);
}
