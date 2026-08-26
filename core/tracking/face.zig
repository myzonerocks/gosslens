//! Face pipeline geometry: how a detection or a previous frame's landmarks
//! become the aligned crop the landmark model reads, and how its output
//! maps back into frame pixels. The constants mirror the task graphs the
//! pinned models ship with: eye keypoints steer rotation to a level face,
//! crops are squares on the long side scaled by one and a half, and the
//! blendshape model reads a fixed 146 landmark subset as pixel pairs.

const std = @import("std");
const sampler = @import("sampler");
const detector = @import("detector");

pub const landmark_count = 478;
pub const blendshape_count = 52;

/// How many faces the multi-face path carries at once. A group selfie
/// rarely fills a frame past this, and the per-face Result is large, so
/// the cap bounds the session buffer that backs face_count/face_result_at.
pub const max_faces = 4;
pub const region_scale = 1.5;

/// The blendshape model's output order, extracted from the pinned model
/// itself (face_blendshapes.tflite carries no separate label file; the
/// names live in a raw flatbuffers string vector inside the model, found
/// by locating the length-52 offset vector and walking it) rather than
/// assumed from the published category list, though it matches it.
pub const blendshape_names = [blendshape_count][]const u8{
    "_neutral",         "browDownLeft",      "browDownRight",     "browInnerUp",
    "browOuterUpLeft",  "browOuterUpRight",  "cheekPuff",         "cheekSquintLeft",
    "cheekSquintRight", "eyeBlinkLeft",      "eyeBlinkRight",     "eyeLookDownLeft",
    "eyeLookDownRight", "eyeLookInLeft",     "eyeLookInRight",    "eyeLookOutLeft",
    "eyeLookOutRight",  "eyeLookUpLeft",     "eyeLookUpRight",    "eyeSquintLeft",
    "eyeSquintRight",   "eyeWideLeft",       "eyeWideRight",      "jawForward",
    "jawLeft",          "jawOpen",           "jawRight",          "mouthClose",
    "mouthDimpleLeft",  "mouthDimpleRight",  "mouthFrownLeft",    "mouthFrownRight",
    "mouthFunnel",      "mouthLeft",         "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthPressLeft",   "mouthPressRight",   "mouthPucker",       "mouthRight",
    "mouthRollLower",   "mouthRollUpper",    "mouthShrugLower",   "mouthShrugUpper",
    "mouthSmileLeft",   "mouthSmileRight",   "mouthStretchLeft",  "mouthStretchRight",
    "mouthUpperUpLeft", "mouthUpperUpRight", "noseSneerLeft",     "noseSneerRight",
};

/// The blendshape's index in blendshape_names/Result.blendshapes, or null
/// for an unknown name. Linear scan over 52 short strings, called only at
/// lens load time (trigger compilation), never per frame.
pub fn blendshapeIndex(name: []const u8) ?u8 {
    for (blendshape_names, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) return @intCast(i);
    }
    return null;
}

pub const Landmark = sampler.Landmark;

/// One published tracking result, the shape that crosses the C boundary.
/// Landmarks are x, y in frame pixels and z in the same scale; a zero
/// landmark count means the frame held no face. The layout is frozen.
pub const Result = extern struct {
    frame_serial: u64,
    timestamp_us: i64,
    presence: f32,
    landmark_count_out: u32,
    landmarks: [landmark_count * 3]f32,
    blendshapes: [blendshape_count]f32,
};

comptime {
    std.debug.assert(@sizeOf(Result) == 5968);
    std.debug.assert(@offsetOf(Result, "presence") == 16);
    std.debug.assert(@offsetOf(Result, "landmarks") == 24);
    std.debug.assert(@offsetOf(Result, "blendshapes") == 24 + landmark_count * 3 * 4);
}

/// Named attach points on the mesh, so a lens can pin content to the
/// forehead or a cheek without knowing the mesh indices. The left/right
/// labels are the subject's own, resolved against the canonical model.
pub const Region = enum(u32) {
    forehead = 0,
    glabella = 1,
    nose_tip = 2,
    chin = 3,
    left_eye = 4,
    right_eye = 5,
    left_cheek = 6,
    right_cheek = 7,
    left_ear = 8,
    right_ear = 9,
    mouth_center = 10,
    left_mouth_corner = 11,
    right_mouth_corner = 12,

    pub fn fromU32(value: u32) ?Region {
        return switch (value) {
            0...12 => @enumFromInt(value),
            else => null,
        };
    }
};

