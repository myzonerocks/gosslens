//! The determinism gate. The same input stream must produce the same records,
//! bit for bit, on the same target, and this names the first place two runs
//! parted rather than reporting that they differ.

const std = @import("std");

pub const Error = error{ OutOfMemory, Truncated };

/// One run's output, as the bytes that actually crossed. Comparing the records
/// rather than the session is what makes this a gate: a field the writer forgot
/// shows up as a difference, and a field nobody wrote cannot hide behind a
/// getter that recomputes it.
pub const Run = struct {
    snapshots: std.ArrayListUnmanaged([]const u8) = .empty,
    events: std.ArrayListUnmanaged([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Run {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(run: *Run) void {
        run.arena.deinit();
        run.* = undefined;
    }

    /// Copies a record in, so the caller's buffer is free to be reused for the
    /// next frame. A gate that borrowed the buffer would compare a frame against
    /// itself.
    pub fn addSnapshot(run: *Run, record: []const u8) Error!void {
        const a = run.arena.allocator();
        const owned = a.dupe(u8, record) catch return error.OutOfMemory;
        run.snapshots.append(a, owned) catch return error.OutOfMemory;
    }

    pub fn addEvent(run: *Run, record: []const u8) Error!void {
        const a = run.arena.allocator();
        const owned = a.dupe(u8, record) catch return error.OutOfMemory;
        run.events.append(a, owned) catch return error.OutOfMemory;
    }
};

/// Where two runs parted. The frame and the byte, so a failure points at a
/// field rather than at a file.
pub const Divergence = struct {
    stream: enum { snapshot, event, length },
    frame: usize,
    byte: usize,
    expected: u8,
    actual: u8,
};

/// Compares two runs and names the first difference. Length is reported as its
/// own kind: a run that stopped early is a different failure from a run that
/// disagreed, and conflating them sends the reader to the wrong place.
pub fn compare(a: *const Run, b: *const Run) ?Divergence {
    if (a.snapshots.items.len != b.snapshots.items.len) {
        return .{
            .stream = .length,
            .frame = @min(a.snapshots.items.len, b.snapshots.items.len),
            .byte = 0,
            .expected = @truncate(a.snapshots.items.len),
            .actual = @truncate(b.snapshots.items.len),
        };
    }
    for (a.snapshots.items, b.snapshots.items, 0..) |want, got, frame| {
        if (firstDifference(want, got)) |at| {
            return .{
                .stream = .snapshot,
                .frame = frame,
                .byte = at,
                .expected = if (at < want.len) want[at] else 0,
                .actual = if (at < got.len) got[at] else 0,
            };
        }
    }
    if (a.events.items.len != b.events.items.len) {
        return .{
            .stream = .length,
            .frame = @min(a.events.items.len, b.events.items.len),
            .byte = 0,
            .expected = @truncate(a.events.items.len),
            .actual = @truncate(b.events.items.len),
        };
    }
    for (a.events.items, b.events.items, 0..) |want, got, frame| {
        if (firstDifference(want, got)) |at| {
            return .{ .stream = .event, .frame = frame, .byte = at, .expected = if (at < want.len) want[at] else 0, .actual = if (at < got.len) got[at] else 0 };
        }
    }
    return null;
}

fn firstDifference(a: []const u8, b: []const u8) ?usize {
    const shared = @min(a.len, b.len);
    for (0..shared) |i| {
        if (a[i] != b[i]) return i;
    }
    if (a.len != b.len) return shared;
    return null;
}

/// A digest of a whole run, for the cross-target compare where shipping both
/// runs is not practical. It is not a substitute for the byte compare: it says
/// two runs differ and cannot say where.
pub fn digest(run: *const Run) u64 {
    var h = std.hash.Wyhash.init(0xD37E12);
    for (run.snapshots.items) |r| h.update(r);
    for (run.events.items) |r| h.update(r);
    return h.final();
}

const testing = std.testing;

test "two identical runs diverge nowhere and digest the same" {
    var a = Run.init(testing.allocator);
    defer a.deinit();
    var b = Run.init(testing.allocator);
    defer b.deinit();
    for (0..4) |i| {
        var record = [_]u8{ 1, 2, 3, @intCast(i) };
        try a.addSnapshot(&record);
        try b.addSnapshot(&record);
    }
    try a.addEvent("face");
    try b.addEvent("face");
    try testing.expect(compare(&a, &b) == null);
    try testing.expectEqual(digest(&a), digest(&b));
}

test "a divergence names the frame and the byte, and a short run says so" {
    var a = Run.init(testing.allocator);
    defer a.deinit();
    var b = Run.init(testing.allocator);
    defer b.deinit();
    try a.addSnapshot(&[_]u8{ 9, 9, 9 });
    try b.addSnapshot(&[_]u8{ 9, 9, 9 });
    try a.addSnapshot(&[_]u8{ 1, 2, 3 });
    try b.addSnapshot(&[_]u8{ 1, 7, 3 });

    const d = compare(&a, &b).?;
    try testing.expectEqual(@as(usize, 1), d.frame);
    try testing.expectEqual(@as(usize, 1), d.byte);
    try testing.expectEqual(@as(u8, 2), d.expected);
    try testing.expectEqual(@as(u8, 7), d.actual);
    try testing.expect(digest(&a) != digest(&b));

    // A run that stopped early is its own kind of failure, not a disagreement.
    var short = Run.init(testing.allocator);
    defer short.deinit();
    try short.addSnapshot(&[_]u8{ 9, 9, 9 });
    const length = compare(&a, &short).?;
    try testing.expectEqual(@as(usize, 1), length.frame);
    try testing.expect(length.stream == .length);
}

test "the events are compared too, after the snapshots agree" {
    var a = Run.init(testing.allocator);
    defer a.deinit();
    var b = Run.init(testing.allocator);
    defer b.deinit();
    try a.addSnapshot(&[_]u8{1});
    try b.addSnapshot(&[_]u8{1});
    try a.addEvent("hand_present");
    try b.addEvent("hand_absent");
    const d = compare(&a, &b).?;
    try testing.expect(d.stream == .event);
    try testing.expectEqual(@as(usize, 0), d.frame);
    // "hand_" is shared; the first byte after it is where they part.
    try testing.expectEqual(@as(usize, 5), d.byte);
}
