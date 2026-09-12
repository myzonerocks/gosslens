//! The web tracking module's export surface. The SDK runs this module inside a
//! Worker, so every call here runs the pipeline synchronously and returns. One
//! instance per create, frames in as RGBA off the camera canvas, the frozen
//! result struct out.

const std = @import("std");
const bundle = @import("bundle");
const runtime = @import("runtime");
const detector = @import("detector");
const sampler = @import("sampler");
const face = @import("face");
const tracker = @import("tracker");
const pose = @import("pose");
const hand = @import("hand");
const segmentation_core = @import("segmentation_core");
const pose_core = @import("pose_core");
const hand_core = @import("hand_core");

const gpa = std.heap.wasm_allocator;

/// The delegate's cache mapper names this libc call; the web target has no
/// page locking, and the mapper treats refusal as advisory.
export fn mlock(address: ?*const anyopaque, length: usize) c_int {
    _ = address;
    _ = length;
    return -1;
}

const status_ok: i32 = 0;
const status_invalid: i32 = 1;
const status_out_of_memory: i32 = 2;
const status_again: i32 = 7;

const Instance = struct {
    task_bytes: []u8,
    detector_payload: bundle.Payload,
    landmarks_payload: bundle.Payload,
    blendshapes_payload: bundle.Payload,
    detector_engine: runtime.Engine,
    landmarks_engine: runtime.Engine,
    blendshapes_engine: runtime.Engine,

    detector_side: u32,
    landmark_side: u32,
    anchors: []detector.Anchor,
    detector_tensor: []f32,
    landmark_tensor: []f32,

    lock: tracker.Tracker = .{},
    result: face.Result = std.mem.zeroes(face.Result),
    has_result: bool = false,
    serial: u64 = 0,
};

fn engineInputSide(engine: *const runtime.Engine) ?u32 {
    const tensor = runtime.c.TfLiteInterpreterGetInputTensor(engine.interpreter, 0) orelse return null;
    if (runtime.c.TfLiteTensorNumDims(tensor) != 4) return null;
    return @intCast(runtime.c.TfLiteTensorDim(tensor, 1));
}

fn anchorTotal(engine: *const runtime.Engine) ?usize {
    const tensor = runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, 0) orelse return null;
    if (runtime.c.TfLiteTensorNumDims(tensor) < 2) return null;
    return @intCast(runtime.c.TfLiteTensorDim(tensor, 1));
}

/// Allocation the embedder pairs with goss_tracking_free; how bundle and
/// frame bytes reach this module's memory.
pub export fn goss_tracking_alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;
    const slice = gpa.alloc(u8, size) catch return null;
    return slice.ptr;
}

pub export fn goss_tracking_free(ptr: ?[*]u8, size: usize) void {
    const p = ptr orelse return;
    if (size == 0) return;
    gpa.free(p[0..size]);
}

pub export fn goss_tracking_result_size() usize {
    return @sizeOf(face.Result);
}

