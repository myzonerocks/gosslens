//! A deterministic few-step diffusion schedule: the beta/alpha noise schedule a
//! latent-diffusion model trains under, the timesteps a short sampler visits,
//! the add-noise for img2img, and the DDIM update between steps. Pure f32 math
//! with no clock and no randomness, so a restyle is bit-stable across runs.

const std = @import("std");

/// The most training timesteps a schedule tabulates; the common value is 1000.
pub const max_train_steps = 1000;

/// The most sampler steps a few-step restyle runs. Live restyle wants a handful
/// of steps, not the tens a still would take.
pub const max_steps = 16;

pub const Schedule = struct {
    train_steps: usize,
    /// alpha_bar[t] = product of (1 - beta[i]) for i in 0..=t, the cumulative
    /// signal retention at timestep t under a linear beta schedule.
    alpha_bar: [max_train_steps]f32,

    /// Builds the linear-beta schedule latent diffusion trains under. The
    /// defaults (0.00085, 0.012, scaled-linear) match the common latent models.
    pub fn init(train_steps: usize, beta_start: f32, beta_end: f32) Schedule {
        var s: Schedule = .{ .train_steps = @min(train_steps, max_train_steps), .alpha_bar = @splat(1) };
        // Scaled-linear beta: beta[t] = (lerp(sqrt(beta_start), sqrt(beta_end)))^2.
        var acc: f32 = 1;
        const n = s.train_steps;
        const sqrt_start = @sqrt(beta_start);
        const sqrt_end = @sqrt(beta_end);
        for (0..n) |t| {
            const frac = if (n > 1) @as(f32, @floatFromInt(t)) / @as(f32, @floatFromInt(n - 1)) else 0;
            const sqrt_beta = sqrt_start + (sqrt_end - sqrt_start) * frac;
            const beta = sqrt_beta * sqrt_beta;
            acc *= (1 - beta);
            s.alpha_bar[t] = acc;
        }
        return s;
    }

    pub fn alphaBar(s: *const Schedule, t: usize) f32 {
        if (t >= s.train_steps) return s.alpha_bar[s.train_steps - 1];
        return s.alpha_bar[t];
    }

    /// The descending timesteps an n-step sampler visits, evenly spaced across
    /// the training range. Returns the slice of `out` it filled.
    pub fn timesteps(s: *const Schedule, n_steps: usize, out: []i32) []i32 {
        const n = @min(@min(n_steps, max_steps), out.len);
        if (n == 0) return out[0..0];
        const last = @as(f32, @floatFromInt(s.train_steps - 1));
        for (0..n) |i| {
            // step i maps high->low so the loop denoises from noisy to clean.
            const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            out[i] = @intFromFloat(last * (1 - frac));
        }
        return out[0..n];
    }

    /// img2img seed: latent_t = sqrt(ab_t) * latent + sqrt(1 - ab_t) * noise, so
    /// a higher timestep buries more of the source under noise (more restyle).
    pub fn addNoise(s: *const Schedule, latent: []const f32, noise: []const f32, t: usize, out: []f32) void {
        const ab = s.alphaBar(t);
        const a = @sqrt(ab);
        const b = @sqrt(@max(1 - ab, 0));
        for (out, latent, noise) |*o, l, nz| o.* = a * l + b * nz;
    }

    /// One DDIM update (deterministic, eta=0): recover the predicted clean
    /// latent from the model's noise estimate, then re-noise it to the previous
    /// timestep. t_prev < t; at the last step t_prev is zero (fully denoised).
    pub fn ddimStep(s: *const Schedule, latent_t: []const f32, noise_pred: []const f32, t: usize, t_prev: usize, out: []f32) void {
        const ab_t = s.alphaBar(t);
        const ab_prev = if (t_prev == 0) 1.0 else s.alphaBar(t_prev);
        const sqrt_ab_t = @sqrt(ab_t);
        const sqrt_one_minus = @sqrt(@max(1 - ab_t, 0));
        const sqrt_ab_prev = @sqrt(ab_prev);
        const sqrt_one_minus_prev = @sqrt(@max(1 - ab_prev, 0));
        for (out, latent_t, noise_pred) |*o, lt, np| {
            const pred_x0 = (lt - sqrt_one_minus * np) / sqrt_ab_t;
            o.* = sqrt_ab_prev * pred_x0 + sqrt_one_minus_prev * np;
        }
    }
};

