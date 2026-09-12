//! Spatial semantics and the questions asked of them. A plane's classification
//! was an opaque number every consumer decoded for itself; here it is a named
//! channel with an agreed meaning. On top of that sit the queries an agent
//! actually asks before it tells a person where to put something: does this
//! fit, how much of this surface is free, how high is it off the floor.

const std = @import("std");

/// What a detected plane is. The platforms agree on more than their enums
/// suggest, and a consumer that wants "a surface I can put something on" should
/// ask that rather than matching a list of integers.
pub const PlaneKind = enum(u32) {
    unknown = 0,
    floor = 1,
    wall = 2,
    ceiling = 3,
    table = 4,
    seat = 5,
    door = 6,
    window = 7,
    screen = 8,

    /// Whether an object can rest on this. A table and a floor can hold a cup;
    /// a wall and a door cannot, whatever their orientation says.
    pub fn bearing(k: PlaneKind) bool {
        return switch (k) {
            .floor, .table, .seat => true,
            else => false,
        };
    }

    /// Whether this is a vertical surface something hangs on or shows on.
    pub fn vertical(k: PlaneKind) bool {
        return switch (k) {
            .wall, .door, .window, .screen => true,
            else => false,
        };
    }
};

/// A plane in world space. The pose's fourth column is its centre and its
/// second column is its normal, the convention every platform's plane anchor
/// already uses.
pub const Plane = struct {
    id: u64,
    pose: [16]f32,
    extent_x: f32,
    extent_z: f32,
    kind: PlaneKind,

    pub fn centre(p: Plane) [3]f32 {
        return .{ p.pose[12], p.pose[13], p.pose[14] };
    }

    pub fn normal(p: Plane) [3]f32 {
        return .{ p.pose[4], p.pose[5], p.pose[6] };
    }

    pub fn area(p: Plane) f32 {
        return p.extent_x * p.extent_z;
    }

    /// Height above a floor plane, which is what makes "the table" different
    /// from "the floor" to anything deciding where a thing goes.
    pub fn heightAbove(p: Plane, floor: Plane) f32 {
        return p.centre()[1] - floor.centre()[1];
    }
};

/// A footprint to place, in metres. Height is what decides whether it fits
/// under a shelf, so it is asked for even when the answer is a flat surface.
pub const Footprint = struct {
    width: f32,
    depth: f32,
    height: f32 = 0,
};

pub const Placement = struct {
    plane_id: u64,
    /// Where on the plane, in world space.
    position: [3]f32,
    /// How much of the plane is still free afterwards, as a fraction, so a
    /// caller can prefer the surface that stays usable.
    free_fraction: f32,
};

/// Anything already on a plane, so a placement query answers about the surface
/// as it is rather than as it was when it was detected.
pub const Occupant = struct {
    plane_id: u64,
    /// Centre on the plane's own axes, metres from its centre.
    x: f32,
    z: f32,
    width: f32,
    depth: f32,
};

/// Where this footprint can go. Answers the bearing plane with the most room
/// left afterwards, because a caller asking "where does this fit" wants the
/// answer that keeps the room usable, not the first surface that technically
/// holds it.
pub fn placeOn(planes: []const Plane, occupants: []const Occupant, item: Footprint, out: []Placement) usize {
    var found: usize = 0;
    for (planes) |p| {
        if (found >= out.len) break;
        if (!p.kind.bearing()) continue;
        if (item.width > p.extent_x or item.depth > p.extent_z) continue;

        var taken: f32 = 0;
        for (occupants) |o| {
            if (o.plane_id != p.id) continue;
            taken += o.width * o.depth;
        }
        const total = p.area();
        if (total <= 0) continue;
        const free = @max(0, total - taken);
        if (free < item.width * item.depth) continue;

        const centre = p.centre();
        out[found] = .{
            .plane_id = p.id,
            .position = centre,
            .free_fraction = @max(0, (free - item.width * item.depth) / total),
        };
        found += 1;
    }
    // The surface that stays most usable comes first.
    std.mem.sortUnstable(Placement, out[0..found], {}, freeDesc);
    return found;
}

fn freeDesc(_: void, a: Placement, b: Placement) bool {
    return a.free_fraction > b.free_fraction;
}

