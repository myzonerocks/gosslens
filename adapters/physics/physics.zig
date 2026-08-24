//! The rigid-body world for lens content: Jolt behind a C shim, fixed
//! 60 Hz stepping for determinism, poses read back as column-major
//! transforms ready for the model draw path.

const std = @import("std");

/// Whether a real backend exists on this target.
pub const supported = true;

pub const Shape = enum(u32) {
    box = 0,
    sphere = 1,
};

pub const Motion = enum(u32) {
    static = 0,
    dynamic = 1,
    /// The engine drives its pose each step; chained bodies follow.
    kinematic = 2,
};

pub const invalid_body: u32 = std.math.maxInt(u32);

extern fn goss_physics_world_create(gravity_y: f32) ?*anyopaque;
extern fn goss_physics_world_destroy(handle: *anyopaque) void;
extern fn goss_physics_body_add(handle: *anyopaque, shape: u32, px: f32, py: f32, pz: f32, sx: f32, sy: f32, sz: f32, motion: u32) u32;
extern fn goss_physics_step(handle: *anyopaque, dt_seconds: f32) void;
extern fn goss_physics_body_pose(handle: *anyopaque, body: u32, out: *[16]f32) i32;
extern fn goss_physics_constrain_distance(handle: *anyopaque, a: u32, b: u32, ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32, min: f32, max: f32) i32;
extern fn goss_physics_constrain_point(handle: *anyopaque, a: u32, b: u32, ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32) i32;
extern fn goss_physics_constrain_fixed(handle: *anyopaque, a: u32, b: u32) i32;
extern fn goss_physics_constrain_hinge(handle: *anyopaque, a: u32, b: u32, px: f32, py: f32, pz: f32, hx: f32, hy: f32, hz: f32) i32;
extern fn goss_physics_constrain_spring(handle: *anyopaque, a: u32, b: u32, ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32, rest_length: f32, frequency: f32, damping: f32) i32;
extern fn goss_physics_body_move(handle: *anyopaque, body: u32, px: f32, py: f32, pz: f32, dt: f32) void;
extern fn goss_physics_add_cloth(handle: *anyopaque, cols: u32, rows: u32, width: f32, height: f32, px: f32, py: f32, pz: f32) u32;
extern fn goss_physics_cloth_read(handle: *anyopaque, body: u32, out: [*]f32, max_vertices: u32) u32;
extern fn goss_physics_add_hair(handle: *anyopaque, strand_count: u32, verts: u32, length: f32) u32;
extern fn goss_physics_hair_update(handle: *anyopaque, hair_id: u32, head_transform: [*]const f32, dt: f32) void;
extern fn goss_physics_hair_read(handle: *anyopaque, hair_id: u32, out: [*]f32, max_vertices: u32) u32;

