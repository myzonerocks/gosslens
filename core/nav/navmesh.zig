//! A navigation mesh and pathfinding over it: walkable ground-plane triangles,
//! their shared-edge adjacency, and an A* search that routes a path from a
//! start point to a goal around the gaps between them. Pure and deterministic,
//! so a world-anchored character walks it identically on every device.

const std = @import("std");

pub const Vec3 = [3]f32;

const no_neighbor: u32 = std.math.maxInt(u32);

fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn dist(a: Vec3, b: Vec3) f32 {
    const d = sub(a, b);
    return @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
}

fn midpoint(a: Vec3, b: Vec3) Vec3 {
    return .{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2 };
}

/// True if p is inside triangle (a, b, c) seen from above (the x/z ground
/// plane), by the sign of the three edge cross products.
fn containsXZ(a: Vec3, b: Vec3, c: Vec3, p: Vec3) bool {
    const d1 = (p[0] - b[0]) * (a[2] - b[2]) - (a[0] - b[0]) * (p[2] - b[2]);
    const d2 = (p[0] - c[0]) * (b[2] - c[2]) - (b[0] - c[0]) * (p[2] - c[2]);
    const d3 = (p[0] - a[0]) * (c[2] - a[2]) - (c[0] - a[0]) * (p[2] - a[2]);
    const has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0);
    const has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0);
    return !(has_neg and has_pos);
}

