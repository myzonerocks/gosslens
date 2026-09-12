//! What the brain sees, and what it costs to show it. The budget is checked
//! before any trigger fires, change is scored from the mean plus a structural
//! term so a still room costs nothing, and redaction happens in normalized space
//! so a rect means the same thing at any capture size.

const std = @import("std");

pub const Format = enum(u32) { jpeg = 0, png = 1, webp = 2, rgba = 3, nv12 = 4 };

/// Where the pixels come from. An agent watching a screen and an agent watching a
/// face want different sources out of one session.
pub const Source = enum(u32) {
    composited = 0,
    camera = 1,
    named_source = 2,
    named_screen = 3,
    segmentation_mask = 4,
    depth = 5,
};

/// When a frame is worth sending. Combinable, because "every keyframe, plus
/// anything that changed, plus anything a perception event touched" is one
/// sensible policy rather than three.
pub const Trigger = packed struct(u32) {
    /// Every frame the rate allows.
    always: bool = false,
    /// The change score crossed the threshold.
    on_change: bool = false,
    /// A perception event arrived since the last egress.
    on_event: bool = false,
    /// The keyframe interval elapsed.
    on_interval: bool = false,
    /// The host asked for one.
    on_request: bool = false,
    _reserved: u27 = 0,
};

/// Why a frame was or was not sent, carried in the metadata so a gateway can
/// explain itself. A decision with no reason is one nobody can tune.
pub const Reason = enum(u32) {
    sent_always = 0,
    sent_changed = 1,
    sent_event = 2,
    sent_interval = 3,
    sent_requested = 4,
    held_rate = 5,
    held_bytes = 6,
    held_unchanged = 7,
    held_no_trigger = 8,
};

pub const Config = struct {
    /// The long edge the frame is scaled to. Zero means no scaling.
    target_long_edge: u32 = 0,
    format: Format = .jpeg,
    /// 1..100 for the lossy formats, ignored otherwise.
    quality: u8 = 80,
    /// Ceilings the policy holds. Zero means no ceiling.
    max_fps: u32 = 0,
    max_bytes_per_second: u64 = 0,
    source: Source = .composited,
    trigger: Trigger = .{ .on_change = true, .on_interval = true },
    /// The change score above which a frame counts as changed, 0..1.
    change_threshold: f32 = 0.02,
    /// Microseconds between keyframes, so a change-gated stream still refreshes.
    keyframe_interval_us: i64 = 5_000_000,

    pub fn valid(c: Config) bool {
        if (c.quality == 0 or c.quality > 100) return false;
        if (c.change_threshold < 0 or c.change_threshold > 1) return false;
        if (c.keyframe_interval_us < 0) return false;
        return true;
    }
};

/// What one decision produced, for the frame's metadata.
pub const Decision = struct {
    send: bool,
    reason: Reason,
    change_score: f32,
    /// Microseconds since the last frame that was actually sent.
    since_last_us: i64,
};