pub const World = struct {
    handle: *anyopaque,

    pub fn create(gravity_y: f32) !World {
        return .{ .handle = goss_physics_world_create(gravity_y) orelse return error.WorldCreateFailed };
    }

    pub fn destroy(world: World) void {
        goss_physics_world_destroy(world.handle);
    }

    /// Half extents size a box; a sphere reads its radius from size[0].
    pub fn addBody(world: World, shape: Shape, position: [3]f32, size: [3]f32, motion: Motion) !u32 {
        const id = goss_physics_body_add(world.handle, @intFromEnum(shape), position[0], position[1], position[2], size[0], size[1], size[2], @intFromEnum(motion));
        if (id == invalid_body) return error.BodyAddFailed;
        return id;
    }

    /// Accumulates dt into fixed 60 Hz substeps - the determinism
    /// contract: the same dt sequence always lands the same poses.
    pub fn step(world: World, dt_seconds: f32) void {
        goss_physics_step(world.handle, dt_seconds);
    }

    /// Links two bodies with a distance constraint between local attach
    /// points - the chain link for content hanging off an anchor.
    pub fn constrainDistance(world: World, a: u32, b: u32, point_a: [3]f32, point_b: [3]f32, min: f32, max: f32) !void {
        if (goss_physics_constrain_distance(world.handle, a, b, point_a[0], point_a[1], point_a[2], point_b[0], point_b[1], point_b[2], min, max) != 0) return error.ConstraintFailed;
    }

    /// Pins two bodies at a single point (a ball joint): the point stays
    /// coincident while the bodies rotate freely about it - a pendulum pivot,
    /// unlike a distance constraint that only bounds separation.
    pub fn constrainPoint(world: World, a: u32, b: u32, point_a: [3]f32, point_b: [3]f32) !void {
        if (goss_physics_constrain_point(world.handle, a, b, point_a[0], point_a[1], point_a[2], point_b[0], point_b[1], point_b[2]) != 0) return error.ConstraintFailed;
    }

    /// Welds two bodies together rigidly at their current relative pose (a
    /// fixed joint): no relative translation or rotation, so the body rides its
    /// anchor, unlike a point joint that lets it swing.
    pub fn constrainFixed(world: World, a: u32, b: u32) !void {
        if (goss_physics_constrain_fixed(world.handle, a, b) != 0) return error.ConstraintFailed;
    }

    /// Hinges two bodies at a world pivot about an axis: the body swings in the
    /// one plane perpendicular to the axis (a door or single-axis pendulum),
    /// unlike a point joint that swings every way.
    pub fn constrainHinge(world: World, a: u32, b: u32, pivot: [3]f32, axis: [3]f32) !void {
        if (goss_physics_constrain_hinge(world.handle, a, b, pivot[0], pivot[1], pivot[2], axis[0], axis[1], axis[2]) != 0) return error.ConstraintFailed;
    }

    /// Tethers two bodies with a spring held at rest_length (frequency in
    /// Hz, damping 0..1): it stretches under load and bobs back, unlike the
    /// rigid distance chain.
    pub fn constrainSpring(world: World, a: u32, b: u32, point_a: [3]f32, point_b: [3]f32, rest_length: f32, frequency: f32, damping: f32) !void {
        if (goss_physics_constrain_spring(world.handle, a, b, point_a[0], point_a[1], point_a[2], point_b[0], point_b[1], point_b[2], rest_length, frequency, damping) != 0) return error.ConstraintFailed;
    }

    /// Drives a kinematic body toward a pose over dt; chained bodies
    /// swing after it.
    pub fn moveBody(world: World, body: u32, position: [3]f32, dt_seconds: f32) void {
        goss_physics_body_move(world.handle, body, position[0], position[1], position[2], dt_seconds);
    }

    /// Adds a pinned-top cloth grid; its deformed vertices drive a mesh.
    pub fn addCloth(world: World, cols: u32, rows: u32, width: f32, height: f32, position: [3]f32) !u32 {
        const id = goss_physics_add_cloth(world.handle, cols, rows, width, height, position[0], position[1], position[2]);
        if (id == invalid_body) return error.BodyAddFailed;
        return id;
    }

    /// Reads the cloth's deformed world-space vertices (3 floats each)
    /// into out; returns the vertex count.
    pub fn clothRead(world: World, body: u32, out: []f32) u32 {
        return goss_physics_cloth_read(world.handle, body, out.ptr, @intCast(out.len / 3));
    }

    /// Adds a clump of strand_count strands, each `verts` long and
    /// `length` metres, rooted near the head. Returns a hair id.
    pub fn addHair(world: World, strand_count: u32, verts: u32, length: f32) !u32 {
        const id = goss_physics_add_hair(world.handle, strand_count, verts, length);
        if (id == invalid_body) return error.BodyAddFailed;
        return id;
    }

    /// Moves the hair with the head (translation from the 16-float
    /// column-major transform) and steps it; the tips swing.
    pub fn hairUpdate(world: World, hair_id: u32, head_transform: [16]f32, dt_seconds: f32) void {
        goss_physics_hair_update(world.handle, hair_id, &head_transform, dt_seconds);
    }

    /// Reads simulated strand vertices (3 floats each); returns count.
    pub fn hairRead(world: World, hair_id: u32, out: []f32) u32 {
        return goss_physics_hair_read(world.handle, hair_id, out.ptr, @intCast(out.len / 3));
    }

    /// The body's column-major world transform.
    pub fn bodyPose(world: World, body: u32) ![16]f32 {
        var out: [16]f32 = undefined;
        if (goss_physics_body_pose(world.handle, body, &out) != 0) return error.BodyPoseFailed;
        return out;
    }
};

const t = std.testing;

