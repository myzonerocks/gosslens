//! Brush strokes: the geometry behind the draw and AR-brush tools. Points are
//! pushed in normalized screen space, expanded into a per-segment ribbon of
//! triangles for the renderer. Bounded fixed storage with an undo/redo stack,
//! so a stroke allocates nothing and the frame path only reads finished vertices.
const std = @import("std");

pub const max_strokes = 64;
pub const max_points = 256;
pub const floats_per_vertex = 6; // x, y, r, g, b, a
/// Six vertices (two triangles) per segment, up to max_points-1 segments.
pub const max_vertices = max_strokes * (max_points - 1) * 6;

pub const Point = struct { x: f32, y: f32 };

/// Brush presets. Each biases the default width and alpha of the strokes it
/// opens; neon also tells the renderer to draw its ribbon additively for the
/// glow. The mode rides each committed stroke so a board can mix modes.
pub const Mode = enum(u8) {
    pen = 0, // opaque, thin
    highlighter = 1, // translucent, wide
    marker = 2, // near-opaque, medium
    neon = 3, // translucent, wide, additive glow at draw time

    pub fn fromU32(v: u32) Mode {
        return switch (v) {
            1 => .highlighter,
            2 => .marker,
            3 => .neon,
            else => .pen,
        };
    }

    /// Multiplier on the style half-width when a stroke opens in this mode.
    pub fn widthScale(self: Mode) f32 {
        return switch (self) {
            .pen => 1.0,
            .highlighter => 2.5,
            .marker => 1.6,
            .neon => 2.0,
        };
    }

    /// Multiplier on the style alpha when a stroke opens in this mode.
    pub fn alphaScale(self: Mode) f32 {
        return switch (self) {
            .pen => 1.0,
            .highlighter => 0.4,
            .marker => 0.85,
            .neon => 0.6,
        };
    }

    /// Whether the renderer should draw this stroke's ribbon additively.
    pub fn additive(self: Mode) bool {
        return self == .neon;
    }
};

pub const Stroke = struct {
    points: [max_points]Point = undefined,
    count: u16 = 0,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    width: f32 = 0.01, // half-width in normalized units
    mode: Mode = .pen,
};

