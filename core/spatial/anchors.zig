//! Anchors that survive. A point agreed in a room is worth nothing if it is
//! forgotten when the app closes, and worth nothing to a second device if the
//! two cannot name the same point. This is the saved map: anchors with their
//! labels, in a versioned file, with the relocalization quality reported rather
//! than assumed.

const std = @import("std");

pub const Error = error{ OutOfMemory, Corrupt, Full, NotFound };

/// What an anchor is for. A label is the difference between "a point" and "the
/// left edge of the whiteboard", and it is what lets a second device agree.
pub const Purpose = enum(u8) {
    unknown = 0,
    /// Placed by a host or an agent, to hang something on.
    placement = 1,
    /// A recognised feature of the room, so two devices can match on it.
    landmark = 2,
    /// A point a person marked, which outlives the session that made it.
    marked = 3,
};

pub const Anchor = struct {
    id: u64,
    /// Column-major, the same convention every platform's anchor pose uses.
    pose: [16]f32,
    purpose: Purpose = .unknown,
    /// How sure the platform was when it last saw this, zero to one. An anchor
    /// restored from a file starts at zero until something relocalizes it, so a
    /// caller cannot mistake a remembered pose for a tracked one.
    confidence: f32 = 0,
    /// Borrowed at read time, owned by the store's arena once added.
    label: []const u8 = &.{},
    created_us: i64 = 0,
    last_seen_us: i64 = 0,
};

