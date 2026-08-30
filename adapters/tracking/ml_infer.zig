//! The bring-your-own model worker: runs a synchronous inference core off the
//! camera thread. Frames arrive NV12 into a latest-wins mailbox; outputs leave
//! through a mutex-guarded read. The web tier skips this wrapper and drives the
//! core directly (ml_infer_core.zig).

const std = @import("std");
const math = @import("math");
const sampler = @import("sampler");
const ml_tensor = @import("ml_tensor");
const core_mod = @import("ml_infer_core");

pub const supported = core_mod.supported;
pub const CreateError = core_mod.CreateError;
pub const Core = core_mod.Core;
pub const max_outputs = core_mod.max_outputs;

/// The audio inference worker, run synchronously (an audio window is small), so
/// the wrapper is a thin pass-through to the core rather than a threaded mailbox.
pub const AudioInfer = core_mod.AudioCore;

pub fn audioCreate(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32) CreateError!*AudioInfer {
    return core_mod.AudioCore.init(gpa, model_bytes, bounds, threads);
}
pub fn audioDestroy(ai: *AudioInfer) void {
    ai.deinit();
}
pub fn audioCompute(ai: *AudioInfer, window: []const f32) bool {
    return ai.compute(window);
}
pub fn audioReadOutput(ai: *const AudioInfer, tensor: u32, index: u32) f32 {
    return ai.readOutput(tensor, index);
}
pub fn audioArgmax(ai: *const AudioInfer, tensor: u32) u32 {
    return ai.argmaxOutput(tensor);
}
pub fn audioOutputLen(ai: *const AudioInfer, tensor: u32) usize {
    return ai.outputLen(tensor);
}
pub fn audioOutputSlice(ai: *const AudioInfer, tensor: u32) []const f32 {
    return ai.outputSlice(tensor);
}

/// A generic model runner (the translation decoder step), a thin pass-through to
/// the core since it runs synchronously in the decode loop.
pub const GenericModel = core_mod.GenericCore;

pub fn genericCreate(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32) CreateError!*GenericModel {
    return core_mod.GenericCore.init(gpa, model_bytes, bounds, threads);
}
pub fn genericDestroy(m: *GenericModel) void {
    m.deinit();
}
pub fn genericWriteFloats(m: *GenericModel, index: usize, floats: []const f32) bool {
    return m.writeFloats(index, floats);
}
pub fn genericInvoke(m: *GenericModel) bool {
    return m.invoke();
}
pub fn genericOutput(m: *const GenericModel, index: usize) []const f32 {
    return m.output(index);
}
pub fn genericInputLen(m: *const GenericModel, index: usize) usize {
    return m.inputLen(index);
}
pub fn audioHasPublished(ai: *const AudioInfer) bool {
    return ai.hasPublished();
}
pub fn audioInputLen(ai: *const AudioInfer) usize {
    return ai.inputLen();
}

const PendingFrame = struct {
    width: u32 = 0,
    height: u32 = 0,
    timestamp_us: i64 = 0,
    conversion: math.color.Conversion = undefined,
    y: std.ArrayList(u8) = .empty,
    uv: std.ArrayList(u8) = .empty,
    fresh: bool = false,
};

pub const MlInfer = struct {
    gpa: std.mem.Allocator,
    core: *Core,

    io_state: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    frame_ready: std.Io.Condition = .init,
    pending: PendingFrame = .{},
    stop: bool = false,

    out_mutex: std.Io.Mutex = .init,

    thread: ?std.Thread = null,
};

