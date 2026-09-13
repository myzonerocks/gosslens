//! What a text region is, and the geometry that makes one usable: an oriented
//! quadrilateral, the upright crop it unwarps to, and a stable id across frames.
//! No model and no GPU: a detector fills these in, and everything downstream
//! reads them the same way whether they came from a net or from a barcode.

const std = @import("std");

/// A point in normalized frame space, so a region means the same thing at any
/// capture resolution and a coordinate an agent sends back maps to a real pixel.
pub const Point = struct { x: f32, y: f32 };

/// One detected region, corners in reading order: top-left, top-right,
/// bottom-right, bottom-left. A quadrilateral rather than a rectangle because
/// text on a sign, a screen or a page is almost never axis-aligned.
pub const Quad = struct {
    corners: [4]Point,

    pub fn centre(q: Quad) Point {
        var cx: f32 = 0;
        var cy: f32 = 0;
        for (q.corners) |p| {
            cx += p.x;
            cy += p.y;
        }
        return .{ .x = cx / 4, .y = cy / 4 };
    }

    /// The shoelace area, always positive, so a quad wound either way measures
    /// the same and a degenerate one measures zero.
    pub fn area(q: Quad) f32 {
        var acc: f32 = 0;
        for (0..4) |i| {
            const a = q.corners[i];
            const b = q.corners[(i + 1) % 4];
            acc += a.x * b.y - b.x * a.y;
        }
        return @abs(acc) / 2;
    }

    /// The longer of the two horizontal edges and of the two vertical ones,
    /// which is the crop size that loses no glyph to foreshortening.
    pub fn extent(q: Quad) struct { w: f32, h: f32 } {
        const top = distance(q.corners[0], q.corners[1]);
        const bottom = distance(q.corners[3], q.corners[2]);
        const left = distance(q.corners[0], q.corners[3]);
        const right = distance(q.corners[1], q.corners[2]);
        return .{ .w = @max(top, bottom), .h = @max(left, right) };
    }

    /// The angle of the top edge, which is how far the text is rotated in the
    /// frame and what an overlay must match to sit on top of it.
    pub fn angle(q: Quad) f32 {
        return std.math.atan2(q.corners[1].y - q.corners[0].y, q.corners[1].x - q.corners[0].x);
    }

    pub fn contains(q: Quad, p: Point) bool {
        // A point is inside a convex quad when it is on the same side of every
        // edge; the sign of the cross product is that side.
        var positive = false;
        var negative = false;
        for (0..4) |i| {
            const a = q.corners[i];
            const b = q.corners[(i + 1) % 4];
            const cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
            if (cross > 0) positive = true;
            if (cross < 0) negative = true;
        }
        return !(positive and negative);
    }

    /// Grows the quad about its centre. A detector trained with shrunk labels
    /// hands back a box inside the ink, and the recogniser needs the glyph
    /// edges back.
    pub fn expand(q: Quad, ratio: f32) Quad {
        const c = q.centre();
        var out = q;
        for (&out.corners) |*p| {
            p.x = c.x + (p.x - c.x) * ratio;
            p.y = c.y + (p.y - c.y) * ratio;
        }
        return out;
    }

    /// Orders four corners into reading order from any winding, so a detector
    /// that emits them counter-clockwise and one that emits them clockwise
    /// produce the same region.
    pub fn ordered(points: [4]Point) Quad {
        var sorted = points;
        // Top two by y, then left-right within each pair: the reading order a
        // recogniser needs and the only ordering that survives rotation.
        std.mem.sortUnstable(Point, &sorted, {}, lessByY);
        var top: [2]Point = .{ sorted[0], sorted[1] };
        var bottom: [2]Point = .{ sorted[2], sorted[3] };
        if (top[0].x > top[1].x) std.mem.swap(Point, &top[0], &top[1]);
        if (bottom[0].x > bottom[1].x) std.mem.swap(Point, &bottom[0], &bottom[1]);
        return .{ .corners = .{ top[0], top[1], bottom[1], bottom[0] } };
    }
};

