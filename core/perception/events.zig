//! A bounded ring of ordered events the render thread publishes and any thread
//! drains.
//!
//! Bounded on purpose: an agent that stops draining must not grow the engine's
//! memory, and a ring that silently forgets is worse than one that says how much
//! it dropped. Overflow is counted and reported with the drained batch, so a
//! consumer always knows whether it saw everything.
//!
//! Single producer, single consumer, no lock: the render thread publishes and one
//! drainer reads. Two drainers would need a lock and there is no reason to have
//! two, so the contract says one rather than paying for a case nobody wants.

const std = @import("std");

/// What happened. Numbers are frozen once shipped: a consumer switches on these,
/// and renumbering is how a host starts reacting to the wrong thing.
pub const Kind = enum(u32) {
    face_appeared = 1,
    face_lost = 2,
    face_count_changed = 3,
    hand_appeared = 4,
    hand_lost = 5,
    gesture_recognised = 6,
    body_appeared = 7,
    body_lost = 8,
    action_recognised = 9,
    tracking_state_changed = 10,
    plane_added = 11,
    plane_updated = 12,
    anchor_added = 13,
    anchor_lost = 14,
    world_mesh_updated = 15,
    detection_appeared = 16,
    detection_lost = 17,
    label_changed = 18,
    text_appeared = 19,
    text_changed = 20,
    segmentation_class_appeared = 21,
    audio_beat = 22,
    voice_activity_started = 23,
    voice_activity_ended = 24,
    lens_activated = 25,
    lens_node_degraded = 26,
    lens_node_failed = 27,
    parameter_changed = 28,
    trigger_fired = 29,
    degrade_level_changed = 30,
    pool_exhausted = 31,
    recording_started = 32,
    recording_paused = 33,
    recording_resumed = 34,
    recording_stopped = 35,
    interruption = 36,
    frame_dropped = 37,
    budget_exceeded = 38,
    thermal_changed = 39,
    _,
};

/// One event. Fixed size and plain data, so the ring is an array and draining is
/// a copy: an event carrying a pointer would outlive what it points at.
pub const Event = extern struct {
    kind: u32,
    /// Monotonic across a session, so a consumer can tell an event it already saw
    /// from one it has not, and can measure a gap the drop count also reports.
    sequence: u64,
    timestamp_us: i64,
    /// What the event is about: a track id, a node index, a channel, a level.
    /// Which field means what is per kind and documented with the kind.
    a: u32 = 0,
    b: u32 = 0,
    value: f32 = 0,
};

/// A fixed ring. Capacity is chosen at session create and never grows: growing
/// under a consumer that stopped draining is the leak this exists to prevent.
pub const Ring = struct {
    slots: []Event,
    /// Total published and total drained, so the difference is what is waiting and
    /// neither counter needs a lock to be read.
    published: u64 = 0,
    drained: u64 = 0,
    /// Events the ring could not hold. Reported with every drain rather than
    /// logged and forgotten, because a consumer that does not know it missed
    /// something will act as though it did not.
    dropped: u64 = 0,
    next_sequence: u64 = 1,

    pub fn init(slots: []Event) Ring {
        return .{ .slots = slots };
    }

    pub fn capacity(r: Ring) usize {
        return r.slots.len;
    }

    pub fn waiting(r: Ring) u64 {
        return r.published - r.drained;
    }

    /// Publishes one event, stamping its sequence. When the ring is full the
    /// OLDEST is dropped rather than the newest: an agent reacting to what is
    /// happening now needs the newest, and a ring that refuses new events under
    /// load goes deaf exactly when something is going on.
    pub fn publish(r: *Ring, kind: Kind, timestamp_us: i64, a: u32, b: u32, value: f32) void {
        if (r.slots.len == 0) {
            r.dropped +|= 1;
            return;
        }
        if (r.waiting() >= r.slots.len) {
            r.drained += 1;
            r.dropped +|= 1;
        }
        const at: usize = @intCast(r.published % r.slots.len);
        r.slots[at] = .{
            .kind = @intFromEnum(kind),
            .sequence = r.next_sequence,
            .timestamp_us = timestamp_us,
            .a = a,
            .b = b,
            .value = value,
        };
        r.next_sequence += 1;
        r.published += 1;
    }

    /// Drains up to `out.len` events in order, and reports how many were dropped
    /// since the last drain. The drop count is cleared by the read, so a consumer
    /// sees each drop once rather than the same number for ever.
    pub fn drain(r: *Ring, out: []Event, out_dropped: *u64) usize {
        const n: usize = @intCast(@min(@as(u64, out.len), r.waiting()));
        for (0..n) |i| {
            const at: usize = @intCast((r.drained + i) % r.slots.len);
            out[i] = r.slots[at];
        }
        r.drained += n;
        out_dropped.* = r.dropped;
        r.dropped = 0;
        return n;
    }
};

