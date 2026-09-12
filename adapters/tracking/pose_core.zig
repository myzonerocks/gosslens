//! The pose inference core: detection plus the landmark model out of one
//! bundle, run detect-then-track, synchronous and free of threading. The host
//! and android tiers wrap it in a worker (pose_tracking.zig); the web tier,
//! whose wasm module is single-threaded, drives it directly.

const std = @import("std");
const bundle = @import("bundle");
const runtime = @import("runtime");
const detector = @import("detector");
const sampler = @import("sampler");
const pose = @import("pose");
const graph = @import("graph");

pub const supported = true;

pub const CreateError = error{ Unsupported, InvalidBundle, OutOfMemory };

const max_candidates = 8;
const presence_floor = 0.5;

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

fn outputFloatCount(engine: *const runtime.Engine, index: i32) usize {
    const tensor = runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, index) orelse return 0;
    return runtime.c.TfLiteTensorByteSize(tensor) / @sizeOf(f32);
}

fn score01(raw: f32) f32 {
    return if (raw < 0.0 or raw > 1.0) 1.0 / (1.0 + @exp(-raw)) else raw;
}

pub const Core = struct {
    gpa: std.mem.Allocator,
    task_bytes: []u8,
    detector_payload: bundle.Payload,
    landmarks_payload: bundle.Payload,
    detector_engine: runtime.Engine,
    landmarks_engine: runtime.Engine,

    detector_side: u32,
    landmark_side: u32,
    anchors: []detector.Anchor,
    detector_tensor: []f32,
    landmark_tensor: []f32,

    /// The region the last frame settled on, which the next frame tracks from
    /// instead of detecting again.
    lock: ?sampler.Region = null,
    slot: graph.ResultSlot(pose.Result) = .{},
    /// Whether a result has ever been published. A u32 because wasm32 has no
    /// 64-bit atomic, and a flag is all a reader needs: the sequence-locked slot
    /// below is what makes the value itself safe to read across threads.
    published: std.atomic.Value(u32) = .init(0),
    serial: u64 = 0,

    /// Copies the bundle, stands both engines up, and verifies the landmark
    /// model's output contract. Every tensor it will ever need is allocated
    /// here, so computing a frame allocates nothing.
    pub fn init(gpa: std.mem.Allocator, task_bytes: []const u8, threads: i32) CreateError!*Core {
        const core = gpa.create(Core) catch return error.OutOfMemory;
        errdefer gpa.destroy(core);

        const owned_bytes = gpa.dupe(u8, task_bytes) catch return error.OutOfMemory;
        errdefer gpa.free(owned_bytes);

        const task = bundle.Bundle.open(owned_bytes) catch return error.InvalidBundle;
        const detector_entry = task.find("pose_detector.tflite") catch return error.InvalidBundle;
        const landmarks_entry = task.find("pose_landmarks_detector.tflite") catch return error.InvalidBundle;

        const detector_payload = task.payload(gpa, detector_entry) catch return error.InvalidBundle;
        errdefer detector_payload.deinit(gpa);
        const landmarks_payload = task.payload(gpa, landmarks_entry) catch return error.InvalidBundle;
        errdefer landmarks_payload.deinit(gpa);

        var detector_engine = runtime.Engine.init(detector_payload.bytes, threads) catch return error.InvalidBundle;
        errdefer detector_engine.deinit();
        var landmarks_engine = runtime.Engine.init(landmarks_payload.bytes, threads) catch return error.InvalidBundle;
        errdefer landmarks_engine.deinit();

        const detector_side = engineInputSide(&detector_engine) orelse return error.InvalidBundle;
        const landmark_side = engineInputSide(&landmarks_engine) orelse return error.InvalidBundle;
        const total = anchorTotal(&detector_engine) orelse return error.InvalidBundle;
        const plan = detector.planForModel(detector_side, total) orelse return error.InvalidBundle;

        // The landmark model's output contract: the five-value raw points at
        // zero and the pose flag at one. A bundle whose sizes disagree is a
        // wiring defect to refuse, not to run with.
        if (outputFloatCount(&landmarks_engine, 0) != pose.raw_landmark_count * pose.raw_values_per_landmark) return error.InvalidBundle;
        if (outputFloatCount(&landmarks_engine, 1) != 1) return error.InvalidBundle;

        const anchors = gpa.alloc(detector.Anchor, total) catch return error.OutOfMemory;
        errdefer gpa.free(anchors);
        detector.generateAnchors(detector_side, plan, anchors);

        const detector_tensor = gpa.alloc(f32, @as(usize, detector_side) * detector_side * 3) catch return error.OutOfMemory;
        errdefer gpa.free(detector_tensor);
        const landmark_tensor = gpa.alloc(f32, @as(usize, landmark_side) * landmark_side * 3) catch return error.OutOfMemory;
        errdefer gpa.free(landmark_tensor);

        core.* = .{
            .gpa = gpa,
            .task_bytes = owned_bytes,
            .detector_payload = detector_payload,
            .landmarks_payload = landmarks_payload,
            .detector_engine = detector_engine,
            .landmarks_engine = landmarks_engine,
            .detector_side = detector_side,
            .landmark_side = landmark_side,
            .anchors = anchors,
            .detector_tensor = detector_tensor,
            .landmark_tensor = landmark_tensor,
        };
        return core;
    }

    pub fn deinit(core: *Core) void {
        const gpa = core.gpa;
        core.detector_engine.deinit();
        core.landmarks_engine.deinit();
        gpa.free(core.landmark_tensor);
        gpa.free(core.detector_tensor);
        gpa.free(core.anchors);
        core.landmarks_payload.deinit(gpa);
        core.detector_payload.deinit(gpa);
        gpa.free(core.task_bytes);
        gpa.destroy(core);
    }

    /// Runs detection when there is no lock, then the landmark model, and
    /// publishes the result. Every failure publishes an empty result rather
    /// than leaving the last one to look current.
    pub fn compute(core: *Core, image: sampler.Frame, timestamp_us: i64) void {
        const crop = core.lock orelse detect: {
            const square = sampler.frameSquare(image.width, image.height);
            // Symmetric input, the pose detector's own tensor range - the
            // face detector's convention, not the palm detector's.
            sampler.sampleRegion(image, square, .symmetric, core.detector_side, core.detector_tensor);
            core.detector_engine.writeInput(0, std.mem.sliceAsBytes(core.detector_tensor)) catch {
                core.publishEmpty(timestamp_us);
                return;
            };
            core.detector_engine.invoke() catch {
                core.publishEmpty(timestamp_us);
                return;
            };
            const raw_boxes = core.detector_engine.outputFloats(0) catch {
                core.publishEmpty(timestamp_us);
                return;
            };
            const raw_scores = core.detector_engine.outputFloats(1) catch {
                core.publishEmpty(timestamp_us);
                return;
            };
            var candidates: [max_candidates]detector.pose.Detection = undefined;
            const found = detector.pose.decode(raw_boxes, raw_scores, core.anchors, @floatFromInt(core.detector_side), 0.5, &candidates);
            if (found.len == 0) {
                core.publishEmpty(timestamp_us);
                return;
            }
            const region = pose.regionFromDetection(found[0], square);
            core.lock = region;
            break :detect region;
        };

        sampler.sampleRegion(image, crop, .unit, core.landmark_side, core.landmark_tensor);
        core.landmarks_engine.writeInput(0, std.mem.sliceAsBytes(core.landmark_tensor)) catch {
            core.publishEmpty(timestamp_us);
            return;
        };
        core.landmarks_engine.invoke() catch {
            core.publishEmpty(timestamp_us);
            return;
        };
        const raw_landmarks = core.landmarks_engine.outputFloats(0) catch {
            core.publishEmpty(timestamp_us);
            return;
        };
        const presence_out = core.landmarks_engine.outputFloats(1) catch {
            core.publishEmpty(timestamp_us);
            return;
        };
        const presence = score01(presence_out[0]);
        if (presence < presence_floor) {
            core.lock = null;
            core.publishEmpty(timestamp_us);
            return;
        }

        var landmarks: [pose.raw_landmark_count]pose.Landmark = undefined;
        var visibilities: [pose.raw_landmark_count]f32 = undefined;
        var presences: [pose.raw_landmark_count]f32 = undefined;
        pose.decodeLandmarks(raw_landmarks, crop, @floatFromInt(core.landmark_side), &landmarks, &visibilities, &presences);
        core.lock = pose.regionFromLandmarks(&landmarks);

        var result: pose.Result = undefined;
        result.frame_serial = core.serial + 1;
        result.timestamp_us = timestamp_us;
        result.presence = presence;
        result.landmark_count_out = pose.landmark_count;
        for (0..pose.landmark_count) |at| {
            result.landmarks[at * 3] = landmarks[at].x;
            result.landmarks[at * 3 + 1] = landmarks[at].y;
            result.landmarks[at * 3 + 2] = landmarks[at].z;
            result.visibilities[at] = visibilities[at];
            result.presences[at] = presences[at];
        }
        core.publish(result);
    }

    /// The latest published result. False until the first frame has computed.
    pub fn readResult(core: *Core, out: *pose.Result) bool {
        if (core.published.load(.acquire) == 0) return false;
        const published = core.slot.latest() orelse return false;
        out.* = published.value;
        return true;
    }

    fn publishEmpty(core: *Core, timestamp_us: i64) void {
        var result = std.mem.zeroes(pose.Result);
        result.frame_serial = core.serial + 1;
        result.timestamp_us = timestamp_us;
        core.publish(result);
    }

    fn publish(core: *Core, result: pose.Result) void {
        core.serial = result.frame_serial;
        core.slot.publish(result, result.timestamp_us);
        core.published.store(1, .release);
    }
};
