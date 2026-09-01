//! Interleaved f32 PCM to the s16 layout platform audio encoders take,
//! plus the sample-to-duration bookkeeping the muxed track timestamps
//! ride on. Target independent, so the host suite proves the exact
//! math the device encoder input buffers consume.

const std = @import("std");

/// Converts interleaved f32 samples in [-1, 1] to interleaved s16.
/// Out-of-range values clamp, NaN maps to silence, and the write stops
/// at whichever of the three buffers runs out. Returns samples written.
pub fn f32ToS16(samples: []const f32, frame_count: u32, channels: u32, out: []i16) usize {
    const total = @as(usize, frame_count) * @as(usize, channels);
    const n = @min(total, @min(samples.len, out.len));
    for (samples[0..n], out[0..n]) |sample, *dst| {
        var v = sample;
        if (std.math.isNan(v)) v = 0;
        if (v > 1.0) v = 1.0;
        if (v < -1.0) v = -1.0;
        dst.* = @intFromFloat(v * 32767.0);
    }
    return n;
}

/// The duration a frame count spans at a sample rate, in microseconds,
/// widened so a long take cannot overflow. A zero rate reports zero
/// rather than dividing by it.
pub fn framesToDurationUs(frame_count: u64, sample_rate: u32) i64 {
    if (sample_rate == 0) return 0;
    const us = (frame_count * std.time.us_per_s) / sample_rate;
    return std.math.cast(i64, us) orelse std.math.maxInt(i64);
}

test "f32 samples clamp, reject NaN, and convert to s16" {
    const in = [_]f32{ 0.0, 1.0, -1.0, 2.0, -2.0, std.math.nan(f32) };
    var out: [6]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 6), f32ToS16(&in, 3, 2, &out));
    try std.testing.expectEqual(@as(i16, 0), out[0]);
    try std.testing.expectEqual(@as(i16, 32767), out[1]);
    try std.testing.expectEqual(@as(i16, -32767), out[2]);
    try std.testing.expectEqual(@as(i16, 32767), out[3]);
    try std.testing.expectEqual(@as(i16, -32767), out[4]);
    try std.testing.expectEqual(@as(i16, 0), out[5]);
}

test "conversion stops at the shortest buffer" {
    const in = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    var out: [2]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), f32ToS16(&in, 2, 2, &out));
}

test "frame counts widen into microsecond durations" {
    try std.testing.expectEqual(@as(i64, 1_000_000), framesToDurationUs(48_000, 48_000));
    try std.testing.expectEqual(@as(i64, 0), framesToDurationUs(48_000, 0));
    const long_take = framesToDurationUs(std.math.maxInt(u32), 8_000);
    try std.testing.expect(long_take > 0);
}
