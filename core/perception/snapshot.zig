//! One versioned record of everything the engine currently sees.
//!
//! Forward compatibility is structural rather than promised: every section
//! carries its own tag, version and byte length, so a reader that does not know a
//! tag steps over it by length and keeps going. That is what lets Wave 7's text
//! section exist in the format from day one, empty, without the format breaking
//! when it fills.
//!
//! Nothing here allocates. A caller hands in a buffer and is told what it would
//! have needed, so an agent polling every frame allocates nothing.

const std = @import("std");

/// Bumped only when the framing itself changes, never when a section is added:
/// adding a section is what the tag and length are for.
pub const schema_version: u16 = 1;

pub const magic: [4]u8 = .{ 'G', 'S', 'P', '1' };

/// Section identity. Numbers are frozen once shipped; a retired section keeps its
/// number rather than letting a later one reuse it and be misread by an old
/// consumer.
pub const Tag = enum(u16) {
    frame = 1,
    faces = 2,
    hands = 3,
    bodies = 4,
    segmentation = 5,
    world = 6,
    depth = 7,
    scene = 8,
    text = 9,
    audio = 10,
    lens = 11,
    engine = 12,
    _,
};

/// Which sections a caller wants. A snapshot is read every frame by an agent that
/// usually cares about two of them, and writing all twelve to be ignored is the
/// cost this avoids.
pub const Select = packed struct(u32) {
    frame: bool = false,
    faces: bool = false,
    hands: bool = false,
    bodies: bool = false,
    segmentation: bool = false,
    world: bool = false,
    depth: bool = false,
    scene: bool = false,
    text: bool = false,
    audio: bool = false,
    lens: bool = false,
    engine: bool = false,
    _reserved: u20 = 0,

    pub const all: Select = .{
        .frame = true,
        .faces = true,
        .hands = true,
        .bodies = true,
        .segmentation = true,
        .world = true,
        .depth = true,
        .scene = true,
        .text = true,
        .audio = true,
        .lens = true,
        .engine = true,
    };

    pub fn wants(s: Select, tag: Tag) bool {
        return switch (tag) {
            .frame => s.frame,
            .faces => s.faces,
            .hands => s.hands,
            .bodies => s.bodies,
            .segmentation => s.segmentation,
            .world => s.world,
            .depth => s.depth,
            .scene => s.scene,
            .text => s.text,
            .audio => s.audio,
            .lens => s.lens,
            .engine => s.engine,
            _ => false,
        };
    }
};

pub const header_bytes: usize = 4 + 2 + 2 + 4 + 8;
pub const section_header_bytes: usize = 2 + 2 + 4;

pub const Error = error{
    /// The buffer was too small. The writer reports what it would have needed, so
    /// a caller sizes once and never guesses.
    Truncated,
    Malformed,
};