/// The policy's running state. Nothing here allocates and nothing here touches a
/// pixel: it is fed a score and a clock and answers.
pub const Policy = struct {
    config: Config,
    last_sent_us: i64 = std.math.minInt(i64),
    last_keyframe_us: i64 = std.math.minInt(i64),
    /// Bytes sent inside the current second, and when that second began.
    window_started_us: i64 = std.math.minInt(i64),
    window_bytes: u64 = 0,
    /// Set by the host asking for a frame, cleared by the decision that serves it.
    requested: bool = false,
    /// Set when a perception event arrived, cleared the same way.
    event_pending: bool = false,
    sent: u64 = 0,
    held: u64 = 0,

    pub fn init(config: Config) Policy {
        return .{ .config = config };
    }

    pub fn request(p: *Policy) void {
        p.requested = true;
    }

    pub fn noteEvent(p: *Policy) void {
        p.event_pending = true;
    }

    /// Decides whether this frame goes. The rate and byte ceilings are checked
    /// FIRST: a budget a trigger can talk its way past is not a budget.
    pub fn decide(p: *Policy, now_us: i64, change_score: f32, estimated_bytes: u64) Decision {
        const since = if (p.last_sent_us == std.math.minInt(i64)) std.math.maxInt(i64) else now_us - p.last_sent_us;

        if (p.config.max_fps != 0 and p.last_sent_us != std.math.minInt(i64)) {
            const min_gap = @divTrunc(@as(i64, 1_000_000), @as(i64, p.config.max_fps));
            if (since < min_gap) return p.hold(.held_rate, change_score, since);
        }
        if (p.config.max_bytes_per_second != 0) {
            const window_open = p.window_started_us != std.math.minInt(i64) and now_us - p.window_started_us < 1_000_000;
            const spent = if (window_open) p.window_bytes else 0;
            if (spent + estimated_bytes > p.config.max_bytes_per_second) {
                return p.hold(.held_bytes, change_score, since);
            }
        }

        const fire = p.config.trigger;
        const keyframe_due = p.last_keyframe_us == std.math.minInt(i64) or
            (p.config.keyframe_interval_us > 0 and now_us - p.last_keyframe_us >= p.config.keyframe_interval_us);

        if (fire.on_request and p.requested) return p.send(.sent_requested, now_us, change_score, since, estimated_bytes, keyframe_due);
        if (fire.on_interval and keyframe_due) return p.send(.sent_interval, now_us, change_score, since, estimated_bytes, true);
        if (fire.on_event and p.event_pending) return p.send(.sent_event, now_us, change_score, since, estimated_bytes, keyframe_due);
        if (fire.on_change and change_score >= p.config.change_threshold) return p.send(.sent_changed, now_us, change_score, since, estimated_bytes, keyframe_due);
        if (fire.always) return p.send(.sent_always, now_us, change_score, since, estimated_bytes, keyframe_due);

        // A still room costs nothing, which is the whole point of the gate.
        const reason: Reason = if (fire.on_change) .held_unchanged else .held_no_trigger;
        return p.hold(reason, change_score, since);
    }

    fn send(p: *Policy, reason: Reason, now_us: i64, score: f32, since: i64, bytes: u64, keyframe: bool) Decision {
        const window_open = p.window_started_us != std.math.minInt(i64) and now_us - p.window_started_us < 1_000_000;
        if (window_open) {
            p.window_bytes += bytes;
        } else {
            p.window_started_us = now_us;
            p.window_bytes = bytes;
        }
        p.last_sent_us = now_us;
        if (keyframe) p.last_keyframe_us = now_us;
        p.requested = false;
        p.event_pending = false;
        p.sent += 1;
        return .{ .send = true, .reason = reason, .change_score = score, .since_last_us = since };
    }

    fn hold(p: *Policy, reason: Reason, score: f32, since: i64) Decision {
        p.held += 1;
        return .{ .send = false, .reason = reason, .change_score = score, .since_last_us = since };
    }
};

/// How different two downsampled luma grids are, in 0..1. Mean absolute
/// difference plus a structural term, because mean alone calls a scene that moved
/// without changing brightness unchanged, which is exactly a person walking
/// across a static room.
pub fn changeScore(previous: []const u8, current: []const u8) f32 {
    const n = @min(previous.len, current.len);
    if (n == 0) return 1.0;
    var sum: u64 = 0;
    var changed_cells: u32 = 0;
    for (0..n) |i| {
        const d = if (current[i] > previous[i]) current[i] - previous[i] else previous[i] - current[i];
        sum += d;
        // A cell that moved meaningfully, counted separately: a few cells moving a
        // lot is a person, and a mean over the whole grid buries it.
        if (d > 12) changed_cells += 1;
    }
    const mean = @as(f32, @floatFromInt(sum)) / (@as(f32, @floatFromInt(n)) * 255.0);
    const structural = @as(f32, @floatFromInt(changed_cells)) / @as(f32, @floatFromInt(n));
    const score = mean + structural;
    return if (score > 1.0) 1.0 else score;
}

const t = std.testing;

