//! Lens audio playback: a deterministic mixer over miniaudio. Sounds decode
//! once into cached PCM (no device, no clock), and each play starts a voice
//! the pull mixes and advances. This is the Zig surface abi drives from a
//! play_sound trigger; the mixed PCM is pulled out to the platform by the SDK.
const std = @import("std");

const Handle = opaque {};
extern fn goss_mixer_create(sample_rate: c_int, channels: c_int) ?*Handle;
extern fn goss_mixer_destroy(m: ?*Handle) void;
extern fn goss_mixer_load(m: ?*Handle, path: [*]const u8, path_len: usize) c_int;
extern fn goss_mixer_load_memory(m: ?*Handle, data: [*]const u8, size: usize) c_int;
extern fn goss_mixer_play(m: ?*Handle, sound_id: c_int, loop: c_int, gain: f32) void;
extern fn goss_mixer_play_fade(m: ?*Handle, sound_id: c_int, loop: c_int, gain: f32, fade_in: u64, fade_out: u64) void;
extern fn goss_mixer_play_pan(m: ?*Handle, sound_id: c_int, loop: c_int, gain: f32, fade_in: u64, fade_out: u64, pan: f32) void;
extern fn goss_mixer_active_voices(m: ?*const Handle) c_int;
extern fn goss_mixer_pull(m: ?*Handle, out: [*]i16, frames: c_int) void;

pub const Mixer = struct {
    handle: *Handle,
    channels: u32,

    pub fn create(sample_rate: u32, channels: u32) !Mixer {
        const h = goss_mixer_create(@intCast(sample_rate), @intCast(channels)) orelse
            return error.MixerCreateFailed;
        return .{ .handle = h, .channels = channels };
    }

    pub fn destroy(self: *Mixer) void {
        goss_mixer_destroy(self.handle);
        self.handle = undefined;
    }

    /// Decodes a sound file into the mixer, returning its id.
    pub fn load(self: *Mixer, path: []const u8) !u32 {
        const id = goss_mixer_load(self.handle, path.ptr, path.len);
        if (id < 0) return error.SoundLoadFailed;
        return @intCast(id);
    }

    /// Decodes a sound from an in-memory encoded buffer (WAV, FLAC, MP3).
    pub fn loadMemory(self: *Mixer, data: []const u8) !u32 {
        const id = goss_mixer_load_memory(self.handle, data.ptr, data.len);
        if (id < 0) return error.SoundLoadFailed;
        return @intCast(id);
    }

    pub fn play(self: *Mixer, sound_id: u32, loop: bool, gain: f32) void {
        goss_mixer_play(self.handle, @intCast(sound_id), if (loop) 1 else 0, gain);
    }

    /// Starts a voice with a linear fade in and out (in frames); a looping voice
    /// ignores the fade out. Zero fades match play.
    pub fn playFade(self: *Mixer, sound_id: u32, loop: bool, gain: f32, fade_in: u64, fade_out: u64) void {
        goss_mixer_play_fade(self.handle, @intCast(sound_id), if (loop) 1 else 0, gain, fade_in, fade_out);
    }

    /// Starts a voice with fade and an equal-power stereo pan (-1 left to 1
    /// right); the pan only splits a stereo mixer, a mono one plays it centred.
    pub fn playPan(self: *Mixer, sound_id: u32, loop: bool, gain: f32, fade_in: u64, fade_out: u64, pan: f32) void {
        goss_mixer_play_pan(self.handle, @intCast(sound_id), if (loop) 1 else 0, gain, fade_in, fade_out, pan);
    }

    pub fn activeVoices(self: *const Mixer) u32 {
        return @intCast(goss_mixer_active_voices(self.handle));
    }

    /// Mixes active voices into out (frames * channels, s16), advancing them.
    /// Bounds the frame count to what `out` holds and to the c_int the shim
    /// takes, so an oversized request cannot wrap negative into its memset.
    pub fn pull(self: *Mixer, out: []i16, frames: u32) void {
        const by_buffer: u32 = @intCast(@min(out.len / @max(self.channels, 1), std.math.maxInt(u32)));
        const bounded: u32 = @min(frames, @min(by_buffer, @as(u32, std.math.maxInt(c_int))));
        goss_mixer_pull(self.handle, out.ptr, @intCast(bounded));
    }
};