/// The representative landmark for each region, chosen so the canonical
/// model position sits on the named part of the face.
const region_landmark = [_]u16{
    10, // forehead - global-max-y centre-line vertex
    168, // glabella - between the brows
    1, // nose_tip - the pinned nose-tip vertex
    152, // chin - global-min-y centre-line vertex
    263, // left_eye - subject's left outer corner (positive canonical x)
    33, // right_eye - subject's right outer corner
    280, // left_cheek - subject's left, positive canonical x
    50, // right_cheek - subject's right
    454, // left_ear - subject's left tragion
    234, // right_ear - subject's right tragion
    13, // mouth_center - inner lip-gap centre
    291, // left_mouth_corner - subject's left commissure
    61, // right_mouth_corner - subject's right commissure
};

/// The mesh landmark a region resolves to.
pub fn regionLandmark(region: Region) u16 {
    return region_landmark[@intFromEnum(region)];
}

/// The outer-lip contour as a closed ring of mesh landmarks, the two corners
/// at 61 and 291 and the rest in order around the lip, so a face-part matte
/// fills this polygon straight from tracking.
pub const outer_lip_loop = [_]u16{
    61, 146, 91,  181, 84,  17,  314, 405, 321, 375,
    291, 409, 270, 269, 267, 0,   37,  39,  40,  185,
};

/// Each eye's lid contour as a closed ring, the outer corner first (263 and
/// 33), lower lid then upper, so a face-part matte fills each eye straight
/// from tracking.
pub const left_eye_loop = [_]u16{
    263, 249, 390, 373, 374, 380, 381, 382,
    362, 398, 384, 385, 386, 387, 388, 466,
};
pub const right_eye_loop = [_]u16{
    33,  7,   163, 144, 145, 153, 154, 155,
    133, 173, 157, 158, 159, 160, 161, 246,
};

/// Each eyebrow as a closed ring: the lower edge lateral to medial, then the
/// upper edge medial back to lateral, so the ring traces the brow perimeter
/// without self-intersecting when it fills.
pub const left_brow_loop = [_]u16{ 276, 283, 282, 295, 285, 336, 296, 334, 293, 300 };
pub const right_brow_loop = [_]u16{ 46, 53, 52, 65, 55, 107, 66, 105, 63, 70 };

/// The tracked point for a region: x, y in frame pixels and z in the same
/// scale, read straight from the mesh. landmarks is a result's flat array.
pub fn regionPoint(landmarks: *const [landmark_count * 3]f32, region: Region) [3]f32 {
    const base = @as(usize, regionLandmark(region)) * 3;
    return .{ landmarks[base], landmarks[base + 1], landmarks[base + 2] };
}

/// The region point read from a Landmark array (the web host-submitted path).
pub fn regionPointFromLandmarks(landmarks: *const [landmark_count]Landmark, region: Region) [3]f32 {
    const lm = landmarks[regionLandmark(region)];
    return .{ lm.x, lm.y, lm.z };
}

test "every region maps to an in-range landmark and reads its point" {
    var landmarks: [landmark_count * 3]f32 = undefined;
    for (0..landmark_count) |i| {
        landmarks[i * 3] = @floatFromInt(i);
        landmarks[i * 3 + 1] = @floatFromInt(i * 2);
        landmarks[i * 3 + 2] = @floatFromInt(i * 3);
    }
    inline for (std.meta.fields(Region)) |field| {
        const region: Region = @enumFromInt(field.value);
        const idx = region_landmark[field.value];
        try t.expect(idx < landmark_count);
        const p = regionPoint(&landmarks, region);
        try t.expectEqual(@as(f32, @floatFromInt(idx)), p[0]);
        try t.expectEqual(@as(f32, @floatFromInt(idx * 2)), p[1]);
        try t.expectEqual(@as(f32, @floatFromInt(idx * 3)), p[2]);
    }
    try t.expectEqual(Region.nose_tip, Region.fromU32(2).?);
    try t.expectEqual(@as(?Region, null), Region.fromU32(99));
}

