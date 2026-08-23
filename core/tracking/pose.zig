//! Pose pipeline geometry: how a pose detection or a previous frame's
//! auxiliary landmarks become the aligned crop the landmark model reads.
//! The constants mirror the pinned model's task graphs; the crop centers
//! on one alignment point and scales off its distance to the second.

const std = @import("std");
const sampler = @import("sampler");
const detector = @import("detector");

/// The published skeleton. The raw model emits 39 points - these 33
/// plus six auxiliary alignment points that only steer the crop.
pub const landmark_count = 33;
/// The most bodies a caller can drive through the multi-person submit path.
pub const max_bodies = 4;
pub const raw_landmark_count = 39;
/// x, y, z, visibility, presence per raw landmark.
pub const raw_values_per_landmark = 5;

pub const Landmark = sampler.Landmark;

/// The crop points the body up: the steering segment's target angle is
/// a quarter turn, same convention as the hand pipeline.
const target_angle = std.math.pi * 0.5;
const region_scale = 1.25;
/// Detection keypoints: the body center and the full-body scale point.
const center_keypoint = 0;
const scale_keypoint = 1;
/// The same pair as raw landmark indices once tracking holds.
const aux_center_landmark = 33;
const aux_scale_landmark = 34;

/// One published pose result, the shape that crosses the C boundary.
/// Landmarks are x, y in frame pixels with z in the same scale;
/// visibility and presence are zero-to-one scores per point. A zero
/// landmark count means the frame held no body. The layout is frozen.
pub const Result = extern struct {
    frame_serial: u64,
    timestamp_us: i64,
    presence: f32,
    landmark_count_out: u32,
    landmarks: [landmark_count * 3]f32,
    visibilities: [landmark_count]f32,
    presences: [landmark_count]f32,
};

comptime {
    std.debug.assert(@offsetOf(Result, "landmarks") == 24);
    // 24 + 33*5*4 = 684 payload bytes, padded to the struct's own
    // 8-byte alignment.
    std.debug.assert(@sizeOf(Result) == 688);
}

/// Named attach points on the tracked body skeleton, so a lens can pin
/// content to a shoulder, a wrist, or a knee without knowing the mesh
/// indices. The left/right labels are the subject's own.
pub const Joint = enum(u32) {
    head = 0,
    left_shoulder = 1,
    right_shoulder = 2,
    left_elbow = 3,
    right_elbow = 4,
    left_wrist = 5,
    right_wrist = 6,
    left_hip = 7,
    right_hip = 8,
    left_knee = 9,
    right_knee = 10,
    left_ankle = 11,
    right_ankle = 12,

    pub fn fromU32(value: u32) ?Joint {
        return switch (value) {
            0...12 => @enumFromInt(value),
            else => null,
        };
    }
};

/// The skeleton landmark each joint resolves to, in the model's own order.
const joint_landmark = [_]u16{ 0, 11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28 };

/// The tracked point for a joint: x, y in frame pixels and z in the same
/// scale, read straight from the pose landmarks (the flat [count*3] array a
/// pose result carries).
pub fn jointPoint(landmarks: *const [landmark_count * 3]f32, joint: Joint) [3]f32 {
    const base = @as(usize, joint_landmark[@intFromEnum(joint)]) * 3;
    return .{ landmarks[base], landmarks[base + 1], landmarks[base + 2] };
}

/// A named bone a lens can trigger on by its bend angle: the angle at the
/// middle joint of a three-point limb chain. Zero is fully folded, pi is
/// straight. The left/right labels are the subject's own.
pub const Bone = enum(u8) {
    left_elbow = 0,
    right_elbow = 1,
    left_knee = 2,
    right_knee = 3,
    left_shoulder = 4,
    right_shoulder = 5,
    left_hip = 6,
    right_hip = 7,

    pub fn fromU8(value: u8) ?Bone {
        return switch (value) {
            0...7 => @enumFromInt(value),
            else => null,
        };
    }
};

pub const bone_count = 8;