/// A bounded store with its labels copied, so an anchor outlives the frame that
/// made it and the map file that held it.
pub fn Store(comptime max_anchors: usize, comptime label_bytes: usize) type {
    return struct {
        const Self = @This();

        anchors: [max_anchors]Anchor = undefined,
        count: usize = 0,
        arena: [label_bytes]u8 = undefined,
        used: usize = 0,
        refused: u64 = 0,

        pub fn clear(s: *Self) void {
            s.count = 0;
            s.used = 0;
        }

        pub fn items(s: *const Self) []const Anchor {
            return s.anchors[0..s.count];
        }

        pub fn find(s: *const Self, id: u64) ?usize {
            for (s.anchors[0..s.count], 0..) |a, i| {
                if (a.id == id) return i;
            }
            return null;
        }

        /// Adds or replaces by id. The same id replaces rather than duplicating,
        /// so an anchor refined by a better observation does not leave the worse
        /// one beside it to be matched instead.
        pub fn put(s: *Self, anchor: Anchor) bool {
            if (s.find(anchor.id)) |at| {
                const kept = s.anchors[at].label;
                s.anchors[at] = anchor;
                s.anchors[at].label = kept;
                if (anchor.label.len != 0) {
                    if (s.used + anchor.label.len > label_bytes) {
                        s.refused += 1;
                        return false;
                    }
                    const start = s.used;
                    @memcpy(s.arena[start..][0..anchor.label.len], anchor.label);
                    s.used += anchor.label.len;
                    s.anchors[at].label = s.arena[start..][0..anchor.label.len];
                }
                return true;
            }
            if (s.count >= max_anchors or s.used + anchor.label.len > label_bytes) {
                s.refused += 1;
                return false;
            }
            s.anchors[s.count] = anchor;
            if (anchor.label.len != 0) {
                const start = s.used;
                @memcpy(s.arena[start..][0..anchor.label.len], anchor.label);
                s.used += anchor.label.len;
                s.anchors[s.count].label = s.arena[start..][0..anchor.label.len];
            }
            s.count += 1;
            return true;
        }

        pub fn remove(s: *Self, id: u64) bool {
            const at = s.find(id) orelse return false;
            // The labels stay where they are: compacting them would move every
            // surviving slice, and an anchor store is small enough that the
            // bytes a removal leaves behind are reclaimed on the next clear.
            for (at..s.count - 1) |i| s.anchors[i] = s.anchors[i + 1];
            s.count -= 1;
            return true;
        }

        /// What a saved map costs, so a caller sizes its buffer once.
        pub fn savedSize(s: *const Self) usize {
            var total: usize = @sizeOf(Header);
            for (s.items()) |a| total += @sizeOf(Entry) + a.label.len;
            return total;
        }

        /// Writes the map. A short buffer reports the size it needed rather than
        /// a truncated file that would load as a different room.
        pub fn save(s: *const Self, out: []u8) usize {
            const needed = s.savedSize();
            if (out.len < needed) return needed;
            var header: Header = .{ .magic = magic.*, .version = version, .count = @intCast(s.count) };
            @memcpy(out[0..@sizeOf(Header)], std.mem.asBytes(&header));
            var at: usize = @sizeOf(Header);
            for (s.items()) |a| {
                var entry: Entry = .{
                    .id = a.id,
                    .pose = a.pose,
                    .purpose = @intFromEnum(a.purpose),
                    .label_len = @intCast(a.label.len),
                    .created_us = a.created_us,
                    .last_seen_us = a.last_seen_us,
                };
                @memcpy(out[at..][0..@sizeOf(Entry)], std.mem.asBytes(&entry));
                at += @sizeOf(Entry);
                @memcpy(out[at..][0..a.label.len], a.label);
                at += a.label.len;
            }
            return needed;
        }

        /// Reads a map back. Confidence is deliberately not restored: a
        /// remembered pose is not a tracked one until something relocalizes it,
        /// and a caller that cannot tell the difference will draw in the wrong
        /// place with total assurance.
        pub fn load(s: *Self, bytes: []const u8) Error!void {
            if (bytes.len < @sizeOf(Header)) return error.Corrupt;
            var header: Header = undefined;
            @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(Header)]);
            if (!std.mem.eql(u8, &header.magic, magic)) return error.Corrupt;
            if (header.version != version) return error.Corrupt;
            if (header.count > max_anchors) return error.Full;

            s.clear();
            var at: usize = @sizeOf(Header);
            for (0..header.count) |_| {
                if (at + @sizeOf(Entry) > bytes.len) return error.Corrupt;
                var entry: Entry = undefined;
                @memcpy(std.mem.asBytes(&entry), bytes[at..][0..@sizeOf(Entry)]);
                at += @sizeOf(Entry);
                if (at + entry.label_len > bytes.len) return error.Corrupt;
                const label = bytes[at..][0..entry.label_len];
                at += entry.label_len;
                const purpose: Purpose = switch (entry.purpose) {
                    0 => .unknown,
                    1 => .placement,
                    2 => .landmark,
                    3 => .marked,
                    else => return error.Corrupt,
                };
                if (!s.put(.{
                    .id = entry.id,
                    .pose = entry.pose,
                    .purpose = purpose,
                    .confidence = 0,
                    .label = label,
                    .created_us = entry.created_us,
                    .last_seen_us = entry.last_seen_us,
                })) return error.Full;
            }
        }

        /// Marks an anchor seen again, which is the only thing that raises its
        /// confidence above what a file restored.
        pub fn relocalize(s: *Self, id: u64, pose: [16]f32, confidence: f32, now_us: i64) bool {
            const at = s.find(id) orelse return false;
            s.anchors[at].pose = pose;
            s.anchors[at].confidence = @max(0, @min(1, confidence));
            s.anchors[at].last_seen_us = now_us;
            return true;
        }

        /// How much of the saved map has been found again, which is what tells a
        /// caller whether it is in the same room or only thinks it is.
        pub fn relocalizedFraction(s: *const Self) f32 {
            if (s.count == 0) return 0;
            var seen: usize = 0;
            for (s.items()) |a| {
                if (a.confidence > 0) seen += 1;
            }
            return @as(f32, @floatFromInt(seen)) / @as(f32, @floatFromInt(s.count));
        }
    };
}

pub const magic = "GOSSANCH";
pub const version: u32 = 1;

