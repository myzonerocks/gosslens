//! On-device generative music: a prompt maps to musical parameters and a short
//! track is composed here - a diatonic progression with bass, pad, melody, and
//! drums - as a mono WAV the mixer decodes. Every note follows music theory, not
//! a model, so it is coherent and deterministic; same prompt+seed, same bytes.
const std = @import("std");

pub const Scale = enum { major, minor, pentatonic };

pub const Params = struct {
    /// Varies the melody and drums without changing the key or feel.
    seed: u32 = 0x51A50123,
    tempo_bpm: f32 = 100,
    /// The tonic as a MIDI note (60 = middle C).
    root_midi: u8 = 57, // A3
    scale: Scale = .major,
    /// Bars of 4/4 to render; each bar is one chord of the progression.
    bars: u32 = 8,
    /// Lifts the melody and pad an octave for a brighter, more open feel.
    bright: bool = false,
};

const major_steps = [_]i32{ 0, 2, 4, 5, 7, 9, 11 };
const minor_steps = [_]i32{ 0, 2, 3, 5, 7, 8, 10 };
const penta_steps = [_]i32{ 0, 2, 4, 7, 9 };

fn steps(scale: Scale) []const i32 {
    return switch (scale) {
        .major => &major_steps,
        .minor => &minor_steps,
        .pentatonic => &penta_steps,
    };
}

/// A four-chord loop by scale degree (0-indexed): a bright I-V-vi-IV for major
/// and pentatonic, a darker i-VI-III-VII for minor.
fn progression(scale: Scale) [4]usize {
    return switch (scale) {
        .major, .pentatonic => .{ 0, 4, 5, 3 },
        .minor => .{ 0, 5, 2, 6 },
    };
}

/// The MIDI note for a scale degree (which may run past the octave) above the
/// root, wrapping through the scale and adding twelve per octave crossed.
fn scaleNote(root: i32, scale: Scale, degree: i32) i32 {
    const s = steps(scale);
    const n: i32 = @intCast(s.len);
    const oct = @divFloor(degree, n);
    const idx: usize = @intCast(@mod(degree, n));
    return root + oct * 12 + s[idx];
}

fn midiToFreq(midi: i32) f32 {
    return 440.0 * std.math.pow(f32, 2.0, @as(f32, @floatFromInt(midi - 69)) / 12.0);
}

