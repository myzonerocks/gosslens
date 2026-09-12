//! Palm detection plus the hand landmark model out of one bundle, detect then
//! track per slot, synchronous and free of threading. Host and android wrap it in
//! a worker; the single-threaded web module drives it directly. Two hands hold
//! their slots, so a hand keeps its identity across frames.

const std = @import("std");
const bundle = @import("bundle");
const runtime = @import("runtime");
const detector = @import("detector");
const sampler = @import("sampler");
const hand = @import("hand");
const graph = @import("graph");

pub const supported = true;

pub const CreateError = error{ Unsupported, InvalidBundle, OutOfMemory };

const max_candidates = 8;
const presence_floor = 0.5;
/// A fresh detection overlapping a tracked hand this much is that hand,
/// not a new one - the shipped graphs associate on the same bar.
const association_overlap = 0.5;

pub const Core = struct {
    gpa: std.mem.Allocator,
    task_bytes: []u8,
    /// Set when the caller handed over a gesture recognizer bundle, whose
    /// landmarker and gesture models nest inside their own containers.
    landmarker_container: ?bundle.Payload,
    gesture_container: ?bundle.Payload,
    detector_payload: bundle.Payload,
    landmarks_payload: bundle.Payload,
    embedder_payload: ?bundle.Payload,
    classifier_payload: ?bundle.Payload,
    detector_engine: runtime.Engine,
    landmarks_engine: runtime.Engine,
    embedder_engine: ?runtime.Engine,
    classifier_engine: ?runtime.Engine,

    detector_side: u32,
    landmark_side: u32,
    anchors: []detector.Anchor,
    detector_tensor: []f32,
    landmark_tensor: []f32,

    locks: [hand.max_hands]?sampler.Region = @splat(null),
    slot: graph.ResultSlot(hand.Result) = .{},
    /// Whether a result has ever been published. A u32 because wasm32 has no
    /// 64-bit atomic, and a flag is all a reader needs: the sequence-locked slot
    /// below is what makes the value itself safe to read across threads.
    published: std.atomic.Value(u32) = .init(0),
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

fn outputFloatCount(engine: *const runtime.Engine, index: i32) usize {
    const tensor = runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, index) orelse return 0;
    return runtime.c.TfLiteTensorByteSize(tensor) / @sizeOf(f32);
}

fn inputFloatCount(engine: *const runtime.Engine, index: i32) usize {
    const tensor = runtime.c.TfLiteInterpreterGetInputTensor(engine.interpreter, index) orelse return 0;
    return runtime.c.TfLiteTensorByteSize(tensor) / @sizeOf(f32);
}