test "a dropped sphere comes to rest on the floor" {
    const world = try World.create(-9.81);
    defer world.destroy();
    _ = try world.addBody(.box, .{ 0, -0.5, 0 }, .{ 10, 0.5, 10 }, .static);
    const ball = try world.addBody(.sphere, .{ 0, 3.0, 0 }, .{ 0.25, 0, 0 }, .dynamic);

    for (0..240) |_| world.step(1.0 / 60.0);
    const pose = try world.bodyPose(ball);
    // Resting height: floor top (0) plus the radius, less the solver's
    // documented penetration slop (0.02 by default).
    try t.expectApproxEqAbs(@as(f32, 0.25), pose[13], 0.03);
}

test "a point joint pins a body to its pivot instead of letting it fall" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const anchor = try world.addBody(.sphere, .{ 0, 2.0, 0 }, .{ 0.1, 0, 0 }, .static);
    const hung = try world.addBody(.sphere, .{ 0, 2.0, 0 }, .{ 0.1, 0, 0 }, .dynamic);
    try world.constrainPoint(anchor, hung, .{ 0, 0, 0 }, .{ 0, 0, 0 });

    for (0..240) |_| world.step(1.0 / 60.0);
    const pose = try world.bodyPose(hung);
    // The pivot pins its centre of mass at the anchor, so it never falls the
    // way an unconstrained body under -9.81 gravity would over four seconds.
    try t.expectApproxEqAbs(@as(f32, 2.0), pose[13], 0.05);
}

test "a point joint holds against a kinematic anchor" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const anchor = try world.addBody(.box, .{ 0, 2.0, 0 }, .{ 0.05, 0.05, 0.05 }, .kinematic);
    const hung = try world.addBody(.sphere, .{ 0, 2.0, 0 }, .{ 0.1, 0, 0 }, .dynamic);
    try world.constrainPoint(anchor, hung, .{ 0, 0, 0 }, .{ 0, 0, 0 });
    for (0..240) |_| world.step(1.0 / 60.0);
    const pose = try world.bodyPose(hung);
    // A kinematic anchor pins the constraint the same as a static one; the
    // body must not free-fall away from y = 2.
    try t.expectApproxEqAbs(@as(f32, 2.0), pose[13], 0.05);
}

test "a hinge joint swings a body in one plane about its axis" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const anchor = try world.addBody(.box, .{ 0, 2.0, 0 }, .{ 0.05, 0.05, 0.05 }, .kinematic);
    // The pendant starts out along +x in the anchor's z = 0 plane; a z-axis
    // hinge lets it swing down in that plane but pins its depth so it never
    // leaves z = 0 (rotation about z preserves the depth coordinate).
    const pend = try world.addBody(.sphere, .{ 0.5, 2.0, 0 }, .{ 0.08, 0, 0 }, .dynamic);
    try world.constrainHinge(anchor, pend, .{ 0, 2.0, 0 }, .{ 0, 0, 1 });

    for (0..240) |_| world.step(1.0 / 60.0);
    const p = try world.bodyPose(pend);
    // The hinge pins the depth exactly to its plane (z stays 0, the distinctive
    // single-axis behavior), and the pendant swings down under gravity within
    // its swing radius about the pivot.
    try t.expectApproxEqAbs(@as(f32, 0.0), p[14], 0.01);
    try t.expect(p[13] < 1.9);
    try t.expect(@abs(p[12]) <= 0.55);
}

test "a fixed joint welds a body rigidly to its anchor" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const anchor = try world.addBody(.box, .{ 0, 2.0, 0 }, .{ 0.05, 0.05, 0.05 }, .static);
    // The dynamic body sits offset from the anchor; a fixed joint must hold
    // that exact offset (no swing toward the anchor, no fall under gravity).
    const welded = try world.addBody(.sphere, .{ 0.5, 2.0, 0 }, .{ 0.1, 0, 0 }, .dynamic);
    try world.constrainFixed(anchor, welded);

    for (0..240) |_| world.step(1.0 / 60.0);
    const pose = try world.bodyPose(welded);
    try t.expectApproxEqAbs(@as(f32, 0.5), pose[12], 0.05); // keeps its x offset
    try t.expectApproxEqAbs(@as(f32, 2.0), pose[13], 0.05); // does not fall
}

