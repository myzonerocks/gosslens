//! The degradation ladder. Effects degrade so capture never does: each step
//! is a named state, transitions are hysteresis-guarded so the pipeline does
//! not flap at a boundary, and every change is reported to the session for
//! logging. The controller is pure state plus measured inputs, so tests can
//! force any walk of the ladder.

const std = @import("std");

/// Ordered from full quality down. The camera itself never stops; the last
/// step still renders the plain preview.
pub const Level = enum(u8) {
    full,
    reduced_ml_cadence,
    segmentation_off,
    beauty_simplified,
    passthrough,

    pub fn moreDegraded(level: Level) ?Level {
        if (level == .passthrough) return null;
        return @enumFromInt(@intFromEnum(level) + 1);
    }

    pub fn lessDegraded(level: Level) ?Level {
        if (level == .full) return null;
        return @enumFromInt(@intFromEnum(level) - 1);
    }
};

/// What each rung actually stops. A stride of N runs that analysis on one
/// frame in N and reuses the last published result in between; zero stops it.
/// The camera path is untouched at every rung, so the preview keeps drawing
/// and a recording keeps every frame while the work stacked on top thins out.
pub const Plan = struct {
    face_stride: u8,
    hand_stride: u8,
    pose_stride: u8,
    segmentation_stride: u8,
    ml_stride: u8,
    beauty: Beauty,
    effects: Effects,

    /// full runs the whole beauty chain, core keeps smoothing and tone and
    /// drops makeup, lashes, reshape and retouch, off bypasses the bridge
    /// without tearing it down so recovery is a flag rather than a re-init.
    pub const Beauty = enum { full, core, off };
    /// off skips the lens chain walk and draws the camera straight through.
    pub const Effects = enum { full, off };

    /// True when an analysis on this stride runs on the given frame.
    pub fn runs(stride: u8, frame_index: u64) bool {
        if (stride == 0) return false;
        return frame_index % stride == 0;
    }
};

/// The plan a rung carries. Strides lengthen before anything switches off, and
/// the segmentation mask is the first whole capability to go because its
/// degrade (a zero mask) is already a defined, tested behaviour.
pub fn planFor(level: Level) Plan {
    return switch (level) {
        .full => .{ .face_stride = 1, .hand_stride = 1, .pose_stride = 1, .segmentation_stride = 1, .ml_stride = 1, .beauty = .full, .effects = .full },
        .reduced_ml_cadence => .{ .face_stride = 2, .hand_stride = 2, .pose_stride = 2, .segmentation_stride = 2, .ml_stride = 2, .beauty = .full, .effects = .full },
        .segmentation_off => .{ .face_stride = 2, .hand_stride = 2, .pose_stride = 2, .segmentation_stride = 0, .ml_stride = 3, .beauty = .full, .effects = .full },
        .beauty_simplified => .{ .face_stride = 3, .hand_stride = 3, .pose_stride = 3, .segmentation_stride = 0, .ml_stride = 4, .beauty = .core, .effects = .full },
        .passthrough => .{ .face_stride = 0, .hand_stride = 0, .pose_stride = 0, .segmentation_stride = 0, .ml_stride = 0, .beauty = .off, .effects = .off },
    };
}

pub const ThermalState = enum(u8) { nominal, fair, serious, critical };

pub const Inputs = struct {
    /// Measured whole-pipeline time for the last frame.
    frame_time_us: u32,
    /// Fed by the SDK from the platform thermal API.
    thermal: ThermalState,
};

pub const Config = struct {
    /// The frame-time budget the session must hold.
    budget_us: u32,
    /// Fraction of budget above which pressure accumulates, in percent.
    degrade_pct: u32 = 100,
    /// Fraction of budget below which recovery accumulates, in percent.
    recover_pct: u32 = 70,
    /// Consecutive over-budget frames before stepping down.
    degrade_dwell: u32 = 12,
    /// Consecutive comfortable frames before stepping back up. Longer than
    /// the degrade dwell on purpose: recovery must be earned.
    recover_dwell: u32 = 120,
};

pub const Transition = struct {
    from: Level,
    to: Level,
};

pub const Controller = struct {
    config: Config,
    level: Level = .full,
    over_streak: u32 = 0,
    under_streak: u32 = 0,

    pub fn init(config: Config) Controller {
        std.debug.assert(config.recover_pct < config.degrade_pct);
        return .{ .config = config };
    }

    /// One call per frame with measured inputs; returns a transition when
    /// the level changes. Serious thermal pressure degrades a frame above the
    /// recovery line at full dwell speed and leaves a cheap frame alone, since a
    /// pass that costs a millisecond buys nothing by going; critical jumps to passthrough.
    pub fn step(c: *Controller, inputs: Inputs) ?Transition {
        if (inputs.thermal == .critical) {
            c.over_streak = 0;
            c.under_streak = 0;
            if (c.level != .passthrough) {
                const from = c.level;
                c.level = .passthrough;
                return .{ .from = from, .to = .passthrough };
            }
            return null;
        }

        const degrade_threshold = c.config.budget_us / 100 * c.config.degrade_pct;
        const recover_threshold = c.config.budget_us / 100 * c.config.recover_pct;
        const over = inputs.frame_time_us > degrade_threshold or
            (inputs.thermal == .serious and inputs.frame_time_us > recover_threshold);
        const under = inputs.frame_time_us < recover_threshold and inputs.thermal == .nominal;

        if (over) {
            c.over_streak += 1;
            c.under_streak = 0;
        } else if (under) {
            c.under_streak += 1;
            c.over_streak = 0;
        } else {
            c.over_streak = 0;
            c.under_streak = 0;
        }

        if (c.over_streak >= c.config.degrade_dwell) {
            c.over_streak = 0;
            if (c.level.moreDegraded()) |next| {
                const from = c.level;
                c.level = next;
                return .{ .from = from, .to = next };
            }
        } else if (c.under_streak >= c.config.recover_dwell) {
            c.under_streak = 0;
            if (c.level.lessDegraded()) |next| {
                const from = c.level;
                c.level = next;
                return .{ .from = from, .to = next };
            }
        }
        return null;
    }
};