const t = std.testing;

test "events drain in order with their sequence numbers" {
    var slots: [8]Event = undefined;
    var ring = Ring.init(&slots);
    ring.publish(.face_appeared, 100, 1, 0, 0);
    ring.publish(.gesture_recognised, 200, 1, 7, 0.9);
    try t.expectEqual(@as(u64, 2), ring.waiting());

    var out: [8]Event = undefined;
    var dropped: u64 = 0;
    try t.expectEqual(@as(usize, 2), ring.drain(&out, &dropped));
    try t.expectEqual(@as(u64, 0), dropped);
    try t.expectEqual(@as(u32, @intFromEnum(Kind.face_appeared)), out[0].kind);
    try t.expectEqual(@as(u64, 1), out[0].sequence);
    try t.expectEqual(@as(u64, 2), out[1].sequence);
    try t.expectEqual(@as(f32, 0.9), out[1].value);
    try t.expectEqual(@as(u64, 0), ring.waiting());
}

test "a full ring drops the oldest and says so, rather than going deaf" {
    var slots: [4]Event = undefined;
    var ring = Ring.init(&slots);
    for (0..10) |i| ring.publish(.audio_beat, @intCast(i), 0, 0, 0);
    var out: [4]Event = undefined;
    var dropped: u64 = 0;
    try t.expectEqual(@as(usize, 4), ring.drain(&out, &dropped));
    try t.expectEqual(@as(u64, 6), dropped);
    // The four that survived are the NEWEST four: an agent reacting to now needs
    // what just happened, not what happened first.
    try t.expectEqual(@as(u64, 7), out[0].sequence);
    try t.expectEqual(@as(u64, 10), out[3].sequence);
}

test "the drop count is reported once and then cleared" {
    var slots: [2]Event = undefined;
    var ring = Ring.init(&slots);
    for (0..5) |_| ring.publish(.frame_dropped, 0, 0, 0, 0);
    var out: [2]Event = undefined;
    var dropped: u64 = 0;
    _ = ring.drain(&out, &dropped);
    try t.expectEqual(@as(u64, 3), dropped);
    // A second drain does not report the same drops again; it would look like the
    // engine is still dropping when it has stopped.
    _ = ring.drain(&out, &dropped);
    try t.expectEqual(@as(u64, 0), dropped);
}

test "a partial drain leaves the rest in order" {
    var slots: [8]Event = undefined;
    var ring = Ring.init(&slots);
    for (0..6) |i| ring.publish(.face_count_changed, @intCast(i), @intCast(i), 0, 0);
    var two: [2]Event = undefined;
    var dropped: u64 = 0;
    try t.expectEqual(@as(usize, 2), ring.drain(&two, &dropped));
    try t.expectEqual(@as(u64, 1), two[0].sequence);
    try t.expectEqual(@as(u64, 2), two[1].sequence);
    try t.expectEqual(@as(u64, 4), ring.waiting());
    var rest: [8]Event = undefined;
    try t.expectEqual(@as(usize, 4), ring.drain(&rest, &dropped));
    try t.expectEqual(@as(u64, 3), rest[0].sequence);
    try t.expectEqual(@as(u64, 6), rest[3].sequence);
}

test "a zero-capacity ring counts every event as dropped rather than faulting" {
    var ring = Ring.init(&.{});
    ring.publish(.audio_beat, 0, 0, 0, 0);
    ring.publish(.audio_beat, 0, 0, 0, 0);
    var out: [4]Event = undefined;
    var dropped: u64 = 0;
    try t.expectEqual(@as(usize, 0), ring.drain(&out, &dropped));
    try t.expectEqual(@as(u64, 2), dropped);
}

test "sequence numbers never repeat across a wrap" {
    var slots: [3]Event = undefined;
    var ring = Ring.init(&slots);
    var seen: [64]bool = @splat(false);
    for (0..20) |_| {
        ring.publish(.trigger_fired, 0, 0, 0, 0);
        var out: [3]Event = undefined;
        var dropped: u64 = 0;
        const n = ring.drain(&out, &dropped);
        for (out[0..n]) |e| {
            const i: usize = @intCast(e.sequence);
            try t.expect(!seen[i]);
            seen[i] = true;
        }
    }
}

test "draining an empty ring is zero events and no drops" {
    var slots: [4]Event = undefined;
    var ring = Ring.init(&slots);
    var out: [4]Event = undefined;
    var dropped: u64 = 0;
    try t.expectEqual(@as(usize, 0), ring.drain(&out, &dropped));
    try t.expectEqual(@as(u64, 0), dropped);
}