/// Copies the bundle, stands the engines up and verifies each model's output
/// contract. Every tensor is allocated here, so a frame allocates nothing. Takes
/// a plain hand landmarker bundle or a gesture recognizer one, which nests the
/// landmarker plus the embedder and classifier pair inside containers.
pub fn init(gpa: std.mem.Allocator, task_bytes: []const u8, threads: i32) CreateError!*Core {
    const core = gpa.create(Core) catch return error.OutOfMemory;
    errdefer gpa.destroy(core);

    const owned_bytes = gpa.dupe(u8, task_bytes) catch return error.OutOfMemory;
    errdefer gpa.free(owned_bytes);

    const task = bundle.Bundle.open(owned_bytes) catch return error.InvalidBundle;

    var landmarker_container: ?bundle.Payload = null;
    errdefer if (landmarker_container) |payload| payload.deinit(gpa);
    var gesture_container: ?bundle.Payload = null;
    errdefer if (gesture_container) |payload| payload.deinit(gpa);

    const landmarker = blk: {
        if (task.find("hand_detector.tflite")) |_| break :blk task else |_| {}
        const nested_entry = task.find("hand_landmarker.task") catch return error.InvalidBundle;
        landmarker_container = task.payload(gpa, nested_entry) catch return error.InvalidBundle;
        break :blk bundle.Bundle.open(landmarker_container.?.bytes) catch return error.InvalidBundle;
    };

    const detector_entry = landmarker.find("hand_detector.tflite") catch return error.InvalidBundle;
    const landmarks_entry = landmarker.find("hand_landmarks_detector.tflite") catch return error.InvalidBundle;

    const detector_payload = landmarker.payload(gpa, detector_entry) catch return error.InvalidBundle;
    errdefer detector_payload.deinit(gpa);
    const landmarks_payload = landmarker.payload(gpa, landmarks_entry) catch return error.InvalidBundle;
    errdefer landmarks_payload.deinit(gpa);

    var detector_engine = runtime.Engine.init(detector_payload.bytes, threads) catch return error.InvalidBundle;
    errdefer detector_engine.deinit();
    var landmarks_engine = runtime.Engine.init(landmarks_payload.bytes, threads) catch return error.InvalidBundle;
    errdefer landmarks_engine.deinit();

    const detector_side = engineInputSide(&detector_engine) orelse return error.InvalidBundle;
    const landmark_side = engineInputSide(&landmarks_engine) orelse return error.InvalidBundle;
    const total = anchorTotal(&detector_engine) orelse return error.InvalidBundle;
    const plan = detector.planForModel(detector_side, total) orelse return error.InvalidBundle;

    // The landmark model's output contract: landmarks, presence,
    // handedness, in that order. A bundle whose sizes disagree is a
    // wiring defect to refuse, not to run with.
    if (outputFloatCount(&landmarks_engine, 0) != hand.landmark_count * 3) return error.InvalidBundle;
    if (outputFloatCount(&landmarks_engine, 1) != 1) return error.InvalidBundle;
    if (outputFloatCount(&landmarks_engine, 2) != 1) return error.InvalidBundle;

    var embedder_payload: ?bundle.Payload = null;
    errdefer if (embedder_payload) |payload| payload.deinit(gpa);
    var classifier_payload: ?bundle.Payload = null;
    errdefer if (classifier_payload) |payload| payload.deinit(gpa);
    var embedder_engine: ?runtime.Engine = null;
    errdefer if (embedder_engine) |*engine| engine.deinit();
    var classifier_engine: ?runtime.Engine = null;
    errdefer if (classifier_engine) |*engine| engine.deinit();

    if (task.find("hand_gesture_recognizer.task")) |gesture_entry| {
        gesture_container = task.payload(gpa, gesture_entry) catch return error.InvalidBundle;
        const gesture = bundle.Bundle.open(gesture_container.?.bytes) catch return error.InvalidBundle;
        const embedder_entry = gesture.find("gesture_embedder.tflite") catch return error.InvalidBundle;
        const classifier_entry = gesture.find("canned_gesture_classifier.tflite") catch return error.InvalidBundle;
        embedder_payload = gesture.payload(gpa, embedder_entry) catch return error.InvalidBundle;
        classifier_payload = gesture.payload(gpa, classifier_entry) catch return error.InvalidBundle;
        embedder_engine = runtime.Engine.init(embedder_payload.?.bytes, threads) catch return error.InvalidBundle;
        classifier_engine = runtime.Engine.init(classifier_payload.?.bytes, threads) catch return error.InvalidBundle;

        // The embedder eats the two canonicalized landmark matrices with
        // handedness between them; the classifier eats the embedding and
        // scores every canned gesture. Sizes disagreeing is refusal.
        if (inputFloatCount(&embedder_engine.?, 0) != hand.landmark_count * 3) return error.InvalidBundle;
        if (inputFloatCount(&embedder_engine.?, 1) != 1) return error.InvalidBundle;
        if (inputFloatCount(&embedder_engine.?, 2) != hand.landmark_count * 3) return error.InvalidBundle;
        if (outputFloatCount(&classifier_engine.?, 0) != hand.gesture_count) return error.InvalidBundle;
        if (inputFloatCount(&classifier_engine.?, 0) != outputFloatCount(&embedder_engine.?, 0)) return error.InvalidBundle;
        if (outputFloatCount(&landmarks_engine, 3) != hand.landmark_count * 3) return error.InvalidBundle;
    } else |_| {}

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
        .landmarker_container = landmarker_container,
        .gesture_container = gesture_container,
        .detector_payload = detector_payload,
        .landmarks_payload = landmarks_payload,
        .embedder_payload = embedder_payload,
        .classifier_payload = classifier_payload,
        .detector_engine = detector_engine,
        .landmarks_engine = landmarks_engine,
        .embedder_engine = embedder_engine,
        .classifier_engine = classifier_engine,
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
    if (core.classifier_engine) |*engine| engine.deinit();
    if (core.embedder_engine) |*engine| engine.deinit();
    core.detector_engine.deinit();
    core.landmarks_engine.deinit();
    gpa.free(core.landmark_tensor);
    gpa.free(core.detector_tensor);
    gpa.free(core.anchors);
    if (core.classifier_payload) |payload| payload.deinit(gpa);
    if (core.embedder_payload) |payload| payload.deinit(gpa);
    core.landmarks_payload.deinit(gpa);
    core.detector_payload.deinit(gpa);
    if (core.gesture_container) |payload| payload.deinit(gpa);
    if (core.landmarker_container) |payload| payload.deinit(gpa);
    gpa.free(core.task_bytes);
    gpa.destroy(core);
}

