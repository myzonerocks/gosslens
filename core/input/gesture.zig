//! Turns a raw screen touch stream into the gestures a lens reacts to. The
//! host feeds one event per finger through feed(); poll() advances the clock a
//! tick and reports what was recognized since. Timing is the accumulated tick
//! delta, never a wall clock, so the same events always recognize alike.

const std = @import("std");

/// What a finger did. began puts a finger down, moved slides it, ended lifts
/// it, cancelled drops it with no gesture (the system took the touch).
pub const Phase = enum(u8) { began, moved, ended, cancelled };

/// The dominant direction of a completed swipe, or none on a tick with no
/// swipe.
pub const Swipe = enum(u8) { none, left, right, up, down };

/// What the recognizer saw over one tick. The edges (tap, double_tap,
/// long_press, swipe) are true for exactly the tick they complete; the levels
/// (position, pinch, rotate) hold their current value. active is how many
/// fingers are down.
pub const Output = struct {
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    start_x: f32 = 0,
    start_y: f32 = 0,
    tap: bool = false,
    double_tap: bool = false,
    long_press: bool = false,
    swipe: Swipe = .none,
    dragging: bool = false,
    pinch_scale: f32 = 1,
    rotate: f32 = 0,
    active: u8 = 0,
};

// Thresholds in normalized screen units (0..1 across the frame) and
// microseconds. A press shorter than tap_max that never leaves the slop ring
// is a tap; a stationary press past long_press is a long press instead.
const tap_max_us: i64 = 300_000;
const long_press_us: i64 = 500_000;
const move_slop: f32 = 0.03;
const double_tap_us: i64 = 320_000;
const double_tap_slop: f32 = 0.08;
const swipe_min_dist: f32 = 0.12;
const swipe_max_us: i64 = 400_000;

const max_pointers = 2;

const Pointer = struct {
    active: bool = false,
    id: u32 = 0,
    start_x: f32 = 0,
    start_y: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    down_us: i64 = 0,
    moved: bool = false,
    long_fired: bool = false,
};

