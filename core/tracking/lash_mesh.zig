//! The 3D eyelash strip: a thin lash ribbon rising off each eye's upper lid.
//! Its base row pins to the upper lash-line landmarks and its tip row is
//! extruded outward from the eye centre by a length and swept by a curl.
//! Positions rebuild from the tracked landmarks each frame so it tracks the eye.

const std = @import("std");

/// Landmarks along one eye's upper lid, outer corner to inner corner: the
/// nine base points a lash strand rises from.
pub const points_per_eye = 9;
const eye_count = 2;

/// A base row and a tip row per eye, both eyes: the strip's own vertices.
pub const vertex_count = points_per_eye * 2 * eye_count;
/// Two triangles per lid segment, eight segments per eye, both eyes.
pub const index_count = (points_per_eye - 1) * 2 * 3 * eye_count;

/// Each eye's full ring, for the centre and height the extrusion scales by.
/// Kept here so this stays a leaf module the renderer imports without the
/// whole tracking pipeline; the loops match the ones the tracker fills.
pub const left_eye_loop = [16]u16{
    263, 249, 390, 373, 374, 380, 381, 382,
    362, 398, 384, 385, 386, 387, 388, 466,
};
pub const right_eye_loop = [16]u16{
    33,  7,   163, 144, 145, 153, 154, 155,
    133, 173, 157, 158, 159, 160, 161, 246,
};

/// Each eye's upper-lid arc: outer corner, the upper-lid run, inner corner.
pub const left_arc = [points_per_eye]u16{ 263, 466, 388, 387, 386, 385, 384, 398, 362 };
pub const right_arc = [points_per_eye]u16{ 33, 246, 161, 160, 159, 158, 157, 173, 133 };

/// The strip's triangles: each lid segment is a quad from the base row up to
/// the tip row, split into two triangles, generated once at compile time.
pub const triangle_indices = buildIndices();
/// Per-vertex strip UV: u runs across each eye's lid, v is zero at the base
/// row and one at the tip row, so the fragment shader combs strands along u
/// and tapers them along v.
pub const vertex_uvs = buildUvs();

fn buildIndices() [index_count]u16 {
    var out: [index_count]u16 = undefined;
    var at: usize = 0;
    var eye: usize = 0;
    while (eye < eye_count) : (eye += 1) {
        const base: u16 = @intCast(eye * points_per_eye * 2);
        const tip: u16 = base + points_per_eye;
        var i: u16 = 0;
        while (i < points_per_eye - 1) : (i += 1) {
            out[at] = base + i;
            out[at + 1] = base + i + 1;
            out[at + 2] = tip + i + 1;
            out[at + 3] = base + i;
            out[at + 4] = tip + i + 1;
            out[at + 5] = tip + i;
            at += 6;
        }
    }
    return out;
}

fn buildUvs() [vertex_count * 2]f32 {
    var out: [vertex_count * 2]f32 = undefined;
    var eye: usize = 0;
    while (eye < eye_count) : (eye += 1) {
        const off = eye * points_per_eye * 2;
        var i: usize = 0;
        while (i < points_per_eye) : (i += 1) {
            const u = @as(f32, @floatFromInt(i)) / @as(f32, points_per_eye - 1);
            out[(off + i) * 2] = u;
            out[(off + i) * 2 + 1] = 0.0;
            out[(off + points_per_eye + i) * 2] = u;
            out[(off + points_per_eye + i) * 2 + 1] = 1.0;
        }
    }
    return out;
}

fn point(landmarks: []const f32, idx: u16) [2]f32 {
    const base = @as(usize, idx) * 3;
    return .{ landmarks[base], landmarks[base + 1] };
}

/// Rebuilds the strip's vertex positions from the tracked landmarks. length
/// and curl are fractions of each eye's height: length is how far a strand
/// rises off the lid, curl how far its tip sweeps toward the outer corner.
/// out holds x, y per vertex, each divided by the frame size.
pub fn buildPositions(landmarks: []const f32, frame_w: f32, frame_h: f32, length: f32, curl: f32, out: *[vertex_count * 2]f32) void {
    buildEye(landmarks, &left_eye_loop, &left_arc, 0, frame_w, frame_h, length, curl, out);
    buildEye(landmarks, &right_eye_loop, &right_arc, points_per_eye * 2, frame_w, frame_h, length, curl, out);
}

