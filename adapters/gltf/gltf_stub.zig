//! Stub glTF decode types for targets with no real cgltf wiring (web):
//! provides the same shapes core/abi's model.gltf dispatch references
//! so it type-checks on every target, decode always fails closed.
//! Directory-based lens activation - the only path that could ever
//! reach a model loader - already refuses with the same has_file_io
//! gate before this would ever be reached. Kept in lockstep with the
//! real adapters/gltf/gltf.zig so `zig build wasm` cannot silently drift.

const std = @import("std");
const math = @import("math");

pub const Error = error{ OutOfMemory, MalformedAsset, UnsupportedAsset, ExternalReference };

pub const AnimationPath = enum { translation, rotation, scale };

pub const DecodedAnimChannel = struct {
    path: AnimationPath,
    times: []f32,
    values: []f32,
};

/// One sampled pose, matching the real decoder so the blend path lowers.
pub const Components = struct {
    translation: math.Vec3 = .{ 0, 0, 0 },
    rotation: math.Quat = math.Quat.identity,
    scale: math.Vec3 = .{ 1, 1, 1 },

    pub fn toMatrix(pose: Components) math.Mat4 {
        return math.Mat4.mul(math.Mat4.mul(math.Mat4.translation(pose.translation), pose.rotation.toMat4()), math.Mat4.scaling(pose.scale));
    }
};

pub fn blendComponents(clips: []const Components, weights: []const f32) Components {
    _ = weights;
    return if (clips.len == 0) .{} else clips[0];
}

pub const DecodedAnimation = struct {
    duration_seconds: f32,
    channels: []DecodedAnimChannel,

    pub fn sampleComponents(anim: *const DecodedAnimation, elapsed_seconds: f32) Components {
        _ = anim;
        _ = elapsed_seconds;
        return .{};
    }

    pub fn sample(anim: *const DecodedAnimation, elapsed_seconds: f32) math.Mat4 {
        _ = anim;
        _ = elapsed_seconds;
        return math.Mat4.identity;
    }
};

pub const DecodedSkin = struct {
    joint_count: u32,
    inverse_bind: []math.Mat4,
    joint_names: [][]const u8,
    vertex_joints: [][4]u16,
    vertex_weights: [][4]f32,
};

pub const DecodedModel = struct {
    positions: [][3]f32,
    indices: []u32,
    base_color: [4]f32,
    animations: []DecodedAnimation,
    skin: ?DecodedSkin = null,
    morph_targets: []const []const [3]f32 = &.{},
    morph_names: []const []const u8 = &.{},
};

pub fn decodeModel(gpa: std.mem.Allocator, bytes: []const u8) Error!DecodedModel {
    _ = gpa;
    _ = bytes;
    return error.UnsupportedAsset;
}

pub fn freeDecodedModel(gpa: std.mem.Allocator, model: DecodedModel) void {
    _ = gpa;
    _ = model;
}

pub fn freeAnimation(gpa: std.mem.Allocator, anim: *const DecodedAnimation) void {
    _ = gpa;
    _ = anim;
}

pub fn freeAnimations(gpa: std.mem.Allocator, anims: []DecodedAnimation) void {
    _ = gpa;
    _ = anims;
}

pub fn freeMorphTargets(gpa: std.mem.Allocator, targets: []const []const [3]f32) void {
    _ = gpa;
    _ = targets;
}

pub fn freeSkin(gpa: std.mem.Allocator, skin: *const DecodedSkin) void {
    _ = gpa;
    _ = skin;
}