// A pub export fn cannot return an error, so its errdefers would be dead;
// the build-and-own body lives here where every errdefer is live, and the
// export below wraps it as `catch null`.
fn createFaceInstance(task_ptr: ?[*]const u8, task_len: usize) !*Instance {
    const task_source = task_ptr orelse return error.CreateFailed;
    if (task_len == 0) return error.CreateFailed;

    const instance = try gpa.create(Instance);
    errdefer gpa.destroy(instance);

    const owned = try gpa.dupe(u8, task_source[0..task_len]);
    errdefer gpa.free(owned);

    const task = try bundle.Bundle.open(owned);
    const detector_entry = try task.find("face_detector.tflite");
    const landmarks_entry = try task.find("face_landmarks_detector.tflite");
    const blendshapes_entry = try task.find("face_blendshapes.tflite");

    const detector_payload = try task.payload(gpa, detector_entry);
    errdefer detector_payload.deinit(gpa);
    const landmarks_payload = try task.payload(gpa, landmarks_entry);
    errdefer landmarks_payload.deinit(gpa);
    const blendshapes_payload = try task.payload(gpa, blendshapes_entry);
    errdefer blendshapes_payload.deinit(gpa);

    var detector_engine = try runtime.Engine.init(detector_payload.bytes, 1);
    errdefer detector_engine.deinit();
    var landmarks_engine = try runtime.Engine.init(landmarks_payload.bytes, 1);
    errdefer landmarks_engine.deinit();
    var blendshapes_engine = try runtime.Engine.init(blendshapes_payload.bytes, 1);
    errdefer blendshapes_engine.deinit();

    const detector_side = engineInputSide(&detector_engine) orelse return error.CreateFailed;
    const landmark_side = engineInputSide(&landmarks_engine) orelse return error.CreateFailed;
    const total = anchorTotal(&detector_engine) orelse return error.CreateFailed;
    const plan = detector.planForModel(detector_side, total) orelse return error.CreateFailed;

    // Reinstate the native output-size contract the wasm face path dropped: a
    // bundle whose landmark model is short must be refused here, not read out
    // of bounds on the frame path where the decode assert compiles out.
    if (floatCount(&landmarks_engine, 0, false) < face.landmark_count * 3) return error.CreateFailed;
    if (floatCount(&landmarks_engine, 1, false) < 1) return error.CreateFailed;

    const anchors = try gpa.alloc(detector.Anchor, total);
    errdefer gpa.free(anchors);
    detector.generateAnchors(detector_side, plan, anchors);

    const detector_tensor = try gpa.alloc(f32, @as(usize, detector_side) * detector_side * 3);
    errdefer gpa.free(detector_tensor);
    const landmark_tensor = try gpa.alloc(f32, @as(usize, landmark_side) * landmark_side * 3);
    errdefer gpa.free(landmark_tensor);

    instance.* = .{
        .task_bytes = owned,
        .detector_payload = detector_payload,
        .landmarks_payload = landmarks_payload,
        .blendshapes_payload = blendshapes_payload,
        .detector_engine = detector_engine,
        .landmarks_engine = landmarks_engine,
        .blendshapes_engine = blendshapes_engine,
        .detector_side = detector_side,
        .landmark_side = landmark_side,
        .anchors = anchors,
        .detector_tensor = detector_tensor,
        .landmark_tensor = landmark_tensor,
    };
    return instance;
}

pub export fn goss_tracking_create(task_ptr: ?[*]const u8, task_len: usize) ?*Instance {
    return createFaceInstance(task_ptr, task_len) catch null;
}

pub export fn goss_tracking_destroy(instance: ?*Instance) void {
    const tracking = instance orelse return;
    tracking.blendshapes_engine.deinit();
    tracking.landmarks_engine.deinit();
    tracking.detector_engine.deinit();
    gpa.free(tracking.landmark_tensor);
    gpa.free(tracking.detector_tensor);
    gpa.free(tracking.anchors);
    tracking.blendshapes_payload.deinit(gpa);
    tracking.landmarks_payload.deinit(gpa);
    tracking.detector_payload.deinit(gpa);
    gpa.free(tracking.task_bytes);
    gpa.destroy(tracking);
}

fn presenceScore(raw: f32) f32 {
    return if (raw < 0.0 or raw > 1.0) 1.0 / (1.0 + @exp(-raw)) else raw;
}