/// The latest published result. False until the first frame has computed.
pub fn readResult(core: *Core, out: *hand.Result) bool {
    if (core.published.load(.acquire) == 0) return false;
    const published = core.slot.latest() orelse return false;
    out.* = published.value;
    return true;
}


fn score01(raw: f32) f32 {
    return if (raw < 0.0 or raw > 1.0) 1.0 / (1.0 + @exp(-raw)) else raw;
}

/// Axis-aligned overlap of two square crops as intersection over union;
/// rotation is close between a detection and the lock it duplicates, so
/// the axis-aligned box is a faithful stand-in.
fn regionOverlap(a: sampler.Region, b: sampler.Region) f32 {
    const ax0 = a.center_x - a.side * 0.5;
    const ay0 = a.center_y - a.side * 0.5;
    const bx0 = b.center_x - b.side * 0.5;
    const by0 = b.center_y - b.side * 0.5;
    const x0 = @max(ax0, bx0);
    const y0 = @max(ay0, by0);
    const x1 = @min(ax0 + a.side, bx0 + b.side);
    const y1 = @min(ay0 + a.side, by0 + b.side);
    if (x1 <= x0 or y1 <= y0) return 0;
    const shared = (x1 - x0) * (y1 - y0);
    const total = a.side * a.side + b.side * b.side - shared;
    if (total <= 0) return 0;
    return shared / total;
}

/// Runs the embedder/classifier pair over one tracked hand when the
/// bundle carried them; without them the slot keeps the no-gesture
/// default. A refused inference leaves the default too - one bad frame
/// must not drop the hand.
fn classifyGesture(
    core: *Core,
    landmarks: *const [hand.landmark_count]hand.Landmark,
    handedness: f32,
    rotation: f32,
    image: sampler.Frame,
    slot: anytype,
) void {
    if (core.embedder_engine == null or core.classifier_engine == null) return;
    const embedder = &core.embedder_engine.?;
    const classifier = &core.classifier_engine.?;
    const raw_world = core.landmarks_engine.outputFloats(3) catch return;

    var screen_input: [hand.landmark_count * 3]f32 = undefined;
    hand.gestureLandmarkInput(landmarks, @floatFromInt(image.width), @floatFromInt(image.height), rotation, &screen_input);
    var world_input: [hand.landmark_count * 3]f32 = undefined;
    hand.gestureWorldInput(raw_world, rotation, &world_input);
    var handedness_input = [1]f32{handedness};

    embedder.writeInput(0, std.mem.sliceAsBytes(&screen_input)) catch return;
    embedder.writeInput(1, std.mem.sliceAsBytes(&handedness_input)) catch return;
    embedder.writeInput(2, std.mem.sliceAsBytes(&world_input)) catch return;
    embedder.invoke() catch return;
    const embedding = embedder.outputFloats(0) catch return;
    classifier.writeInput(0, std.mem.sliceAsBytes(embedding)) catch return;
    classifier.invoke() catch return;
    const scores = classifier.outputFloats(0) catch return;

    var best: usize = 0;
    for (scores, 0..) |score, at| {
        if (score > scores[best]) best = at;
    }
    slot.gesture = @intCast(best);
    slot.gesture_score = score01(scores[best]);
}