/// A board of strokes with an undo/redo op-log. begin/point/end build the
/// current stroke; undo pops the last committed stroke onto the redo stack;
/// redo replays it; clear drops everything. All bounded, no allocation.
pub const Board = struct {
    strokes: [max_strokes]Stroke = undefined,
    count: u16 = 0,
    redo: [max_strokes]Stroke = undefined,
    redo_count: u16 = 0,
    drawing: bool = false,
    style_color: [4]f32 = .{ 1, 1, 1, 1 },
    style_width: f32 = 0.01,
    style_mode: Mode = .pen,

    pub fn setStyle(self: *Board, color: [4]f32, width: f32) void {
        self.style_color = color;
        self.style_width = if (width > 0) width else 0.001;
    }

    /// Selects the brush preset the next stroke opens with. The preset biases
    /// the opened stroke's width and alpha; the renderer reads the stored mode
    /// to draw neon additively.
    pub fn setMode(self: *Board, mode: Mode) void {
        self.style_mode = mode;
    }

    /// Starts a new stroke with the current style biased by the current mode. A
    /// fresh stroke invalidates the redo stack, the same as any editor.
    pub fn begin(self: *Board) void {
        if (self.count >= max_strokes) return;
        self.redo_count = 0;
        const m = self.style_mode;
        var color = self.style_color;
        color[3] *= m.alphaScale();
        self.strokes[self.count] = .{
            .color = color,
            .width = self.style_width * m.widthScale(),
            .mode = m,
        };
        self.drawing = true;
    }

    /// Removes every committed stroke whose ribbon passes within `radius`
    /// (normalized units) of (x, y) and returns how many were dropped. A
    /// point-to-segment test, so a straight run between sampled points erases
    /// too. Refuses mid-stroke so the open stroke's index stays valid.
    pub fn eraseAt(self: *Board, x: f32, y: f32, radius: f32) usize {
        if (self.drawing or self.count == 0) return 0;
        const r2 = radius * radius;
        var write: u16 = 0;
        var read: u16 = 0;
        var removed: usize = 0;
        while (read < self.count) : (read += 1) {
            if (strokeHit(self.strokes[read], x, y, r2)) {
                removed += 1;
                continue;
            }
            if (write != read) self.strokes[write] = self.strokes[read];
            write += 1;
        }
        self.count = write;
        return removed;
    }

    pub fn point(self: *Board, x: f32, y: f32) void {
        if (!self.drawing or self.count >= max_strokes) return;
        const s = &self.strokes[self.count];
        if (s.count >= max_points) return;
        s.points[s.count] = .{ .x = x, .y = y };
        s.count += 1;
    }

    /// Commits the current stroke; a stroke of fewer than two points is dropped.
    pub fn end(self: *Board) void {
        if (!self.drawing) return;
        self.drawing = false;
        if (self.strokes[self.count].count >= 2) self.count += 1;
    }

    pub fn undo(self: *Board) void {
        if (self.count == 0) return;
        self.count -= 1;
        self.redo[self.redo_count] = self.strokes[self.count];
        self.redo_count += 1;
    }

    pub fn redoLast(self: *Board) void {
        if (self.redo_count == 0 or self.count >= max_strokes) return;
        self.redo_count -= 1;
        self.strokes[self.count] = self.redo[self.redo_count];
        self.count += 1;
    }

    pub fn clear(self: *Board) void {
        self.count = 0;
        self.redo_count = 0;
        self.drawing = false;
    }

    /// The float count buildVertices would write for the current strokes, so a
    /// caller can size its buffer before pulling the ribbon. Counts only
    /// segments long enough to survive the degenerate check.
    pub fn vertexFloatCount(self: *const Board) usize {
        var v: usize = 0;
        for (self.strokes[0..self.count]) |s| {
            if (s.count < 2) continue;
            var i: u16 = 0;
            while (i + 1 < s.count) : (i += 1) {
                const a = s.points[i];
                const b = s.points[i + 1];
                const dx = b.x - a.x;
                const dy = b.y - a.y;
                if (@sqrt(dx * dx + dy * dy) < 1e-6) continue;
                v += 6 * floats_per_vertex;
            }
        }
        return v;
    }

    /// Expands every committed stroke into a triangle ribbon in `out`
    /// (floats_per_vertex per vertex), returning the vertex count. Each segment
    /// becomes a quad whose thickness is the stroke's half-width offset
    /// perpendicular to the segment direction.
    pub fn buildVertices(self: *const Board, out: []f32) usize {
        var v: usize = 0;
        for (self.strokes[0..self.count]) |s| {
            if (s.count < 2) continue;
            var i: u16 = 0;
            while (i + 1 < s.count) : (i += 1) {
                const a = s.points[i];
                const b = s.points[i + 1];
                var dx = b.x - a.x;
                var dy = b.y - a.y;
                const len = @sqrt(dx * dx + dy * dy);
                if (len < 1e-6) continue;
                dx /= len;
                dy /= len;
                const nx = -dy * s.width; // perpendicular offset
                const ny = dx * s.width;
                const corners = [4][2]f32{
                    .{ a.x + nx, a.y + ny },
                    .{ a.x - nx, a.y - ny },
                    .{ b.x - nx, b.y - ny },
                    .{ b.x + nx, b.y + ny },
                };
                const tri = [6]usize{ 0, 1, 2, 0, 2, 3 };
                for (tri) |c| {
                    if (v + floats_per_vertex > out.len) return v;
                    out[v + 0] = corners[c][0];
                    out[v + 1] = corners[c][1];
                    out[v + 2] = s.color[0];
                    out[v + 3] = s.color[1];
                    out[v + 4] = s.color[2];
                    out[v + 5] = s.color[3];
                    v += floats_per_vertex;
                }
            }
        }
        return v;
    }
};

/// True when any segment of the stroke passes within the squared radius of the
/// point. A one-point stroke tests the point itself.
fn strokeHit(s: Stroke, x: f32, y: f32, r2: f32) bool {
    if (s.count == 0) return false;
    if (s.count == 1) {
        const dx = s.points[0].x - x;
        const dy = s.points[0].y - y;
        return dx * dx + dy * dy <= r2;
    }
    var i: u16 = 0;
    while (i + 1 < s.count) : (i += 1) {
        if (pointSegDist2(x, y, s.points[i], s.points[i + 1]) <= r2) return true;
    }
    return false;
}

