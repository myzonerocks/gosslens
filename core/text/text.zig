//! The text rail: what the frame says, from whatever found it. A recognised
//! region, a barcode and a QR code all land in one stream, so a caller asking
//! "what does this frame say" reads one field rather than three.

const std = @import("std");

pub const region = @import("region.zig");
pub const detect = @import("detect.zig");
pub const rectify = @import("rectify.zig");
pub const recognize = @import("recognize.zig");

pub const Quad = region.Quad;
pub const Point = region.Point;
pub const Region = region.Region;
pub const Script = region.Script;
pub const Direction = region.Direction;

/// What found this text. A caller that wants only scanned codes, or only read
/// text, filters on it rather than keeping two streams in step.
pub const Origin = enum { recognized, barcode, qr };

/// One thing the frame says. The text is a slice of the store's own buffer, so
/// an entry outlives the frame that produced it without borrowing from it.
pub const Entry = struct {
    text: []const u8,
    quad: Quad,
    confidence: f32,
    origin: Origin,
    script: Script = .unknown,
    direction: Direction = .left_to_right,
    track_id: u32 = 0,
    /// Which line and paragraph this entry belongs to, so a caller can rebuild
    /// the reading without redoing the geometry.
    line: u16 = 0,
    paragraph: u16 = 0,
    first_seen_us: i64 = 0,
    last_seen_us: i64 = 0,
};

/// A bounded store of what the frame says, with the text copied. Bounded
/// because an unbounded one is a leak with a nicer name, and a refused add is
/// counted so a caller learns it is losing readings rather than guessing.
pub fn Store(comptime max_entries: usize, comptime text_bytes: usize) type {
    return struct {
        const Self = @This();

        entries: [max_entries]Entry = undefined,
        count: usize = 0,
        arena: [text_bytes]u8 = undefined,
        used: usize = 0,
        refused: u64 = 0,
        /// The next id handed to a region nothing matched, so an id is never
        /// reused while anything still refers to it.
        next_track: u32 = 1,

        pub fn clear(s: *Self) void {
            s.count = 0;
            s.used = 0;
        }

        pub fn add(s: *Self, entry: Entry) bool {
            if (s.count >= max_entries or s.used + entry.text.len > text_bytes) {
                s.refused += 1;
                return false;
            }
            const start = s.used;
            @memcpy(s.arena[start..][0..entry.text.len], entry.text);
            s.used += entry.text.len;
            s.entries[s.count] = entry;
            s.entries[s.count].text = s.arena[start..][0..entry.text.len];
            s.count += 1;
            return true;
        }

        pub fn items(s: *const Self) []const Entry {
            return s.entries[0..s.count];
        }

        /// Whether anything in the store contains the needle, which is the
        /// trigger a lens binds to watch for a word.
        pub fn matches(s: *const Self, needle: []const u8) bool {
            if (needle.len == 0) return false;
            for (s.items()) |e| {
                if (std.mem.indexOf(u8, e.text, needle) != null) return true;
            }
            return false;
        }

        /// A hash of everything read, so "the text changed" is one comparison
        /// rather than a walk. Order matters: text that moved is text that
        /// changed as far as an overlay pinned to it is concerned.
        pub fn digest(s: *const Self) u64 {
            var h = std.hash.Wyhash.init(0x7e57);
            for (s.items()) |e| {
                h.update(e.text);
                h.update(std.mem.asBytes(&e.quad.corners[0]));
            }
            return h.final();
        }
    };
}