/// Each bone is the landmark triple (endpoint, vertex, endpoint); the angle
/// is measured at the vertex between the two endpoints.
const bone_joints = [bone_count][3]u16{
    .{ 11, 13, 15 },
    .{ 12, 14, 16 },
    .{ 23, 25, 27 },
    .{ 24, 26, 28 },
    .{ 13, 11, 23 },
    .{ 14, 12, 24 },
    .{ 11, 23, 25 },
    .{ 12, 24, 26 },
};

const bone_names = [bone_count][]const u8{
    "left_elbow",    "right_elbow", "left_knee", "right_knee",
    "left_shoulder", "right_shoulder", "left_hip", "right_hip",
};

/// The index of a bone by name, for the trigger grammar; null if unknown.
pub fn boneIndex(name: []const u8) ?u8 {
    for (bone_names, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) return @intCast(i);
    }
    return null;
}

fn landmarkPoint(landmarks: *const [landmark_count * 3]f32, index: u16) [3]f32 {
    const base = @as(usize, index) * 3;
    return .{ landmarks[base], landmarks[base + 1], landmarks[base + 2] };
}

/// The bend angle at a bone's vertex, in radians [0, pi]. A degenerate limb
/// with a zero-length segment reads zero rather than a NaN.
pub fn boneAngle(landmarks: *const [landmark_count * 3]f32, bone: Bone) f32 {
    const j = bone_joints[@intFromEnum(bone)];
    const a = landmarkPoint(landmarks, j[0]);
    const v = landmarkPoint(landmarks, j[1]);
    const b = landmarkPoint(landmarks, j[2]);
    const va = [3]f32{ a[0] - v[0], a[1] - v[1], a[2] - v[2] };
    const vb = [3]f32{ b[0] - v[0], b[1] - v[1], b[2] - v[2] };
    const dot = va[0] * vb[0] + va[1] * vb[1] + va[2] * vb[2];
    const la = @sqrt(va[0] * va[0] + va[1] * va[1] + va[2] * va[2]);
    const lb = @sqrt(vb[0] * vb[0] + vb[1] * vb[1] + vb[2] * vb[2]);
    if (la == 0 or lb == 0) return 0;
    const cosang = std.math.clamp(dot / (la * lb), -1.0, 1.0);
    return std.math.acos(cosang);
}

/// Fills out with every bone's current bend angle, in Bone order.
pub fn fillBoneAngles(landmarks: *const [landmark_count * 3]f32, out: *[bone_count]f32) void {
    var i: u8 = 0;
    while (i < bone_count) : (i += 1) {
        out[i] = boneAngle(landmarks, @enumFromInt(i));
    }
}

fn handUpRotation(dx: f32, dy: f32) f32 {
    return normalizeRadians(target_angle - std.math.atan2(-dy, dx));
}

fn normalizeRadians(angle: f32) f32 {
    return angle - 2.0 * std.math.pi * @floor((angle + std.math.pi) / (2.0 * std.math.pi));
}

fn alignedRegion(center_x: f32, center_y: f32, scale_x: f32, scale_y: f32) sampler.Region {
    const dx = scale_x - center_x;
    const dy = scale_y - center_y;
    // The box side is double the center-to-scale-point distance, the
    // whole body with headroom, scaled like the shipped graph's rect.
    const side = @sqrt(dx * dx + dy * dy) * 2.0;
    return .{
        .center_x = center_x,
        .center_y = center_y,
        .side = side * region_scale,
        .rotation = handUpRotation(dx, dy),
    };
}

/// The aligned landmark crop for a fresh pose detection, in frame
/// pixels. Detection coordinates are normalized to the detector's
/// input square.
pub fn regionFromDetection(detection: detector.pose.Detection, square: sampler.Region) sampler.Region {
    const center_u = detection.keypoints[center_keypoint][0];
    const center_v = detection.keypoints[center_keypoint][1];
    const scale_u = detection.keypoints[scale_keypoint][0];
    const scale_v = detection.keypoints[scale_keypoint][1];
    return alignedRegion(
        square.center_x + (center_u - 0.5) * square.side,
        square.center_y + (center_v - 0.5) * square.side,
        square.center_x + (scale_u - 0.5) * square.side,
        square.center_y + (scale_v - 0.5) * square.side,
    );
}