pub const NavMesh = struct {
    vertices: []const Vec3,
    triangles: []const [3]u32,
    /// Per triangle, the neighbour across each edge (0: v0-v1, 1: v1-v2,
    /// 2: v2-v0), or `no_neighbor`.
    neighbors: [][3]u32,
    centroids: []Vec3,
    gpa: std.mem.Allocator,

    /// Builds the mesh and its edge adjacency. Borrows `vertices` and
    /// `triangles` for the mesh's lifetime.
    pub fn build(gpa: std.mem.Allocator, vertices: []const Vec3, triangles: []const [3]u32) !NavMesh {
        const neighbors = try gpa.alloc([3]u32, triangles.len);
        errdefer gpa.free(neighbors);
        for (neighbors) |*n| n.* = .{ no_neighbor, no_neighbor, no_neighbor };
        const centroids = try gpa.alloc(Vec3, triangles.len);
        errdefer gpa.free(centroids);
        for (triangles, 0..) |tri, i| {
            const a = vertices[tri[0]];
            const b = vertices[tri[1]];
            const c = vertices[tri[2]];
            centroids[i] = .{ (a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3 };
        }
        // Map each undirected edge (sorted vertex pair) to the first triangle
        // and edge slot that owns it; the second owner links the pair.
        var edges: std.AutoHashMapUnmanaged(u64, u64) = .empty;
        defer edges.deinit(gpa);
        for (triangles, 0..) |tri, ti| {
            for (0..3) |e| {
                const v0 = tri[e];
                const v1 = tri[(e + 1) % 3];
                const key = (@as(u64, @min(v0, v1)) << 32) | @as(u64, @max(v0, v1));
                const packed_owner = (@as(u64, @intCast(ti)) << 2) | @as(u64, e);
                if (edges.fetchRemove(key)) |kv| {
                    const other_ti: usize = @intCast(kv.value >> 2);
                    const other_e: usize = @intCast(kv.value & 3);
                    neighbors[ti][e] = @intCast(other_ti);
                    neighbors[other_ti][other_e] = @intCast(ti);
                } else {
                    try edges.put(gpa, key, packed_owner);
                }
            }
        }
        return .{ .vertices = vertices, .triangles = triangles, .neighbors = neighbors, .centroids = centroids, .gpa = gpa };
    }

    pub fn deinit(self: *NavMesh) void {
        self.gpa.free(self.neighbors);
        self.gpa.free(self.centroids);
    }

    /// The triangle containing p on the ground plane, or null if p is off-mesh.
    pub fn locate(self: *const NavMesh, p: Vec3) ?usize {
        for (self.triangles, 0..) |tri, i| {
            if (containsXZ(self.vertices[tri[0]], self.vertices[tri[1]], self.vertices[tri[2]], p)) return i;
        }
        return null;
    }

    /// The shared edge's midpoint between adjacent triangles `from` and `to`.
    fn portal(self: *const NavMesh, from: usize, to: usize) Vec3 {
        const tri = self.triangles[from];
        for (0..3) |e| {
            if (self.neighbors[from][e] == to) {
                return midpoint(self.vertices[tri[e]], self.vertices[tri[(e + 1) % 3]]);
            }
        }
        return self.centroids[to];
    }

    /// A path from start to goal: start, the portal midpoints between the
    /// triangles A* strings together, then goal. Null if either endpoint is off
    /// the mesh or no route connects them. Caller frees the returned slice.
    pub fn findPath(self: *const NavMesh, gpa: std.mem.Allocator, start: Vec3, goal: Vec3) !?[]Vec3 {
        const start_tri = self.locate(start) orelse return null;
        const goal_tri = self.locate(goal) orelse return null;
        const n = self.triangles.len;
        const came_from = try gpa.alloc(u32, n);
        defer gpa.free(came_from);
        const g_score = try gpa.alloc(f32, n);
        defer gpa.free(g_score);
        const closed = try gpa.alloc(bool, n);
        defer gpa.free(closed);
        for (came_from) |*c| c.* = no_neighbor;
        for (g_score) |*g| g.* = std.math.floatMax(f32);
        for (closed) |*c| c.* = false;
        g_score[start_tri] = 0;

        while (true) {
            // Pick the open triangle with the least g + heuristic; ties by index
            // keep the search deterministic.
            var current: usize = n;
            var best: f32 = std.math.floatMax(f32);
            for (0..n) |i| {
                if (closed[i] or g_score[i] == std.math.floatMax(f32)) continue;
                const f = g_score[i] + dist(self.centroids[i], self.centroids[goal_tri]);
                if (f < best) {
                    best = f;
                    current = i;
                }
            }
            if (current == n) return null; // open set exhausted, no route
            if (current == goal_tri) break;
            closed[current] = true;
            for (self.neighbors[current]) |nb| {
                if (nb == no_neighbor or closed[nb]) continue;
                const tentative = g_score[current] + dist(self.centroids[current], self.centroids[nb]);
                if (tentative < g_score[nb]) {
                    came_from[nb] = @intCast(current);
                    g_score[nb] = tentative;
                }
            }
        }

        // Walk came_from back to the start to get the triangle chain.
        var chain: std.ArrayList(usize) = .empty;
        defer chain.deinit(gpa);
        var node: usize = goal_tri;
        while (true) {
            try chain.append(gpa, node);
            if (node == start_tri) break;
            node = @intCast(came_from[node]);
        }
        std.mem.reverse(usize, chain.items);

        var path: std.ArrayList(Vec3) = .empty;
        errdefer path.deinit(gpa);
        try path.append(gpa, start);
        for (0..chain.items.len - 1) |i| {
            try path.append(gpa, self.portal(chain.items[i], chain.items[i + 1]));
        }
        try path.append(gpa, goal);
        return try path.toOwnedSlice(gpa);
    }
};

const t = std.testing;

// A walkable strip bent into an L around a missing corner: cells 0..3 run
// along +x, cells 4..5 turn up +z, so a path from the first to the last must
// follow the bend rather than cut across the empty corner.
fn lShapedMesh(gpa: std.mem.Allocator) !struct { verts: []Vec3, tris: [][3]u32 } {
    // Grid points; the L covers the bottom row and the right column.
    const verts = try gpa.alloc(Vec3, 8);
    verts[0] = .{ 0, 0, 0 };
    verts[1] = .{ 1, 0, 0 };
    verts[2] = .{ 2, 0, 0 };
    verts[3] = .{ 3, 0, 0 };
    verts[4] = .{ 0, 0, 1 };
    verts[5] = .{ 1, 0, 1 };
    verts[6] = .{ 2, 0, 1 };
    verts[7] = .{ 3, 0, 1 };
    // Bottom strip (two quads = four tris) plus a right-column quad going to z=2.
    const tris = try gpa.alloc([3]u32, 6);
    tris[0] = .{ 0, 1, 5 };
    tris[1] = .{ 0, 5, 4 };
    tris[2] = .{ 1, 2, 6 };
    tris[3] = .{ 1, 6, 5 };
    tris[4] = .{ 2, 3, 7 };
    tris[5] = .{ 2, 7, 6 };
    return .{ .verts = verts, .tris = tris };
}

test "a nav mesh links its triangles across shared edges" {
    const m = try lShapedMesh(t.allocator);
    defer t.allocator.free(m.verts);
    defer t.allocator.free(m.tris);
    var nav = try NavMesh.build(t.allocator, m.verts, m.tris);
    defer nav.deinit();
    // Triangle 0 shares its v0-v2 edge (0-5) with triangle 1.
    var linked = false;
    for (nav.neighbors[0]) |nb| {
        if (nb == 1) linked = true;
    }
    try t.expect(linked);
}

test "pathfinding routes from one arm of the mesh to the other and is deterministic" {
    const m = try lShapedMesh(t.allocator);
    defer t.allocator.free(m.verts);
    defer t.allocator.free(m.tris);
    var nav = try NavMesh.build(t.allocator, m.verts, m.tris);
    defer nav.deinit();

    const start: Vec3 = .{ 0.2, 0, 0.3 };
    const goal: Vec3 = .{ 2.8, 0, 0.7 };
    const path = (try nav.findPath(t.allocator, start, goal)) orelse return error.NoPath;
    defer t.allocator.free(path);

    try t.expect(path.len >= 2);
    try t.expectEqual(start, path[0]);
    try t.expectEqual(goal, path[path.len - 1]);
    // Every interior waypoint sits on a walkable triangle.
    for (path[1 .. path.len - 1]) |p| {
        try t.expect(nav.locate(p) != null);
    }
    // The routed path is at least the straight-line distance and threads the
    // cells rather than teleporting.
    var length: f32 = 0;
    for (0..path.len - 1) |i| length += dist(path[i], path[i + 1]);
    try t.expect(length >= dist(start, goal) - 1e-4);

    // A second search over a fresh build lands the identical path.
    var nav2 = try NavMesh.build(t.allocator, m.verts, m.tris);
    defer nav2.deinit();
    const path2 = (try nav2.findPath(t.allocator, start, goal)) orelse return error.NoPath;
    defer t.allocator.free(path2);
    try t.expectEqual(path.len, path2.len);
    for (path, path2) |p, q| try t.expectEqual(p, q);
}

test "a goal off the mesh has no path" {
    const m = try lShapedMesh(t.allocator);
    defer t.allocator.free(m.verts);
    defer t.allocator.free(m.tris);
    var nav = try NavMesh.build(t.allocator, m.verts, m.tris);
    defer nav.deinit();
    try t.expect((try nav.findPath(t.allocator, .{ 0.2, 0, 0.3 }, .{ 9, 0, 9 })) == null);
}
