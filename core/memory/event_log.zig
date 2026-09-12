//! The durable event log. "What happened in the last ten minutes" should be
//! answerable without replaying frames, and it should not be answerable by a
//! log that grew without bound: retention is enforced in the engine rather than
//! left to whoever remembers to call a purge.

const std = @import("std");

pub const Error = error{ OutOfMemory, Corrupt };

/// One thing that happened. The payload is a slice of the log's own arena, so
/// an entry outlives the frame that produced it without borrowing from it.
pub const Record = struct {
    kind: u32,
    timestamp_us: i64,
    /// Monotonic within one log, so two records at the same microsecond still
    /// have an order and a cursor can resume exactly.
    sequence: u64,
    payload: []const u8,
};

pub const Retention = struct {
    /// Nothing older than this survives a write. Zero means age does not retire
    /// a record.
    max_age_us: i64 = 0,
    max_records: usize = 4096,
    max_payload_bytes: usize = 256 * 1024,
};

/// An append-only ring with a payload arena behind it. Bounded three ways, and
/// each bound retires the oldest record rather than refusing the newest: a log
/// that stops recording when it fills is a log that misses exactly the moment
/// something went wrong.
pub const Log = struct {
    gpa: std.mem.Allocator,
    retention: Retention,

    records: std.ArrayListUnmanaged(Record) = .empty,
    arena: std.ArrayListUnmanaged(u8) = .empty,
    /// Where the live payload bytes begin, so retiring a record reclaims its
    /// bytes without moving what is still live.
    arena_base: usize = 0,
    next_sequence: u64 = 1,
    retired: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, retention: Retention) Log {
        return .{ .gpa = gpa, .retention = retention };
    }

    pub fn deinit(log: *Log) void {
        log.records.deinit(log.gpa);
        log.arena.deinit(log.gpa);
        log.* = undefined;
    }

    pub fn count(log: *const Log) usize {
        return log.records.items.len;
    }

    /// Records one event and applies retention. Answers the sequence number it
    /// took, so a caller can cite the exact record later.
    pub fn append(log: *Log, kind: u32, timestamp_us: i64, payload: []const u8) Error!u64 {
        if (payload.len > log.retention.max_payload_bytes) return error.OutOfMemory;
        const start = log.arena.items.len;
        try log.arena.appendSlice(log.gpa, payload);
        const sequence = log.next_sequence;
        log.next_sequence += 1;
        try log.records.append(log.gpa, .{
            .kind = kind,
            .timestamp_us = timestamp_us,
            .sequence = sequence,
            .payload = log.arena.items[start..][0..payload.len],
        });
        log.enforce(timestamp_us);
        return sequence;
    }

    /// Retires whatever the retention policy no longer covers. Called on every
    /// write, so the bound is a property of the log rather than of the caller's
    /// diligence.
    fn enforce(log: *Log, now_us: i64) void {
        var drop: usize = 0;
        while (drop < log.records.items.len) {
            const r = log.records.items[drop];
            const too_old = log.retention.max_age_us > 0 and now_us - r.timestamp_us > log.retention.max_age_us;
            const too_many = log.records.items.len - drop > log.retention.max_records;
            if (!too_old and !too_many) break;
            drop += 1;
        }
        if (drop == 0) {
            log.rebase();
            return;
        }
        log.retired += drop;
        std.mem.copyForwards(Record, log.records.items[0 .. log.records.items.len - drop], log.records.items[drop..]);
        log.records.shrinkRetainingCapacity(log.records.items.len - drop);
        log.rebase();
    }

    /// Reclaims the arena bytes no live record points at, then repoints the
    /// survivors. The payloads move, so this is the only place that may run.
    fn rebase(log: *Log) void {
        if (log.records.items.len == 0) {
            log.arena.clearRetainingCapacity();
            return;
        }
        const first = log.records.items[0].payload;
        const offset = @intFromPtr(first.ptr) - @intFromPtr(log.arena.items.ptr);
        if (offset == 0 and log.arena.items.len <= log.retention.max_payload_bytes * 4) return;
        std.mem.copyForwards(u8, log.arena.items[0 .. log.arena.items.len - offset], log.arena.items[offset..]);
        log.arena.shrinkRetainingCapacity(log.arena.items.len - offset);
        for (log.records.items) |*r| {
            const at = @intFromPtr(r.payload.ptr) - @intFromPtr(log.arena.items.ptr) - offset;
            r.payload = log.arena.items[at..][0..r.payload.len];
        }
    }

    /// The records inside a time window, optionally of one kind. Writes into the
    /// caller's slice and answers how many landed, so a query allocates nothing.
    pub fn query(log: *const Log, from_us: i64, to_us: i64, kind: ?u32, out: []Record) usize {
        var found: usize = 0;
        for (log.records.items) |r| {
            if (found >= out.len) break;
            if (r.timestamp_us < from_us or r.timestamp_us > to_us) continue;
            if (kind) |k| {
                if (r.kind != k) continue;
            }
            out[found] = r;
            found += 1;
        }
        return found;
    }

    /// Everything after a sequence number, which is how a consumer resumes
    /// without rereading or missing what arrived while it was away.
    pub fn since(log: *const Log, sequence: u64, out: []Record) usize {
        var found: usize = 0;
        for (log.records.items) |r| {
            if (found >= out.len) break;
            if (r.sequence <= sequence) continue;
            out[found] = r;
            found += 1;
        }
        return found;
    }

    /// Drops everything, on the host's word rather than on a bound. The
    /// sequence does not restart: a cursor held across a purge must not silently
    /// match a new record.
    pub fn purge(log: *Log) void {
        log.retired += log.records.items.len;
        log.records.clearRetainingCapacity();
        log.arena.clearRetainingCapacity();
    }
};

