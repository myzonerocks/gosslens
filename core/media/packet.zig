//! An encoded packet and the clock it is timed on. The adapter had no packet
//! type at all: a frame went in and a file came out, so nothing could carry a
//! timestamp the engine owns, and pause, resume and discontinuity had nowhere
//! to live.

const std = @import("std");

/// A rational timebase, because a container's timestamps are integers in its own
/// units and converting through a float loses the exactness at 29.97 and 23.976.
pub const Timebase = struct {
    num: u32,
    den: u32,

    pub const microseconds: Timebase = .{ .num = 1, .den = 1_000_000 };

    pub fn valid(tb: Timebase) bool {
        return tb.num > 0 and tb.den > 0;
    }

    /// A count in this timebase as microseconds, rounded to nearest. The i128
    /// intermediate is what keeps a 90kHz stream exact past the 24-day mark a
    /// 64-bit product overflows at.
    pub fn toMicros(tb: Timebase, ticks: i64) i64 {
        const scaled = @as(i128, ticks) * @as(i128, tb.num) * 1_000_000;
        return @intCast(divRoundNearest(scaled, @as(i128, tb.den)));
    }

    /// The reverse, so a packet built from a camera timestamp lands on a tick.
    pub fn fromMicros(tb: Timebase, micros: i64) i64 {
        const scaled = @as(i128, micros) * @as(i128, tb.den);
        return @intCast(divRoundNearest(scaled, @as(i128, tb.num) * 1_000_000));
    }
};

/// Round-to-nearest that works for negative numerators too, which a timestamp
/// before the clock's origin is.
fn divRoundNearest(n: i128, d: i128) i128 {
    if (d == 0) return 0;
    const half = @divTrunc(d, 2);
    return if (n >= 0) @divTrunc(n + half, d) else @divTrunc(n - half, d);
}

/// One encoded packet. The payload is borrowed: a muxer writes it and returns,
/// and nothing here owns heap, so feeding a packet allocates nothing.
pub const Packet = struct {
    payload: []const u8,
    timebase: Timebase,
    /// Presentation and decode stamps in the timebase. dts may trail pts on a
    /// codec with reordering, and a muxer that assumes they are equal writes a
    /// file that stutters.
    pts: i64,
    dts: i64,
    duration: i64 = 0,
    track: u32 = 0,
    keyframe: bool = false,
    /// The codec's out-of-band configuration (avcC, hvcC, CodecPrivate) the
    /// container needs in its header. Borrowed like the payload.
    extradata: []const u8 = &.{},

    pub fn valid(p: Packet) bool {
        if (!p.timebase.valid()) return false;
        if (p.payload.len == 0) return false;
        // Decode cannot come after presentation; the reverse is normal.
        if (p.dts > p.pts) return false;
        if (p.duration < 0) return false;
        return true;
    }

    pub fn ptsMicros(p: Packet) i64 {
        return p.timebase.toMicros(p.pts);
    }
};

const t = std.testing;

test "a timebase converts exactly where a float would not" {
    const tb: Timebase = .{ .num = 1001, .den = 30_000 };
    // One frame of 29.97 is 33366.7us, so a single tick rounds; thirty ticks is
    // 1.001s exactly, which is the figure a float timebase drifts away from.
    try t.expectEqual(@as(i64, 33_367), tb.toMicros(1));
    try t.expectEqual(@as(i64, 1_001_000), tb.toMicros(30));
    try t.expectEqual(@as(i64, 30), tb.fromMicros(1_001_000));
    try t.expectEqual(@as(i64, 1), tb.fromMicros(33_367));
}

test "microsecond ticks are their own microseconds" {
    const tb: Timebase = .microseconds;
    try t.expectEqual(@as(i64, 123_456), tb.toMicros(123_456));
    try t.expectEqual(@as(i64, 123_456), tb.fromMicros(123_456));
}

test "a 90kHz stream stays exact past the point a 64-bit product overflows" {
    const tb: Timebase = .{ .num = 1, .den = 90_000 };
    // Thirty days of 90kHz ticks; the i128 intermediate is what holds it.
    const ticks: i64 = 90_000 * 60 * 60 * 24 * 30;
    try t.expectEqual(@as(i64, 60 * 60 * 24 * 30 * 1_000_000), tb.toMicros(ticks));
}

test "a stamp before the origin rounds the same way" {
    const tb: Timebase = .{ .num = 1001, .den = 30_000 };
    try t.expectEqual(@as(i64, -33_367), tb.toMicros(-1));
    try t.expectEqual(@as(i64, -30), tb.fromMicros(-1_001_001));
}

test "a packet with decode after presentation is refused" {
    const bytes = [_]u8{ 1, 2, 3 };
    const good: Packet = .{ .payload = &bytes, .timebase = .microseconds, .pts = 100, .dts = 100 };
    try t.expect(good.valid());
    // Reordering puts dts before pts, which is normal; the reverse is not.
    const reordered: Packet = .{ .payload = &bytes, .timebase = .microseconds, .pts = 200, .dts = 100 };
    try t.expect(reordered.valid());
    const bad: Packet = .{ .payload = &bytes, .timebase = .microseconds, .pts = 100, .dts = 200 };
    try t.expect(!bad.valid());
}

test "an empty payload or a zero timebase is not a packet" {
    const bytes = [_]u8{1};
    try t.expect(!(Packet{ .payload = &.{}, .timebase = .microseconds, .pts = 0, .dts = 0 }).valid());
    try t.expect(!(Packet{ .payload = &bytes, .timebase = .{ .num = 0, .den = 1 }, .pts = 0, .dts = 0 }).valid());
    try t.expect(!(Packet{ .payload = &bytes, .timebase = .microseconds, .pts = 0, .dts = 0, .duration = -1 }).valid());
}

test "a packet reports its presentation time in microseconds" {
    const bytes = [_]u8{1};
    const p: Packet = .{ .payload = &bytes, .timebase = .{ .num = 1, .den = 90_000 }, .pts = 90_000, .dts = 90_000 };
    try t.expectEqual(@as(i64, 1_000_000), p.ptsMicros());
}