/// Runs the whole pipeline over one packed RGBA frame and publishes the
/// result for goss_tracking_result. Synchronous by design: the Worker this
/// runs in is the off-main-thread guarantee.
pub export fn goss_tracking_process(instance: ?*Instance, rgba: ?[*]const u8, width: u32, height: u32, timestamp_us: i64) i32 {
    const tracking = instance orelse return status_invalid;
    const pixels = rgba orelse return status_invalid;
    if (width == 0 or width > 65535 or height == 0 or height > 65535) return status_invalid;

    const image: sampler.Frame = .{
        .width = width,
        .height = height,
        .pixels = .{ .rgba8 = pixels[0 .. @as(usize, width) * height * 4] },
    };

    const crop = tracking.lock.cropForFrame() orelse detect: {
        sampler.sampleRegion(image, sampler.frameSquare(width, height), .symmetric, tracking.detector_side, tracking.detector_tensor);
        tracking.detector_engine.writeInput(0, std.mem.sliceAsBytes(tracking.detector_tensor)) catch return status_invalid;
        tracking.detector_engine.invoke() catch return status_invalid;
        const raw_boxes = tracking.detector_engine.outputFloats(0) catch return status_invalid;
        const raw_scores = tracking.detector_engine.outputFloats(1) catch return status_invalid;
        var candidates: [16]detector.face.Detection = undefined;
        const found = detector.face.decode(raw_boxes, raw_scores, tracking.anchors, @floatFromInt(tracking.detector_side), 0.5, &candidates);
        if (found.len == 0) {
            publishEmpty(tracking, timestamp_us);
            return status_ok;
        }
        const region = face.regionFromDetection(found[0], sampler.frameSquare(width, height));
        tracking.lock.onDetection(region);
        break :detect region;
    };

    sampler.sampleRegion(image, crop, .unit, tracking.landmark_side, tracking.landmark_tensor);
    tracking.landmarks_engine.writeInput(0, std.mem.sliceAsBytes(tracking.landmark_tensor)) catch return status_invalid;
    tracking.landmarks_engine.invoke() catch return status_invalid;
    const raw_landmarks = tracking.landmarks_engine.outputFloats(0) catch return status_invalid;
    const presence = presenceScore((tracking.landmarks_engine.outputFloats(1) catch return status_invalid)[0]);

    var landmarks: [face.landmark_count]face.Landmark = undefined;
    face.decodeLandmarks(raw_landmarks, crop, @floatFromInt(tracking.landmark_side), &landmarks);
    if (tracking.lock.onLandmarks(presence, &landmarks) == .searching) {
        publishEmpty(tracking, timestamp_us);
        return status_ok;
    }

    tracking.serial += 1;
    tracking.result.frame_serial = tracking.serial;
    tracking.result.timestamp_us = timestamp_us;
    tracking.result.presence = presence;
    tracking.result.landmark_count_out = face.landmark_count;
    for (landmarks, 0..) |landmark, at| {
        tracking.result.landmarks[at * 3] = landmark.x;
        tracking.result.landmarks[at * 3 + 1] = landmark.y;
        tracking.result.landmarks[at * 3 + 2] = landmark.z;
    }

    var blend_input: [face.blendshape_subset.len * 2]f32 = undefined;
    face.blendshapeInput(&landmarks, &blend_input);
    @memset(&tracking.result.blendshapes, 0);
    if (tracking.blendshapes_engine.writeInput(0, std.mem.sliceAsBytes(&blend_input))) |_| {
        if (tracking.blendshapes_engine.invoke()) |_| {
            const scores = tracking.blendshapes_engine.outputFloats(0) catch &[_]f32{};
            const count = @min(scores.len, tracking.result.blendshapes.len);
            @memcpy(tracking.result.blendshapes[0..count], scores[0..count]);
        } else |_| {}
    } else |_| {}

    tracking.has_result = true;
    return status_ok;
}

pub export fn goss_tracking_result(instance: ?*Instance, out: ?[*]u8) i32 {
    const tracking = instance orelse return status_invalid;
    const destination = out orelse return status_invalid;
    if (!tracking.has_result) return status_again;
    @memcpy(destination[0..@sizeOf(face.Result)], std.mem.asBytes(&tracking.result));
    return status_ok;
}

fn publishEmpty(tracking: *Instance, timestamp_us: i64) void {
    tracking.serial += 1;
    tracking.result = std.mem.zeroes(face.Result);
    tracking.result.frame_serial = tracking.serial;
    tracking.result.timestamp_us = timestamp_us;
    tracking.has_result = true;
}

// The selfie/hair segmenter, same shape: one Core per create, RGBA frames
// in, a 256x256 mask out. The embedder allocates the model and the mask
// buffer with goss_tracking_alloc/free.

pub export fn goss_segmentation_mask_side() u32 {
    return segmentation_core.mask_side;
}

pub export fn goss_segmentation_create(model_ptr: ?[*]const u8, model_len: usize, threads: i32) ?*segmentation_core.Core {
    const model = model_ptr orelse return null;
    if (model_len == 0) return null;
    return segmentation_core.Core.init(gpa, model[0..model_len], threads) catch null;
}

pub export fn goss_segmentation_destroy(core: ?*segmentation_core.Core) void {
    if (core) |c| c.deinit();
}

pub export fn goss_segmentation_class_count(core: ?*segmentation_core.Core) u32 {
    const c = core orelse return 0;
    return c.class_count;
}

pub export fn goss_segmentation_process(core: ?*segmentation_core.Core, rgba: ?[*]const u8, width: u32, height: u32) i32 {
    const c = core orelse return status_invalid;
    const pixels = rgba orelse return status_invalid;
    if (width == 0 or width > 65535 or height == 0 or height > 65535) return status_invalid;
    const frame: sampler.Frame = .{
        .width = width,
        .height = height,
        .pixels = .{ .rgba8 = pixels[0 .. @as(usize, width) * height * 4] },
    };
    if (!c.compute(frame)) return status_invalid;
    c.publish();
    return status_ok;
}

