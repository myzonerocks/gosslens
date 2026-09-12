//! One clock for a recording. Capture stamps arrive on the camera's timeline and
//! the output needs its own, monotonic, with pauses removed and declared breaks
//! accounted for. Without this a pause left a gap the size of the pause and the
//! file drifted from the audio for the rest of the recording.

const std = @import("std");
const packet = @import("packet.zig");
const container = @import("container.zig");

pub const Error = error{
    InvalidState,
    /// A stamp that cannot be placed: before the origin, or while paused.
    InvalidArgument,
};

/// The recording clock. Capture time goes in, output time comes out, and the
/// paused spans are subtracted so the output has no gap where a pause was.
pub const Clock = struct {
    /// The first capture stamp seen, the origin output time counts from.
    origin_us: ?i64 = null,
    /// Total microseconds spent paused, subtracted from every later stamp.
    paused_total_us: i64 = 0,
    /// When the current pause began, in capture time. Null when running.
    paused_at_us: ?i64 = null,
    /// The last output time handed out, so the result is monotonic even when a
    /// capture stamp repeats or goes backwards by a hair.
    last_out_us: i64 = 0,
    /// Declared breaks, and the drift the largest one left behind.
    breaks: u32 = 0,
    /// The largest gap between consecutive capture stamps that was not a pause,
    /// which is the measured drift a budget asserts against.
    max_gap_us: i64 = 0,
    /// The previous capture stamp, for the gap measurement.
    prev_capture_us: ?i64 = null,
    /// Set by a declared break that is not a pause: the gap across it is the
    /// break, not drift, so the next stamp starts a fresh measurement.
    skip_next_gap: bool = false,

    pub fn isPaused(c: Clock) bool {
        return c.paused_at_us != null;
    }

    /// The output time for a capture stamp. Refused while paused: a frame that
    /// arrives during a pause has no place in the output, and silently giving it
    /// one is what produces a file whose audio leads its video.
    pub fn map(c: *Clock, capture_us: i64) Error!i64 {
        if (c.isPaused()) return error.InvalidArgument;
        const origin = c.origin_us orelse blk: {
            c.origin_us = capture_us;
            break :blk capture_us;
        };
        if (capture_us < origin) return error.InvalidArgument;
        if (c.skip_next_gap) {
            c.skip_next_gap = false;
        } else if (c.prev_capture_us) |prev| {
            const gap = capture_us - prev;
            if (gap > c.max_gap_us) c.max_gap_us = gap;
        }
        c.prev_capture_us = capture_us;
        const out = capture_us - origin - c.paused_total_us;
        // Monotonic by construction: a stamp that would go backwards lands on the
        // last one rather than being refused, since a repeated camera stamp is
        // common and dropping the frame is worse than holding the instant.
        const clamped = if (out < c.last_out_us) c.last_out_us else out;
        c.last_out_us = clamped;
        return clamped;
    }

    pub fn pause(c: *Clock, capture_us: i64) Error!void {
        if (c.isPaused()) return error.InvalidState;
        if (c.origin_us == null) return error.InvalidState;
        c.paused_at_us = capture_us;
    }

    pub fn resume_(c: *Clock, capture_us: i64) Error!void {
        const began = c.paused_at_us orelse return error.InvalidState;
        if (capture_us < began) return error.InvalidArgument;
        c.paused_total_us += capture_us - began;
        c.paused_at_us = null;
        // The resumed stamp is the next gap's start, not a gap of its own.
        c.prev_capture_us = capture_us;
    }

    /// A declared break. Counted, and for everything but a pause the gap it left
    /// is not held against the drift figure, since the engine was not running.
    pub fn note(c: *Clock, kind: container.Discontinuity, capture_us: i64) void {
        c.breaks += 1;
        if (kind != .pause) {
            c.prev_capture_us = capture_us;
            c.skip_next_gap = true;
        }
    }

    /// The drift the recording actually carries: the largest unexplained gap
    /// between consecutive frames, which is what a per-tier budget asserts.
    pub fn driftUs(c: Clock) i64 {
        return c.max_gap_us;
    }

    /// The output duration so far, which is the recording's length with the
    /// pauses removed.
    pub fn durationUs(c: Clock) i64 {
        return c.last_out_us;
    }

    /// The output time as a tick in a track's own timebase, which is what a
    /// packet carries.
    pub fn ticks(c: *Clock, capture_us: i64, tb: packet.Timebase) Error!i64 {
        const out = try c.map(capture_us);
        return tb.fromMicros(out);
    }
};