test "a spring joint stretches under gravity and settles below its rest length" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const anchor = try world.addBody(.box, .{ 0, 2.0, 0 }, .{ 0.05, 0.05, 0.05 }, .kinematic);
    // The pendant starts exactly a rest length (0.5) below the anchor. A rigid
    // rope would hold it there; the spring is soft, so gravity stretches it and
    // it settles below that rest position, hanging straight down.
    const pend = try world.addBody(.sphere, .{ 0, 1.5, 0 }, .{ 0.08, 0, 0 }, .dynamic);
    try world.constrainSpring(anchor, pend, .{ 0, 0, 0 }, .{ 0, 0, 0 }, 0.5, 2.0, 0.5);

    for (0..240) |_| world.step(1.0 / 60.0);
    const p = try world.bodyPose(pend);
    // Stretched below the 1.5 rest position, but bounded by the spring (not a
    // free fall), and hanging straight under the anchor.
    try t.expect(p[13] < 1.48);
    try t.expect(p[13] > 1.30);
    try t.expect(@abs(p[12]) < 0.05);
    try t.expect(@abs(p[14]) < 0.05);
}

test "two identical worlds land bit-identical poses" {
    var poses: [2][16]f32 = undefined;
    for (0..2) |run| {
        const world = try World.create(-9.81);
        defer world.destroy();
        _ = try world.addBody(.box, .{ 0, -0.5, 0 }, .{ 10, 0.5, 10 }, .static);
        const ball = try world.addBody(.sphere, .{ 0.3, 2.0, -0.1 }, .{ 0.2, 0, 0 }, .dynamic);
        for (0..90) |_| world.step(1.0 / 60.0);
        poses[run] = try world.bodyPose(ball);
    }
    try t.expectEqualSlices(f32, &poses[0], &poses[1]);
}

test "a chained pendant follows a moved kinematic anchor" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const anchor = try world.addBody(.sphere, .{ 0, 1.0, 0 }, .{ 0.02, 0, 0 }, .kinematic);
    const pendant = try world.addBody(.sphere, .{ 0, 0.9, 0 }, .{ 0.03, 0, 0 }, .dynamic);
    try world.constrainDistance(anchor, pendant, .{ 0, 0, 0 }, .{ 0, 0, 0 }, 0.0, 0.1);
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        const x = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.08);
        world.moveBody(anchor, .{ x, 1.0, 0 }, 1.0 / 60.0);
        world.step(1.0 / 60.0);
    }
    const anchor_pose = try world.bodyPose(anchor);
    const pendant_pose = try world.bodyPose(pendant);
    // The pendant hangs below the anchor within the chain length.
    try t.expect(pendant_pose[13] <= anchor_pose[13]);
    const dx = pendant_pose[12] - anchor_pose[12];
    const dy = pendant_pose[13] - anchor_pose[13];
    try t.expect(@sqrt(dx * dx + dy * dy) <= 0.16);
}

test "a pinned cloth grid drapes and reads back deformed vertices" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const cloth = try world.addCloth(6, 6, 1.0, 1.0, .{ 0, 0, 0 });
    var i: usize = 0;
    while (i < 180) : (i += 1) world.step(1.0 / 60.0);
    var verts: [36 * 3]f32 = undefined;
    const n = world.clothRead(cloth, &verts);
    try t.expectEqual(@as(u32, 36), n);
    // Top-row centre stays high, bottom-row centre has draped below.
    const top_y = verts[(30 + 3) * 3 + 1];
    const bottom_y = verts[(0 + 3) * 3 + 1];
    try t.expect(top_y - bottom_y > 0.3);
}

test "a hair clump hangs and reads back strand vertices" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const hair = try world.addHair(2, 16, 0.5);
    var i: usize = 0;
    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    while (i < 60) : (i += 1) world.hairUpdate(hair, identity, 1.0 / 60.0);
    var verts: [128 * 3]f32 = undefined;
    const n = world.hairRead(hair, &verts);
    try t.expect(n > 0);
    // Some tip vertex hangs below the pinned root region.
    var min_y: f32 = 1e9;
    for (0..n) |v| min_y = @min(min_y, verts[v * 3 + 1]);
    try t.expect(min_y < 0.4);
}
