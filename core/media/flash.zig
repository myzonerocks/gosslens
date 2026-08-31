//! Flashing-effect detection for a photosensitivity-safe gate. A frame-luminance
//! stream is scanned for the rapid light-dark transitions that can trigger a
//! seizure; when their rate crosses the general-flash threshold the detector
//! raises a 0..1 risk a lens reads to soften or gate the effect. Alloc-free.
const std = @import("std");

/// A luminance transition counts when the trend reverses after swinging at least
/// this far (0..1), matching the general-flash relative-luminance guidance.
const swing_threshold: f32 = 0.1;
/// The rolling window transitions are counted over.
const window_us: i64 = 1_000_000;
/// Transitions per second at or above which the risk is full: three flashes a
/// second is six light-dark transitions, the general-flash limit.
const risk_transitions_per_s: f32 = 6.0;

pub const Detector = struct {
    primed: bool = false,
    /// The luminance at the last reversal, the base the current swing is measured
    /// from, and the trend direction since it (1 rising, -1 falling).
    extreme: f32 = 0,
    dir: i2 = 0,
    /// A ring of the timestamps of recent transitions, to count them in a window.
    times: [max_transitions]i64 = @splat(0),
    head: usize = 0,
    len: usize = 0,

    const max_transitions = 64;

    pub fn reset(self: *Detector) void {
        self.* = .{};
    }

    fn record(self: *Detector, ts: i64) void {
        self.times[self.head] = ts;
        self.head = (self.head + 1) % max_transitions;
        if (self.len < max_transitions) self.len += 1;
    }

    /// Feeds one frame's mean luminance (0..1) at timestamp t (microseconds) and
    /// returns the current photosensitivity risk in 0..1: the flash-transition
    /// rate over the last second scaled against the general-flash threshold.
    pub fn push(self: *Detector, lum: f32, ts: i64) f32 {
        if (!self.primed) {
            self.primed = true;
            self.extreme = lum;
            self.dir = 0;
            return 0;
        }
        const delta = lum - self.extreme;
        if (@abs(delta) >= swing_threshold) {
            const new_dir: i2 = if (delta > 0) 1 else -1;
            // A reversal past the threshold is a transition; a continued swing in
            // the same direction just extends it and moves the base outward.
            if (self.dir != 0 and new_dir != self.dir) self.record(ts);
            self.dir = new_dir;
            self.extreme = lum;
        }
        return self.risk(ts);
    }

    /// The risk from the transitions still inside the window ending at t.
    pub fn risk(self: *const Detector, ts: i64) f32 {
        var recent: u32 = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + max_transitions - 1 - i) % max_transitions;
            if (ts - self.times[idx] <= window_us) recent += 1 else break;
        }
        const per_s = @as(f32, @floatFromInt(recent));
        return std.math.clamp(per_s / risk_transitions_per_s, 0.0, 1.0);
    }
};

const t = std.testing;

test "a hard strobe trips full risk and steady light stays clear" {
    var d = Detector{};
    // Steady bright frames raise no risk.
    var tu: i64 = 0;
    var last: f32 = 0;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        last = d.push(0.8, tu);
        tu += 33_333; // ~30 fps
    }
    try t.expect(last < 0.05);

    // A hard black-white strobe every other frame is well past the limit.
    var d2 = Detector{};
    tu = 0;
    last = 0;
    i = 0;
    while (i < 30) : (i += 1) {
        last = d2.push(if (i % 2 == 0) @as(f32, 0.0) else 1.0, tu);
        tu += 33_333;
    }
    try t.expect(last > 0.9);
}

test "a slow fade stays under the flash threshold" {
    var d = Detector{};
    var tu: i64 = 0;
    var last: f32 = 0;
    var i: usize = 0;
    // A one-hertz gentle pulse: two transitions a second, well under six.
    while (i < 60) : (i += 1) {
        const lum = 0.5 + 0.4 * @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 30.0);
        last = d.push(lum, tu);
        tu += 33_333;
    }
    try t.expect(last < 0.6);
}

test "small ripples below the swing threshold never count" {
    var d = Detector{};
    var tu: i64 = 0;
    var last: f32 = 0;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        last = d.push(if (i % 2 == 0) @as(f32, 0.5) else 0.55, tu); // 0.05 swing < 0.1
        tu += 33_333;
    }
    try t.expectEqual(@as(f32, 0), last);
}