/// Indices of the landmarks the blendshape model consumes, in its input
/// order. The subset is part of the model's contract, fixed at training.
pub const blendshape_subset = [146]u16{
    0,   1,   4,   5,   6,   7,   8,   10,  13,  14,  17,  21,  33,
    37,  39,  40,  46,  52,  53,  54,  55,  58,  61,  63,  65,  66,
    67,  70,  78,  80,  81,  82,  84,  87,  88,  91,  93,  95,  103,
    105, 107, 109, 127, 132, 133, 136, 144, 145, 146, 148, 149, 150,
    152, 153, 154, 155, 157, 158, 159, 160, 161, 162, 163, 168, 172,
    173, 176, 178, 181, 185, 191, 195, 197, 234, 246, 249, 251, 263,
    267, 269, 270, 276, 282, 283, 284, 285, 288, 291, 293, 295, 296,
    297, 300, 308, 310, 311, 312, 314, 317, 318, 321, 323, 324, 332,
    334, 336, 338, 356, 361, 362, 365, 373, 374, 375, 377, 378, 379,
    380, 381, 382, 384, 385, 386, 387, 388, 389, 390, 397, 398, 400,
    402, 405, 409, 415, 454, 466, 468, 469, 470, 471, 472, 473, 474,
    475, 476, 477,
};

/// Landmark pair steering the tracking crop's rotation: the eye outer
/// corners, leveled to zero degrees.
pub const rotation_start_landmark = 33;
pub const rotation_end_landmark = 263;

fn mapToFrame(square: sampler.Region, u: f32, v: f32) [2]f32 {
    return .{
        square.center_x + (u - 0.5) * square.side,
        square.center_y + (v - 0.5) * square.side,
    };
}

fn levelRotation(dx: f32, dy: f32) f32 {
    // Zero when the steering segment lies level in the image; the sign
    // convention matches the task graph's target angle of zero degrees.
    return -std.math.atan2(-dy, dx);
}

/// The aligned landmark crop for a fresh detection, in frame pixels.
/// Detection coordinates are normalized to the detector's input square.
pub fn regionFromDetection(detection: detector.face.Detection, square: sampler.Region) sampler.Region {
    const eye_right = mapToFrame(square, detection.keypoints[0][0], detection.keypoints[0][1]);
    const eye_left = mapToFrame(square, detection.keypoints[1][0], detection.keypoints[1][1]);
    const center = mapToFrame(square, detection.x, detection.y);
    const long_side = @max(detection.width, detection.height) * square.side;
    return .{
        .center_x = center[0],
        .center_y = center[1],
        .side = long_side * region_scale,
        .rotation = levelRotation(eye_left[0] - eye_right[0], eye_left[1] - eye_right[1]),
    };
}

/// The next frame's crop from this frame's landmarks, which keeps the
/// model tracking without re-running detection while the face holds.
pub fn regionFromLandmarks(landmarks: *const [landmark_count]Landmark) sampler.Region {
    var min_x = landmarks[0].x;
    var max_x = landmarks[0].x;
    var min_y = landmarks[0].y;
    var max_y = landmarks[0].y;
    for (landmarks[1..]) |landmark| {
        min_x = @min(min_x, landmark.x);
        max_x = @max(max_x, landmark.x);
        min_y = @min(min_y, landmark.y);
        max_y = @max(max_y, landmark.y);
    }
    const start = landmarks[rotation_start_landmark];
    const end = landmarks[rotation_end_landmark];
    return .{
        .center_x = (min_x + max_x) * 0.5,
        .center_y = (min_y + max_y) * 0.5,
        .side = @max(max_x - min_x, max_y - min_y) * region_scale,
        .rotation = levelRotation(end.x - start.x, end.y - start.y),
    };
}

/// Maps the landmark model's raw output, in crop input pixels, back into
/// frame pixels through the crop's rotation and scale.
pub fn decodeLandmarks(raw: []const f32, region: sampler.Region, input_side: f32, out: *[landmark_count]Landmark) void {
    sampler.decodeLandmarks(landmark_count, raw, region, input_side, out);
}