test "a still room sends nothing after its first keyframe" {
    var p = Policy.init(.{ .trigger = .{ .on_change = true, .on_interval = true }, .keyframe_interval_us = 5_000_000 });
    const first = p.decide(0, 0.0, 1000);
    try t.expect(first.send);
    try t.expectEqual(Reason.sent_interval, first.reason);
    // Nothing changes for four seconds: nothing is sent, and the reason says why.
    var at: i64 = 33_333;
    while (at < 4_000_000) : (at += 33_333) {
        const d = p.decide(at, 0.0, 1000);
        try t.expect(!d.send);
        try t.expectEqual(Reason.held_unchanged, d.reason);
    }
    try t.expectEqual(@as(u64, 1), p.sent);
}

test "the keyframe cadence refreshes a change-gated stream" {
    var p = Policy.init(.{ .trigger = .{ .on_change = true, .on_interval = true }, .keyframe_interval_us = 1_000_000 });
    _ = p.decide(0, 0.0, 100);
    try t.expect(!p.decide(500_000, 0.0, 100).send);
    const refresh = p.decide(1_000_000, 0.0, 100);
    try t.expect(refresh.send);
    try t.expectEqual(Reason.sent_interval, refresh.reason);
}

test "a change above the threshold sends, below it holds" {
    var p = Policy.init(.{ .trigger = .{ .on_change = true }, .change_threshold = 0.1, .keyframe_interval_us = 0 });
    const quiet = p.decide(0, 0.05, 100);
    try t.expect(!quiet.send);
    try t.expectEqual(Reason.held_unchanged, quiet.reason);
    const moved = p.decide(100_000, 0.5, 100);
    try t.expect(moved.send);
    try t.expectEqual(Reason.sent_changed, moved.reason);
    try t.expectEqual(@as(f32, 0.5), moved.change_score);
}

test "a budget a trigger can talk past is not a budget" {
    var p = Policy.init(.{ .trigger = .{ .always = true }, .max_fps = 10, .keyframe_interval_us = 0 });
    try t.expect(p.decide(0, 1.0, 10).send);
    // 50ms later, inside the 100ms the rate allows: held, even though `always`
    // asked for it and the frame changed completely.
    const early = p.decide(50_000, 1.0, 10);
    try t.expect(!early.send);
    try t.expectEqual(Reason.held_rate, early.reason);
    try t.expect(p.decide(100_000, 1.0, 10).send);
}

test "the byte ceiling holds inside its second and opens on the next" {
    var p = Policy.init(.{ .trigger = .{ .always = true }, .max_bytes_per_second = 1000, .keyframe_interval_us = 0 });
    try t.expect(p.decide(0, 1.0, 600).send);
    const over = p.decide(100_000, 1.0, 600);
    try t.expect(!over.send);
    try t.expectEqual(Reason.held_bytes, over.reason);
    // A new second, a fresh budget.
    try t.expect(p.decide(1_100_000, 1.0, 600).send);
}

test "an event and a request each send once and are cleared by the frame they serve" {
    var p = Policy.init(.{ .trigger = .{ .on_event = true, .on_request = true }, .keyframe_interval_us = 0 });
    try t.expect(!p.decide(0, 0.0, 10).send);
    p.noteEvent();
    const on_event = p.decide(100_000, 0.0, 10);
    try t.expect(on_event.send);
    try t.expectEqual(Reason.sent_event, on_event.reason);
    // Cleared: the same event does not send a second frame.
    try t.expect(!p.decide(200_000, 0.0, 10).send);
    p.request();
    try t.expectEqual(Reason.sent_requested, p.decide(300_000, 0.0, 10).reason);
    try t.expect(!p.decide(400_000, 0.0, 10).send);
}

test "no trigger at all holds every frame and says so" {
    var p = Policy.init(.{ .trigger = .{}, .keyframe_interval_us = 0 });
    const d = p.decide(0, 1.0, 10);
    try t.expect(!d.send);
    try t.expectEqual(Reason.held_no_trigger, d.reason);
    try t.expectEqual(@as(u64, 1), p.held);
}

