//! World-anchored brush strokes: the AR-brush geometry. Points are pushed in
//! world space and projected to screen each frame through the camera pose, then
//! drawn by the same ribbon path as the screen brush. Bounded fixed storage, so
//! a stroke allocates nothing and the frame path only reads finished points.
const std = @import("std");
const math = @import("math");
const stroke = @import("stroke");

pub const max_strokes = stroke.max_strokes;
pub const max_points = stroke.max_points;

pub const Point3 = struct { x: f32, y: f32, z: f32 };

pub const WorldStroke = struct {
    points: [max_points]Point3 = undefined,
    count: u16 = 0,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    width: f32 = 0.01, // half-width in normalized screen units
    mode: stroke.Mode = .pen,
};

/// A board of world-anchored strokes. begin/point/end build the current stroke
/// in world space; project maps every finished stroke to a screen-space
/// stroke.Board the renderer already knows how to draw. All bounded, no
/// allocation.
pub const WorldBoard = struct {
    strokes: [max_strokes]WorldStroke = undefined,
    count: u16 = 0,
    drawing: bool = false,
    style_color: [4]f32 = .{ 1, 1, 1, 1 },
    style_width: f32 = 0.01,
    style_mode: stroke.Mode = .pen,

    pub fn setStyle(self: *WorldBoard, color: [4]f32, width: f32) void {
        self.style_color = color;
        self.style_width = if (width > 0) width else 0.001;
    }

    pub fn setMode(self: *WorldBoard, mode: stroke.Mode) void {
        self.style_mode = mode;
    }

    /// Opens a stroke with the current style biased by the current mode, the
    /// same bias the screen brush applies, so a projected stroke looks the same.
    pub fn begin(self: *WorldBoard) void {
        if (self.count >= max_strokes) return;
        const m = self.style_mode;
        var color = self.style_color;
        color[3] *= m.alphaScale();
        self.strokes[self.count] = .{ .color = color, .width = self.style_width * m.widthScale(), .mode = m };
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

    /// Whether world stroke i draws additively (its mode is neon), for the
    /// projected board's per-stroke blend.
    pub fn additiveOf(self: *const WorldBoard, i: u16) bool {
        if (i >= self.count) return false;
        return self.strokes[i].mode.additive();
    }

    /// Projects every finished world stroke into `out`, a screen-space board the
    /// renderer draws with its ribbon path. `view_proj` is the camera view and
    /// projection combined. A point behind the camera is dropped, breaking the
    /// ribbon rather than smearing it. `out` is cleared first, no allocation.
    pub fn project(self: *const WorldBoard, view_proj: math.Mat4, out: *stroke.Board) void {
        out.clear();
        for (self.strokes[0..self.count]) |ws| {
            if (ws.count < 2 or out.count >= max_strokes) continue;
            const os = &out.strokes[out.count];
            os.* = .{ .color = ws.color, .width = ws.width, .mode = ws.mode };
            var n: u16 = 0;
            for (ws.points[0..ws.count]) |p| {
                const clip = view_proj.mulVec(.{ p.x, p.y, p.z, 1.0 });
                if (clip[3] <= 1e-6) continue; // behind the camera
                const ndc_x = clip[0] / clip[3];
                const ndc_y = clip[1] / clip[3];
                os.points[n] = .{ .x = ndc_x * 0.5 + 0.5, .y = 0.5 - ndc_y * 0.5 };
                n += 1;
            }
            os.count = n;
            if (n >= 2) out.count += 1;
        }
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
}

test "project maps world points to screen through the view-projection" {
    var b = WorldBoard{};
    b.begin();
    b.point(0, 0, 0);
    b.point(0.5, -0.5, 0);
    b.end();

    var out = stroke.Board{};
    b.project(math.Mat4.identity, &out);
    try t.expectEqual(@as(u16, 1), out.count);
    // (0,0,0) -> centre of the screen.
    try t.expectApproxEqAbs(@as(f32, 0.5), out.strokes[0].points[0].x, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5), out.strokes[0].points[0].y, 1e-6);
    // (0.5,-0.5,0): ndc (0.5,-0.5) -> screen (0.75, 0.75) with y measured down.
    try t.expectApproxEqAbs(@as(f32, 0.75), out.strokes[0].points[1].x, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.75), out.strokes[0].points[1].y, 1e-6);
    // The style rides across the projection.
    try t.expectEqual(stroke.Mode.pen, out.strokes[0].mode);
}

test "a point behind the camera is dropped" {
    var b = WorldBoard{};
    b.setMode(.neon);
    b.begin();
    b.point(0, 0, 1); // in front once w flips via projection below
    b.point(0, 0, 2);
    b.end();
    // A projection that puts positive-z behind the camera (w = -z).
    var vp = math.Mat4.identity;
    vp.cols[2][3] = -1.0; // w = -z
    vp.cols[3][3] = 0.0;
    var out = stroke.Board{};
    b.project(vp, &out);
    // Both points have w <= 0, so nothing survives to draw.
    try t.expectEqual(@as(u16, 0), out.count);
    // Neon still rides the world stroke's own style.
    try t.expect(b.additiveOf(0));
}