pub const Recognizer = struct {
    pointers: [max_pointers]Pointer = [_]Pointer{.{}} ** max_pointers,
    last_x: f32 = 0,
    last_y: f32 = 0,

    // The two-finger gesture baseline, captured when the second finger lands.
    pinch_start_dist: f32 = 0,
    rotate_start: f32 = 0,
    rotate_accum: f32 = 0,
    two_active: bool = false,

    // The previous completed tap, so a second one close in time and space
    // reads as a double tap.
    last_tap_us: i64 = std.math.minInt(i64) / 2,
    last_tap_x: f32 = 0,
    last_tap_y: f32 = 0,
    clock_us: i64 = 0,

    // Edges latched since the last poll.
    pending_tap: bool = false,
    pending_double: bool = false,
    pending_long: bool = false,
    pending_swipe: Swipe = .none,

    /// Clears every finger and pending edge without disturbing the clock, so a
    /// lens change or a lost touch session starts clean.
    pub fn reset(self: *Recognizer) void {
        self.pointers = [_]Pointer{.{}} ** max_pointers;
        self.two_active = false;
        self.pending_tap = false;
        self.pending_double = false;
        self.pending_long = false;
        self.pending_swipe = .none;
    }

    fn slotOf(self: *Recognizer, id: u32) ?usize {
        for (&self.pointers, 0..) |*p, i| {
            if (p.active and p.id == id) return i;
        }
        return null;
    }

    fn freeSlot(self: *Recognizer) ?usize {
        for (&self.pointers, 0..) |*p, i| {
            if (!p.active) return i;
        }
        return null;
    }

    fn activeCount(self: *const Recognizer) u8 {
        var n: u8 = 0;
        for (self.pointers) |p| {
            if (p.active) n += 1;
        }
        return n;
    }

    fn twoActiveSlots(self: *Recognizer) ?[2]usize {
        var found: [2]usize = undefined;
        var n: usize = 0;
        for (&self.pointers, 0..) |*p, i| {
            if (p.active) {
                if (n < 2) found[n] = i;
                n += 1;
            }
        }
        return if (n == 2) found else null;
    }

    fn captureTwoFinger(self: *Recognizer) void {
        const slots = self.twoActiveSlots() orelse return;
        const a = self.pointers[slots[0]];
        const b = self.pointers[slots[1]];
        self.pinch_start_dist = @max(distance(a.x, a.y, b.x, b.y), 1e-4);
        self.rotate_start = std.math.atan2(b.y - a.y, b.x - a.x);
        self.rotate_accum = 0;
        self.two_active = true;
    }

    /// Records one touch event. Position is normalized 0..1 over the frame.
    pub fn feed(self: *Recognizer, phase: Phase, id: u32, x: f32, y: f32) void {
        self.last_x = x;
        self.last_y = y;
        switch (phase) {
            .began => {
                const slot = self.slotOf(id) orelse self.freeSlot() orelse return;
                self.pointers[slot] = .{ .active = true, .id = id, .start_x = x, .start_y = y, .x = x, .y = y };
                if (self.activeCount() == 2) self.captureTwoFinger();
            },
            .moved => {
                const slot = self.slotOf(id) orelse return;
                var p = &self.pointers[slot];
                p.x = x;
                p.y = y;
                if (distance(x, y, p.start_x, p.start_y) > move_slop) p.moved = true;
            },
            .ended => {
                const slot = self.slotOf(id) orelse return;
                self.finishPointer(slot);
            },
            .cancelled => {
                const slot = self.slotOf(id) orelse return;
                self.pointers[slot] = .{};
                self.two_active = self.twoActiveSlots() != null;
            },
        }
    }

    fn finishPointer(self: *Recognizer, slot: usize) void {
        const p = self.pointers[slot];
        // A quick straight flick is a swipe; otherwise a short stationary
        // press that never became a long press is a tap.
        const travel = distance(p.x, p.y, p.start_x, p.start_y);
        if (!self.two_active and travel >= swipe_min_dist and p.down_us <= swipe_max_us) {
            self.pending_swipe = swipeDir(p.x - p.start_x, p.y - p.start_y);
        } else if (!p.long_fired and !p.moved and p.down_us <= tap_max_us) {
            self.recordTap(p.x, p.y);
        }
        self.pointers[slot] = .{};
        self.two_active = self.twoActiveSlots() != null;
    }

    fn recordTap(self: *Recognizer, x: f32, y: f32) void {
        const close = distance(x, y, self.last_tap_x, self.last_tap_y) <= double_tap_slop;
        if (close and (self.clock_us - self.last_tap_us) <= double_tap_us) {
            self.pending_double = true;
            self.last_tap_us = std.math.minInt(i64) / 2;
        } else {
            self.pending_tap = true;
            self.last_tap_us = self.clock_us;
            self.last_tap_x = x;
            self.last_tap_y = y;
        }
    }

    /// Advances the clock by one tick and returns what was recognized. The
    /// edges reported here are cleared so each completes exactly once.
    pub fn poll(self: *Recognizer, dt_us: i64) Output {
        self.clock_us += dt_us;
        var out: Output = .{};

        // Age each finger and fire a long press for a stationary hold.
        for (&self.pointers) |*p| {
            if (!p.active) continue;
            p.down_us += dt_us;
            if (!p.long_fired and !p.moved and p.down_us >= long_press_us) {
                p.long_fired = true;
                self.pending_long = true;
            }
        }

        const count = self.activeCount();
        out.active = count;
        out.pointer_x = self.last_x;
        out.pointer_y = self.last_y;
        if (count >= 1) {
            const primary = self.pointers[self.primarySlot()];
            out.start_x = primary.start_x;
            out.start_y = primary.start_y;
        } else {
            out.start_x = self.last_x;
            out.start_y = self.last_y;
        }
        out.dragging = count == 1 and self.pointers[self.primarySlot()].moved;

        if (self.two_active) {
            if (self.twoActiveSlots()) |slots| {
                const a = self.pointers[slots[0]];
                const b = self.pointers[slots[1]];
                out.pinch_scale = @max(distance(a.x, a.y, b.x, b.y), 1e-4) / self.pinch_start_dist;
                const now = std.math.atan2(b.y - a.y, b.x - a.x);
                self.rotate_accum += wrapAngle(now - self.rotate_start);
                self.rotate_start = now;
                out.rotate = self.rotate_accum;
            }
        } else {
            out.pinch_scale = 1;
        }

        out.tap = self.pending_tap;
        out.double_tap = self.pending_double;
        out.long_press = self.pending_long;
        out.swipe = self.pending_swipe;
        self.pending_tap = false;
        self.pending_double = false;
        self.pending_long = false;
        self.pending_swipe = .none;
        return out;
    }

    fn primarySlot(self: *const Recognizer) usize {
        for (self.pointers, 0..) |p, i| {
            if (p.active) return i;
        }
        return 0;
    }
};