fn buildEye(landmarks: []const f32, loop: []const u16, arc: []const u16, off: usize, frame_w: f32, frame_h: f32, length: f32, curl: f32, out: *[vertex_count * 2]f32) void {
    var sum = [2]f32{ 0, 0 };
    var min_y = point(landmarks, loop[0])[1];
    var max_y = min_y;
    for (loop) |idx| {
        const p = point(landmarks, idx);
        sum[0] += p[0];
        sum[1] += p[1];
        min_y = @min(min_y, p[1]);
        max_y = @max(max_y, p[1]);
    }
    const n: f32 = @floatFromInt(loop.len);
    const center = [2]f32{ sum[0] / n, sum[1] / n };
    const height = max_y - min_y;
    const rise = length * height;
    const sweep = curl * height;
    var i: usize = 0;
    while (i < arc.len) : (i += 1) {
        const p = point(landmarks, arc[i]);
        // Outward is from the eye centre through the lid point, so the strand
        // rises off the lid rather than lying across it.
        var ox = p[0] - center[0];
        var oy = p[1] - center[1];
        const od = @sqrt(ox * ox + oy * oy);
        if (od > 1e-6) {
            ox /= od;
            oy /= od;
        }
        // Tangent runs along the lid toward the outer corner (arc[0]); the
        // neighbours clamp at the two corners so the sweep never wraps.
        const prev = point(landmarks, arc[if (i == 0) 0 else i - 1]);
        const next = point(landmarks, arc[if (i + 1 >= arc.len) arc.len - 1 else i + 1]);
        var tx = prev[0] - next[0];
        var ty = prev[1] - next[1];
        const td = @sqrt(tx * tx + ty * ty);
        if (td > 1e-6) {
            tx /= td;
            ty /= td;
        }
        const tip_x = p[0] + ox * rise + tx * sweep;
        const tip_y = p[1] + oy * rise + ty * sweep;
        out[(off + i) * 2] = p[0] / frame_w;
        out[(off + i) * 2 + 1] = p[1] / frame_h;
        out[(off + points_per_eye + i) * 2] = tip_x / frame_w;
        out[(off + points_per_eye + i) * 2 + 1] = tip_y / frame_h;
    }
}

const t = std.testing;

test "every index and uv addresses a real strip vertex" {
    for (triangle_indices) |index| try t.expect(index < vertex_count);
    var at: usize = 0;
    while (at < vertex_uvs.len) : (at += 1) try t.expect(vertex_uvs[at] >= 0.0 and vertex_uvs[at] <= 1.0);
}

test "each strand tip rises above its base off the upper lid" {
    // A synthetic left eye: the upper lid a row above the centre, the lower
    // lid a row below, so outward from the centre points up through the lid.
    var landmarks: [478 * 3]f32 = @splat(0);
    const upper = [_]u16{ 466, 388, 387, 386, 385, 384, 398 };
    const lower = [_]u16{ 249, 390, 373, 374, 380, 381, 382 };
    for (upper, 0..) |idx, i| {
        landmarks[@as(usize, idx) * 3] = @floatFromInt(i);
        landmarks[@as(usize, idx) * 3 + 1] = -1;
    }
    for (lower, 0..) |idx, i| {
        landmarks[@as(usize, idx) * 3] = @floatFromInt(i);
        landmarks[@as(usize, idx) * 3 + 1] = 1;
    }
    landmarks[263 * 3] = -1;
    landmarks[362 * 3] = 7;

    var pos: [vertex_count * 2]f32 = undefined;
    buildPositions(&landmarks, 1.0, 1.0, 0.6, 0.2, &pos);
    // The three central upper-lid strands: their tips sit above their bases.
    for ([_]usize{ 3, 4, 5 }) |i| {
        const base_y = pos[i * 2 + 1];
        const tip_y = pos[(points_per_eye + i) * 2 + 1];
        try t.expect(tip_y < base_y);
    }
}