test "the mixer decodes, plays, and mixes deterministically" {
    const sr: u32 = 48000;
    const pcm = [_]i16{ 100, 200, 300, 400, 500, 600, 700, 800 };
    const data_size: u32 = pcm.len * 2;

    var wav: [44 + pcm.len * 2]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 36 + data_size, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, wav[22..24], 1, .little); // mono
    std.mem.writeInt(u32, wav[24..28], sr, .little);
    std.mem.writeInt(u32, wav[28..32], sr * 2, .little); // byte rate
    std.mem.writeInt(u16, wav[32..34], 2, .little); // block align
    std.mem.writeInt(u16, wav[34..36], 16, .little); // bits
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], data_size, .little);
    for (pcm, 0..) |s, i| std.mem.writeInt(i16, wav[44 + i * 2 ..][0..2], s, .little);

    var m = try Mixer.create(sr, 1);
    defer m.destroy();
    const sound = try m.loadMemory(&wav);

    // No voice yet: silence.
    var out = [_]i16{0} ** pcm.len;
    m.pull(&out, pcm.len);
    try std.testing.expectEqual(@as(u32, 0), m.activeVoices());
    for (out) |s| try std.testing.expectEqual(@as(i16, 0), s);

    // One voice at full gain reproduces the source exactly, then exhausts.
    m.play(sound, false, 1.0);
    try std.testing.expectEqual(@as(u32, 1), m.activeVoices());
    m.pull(&out, pcm.len);
    try std.testing.expectEqualSlices(i16, &pcm, &out);
    try std.testing.expectEqual(@as(u32, 0), m.activeVoices());

    // Two voices at half gain sum back to the source, deterministically.
    m.play(sound, false, 0.5);
    m.play(sound, false, 0.5);
    var out2 = [_]i16{0} ** pcm.len;
    m.pull(&out2, pcm.len);
    try std.testing.expectEqualSlices(i16, &pcm, &out2);
}

test "the mixer fades a voice in and out linearly" {
    const sr: u32 = 48000;
    const pcm = [_]i16{ 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000 };
    const data_size: u32 = pcm.len * 2;
    var wav: [44 + pcm.len * 2]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 36 + data_size, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], sr, .little);
    std.mem.writeInt(u32, wav[28..32], sr * 2, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], data_size, .little);
    for (pcm, 0..) |s, i| std.mem.writeInt(i16, wav[44 + i * 2 ..][0..2], s, .little);

    var m = try Mixer.create(sr, 1);
    defer m.destroy();
    const sound = try m.loadMemory(&wav);

    // Fade in over 4 frames: the constant tone ramps from silence to full.
    m.playFade(sound, false, 1.0, 4, 0);
    var fin = [_]i16{0} ** pcm.len;
    m.pull(&fin, pcm.len);
    try std.testing.expectEqualSlices(i16, &[_]i16{ 0, 250, 500, 750, 1000, 1000, 1000, 1000 }, &fin);

    // Fade out over 4 frames: the tone ramps down into its end.
    m.playFade(sound, false, 1.0, 0, 4);
    var fout = [_]i16{0} ** pcm.len;
    m.pull(&fout, pcm.len);
    try std.testing.expectEqualSlices(i16, &[_]i16{ 1000, 1000, 1000, 1000, 1000, 750, 500, 250 }, &fout);
}

test "a stereo mixer pans a voice across the field with equal power" {
    const sr: u32 = 48000;
    const frames = 4;
    const pcm = [_]i16{ 1000, 1000, 1000, 1000 };
    const data_size: u32 = pcm.len * 2;
    var wav: [44 + pcm.len * 2]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 36 + data_size, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], sr, .little);
    std.mem.writeInt(u32, wav[28..32], sr * 2, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], data_size, .little);
    for (pcm, 0..) |s, i| std.mem.writeInt(i16, wav[44 + i * 2 ..][0..2], s, .little);

    // A stereo mixer upmixes the mono source to both channels on decode.
    var m = try Mixer.create(sr, 2);
    defer m.destroy();
    const sound = try m.loadMemory(&wav);

    // Hard left: the left channel carries the tone, the right is silent.
    m.playPan(sound, false, 1.0, 0, 0, -1.0);
    var left = [_]i16{0} ** (frames * 2);
    m.pull(&left, frames);
    try std.testing.expectEqual(@as(i16, 1000), left[0]);
    try std.testing.expectEqual(@as(i16, 0), left[1]);

    // Hard right: mirror image.
    m.playPan(sound, false, 1.0, 0, 0, 1.0);
    var right = [_]i16{0} ** (frames * 2);
    m.pull(&right, frames);
    try std.testing.expectEqual(@as(i16, 0), right[0]);
    try std.testing.expectEqual(@as(i16, 1000), right[1]);

    // Centred: equal power, about 0.707 into each channel, so both read together.
    m.playPan(sound, false, 1.0, 0, 0, 0.0);
    var mid = [_]i16{0} ** (frames * 2);
    m.pull(&mid, frames);
    try std.testing.expectEqual(mid[0], mid[1]);
    try std.testing.expect(mid[0] > 690 and mid[0] < 720);
}