pub export fn goss_segmentation_read_mask(core: ?*segmentation_core.Core, out: ?[*]f32) i32 {
    const c = core orelse return status_invalid;
    const dst = out orelse return status_invalid;
    if (!c.subjectMask(@ptrCast(dst))) return status_again;
    return status_ok;
}

pub export fn goss_segmentation_read_class_mask(core: ?*segmentation_core.Core, class_index: u32, out: ?[*]f32) i32 {
    const c = core orelse return status_invalid;
    const dst = out orelse return status_invalid;
    if (!c.classMask(class_index, @ptrCast(dst))) return status_again;
    return status_ok;
}

/// A tensor's float count, the size contract the face path checks a bundle
/// against before the frame path trusts it.
fn floatCount(engine: *const runtime.Engine, index: i32, input: bool) usize {
    const tensor = if (input)
        runtime.c.TfLiteInterpreterGetInputTensor(engine.interpreter, index)
    else
        runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, index);
    const t = tensor orelse return 0;
    return runtime.c.TfLiteTensorByteSize(t) / @sizeOf(f32);
}

// Pose and hands run the same cores the host and android workers run, driven
// directly because this module is single-threaded. These blocks used to carry
// their own copy of each pipeline, so a decode fixed on one tier stayed broken
// on the other; one implementation now, so the web result is the native one.

pub export fn goss_pose_result_size() usize {
    return @sizeOf(pose.Result);
}

pub export fn goss_pose_create(task_ptr: ?[*]const u8, task_len: usize) ?*pose_core.Core {
    const task = task_ptr orelse return null;
    if (task_len == 0) return null;
    return pose_core.Core.init(gpa, task[0..task_len], 1) catch null;
}

pub export fn goss_pose_destroy(core: ?*pose_core.Core) void {
    const c = core orelse return;
    c.deinit();
}

pub export fn goss_pose_process(core: ?*pose_core.Core, rgba: ?[*]const u8, width: u32, height: u32, timestamp_us: i64) i32 {
    const c = core orelse return status_invalid;
    const pixels = rgba orelse return status_invalid;
    if (width == 0 or width > 65535 or height == 0 or height > 65535) return status_invalid;
    c.compute(.{
        .width = width,
        .height = height,
        .pixels = .{ .rgba8 = pixels[0 .. @as(usize, width) * height * 4] },
    }, timestamp_us);
    return status_ok;
}

pub export fn goss_pose_result(core: ?*pose_core.Core, out: ?[*]u8) i32 {
    const c = core orelse return status_invalid;
    const destination = out orelse return status_invalid;
    var result: pose.Result = undefined;
    if (!c.readResult(&result)) return status_again;
    @memcpy(destination[0..@sizeOf(pose.Result)], std.mem.asBytes(&result));
    return status_ok;
}

pub export fn goss_hand_result_size() usize {
    return @sizeOf(hand.Result);
}

pub export fn goss_hand_create(task_ptr: ?[*]const u8, task_len: usize) ?*hand_core.Core {
    const task = task_ptr orelse return null;
    if (task_len == 0) return null;
    return hand_core.init(gpa, task[0..task_len], 1) catch null;
}

pub export fn goss_hand_destroy(core: ?*hand_core.Core) void {
    const c = core orelse return;
    hand_core.deinit(c);
}

pub export fn goss_hand_process(core: ?*hand_core.Core, rgba: ?[*]const u8, width: u32, height: u32, timestamp_us: i64) i32 {
    const c = core orelse return status_invalid;
    const pixels = rgba orelse return status_invalid;
    if (width == 0 or width > 65535 or height == 0 or height > 65535) return status_invalid;
    hand_core.compute(c, .{
        .width = width,
        .height = height,
        .pixels = .{ .rgba8 = pixels[0 .. @as(usize, width) * height * 4] },
    }, timestamp_us);
    return status_ok;
}

pub export fn goss_hand_result(core: ?*hand_core.Core, out: ?[*]u8) i32 {
    const c = core orelse return status_invalid;
    const destination = out orelse return status_invalid;
    var result: hand.Result = undefined;
    if (!hand_core.readResult(c, &result)) return status_again;
    @memcpy(destination[0..@sizeOf(hand.Result)], std.mem.asBytes(&result));
    return status_ok;
}