fn detectHands(core: *Core, image: sampler.Frame) void {
    const square = sampler.frameSquare(image.width, image.height);
    // The palm detector reads zero-to-one input, unlike the face
    // detector's symmetric range - the shipped graph's own tensor range.
    sampler.sampleRegion(image, square, .unit, core.detector_side, core.detector_tensor);
    core.detector_engine.writeInput(0, std.mem.sliceAsBytes(core.detector_tensor)) catch return;
    core.detector_engine.invoke() catch return;
    const raw_boxes = core.detector_engine.outputFloats(0) catch return;
    const raw_scores = core.detector_engine.outputFloats(1) catch return;
    var candidates: [max_candidates]detector.palm.Detection = undefined;
    const found = detector.palm.decode(raw_boxes, raw_scores, core.anchors, @floatFromInt(core.detector_side), 0.5, &candidates);

    for (found) |detection| {
        const region = hand.regionFromDetection(detection, square);
        var duplicate = false;
        for (core.locks) |maybe_lock| {
            const lock = maybe_lock orelse continue;
            if (regionOverlap(region, lock) >= association_overlap) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        for (&core.locks) |*slot| {
            if (slot.* == null) {
                slot.* = region;
                break;
            }
        }
    }
}

pub fn compute(core: *Core, image: sampler.Frame, timestamp_us: i64) void {
    var free_slots: usize = 0;
    for (core.locks) |maybe_lock| {
        if (maybe_lock == null) free_slots += 1;
    }
    if (free_slots > 0) detectHands(core, image);

    var result: hand.Result = std.mem.zeroes(hand.Result);
    result.frame_serial = core.serial + 1;
    result.timestamp_us = timestamp_us;

    for (&core.locks) |*maybe_lock| {
        const crop = maybe_lock.* orelse continue;
        sampler.sampleRegion(image, crop, .unit, core.landmark_side, core.landmark_tensor);
        core.landmarks_engine.writeInput(0, std.mem.sliceAsBytes(core.landmark_tensor)) catch continue;
        core.landmarks_engine.invoke() catch continue;
        const raw_landmarks = core.landmarks_engine.outputFloats(0) catch continue;
        const presence = score01((core.landmarks_engine.outputFloats(1) catch continue)[0]);
        if (presence < presence_floor) {
            maybe_lock.* = null;
            continue;
        }
        const handedness = score01((core.landmarks_engine.outputFloats(2) catch continue)[0]);

        var landmarks: [hand.landmark_count]hand.Landmark = undefined;
        hand.decodeLandmarks(raw_landmarks, crop, @floatFromInt(core.landmark_side), &landmarks);
        maybe_lock.* = hand.regionFromLandmarks(&landmarks);

        const slot = &result.hands[result.hand_count];
        slot.presence = presence;
        slot.handedness = handedness;
        slot.gesture = 0;
        slot.gesture_score = 0;
        classifyGesture(core, &landmarks, handedness, crop.rotation, image, slot);
        for (landmarks, 0..) |landmark, at| {
            slot.landmarks[at * 3] = landmark.x;
            slot.landmarks[at * 3 + 1] = landmark.y;
            slot.landmarks[at * 3 + 2] = landmark.z;
        }
        result.hand_count += 1;
    }

    core.serial = result.frame_serial;
    core.slot.publish(result, result.timestamp_us);
    core.published.store(1, .release);
}
