//! Audio analysis for lens triggers: a smoothed level envelope and an
//! energy-flux beat pulse, computed deterministically from submitted
//! PCM so the same samples always produce the same signal values.

const std = @import("std");

/// Analysis window: level and beat update once per hop of this many
/// samples, giving ~93 updates a second at 48 kHz - ample for triggers.
pub const hop_size = 512;

pub const Analysis = struct {
    /// Smoothed envelope in [0, 1]; attack rises fast, release decays
    /// slowly, matching how audio-reactive effects want to move.
    level: f32 = 0,
    /// True exactly on hops whose energy jumps well above the recent
    /// average - a beat-ish onset pulse for triggers.
    beat: bool = false,
    /// Monotonic count of onsets seen, incremented on every beat, so a lens can
    /// sync to a beat number (every fourth beat, say), not just the pulse. Wraps
    /// at the u32 ceiling, far beyond any session's beat count.
    beat_count: u32 = 0,
    /// Voiced (low-band) and unvoiced (high-band) energy in [0, 1], split by a
    /// one-pole low-pass, so a vowel reads high on low and a fricative on high.
    band_low: f32 = 0,
    band_high: f32 = 0,
    /// A gated jaw-open envelope in [0, 1] for a talking avatar: it opens on
    /// voiced energy and closes on silence, so a mesh mouths the audio.
    jaw: f32 = 0,

    // Running energy history for the onset comparison.
    history: [43]f32 = @splat(0),
    history_at: usize = 0,
    history_filled: bool = false,
    carry: [hop_size]f32 = @splat(0),
    carry_len: usize = 0,
    // Persisted one-pole low-pass state for the band split.
    lp_state: f32 = 0,

    const attack: f32 = 0.6;
    const release: f32 = 0.05;
    const onset_ratio: f32 = 1.6;
    // The band split's low-pass, the jaw envelope's rates, and the silence gate.
    const lp_coeff: f32 = 0.15;
    const jaw_attack: f32 = 0.5;
    const jaw_release: f32 = 0.15;
    const jaw_gain: f32 = 4.0;
    const silence_gate: f32 = 0.01;

    /// Feeds interleaved f32 samples; channels are averaged to mono.
    /// Level and beat reflect the latest completed hop afterwards.
    pub fn feed(analysis: *Analysis, samples: []const f32, channels: u32) void {
        if (channels == 0) return;
        analysis.beat = false;
        var at: usize = 0;
        const frame_count = samples.len / channels;
        while (at < frame_count) : (at += 1) {
            var mono: f32 = 0;
            for (0..channels) |ch| mono += samples[at * channels + ch];
            mono /= @floatFromInt(channels);
            analysis.carry[analysis.carry_len] = mono;
            analysis.carry_len += 1;
            if (analysis.carry_len == hop_size) {
                analysis.completeHop();
                analysis.carry_len = 0;
            }
        }
    }

    fn completeHop(analysis: *Analysis) void {
        var energy: f32 = 0;
        var low_energy: f32 = 0;
        var high_energy: f32 = 0;
        for (analysis.carry) |sample| {
            energy += sample * sample;
            // One-pole low-pass carries the voiced band; the residual is the
            // unvoiced band, so a vowel and a fricative split apart.
            analysis.lp_state += (sample - analysis.lp_state) * lp_coeff;
            const high = sample - analysis.lp_state;
            low_energy += analysis.lp_state * analysis.lp_state;
            high_energy += high * high;
        }
        energy /= hop_size;
        // Reject a non-finite hop (a caller's NaN/inf sample) rather than let it
        // poison the envelopes; treat it as silence.
        if (!(energy >= 0)) {
            energy = 0;
            low_energy = 0;
            high_energy = 0;
            analysis.lp_state = 0;
        }
        const rms = @sqrt(energy);
        analysis.band_low = std.math.clamp(@sqrt(low_energy / hop_size), 0.0, 1.0);
        analysis.band_high = std.math.clamp(@sqrt(high_energy / hop_size), 0.0, 1.0);

        // The jaw opens on voiced energy above the silence gate and releases
        // toward closed otherwise, so the mouth mimics speech, not noise.
        const jaw_target: f32 = if (rms > silence_gate) std.math.clamp(analysis.band_low * jaw_gain, 0.0, 1.0) else 0.0;
        const jaw_coeff: f32 = if (jaw_target > analysis.jaw) jaw_attack else jaw_release;
        analysis.jaw += (jaw_target - analysis.jaw) * jaw_coeff;
        analysis.jaw = std.math.clamp(analysis.jaw, 0.0, 1.0);

        const coefficient: f32 = if (rms > analysis.level) attack else release;
        analysis.level += (rms - analysis.level) * coefficient;
        analysis.level = std.math.clamp(analysis.level, 0.0, 1.0);

        // Onset: this hop's energy against the recent average, only
        // once the history holds real data and the signal is audible.
        var sum: f32 = 0;
        for (analysis.history) |past| sum += past;
        const average = sum / analysis.history.len;
        if (analysis.history_filled and energy > average * onset_ratio and rms > 0.02) {
            analysis.beat = true;
            analysis.beat_count +%= 1;
        }
        analysis.history[analysis.history_at] = energy;
        analysis.history_at = (analysis.history_at + 1) % analysis.history.len;
        if (analysis.history_at == 0) analysis.history_filled = true;
    }
};