fn distance(ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = ax - bx;
    const dy = ay - by;
    return @sqrt(dx * dx + dy * dy);
}

fn swipeDir(dx: f32, dy: f32) Swipe {
    if (@abs(dx) >= @abs(dy)) {
        return if (dx >= 0) .right else .left;
    }
    return if (dy >= 0) .down else .up;
}

// Folds an angle difference into -pi..pi so a rotation accumulates smoothly
// across the atan2 seam.
fn wrapAngle(a: f32) f32 {
    var r = a;
    const two_pi = std.math.pi * 2.0;
    while (r > std.math.pi) r -= two_pi;
    while (r < -std.math.pi) r += two_pi;
    return r;
}

const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

test "a short stationary press is a tap" {
    var r: Recognizer = .{};
    r.feed(.began, 1, 0.5, 0.5);
    _ = r.poll(16_000);
    r.feed(.ended, 1, 0.5, 0.5);
    const out = r.poll(16_000);
    try expect(out.tap);
    try expect(!out.double_tap);
    try expect(!out.long_press);
}

test "two quick taps close together read as a double tap" {
    var r: Recognizer = .{};
    r.feed(.began, 1, 0.5, 0.5);
    r.feed(.ended, 1, 0.5, 0.5);
    const first = r.poll(16_000);
    try expect(first.tap);
    r.feed(.began, 2, 0.51, 0.5);
    r.feed(.ended, 2, 0.51, 0.5);
    const second = r.poll(16_000);
    try expect(second.double_tap);
    try expect(!second.tap);
}

test "a stationary hold past the threshold is a long press, not a tap" {
    var r: Recognizer = .{};
    r.feed(.began, 1, 0.4, 0.4);
    var fired = false;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        if (r.poll(16_000).long_press) fired = true;
    }
    try expect(fired);
    r.feed(.ended, 1, 0.4, 0.4);
    try expect(!r.poll(16_000).tap);
}

test "a fast straight drag is a swipe in the travelled direction" {
    var r: Recognizer = .{};
    r.feed(.began, 1, 0.2, 0.5);
    _ = r.poll(16_000);
    r.feed(.moved, 1, 0.6, 0.5);
    r.feed(.ended, 1, 0.6, 0.5);
    const out = r.poll(16_000);
    try expect(out.swipe == .right);
}

test "two fingers spreading apart read as a pinch open" {
    var r: Recognizer = .{};
    r.feed(.began, 1, 0.4, 0.5);
    r.feed(.began, 2, 0.6, 0.5);
    _ = r.poll(16_000);
    r.feed(.moved, 1, 0.3, 0.5);
    r.feed(.moved, 2, 0.7, 0.5);
    const out = r.poll(16_000);
    try expect(out.pinch_scale > 1.5);
    try expect(out.active == 2);
}

test "twisting two fingers reports a rotation" {
    var r: Recognizer = .{};
    r.feed(.began, 1, 0.5, 0.4);
    r.feed(.began, 2, 0.5, 0.6);
    _ = r.poll(16_000);
    r.feed(.moved, 1, 0.4, 0.5);
    r.feed(.moved, 2, 0.6, 0.5);
    const out = r.poll(16_000);
    try expect(@abs(out.rotate) > 0.5);
}

test "a moving single finger reports dragging and the live position" {
    var r: Recognizer = .{};
    r.feed(.began, 1, 0.5, 0.5);
    _ = r.poll(16_000);
    r.feed(.moved, 1, 0.7, 0.3);
    const out = r.poll(16_000);
    try expect(out.dragging);
    try expectApprox(@as(f32, 0.7), out.pointer_x, 1e-6);
    try expectApprox(@as(f32, 0.3), out.pointer_y, 1e-6);
}

test "the same events and deltas recognize the same gestures" {
    var a: Recognizer = .{};
    var b: Recognizer = .{};
    inline for (.{ &a, &b }) |r| {
        r.feed(.began, 1, 0.2, 0.5);
        _ = r.poll(16_000);
        r.feed(.moved, 1, 0.6, 0.5);
        r.feed(.ended, 1, 0.6, 0.5);
    }
    try expect(a.poll(16_000).swipe == b.poll(16_000).swipe);
}
