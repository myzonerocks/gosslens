//! A value per graph node, indexed rather than hashed. The chain walk reads a
//! node's parameters every frame, which a hash map charged a hash for on a path
//! the graph contract says does none. Indices are dense, so a slice answers in
//! one load, under the same API the call sites already used.

const std = @import("std");
const topology = @import("topology.zig");

/// Values keyed by node index. Grows to cover the highest index stored; an
/// index never stored reads as null, the same as a missing map entry.
pub fn NodeMap(comptime V: type) type {
    return struct {
        const Self = @This();

        slots: []?V = &.{},

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            if (self.slots.len != 0) gpa.free(self.slots);
            self.slots = &.{};
        }

        /// Stores a value, growing to cover the index. The grow is an edit-time
        /// cost: a frame reads only what activation already stored.
        pub fn put(self: *Self, gpa: std.mem.Allocator, index: topology.NodeIndex, value: V) std.mem.Allocator.Error!void {
            const want = @as(usize, index) + 1;
            if (want > self.slots.len) {
                const grown = try gpa.realloc(self.slots, want);
                @memset(grown[self.slots.len..], null);
                self.slots = grown;
            }
            self.slots[index] = value;
        }

        pub fn get(self: Self, index: topology.NodeIndex) ?V {
            if (index >= self.slots.len) return null;
            return self.slots[index];
        }

        pub fn getPtr(self: Self, index: topology.NodeIndex) ?*V {
            if (index >= self.slots.len) return null;
            if (self.slots[index] == null) return null;
            return &self.slots[index].?;
        }

        pub fn contains(self: Self, index: topology.NodeIndex) bool {
            return self.get(index) != null;
        }

        pub fn remove(self: *Self, index: topology.NodeIndex) bool {
            if (index >= self.slots.len) return false;
            if (self.slots[index] == null) return false;
            self.slots[index] = null;
            return true;
        }

        pub const KV = struct { key: topology.NodeIndex, value: V };

        /// Removes and hands back what was there, so a caller that owns the
        /// value can free it in the same step it drops the entry.
        pub fn fetchRemove(self: *Self, index: topology.NodeIndex) ?KV {
            if (index >= self.slots.len) return null;
            const held = self.slots[index] orelse return null;
            self.slots[index] = null;
            return .{ .key = index, .value = held };
        }

        /// Stores and hands back what the index held before, so a caller
        /// replacing an owned value frees the old one rather than leaking it.
        pub fn fetchPut(self: *Self, gpa: std.mem.Allocator, index: topology.NodeIndex, value: V) std.mem.Allocator.Error!?KV {
            const previous = if (index < self.slots.len) self.slots[index] else null;
            try self.put(gpa, index, value);
            if (previous) |held| return .{ .key = index, .value = held };
            return null;
        }

        pub fn count(self: Self) usize {
            var total: usize = 0;
            for (self.slots) |slot| {
                if (slot != null) total += 1;
            }
            return total;
        }

        /// Keeps the storage and clears every value, so the next lens stores
        /// into memory this one already grew.
        pub fn clearRetainingCapacity(self: *Self) void {
            @memset(self.slots, null);
        }

        pub const Entry = struct { key_ptr: *const topology.NodeIndex, value_ptr: *V };

        /// Walks the values that are present, in node order. The key pointer
        /// addresses the iterator's own cursor, which is live for as long as the
        /// entry is, matching how a map entry's key is read and not kept.
        pub const Iterator = struct {
            slots: []?V,
            at: usize = 0,
            key: topology.NodeIndex = 0,

            pub fn next(it: *Iterator) ?Entry {
                while (it.at < it.slots.len) {
                    const index = it.at;
                    it.at += 1;
                    if (it.slots[index] != null) {
                        it.key = @intCast(index);
                        return .{ .key_ptr = &it.key, .value_ptr = &it.slots[index].? };
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .slots = self.slots };
        }

        pub const ValueIterator = struct {
            slots: []?V,
            at: usize = 0,

            pub fn next(it: *ValueIterator) ?*V {
                while (it.at < it.slots.len) {
                    const index = it.at;
                    it.at += 1;
                    if (it.slots[index] != null) return &it.slots[index].?;
                }
                return null;
            }
        };

        pub fn valueIterator(self: *Self) ValueIterator {
            return .{ .slots = self.slots };
        }
    };
}

const t = std.testing;

test "a stored value reads back and a missing one reads null" {
    var map: NodeMap(u32) = .empty;
    defer map.deinit(t.allocator);
    try t.expect(map.get(3) == null);
    try t.expect(!map.contains(3));
    try map.put(t.allocator, 3, 42);
    try t.expectEqual(@as(?u32, 42), map.get(3));
    try t.expect(map.contains(3));
    try t.expect(map.get(2) == null);
    try t.expectEqual(@as(usize, 1), map.count());
}

test "a sparse map iterates only what it holds, in node order" {
    var map: NodeMap(u32) = .empty;
    defer map.deinit(t.allocator);
    try map.put(t.allocator, 5, 50);
    try map.put(t.allocator, 1, 10);
    try map.put(t.allocator, 9, 90);

    var seen_keys: [3]u16 = undefined;
    var seen_values: [3]u32 = undefined;
    var at: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        seen_keys[at] = entry.key_ptr.*;
        seen_values[at] = entry.value_ptr.*;
        at += 1;
    }
    try t.expectEqual(@as(usize, 3), at);
    try t.expectEqualSlices(u16, &.{ 1, 5, 9 }, &seen_keys);
    try t.expectEqualSlices(u32, &.{ 10, 50, 90 }, &seen_values);
}

