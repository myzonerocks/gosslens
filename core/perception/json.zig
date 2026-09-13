//! The snapshot as JSON, for the agent gateways that speak it. Projected from
//! the binary record rather than written a second time, so the two cannot drift,
//! and read through the declared schema rather than offsets typed here.

const std = @import("std");
const snapshot = @import("snapshot.zig");
const schema = @import("schema.zig");

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
            // Read through the declared schema rather than from numbers typed
            // here, so the writer and this projector cannot drift apart.
            const layout = schema.sectionFor(.frame).?;
            w.field("width", readU32(section.payload, layout.offsetOf("width").?));
            w.field("height", readU32(section.payload, layout.offsetOf("height").?));
            w.field("pixel_format", readU32(section.payload, layout.offsetOf("pixel_format").?));
            w.field("color_standard", readU32(section.payload, layout.offsetOf("color_standard").?));
            w.field("color_range", readU32(section.payload, layout.offsetOf("color_range").?));
            w.raw(",\"timestamp_us\":");
            w.inum(readI64(section.payload, layout.offsetOf("timestamp_us").?));
            w.raw(",\"frames_submitted\":");
            w.unum(readU64(section.payload, layout.offsetOf("frames_submitted").?));
        },
        .faces, .bodies, .hands => {
            w.field("count", readU32(section.payload, 0));
        },
        .text => {
            w.field("count", readU32(section.payload, 0));
            // The strings themselves, because a reading that stays in the
            // binary record is a reading an agent cannot act on.
            w.raw(",\"readings\":[");
            var at: usize = 4;
            var i: usize = 0;
            const count = readU32(section.payload, 0);
            while (i < count) : (i += 1) {
                if (at + text_entry_header > section.payload.len) break;
                const len = readU32(section.payload, at + text_entry_header - 4);
                if (at + text_entry_header + len > section.payload.len) break;
                if (i != 0) w.raw(",");
                w.raw("{\"text\":");
                w.string(section.payload[at + text_entry_header ..][0..len]);
                w.raw(",\"confidence\":");
                w.fnum(readF32(section.payload, at + 32));
                w.field("origin", readU32(section.payload, at + 36));
                w.field("track_id", readU32(section.payload, at + 48));
                w.raw("}");
                at += text_entry_header + len;
            }
            w.raw("]");
        },
        .segmentation, .depth => {
            // Both say the same thing in the same shape: whether a mask this build
            // could produce is live. Read through the declaration so a field added to
            // either is projected rather than silently dropped.
            const layout = schema.sectionFor(section.tag).?;
            w.field("live", readU32(section.payload, layout.offsetOf("live").?));
        },
        .world => {
            const layout = schema.sectionFor(.world).?;
            w.field("tracking_state", readU32(section.payload, layout.offsetOf("tracking_state").?));
            w.field("plane_count", readU32(section.payload, layout.offsetOf("plane_count").?));
            w.field("anchor_count", readU32(section.payload, layout.offsetOf("anchor_count").?));
        },
        .scene => {
            // A count of zero is an answer: the segmenter is not running. The channels
            // follow it, each with the score that says whether that one is live.
            const layout = schema.sectionFor(.scene).?;
            const count = readU32(section.payload, layout.offsetOf("count").?);
            w.field("count", count);
            w.raw(",\"channels\":[");
            const stride = layout.repeatSize();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                if (i != 0) w.raw(",");
                const at = layout.headSize() + i * stride;
                if (at + stride > section.payload.len) break;
                w.raw("{\"channel\":");
                w.num(readU32(section.payload, at + layout.repeatOffsetOf("channel").?));
                w.raw(",\"score\":");
                w.fnum(readF32(section.payload, at + layout.repeatOffsetOf("score").?));
                w.raw("}");
            }
            w.raw("]");
        },
        .detections => {
            // The answer to "what is in front of me", named rather than counted in
            // bytes: each box where it is, what it is, and how sure.
            const layout = schema.sectionFor(.detections).?;
            const count = readU32(section.payload, layout.offsetOf("count").?);
            w.field("count", count);
            w.raw(",\"items\":[");
            const stride = layout.repeatSize();
            const head = layout.headSize();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const at = head + i * stride;
                if (at + stride > section.payload.len) break;
                if (i != 0) w.raw(",");
                w.raw("{\"label\":");
                w.num(readU32(section.payload, at + layout.repeatOffsetOf("label").?));
                w.raw(",\"score\":");
                w.fnum(readF32(section.payload, at + layout.repeatOffsetOf("score").?));
                w.raw(",\"x\":");
                w.fnum(readF32(section.payload, at + layout.repeatOffsetOf("x").?));
                w.raw(",\"y\":");
                w.fnum(readF32(section.payload, at + layout.repeatOffsetOf("y").?));
                w.raw(",\"width\":");
                w.fnum(readF32(section.payload, at + layout.repeatOffsetOf("width").?));
                w.raw(",\"height\":");
                w.fnum(readF32(section.payload, at + layout.repeatOffsetOf("height").?));
                w.raw("}");
            }
            w.raw("]");
        },
        .lens => {
            // The id an agent needs to know which lens is drawing, and every node that
            // did not come up. A lens whose nodes all came up reports an empty list,
            // which is an answer; the byte count this used to report was not.
            const layout = schema.sectionFor(.lens).?;
            w.field("active", readU32(section.payload, layout.offsetOf("active").?));
            const count = readU32(section.payload, layout.offsetOf("count").?);
            const id_len = readU32(section.payload, layout.offsetOf("id_len").?);
            const stride = layout.repeatSize();
            const head = layout.headSize();
            const id_at = head + count * stride;
            w.raw(",\"id\":");
            if (id_at + id_len <= section.payload.len) {
                w.string(section.payload[id_at .. id_at + id_len]);
            } else {
                w.raw("\"\"");
            }
            w.field("count", count);
            w.raw(",\"degraded\":[");
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const at = head + i * stride;
                if (at + stride > section.payload.len) break;
                if (i != 0) w.raw(",");
                w.raw("{\"node_index\":");
                w.num(readU32(section.payload, at + layout.repeatOffsetOf("node_index").?));
                w.raw(",\"state\":");
                w.num(readU32(section.payload, at + layout.repeatOffsetOf("state").?));
                w.raw(",\"reason\":");
                w.num(readU32(section.payload, at + layout.repeatOffsetOf("reason").?));
                w.raw("}");
            }
            w.raw("]");
        },
        .audio => {
            const layout = schema.sectionFor(.audio).?;
            w.raw(",\"level\":");
            w.fnum(readF32(section.payload, layout.offsetOf("level").?));
            w.field("beat", readU32(section.payload, layout.offsetOf("beat").?));
            w.field("engine_fed", readU32(section.payload, layout.offsetOf("engine_fed").?));
        },
        .embedding => {
            // The vector itself stays in the binary record: a JSON projection
            // of 512 floats is the one section nothing gains from reading as
            // text, so the shape is projected and the numbers are not.
            w.field("dim", readU32(section.payload, 0));
            w.field("source", readU32(section.payload, 4));
        },
        .engine => {
            const layout = schema.sectionFor(.engine).?;
            w.field("degrade_level", readU32(section.payload, layout.offsetOf("degrade_level").?));
            w.field("degrade_transitions", readU32(section.payload, layout.offsetOf("degrade_transitions").?));
            w.raw(",\"frames_rendered\":");
            w.unum(readU64(section.payload, layout.offsetOf("frames_rendered").?));
            w.field("script_faults", readU32(section.payload, layout.offsetOf("script_faults").?));
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

/// The fixed part of one reading, taken from the declared schema rather than
/// counted by hand here.
const text_entry_header: usize = schema.sectionFor(.text).?.repeatSize();

fn tagName(tag: snapshot.Tag) []const u8 {
    return switch (tag) {
        .frame => "frame",
        .faces => "faces",
        .hands => "hands",
        .bodies => "bodies",
        .detections => "detections",
        .segmentation => "segmentation",
        .world => "world",
        .depth => "depth",
        .scene => "scene",
        .text => "text",
        .audio => "audio",
        .lens => "lens",
        .engine => "engine",
        .embedding => "embedding",
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

    /// A JSON string with the control characters and the two structural ones
    /// escaped. A sign that reads `"SALE"` is a sign, not a parse error, and a
    /// reading is untrusted input from whatever the camera saw.
    fn string(o: *Out, text: []const u8) void {
        o.raw("\"");
        for (text) |ch| {
            switch (ch) {
                '"' => o.raw("\\\""),
                '\\' => o.raw("\\\\"),
                '\n' => o.raw("\\n"),
                '\r' => o.raw("\\r"),
                '\t' => o.raw("\\t"),
                0...8, 11, 12, 14...31 => {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch return;
                    o.raw(hex);
                },
                else => o.raw(&[_]u8{ch}),
            }
        }
        o.raw("\"");
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

test "the sections this build added project their fields, not their byte counts" {
    var raw: [512]u8 = undefined;
    var w = snapshot.Writer.init(&raw, 7_000_000);
    w.beginSection(.segmentation, 1);
    w.u32v(1);
    w.endSection();
    w.beginSection(.world, 1);
    w.u32v(2);
    w.u32v(5);
    w.u32v(9);
    w.endSection();
    w.beginSection(.depth, 1);
    w.u32v(1);
    w.endSection();
    w.beginSection(.scene, 1);
    w.u32v(2);
    w.u32v(3);
    w.f32v(0.75);
    w.u32v(4);
    w.f32v(0.25);
    w.endSection();
    const n = try w.finish();

    var json: [1024]u8 = undefined;
    const m = try write(raw[0..n], &json);
    const text = json[0..m];
    try t.expect(std.mem.indexOf(u8, text, "\"tracking_state\":2") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"plane_count\":5") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"anchor_count\":9") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"count\":2") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"channel\":3") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"channel\":4") != null);
    // The shape nothing could read before: a tag and a length instead of an answer.
    try t.expect(std.mem.indexOf(u8, text, "\"tag\":5") == null);
    try t.expect(std.mem.indexOf(u8, text, "\"tag\":6") == null);
}