const testing = std.testing;

test "the log keeps a window, answers by kind, and resumes from a cursor" {
    var log = Log.init(testing.allocator, .{ .max_records = 16 });
    defer log.deinit();

    _ = try log.append(1, 1_000_000, "first");
    const second = try log.append(2, 2_000_000, "second");
    _ = try log.append(1, 3_000_000, "third");
    try testing.expectEqual(@as(usize, 3), log.count());

    var out: [8]Record = undefined;
    try testing.expectEqual(@as(usize, 2), log.query(2_000_000, 4_000_000, null, &out));
    try testing.expectEqualStrings("second", out[0].payload);

    try testing.expectEqual(@as(usize, 2), log.query(0, 9_000_000, 1, &out));
    try testing.expectEqualStrings("third", out[1].payload);

    // A consumer resumes exactly where it left off.
    try testing.expectEqual(@as(usize, 1), log.since(second, &out));
    try testing.expectEqualStrings("third", out[0].payload);
}

test "retention retires the oldest rather than refusing the newest" {
    var log = Log.init(testing.allocator, .{ .max_records = 3 });
    defer log.deinit();
    for (0..6) |i| _ = try log.append(0, @intCast((i + 1) * 1000), "x");
    try testing.expectEqual(@as(usize, 3), log.count());
    try testing.expectEqual(@as(u64, 3), log.retired);
    // The survivors are the newest three, and their payloads still read.
    var out: [8]Record = undefined;
    const n = log.since(0, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u64, 4), out[0].sequence);
    try testing.expectEqualStrings("x", out[0].payload);
}

test "an age policy retires what fell outside the window, payloads intact" {
    var log = Log.init(testing.allocator, .{ .max_age_us = 10_000, .max_records = 100 });
    defer log.deinit();
    _ = try log.append(0, 1_000, "old");
    _ = try log.append(0, 5_000, "middle");
    try testing.expectEqual(@as(usize, 2), log.count());

    // Far enough past the first to retire it and near enough to keep the
    // second: at 12ms the 1ms record is 11ms old and the 5ms record is 7ms.
    _ = try log.append(0, 12_000, "new");
    try testing.expectEqual(@as(usize, 2), log.count());
    var out: [4]Record = undefined;
    const n = log.since(0, &out);
    try testing.expectEqual(@as(usize, 2), n);
    // The surviving payloads must still be their own, which is what the arena
    // rebase is for: a stale pointer here reads another record's bytes.
    try testing.expectEqualStrings("middle", out[0].payload);
    try testing.expectEqualStrings("new", out[1].payload);

    log.purge();
    try testing.expectEqual(@as(usize, 0), log.count());
    // A cursor from before the purge must not match a record written after it.
    const after = try log.append(0, 20_000, "later");
    try testing.expect(after > 3);
}