/// Fills buf with deterministic standard-normal noise from a seed: a hash per
/// element pair driven through Box-Muller, so the same seed yields the same
/// noise on every run and platform with no clock or PRNG state.
pub fn fillNoise(buf: []f32, seed: u64) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 2) {
        const u1_bits = hash(seed, @intCast(i));
        const u2_bits = hash(seed, @intCast(i + 1));
        // Two uniforms in (0, 1]; keep u1 off zero so the log is finite.
        const u1v = (@as(f32, @floatFromInt(u1_bits >> 8)) + 1.0) / @as(f32, @floatFromInt((1 << 24) + 1));
        const u2v = @as(f32, @floatFromInt(u2_bits >> 8)) / @as(f32, @floatFromInt(1 << 24));
        const r = @sqrt(-2.0 * @log(u1v));
        const theta = 2.0 * std.math.pi * u2v;
        buf[i] = r * @cos(theta);
        if (i + 1 < buf.len) buf[i + 1] = r * @sin(theta);
    }
}

/// A small integer hash (splitmix-style) mixing the seed and index into 24
/// usable low bits, deterministic on every target.
fn hash(seed: u64, index: u64) u32 {
    var x = seed +% (index +% 1) *% 0x9E3779B97F4A7C15;
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    x = x ^ (x >> 31);
    return @truncate(x);
}

const testing = std.testing;

test "add-noise at timestep zero keeps the source, and is bit-stable" {
    const s = Schedule.init(1000, 0.00085, 0.012);
    const latent = [_]f32{ 0.5, -0.25, 1.0, 0.0 };
    var noise: [4]f32 = undefined;
    fillNoise(&noise, 42);
    var out: [4]f32 = undefined;
    s.addNoise(&latent, &noise, 0, &out);
    // alpha_bar[0] is very close to 1, so the source dominates at t=0.
    try testing.expectApproxEqAbs(latent[0], out[0], 0.05);
    // Same seed reproduces the same noise exactly.
    var noise2: [4]f32 = undefined;
    fillNoise(&noise2, 42);
    try testing.expectEqualSlices(f32, &noise, &noise2);
}

test "a ddim step with a zero noise estimate returns the predicted clean latent" {
    const s = Schedule.init(1000, 0.00085, 0.012);
    const latent_t = [_]f32{ 0.4, -0.2, 0.9, 0.1 };
    const zero_pred = [_]f32{ 0, 0, 0, 0 };
    var out: [4]f32 = undefined;
    // With no predicted noise, pred_x0 = latent_t / sqrt(ab_t); stepping to
    // t_prev=0 (ab_prev=1) returns exactly that clean latent.
    s.ddimStep(&latent_t, &zero_pred, 500, 0, &out);
    const ab = s.alphaBar(500);
    for (out, latent_t) |o, lt| try testing.expectApproxEqAbs(lt / @sqrt(ab), o, 1e-4);
}

test "timesteps descend across the training range" {
    const s = Schedule.init(1000, 0.00085, 0.012);
    var buf: [max_steps]i32 = undefined;
    const ts = s.timesteps(4, &buf);
    try testing.expectEqual(@as(usize, 4), ts.len);
    try testing.expect(ts[0] > ts[1] and ts[1] > ts[2] and ts[2] > ts[3]);
    try testing.expect(ts[0] < 1000);
}

test "fillNoise is roughly zero-mean and unit-variance" {
    var buf: [1024]f32 = undefined;
    fillNoise(&buf, 7);
    var mean: f64 = 0;
    for (buf) |v| mean += v;
    mean /= buf.len;
    var variance: f64 = 0;
    for (buf) |v| variance += (v - mean) * (v - mean);
    variance /= buf.len;
    try testing.expectApproxEqAbs(@as(f64, 0), mean, 0.15);
    try testing.expectApproxEqAbs(@as(f64, 1), variance, 0.2);
}
