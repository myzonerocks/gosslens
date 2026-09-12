//! The action channel: what an agent draws back into the frame. Annotations are
//! addressed by id, so moving one every frame leaks no entry, and each carries a
//! lifetime because the failure mode of an imperative overlay is annotations
//! nobody removed.

const std = @import("std");

pub const Kind = enum(u32) {
    box = 1,
    label = 2,
    point = 3,
    arrow = 4,
    path = 5,
    highlight = 6,
    mask_overlay = 7,
    image = 8,
    meter = 9,
    _,
};

/// What an annotation is positioned against. A box drawn in screen space and a box
/// bound to a face are the same annotation with different anchors, so the anchor
/// is a field rather than a separate kind.
pub const AnchorSpace = enum(u32) {
    /// Normalized 0..1 over the frame, which survives a resolution change.
    screen = 0,
    /// Frame pixels, for a caller that already has them.
    pixels = 1,
    /// The world seam's own space.
    world = 2,
    /// Follows a track: a face, a hand, a body, a detection.
    track = 3,
    /// A named face region, reusing the region set the engine already has.
    face_region = 4,
};

/// What happens when the thing an annotation is bound to goes away. Stated rather
/// than assumed: a label that outlives its face is the bug an agent overlay makes
/// most often, and the engine cannot guess which of these the caller wanted.
pub const OnLost = enum(u32) { remove = 0, hold = 1, fade = 2 };

/// When an annotation goes away by itself.
pub const Lifetime = union(enum) {
    /// Until the caller removes it. The only one that can leak, and it leaks on
    /// purpose because some overlays are meant to persist.
    explicit,
    /// A number of rendered frames.
    frames: u32,
    /// A wall-clock span from when it was added.
    duration_us: i64,
    /// As long as the track it follows exists.
    track,
};

pub const Annotation = struct {
    id: u32,
    kind: Kind,
    space: AnchorSpace,
    /// The anchor: x, y, w, h in the anchor's own units, or a track id in x.
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    track_id: u32 = 0,
    colour: [4]u8 = .{ 255, 255, 255, 255 },
    /// Draw order. Equal z keeps insertion order, so a set added together lands
    /// in the order it was written rather than an arbitrary one.
    z: i32 = 0,
    opacity: f32 = 1.0,
    lifetime: Lifetime = .explicit,
    on_lost: OnLost = .remove,
    /// Text for a label, borrowed from the caller's batch for the call's span and
    /// copied by the store, so an annotation never points at a freed string.
    text: []const u8 = "",
    value: f32 = 0,

    pub fn valid(a: Annotation) bool {
        if (a.opacity < 0 or a.opacity > 1) return false;
        if (a.space == .track and a.track_id == 0) return false;
        if (a.kind == .label and a.text.len == 0) return false;
        if (a.space == .screen) {
            for (a.rect) |v| {
                if (!(v >= -1.0 and v <= 2.0)) return false;
            }
        }
        return true;
    }
};

pub const Error = error{ Full, TextTooLong, Invalid, OutOfMemory };