const t = std.testing;

test "silence stays at zero with no beats" {
    var analysis: Analysis = .{};
    const silence: [hop_size * 4]f32 = @splat(0);
    analysis.feed(&silence, 1);
    try t.expectEqual(@as(f32, 0), analysis.level);
    try t.expect(!analysis.beat);
}

test "a loud burst after quiet raises the level and fires a beat" {
    var analysis: Analysis = .{};
    // Enough quiet hops to fill the history ring.
    var quiet: [hop_size]f32 = undefined;
    for (&quiet, 0..) |*sample, i| sample.* = 0.03 * @sin(@as(f32, @floatFromInt(i)) * 0.2);
    for (0..44) |_| analysis.feed(&quiet, 1);
    try t.expect(!analysis.beat);
    const level_before = analysis.level;

    var burst: [hop_size]f32 = undefined;
    for (&burst, 0..) |*sample, i| sample.* = 0.8 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
    analysis.feed(&burst, 1);
    try t.expect(analysis.beat);
    try t.expect(analysis.level > level_before);
}

test "the beat count increments once per detected onset" {
    var analysis: Analysis = .{};
    var quiet: [hop_size]f32 = undefined;
    for (&quiet, 0..) |*s, i| s.* = 0.03 * @sin(@as(f32, @floatFromInt(i)) * 0.2);
    var burst: [hop_size]f32 = undefined;
    for (&burst, 0..) |*s, i| s.* = 0.8 * @sin(@as(f32, @floatFromInt(i)) * 0.3);

    for (0..44) |_| analysis.feed(&quiet, 1);
    try t.expectEqual(@as(u32, 0), analysis.beat_count);

    // The first burst is an onset: the count ticks to one.
    analysis.feed(&burst, 1);
    try t.expect(analysis.beat);
    try t.expectEqual(@as(u32, 1), analysis.beat_count);

    // Quiet lets the running average fall back, so a second burst is a new onset.
    for (0..44) |_| analysis.feed(&quiet, 1);
    analysis.feed(&burst, 1);
    try t.expect(analysis.beat);
    try t.expectEqual(@as(u32, 2), analysis.beat_count);

    // A quiet hop is no onset, so the count holds where it was.
    analysis.feed(&quiet, 1);
    try t.expect(!analysis.beat);
    try t.expectEqual(@as(u32, 2), analysis.beat_count);
}

test "the jaw opens on voiced audio, less on unvoiced, and closes on silence" {
    // A low, near-DC tone reads as voiced (low band); a Nyquist-alternating
    // tone of equal energy reads as unvoiced (high band).
    var voiced: [hop_size]f32 = undefined;
    var unvoiced: [hop_size]f32 = undefined;
    for (0..hop_size) |i| {
        voiced[i] = 0.5;
        unvoiced[i] = if (i % 2 == 0) 0.5 else -0.5;
    }

    var open_mouth: Analysis = .{};
    for (0..20) |_| open_mouth.feed(&voiced, 1);
    try t.expect(open_mouth.jaw > 0.5);
    try t.expect(open_mouth.band_low > open_mouth.band_high);

    var closed_mouth: Analysis = .{};
    for (0..20) |_| closed_mouth.feed(&unvoiced, 1);
    // Equal energy, but the fricative opens the jaw far less than the vowel.
    try t.expect(closed_mouth.jaw < open_mouth.jaw);
    try t.expect(closed_mouth.band_high > closed_mouth.band_low);

    // Silence releases the open jaw back toward closed.
    const silence: [hop_size]f32 = @splat(0);
    for (0..40) |_| open_mouth.feed(&silence, 1);
    try t.expect(open_mouth.jaw < 0.1);
}

test "a non-finite audio sample does not poison the jaw envelope" {
    var analysis: Analysis = .{};
    var bad: [hop_size]f32 = @splat(std.math.nan(f32));
    analysis.feed(&bad, 1);
    try t.expect(analysis.jaw == analysis.jaw); // finite, not NaN
    try t.expectEqual(@as(f32, 0), analysis.jaw);
}