test "what the detector found reaches a reader as boxes, not as a byte count" {
    var raw: [256]u8 = undefined;
    var w = snapshot.Writer.init(&raw, 2000);
    w.beginSection(.detections, 1);
    w.u32v(1);
    w.u32v(17);
    w.f32v(0.94);
    w.f32v(0.25);
    w.f32v(0.10);
    w.f32v(0.30);
    w.f32v(0.60);
    w.endSection();
    const n = try w.finish();

    var json: [512]u8 = undefined;
    const m = try write(raw[0..n], &json);
    const text = json[0..m];
    try t.expect(std.mem.indexOf(u8, text, "\"label\":17") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"score\":0.940") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"width\":0.300") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"tag\":14") == null);
}

test "the lens section names the lens and the nodes that did not come up" {
    var raw: [256]u8 = undefined;
    var w = snapshot.Writer.init(&raw, 1000);
    w.beginSection(.lens, 2);
    w.u32v(1);
    w.u32v(1);
    w.u32v(@intCast("goss.reference.warm-lut".len));
    w.u32v(7);
    w.u32v(2);
    w.u32v(5);
    w.bytes("goss.reference.warm-lut");
    w.endSection();
    const n = try w.finish();

    var json: [512]u8 = undefined;
    const m = try write(raw[0..n], &json);
    const text = json[0..m];
    try t.expect(std.mem.indexOf(u8, text, "\"id\":\"goss.reference.warm-lut\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"node_index\":7") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"state\":2") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"reason\":5") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"tag\":11") == null);
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

test "a reading with a quote in it stays valid json" {
    var out: Out = .{ .buf = &.{} };
    out.string("SALE \"50%\" off\nnow");
    // Nothing is written to a zero-length buffer, but the size is counted, so
    // the escapes are what makes the count larger than the input.
    try std.testing.expect(out.needed > "SALE \"50%\" off\nnow".len + 2);

    var room: [64]u8 = undefined;
    var sized: Out = .{ .buf = &room };
    sized.string("A\"B\\C\nD");
    try std.testing.expectEqualStrings("\"A\\\"B\\\\C\\nD\"", room[0..sized.at]);
}
