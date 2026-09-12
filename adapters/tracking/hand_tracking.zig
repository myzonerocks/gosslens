//! Runs the synchronous hand core off the camera thread. Frames arrive NV12 into
//! a latest-wins mailbox; results leave through the core's sequence-locked slot.
//! The web tier skips this wrapper and drives hand_core.zig directly, the same
//! split segmentation, pose and the ml rail take.

const std = @import("std");
const hand = @import("hand");
const math = @import("math");
const core_mod = @import("hand_core.zig");

pub const supported = core_mod.supported;
pub const CreateError = core_mod.CreateError;
pub const Core = core_mod.Core;

const PendingFrame = struct {
    width: u32 = 0,
    height: u32 = 0,
    timestamp_us: i64 = 0,
    conversion: math.color.Conversion = undefined,
    y: std.ArrayList(u8) = .empty,
    uv: std.ArrayList(u8) = .empty,
    fresh: bool = false,
};

pub const HandTracking = struct {
    gpa: std.mem.Allocator,
    core: *Core,

    io_state: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    frame_ready: std.Io.Condition = .init,
    pending: PendingFrame = .{},
    stop: bool = false,

    thread: ?std.Thread = null,
};

/// Stands the core up and starts the worker around it. Accepts either a plain
/// hand landmarker bundle or a gesture recognizer bundle, whichever the core
/// takes.
pub fn create(gpa: std.mem.Allocator, task_bytes: []const u8, threads: i32) CreateError!*HandTracking {
    const tracking = gpa.create(HandTracking) catch return error.OutOfMemory;
    errdefer gpa.destroy(tracking);

    const core = try core_mod.init(gpa, task_bytes, threads);
    errdefer core_mod.deinit(core);

    tracking.* = .{
        .gpa = gpa,
        .core = core,
        .io_state = std.Io.Threaded.init(gpa, .{}),
    };

    // io_state is live from the struct assignment above; a failed spawn must
    // tear it down rather than leak its worker-pool state.
    errdefer tracking.io_state.deinit();
    tracking.thread = std.Thread.spawn(.{}, workerMain, .{tracking}) catch return error.OutOfMemory;
    return tracking;
}

pub fn destroy(tracking: *HandTracking) void {
    const io = tracking.io_state.io();
    {
        tracking.mutex.lockUncancelable(io);
        defer tracking.mutex.unlock(io);
        tracking.stop = true;
        tracking.frame_ready.signal(io);
    }
    if (tracking.thread) |thread| thread.join();

    const gpa = tracking.gpa;
    tracking.pending.y.deinit(gpa);
    tracking.pending.uv.deinit(gpa);
    core_mod.deinit(tracking.core);
    tracking.io_state.deinit();
    gpa.destroy(tracking);
}

/// Copies one NV12 frame into the mailbox, replacing any frame the worker has
/// not picked up yet - tracking always wants the newest frame.
pub fn submitNv12(
    tracking: *HandTracking,
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

    const io = tracking.io_state.io();
    tracking.mutex.lockUncancelable(io);
    defer tracking.mutex.unlock(io);
    if (tracking.stop) return;

    tracking.pending.y.resize(tracking.gpa, y_size) catch return;
    tracking.pending.uv.resize(tracking.gpa, uv_size) catch return;
    for (0..height) |row| {
        const src = y[row * y_stride ..][0..width];
        @memcpy(tracking.pending.y.items[row * width ..][0..width], src);
    }
    for (0..half_height) |row| {
        const src = uv[row * uv_stride ..][0 .. half_width * 2];
        @memcpy(tracking.pending.uv.items[row * half_width * 2 ..][0 .. half_width * 2], src);
    }
    tracking.pending.width = width;
    tracking.pending.height = height;
    tracking.pending.timestamp_us = timestamp_us;
    tracking.pending.conversion = conversion;
    tracking.pending.fresh = true;
    tracking.frame_ready.signal(io);
}

/// Reads the latest published result. False until the worker has produced its
/// first one.
pub fn readResult(tracking: *HandTracking, out: *hand.Result) bool {
    return core_mod.readResult(tracking.core, out);
}

fn workerMain(tracking: *HandTracking) void {
    var frame: PendingFrame = .{};
    defer {
        frame.y.deinit(tracking.gpa);
        frame.uv.deinit(tracking.gpa);
    }

    while (true) {
        {
            const io = tracking.io_state.io();
            tracking.mutex.lockUncancelable(io);
            defer tracking.mutex.unlock(io);
            while (!tracking.pending.fresh and !tracking.stop) {
                tracking.frame_ready.waitUncancelable(io, &tracking.mutex);
            }
            if (tracking.stop) return;
            std.mem.swap(PendingFrame, &frame, &tracking.pending);
            tracking.pending.fresh = false;
        }
        core_mod.compute(tracking.core, .{
            .width = frame.width,
            .height = frame.height,
            .pixels = .{ .nv12 = .{
                .y = frame.y.items,
                .y_stride = frame.width,
                .uv = frame.uv.items,
                .uv_stride = ((frame.width + 1) / 2) * 2,
                .conversion = frame.conversion,
            } },
        }, frame.timestamp_us);
    }
}