/// Stands the core up under the sandbox bounds and starts the worker.
pub fn create(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32, aux_rgba: ?[]const u8, aux_width: u32, aux_height: u32, temporal: bool) CreateError!*MlInfer {
    const ml = gpa.create(MlInfer) catch return error.OutOfMemory;
    errdefer gpa.destroy(ml);

    const core = try Core.init(gpa, model_bytes, bounds, threads, aux_rgba, aux_width, aux_height, temporal);
    errdefer core.deinit();

    ml.* = .{
        .gpa = gpa,
        .core = core,
        .io_state = std.Io.Threaded.init(gpa, .{}),
    };

    // io_state is live from the assignment above; a failed spawn must tear it
    // down rather than leak its worker-pool state.
    errdefer ml.io_state.deinit();
    ml.thread = std.Thread.spawn(.{}, workerMain, .{ml}) catch return error.OutOfMemory;
    return ml;
}

pub fn destroy(ml: *MlInfer) void {
    const io = ml.io_state.io();
    {
        ml.mutex.lockUncancelable(io);
        defer ml.mutex.unlock(io);
        ml.stop = true;
        ml.frame_ready.signal(io);
    }
    if (ml.thread) |thread| thread.join();

    const gpa = ml.gpa;
    ml.pending.y.deinit(gpa);
    ml.pending.uv.deinit(gpa);
    ml.core.deinit();
    ml.io_state.deinit();
    gpa.destroy(ml);
}

/// Copies one NV12 frame into the mailbox, replacing any frame the worker has
/// not picked up yet - inference always wants the newest frame, never a
/// backlog.
pub fn submitNv12(
    ml: *MlInfer,
    width: u32,
    height: u32,
    timestamp_us: i64,
    conversion: math.color.Conversion,
    y: [*]const u8,
    y_stride: u32,
    uv: [*]const u8,
    uv_stride: u32,
) void {
    const y_size = @as(usize, width) * height;
    const half_width = (width + 1) / 2;
    const half_height = (height + 1) / 2;
    const uv_size = @as(usize, half_width) * half_height * 2;

    const io = ml.io_state.io();
    ml.mutex.lockUncancelable(io);
    defer ml.mutex.unlock(io);
    if (ml.stop) return;

    ml.pending.y.resize(ml.gpa, y_size) catch return;
    ml.pending.uv.resize(ml.gpa, uv_size) catch return;
    for (0..height) |row| {
        const src = y[row * y_stride ..][0..width];
        @memcpy(ml.pending.y.items[row * width ..][0..width], src);
    }
    for (0..half_height) |row| {
        const src = uv[row * uv_stride ..][0 .. half_width * 2];
        @memcpy(ml.pending.uv.items[row * half_width * 2 ..][0 .. half_width * 2], src);
    }
    ml.pending.width = width;
    ml.pending.height = height;
    ml.pending.timestamp_us = timestamp_us;
    ml.pending.conversion = conversion;
    ml.pending.fresh = true;
    ml.frame_ready.signal(io);
}

/// One output tensor element the model published, guarded and thread-safe.
pub fn readOutput(ml: *MlInfer, tensor: u32, index: u32) f32 {
    const io = ml.io_state.io();
    ml.out_mutex.lockUncancelable(io);
    defer ml.out_mutex.unlock(io);
    return ml.core.readOutput(tensor, index);
}

/// Whether the worker has published at least one inference. A reader leaves a
/// bound parameter at its authored default until this turns true, rather than
/// forcing it to zero for the frames before the first result lands.
pub fn hasPublished(ml: *MlInfer) bool {
    const io = ml.io_state.io();
    ml.out_mutex.lockUncancelable(io);
    defer ml.out_mutex.unlock(io);
    return ml.core.published;
}

/// The element count of an output tensor, for a mask reader sizing its copy.
pub fn outputLen(ml: *MlInfer, tensor: u32) usize {
    return ml.core.outputLen(tensor);
}

/// The predicted class of an output tensor (its argmax), thread-safe.
pub fn argmaxOutput(ml: *MlInfer, tensor: u32) u32 {
    const io = ml.io_state.io();
    ml.out_mutex.lockUncancelable(io);
    defer ml.out_mutex.unlock(io);
    return ml.core.argmaxOutput(tensor);
}

/// Whether the model's image tensors are channel-first (NCHW).
pub fn layoutIsNchw(ml: *MlInfer) bool {
    return ml.core.layoutIsNchw();
}