/// Assembles the blendshape model's input: the subset landmarks as pixel
/// coordinate pairs, in subset order.
pub fn blendshapeInput(landmarks: *const [landmark_count]Landmark, out: *[blendshape_subset.len * 2]f32) void {
    for (blendshape_subset, 0..) |index, at| {
        out[at * 2] = landmarks[index].x;
        out[at * 2 + 1] = landmarks[index].y;
    }
}

const t = std.testing;

test "blendshape names are unique and resolve to their own index" {
    for (blendshape_names, 0..) |name, i| {
        try t.expectEqual(@as(?u8, @intCast(i)), blendshapeIndex(name));
    }
    try t.expectEqual(@as(?u8, null), blendshapeIndex("not_a_real_blendshape"));
    try t.expectEqualStrings("_neutral", blendshape_names[0]);
    try t.expectEqualStrings("jawOpen", blendshape_names[25]);
    try t.expectEqualStrings("noseSneerRight", blendshape_names[51]);
}

test "the blendshape subset is strictly increasing within the mesh" {
    var previous: i32 = -1;
    for (blendshape_subset) |index| {
        try t.expect(index > previous);
        previous = index;
    }
    try t.expect(blendshape_subset[blendshape_subset.len - 1] < landmark_count);
}

test "level eyes produce an unrotated crop" {
    var detection = std.mem.zeroes(detector.face.Detection);
    detection.x = 0.5;
    detection.y = 0.5;
    detection.width = 0.4;
    detection.height = 0.3;
    detection.keypoints[0] = .{ 0.4, 0.5 };
    detection.keypoints[1] = .{ 0.6, 0.5 };
    const square = sampler.frameSquare(640, 480);
    const region = regionFromDetection(detection, square);
    try t.expectApproxEqAbs(@as(f32, 0.0), region.rotation, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 320.0), region.center_x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 240.0), region.center_y, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 0.4 * 640.0 * region_scale), region.side, 1e-3);
}

test "a tilted eye line rotates the crop level" {
    var detection = std.mem.zeroes(detector.face.Detection);
    detection.keypoints[0] = .{ 0.5, 0.5 };
    detection.keypoints[1] = .{ 0.5, 0.6 }; // left eye straight below right
    const region = regionFromDetection(detection, sampler.frameSquare(100, 100));
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), @abs(region.rotation), 1e-5);
}

test "landmark decode through an identity region is a rescale" {
    var raw: [landmark_count * 3]f32 = undefined;
    for (0..landmark_count) |at| {
        raw[at * 3] = 128;
        raw[at * 3 + 1] = 64;
        raw[at * 3 + 2] = 8;
    }
    const region: sampler.Region = .{ .center_x = 100, .center_y = 100, .side = 256, .rotation = 0 };
    var out: [landmark_count]Landmark = undefined;
    decodeLandmarks(&raw, region, 256, &out);
    try t.expectApproxEqAbs(@as(f32, 100.0), out[0].x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 100.0 - 64.0), out[0].y, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 8.0), out[0].z, 1e-3);
}

test "tracking region covers the landmarks with headroom" {
    var landmarks: [landmark_count]Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        const angle = @as(f32, @floatFromInt(at)) * 0.013;
        landmark.* = .{ .x = 200 + 50 * @cos(angle), .y = 300 + 40 * @sin(angle), .z = 0 };
    }
    const region = regionFromLandmarks(&landmarks);
    try t.expectApproxEqAbs(@as(f32, 200.0), region.center_x, 1.0);
    try t.expectApproxEqAbs(@as(f32, 300.0), region.center_y, 1.0);
    try t.expect(region.side > 100.0 and region.side < 200.0);
}

test "blendshape input gathers subset pairs in order" {
    var landmarks: [landmark_count]Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        landmark.* = .{ .x = @floatFromInt(at), .y = @floatFromInt(at * 2), .z = 0 };
    }
    var out: [blendshape_subset.len * 2]f32 = undefined;
    blendshapeInput(&landmarks, &out);
    try t.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, @floatFromInt(blendshape_subset[12])), out[24], 1e-6);
    try t.expectApproxEqAbs(@as(f32, @floatFromInt(blendshape_subset[145] * 2)), out[291], 1e-6);
}
