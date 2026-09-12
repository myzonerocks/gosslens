//! The snapshot as JSON, for the agent gateways that speak it.
//!
//! Written by READING the binary record rather than from the session, so the two
//! forms cannot diverge: there is one producer of the facts and this is a
//! projection of it. A second writer walking the session again is how two
//! representations of one thing drift apart, and nothing would catch it.
//!
//! An unknown section becomes an object with its tag and byte length rather than
//! being dropped, so a newer engine's record stays readable and honestly says what
//! it is carrying that this build cannot name.

const std = @import("std");
const snapshot = @import("snapshot.zig");

pub const Error = snapshot.Error;

/// Writes the record as compact JSON into the caller's buffer, reporting what a
/// full write needed. Same contract as the binary writer: nothing allocates.
pub fn write(record: []const u8, out: []u8) Error!usize {
    var w: Out = .{ .buf = out };
    var reader = try snapshot.Reader.init(record);
    const head = reader.head();

    w.raw("{\"schema\":");
    w.num(head.schema);
    w.raw(",\"snapshot_us\":");
    w.inum(head.snapshot_us);
    w.raw(",\"sections\":{");

    var first = true;
    while (try reader.next()) |section| {
        if (!first) w.raw(",");
        first = false;
        writeSection(&w, section);
    }
    w.raw("}}");
    if (w.overflowed) return error.Truncated;
    return w.needed;
}

/// How many bytes the JSON form takes, so a caller sizes once.
pub fn size(record: []const u8) Error!usize {
    var scratch: [0]u8 = undefined;
    return write(record, &scratch) catch |err| switch (err) {
        error.Truncated => blk: {
            var w: Out = .{ .buf = &scratch };
            var reader = try snapshot.Reader.init(record);
            const head = reader.head();
            w.raw("{\"schema\":");
            w.num(head.schema);
            w.raw(",\"snapshot_us\":");
            w.inum(head.snapshot_us);
            w.raw(",\"sections\":{");
            var first = true;
            while (try reader.next()) |section| {
                if (!first) w.raw(",");
                first = false;
                writeSection(&w, section);
            }
            w.raw("}}");
            break :blk w.needed;
        },
        else => err,
    };
}

fn writeSection(w: *Out, section: snapshot.Section) void {
    w.raw("\"");
    w.raw(tagName(section.tag));
    w.raw("\":{\"version\":");
    w.num(section.version);
    switch (section.tag) {
        .frame => {
            w.field("width", readU32(section.payload, 0));
            w.field("height", readU32(section.payload, 4));
            w.field("pixel_format", readU32(section.payload, 8));
            w.field("color_standard", readU32(section.payload, 12));
            w.field("color_range", readU32(section.payload, 16));
            w.raw(",\"timestamp_us\":");
            w.inum(readI64(section.payload, 24));
            w.raw(",\"frames_submitted\":");
            w.unum(readU64(section.payload, 32));
        },
        .faces, .bodies, .hands, .text => {
            w.field("count", readU32(section.payload, 0));
        },
        .audio => {
            w.raw(",\"level\":");
            w.fnum(readF32(section.payload, 0));
            w.field("beat", readU32(section.payload, 4));
            w.field("engine_fed", readU32(section.payload, 8));
        },
        .engine => {
            w.field("degrade_level", readU32(section.payload, 0));
            w.field("degrade_transitions", readU32(section.payload, 4));
            w.raw(",\"frames_rendered\":");
            w.unum(readU64(section.payload, 8));
            w.field("script_faults", readU32(section.payload, 16));
        },
        else => {
            // A section this build cannot name is reported as itself rather than
            // dropped, so a newer engine's record stays readable and says what it
            // is carrying.
            w.raw(",\"tag\":");
            w.num(@intFromEnum(section.tag));
            w.raw(",\"bytes\":");
            w.unum(section.payload.len);
        },
    }
    w.raw("}");
}

fn tagName(tag: snapshot.Tag) []const u8 {
    return switch (tag) {
        .frame => "frame",
        .faces => "faces",
        .hands => "hands",
        .bodies => "bodies",
        .segmentation => "segmentation",
        .world => "world",
        .depth => "depth",
        .scene => "scene",
        .text => "text",
        .audio => "audio",
        .lens => "lens",
        .engine => "engine",
        _ => "unknown",
    };
}

fn readU32(p: []const u8, at: usize) u32 {
    if (at + 4 > p.len) return 0;
    return std.mem.readInt(u32, p[at..][0..4], .little);
}