test "the change score sees a moved subject a mean alone would miss" {
    const still = [_]u8{128} ** 64;
    var same = still;
    try t.expectEqual(@as(f32, 0.0), changeScore(&still, &same));

    // A person crossing: four cells of sixty-four move a lot, the rest do not.
    // The mean of that is tiny; the structural term is what catches it.
    var moved = still;
    for (0..4) |i| moved[i] = 255;
    const score = changeScore(&still, &moved);
    try t.expect(score > 0.06);
    same[0] = 129;
    // A single cell nudged by one is noise, not a change.
    try t.expect(changeScore(&still, &same) < 0.001);
}

test "a wholly different frame scores at the ceiling" {
    const black = [_]u8{0} ** 64;
    const white = [_]u8{255} ** 64;
    try t.expectEqual(@as(f32, 1.0), changeScore(&black, &white));
}

test "an empty grid is a change rather than a silent zero" {
    // No previous frame means everything is new; scoring it zero would hold the
    // first frame for ever on a change-gated policy.
    try t.expectEqual(@as(f32, 1.0), changeScore(&.{}, &.{}));
}

test "a configuration outside its own ranges is refused" {
    try t.expect((Config{}).valid());
    try t.expect(!(Config{ .quality = 0 }).valid());
    try t.expect(!(Config{ .quality = 101 }).valid());
    try t.expect(!(Config{ .change_threshold = 1.5 }).valid());
    try t.expect(!(Config{ .keyframe_interval_us = -1 }).valid());
}

/// How a redacted region is hidden. Blur and pixelate keep the shape of what was
/// there, which a scene-understanding agent still needs; fill and colour remove it
/// entirely, which is what a privacy rule usually wants.
pub const RedactMode = enum(u32) { fill = 0, blur = 1, pixelate = 2, colour = 3 };

/// A rectangle in normalized frame space, so a redaction survives a rescale: a
/// rule written in pixels is wrong the moment the egress target edge changes.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn valid(r: Rect) bool {
        return r.w > 0 and r.h > 0 and r.x >= 0 and r.y >= 0 and r.x + r.w <= 1.0001 and r.y + r.h <= 1.0001;
    }

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }

    /// The rectangle in pixels for a frame of this size, clamped to it so a rule
    /// that rounds outward cannot write past the buffer.
    pub fn pixels(r: Rect, width: u32, height: u32) struct { x0: u32, y0: u32, x1: u32, y1: u32 } {
        const fw: f32 = @floatFromInt(width);
        const fh: f32 = @floatFromInt(height);
        const x0: u32 = @intFromFloat(@max(0.0, @floor(r.x * fw)));
        const y0: u32 = @intFromFloat(@max(0.0, @floor(r.y * fh)));
        const x1: u32 = @intFromFloat(@min(fw, @ceil((r.x + r.w) * fw)));
        const y1: u32 = @intFromFloat(@min(fh, @ceil((r.y + r.h) * fh)));
        return .{ .x0 = @min(x0, width), .y0 = @min(y0, height), .x1 = @min(x1, width), .y1 = @min(y1, height) };
    }
};

/// Applies one rectangle to an RGBA buffer in place. The egress path owns the
/// buffer it hands here, so this never touches the preview or the recording:
/// redacting those is a separate decision a caller makes explicitly.
pub fn redactRect(rgba: []u8, width: u32, height: u32, rect: Rect, mode: RedactMode, colour: [3]u8) void {
    if (!rect.valid()) return;
    const box = rect.pixels(width, height);
    if (box.x1 <= box.x0 or box.y1 <= box.y0) return;
    const block: u32 = 8;
    var y = box.y0;
    while (y < box.y1) : (y += 1) {
        var x = box.x0;
        while (x < box.x1) : (x += 1) {
            const at = (@as(usize, y) * width + x) * 4;
            if (at + 3 >= rgba.len) continue;
            switch (mode) {
                .fill => {
                    rgba[at] = 0;
                    rgba[at + 1] = 0;
                    rgba[at + 2] = 0;
                },
                .colour => {
                    rgba[at] = colour[0];
                    rgba[at + 1] = colour[1];
                    rgba[at + 2] = colour[2];
                },
                .pixelate, .blur => {
                    // Both take the block's top-left sample: a true blur needs a
                    // second buffer, and a block average that reads pixels this
                    // loop has already overwritten would smear rather than hide.
                    const bx = box.x0 + ((x - box.x0) / block) * block;
                    const by = box.y0 + ((y - box.y0) / block) * block;
                    const src = (@as(usize, by) * width + bx) * 4;
                    if (src + 3 >= rgba.len) continue;
                    rgba[at] = rgba[src];
                    rgba[at + 1] = rgba[src + 1];
                    rgba[at + 2] = rgba[src + 2];
                },
            }
        }
    }
}

