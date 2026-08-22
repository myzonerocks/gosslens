//! World-anchored brush strokes: the AR-brush storage. Points are pushed in
//! world space; the engine projects them to screen and draws them by the same
//! ribbon path as the screen brush. Pure, bounded state, no allocation; the
//! projection and mode bias live with the engine's math and renderer.
const std = @import("std");

pub const max_strokes = 64;
pub const max_points = 256;

pub const Point3 = struct { x: f32, y: f32, z: f32 };

/// mode matches stroke.Mode's integer values (0 pen, 1 highlighter, 2 marker,
/// 3 neon); the engine turns it back into the mode when it projects the stroke.
pub const WorldStroke = struct {
    points: [max_points]Point3 = undefined,
    count: u16 = 0,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    width: f32 = 0.01,
    mode: u8 = 0,
};

/// A board of world-anchored strokes. begin/point/end build the current stroke
/// in world space; the engine reads finished strokes back to project and draw
/// them. All bounded, no allocation.
pub const WorldBoard = struct {
    strokes: [max_strokes]WorldStroke = undefined,
    count: u16 = 0,
    drawing: bool = false,
    style_color: [4]f32 = .{ 1, 1, 1, 1 },
    style_width: f32 = 0.01,
    style_mode: u8 = 0,

    pub fn setStyle(self: *WorldBoard, color: [4]f32, width: f32) void {
        self.style_color = color;
        self.style_width = if (width > 0) width else 0.001;
    }

    pub fn setMode(self: *WorldBoard, mode: u8) void {
        self.style_mode = mode;
    }

    pub fn begin(self: *WorldBoard) void {
        if (self.count >= max_strokes) return;
        self.strokes[self.count] = .{ .color = self.style_color, .width = self.style_width, .mode = self.style_mode };
        self.drawing = true;
    }

    pub fn point(self: *WorldBoard, x: f32, y: f32, z: f32) void {
        if (!self.drawing or self.count >= max_strokes) return;
        const s = &self.strokes[self.count];
        if (s.count >= max_points) return;
        s.points[s.count] = .{ .x = x, .y = y, .z = z };
        s.count += 1;
    }

    pub fn end(self: *WorldBoard) void {
        if (!self.drawing) return;
        self.drawing = false;
        if (self.strokes[self.count].count >= 2) self.count += 1;
    }

    pub fn undo(self: *WorldBoard) void {
        if (self.count > 0) self.count -= 1;
    }

    pub fn clear(self: *WorldBoard) void {
        self.count = 0;
        self.drawing = false;
    }

    pub fn strokeCount(self: *const WorldBoard) u16 {
        return self.count;
    }

    /// The committed stroke at i, or null past the end.
    pub fn get(self: *const WorldBoard, i: u16) ?*const WorldStroke {
        if (i >= self.count) return null;
        return &self.strokes[i];
    }
};

const t = std.testing;

test "a world stroke commits only with two or more points" {
    var b = WorldBoard{};
    b.begin();
    b.point(0, 0, 0);
    b.end();
    try t.expectEqual(@as(u16, 0), b.count);
    b.begin();
    b.point(0, 0, -1);
    b.point(1, 1, -1);
    b.end();
    try t.expectEqual(@as(u16, 1), b.count);
    try t.expectEqual(@as(u16, 2), b.get(0).?.count);
}

test "the style rides each opened stroke" {
    var b = WorldBoard{};
    b.setStyle(.{ 1, 0.2, 0.4, 1 }, 0.02);
    b.setMode(3); // neon
    b.begin();
    b.point(0, 0, -1);
    b.point(1, 0, -1);
    b.end();
    const s = b.get(0).?;
    try t.expectEqual(@as(u8, 3), s.mode);
    try t.expectApproxEqAbs(@as(f32, 0.02), s.width, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.2), s.color[1], 1e-6);
}

test "undo drops the last stroke and clear empties the board" {
    var b = WorldBoard{};
    b.begin();
    b.point(0, 0, -1);
    b.point(1, 1, -1);
    b.end();
    b.begin();
    b.point(0, 1, -1);
    b.point(1, 0, -1);
    b.end();
    try t.expectEqual(@as(u16, 2), b.strokeCount());
    b.undo();
    try t.expectEqual(@as(u16, 1), b.strokeCount());
    b.clear();
    try t.expectEqual(@as(u16, 0), b.strokeCount());
    try t.expectEqual(@as(?*const WorldStroke, null), b.get(0));
}
