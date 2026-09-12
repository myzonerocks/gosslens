//! What is worth remembering. A camera produces thirty frames a second and
//! almost none of them are worth keeping: this decides which are, from the
//! change score the egress rail already computes, the events the frame carried,
//! and how unlike anything already remembered it is. Novelty is the one that
//! matters, because a change score alone remembers a hundred frames of the same
//! sign from slightly different angles.

const std = @import("std");
const vector_index = @import("vector_index.zig");
const hnsw = @import("hnsw.zig");

pub const Options = struct {
    /// Below this the frame is too like the last kept one to be worth keeping,
    /// however much it changed: a camera panning back and forth over one desk
    /// changes constantly and is never new.
    novelty_threshold: f32 = 0.15,
    /// A frame that changed less than this is not considered at all, so a still
    /// camera costs one comparison.
    change_threshold: f32 = 0.05,
    /// Whatever else is true, never more often than this, so a scene that keeps
    /// changing cannot fill the memory by itself.
    min_interval_us: i64 = 500_000,
    /// An event carried by the frame lowers the bar rather than bypassing it:
    /// something happened, but a duplicate of what is already remembered is
    /// still a duplicate.
    event_novelty_threshold: f32 = 0.05,
    max_keyframes: usize = 512,
};

pub const Decision = struct {
    keep: bool,
    /// One minus the best similarity to anything already remembered, so a frame
    /// unlike everything reads as one and an exact repeat as zero.
    novelty: f32,
    reason: Reason,
};

pub const Reason = enum {
    /// Nothing is remembered yet, so the first frame worth anything is kept.
    first,
    novel,
    /// Something happened here, and it is different enough to be worth it.
    event,
    too_soon,
    too_similar,
    too_still,
};

/// Decides whether to remember this frame. The index is the memory itself, so
/// novelty is measured against what is actually kept rather than against the
/// previous frame, which is what stops a slow pan filling the store.
pub fn decide(
    index: *hnsw.Index,
    embedding: []const f32,
    change_score: f32,
    event_count: u32,
    timestamp_us: i64,
    last_kept_us: i64,
    opts: Options,
) !Decision {
    if (index.count() == 0) {
        return .{ .keep = true, .novelty = 1, .reason = .first };
    }
    if (timestamp_us - last_kept_us < opts.min_interval_us) {
        return .{ .keep = false, .novelty = 0, .reason = .too_soon };
    }
    if (change_score < opts.change_threshold and event_count == 0) {
        return .{ .keep = false, .novelty = 0, .reason = .too_still };
    }

    var nearest: [1]vector_index.Match = undefined;
    const found = try index.search(embedding, &nearest, 32);
    const novelty: f32 = if (found == 0) 1 else @max(0, 1 - nearest[0].score);
    const bar = if (event_count > 0) opts.event_novelty_threshold else opts.novelty_threshold;
    if (novelty < bar) {
        return .{ .keep = false, .novelty = novelty, .reason = .too_similar };
    }
    return .{
        .keep = true,
        .novelty = novelty,
        .reason = if (event_count > 0) .event else .novel,
    };
}

/// One remembered frame. The thumbnail and the snapshot record are the caller's
/// bytes; this holds where they live, not the pixels themselves.
pub const Keyframe = struct {
    id: u64,
    timestamp_us: i64,
    novelty: f32,
    reason: Reason,
    thumbnail_offset: usize,
    thumbnail_len: usize,
    snapshot_offset: usize,
    snapshot_len: usize,
};

const testing = std.testing;

test "the first frame is kept and a still camera is not asked twice" {
    var index = try hnsw.Index.init(testing.allocator, 4, .{ .connections = 4 });
    defer index.deinit();
    const opts: Options = .{};

    const first = try decide(&index, &[_]f32{ 1, 0, 0, 0 }, 0.9, 0, 0, 0, opts);
    try testing.expect(first.keep);
    try testing.expectEqual(Reason.first, first.reason);
    try index.insert(1, &[_]f32{ 1, 0, 0, 0 });

    // Too soon after the last one, whatever it holds.
    const soon = try decide(&index, &[_]f32{ 0, 1, 0, 0 }, 0.9, 0, 100_000, 0, opts);
    try testing.expect(!soon.keep);
    try testing.expectEqual(Reason.too_soon, soon.reason);

    // A still camera is not measured against the index at all.
    const still = try decide(&index, &[_]f32{ 0, 1, 0, 0 }, 0.01, 0, 5_000_000, 0, opts);
    try testing.expect(!still.keep);
    try testing.expectEqual(Reason.too_still, still.reason);
}

test "novelty is measured against what is remembered, not against the last frame" {
    var index = try hnsw.Index.init(testing.allocator, 4, .{ .connections = 4 });
    defer index.deinit();
    const opts: Options = .{};
    try index.insert(1, &[_]f32{ 1, 0, 0, 0 });

    // A pan back to something already remembered changed a lot and is not new.
    const repeat = try decide(&index, &[_]f32{ 1, 0, 0, 0 }, 0.9, 0, 5_000_000, 0, opts);
    try testing.expect(!repeat.keep);
    try testing.expectEqual(Reason.too_similar, repeat.reason);
    try testing.expect(repeat.novelty < opts.novelty_threshold);

    // Something genuinely unlike anything kept.
    const fresh = try decide(&index, &[_]f32{ 0, 1, 0, 0 }, 0.9, 0, 5_000_000, 0, opts);
    try testing.expect(fresh.keep);
    try testing.expectEqual(Reason.novel, fresh.reason);
    try testing.expect(fresh.novelty > 0.9);
}

test "an event lowers the bar without bypassing it" {
    var index = try hnsw.Index.init(testing.allocator, 4, .{ .connections = 4 });
    defer index.deinit();
    const opts: Options = .{};
    try index.insert(1, &[_]f32{ 1, 0, 0, 0 });

    // Cosine 0.894 against what is remembered, so novelty is 0.106: under the
    // quiet bar of 0.15 and over the event bar of 0.05.
    const middling = [_]f32{ 2, 1, 0, 0 };
    const quiet = try decide(&index, &middling, 0.9, 0, 5_000_000, 0, opts);
    try testing.expect(!quiet.keep);
    const eventful = try decide(&index, &middling, 0.9, 2, 5_000_000, 0, opts);
    try testing.expect(eventful.keep);
    try testing.expectEqual(Reason.event, eventful.reason);

    // An exact repeat is still a repeat, event or not.
    const same = try decide(&index, &[_]f32{ 1, 0, 0, 0 }, 0.9, 5, 5_000_000, 0, opts);
    try testing.expect(!same.keep);
}