/// Maps a free-text prompt to musical parameters by keyword, so "a sad slow
/// piano" and "upbeat happy dance" render different music. Unmatched prompts
/// keep the balanced default; the seed threads the prompt's own hash so two
/// different prompts with the same mood still vary.
pub fn paramsFromPrompt(prompt: []const u8) Params {
    var p = Params{};
    var hash: u32 = 2166136261;
    for (prompt) |c| {
        hash = (hash ^ std.ascii.toLower(c)) *% 16777619;
    }
    p.seed = hash | 1;
    if (contains(prompt, "sad") or contains(prompt, "melanch") or contains(prompt, "dark") or contains(prompt, "somber")) {
        p.scale = .minor;
    } else if (contains(prompt, "epic") or contains(prompt, "cinematic")) {
        p.scale = .minor;
        p.bright = true;
    } else if (contains(prompt, "chill") or contains(prompt, "lofi") or contains(prompt, "calm") or contains(prompt, "ambient")) {
        p.scale = .pentatonic;
    }
    if (contains(prompt, "fast") or contains(prompt, "upbeat") or contains(prompt, "dance") or contains(prompt, "energetic")) {
        p.tempo_bpm = 132;
    } else if (contains(prompt, "slow") or contains(prompt, "chill") or contains(prompt, "calm") or contains(prompt, "ambient")) {
        p.tempo_bpm = 76;
    }
    if (contains(prompt, "bright") or contains(prompt, "happy") or contains(prompt, "high")) p.bright = true;
    return p;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const Rng = struct {
    state: u32,
    fn next(self: *Rng) u32 {
        self.state = self.state *% 1664525 +% 1013904223;
        return self.state;
    }
    fn upTo(self: *Rng, n: u32) u32 {
        return self.next() % n;
    }
};

fn sine(freq: f32, tt: f32) f32 {
    return @sin(2.0 * std.math.pi * freq * tt);
}

/// One voice: adds a note of `freq` starting at sample `start` for `len` samples
/// into pcm, with a pluck/decay envelope and the given gain, summed over what is
/// already there so the parts blend.
fn addNote(pcm: []f32, sr: f32, start: usize, len: usize, freq: f32, gain: f32, decay: f32) void {
    var i: usize = 0;
    while (i < len and start + i < pcm.len) : (i += 1) {
        const tt = @as(f32, @floatFromInt(i)) / sr;
        // Quick attack then exponential decay: a natural plucked/struck shape.
        const attack = @min(1.0, tt * 200.0);
        const env = attack * @exp(-tt * decay);
        pcm[start + i] += sine(freq, tt) * env * gain;
    }
}

/// Kick: a short low sine whose pitch drops, for the beat.
fn addKick(pcm: []f32, sr: f32, start: usize) void {
    const len: usize = @intFromFloat(sr * 0.12);
    var i: usize = 0;
    while (i < len and start + i < pcm.len) : (i += 1) {
        const tt = @as(f32, @floatFromInt(i)) / sr;
        const freq = 120.0 - 70.0 * @min(1.0, tt * 20.0);
        pcm[start + i] += sine(freq, tt) * @exp(-tt * 24.0) * 0.9;
    }
}

/// Snare/hat: a short decaying noise burst; `hp` shortens the decay for a hat.
fn addNoise(pcm: []f32, sr: f32, start: usize, rng: *Rng, gain: f32, decay: f32) void {
    const len: usize = @intFromFloat(sr * 0.08);
    var i: usize = 0;
    while (i < len and start + i < pcm.len) : (i += 1) {
        const tt = @as(f32, @floatFromInt(i)) / sr;
        const n = @as(f32, @floatFromInt(rng.next() >> 16)) / 32768.0 - 1.0;
        pcm[start + i] += n * @exp(-tt * decay) * gain;
    }
}

fn wrapWav(gpa: std.mem.Allocator, pcm: []const i16, sample_rate: u32) ![]u8 {
    const data_size: u32 = @intCast(pcm.len * 2);
    const buf = try gpa.alloc(u8, 44 + pcm.len * 2);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, buf[22..24], 1, .little); // mono
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, buf[32..34], 2, .little);
    std.mem.writeInt(u16, buf[34..36], 16, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);
    for (pcm, 0..) |s, i| std.mem.writeInt(i16, buf[44 + i * 2 ..][0..2], s, .little);
    return buf;
}

