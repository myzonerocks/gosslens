//! The demux contract: what a container holds, how a packet is addressed, and
//! what a seek is allowed to do. A seek refuses rather than clamps, because a
//! clamped seek returns the wrong frame and says nothing.

const std = @import("std");
const types = @import("types.zig");
const packet = @import("packet.zig");
const container = @import("container.zig");

pub const Error = error{
    InvalidState,
    /// The bytes are not the container they claim to be, or a required box or
    /// element is missing. Failing closed here is the point: a half-parsed
    /// container produces a file that plays for a second and then does not.
    Malformed,
    /// A container or codec this build does not read.
    Unsupported,
    /// A seek target outside the stream.
    OutOfRange,
    Backend,
    OutOfMemory,
};

/// Where a demuxer is. Tracks are known only after the header is parsed, and a
/// packet only comes out while reading: asking out of order is refused by name
/// rather than answering with an empty track list.
pub const State = enum(u32) {
    /// Opened, nothing parsed.
    opened = 0,
    /// Header parsed, tracks known, packets available.
    parsed = 1,
    /// Every packet of every track has come out.
    ended = 2,
    errored = 3,
};

/// How a seek lands. A container's index is keyframe-granular, so an exact seek is
/// a keyframe seek plus a decode forward, and saying which one a caller asked for
/// is the difference between scrubbing that is fast and scrubbing that is right.
pub const SeekMode = enum(u32) {
    /// The nearest keyframe at or before the target. Fast, approximate.
    keyframe_before = 0,
    /// The nearest keyframe at or after the target.
    keyframe_after = 1,
    /// The exact frame: a keyframe_before seek, then decode forward to it.
    exact = 2,
};

/// The demuxer's own rules, free of any backend, so every backend obeys the same
/// ones and they are testable without a file.
pub const Demuxer = struct {
    state: State = .opened,
    track_count: u32 = 0,
    /// The read position in microseconds, which is what a host scrubs.
    position_us: i64 = 0,
    /// The stream's duration, zero when the container does not declare one.
    duration_us: i64 = 0,
    /// Seeks performed, so a proof can tell a real seek from a sequential decode
    /// that happened to land on the right frame.
    seeks: u64 = 0,

    pub fn parsed(d: *Demuxer, tracks: u32, duration_us: i64) Error!void {
        if (d.state != .opened) return error.InvalidState;
        if (tracks == 0) return error.Malformed;
        if (duration_us < 0) return error.Malformed;
        d.track_count = tracks;
        d.duration_us = duration_us;
        d.state = .parsed;
    }

    /// One packet out. The position follows the packet's presentation time, so a
    /// host reading sequentially and a host that seeked read the same number.
    pub fn read(d: *Demuxer, p: packet.Packet) Error!void {
        if (d.state != .parsed) return error.InvalidState;
        if (!p.valid()) return error.Malformed;
        if (p.track >= d.track_count) return error.Malformed;
        d.position_us = p.ptsMicros();
    }

    /// No more packets. Not an error: a stream ends.
    pub fn end(d: *Demuxer) Error!void {
        switch (d.state) {
            .parsed => d.state = .ended,
            .ended => {},
            .opened, .errored => return error.InvalidState,
        }
    }

    /// Moves the read position. A seek past the declared duration is out of range
    /// rather than clamped, because a clamped seek silently returns the wrong
    /// frame and a scrubber cannot tell.
    pub fn seek(d: *Demuxer, target_us: i64, mode: SeekMode) Error!void {
        if (d.state != .parsed and d.state != .ended) return error.InvalidState;
        if (target_us < 0) return error.OutOfRange;
        if (d.duration_us > 0 and target_us > d.duration_us) return error.OutOfRange;
        _ = mode;
        d.position_us = target_us;
        d.seeks += 1;
        // A seek out of an ended stream reopens it: the position is inside the
        // stream again, so packets are available.
        d.state = .parsed;
    }

    pub fn fail(d: *Demuxer) void {
        d.state = .errored;
    }
};