/// Writes a record into a caller's buffer. Counts what it would have written even
/// when the buffer is short, so one failed call tells a caller the exact size.
pub const Writer = struct {
    buf: []u8,
    at: usize = 0,
    /// What a full write would have taken, whether or not it fit.
    needed: usize = 0,
    /// Where the section being written started, so its length can be back-filled.
    section_at: ?usize = null,
    overflowed: bool = false,

    pub fn init(buf: []u8, snapshot_us: i64) Writer {
        var w: Writer = .{ .buf = buf };
        w.bytes(&magic);
        w.u16v(schema_version);
        w.u16v(0);
        w.u32v(0);
        w.i64v(snapshot_us);
        return w;
    }

    pub fn beginSection(w: *Writer, tag: Tag, version: u16) void {
        std.debug.assert(w.section_at == null);
        w.section_at = w.needed;
        w.u16v(@intFromEnum(tag));
        w.u16v(version);
        w.u32v(0);
    }

    pub fn endSection(w: *Writer) void {
        const start = w.section_at orelse return;
        w.section_at = null;
        const payload = w.needed - start - section_header_bytes;
        // Back-fill only when the length field actually landed in the buffer; a
        // truncated write still counts, it just has nowhere to put the number.
        const at = start + 4;
        if (at + 4 <= w.buf.len) std.mem.writeInt(u32, w.buf[at..][0..4], @intCast(payload), .little);
    }

    pub fn u8v(w: *Writer, v: u8) void {
        w.bytes(&[_]u8{v});
    }

    pub fn u16v(w: *Writer, v: u16) void {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp, v, .little);
        w.bytes(&tmp);
    }

    pub fn u32v(w: *Writer, v: u32) void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        w.bytes(&tmp);
    }

    pub fn i64v(w: *Writer, v: i64) void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(i64, &tmp, v, .little);
        w.bytes(&tmp);
    }

    pub fn u64v(w: *Writer, v: u64) void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, v, .little);
        w.bytes(&tmp);
    }

    pub fn f32v(w: *Writer, v: f32) void {
        w.u32v(@bitCast(v));
    }

    /// A length-prefixed string, so a reader needs no terminator scan and a name
    /// with a zero byte in it cannot truncate the record.
    pub fn str(w: *Writer, s: []const u8) void {
        const n: u16 = @intCast(@min(s.len, std.math.maxInt(u16)));
        w.u16v(n);
        w.bytes(s[0..n]);
    }

    pub fn bytes(w: *Writer, b: []const u8) void {
        const room = if (w.at < w.buf.len) w.buf.len - w.at else 0;
        const n = @min(room, b.len);
        if (n != 0) @memcpy(w.buf[w.at..][0..n], b[0..n]);
        if (n < b.len) w.overflowed = true;
        w.at += n;
        w.needed += b.len;
    }

    /// Stamps the total length into the header and reports the record's size.
    /// Truncated when the buffer was short, with `needed` carrying the answer.
    pub fn finish(w: *Writer) Error!usize {
        if (w.buf.len >= header_bytes) {
            std.mem.writeInt(u32, w.buf[8..][0..4], @intCast(w.needed), .little);
        }
        if (w.overflowed) return error.Truncated;
        return w.needed;
    }
};

/// One section as a reader sees it.
pub const Section = struct {
    tag: Tag,
    version: u16,
    payload: []const u8,
};

/// Walks a record's sections. An unknown tag is handed over with its payload so a
/// caller can skip it by length; that is the whole forward-compatibility story.
pub const Reader = struct {
    record: []const u8,
    at: usize,
    pub const Head = struct { schema: u16, total: u32, snapshot_us: i64 };

    pub fn init(record: []const u8) Error!Reader {
        if (record.len < header_bytes) return error.Malformed;
        if (!std.mem.eql(u8, record[0..4], &magic)) return error.Malformed;
        return .{ .record = record, .at = header_bytes };
    }

    pub fn head(r: Reader) Head {
        return .{
            .schema = std.mem.readInt(u16, r.record[4..][0..2], .little),
            .total = std.mem.readInt(u32, r.record[8..][0..4], .little),
            .snapshot_us = std.mem.readInt(i64, r.record[12..][0..8], .little),
        };
    }

    pub fn next(r: *Reader) Error!?Section {
        if (r.at >= r.record.len) return null;
        if (r.at + section_header_bytes > r.record.len) return error.Malformed;
        const tag: Tag = @enumFromInt(std.mem.readInt(u16, r.record[r.at..][0..2], .little));
        const version = std.mem.readInt(u16, r.record[r.at + 2 ..][0..2], .little);
        const len = std.mem.readInt(u32, r.record[r.at + 4 ..][0..4], .little);
        const start = r.at + section_header_bytes;
        const end = start + len;
        if (end > r.record.len) return error.Malformed;
        r.at = end;
        return .{ .tag = tag, .version = version, .payload = r.record[start..end] };
    }

    /// The first section with this tag, or null. A reader that wants two sections
    /// walks once rather than calling this twice.
    pub fn find(record: []const u8, tag: Tag) Error!?Section {
        var r = try Reader.init(record);
        while (try r.next()) |section| {
            if (section.tag == tag) return section;
        }
        return null;
    }
};

const t = std.testing;

fn writeSample(buf: []u8) Error!usize {
    var w = Writer.init(buf, 1_234_567);
    w.beginSection(.frame, 1);
    w.u32v(1920);
    w.u32v(1080);
    w.i64v(99);
    w.endSection();
    w.beginSection(.faces, 1);
    w.u32v(2);
    w.str("left");
    w.f32v(0.5);
    w.endSection();
    return w.finish();
}