const Header = extern struct {
    magic: [8]u8,
    version: u32,
    count: u32,
};

const Entry = extern struct {
    id: u64,
    pose: [16]f32,
    purpose: u8,
    label_len: u16,
    created_us: i64,
    last_seen_us: i64,
};

const testing = std.testing;

test "an anchor survives a save and comes back untracked" {
    var store: Store(8, 256) = .{};
    var pose: [16]f32 = @splat(0);
    pose[0] = 1;
    pose[5] = 1;
    pose[10] = 1;
    pose[15] = 1;
    pose[12] = 1.5;

    try testing.expect(store.put(.{ .id = 1, .pose = pose, .purpose = .marked, .confidence = 0.9, .label = "whiteboard left", .created_us = 100 }));
    try testing.expect(store.put(.{ .id = 2, .pose = pose, .purpose = .placement, .confidence = 0.5, .created_us = 200 }));
    try testing.expectApproxEqAbs(@as(f32, 1), store.relocalizedFraction(), 1e-6);

    const needed = store.save(&.{});
    const buffer = try testing.allocator.alloc(u8, needed);
    defer testing.allocator.free(buffer);
    try testing.expectEqual(needed, store.save(buffer));

    var restored: Store(8, 256) = .{};
    try restored.load(buffer);
    try testing.expectEqual(@as(usize, 2), restored.count);
    try testing.expectEqualStrings("whiteboard left", restored.items()[0].label);
    try testing.expectApproxEqAbs(@as(f32, 1.5), restored.items()[0].pose[12], 1e-6);
    // A remembered pose is not a tracked one, and nothing restored says it is.
    try testing.expectApproxEqAbs(@as(f32, 0), restored.items()[0].confidence, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), restored.relocalizedFraction(), 1e-6);

    // Seeing one again is what raises it, and says how much of the room is back.
    try testing.expect(restored.relocalize(1, pose, 0.8, 999));
    try testing.expectApproxEqAbs(@as(f32, 0.5), restored.relocalizedFraction(), 1e-6);
    try testing.expect(!restored.relocalize(77, pose, 1, 999));
}

test "the same id refines rather than duplicating, and a bad file is refused" {
    var store: Store(4, 64) = .{};
    const pose: [16]f32 = @splat(0);
    try testing.expect(store.put(.{ .id = 7, .pose = pose, .label = "door" }));
    try testing.expect(store.put(.{ .id = 7, .pose = pose, .confidence = 0.4 }));
    try testing.expectEqual(@as(usize, 1), store.count);
    // Replacing without a label keeps the one it had, so an anchor does not lose
    // its name to a refinement that did not carry one.
    try testing.expectEqualStrings("door", store.items()[0].label);

    try testing.expect(store.remove(7));
    try testing.expectEqual(@as(usize, 0), store.count);
    try testing.expect(!store.remove(7));

    var broken: Store(4, 64) = .{};
    try testing.expectError(error.Corrupt, broken.load(&[_]u8{ 1, 2, 3 }));
    var header = [_]u8{0} ** 16;
    @memcpy(header[0..8], magic);
    header[8] = 9;
    try testing.expectError(error.Corrupt, broken.load(&header));
}

test "the store refuses past its bounds and counts what it turned away" {
    var store: Store(2, 8) = .{};
    const pose: [16]f32 = @splat(0);
    try testing.expect(store.put(.{ .id = 1, .pose = pose, .label = "abcd" }));
    try testing.expect(store.put(.{ .id = 2, .pose = pose, .label = "efgh" }));
    // Out of slots and out of label room, both counted.
    try testing.expect(!store.put(.{ .id = 3, .pose = pose }));
    try testing.expect(!store.put(.{ .id = 4, .pose = pose, .label = "ijkl" }));
    try testing.expectEqual(@as(u64, 2), store.refused);
    try testing.expectEqual(@as(usize, 2), store.count);
}