/// The free area of one plane in square metres, which is the question behind
/// "is there room" when the thing being placed is not yet decided.
pub fn freeArea(plane: Plane, occupants: []const Occupant) f32 {
    var taken: f32 = 0;
    for (occupants) |o| {
        if (o.plane_id != plane.id) continue;
        taken += o.width * o.depth;
    }
    return @max(0, plane.area() - taken);
}

/// The floor, if one was detected: the lowest bearing plane large enough to be
/// a floor rather than a stool. Height questions are meaningless without it, so
/// it is found once and asked for by name.
pub fn floorOf(planes: []const Plane) ?Plane {
    var best: ?Plane = null;
    for (planes) |p| {
        if (p.kind != .floor) continue;
        if (best == null or p.centre()[1] < best.?.centre()[1]) best = p;
    }
    return best;
}

const testing = std.testing;

fn planeAt(id: u64, kind: PlaneKind, y: f32, x: f32, z: f32) Plane {
    var pose: [16]f32 = @splat(0);
    pose[0] = 1;
    pose[5] = 1;
    pose[10] = 1;
    pose[15] = 1;
    pose[13] = y;
    return .{ .id = id, .pose = pose, .extent_x = x, .extent_z = z, .kind = kind };
}

test "a plane's kind says what can be done with it, not just what it is" {
    try testing.expect(PlaneKind.table.bearing());
    try testing.expect(PlaneKind.floor.bearing());
    // A door is vertical and a seat is not, whatever either normal reads.
    try testing.expect(!PlaneKind.door.bearing());
    try testing.expect(PlaneKind.door.vertical());
    try testing.expect(!PlaneKind.seat.vertical());
    try testing.expect(!PlaneKind.unknown.bearing());
}

test "placement prefers the surface that stays usable" {
    const planes = [_]Plane{
        planeAt(1, .floor, 0, 4, 4),
        planeAt(2, .table, 0.75, 1.2, 0.8),
        planeAt(3, .wall, 1.5, 3, 2.5),
    };
    // The table already holds most of itself.
    const occupants = [_]Occupant{
        .{ .plane_id = 2, .x = 0, .z = 0, .width = 1.0, .depth = 0.7 },
    };
    var out: [4]Placement = undefined;
    const n = placeOn(&planes, &occupants, .{ .width = 0.1, .depth = 0.1 }, &out);
    // The wall is not a candidate at all, and the floor has more room left.
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 1), out[0].plane_id);
    try testing.expect(out[0].free_fraction > out[1].free_fraction);

    // Something larger than the table only fits on the floor.
    const big = placeOn(&planes, &occupants, .{ .width = 2, .depth = 2 }, &out);
    try testing.expectEqual(@as(usize, 1), big);
    try testing.expectEqual(@as(u64, 1), out[0].plane_id);

    // And something larger than everything fits nowhere, which is an answer.
    try testing.expectEqual(@as(usize, 0), placeOn(&planes, &occupants, .{ .width = 9, .depth = 9 }, &out));
}

test "height is measured against the floor, and free area against what is on it" {
    const planes = [_]Plane{
        planeAt(1, .floor, 0, 4, 4),
        planeAt(2, .table, 0.75, 1.2, 0.8),
    };
    const floor = floorOf(&planes).?;
    try testing.expectEqual(@as(u64, 1), floor.id);
    try testing.expectApproxEqAbs(@as(f32, 0.75), planes[1].heightAbove(floor), 1e-6);

    const occupants = [_]Occupant{
        .{ .plane_id = 2, .x = 0, .z = 0, .width = 0.5, .depth = 0.4 },
    };
    try testing.expectApproxEqAbs(@as(f32, 0.96 - 0.2), freeArea(planes[1], &occupants), 1e-5);
    // An occupant of another plane does not count against this one.
    try testing.expectApproxEqAbs(@as(f32, 16), freeArea(planes[0], &occupants), 1e-4);

    // No floor detected is null rather than a guess at one.
    const roomless = [_]Plane{planeAt(2, .table, 0.75, 1.2, 0.8)};
    try testing.expect(floorOf(&roomless) == null);
}

pub const anchors = @import("anchors.zig");
pub const measure = @import("measure.zig");
pub const Anchor = anchors.Anchor;
pub const AnchorStore = anchors.Store;

test {
    std.testing.refAllDecls(@This());
}