test "a redacted rectangle keeps no pixel of what was under it" {
    const w: u32 = 16;
    const h: u32 = 16;
    var rgba: [16 * 16 * 4]u8 = undefined;
    // A distinctive field, so any surviving pixel is recognisable.
    for (0..w * h) |i| {
        rgba[i * 4] = 200;
        rgba[i * 4 + 1] = 50;
        rgba[i * 4 + 2] = 100;
        rgba[i * 4 + 3] = 255;
    }
    const rect: Rect = .{ .x = 0.25, .y = 0.25, .w = 0.5, .h = 0.5 };
    redactRect(&rgba, w, h, rect, .fill, .{ 0, 0, 0 });

    const box = rect.pixels(w, h);
    var y = box.y0;
    while (y < box.y1) : (y += 1) {
        var x = box.x0;
        while (x < box.x1) : (x += 1) {
            const at = (@as(usize, y) * w + x) * 4;
            try t.expectEqual(@as(u8, 0), rgba[at]);
            try t.expectEqual(@as(u8, 0), rgba[at + 1]);
        }
    }
    // Outside is untouched: a redaction that ate the frame is not a redaction.
    try t.expectEqual(@as(u8, 200), rgba[0]);
    const last = (@as(usize, h - 1) * w + (w - 1)) * 4;
    try t.expectEqual(@as(u8, 200), rgba[last]);
}

test "alpha survives a redaction, so a masked frame still composites" {
    const w: u32 = 8;
    const h: u32 = 8;
    var rgba: [8 * 8 * 4]u8 = @splat(255);
    redactRect(&rgba, w, h, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .fill, .{ 0, 0, 0 });
    for (0..w * h) |i| try t.expectEqual(@as(u8, 255), rgba[i * 4 + 3]);
}

test "a rectangle outside the frame is refused rather than written past the end" {
    const w: u32 = 4;
    const h: u32 = 4;
    var rgba: [4 * 4 * 4]u8 = @splat(77);
    redactRect(&rgba, w, h, .{ .x = 0.9, .y = 0.9, .w = 0.5, .h = 0.5 }, .fill, .{ 0, 0, 0 });
    // Refused: the rectangle runs past the frame, and a rule that rounds outward
    // must not write past the buffer.
    for (rgba) |v| try t.expectEqual(@as(u8, 77), v);
}

test "a normalized rectangle maps to the same fraction at any size" {
    const rect: Rect = .{ .x = 0.5, .y = 0.0, .w = 0.5, .h = 1.0 };
    const small = rect.pixels(100, 100);
    const large = rect.pixels(1000, 1000);
    try t.expectEqual(@as(u32, 50), small.x0);
    try t.expectEqual(@as(u32, 500), large.x0);
    try t.expectEqual(@as(u32, 100), small.x1);
    try t.expectEqual(@as(u32, 1000), large.x1);
}

test "pixelate hides detail without flattening the block to one colour" {
    const w: u32 = 16;
    const h: u32 = 16;
    var rgba: [16 * 16 * 4]u8 = undefined;
    for (0..w * h) |i| {
        rgba[i * 4] = @intCast(i % 256);
        rgba[i * 4 + 1] = 0;
        rgba[i * 4 + 2] = 0;
        rgba[i * 4 + 3] = 255;
    }
    redactRect(&rgba, w, h, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .pixelate, .{ 0, 0, 0 });
    // Neighbours inside one block now match, which is what hides the detail.
    try t.expectEqual(rgba[0], rgba[4]);
    try t.expectEqual(rgba[0], rgba[7 * 4]);
    // A different block keeps its own value, so the frame is not one flat colour.
    try t.expect(rgba[0] != rgba[8 * 4]);
}