const t = std.testing;

test "the first stamp is the origin and output starts at zero" {
    var c: Clock = .{};
    try t.expectEqual(@as(i64, 0), try c.map(1_000_000));
    try t.expectEqual(@as(i64, 33_333), try c.map(1_033_333));
    try t.expectEqual(@as(i64, 33_333), c.durationUs());
}

test "a pause leaves no gap in the output" {
    var c: Clock = .{};
    _ = try c.map(0);
    _ = try c.map(33_333);
    try c.pause(50_000);
    // Ten seconds of wall clock pass while paused.
    try c.resume_(10_050_000);
    // The next frame lands just past the last one, not ten seconds later.
    const out = try c.map(10_083_333);
    try t.expectEqual(@as(i64, 83_333), out);
}

test "a frame that arrives while paused is refused rather than placed" {
    var c: Clock = .{};
    _ = try c.map(0);
    try c.pause(1_000);
    try t.expectError(error.InvalidArgument, c.map(2_000));
    try c.resume_(5_000);
    _ = try c.map(6_000);
}

test "pause and resume out of order are refused" {
    var c: Clock = .{};
    // A pause before any frame has nothing to pause.
    try t.expectError(error.InvalidState, c.pause(0));
    _ = try c.map(0);
    try t.expectError(error.InvalidState, c.resume_(100));
    try c.pause(100);
    try t.expectError(error.InvalidState, c.pause(200));
    try t.expectError(error.InvalidArgument, c.resume_(50));
    try c.resume_(200);
}

test "a repeated capture stamp holds the instant rather than going backwards" {
    var c: Clock = .{};
    _ = try c.map(0);
    try t.expectEqual(@as(i64, 1_000), try c.map(1_000));
    // The same stamp twice, and a stamp a hair behind: both hold.
    try t.expectEqual(@as(i64, 1_000), try c.map(1_000));
    try t.expectEqual(@as(i64, 1_000), try c.map(999));
    try t.expectEqual(@as(i64, 2_000), try c.map(2_000));
}

test "a stamp before the origin is refused" {
    var c: Clock = .{};
    _ = try c.map(1_000_000);
    try t.expectError(error.InvalidArgument, c.map(999_999));
}

test "drift is the largest unexplained gap, and a pause is not one" {
    var c: Clock = .{};
    _ = try c.map(0);
    _ = try c.map(33_333);
    _ = try c.map(66_666);
    try t.expectEqual(@as(i64, 33_333), c.driftUs());
    // A pause of ten seconds does not count as drift.
    try c.pause(70_000);
    try c.resume_(10_070_000);
    _ = try c.map(10_103_333);
    try t.expectEqual(@as(i64, 33_333), c.driftUs());
    // A dropped frame does: two periods with nothing between them.
    _ = try c.map(10_170_000);
    try t.expectEqual(@as(i64, 66_667), c.driftUs());
}

test "a declared break that is not a pause does not become drift" {
    var c: Clock = .{};
    _ = try c.map(0);
    _ = try c.map(33_333);
    c.note(.camera_lost, 33_333);
    // The camera came back five seconds later; the engine was not running, so
    // the gap is the break, not drift.
    _ = try c.map(5_033_333);
    try t.expectEqual(@as(i64, 33_333), c.driftUs());
    try t.expectEqual(@as(u32, 1), c.breaks);
}

test "output time converts to a track's own ticks" {
    var c: Clock = .{};
    _ = try c.map(0);
    const tb: packet.Timebase = .{ .num = 1, .den = 90_000 };
    try t.expectEqual(@as(i64, 90_000), try c.ticks(1_000_000, tb));
}
