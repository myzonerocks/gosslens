//! A session's inputs and outputs as one ordered log, so a run can be replayed
//! bit for bit.
//!
//! This is the determinism claim made checkable. A log records what went in
//! (frames by hash rather than by pixels, world submissions, audio, touches, all
//! stamped) and what came out (events and snapshot digests), and a replay that
//! produces a different output stream is a regression with an exact first
//! divergence rather than a vague "it looks different".
//!
//! Frames go in by hash because a log that carried pixels would be gigabytes and
//! nobody would keep one; the hash is what makes a divergence provable without
//! storing the frame.

const std = @import("std");

pub const magic: [4]u8 = .{ 'G', 'S', 'R', '1' };
pub const version: u16 = 1;

/// What one log entry is. Inputs and outputs share a stream because the ORDER
/// between them is the thing being checked: an event that used to arrive before a
/// frame and now arrives after it is a real difference.
pub const Kind = enum(u16) {
    frame_in = 1,
    audio_in = 2,
    world_in = 3,
    touch_in = 4,
    event_out = 5,
    snapshot_out = 6,
    _,
};

pub const Entry = extern struct {
    kind: u16,
    /// Per-kind discriminator: an event's kind, a frame's pixel format.
    detail: u16,
    sequence: u64,
    timestamp_us: i64,
    /// A frame's pixel hash, an event's packed a and b, a snapshot's digest.
    hash: u64,
    a: u32,
    b: u32,
};

pub const Error = error{ Truncated, Malformed, Diverged };

/// Where two logs first differ, which is what a replay failure needs to say. A
/// bare "not equal" over a thousand entries is not a diagnosis.
pub const Divergence = struct {
    at: usize,
    expected: Entry,
    actual: Entry,
};

pub const header_bytes: usize = 4 + 2 + 2 + 8;

/// Appends entries into a caller's buffer, counting what a full write needed.
pub const Log = struct {
    buf: []u8,
    at: usize = 0,
    needed: usize = header_bytes,
    count: u64 = 0,
    overflowed: bool = false,

    pub fn init(buf: []u8) Log {
        var l: Log = .{ .buf = buf };
        l.write(&magic);
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp, version, .little);
        l.write(&tmp);
        std.mem.writeInt(u16, &tmp, 0, .little);
        l.write(&tmp);
        var count: [8]u8 = undefined;
        std.mem.writeInt(u64, &count, 0, .little);
        l.write(&count);
        l.needed = header_bytes;
        l.at = @min(header_bytes, buf.len);
        return l;
    }

    fn write(l: *Log, bytes: []const u8) void {
        const room = if (l.at < l.buf.len) l.buf.len - l.at else 0;
        const n = @min(room, bytes.len);
        if (n != 0) @memcpy(l.buf[l.at..][0..n], bytes[0..n]);
        if (n < bytes.len) l.overflowed = true;
        l.at += n;
    }

    pub fn append(l: *Log, entry: Entry) void {
        const bytes = std.mem.asBytes(&entry);
        l.write(bytes);
        l.needed += bytes.len;
        l.count += 1;
    }

    /// Stamps the entry count and reports the log's size.
    pub fn finish(l: *Log) Error!usize {
        if (l.buf.len >= header_bytes) {
            std.mem.writeInt(u64, l.buf[8..][0..8], l.count, .little);
        }
        if (l.overflowed) return error.Truncated;
        return l.needed;
    }
};

pub fn entryCount(log: []const u8) Error!u64 {
    if (log.len < header_bytes) return error.Malformed;
    if (!std.mem.eql(u8, log[0..4], &magic)) return error.Malformed;
    return std.mem.readInt(u64, log[8..][0..8], .little);
}

pub fn entryAt(log: []const u8, index: usize) Error!Entry {
    const at = header_bytes + index * @sizeOf(Entry);
    if (at + @sizeOf(Entry) > log.len) return error.Malformed;
    var e: Entry = undefined;
    @memcpy(std.mem.asBytes(&e), log[at..][0..@sizeOf(Entry)]);
    return e;
}

/// Compares two logs and names the first entry that differs. Null when they are
/// identical, which is the only passing answer a replay proof accepts.
pub fn diverges(expected: []const u8, actual: []const u8) Error!?Divergence {
    const want = try entryCount(expected);
    const got = try entryCount(actual);
    const shared = @min(want, got);
    for (0..@intCast(shared)) |i| {
        const a = try entryAt(expected, i);
        const b = try entryAt(actual, i);
        if (!std.meta.eql(a, b)) return .{ .at = i, .expected = a, .actual = b };
    }
    if (want != got) {
        // One log ran longer. The first missing or extra entry is the divergence,
        // reported against a zeroed twin so a caller still gets a place to look.
        const at: usize = @intCast(shared);
        const zero = std.mem.zeroes(Entry);
        return .{
            .at = at,
            .expected = if (want > shared) try entryAt(expected, at) else zero,
            .actual = if (got > shared) try entryAt(actual, at) else zero,
        };
    }
    return null;
}

/// A frame's identity without its pixels: the hash a log records instead of the
/// megabytes it would otherwise carry.
pub fn hashFrame(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x60551e45, bytes);
}