/// Carries track ids from the previous frame's regions onto this frame's, so a
/// label pinned to a sign keeps its identity while the sign stays put. Matching
/// is on centre distance against the region's own size, which survives a camera
/// that moves and a region that grows.
pub fn carryTracks(previous: []const Region, current: []Region, next_id: *u32) void {
    for (current) |*now| {
        var best: ?usize = null;
        var best_distance: f32 = std.math.floatMax(f32);
        const c = now.quad.centre();
        const size = now.quad.extent();
        const reach = @max(size.w, size.h) * 0.5;
        for (previous, 0..) |was, i| {
            if (was.track_id == 0) continue;
            var taken = false;
            for (current) |already| {
                if (already.track_id == was.track_id) taken = true;
            }
            if (taken) continue;
            const p = was.quad.centre();
            const d = @sqrt((p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y));
            if (d < best_distance and d <= reach) {
                best_distance = d;
                best = i;
            }
        }
        if (best) |i| {
            now.track_id = previous[i].track_id;
            now.content_hash = previous[i].content_hash;
        } else {
            now.track_id = next_id.*;
            next_id.* += 1;
        }
    }
}

const testing = std.testing;

test "the store copies its text, bounds itself, and counts what it refused" {
    var store: Store(2, 16) = .{};
    var buffer = [_]u8{ 'E', 'X', 'I', 'T' };
    try testing.expect(store.add(.{ .text = &buffer, .quad = boxAt(0.1, 0.1), .confidence = 0.9, .origin = .recognized }));
    // The store owns its copy, so overwriting the caller's buffer changes nothing.
    @memset(&buffer, 'Z');
    try testing.expectEqualStrings("EXIT", store.items()[0].text);

    try testing.expect(store.add(.{ .text = "OPEN", .quad = boxAt(0.2, 0.2), .confidence = 0.8, .origin = .qr }));
    try testing.expect(!store.add(.{ .text = "FULL", .quad = boxAt(0.3, 0.3), .confidence = 0.7, .origin = .barcode }));
    try testing.expectEqual(@as(u64, 1), store.refused);
    try testing.expect(store.matches("XI"));
    try testing.expect(!store.matches("CLOSED"));
}

test "the digest changes when the text changes or when it moves" {
    var store: Store(4, 64) = .{};
    _ = store.add(.{ .text = "SLOW", .quad = boxAt(0.1, 0.1), .confidence = 1, .origin = .recognized });
    const first = store.digest();

    store.clear();
    _ = store.add(.{ .text = "SLOW", .quad = boxAt(0.1, 0.1), .confidence = 1, .origin = .recognized });
    try testing.expectEqual(first, store.digest());

    store.clear();
    _ = store.add(.{ .text = "STOP", .quad = boxAt(0.1, 0.1), .confidence = 1, .origin = .recognized });
    try testing.expect(first != store.digest());

    store.clear();
    _ = store.add(.{ .text = "SLOW", .quad = boxAt(0.4, 0.4), .confidence = 1, .origin = .recognized });
    try testing.expect(first != store.digest());
}

test "a region that stays put keeps its track id and a new one gets a fresh id" {
    var next: u32 = 1;
    var first = [_]Region{
        .{ .quad = boxAt(0.10, 0.10), .confidence = 1 },
        .{ .quad = boxAt(0.60, 0.60), .confidence = 1 },
    };
    carryTracks(&.{}, &first, &next);
    try testing.expectEqual(@as(u32, 1), first[0].track_id);
    try testing.expectEqual(@as(u32, 2), first[1].track_id);

    // The first drifted a little, the second is gone, and a third appeared.
    var second = [_]Region{
        .{ .quad = boxAt(0.11, 0.105), .confidence = 1 },
        .{ .quad = boxAt(0.30, 0.80), .confidence = 1 },
    };
    carryTracks(&first, &second, &next);
    try testing.expectEqual(@as(u32, 1), second[0].track_id);
    try testing.expectEqual(@as(u32, 3), second[1].track_id);
}

fn boxAt(x: f32, y: f32) Quad {
    return .{ .corners = .{
        .{ .x = x, .y = y },
        .{ .x = x + 0.2, .y = y },
        .{ .x = x + 0.2, .y = y + 0.05 },
        .{ .x = x, .y = y + 0.05 },
    } };
}
