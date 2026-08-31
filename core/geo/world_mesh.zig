//! Ray queries against a host-submitted world mesh: the pre-scanned environment
//! geometry a device's scene reconstruction (ARKit, ARCore, a VPS scan) hands
//! the engine in world space, so a tap ray returns where it meets the scanned
//! surface and content anchors on real geometry. Möller-Trumbore, two-sided.
const std = @import("std");

/// Where a ray meets the mesh: the world-space point, the ray distance to it,
/// and the triangle it hit.
pub const Hit = struct { point: [3]f32, distance: f32, triangle: u32 };

fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// Distance along a ray to a triangle, or null if it misses. Two-sided: a ray
/// hits a triangle from either face, since a scanned mesh has no reliable
/// winding. Returns t for `origin + t*dir`, t at or past zero.
fn rayTriangle(origin: [3]f32, dir: [3]f32, a: [3]f32, b: [3]f32, c: [3]f32) ?f32 {
    const eps: f32 = 1e-7;
    const edge1 = sub(b, a);
    const edge2 = sub(c, a);
    const h = cross(dir, edge2);
    const det = dot(edge1, h);
    if (@abs(det) < eps) return null; // ray parallel to the triangle plane
    const inv = 1.0 / det;
    const s = sub(origin, a);
    const u = inv * dot(s, h);
    if (u < 0 or u > 1) return null;
    const q = cross(s, edge1);
    const v = inv * dot(dir, q);
    if (v < 0 or u + v > 1) return null;
    const dist = inv * dot(edge2, q);
    if (dist < eps) return null; // hit is behind the ray origin
    return dist;
}

/// Casts a ray from origin along dir against the triangle mesh - vertices indexed
/// three-per-triangle by indices - and returns the nearest forward hit, or null
/// when the ray misses every triangle. dir need not be normalized; the returned
/// distance is in units of dir's length.
pub fn raycast(vertices: []const [3]f32, indices: []const u32, origin: [3]f32, dir: [3]f32) ?Hit {
    var best: ?Hit = null;
    var tri: u32 = 0;
    var i: usize = 0;
    while (i + 3 <= indices.len) : (i += 3) {
        const ia = indices[i];
        const ib = indices[i + 1];
        const ic = indices[i + 2];
        if (ia >= vertices.len or ib >= vertices.len or ic >= vertices.len) {
            tri += 1;
            continue;
        }
        if (rayTriangle(origin, dir, vertices[ia], vertices[ib], vertices[ic])) |hit_t| {
            if (best == null or hit_t < best.?.distance) {
                best = .{
                    .point = .{ origin[0] + hit_t * dir[0], origin[1] + hit_t * dir[1], origin[2] + hit_t * dir[2] },
                    .distance = hit_t,
                    .triangle = tri,
                };
            }
        }
        tri += 1;
    }
    return best;
}

const t = std.testing;

test "a ray hits the nearer of two stacked quads and reports the point" {
    // Two quads in the z=0 and z=-2 planes, each spanning x,y in [-1,1].
    const verts = [_][3]f32{
        .{ -1, -1, 0 },  .{ 1, -1, 0 },  .{ 1, 1, 0 },  .{ -1, 1, 0 },
        .{ -1, -1, -2 }, .{ 1, -1, -2 }, .{ 1, 1, -2 }, .{ -1, 1, -2 },
    };
    const idx = [_]u32{ 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 };
    const hit = raycast(&verts, &idx, .{ 0, 0, 1 }, .{ 0, 0, -1 }) orelse return error.NoHit;
    try t.expectApproxEqAbs(@as(f32, 1), hit.distance, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0), hit.point[2], 1e-5);
}

test "a ray that clears the mesh returns no hit" {
    const verts = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } };
    const idx = [_]u32{ 0, 1, 2, 0, 2, 3 };
    try t.expectEqual(@as(?Hit, null), raycast(&verts, &idx, .{ 5, 5, 1 }, .{ 0, 0, -1 }));
}

test "a triangle is hit from its back face too" {
    const verts = [_][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 0, 1, 0 } };
    const idx = [_]u32{ 0, 1, 2 };
    // Cast upward from below the triangle; a one-sided test would miss it.
    const hit = raycast(&verts, &idx, .{ 0, 0, -1 }, .{ 0, 0, 1 }) orelse return error.NoHit;
    try t.expectApproxEqAbs(@as(f32, 1), hit.distance, 1e-5);
}