/// The next frame's crop from this frame's auxiliary landmarks - the
/// raw output's alignment pair, decoded to frame pixels like the rest.
pub fn regionFromLandmarks(raw_landmarks: *const [raw_landmark_count]Landmark) sampler.Region {
    const center = raw_landmarks[aux_center_landmark];
    const scale = raw_landmarks[aux_scale_landmark];
    return alignedRegion(center.x, center.y, scale.x, scale.y);
}

/// Maps the landmark model's raw output back into frame pixels. The
/// model emits five values per point in crop input pixels; x, y, z map
/// through the crop like every other pipeline, visibility and presence
/// pass through as scores (already sigmoid in the model).
pub fn decodeLandmarks(raw: []const f32, region: sampler.Region, input_side: f32, out: *[raw_landmark_count]Landmark, visibilities: *[raw_landmark_count]f32, presences: *[raw_landmark_count]f32) void {
    std.debug.assert(raw.len >= raw_landmark_count * raw_values_per_landmark);
    const cos = @cos(region.rotation);
    const sin = @sin(region.rotation);
    const scale = region.side / input_side;
    for (out, 0..) |*landmark, at| {
        const u = raw[at * raw_values_per_landmark] / input_side - 0.5;
        const v = raw[at * raw_values_per_landmark + 1] / input_side - 0.5;
        landmark.* = .{
            .x = region.center_x + (u * cos - v * sin) * region.side,
            .y = region.center_y + (u * sin + v * cos) * region.side,
            .z = raw[at * raw_values_per_landmark + 2] * scale,
        };
        visibilities[at] = score01(raw[at * raw_values_per_landmark + 3]);
        presences[at] = score01(raw[at * raw_values_per_landmark + 4]);
    }
}

fn score01(raw: f32) f32 {
    return if (raw < 0.0 or raw > 1.0) 1.0 / (1.0 + @exp(-raw)) else raw;
}

const t = std.testing;

test "every body joint maps to an in-range landmark and reads its point" {
    var landmarks: [landmark_count * 3]f32 = undefined;
    for (0..landmark_count) |i| {
        landmarks[i * 3] = @floatFromInt(i);
        landmarks[i * 3 + 1] = @floatFromInt(i * 2);
        landmarks[i * 3 + 2] = @floatFromInt(i * 3);
    }
    inline for (std.meta.fields(Joint)) |field| {
        const joint: Joint = @enumFromInt(field.value);
        const idx = joint_landmark[field.value];
        try t.expect(idx < landmark_count);
        const p = jointPoint(&landmarks, joint);
        try t.expectEqual(@as(f32, @floatFromInt(idx)), p[0]);
        try t.expectEqual(@as(f32, @floatFromInt(idx * 2)), p[1]);
        try t.expectEqual(@as(f32, @floatFromInt(idx * 3)), p[2]);
    }
    try t.expectEqual(Joint.right_ankle, Joint.fromU32(12).?);
    try t.expectEqual(@as(?Joint, null), Joint.fromU32(13));
}