fn readU64(p: []const u8, at: usize) u64 {
    if (at + 8 > p.len) return 0;
    return std.mem.readInt(u64, p[at..][0..8], .little);
}

fn readI64(p: []const u8, at: usize) i64 {
    if (at + 8 > p.len) return 0;
    return std.mem.readInt(i64, p[at..][0..8], .little);
}

fn readF32(p: []const u8, at: usize) f32 {
    return @bitCast(readU32(p, at));
}

/// The same count-even-when-short discipline the binary writer uses.
const Out = struct {
    buf: []u8,
    at: usize = 0,
    needed: usize = 0,
    overflowed: bool = false,

    fn raw(o: *Out, s: []const u8) void {
        const room = if (o.at < o.buf.len) o.buf.len - o.at else 0;
        const n = @min(room, s.len);
        if (n != 0) @memcpy(o.buf[o.at..][0..n], s[0..n]);
        if (n < s.len) o.overflowed = true;
        o.at += n;
        o.needed += s.len;
    }

    fn field(o: *Out, name: []const u8, v: u32) void {
        o.raw(",\"");
        o.raw(name);
        o.raw("\":");
        o.num(v);
    }

    fn num(o: *Out, v: anytype) void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "0";
        o.raw(s);
    }

    fn unum(o: *Out, v: anytype) void {
        o.num(v);
    }

    fn inum(o: *Out, v: i64) void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "0";
        o.raw(s);
    }

    /// Three decimals: an agent gateway reads a level, not a bit pattern, and a
    /// full float print makes every snapshot bigger for no reader's benefit.
    fn fnum(o: *Out, v: f32) void {
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d:.3}", .{v}) catch "0";
        o.raw(s);
    }
};

const t = std.testing;

fn sampleRecord(buf: []u8) ![]u8 {
    var w = snapshot.Writer.init(buf, 7_000_000);
    w.beginSection(.frame, 1);
    w.u32v(1920);
    w.u32v(1080);
    w.u32v(0);
    w.u32v(1);
    w.u32v(1);
    w.u32v(0);
    w.i64v(33_333);
    w.u64v(12);
    w.endSection();
    w.beginSection(.audio, 1);
    w.f32v(0.25);
    w.u32v(1);
    w.u32v(1);
    w.endSection();
    const n = try w.finish();
    return buf[0..n];
}

test "the json form carries the same facts as the record it reads" {
    var raw: [256]u8 = undefined;
    const record = try sampleRecord(&raw);
    var json: [512]u8 = undefined;
    const n = try write(record, &json);
    const text = json[0..n];
    try t.expect(std.mem.indexOf(u8, text, "\"schema\":1") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"snapshot_us\":7000000") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"width\":1920") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"height\":1080") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"frames_submitted\":12") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"level\":0.250") != null);
}

test "a section this build cannot name is reported, never dropped" {
    var raw: [256]u8 = undefined;
    var w = snapshot.Writer.init(&raw, 0);
    w.beginSection(@enumFromInt(4242), 9);
    w.bytes("from a newer engine");
    w.endSection();
    const n = try w.finish();
    var json: [512]u8 = undefined;
    const m = try write(raw[0..n], &json);
    const text = json[0..m];
    try t.expect(std.mem.indexOf(u8, text, "\"unknown\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"tag\":4242") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"bytes\":19") != null);
}

test "a short buffer reports the size it needed" {
    var raw: [256]u8 = undefined;
    const record = try sampleRecord(&raw);
    var big: [512]u8 = undefined;
    const full = try write(record, &big);
    var small: [8]u8 = undefined;
    try t.expectError(error.Truncated, write(record, &small));
    try t.expectEqual(full, try size(record));
}

test "an empty record is still valid json" {
    var raw: [64]u8 = undefined;
    var w = snapshot.Writer.init(&raw, 5);
    const n = try w.finish();
    var json: [128]u8 = undefined;
    const m = try write(raw[0..n], &json);
    try t.expectEqualStrings("{\"schema\":1,\"snapshot_us\":5,\"sections\":{}}", json[0..m]);
}

test "a malformed record is refused rather than half-projected" {
    var bad = [_]u8{ 'X', 'X', 'X', 'X', 0, 0, 0, 0 };
    var json: [64]u8 = undefined;
    try t.expectError(error.Malformed, write(&bad, &json));
}
