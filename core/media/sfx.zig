//! Built-in sound effects synthesized on demand, so a lens fires a whoosh, a
//! ding, or applause by name (a play_sound target of "builtin:ding") without
//! bundling an audio file. Each effect is procedural and deterministic - the
//! same bytes on every platform - and returned as a mono WAV the mixer decodes.
const std = @import("std");

/// The built-in effect names a lens may play. A name outside this set falls
/// through to the bundle's own file, so a lens can still ship custom sounds.
pub const names = [_][]const u8{ "ding", "chime", "click", "pop", "beep", "whoosh", "swoosh", "applause", "success", "error" };

pub fn isBuiltin(name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn durationS(name: []const u8) f32 {
    if (std.mem.eql(u8, name, "click")) return 0.04;
    if (std.mem.eql(u8, name, "pop")) return 0.12;
    if (std.mem.eql(u8, name, "beep")) return 0.18;
    if (std.mem.eql(u8, name, "swoosh")) return 0.35;
    if (std.mem.eql(u8, name, "whoosh")) return 0.55;
    if (std.mem.eql(u8, name, "applause")) return 1.2;
    return 0.6; // ding, chime, success, error
}

/// A deterministic white-noise source, so an effect sounds the same every run.
const Noise = struct {
    seed: u32 = 0x1234567,
    fn next(self: *Noise) f32 {
        self.seed = self.seed *% 1664525 +% 1013904223;
        return @as(f32, @floatFromInt(self.seed >> 16)) / 32768.0 - 1.0;
    }
};

fn sine(freq: f32, tt: f32) f32 {
    return @sin(2.0 * std.math.pi * freq * tt);
}

fn writeSample(pcm: []i16, i: usize, v: f32) void {
    const s = std.math.clamp(v, -1.0, 1.0) * 0.35 * 32767.0;
    pcm[i] = @intFromFloat(@round(s));
}

/// Renders the named effect into pcm (mono, sample_rate). The name is assumed to
/// be one of `names`; an unknown name renders silence.
fn render(name: []const u8, pcm: []i16, sample_rate: u32) void {
    const sr: f32 = @floatFromInt(sample_rate);
    var noise = Noise{};
    var lp: f32 = 0; // one-pole low-pass state the whoosh carries across samples
    for (pcm, 0..) |_, i| {
        const tt = @as(f32, @floatFromInt(i)) / sr;
        const p = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pcm.len)); // 0..1 progress
        var v: f32 = 0;
        if (std.mem.eql(u8, name, "ding")) {
            v = sine(880, tt) * @exp(-tt * 6.0);
        } else if (std.mem.eql(u8, name, "chime")) {
            v = (sine(523.25, tt) + sine(659.25, tt) + sine(783.99, tt)) / 3.0 * @exp(-tt * 3.5);
        } else if (std.mem.eql(u8, name, "click")) {
            v = noise.next() * @exp(-tt * 120.0);
        } else if (std.mem.eql(u8, name, "pop")) {
            const freq = 420.0 - 300.0 * p;
            v = sine(freq, tt) * @exp(-tt * 30.0);
        } else if (std.mem.eql(u8, name, "beep")) {
            const env = @sin(std.math.pi * p); // fade in and out
            v = sine(800, tt) * env;
        } else if (std.mem.eql(u8, name, "whoosh") or std.mem.eql(u8, name, "swoosh")) {
            // Noise shaped by a bell envelope, low-passed by a one-pole whose
            // cutoff rides the envelope so it opens then closes like air moving.
            const env = @sin(std.math.pi * p);
            const target = noise.next() * env;
            v = lp + (target - lp) * (0.05 + 0.35 * env);
            lp = v;
        } else if (std.mem.eql(u8, name, "applause")) {
            // Many short decaying noise claps at pseudo-random offsets.
            const clap = noise.next();
            const density = 0.5 + 0.5 * @sin(std.math.pi * p);
            v = clap * density * 0.8;
        } else if (std.mem.eql(u8, name, "success")) {
            // Two rising tones.
            const f: f32 = if (p < 0.5) 659.25 else 987.77;
            const local = if (p < 0.5) tt else tt - pcm_half(pcm.len, sr);
            v = sine(f, tt) * @exp(-local * 5.0);
        } else if (std.mem.eql(u8, name, "error")) {
            // Two falling low tones.
            const f: f32 = if (p < 0.5) 311.13 else 233.08;
            const local = if (p < 0.5) tt else tt - pcm_half(pcm.len, sr);
            v = sine(f, tt) * @exp(-local * 5.0);
        }
        writeSample(pcm, i, v);
    }
}

// A one-pole low-pass carries across samples inside render; file-scope so the
// whoosh branch can hold its state without threading it through every branch.
var lp_state: f32 = 0;

fn pcm_half(len: usize, sr: f32) f32 {
    return @as(f32, @floatFromInt(len / 2)) / sr;
}

/// Wraps mono i16 PCM in a 44-byte canonical WAV header.
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
    std.mem.writeInt(u32, buf[28..32], sample_rate * 2, .little); // byte rate
    std.mem.writeInt(u16, buf[32..34], 2, .little); // block align
    std.mem.writeInt(u16, buf[34..36], 16, .little); // bits
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);
    for (pcm, 0..) |s, i| std.mem.writeInt(i16, buf[44 + i * 2 ..][0..2], s, .little);
    return buf;
}

/// Synthesizes the named effect as an owned mono 16-bit WAV buffer at
/// sample_rate. error.UnknownEffect for a name that is not built in.
pub fn synth(gpa: std.mem.Allocator, name: []const u8, sample_rate: u32) ![]u8 {
    if (!isBuiltin(name) or sample_rate == 0) return error.UnknownEffect;
    lp_state = 0;
    const n: usize = @intFromFloat(durationS(name) * @as(f32, @floatFromInt(sample_rate)));
    const pcm = try gpa.alloc(i16, @max(n, 1));
    defer gpa.free(pcm);
    render(name, pcm, sample_rate);
    return wrapWav(gpa, pcm, sample_rate);
}

const t = std.testing;

test "every built-in effect synthesizes a non-silent, well-formed wav" {
    for (names) |name| {
        const wav = try synth(t.allocator, name, 48000);
        defer t.allocator.free(wav);
        try t.expect(wav.len > 44);
        try t.expectEqualSlices(u8, "RIFF", wav[0..4]);
        try t.expectEqualSlices(u8, "WAVE", wav[8..12]);
        // Some sample past the header must be non-zero: the effect made sound.
        var energy: u64 = 0;
        var i: usize = 44;
        while (i + 1 < wav.len) : (i += 2) {
            const s = std.mem.readInt(i16, wav[i..][0..2], .little);
            energy += @abs(@as(i64, s));
        }
        try t.expect(energy > 0);
    }
}

test "an unknown effect is rejected" {
    try t.expectError(error.UnknownEffect, synth(t.allocator, "not-a-sound", 48000));
}

test "synthesis is deterministic across runs" {
    const a = try synth(t.allocator, "whoosh", 48000);
    defer t.allocator.free(a);
    const b = try synth(t.allocator, "whoosh", 48000);
    defer t.allocator.free(b);
    try t.expectEqualSlices(u8, a, b);
}