/// A bounded set of live annotations. Bounded because an agent that adds and never
/// removes must not grow the engine, and the bound is what makes the failure a
/// refused add rather than a slow leak nobody attributes.
pub fn Store(comptime max_annotations: usize, comptime text_bytes: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            annotation: Annotation,
            /// Where this entry's text lives inside the arena.
            text_at: u32 = 0,
            text_len: u32 = 0,
            added_frame: u64 = 0,
            added_us: i64 = 0,
            /// Insertion order, so equal z keeps the order it was written in.
            seq: u64 = 0,
        };

        entries: [max_annotations]Entry = undefined,
        len: usize = 0,
        /// Text is copied here rather than borrowed, so an annotation outliving the
        /// batch that added it never points at a freed string.
        text: [text_bytes]u8 = undefined,
        text_used: usize = 0,
        next_seq: u64 = 0,
        /// Adds refused because the store was full, reported rather than silent.
        refused: u64 = 0,

        pub fn count(s: Self) usize {
            return s.len;
        }

        fn find(s: *Self, id: u32) ?usize {
            for (s.entries[0..s.len], 0..) |e, i| {
                if (e.annotation.id == id) return i;
            }
            return null;
        }

        /// Adds, or replaces the annotation with the same id. Replacing rather than
        /// duplicating is what lets an agent update one box every frame without
        /// rebuilding the set or leaking a new entry each time.
        pub fn put(s: *Self, a: Annotation, frame: u64, now_us: i64) Error!void {
            if (!a.valid()) return error.Invalid;
            if (a.text.len > text_bytes) return error.TextTooLong;

            const existing = s.find(a.id);
            // Release the old text BEFORE reclaiming, or an update holds its own
            // previous string against the arena and a long-lived label runs it out.
            if (existing) |at| s.entries[at].text_len = 0;

            var entry: Entry = .{
                .annotation = a,
                .added_frame = frame,
                .added_us = now_us,
                .seq = s.next_seq,
            };
            if (a.text.len != 0) {
                if (s.text_used + a.text.len > text_bytes) {
                    s.compactText();
                    if (s.text_used + a.text.len > text_bytes) return error.TextTooLong;
                }
                @memcpy(s.text[s.text_used..][0..a.text.len], a.text);
                entry.text_at = @intCast(s.text_used);
                entry.text_len = @intCast(a.text.len);
                s.text_used += a.text.len;
            }
            entry.annotation.text = "";

            if (existing) |at| {
                // Keep the original order so an updated annotation does not jump
                // above its neighbours every time its value changes.
                entry.seq = s.entries[at].seq;
                s.entries[at] = entry;
                return;
            }
            if (s.len == max_annotations) {
                s.refused +|= 1;
                return error.Full;
            }
            s.next_seq += 1;
            s.entries[s.len] = entry;
            s.len += 1;
        }

        pub fn remove(s: *Self, id: u32) bool {
            const at = s.find(id) orelse return false;
            for (at..s.len - 1) |i| s.entries[i] = s.entries[i + 1];
            s.len -= 1;
            return true;
        }

        pub fn clear(s: *Self) void {
            s.len = 0;
            s.text_used = 0;
        }

        pub fn textOf(s: *const Self, index: usize) []const u8 {
            const e = s.entries[index];
            return s.text[e.text_at..][0..e.text_len];
        }

        /// Drops what has expired. Called once per frame, so an overlay nobody
        /// removed goes away on its own terms rather than staying for ever.
        pub fn expire(s: *Self, frame: u64, now_us: i64, trackAlive: *const fn (u32) bool) void {
            var i: usize = 0;
            while (i < s.len) {
                const e = s.entries[i];
                const gone = switch (e.annotation.lifetime) {
                    .explicit => false,
                    .frames => |n| frame >= e.added_frame + n,
                    .duration_us => |d| now_us - e.added_us >= d,
                    .track => !trackAlive(e.annotation.track_id),
                };
                const lost_track = e.annotation.space == .track and
                    e.annotation.on_lost == .remove and
                    !trackAlive(e.annotation.track_id);
                if (gone or lost_track) {
                    _ = s.remove(e.annotation.id);
                    continue;
                }
                i += 1;
            }
        }

        /// Reclaims the text arena from the live entries, so a long session of
        /// updates does not run the arena out on strings nobody references.
        fn compactText(s: *Self) void {
            var packed_bytes: [text_bytes]u8 = undefined;
            var at: usize = 0;
            for (s.entries[0..s.len]) |*e| {
                if (e.text_len == 0) continue;
                @memcpy(packed_bytes[at..][0..e.text_len], s.text[e.text_at..][0..e.text_len]);
                e.text_at = @intCast(at);
                at += e.text_len;
            }
            @memcpy(s.text[0..at], packed_bytes[0..at]);
            s.text_used = at;
        }

        /// The draw order: z ascending, then insertion order. Written into the
        /// caller's buffer so ordering allocates nothing per frame.
        pub fn order(s: *const Self, out: []usize) usize {
            const n = @min(out.len, s.len);
            for (0..n) |i| out[i] = i;
            // Insertion sort: the set is small and bounded, and a stable order is
            // what the contract promises.
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const key = out[i];
                var j = i;
                while (j > 0 and less(s.entries[key], s.entries[out[j - 1]])) : (j -= 1) {
                    out[j] = out[j - 1];
                }
                out[j] = key;
            }
            return n;
        }

        fn less(a: Entry, b: Entry) bool {
            if (a.annotation.z != b.annotation.z) return a.annotation.z < b.annotation.z;
            return a.seq < b.seq;
        }
    };
}

const t = std.testing;

const TestStore = Store(8, 256);

fn alwaysAlive(_: u32) bool {
    return true;
}

fn neverAlive(_: u32) bool {
    return false;
}

fn box(id: u32) Annotation {
    return .{ .id = id, .kind = .box, .space = .screen, .rect = .{ 0.1, 0.1, 0.2, 0.2 } };
}

test "an id is updated in place rather than duplicated" {
    var s: TestStore = .{};
    try s.put(box(1), 0, 0);
    var moved = box(1);
    moved.rect = .{ 0.5, 0.5, 0.1, 0.1 };
    try s.put(moved, 1, 1000);
    try t.expectEqual(@as(usize, 1), s.count());
    try t.expectEqual(@as(f32, 0.5), s.entries[0].annotation.rect[0]);
}

test "an updated annotation keeps its place in the draw order" {
    var s: TestStore = .{};
    try s.put(box(1), 0, 0);
    try s.put(box(2), 0, 0);
    try s.put(box(3), 0, 0);
    // Updating the first must not lift it above the others every frame.
    try s.put(box(1), 1, 0);
    var out: [8]usize = undefined;
    const n = s.order(&out);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(u32, 1), s.entries[out[0]].annotation.id);
    try t.expectEqual(@as(u32, 3), s.entries[out[2]].annotation.id);
}