test "remove and clear leave reads null without dropping the storage" {
    var map: NodeMap(u32) = .empty;
    defer map.deinit(t.allocator);
    try map.put(t.allocator, 2, 20);
    try map.put(t.allocator, 4, 40);
    try t.expect(map.remove(2));
    try t.expect(!map.remove(2));
    try t.expect(map.get(2) == null);
    try t.expectEqual(@as(usize, 1), map.count());

    const capacity_before = map.slots.len;
    map.clearRetainingCapacity();
    try t.expectEqual(@as(usize, 0), map.count());
    try t.expectEqual(capacity_before, map.slots.len);
}

test "the first put grows from an empty map" {
    var map: NodeMap(u32) = .empty;
    defer map.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), map.slots.len);
    // The empty map's slice points at no allocation, so the first grow has to be
    // an allocation rather than a resize of one.
    try map.put(t.allocator, 0, 7);
    try t.expectEqual(@as(?u32, 7), map.get(0));
    try t.expectEqual(@as(usize, 1), map.slots.len);
}

test "a put past the end grows and leaves the gap empty" {
    var map: NodeMap(u32) = .empty;
    defer map.deinit(t.allocator);
    try map.put(t.allocator, 0, 1);
    try map.put(t.allocator, 6, 2);
    try t.expectEqual(@as(usize, 7), map.slots.len);
    try t.expectEqual(@as(?u32, 1), map.get(0));
    try t.expectEqual(@as(?u32, 2), map.get(6));
    for (1..6) |gap| try t.expect(map.get(@intCast(gap)) == null);
    // A read past the end is a miss, never a fault.
    try t.expect(map.get(7) == null);
    try t.expect(map.get(65535) == null);
}

test "a value is edited in place through its pointer" {
    var map: NodeMap(u32) = .empty;
    defer map.deinit(t.allocator);
    try map.put(t.allocator, 7, 1);
    const slot = map.getPtr(7) orelse return error.Missing;
    slot.* = 99;
    try t.expectEqual(@as(?u32, 99), map.get(7));
    try t.expect(map.getPtr(8) == null);
}

test "fetchRemove hands back the value it drops" {
    var map: NodeMap(u32) = .empty;
    defer map.deinit(t.allocator);
    try map.put(t.allocator, 4, 40);
    const taken = map.fetchRemove(4) orelse return error.Missing;
    try t.expectEqual(@as(u16, 4), taken.key);
    try t.expectEqual(@as(u32, 40), taken.value);
    try t.expect(map.get(4) == null);
    // A second take, and one past the end, are misses rather than faults.
    try t.expect(map.fetchRemove(4) == null);
    try t.expect(map.fetchRemove(9000) == null);
}

test "fetchPut hands back the value it replaced and null on a first store" {
    var map: NodeMap(u32) = .empty;
    defer map.deinit(t.allocator);
    try t.expect(try map.fetchPut(t.allocator, 2, 20) == null);
    const replaced = (try map.fetchPut(t.allocator, 2, 21)) orelse return error.Missing;
    try t.expectEqual(@as(u32, 20), replaced.value);
    try t.expectEqual(@as(?u32, 21), map.get(2));
    // A store past the end grows and reports no previous value.
    try t.expect(try map.fetchPut(t.allocator, 11, 1) == null);
    try t.expectEqual(@as(usize, 12), map.slots.len);
}