/// Squared distance from (px, py) to segment a-b, clamped to the segment.
fn pointSegDist2(px: f32, py: f32, a: Point, b: Point) f32 {
    const abx = b.x - a.x;
    const aby = b.y - a.y;
    const denom = abx * abx + aby * aby;
    var s: f32 = 0;
    if (denom > 1e-12) s = ((px - a.x) * abx + (py - a.y) * aby) / denom;
    if (s < 0) s = 0;
    if (s > 1) s = 1;
    const dx = px - (a.x + s * abx);
    const dy = py - (a.y + s * aby);
    return dx * dx + dy * dy;
}

const t = std.testing;

test "a stroke commits only with two or more points" {
    var b = Board{};
    b.begin();
    b.point(0.1, 0.1);
    b.end();
    try t.expectEqual(@as(u16, 0), b.count); // one point is dropped
    b.begin();
    b.point(0.1, 0.1);
    b.point(0.5, 0.5);
    b.end();
    try t.expectEqual(@as(u16, 1), b.count);
}

test "undo and redo move the last stroke across the stacks" {
    var b = Board{};
    b.begin();
    b.point(0, 0);
    b.point(1, 1);
    b.end();
    try t.expectEqual(@as(u16, 1), b.count);
    b.undo();
    try t.expectEqual(@as(u16, 0), b.count);
    b.redoLast();
    try t.expectEqual(@as(u16, 1), b.count);
    // A fresh stroke invalidates redo.
    b.undo();
    b.begin();
    b.point(0, 0);
    b.point(0.2, 0.2);
    b.end();
    try t.expectEqual(@as(u16, 0), b.redo_count);
}

test "buildVertices produces six vertices per segment" {
    var b = Board{};
    b.begin();
    b.point(0, 0);
    b.point(1, 0); // one segment
    b.point(1, 1); // second segment
    b.end();
    var out: [max_vertices]f32 = undefined;
    const n = b.buildVertices(&out);
    // two segments * six vertices * six floats
    try t.expectEqual(@as(usize, 2 * 6 * floats_per_vertex), n);
    // the color rides every vertex
    try t.expectEqual(@as(f32, 1), out[2]);
}

test "a mode biases the opened stroke width and alpha" {
    var b = Board{};
    b.setStyle(.{ 1, 1, 1, 1 }, 0.01);
    b.setMode(.highlighter);
    b.begin();
    b.point(0, 0);
    b.point(0.5, 0);
    b.end();
    const s = b.strokes[0];
    try t.expectEqual(Mode.highlighter, s.mode);
    try t.expectApproxEqAbs(@as(f32, 0.01 * 2.5), s.width, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.4), s.color[3], 1e-6);
    try t.expect(Mode.neon.additive());
    try t.expect(!Mode.pen.additive());
}

test "eraseAt drops strokes it crosses and keeps the rest" {
    var b = Board{};
    // A horizontal stroke along y = 0.
    b.begin();
    b.point(0, 0);
    b.point(1, 0);
    b.end();
    // A far horizontal stroke along y = 0.8.
    b.begin();
    b.point(0, 0.8);
    b.point(1, 0.8);
    b.end();
    try t.expectEqual(@as(u16, 2), b.count);
    // Erase near the middle of the first stroke; the second is untouched.
    try t.expectEqual(@as(usize, 1), b.eraseAt(0.5, 0.02, 0.05));
    try t.expectEqual(@as(u16, 1), b.count);
    // The survivor is the y = 0.8 stroke.
    try t.expectApproxEqAbs(@as(f32, 0.8), b.strokes[0].points[0].y, 1e-6);
    // A miss removes nothing; mid-stroke erase is refused.
    try t.expectEqual(@as(usize, 0), b.eraseAt(0.5, 0.4, 0.05));
    b.begin();
    try t.expectEqual(@as(usize, 0), b.eraseAt(0.5, 0.8, 0.2));
}

test "clear drops everything" {
    var b = Board{};
    b.begin();
    b.point(0, 0);
    b.point(1, 1);
    b.end();
    b.clear();
    try t.expectEqual(@as(u16, 0), b.count);
    var out: [max_vertices]f32 = undefined;
    try t.expectEqual(@as(usize, 0), b.buildVertices(&out));
}