test "z orders above insertion, and equal z keeps insertion order" {
    var s: TestStore = .{};
    var a = box(1);
    a.z = 5;
    var b = box(2);
    b.z = -1;
    var c_ = box(3);
    c_.z = 5;
    try s.put(a, 0, 0);
    try s.put(b, 0, 0);
    try s.put(c_, 0, 0);
    var out: [8]usize = undefined;
    _ = s.order(&out);
    try t.expectEqual(@as(u32, 2), s.entries[out[0]].annotation.id);
    try t.expectEqual(@as(u32, 1), s.entries[out[1]].annotation.id);
    try t.expectEqual(@as(u32, 3), s.entries[out[2]].annotation.id);
}

test "a frame lifetime expires on its own, so nobody has to remember" {
    var s: TestStore = .{};
    var a = box(1);
    a.lifetime = .{ .frames = 3 };
    try s.put(a, 10, 0);
    s.expire(12, 0, alwaysAlive);
    try t.expectEqual(@as(usize, 1), s.count());
    s.expire(13, 0, alwaysAlive);
    try t.expectEqual(@as(usize, 0), s.count());
}

test "a duration lifetime expires on the clock" {
    var s: TestStore = .{};
    var a = box(1);
    a.lifetime = .{ .duration_us = 500_000 };
    try s.put(a, 0, 1_000_000);
    s.expire(1, 1_400_000, alwaysAlive);
    try t.expectEqual(@as(usize, 1), s.count());
    s.expire(2, 1_500_000, alwaysAlive);
    try t.expectEqual(@as(usize, 0), s.count());
}

test "a track-bound annotation goes when its track does, or holds if asked" {
    var s: TestStore = .{};
    var follow = box(1);
    follow.space = .track;
    follow.track_id = 7;
    follow.on_lost = .remove;
    try s.put(follow, 0, 0);
    s.expire(1, 0, alwaysAlive);
    try t.expectEqual(@as(usize, 1), s.count());
    s.expire(2, 0, neverAlive);
    try t.expectEqual(@as(usize, 0), s.count());

    var held = box(2);
    held.space = .track;
    held.track_id = 7;
    held.on_lost = .hold;
    try s.put(held, 0, 0);
    s.expire(3, 0, neverAlive);
    try t.expectEqual(@as(usize, 1), s.count());
}

test "a full store refuses and counts, rather than leaking slowly" {
    var s: TestStore = .{};
    for (1..9) |i| try s.put(box(@intCast(i)), 0, 0);
    try t.expectEqual(@as(usize, 8), s.count());
    try t.expectError(error.Full, s.put(box(99), 0, 0));
    try t.expectEqual(@as(u64, 1), s.refused);
    // Removing one makes room again: the bound is a ceiling, not a one-way door.
    try t.expect(s.remove(1));
    try s.put(box(99), 0, 0);
}

test "text is copied, so an annotation never points at a freed string" {
    var s: TestStore = .{};
    var buffer = [_]u8{ 'h', 'i', ' ', 't', 'h', 'e', 'r', 'e' };
    const label: Annotation = .{ .id = 1, .kind = .label, .space = .screen, .text = &buffer };
    try s.put(label, 0, 0);
    // The caller's buffer changes under us; the store's copy does not.
    @memset(&buffer, 'X');
    try t.expectEqualStrings("hi there", s.textOf(0));
}

test "the text arena is reclaimed rather than run out by updates" {
    var s: TestStore = .{};
    const long = "a" ** 200;
    const label: Annotation = .{ .id = 1, .kind = .label, .space = .screen, .text = long };
    try s.put(label, 0, 0);
    // Updating the same label many times must not exhaust a 256-byte arena.
    for (0..20) |_| try s.put(label, 0, 0);
    try t.expectEqual(@as(usize, 1), s.count());
    try t.expectEqualStrings(long, s.textOf(0));
}

test "an invalid annotation is refused by name" {
    var s: TestStore = .{};
    var bad = box(1);
    bad.opacity = 2.0;
    try t.expectError(error.Invalid, s.put(bad, 0, 0));
    var trackless = box(2);
    trackless.space = .track;
    try t.expectError(error.Invalid, s.put(trackless, 0, 0));
    const empty: Annotation = .{ .id = 3, .kind = .label, .space = .screen };
    try t.expectError(error.Invalid, s.put(empty, 0, 0));
}

test "clearing drops everything including the text" {
    var s: TestStore = .{};
    try s.put(.{ .id = 1, .kind = .label, .space = .screen, .text = "gone" }, 0, 0);
    s.clear();
    try t.expectEqual(@as(usize, 0), s.count());
    try t.expectEqual(@as(usize, 0), s.text_used);
}