/// A bounded cache of decoded frames, keyed by presentation time, so scrubbing a
/// timeline does not decode the same frames again and does not grow without end.
/// Eviction is least-recently-used because a scrub moves back and forth across one
/// region, which is exactly the access pattern an LRU serves and a ring does not.
pub fn FrameCache(comptime Frame: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            pts_us: i64,
            frame: Frame,
            /// Monotonic use counter; the smallest is evicted.
            used_at: u64,
        };

        entries: []Entry,
        len: usize = 0,
        clock: u64 = 0,
        hits: u64 = 0,
        misses: u64 = 0,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!Self {
            return .{ .entries = try gpa.alloc(Entry, capacity) };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.entries);
            self.* = .{ .entries = &.{} };
        }

        pub fn get(self: *Self, pts_us: i64) ?*Frame {
            for (self.entries[0..self.len]) |*e| {
                if (e.pts_us != pts_us) continue;
                self.clock += 1;
                e.used_at = self.clock;
                self.hits += 1;
                return &e.frame;
            }
            self.misses += 1;
            return null;
        }

        /// Stores a frame, evicting the least recently used when full. Returns the
        /// evicted frame so the caller frees whatever the frame owns; a cache that
        /// dropped it silently would leak every decoded frame past capacity.
        pub fn put(self: *Self, pts_us: i64, frame: Frame) ?Frame {
            self.clock += 1;
            for (self.entries[0..self.len]) |*e| {
                if (e.pts_us != pts_us) continue;
                const replaced = e.frame;
                e.frame = frame;
                e.used_at = self.clock;
                return replaced;
            }
            if (self.len < self.entries.len) {
                self.entries[self.len] = .{ .pts_us = pts_us, .frame = frame, .used_at = self.clock };
                self.len += 1;
                return null;
            }
            var oldest: usize = 0;
            for (self.entries[0..self.len], 0..) |e, i| {
                if (e.used_at < self.entries[oldest].used_at) oldest = i;
            }
            const evicted = self.entries[oldest].frame;
            self.entries[oldest] = .{ .pts_us = pts_us, .frame = frame, .used_at = self.clock };
            return evicted;
        }

        /// Drops everything, handing each frame back so the caller frees it. A seek
        /// far away makes the whole cache useless and keeping it wastes the bound.
        pub fn drain(self: *Self, out: []Frame) usize {
            const n = @min(self.len, out.len);
            for (0..n) |i| out[i] = self.entries[i].frame;
            self.len = 0;
            return n;
        }

        pub fn count(self: Self) usize {
            return self.len;
        }
    };
}

const t = std.testing;

fn hdTrack() container.Track {
    return .{
        .kind = .video,
        .index = 0,
        .timebase = .microseconds,
        .video = .{ .width = 1920, .height = 1080, .codec = .h264 },
    };
}

test "tracks are known only after the header is parsed" {
    var d: Demuxer = .{};
    const bytes = [_]u8{ 1, 2 };
    const p: packet.Packet = .{ .payload = &bytes, .timebase = .microseconds, .pts = 0, .dts = 0 };
    try t.expectError(error.InvalidState, d.read(p));
    try d.parsed(1, 5_000_000);
    try t.expectEqual(@as(u32, 1), d.track_count);
    try d.read(p);
}

test "a container with no track is malformed, not an empty stream" {
    var d: Demuxer = .{};
    try t.expectError(error.Malformed, d.parsed(0, 1_000));
    try t.expectEqual(State.opened, d.state);
}

test "the position follows the packet's presentation time" {
    var d: Demuxer = .{};
    try d.parsed(1, 5_000_000);
    const bytes = [_]u8{1};
    try d.read(.{ .payload = &bytes, .timebase = .{ .num = 1, .den = 90_000 }, .pts = 90_000, .dts = 90_000 });
    try t.expectEqual(@as(i64, 1_000_000), d.position_us);
}

test "a packet on a track the container does not have is malformed" {
    var d: Demuxer = .{};
    try d.parsed(1, 1_000_000);
    const bytes = [_]u8{1};
    try t.expectError(error.Malformed, d.read(.{ .payload = &bytes, .timebase = .microseconds, .pts = 0, .dts = 0, .track = 3 }));
}