/// Copies a whole output tensor into dst under the output lock, for a consumer
/// that reads a full mask; false before the first publish or on a size mismatch.
pub fn copyOutput(ml: *MlInfer, tensor: u32, dst: []f32) bool {
    const io = ml.io_state.io();
    ml.out_mutex.lockUncancelable(io);
    defer ml.out_mutex.unlock(io);
    return ml.core.copyOutput(tensor, dst);
}

pub fn outputCount(ml: *MlInfer) u32 {
    return ml.core.output_count;
}

fn workerMain(ml: *MlInfer) void {
    var frame: PendingFrame = .{};
    defer {
        frame.y.deinit(ml.gpa);
        frame.uv.deinit(ml.gpa);
    }

    while (true) {
        {
            const io = ml.io_state.io();
            ml.mutex.lockUncancelable(io);
            defer ml.mutex.unlock(io);
            while (!ml.pending.fresh and !ml.stop) {
                ml.frame_ready.waitUncancelable(io, &ml.mutex);
            }
            if (ml.stop) return;
            std.mem.swap(PendingFrame, &frame, &ml.pending);
            ml.pending.fresh = false;
        }

        const image: sampler.Frame = .{
            .width = frame.width,
            .height = frame.height,
            .pixels = .{ .nv12 = .{
                .y = frame.y.items,
                .y_stride = frame.width,
                .uv = frame.uv.items,
                .uv_stride = ((frame.width + 1) / 2) * 2,
                .conversion = frame.conversion,
            } },
        };
        // Invoke off the lock, then hold the output lock only across the copy
        // so readers block for a copy, not an inference.
        if (!ml.core.compute(image)) continue;
        const io = ml.io_state.io();
        ml.out_mutex.lockUncancelable(io);
        defer ml.out_mutex.unlock(io);
        ml.core.publish();
    }
}

pub const TemporalCore = core_mod.TemporalCore;

/// The threaded wrapper around a TemporalCore: a mailbox holds the newest frame,
/// the worker feeds it into the fusion ring (deduped by timestamp) and publishes
/// the fused image once the ring is full. Mirrors MlInfer, off the frame thread.
pub const TemporalInfer = struct {
    gpa: std.mem.Allocator,
    core: *TemporalCore,
    io_state: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    frame_ready: std.Io.Condition = .init,
    pending: PendingFrame = .{},
    stop: bool = false,
    out_mutex: std.Io.Mutex = .init,
    /// The count of frames the worker has ringed, published for a caller pacing
    /// its feed so the ring keeps distinct frames in order.
    filled: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    thread: ?std.Thread = null,
};

pub fn temporalCreate(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32, frames: u32) CreateError!*TemporalInfer {
    const ti = gpa.create(TemporalInfer) catch return error.OutOfMemory;
    errdefer gpa.destroy(ti);
    const core = try TemporalCore.init(gpa, model_bytes, bounds, threads, frames);
    errdefer core.deinit();
    ti.* = .{ .gpa = gpa, .core = core, .io_state = std.Io.Threaded.init(gpa, .{}) };
    errdefer ti.io_state.deinit();
    ti.thread = std.Thread.spawn(.{}, temporalMain, .{ti}) catch return error.OutOfMemory;
    return ti;
}

pub fn temporalDestroy(ti: *TemporalInfer) void {
    const io = ti.io_state.io();
    {
        ti.mutex.lockUncancelable(io);
        defer ti.mutex.unlock(io);
        ti.stop = true;
        ti.frame_ready.signal(io);
    }
    if (ti.thread) |thread| thread.join();
    const gpa = ti.gpa;
    ti.pending.y.deinit(gpa);
    ti.pending.uv.deinit(gpa);
    ti.core.deinit();
    ti.io_state.deinit();
    gpa.destroy(ti);
}