test "stereo averages to mono and determinism holds" {
    var first: Analysis = .{};
    var second: Analysis = .{};
    var stereo: [hop_size * 2]f32 = undefined;
    for (0..hop_size) |i| {
        stereo[i * 2] = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        stereo[i * 2 + 1] = stereo[i * 2];
    }
    first.feed(&stereo, 2);
    second.feed(&stereo, 2);
    try t.expectEqual(first.level, second.level);
    try t.expectEqual(first.beat, second.beat);
    try t.expect(first.level > 0);
}

/// The rate the microphone ring holds, whatever the device hands over. One second of ring.
pub const mic_rate: u32 = 48000;

/// Resamples the microphone to the ring's fixed rate, so a model reads the same window whatever
/// rate the handset submits. Stateful across calls on purpose: the fractional position and the
/// previous buffer's last sample carry, so consecutive buffers join without a click at the seam.
/// `sink` is anything with a `put(f32)` method, so the ring writes in place.
pub const MicResampler = struct {
    /// Fractional position in the incoming stream, in source samples.
    pos: f32 = 0,
    /// The final sample of the previous buffer, so the first output can interpolate across.
    tail: f32 = 0,
    have_tail: bool = false,

    /// A stream already at mic_rate passes through untouched — identical values, no filter.
    pub fn feed(self: *MicResampler, in: []const f32, rate: u32, sink: anytype) void {
        if (in.len == 0 or rate == 0) return;
        if (rate == mic_rate) {
            for (in) |v| sink.put(v);
            self.tail = in[in.len - 1];
            self.have_tail = true;
            self.pos = 0;
            return;
        }
        const step = @as(f32, @floatFromInt(rate)) / @as(f32, @floatFromInt(mic_rate));
        var at = self.pos;
        while (at < @as(f32, @floatFromInt(in.len))) : (at += step) {
            const i = @floor(at);
            const frac = at - i;
            const idx: isize = @intFromFloat(i);
            // Index -1 is the previous buffer's last sample, which is what makes the seam smooth.
            const a: f32 = if (idx < 0) (if (self.have_tail) self.tail else in[0]) else in[@intCast(idx)];
            const next: usize = @intCast(idx + 1);
            const b: f32 = if (next < in.len) in[next] else a;
            sink.put(a + (b - a) * frac);
        }
        // Carry the overshoot into the next buffer rather than restarting at zero.
        self.pos = at - @as(f32, @floatFromInt(in.len));
        self.tail = in[in.len - 1];
        self.have_tail = true;
    }
};

const CountingSink = struct {
    out: []f32,
    n: usize = 0,

    fn put(self: *CountingSink, v: f32) void {
        if (self.n < self.out.len) self.out[self.n] = v;
        self.n += 1;
    }
};

test "a stream already at the ring rate passes through untouched" {
    var r = MicResampler{};
    const in = [_]f32{ 0.1, -0.2, 0.3, -0.4 };
    var buf: [8]f32 = undefined;
    var sink = CountingSink{ .out = buf[0..] };
    r.feed(&in, mic_rate, &sink);
    try t.expectEqual(@as(usize, 4), sink.n);
    try t.expectEqualSlices(f32, &in, buf[0..4]);
}

test "a lower rate stretches to the ring rate and joins across buffers" {
    var r = MicResampler{};
    var buf: [512]f32 = undefined;
    var sink = CountingSink{ .out = buf[0..] };
    // 24 kHz in: every source sample becomes two at 48 kHz.
    const first = [_]f32{ 0.0, 1.0, 0.0, -1.0 };
    r.feed(&first, 24000, &sink);
    try t.expectEqual(@as(usize, 8), sink.n);
    try t.expectApproxEqAbs(@as(f32, 0.0), buf[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5), buf[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0), buf[2], 1e-6);

    // The second buffer continues the phase instead of restarting, so there is no click at the
    // seam: the first output interpolates from the previous tail (-1) toward this buffer's 0.
    const before = sink.n;
    const second = [_]f32{ 0.0, 1.0, 0.0, -1.0 };
    r.feed(&second, 24000, &sink);
    try t.expect(sink.n > before);
    try t.expect(buf[before] >= -1.0 and buf[before] <= 0.0);
}

test "a rate above the ring rate decimates" {
    var r = MicResampler{};
    var buf: [512]f32 = undefined;
    var sink = CountingSink{ .out = buf[0..] };
    var in: [96]f32 = undefined;
    for (&in, 0..) |*v, i| v.* = @floatFromInt(i);
    r.feed(&in, 96000, &sink);
    try t.expectEqual(@as(usize, 48), sink.n);
    try t.expectApproxEqAbs(@as(f32, 0.0), buf[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 2.0), buf[1], 1e-6);
}