fn lessByY(_: void, a: Point, b: Point) bool {
    if (a.y == b.y) return a.x < b.x;
    return a.y < b.y;
}

fn distance(a: Point, b: Point) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return @sqrt(dx * dx + dy * dy);
}

/// Which script a region's glyphs belong to, as far as geometry and the decoded
/// characters can tell. It is a hint for choosing a recogniser, never a claim.
pub const Script = enum { unknown, latin, han, kana, hangul, cyrillic, arabic, devanagari, thai, hebrew };

/// Where the glyphs run. A recogniser reads a rectified crop left to right; a
/// vertical region is rectified with a quarter turn first.
pub const Direction = enum { left_to_right, right_to_left, top_to_bottom };

/// One detected region before recognition: where it is, how sure the detector
/// is, and the id that ties it to the same region in the previous frame.
pub const Region = struct {
    quad: Quad,
    confidence: f32,
    script: Script = .unknown,
    direction: Direction = .left_to_right,
    /// Stable across frames while the region keeps its place, so an overlay
    /// pinned to a sign does not flicker and a cache keyed on it holds.
    track_id: u32 = 0,
    /// A hash of the rectified pixels, so a region whose content has not
    /// changed skips recognition entirely. Watching a static sign costs nothing.
    content_hash: u64 = 0,
};

const testing = std.testing;

test "a quad orders its corners from any winding" {
    const clockwise = Quad.ordered(.{
        .{ .x = 0.1, .y = 0.1 },
        .{ .x = 0.5, .y = 0.1 },
        .{ .x = 0.5, .y = 0.3 },
        .{ .x = 0.1, .y = 0.3 },
    });
    const counter = Quad.ordered(.{
        .{ .x = 0.1, .y = 0.3 },
        .{ .x = 0.5, .y = 0.3 },
        .{ .x = 0.5, .y = 0.1 },
        .{ .x = 0.1, .y = 0.1 },
    });
    try testing.expectEqual(clockwise.corners[0].x, counter.corners[0].x);
    try testing.expectEqual(clockwise.corners[0].y, counter.corners[0].y);
    try testing.expectEqual(clockwise.corners[2].x, counter.corners[2].x);
    try testing.expectApproxEqAbs(@as(f32, 0.08), clockwise.area(), 1e-6);
}

test "a quad measures its extent, angle and what is inside it" {
    const q: Quad = .{ .corners = .{
        .{ .x = 0.2, .y = 0.2 },
        .{ .x = 0.6, .y = 0.4 },
        .{ .x = 0.55, .y = 0.5 },
        .{ .x = 0.15, .y = 0.3 },
    } };
    const size = q.extent();
    try testing.expectApproxEqAbs(@as(f32, 0.4472), size.w, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.1118), size.h, 1e-3);
    // The top edge rises 0.2 over 0.4, which is a touch over 26 degrees.
    try testing.expectApproxEqAbs(@as(f32, 0.4636), q.angle(), 1e-3);
    try testing.expect(q.contains(q.centre()));
    try testing.expect(!q.contains(.{ .x = 0.9, .y = 0.9 }));
}

test "expanding a quad recovers the ink a shrunk label cut off" {
    const q: Quad = .{ .corners = .{
        .{ .x = 0.4, .y = 0.4 },
        .{ .x = 0.6, .y = 0.4 },
        .{ .x = 0.6, .y = 0.5 },
        .{ .x = 0.4, .y = 0.5 },
    } };
    const wide = q.expand(1.5);
    try testing.expectApproxEqAbs(@as(f32, 0.35), wide.corners[0].x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.65), wide.corners[1].x, 1e-6);
    // The centre does not move and the area grows by the square of the ratio.
    try testing.expectApproxEqAbs(q.centre().x, wide.centre().x, 1e-6);
    try testing.expectApproxEqAbs(q.area() * 2.25, wide.area(), 1e-6);
}
