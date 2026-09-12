//! The snapshot record's schema, declared rather than implied. The writer and
//! the JSON projector both worked from offsets written by hand in two places,
//! which is exactly the arrangement that lets one drift from the other. The
//! layout lives here, the projector reads through it, and a baseline file pins
//! it so a field cannot be reordered or dropped inside a major version.

const std = @import("std");
const snapshot = @import("snapshot.zig");

pub const FieldType = enum(u8) {
    u32,
    i32,
    u64,
    i64,
    f32,

    pub fn size(t: FieldType) usize {
        return switch (t) {
            .u32, .i32, .f32 => 4,
            .u64, .i64 => 8,
        };
    }
};

pub const Field = struct {
    name: []const u8,
    type: FieldType,
};

/// One section's fixed head. Everything after it is repeated per entry and
/// described by `repeat`, because a count followed by a run of records is the
/// shape most sections take.
pub const Section = struct {
    tag: snapshot.Tag,
    version: u16,
    head: []const Field,
    repeat: []const Field = &.{},

    /// Where a field starts in the payload. The alignment is the writer's: it
    /// packs fields back to back and pads an eight byte field to eight, which is
    /// what the reader must assume too.
    pub fn offsetOf(section: Section, name: []const u8) ?usize {
        var at: usize = 0;
        for (section.head) |f| {
            at = std.mem.alignForward(usize, at, f.type.size());
            if (std.mem.eql(u8, f.name, name)) return at;
            at += f.type.size();
        }
        return null;
    }

    pub fn headSize(section: Section) usize {
        var at: usize = 0;
        for (section.head) |f| {
            at = std.mem.alignForward(usize, at, f.type.size());
            at += f.type.size();
        }
        return at;
    }

    pub fn repeatSize(section: Section) usize {
        var at: usize = 0;
        for (section.repeat) |f| {
            at = std.mem.alignForward(usize, at, f.type.size());
            at += f.type.size();
        }
        return at;
    }
};

/// Every section the engine writes. Adding one here and writing it are two
/// steps on purpose: the gate compares this against its baseline, so a new
/// section shows up in review as a line rather than as a shape nobody declared.
pub const sections = [_]Section{
    .{
        .tag = .frame,
        .version = 1,
        .head = &.{
            .{ .name = "width", .type = .u32 },
            .{ .name = "height", .type = .u32 },
            .{ .name = "pixel_format", .type = .u32 },
            .{ .name = "color_standard", .type = .u32 },
            .{ .name = "color_range", .type = .u32 },
            .{ .name = "flags", .type = .u32 },
            .{ .name = "timestamp_us", .type = .i64 },
            .{ .name = "frames_submitted", .type = .u64 },
        },
    },
    .{
        .tag = .faces,
        .version = 1,
        .head = &.{.{ .name = "count", .type = .u32 }},
    },
    .{
        .tag = .hands,
        .version = 1,
        .head = &.{.{ .name = "count", .type = .u32 }},
    },
    .{
        .tag = .bodies,
        .version = 1,
        .head = &.{.{ .name = "count", .type = .u32 }},
    },
    .{
        .tag = .audio,
        .version = 1,
        .head = &.{
            .{ .name = "level", .type = .f32 },
            .{ .name = "beat", .type = .u32 },
            .{ .name = "engine_fed", .type = .u32 },
        },
    },
    .{
        .tag = .engine,
        .version = 1,
        .head = &.{
            .{ .name = "degrade_level", .type = .u32 },
            .{ .name = "degrade_transitions", .type = .u32 },
            .{ .name = "frames_rendered", .type = .u64 },
            .{ .name = "script_faults", .type = .u32 },
        },
    },
    .{
        .tag = .embedding,
        .version = 1,
        .head = &.{
            .{ .name = "dim", .type = .u32 },
            .{ .name = "source", .type = .u32 },
        },
        .repeat = &.{.{ .name = "value", .type = .f32 }},
    },
    .{
        .tag = .text,
        .version = 2,
        .head = &.{.{ .name = "count", .type = .u32 }},
        .repeat = &.{
            .{ .name = "x0", .type = .f32 },
            .{ .name = "y0", .type = .f32 },
            .{ .name = "x1", .type = .f32 },
            .{ .name = "y1", .type = .f32 },
            .{ .name = "x2", .type = .f32 },
            .{ .name = "y2", .type = .f32 },
            .{ .name = "x3", .type = .f32 },
            .{ .name = "y3", .type = .f32 },
            .{ .name = "confidence", .type = .f32 },
            .{ .name = "origin", .type = .u32 },
            .{ .name = "script", .type = .u32 },
            .{ .name = "direction", .type = .u32 },
            .{ .name = "track_id", .type = .u32 },
            .{ .name = "line", .type = .u32 },
            .{ .name = "paragraph", .type = .u32 },
            .{ .name = "text_len", .type = .u32 },
        },
    },
};