test "a seek past the duration is out of range, never clamped" {
    var d: Demuxer = .{};
    try d.parsed(1, 5_000_000);
    try d.seek(2_000_000, .keyframe_before);
    try t.expectEqual(@as(i64, 2_000_000), d.position_us);
    try t.expectEqual(@as(u64, 1), d.seeks);
    // Clamping would return the last frame and a scrubber could not tell.
    try t.expectError(error.OutOfRange, d.seek(6_000_000, .exact));
    try t.expectError(error.OutOfRange, d.seek(-1, .exact));
    try t.expectEqual(@as(i64, 2_000_000), d.position_us);
}

test "a seek out of an ended stream makes packets available again" {
    var d: Demuxer = .{};
    try d.parsed(1, 5_000_000);
    try d.end();
    try t.expectEqual(State.ended, d.state);
    const bytes = [_]u8{1};
    try t.expectError(error.InvalidState, d.read(.{ .payload = &bytes, .timebase = .microseconds, .pts = 0, .dts = 0 }));
    try d.seek(1_000_000, .keyframe_before);
    try t.expectEqual(State.parsed, d.state);
    try d.read(.{ .payload = &bytes, .timebase = .microseconds, .pts = 1_000_000, .dts = 1_000_000 });
}

test "ending twice is not an error, and an errored demuxer refuses both" {
    var d: Demuxer = .{};
    try d.parsed(1, 1_000);
    try d.end();
    try d.end();
    d.fail();
    try t.expectError(error.InvalidState, d.end());
    try t.expectError(error.InvalidState, d.seek(0, .exact));
}

test "a stream with no declared duration allows any forward seek" {
    var d: Demuxer = .{};
    try d.parsed(1, 0);
    try d.seek(999_999_999, .keyframe_before);
    try t.expectEqual(@as(i64, 999_999_999), d.position_us);
}

test "the frame cache hits on a repeated time and misses otherwise" {
    var cache = try FrameCache(u32).init(t.allocator, 3);
    defer cache.deinit(t.allocator);
    try t.expect(cache.get(100) == null);
    try t.expect(cache.put(100, 1) == null);
    const got = cache.get(100) orelse return error.Missing;
    try t.expectEqual(@as(u32, 1), got.*);
    try t.expectEqual(@as(u64, 1), cache.hits);
    // One miss: the read before the store. The read after it hits.
    try t.expectEqual(@as(u64, 1), cache.misses);
}

test "the cache evicts the least recently used and hands the frame back" {
    var cache = try FrameCache(u32).init(t.allocator, 2);
    defer cache.deinit(t.allocator);
    try t.expect(cache.put(1, 10) == null);
    try t.expect(cache.put(2, 20) == null);
    // Touch 1 so 2 is the least recently used.
    _ = cache.get(1);
    const evicted = cache.put(3, 30) orelse return error.NothingEvicted;
    try t.expectEqual(@as(u32, 20), evicted);
    try t.expect(cache.get(2) == null);
    try t.expectEqual(@as(usize, 2), cache.count());
}

test "storing the same time replaces and returns the old frame" {
    var cache = try FrameCache(u32).init(t.allocator, 2);
    defer cache.deinit(t.allocator);
    try t.expect(cache.put(5, 50) == null);
    const replaced = cache.put(5, 51) orelse return error.NothingReplaced;
    try t.expectEqual(@as(u32, 50), replaced);
    try t.expectEqual(@as(usize, 1), cache.count());
}

test "draining hands every frame back so none is leaked" {
    var cache = try FrameCache(u32).init(t.allocator, 3);
    defer cache.deinit(t.allocator);
    _ = cache.put(1, 10);
    _ = cache.put(2, 20);
    var out: [3]u32 = undefined;
    try t.expectEqual(@as(usize, 2), cache.drain(&out));
    try t.expectEqual(@as(usize, 0), cache.count());
    try t.expect(cache.get(1) == null);
}