const t = std.testing;

const test_config: Config = .{
    .budget_us = 16_000,
    .degrade_dwell = 3,
    .recover_dwell = 6,
};

fn stepMany(c: *Controller, inputs: Inputs, frames: u32) ?Transition {
    var last: ?Transition = null;
    for (0..frames) |_| {
        if (c.step(inputs)) |tr| last = tr;
    }
    return last;
}

test "sustained overload steps down one level after the dwell" {
    var c = Controller.init(test_config);
    const slow: Inputs = .{ .frame_time_us = 20_000, .thermal = .nominal };
    try t.expect(c.step(slow) == null);
    try t.expect(c.step(slow) == null);
    const tr = c.step(slow).?;
    try t.expectEqual(Level.full, tr.from);
    try t.expectEqual(Level.reduced_ml_cadence, tr.to);
}

test "a single spike does not degrade" {
    var c = Controller.init(test_config);
    _ = c.step(.{ .frame_time_us = 30_000, .thermal = .nominal });
    _ = c.step(.{ .frame_time_us = 30_000, .thermal = .nominal });
    _ = c.step(.{ .frame_time_us = 8_000, .thermal = .nominal });
    try t.expect(stepMany(&c, .{ .frame_time_us = 15_000, .thermal = .nominal }, 10) == null);
    try t.expectEqual(Level.full, c.level);
}

test "recovery needs a longer streak than degradation" {
    var c = Controller.init(test_config);
    _ = stepMany(&c, .{ .frame_time_us = 20_000, .thermal = .nominal }, 3);
    try t.expectEqual(Level.reduced_ml_cadence, c.level);

    const fast: Inputs = .{ .frame_time_us = 8_000, .thermal = .nominal };
    try t.expect(stepMany(&c, fast, 5) == null);
    const tr = c.step(fast).?;
    try t.expectEqual(Level.full, tr.to);
}

test "the band between thresholds holds the current level" {
    var c = Controller.init(test_config);
    _ = stepMany(&c, .{ .frame_time_us = 20_000, .thermal = .nominal }, 3);
    try t.expectEqual(Level.reduced_ml_cadence, c.level);
    try t.expect(stepMany(&c, .{ .frame_time_us = 13_000, .thermal = .nominal }, 500) == null);
    try t.expectEqual(Level.reduced_ml_cadence, c.level);
}

test "critical thermal jumps straight to passthrough and recovery walks back" {
    var c = Controller.init(test_config);
    const tr = c.step(.{ .frame_time_us = 8_000, .thermal = .critical }).?;
    try t.expectEqual(Level.full, tr.from);
    try t.expectEqual(Level.passthrough, tr.to);

    const fast: Inputs = .{ .frame_time_us = 8_000, .thermal = .nominal };
    const up = stepMany(&c, fast, 6).?;
    try t.expectEqual(Level.beauty_simplified, up.to);
}

test "serious thermal degrades a frame above the recovery line even under budget" {
    var c = Controller.init(test_config);
    const above = test_config.budget_us / 100 * test_config.recover_pct + 1;
    const tr = stepMany(&c, .{ .frame_time_us = above, .thermal = .serious }, 3).?;
    try t.expectEqual(Level.reduced_ml_cadence, tr.to);
}

test "serious thermal leaves a cheap frame alone" {
    var c = Controller.init(test_config);
    try t.expect(stepMany(&c, .{ .frame_time_us = 1_000, .thermal = .serious }, 100) == null);
    try t.expectEqual(Level.full, c.level);
}

test "the ladder walks all the way down and stops" {
    var c = Controller.init(test_config);
    const slow: Inputs = .{ .frame_time_us = 40_000, .thermal = .nominal };
    _ = stepMany(&c, slow, 100);
    try t.expectEqual(Level.passthrough, c.level);
    try t.expect(stepMany(&c, slow, 100) == null);
}

test "the plan thins analysis before it stops any of it" {
    const full = planFor(.full);
    try t.expectEqual(@as(u8, 1), full.face_stride);
    try t.expectEqual(Plan.Beauty.full, full.beauty);
    try t.expectEqual(Plan.Effects.full, full.effects);

    const reduced = planFor(.reduced_ml_cadence);
    try t.expect(reduced.face_stride > full.face_stride);
    try t.expect(reduced.segmentation_stride > 0);

    try t.expectEqual(@as(u8, 0), planFor(.segmentation_off).segmentation_stride);
    try t.expectEqual(Plan.Beauty.core, planFor(.beauty_simplified).beauty);

    const bottom = planFor(.passthrough);
    try t.expectEqual(Plan.Beauty.off, bottom.beauty);
    try t.expectEqual(Plan.Effects.off, bottom.effects);
    try t.expectEqual(@as(u8, 0), bottom.face_stride);
}

test "a stride runs one frame in n and a zero stride never runs" {
    try t.expect(Plan.runs(1, 0));
    try t.expect(Plan.runs(1, 7));
    try t.expect(Plan.runs(2, 0));
    try t.expect(!Plan.runs(2, 1));
    try t.expect(Plan.runs(2, 2));
    try t.expect(!Plan.runs(0, 0));
    try t.expect(!Plan.runs(0, 9));
}