/// Copies one NV12 frame into the mailbox, replacing any the worker has not
/// picked up yet; the fusion ring keeps the newest distinct frames by timestamp.
pub fn temporalSubmitNv12(ti: *TemporalInfer, width: u32, height: u32, timestamp_us: i64, conversion: math.color.Conversion, y: [*]const u8, y_stride: u32, uv: [*]const u8, uv_stride: u32) void {
    const y_size = @as(usize, width) * height;
    const half_width = (width + 1) / 2;
    const half_height = (height + 1) / 2;
    const uv_size = @as(usize, half_width) * half_height * 2;
    const io = ti.io_state.io();
    ti.mutex.lockUncancelable(io);
    defer ti.mutex.unlock(io);
    if (ti.stop) return;
    ti.pending.y.resize(ti.gpa, y_size) catch return;
    ti.pending.uv.resize(ti.gpa, uv_size) catch return;
    for (0..height) |row| {
        @memcpy(ti.pending.y.items[row * width ..][0..width], y[row * y_stride ..][0..width]);
    }
    for (0..half_height) |row| {
        @memcpy(ti.pending.uv.items[row * half_width * 2 ..][0 .. half_width * 2], uv[row * uv_stride ..][0 .. half_width * 2]);
    }
    ti.pending.width = width;
    ti.pending.height = height;
    ti.pending.timestamp_us = timestamp_us;
    ti.pending.conversion = conversion;
    ti.pending.fresh = true;
    ti.frame_ready.signal(io);
}

pub fn temporalSetPhase(ti: *TemporalInfer, phase: f32) void {
    const io = ti.io_state.io();
    ti.out_mutex.lockUncancelable(io);
    defer ti.out_mutex.unlock(io);
    ti.core.setPhase(phase);
}

pub fn temporalHasPublished(ti: *TemporalInfer) bool {
    const io = ti.io_state.io();
    ti.out_mutex.lockUncancelable(io);
    defer ti.out_mutex.unlock(io);
    return ti.core.published;
}

pub fn temporalCopyStyle(ti: *TemporalInfer, dst: []f32) bool {
    const io = ti.io_state.io();
    ti.out_mutex.lockUncancelable(io);
    defer ti.out_mutex.unlock(io);
    return ti.core.copyStyle(dst);
}

pub fn temporalStyleLen(ti: *const TemporalInfer) usize {
    return ti.core.styleLen();
}

pub fn temporalFilled(ti: *const TemporalInfer) u32 {
    return ti.filled.load(.acquire);
}

pub fn temporalLayoutIsNchw(ti: *const TemporalInfer) bool {
    return ti.core.layoutIsNchw();
}

fn temporalMain(ti: *TemporalInfer) void {
    var frame: PendingFrame = .{};
    defer {
        frame.y.deinit(ti.gpa);
        frame.uv.deinit(ti.gpa);
    }
    while (true) {
        {
            const io = ti.io_state.io();
            ti.mutex.lockUncancelable(io);
            defer ti.mutex.unlock(io);
            while (!ti.pending.fresh and !ti.stop) {
                ti.frame_ready.waitUncancelable(io, &ti.mutex);
            }
            if (ti.stop) return;
            std.mem.swap(PendingFrame, &frame, &ti.pending);
            ti.pending.fresh = false;
        }
        const image: sampler.Frame = .{
            .width = frame.width,
            .height = frame.height,
            .pixels = .{ .nv12 = .{
                .y = frame.y.items,
                .y_stride = frame.width,
                .uv = frame.uv.items,
                .uv_stride = ((frame.width + 1) / 2) * 2,
                .conversion = frame.conversion,
            } },
        };
        _ = ti.core.feed(image, frame.timestamp_us);
        ti.filled.store(ti.core.filled, .release);
        if (!ti.core.ready()) continue;
        if (!ti.core.compute()) continue;
        const io = ti.io_state.io();
        ti.out_mutex.lockUncancelable(io);
        defer ti.out_mutex.unlock(io);
        ti.core.publish();
    }
}