test "boneAngle measures the bend at the vertex and bone names resolve" {
    const set = struct {
        fn p(l: *[landmark_count * 3]f32, i: usize, x: f32, y: f32, z: f32) void {
            l[i * 3] = x;
            l[i * 3 + 1] = y;
            l[i * 3 + 2] = z;
        }
    }.p;
    var lm: [landmark_count * 3]f32 = @splat(0);
    // left_elbow is (11 shoulder, 13 elbow, 15 wrist); a right angle at the
    // elbow: shoulder straight up, wrist out to the side.
    set(&lm, 11, 0, 1, 0);
    set(&lm, 13, 0, 0, 0);
    set(&lm, 15, 1, 0, 0);
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), boneAngle(&lm, .left_elbow), 0.001);
    // Straightening the arm (wrist opposite the shoulder) reads pi.
    set(&lm, 15, 0, -1, 0);
    try t.expectApproxEqAbs(@as(f32, std.math.pi), boneAngle(&lm, .left_elbow), 0.001);

    try t.expectEqual(@as(?u8, 0), boneIndex("left_elbow"));
    try t.expectEqual(@as(?u8, null), boneIndex("nope"));
    try t.expect(bone_names.len == bone_count);
    try t.expectEqual(Bone.right_hip, Bone.fromU8(7).?);
    try t.expectEqual(@as(?Bone, null), Bone.fromU8(8));
    var out: [bone_count]f32 = undefined;
    fillBoneAngles(&lm, &out);
    try t.expectEqual(boneAngle(&lm, .left_elbow), out[0]);
}

test "an upright detection produces an unrotated crop of double the alignment distance" {
    var detection = std.mem.zeroes(detector.pose.Detection);
    detection.keypoints[center_keypoint] = .{ 0.5, 0.6 };
    detection.keypoints[scale_keypoint] = .{ 0.5, 0.4 }; // scale point above center
    const square = sampler.frameSquare(1000, 1000);
    const region = regionFromDetection(detection, square);
    try t.expectApproxEqAbs(@as(f32, 0.0), region.rotation, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 500.0), region.center_x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 600.0), region.center_y, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 200.0 * 2.0 * region_scale), region.side, 1e-2);
}

test "a sideways body rotates the crop upright" {
    var detection = std.mem.zeroes(detector.pose.Detection);
    detection.keypoints[center_keypoint] = .{ 0.4, 0.5 };
    detection.keypoints[scale_keypoint] = .{ 0.6, 0.5 }; // scale point to the right
    const region = regionFromDetection(detection, sampler.frameSquare(100, 100));
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), region.rotation, 1e-5);
}

test "the tracking crop follows the auxiliary pair" {
    var raw: [raw_landmark_count]Landmark = undefined;
    for (&raw) |*landmark| landmark.* = .{ .x = 0, .y = 0, .z = 0 };
    raw[aux_center_landmark] = .{ .x = 320, .y = 400, .z = 0 };
    raw[aux_scale_landmark] = .{ .x = 320, .y = 250, .z = 0 };
    const region = regionFromLandmarks(&raw);
    try t.expectApproxEqAbs(@as(f32, 320.0), region.center_x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 400.0), region.center_y, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 150.0 * 2.0 * region_scale), region.side, 1e-2);
    try t.expectApproxEqAbs(@as(f32, 0.0), region.rotation, 1e-4);
}

test "landmark decode maps five-value points and passes scores through" {
    var raw: [raw_landmark_count * raw_values_per_landmark]f32 = undefined;
    for (0..raw_landmark_count) |at| {
        raw[at * 5] = 128;
        raw[at * 5 + 1] = 64;
        raw[at * 5 + 2] = 8;
        raw[at * 5 + 3] = 0.75;
        raw[at * 5 + 4] = 4.0; // a logit, must squash
    }
    const region: sampler.Region = .{ .center_x = 100, .center_y = 100, .side = 256, .rotation = 0 };
    var out: [raw_landmark_count]Landmark = undefined;
    var visibilities: [raw_landmark_count]f32 = undefined;
    var presences: [raw_landmark_count]f32 = undefined;
    decodeLandmarks(&raw, region, 256, &out, &visibilities, &presences);
    try t.expectApproxEqAbs(@as(f32, 100.0), out[0].x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 100.0 - 64.0), out[0].y, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 0.75), visibilities[0], 1e-6);
    try t.expect(presences[0] > 0.95 and presences[0] <= 1.0);
}

test "the frozen result layout holds" {
    var result = std.mem.zeroes(Result);
    result.landmark_count_out = landmark_count;
    try t.expectEqual(@as(usize, 688), @sizeOf(Result));
    try t.expectEqual(@as(usize, 24 + 33 * 3 * 4), @offsetOf(Result, "visibilities"));
}