pub fn sectionFor(tag: snapshot.Tag) ?Section {
    for (sections) |s| {
        if (s.tag == tag) return s;
    }
    return null;
}

/// The schema as deterministic text, for the baseline the gate compares against.
/// The same shape as the ABI dump, because the same class of mistake is being
/// prevented: a layout changing without anybody seeing a diff.
pub fn write(w: anytype) !void {
    try w.print("snapshot schema {d}\n", .{snapshot.schema_version});
    for (sections) |s| {
        try w.print("section {s} tag={d} version={d} head={d} repeat={d}\n", .{
            @tagName(s.tag), @intFromEnum(s.tag), s.version, s.headSize(), s.repeatSize(),
        });
        for (s.head) |f| {
            try w.print("  head {s} {s} offset={d}\n", .{ f.name, @tagName(f.type), s.offsetOf(f.name).? });
        }
        for (s.repeat) |f| {
            try w.print("  repeat {s} {s}\n", .{ f.name, @tagName(f.type) });
        }
    }
}

const testing = std.testing;

test "a field's offset is where the writer actually puts it" {
    const frame = sectionFor(.frame).?;
    try testing.expectEqual(@as(usize, 0), frame.offsetOf("width").?);
    try testing.expectEqual(@as(usize, 20), frame.offsetOf("flags").?);
    // Six u32 then an i64: the eight byte field pads to eight, which is where
    // the projector has always read it from.
    try testing.expectEqual(@as(usize, 24), frame.offsetOf("timestamp_us").?);
    try testing.expectEqual(@as(usize, 32), frame.offsetOf("frames_submitted").?);
    try testing.expectEqual(@as(usize, 40), frame.headSize());
    try testing.expect(frame.offsetOf("nothing") == null);

    const engine = sectionFor(.engine).?;
    try testing.expectEqual(@as(usize, 8), engine.offsetOf("frames_rendered").?);
    try testing.expectEqual(@as(usize, 16), engine.offsetOf("script_faults").?);
}

test "the text section's repeated head is the size every reader assumes" {
    const text = sectionFor(.text).?;
    try testing.expectEqual(@as(usize, 4), text.headSize());
    // Eight quad floats, confidence, then six u32 and the length.
    try testing.expectEqual(@as(usize, 8 * 4 + 4 + 7 * 4), text.repeatSize());
    try testing.expectEqual(@as(u16, 2), text.version);
}

test "every declared section names a tag the record can carry" {
    for (sections) |s| {
        try testing.expect(@intFromEnum(s.tag) != 0);
        try testing.expect(s.head.len != 0);
        // A repeated field list with no count to drive it is a layout nothing
        // can read, so a section with repeats must declare a count or a dim.
        if (s.repeat.len != 0) {
            const has_count = s.offsetOf("count") != null or s.offsetOf("dim") != null;
            try testing.expect(has_count);
        }
    }
}