/// Composes and synthesizes the track described by `params` into an owned mono
/// 16-bit WAV at sample_rate. Deterministic in the params and seed.
pub fn synth(gpa: std.mem.Allocator, params: Params, sample_rate: u32) ![]u8 {
    if (sample_rate == 0) return error.BadSampleRate;
    const sr: f32 = @floatFromInt(sample_rate);
    const bars = std.math.clamp(params.bars, 1, 64);
    const beats_per_bar: u32 = 4;
    const beat_s = 60.0 / @max(params.tempo_bpm, 1.0);
    const beat_len: usize = @intFromFloat(beat_s * sr);
    const per_bar = std.math.mul(usize, beat_len, beats_per_bar) catch return error.OutOfMemory;
    const total = std.math.mul(usize, per_bar, bars) catch return error.OutOfMemory;
    if (total > (1 << 29)) return error.OutOfMemory;
    const mix = try gpa.alloc(f32, @max(total, 1));
    defer gpa.free(mix);
    @memset(mix, 0);

    const root: i32 = @intCast(params.root_midi);
    const prog = progression(params.scale);
    const oct: i32 = if (params.bright) 12 else 0;
    var rng = Rng{ .state = params.seed | 1 };

    var bar: u32 = 0;
    while (bar < bars) : (bar += 1) {
        const chord_root_degree: i32 = @intCast(prog[bar % 4]);
        const bar_start = bar * beats_per_bar * beat_len;
        // Bass: the chord root an octave below the tonic, struck each beat.
        const bass_note = scaleNote(root - 12, params.scale, chord_root_degree);
        // Pad: a triad (root, third, fifth in the scale) sustained over the bar.
        const third = scaleNote(root + oct, params.scale, chord_root_degree + 2);
        const fifth = scaleNote(root + oct, params.scale, chord_root_degree + 4);
        const pad_root = scaleNote(root + oct, params.scale, chord_root_degree);
        addNote(mix, sr, bar_start, beat_len * beats_per_bar, midiToFreq(pad_root), 0.12, 1.2);
        addNote(mix, sr, bar_start, beat_len * beats_per_bar, midiToFreq(third), 0.10, 1.2);
        addNote(mix, sr, bar_start, beat_len * beats_per_bar, midiToFreq(fifth), 0.10, 1.2);

        var beat: u32 = 0;
        while (beat < beats_per_bar) : (beat += 1) {
            const beat_start = bar_start + beat * beat_len;
            addNote(mix, sr, beat_start, beat_len, midiToFreq(bass_note), 0.35, 4.0);
            // Drums: kick on 1 and 3, snare on 2 and 4, hats on every eighth.
            if (beat % 2 == 0) addKick(mix, sr, beat_start) else addNoise(mix, sr, beat_start, &rng, 0.35, 30.0);
            addNoise(mix, sr, beat_start, &rng, 0.08, 90.0);
            addNoise(mix, sr, beat_start + beat_len / 2, &rng, 0.06, 90.0);
            // Melody: two eighth notes a scale step around a chord tone, so the
            // lead stays consonant while wandering. Higher octave than the pad.
            const tone_choices = [_]i32{ chord_root_degree, chord_root_degree + 2, chord_root_degree + 4, chord_root_degree + 7 };
            const base_deg = tone_choices[rng.upTo(tone_choices.len)];
            const lead1 = scaleNote(root + 12 + oct, params.scale, base_deg);
            const lead2 = scaleNote(root + 12 + oct, params.scale, base_deg + @as(i32, @intCast(rng.upTo(3))) - 1);
            addNote(mix, sr, beat_start, beat_len / 2, midiToFreq(lead1), 0.16, 6.0);
            addNote(mix, sr, beat_start + beat_len / 2, beat_len / 2, midiToFreq(lead2), 0.16, 6.0);
        }
    }

    // Normalize to a safe peak, then quantize to 16-bit.
    var peak: f32 = 1e-6;
    for (mix) |v| peak = @max(peak, @abs(v));
    const norm = 0.9 / peak;
    const pcm = try gpa.alloc(i16, mix.len);
    defer gpa.free(pcm);
    for (mix, 0..) |v, i| {
        const s = std.math.clamp(v * norm, -1.0, 1.0) * 32767.0;
        pcm[i] = @intFromFloat(@round(s));
    }
    return wrapWav(gpa, pcm, sample_rate);
}

const t = std.testing;

test "a composed track is non-silent, well-formed, and deterministic" {
    const a = try synth(t.allocator, .{}, 48000);
    defer t.allocator.free(a);
    try t.expect(a.len > 44);
    try t.expectEqualSlices(u8, "RIFF", a[0..4]);
    try t.expectEqualSlices(u8, "WAVE", a[8..12]);
    var energy: u64 = 0;
    var i: usize = 44;
    while (i + 1 < a.len) : (i += 2) energy += @abs(@as(i64, std.mem.readInt(i16, a[i..][0..2], .little)));
    try t.expect(energy > 0);
    const b = try synth(t.allocator, .{}, 48000);
    defer t.allocator.free(b);
    try t.expectEqualSlices(u8, a, b);
}

test "the prompt steers the key and tempo" {
    const sad = paramsFromPrompt("a sad slow song");
    try t.expectEqual(Scale.minor, sad.scale);
    try t.expect(sad.tempo_bpm < 90);
    const happy = paramsFromPrompt("upbeat happy dance");
    try t.expectEqual(Scale.major, happy.scale);
    try t.expect(happy.tempo_bpm > 120);
    // Different prompts thread different seeds, so they do not collide.
    try t.expect(sad.seed != happy.seed);
}

test "every scale note stays in the scale" {
    for ([_]Scale{ .major, .minor, .pentatonic }) |sc| {
        const s = steps(sc);
        var degree: i32 = -7;
        while (degree < 21) : (degree += 1) {
            const note = scaleNote(60, sc, degree);
            const pc: usize = @intCast(@mod(note - 60, 12));
            var found = false;
            for (s) |step| if (@mod(step, 12) == @as(i32, @intCast(pc))) {
                found = true;
            };
            try t.expect(found);
        }
    }
}