const t = std.testing;

fn buildLog(buf: []u8, drift: bool) Error!usize {
    var l = Log.init(buf);
    l.append(.{ .kind = @intFromEnum(Kind.frame_in), .detail = 0, .sequence = 1, .timestamp_us = 33_333, .hash = 0xAA, .a = 1920, .b = 1080 });
    l.append(.{ .kind = @intFromEnum(Kind.event_out), .detail = 3, .sequence = 2, .timestamp_us = 33_333, .hash = 0, .a = 0, .b = 1 });
    l.append(.{
        .kind = @intFromEnum(Kind.frame_in),
        .detail = 0,
        .sequence = 3,
        .timestamp_us = 66_666,
        .hash = if (drift) 0xBB else 0xCC,
        .a = 1920,
        .b = 1080,
    });
    return l.finish();
}

test "an identical replay diverges nowhere" {
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    const na = try buildLog(&a, false);
    const nb = try buildLog(&b, false);
    try t.expect(try diverges(a[0..na], b[0..nb]) == null);
    try t.expectEqual(@as(u64, 3), try entryCount(a[0..na]));
}

test "a divergence names the first entry that differs, not merely that one does" {
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    const na = try buildLog(&a, false);
    const nb = try buildLog(&b, true);
    const d = (try diverges(a[0..na], b[0..nb])) orelse return error.NoDivergence;
    try t.expectEqual(@as(usize, 2), d.at);
    try t.expectEqual(@as(u64, 0xCC), d.expected.hash);
    try t.expectEqual(@as(u64, 0xBB), d.actual.hash);
}

test "a log that ran longer diverges at the first extra entry" {
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    const na = try buildLog(&a, false);
    var lb = Log.init(&b);
    lb.append(try entryAt(a[0..na], 0));
    const nb = try lb.finish();
    const d = (try diverges(a[0..na], b[0..nb])) orelse return error.NoDivergence;
    try t.expectEqual(@as(usize, 1), d.at);
    try t.expectEqual(@as(u16, @intFromEnum(Kind.event_out)), d.expected.kind);
    try t.expectEqual(@as(u16, 0), d.actual.kind);
}

test "the order between an input and an output is part of what is checked" {
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    var la = Log.init(&a);
    la.append(.{ .kind = @intFromEnum(Kind.frame_in), .detail = 0, .sequence = 1, .timestamp_us = 0, .hash = 1, .a = 0, .b = 0 });
    la.append(.{ .kind = @intFromEnum(Kind.event_out), .detail = 0, .sequence = 2, .timestamp_us = 0, .hash = 0, .a = 0, .b = 0 });
    const na = try la.finish();
    // The same two entries, swapped: an event that used to arrive before a frame
    // and now arrives after it is a real difference, not a reordering to forgive.
    var lb = Log.init(&b);
    lb.append(.{ .kind = @intFromEnum(Kind.event_out), .detail = 0, .sequence = 2, .timestamp_us = 0, .hash = 0, .a = 0, .b = 0 });
    lb.append(.{ .kind = @intFromEnum(Kind.frame_in), .detail = 0, .sequence = 1, .timestamp_us = 0, .hash = 1, .a = 0, .b = 0 });
    const nb = try lb.finish();
    const d = (try diverges(a[0..na], b[0..nb])) orelse return error.NoDivergence;
    try t.expectEqual(@as(usize, 0), d.at);
}

test "a frame hashes to itself and not to a neighbour" {
    const one = [_]u8{ 1, 2, 3, 4 };
    const same = [_]u8{ 1, 2, 3, 4 };
    const other = [_]u8{ 1, 2, 3, 5 };
    try t.expectEqual(hashFrame(&one), hashFrame(&same));
    try t.expect(hashFrame(&one) != hashFrame(&other));
}

test "a truncated or wrongly-magicked log is malformed rather than half-read" {
    var a: [512]u8 = undefined;
    const na = try buildLog(&a, false);
    try t.expectError(error.Malformed, entryCount(a[0 .. header_bytes - 1]));
    var wrong = a;
    wrong[1] = 'X';
    try t.expectError(error.Malformed, entryCount(wrong[0..na]));
    // A count claiming more entries than the bytes hold.
    var lying = a;
    std.mem.writeInt(u64, lying[8..][0..8], 99, .little);
    try t.expectError(error.Malformed, diverges(lying[0..na], a[0..na]));
}

test "a short buffer reports the size it needed" {
    var big: [512]u8 = undefined;
    const full = try buildLog(&big, false);
    var small: [20]u8 = undefined;
    var l = Log.init(&small);
    l.append(.{ .kind = 1, .detail = 0, .sequence = 1, .timestamp_us = 0, .hash = 0, .a = 0, .b = 0 });
    l.append(.{ .kind = 1, .detail = 0, .sequence = 2, .timestamp_us = 0, .hash = 0, .a = 0, .b = 0 });
    l.append(.{ .kind = 1, .detail = 0, .sequence = 3, .timestamp_us = 0, .hash = 0, .a = 0, .b = 0 });
    try t.expectError(error.Truncated, l.finish());
    try t.expectEqual(full, l.needed);
}
