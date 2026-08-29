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
pub fn create(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32) CreateError!*MlInfer {
    const ml = gpa.create(MlInfer) catch return error.OutOfMemory;
    errdefer gpa.destroy(ml);

    const core = try Core.init(gpa, model_bytes, bounds, threads);
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