test "a record round trips through its own reader" {
    var buf: [256]u8 = undefined;
    const n = try writeSample(&buf);
    var r = try Reader.init(buf[0..n]);
    const h = r.head();
    try t.expectEqual(schema_version, h.schema);
    try t.expectEqual(@as(u32, @intCast(n)), h.total);
    try t.expectEqual(@as(i64, 1_234_567), h.snapshot_us);

    const first = (try r.next()) orelse return error.NoSection;
    try t.expectEqual(Tag.frame, first.tag);
    try t.expectEqual(@as(usize, 16), first.payload.len);
    try t.expectEqual(@as(u32, 1920), std.mem.readInt(u32, first.payload[0..4], .little));

    const second = (try r.next()) orelse return error.NoSection;
    try t.expectEqual(Tag.faces, second.tag);
    try t.expect(try r.next() == null);
}

test "an unknown tag is stepped over by length, not guessed at" {
    var buf: [128]u8 = undefined;
    var w = Writer.init(&buf, 0);
    // A section from a future build this reader has never heard of.
    w.beginSection(@enumFromInt(9999), 3);
    w.bytes("payload a reader cannot parse");
    w.endSection();
    w.beginSection(.audio, 1);
    w.f32v(0.25);
    w.endSection();
    const n = try w.finish();

    // The known section is still found, past the unknown one.
    const audio = (try Reader.find(buf[0..n], .audio)) orelse return error.NotFound;
    try t.expectEqual(@as(usize, 4), audio.payload.len);
    try t.expectEqual(@as(f32, 0.25), @as(f32, @bitCast(std.mem.readInt(u32, audio.payload[0..4], .little))));
}

test "a short buffer reports the size it needed rather than writing garbage" {
    var big: [256]u8 = undefined;
    const full = try writeSample(&big);

    var small: [16]u8 = undefined;
    var w = Writer.init(&small, 1_234_567);
    w.beginSection(.frame, 1);
    w.u32v(1920);
    w.u32v(1080);
    w.i64v(99);
    w.endSection();
    w.beginSection(.faces, 1);
    w.u32v(2);
    w.str("left");
    w.f32v(0.5);
    w.endSection();
    try t.expectError(error.Truncated, w.finish());
    try t.expectEqual(full, w.needed);
}

test "a record with no sections is still a valid record" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf, 42);
    const n = try w.finish();
    try t.expectEqual(header_bytes, n);
    var r = try Reader.init(buf[0..n]);
    try t.expectEqual(@as(i64, 42), r.head().snapshot_us);
    try t.expect(try r.next() == null);
}

test "a truncated or wrongly-magicked record is malformed, never half-read" {
    var buf: [256]u8 = undefined;
    const n = try writeSample(&buf);
    try t.expectError(error.Malformed, Reader.init(buf[0 .. header_bytes - 1]));
    var wrong = buf;
    wrong[0] = 'X';
    try t.expectError(error.Malformed, Reader.init(wrong[0..n]));
    // A section header claiming more payload than the record holds.
    var lying = buf;
    std.mem.writeInt(u32, lying[header_bytes + 4 ..][0..4], 9999, .little);
    var r = try Reader.init(lying[0..n]);
    try t.expectError(error.Malformed, r.next());
}

test "selection answers for every tag it knows and refuses one it does not" {
    const only_faces: Select = .{ .faces = true };
    try t.expect(only_faces.wants(.faces));
    try t.expect(!only_faces.wants(.hands));
    try t.expect(Select.all.wants(.engine));
    try t.expect(!Select.all.wants(@enumFromInt(9999)));
}

test "a string carries its own length, so a zero byte cannot truncate a record" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf, 0);
    w.beginSection(.lens, 1);
    w.str("a\x00b");
    w.endSection();
    const n = try w.finish();
    const lens = (try Reader.find(buf[0..n], .lens)) orelse return error.NotFound;
    try t.expectEqual(@as(u16, 3), std.mem.readInt(u16, lens.payload[0..2], .little));
    try t.expectEqualSlices(u8, "a\x00b", lens.payload[2..5]);
}
