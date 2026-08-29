//! The diffusion restyle worker: runs the synchronous restyle core off the
//! camera thread. Frames arrive NV12 into a latest-wins mailbox; the decoded
//! image leaves through a mutex-guarded read. A restyle is many model passes,
//! far heavier than one inference, so it must never sit on the frame thread.

const std = @import("std");
const math = @import("math");
const sampler = @import("sampler");
const ml_tensor = @import("ml_tensor");
const core_mod = @import("diffusion_core");

pub const supported = core_mod.supported;
pub const CreateError = core_mod.CreateError;
pub const Bytes = core_mod.Bytes;
pub const Config = core_mod.Config;
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

pub const Diffusion = struct {
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

/// Stands the restyle core up under the sandbox bounds and starts the worker.
pub fn create(gpa: std.mem.Allocator, bytes: Bytes, bounds: ml_tensor.Bounds, cfg: Config, threads: i32) CreateError!*Diffusion {
    const d = gpa.create(Diffusion) catch return error.OutOfMemory;
    errdefer gpa.destroy(d);

    const core = try Core.init(gpa, bytes, bounds, cfg, threads);
    errdefer core.deinit();

    d.* = .{
        .gpa = gpa,
        .core = core,
        .io_state = std.Io.Threaded.init(gpa, .{}),
    };

    errdefer d.io_state.deinit();
    d.thread = std.Thread.spawn(.{}, workerMain, .{d}) catch return error.OutOfMemory;
    return d;
}

pub fn destroy(d: *Diffusion) void {
    const io = d.io_state.io();
    {
        d.mutex.lockUncancelable(io);
        defer d.mutex.unlock(io);
        d.stop = true;
        d.frame_ready.signal(io);
    }
    if (d.thread) |thread| thread.join();

    const gpa = d.gpa;
    d.pending.y.deinit(gpa);
    d.pending.uv.deinit(gpa);
    d.core.deinit();
    d.io_state.deinit();
    gpa.destroy(d);
}

/// Copies one NV12 frame into the mailbox, replacing any the worker has not
/// picked up: a restyle always wants the newest frame, never a backlog.
pub fn submitNv12(
    d: *Diffusion,
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

    const io = d.io_state.io();
    d.mutex.lockUncancelable(io);
    defer d.mutex.unlock(io);
    if (d.stop) return;

    d.pending.y.resize(d.gpa, y_size) catch return;
    d.pending.uv.resize(d.gpa, uv_size) catch return;
    for (0..height) |row| {
        const src = y[row * y_stride ..][0..width];
        @memcpy(d.pending.y.items[row * width ..][0..width], src);
    }
    for (0..half_height) |row| {
        const src = uv[row * uv_stride ..][0 .. half_width * 2];
        @memcpy(d.pending.uv.items[row * half_width * 2 ..][0 .. half_width * 2], src);
    }
    d.pending.width = width;
    d.pending.height = height;
    d.pending.timestamp_us = timestamp_us;
    d.pending.conversion = conversion;
    d.pending.fresh = true;
    d.frame_ready.signal(io);
}

/// Copies the latest restyled image into dst, thread-safe; false before the
/// first result or on a size mismatch.
pub fn readOutput(d: *Diffusion, dst: []f32) bool {
    const io = d.io_state.io();
    d.out_mutex.lockUncancelable(io);
    defer d.out_mutex.unlock(io);
    return d.core.copyOutput(dst);
}

pub fn hasPublished(d: *Diffusion) bool {
    const io = d.io_state.io();
    d.out_mutex.lockUncancelable(io);
    defer d.out_mutex.unlock(io);
    return d.core.published;
}

pub fn outputLen(d: *Diffusion) usize {
    return d.core.outputLen();
}

pub fn outputSide(d: *Diffusion) u32 {
    return d.core.out_side;
}

pub fn outputIsNchw(d: *Diffusion) bool {
    return d.core.out_nchw;
}

fn workerMain(d: *Diffusion) void {
    var frame: PendingFrame = .{};
    defer {
        frame.y.deinit(d.gpa);
        frame.uv.deinit(d.gpa);
    }

    while (true) {
        {
            const io = d.io_state.io();
            d.mutex.lockUncancelable(io);
            defer d.mutex.unlock(io);
            while (!d.pending.fresh and !d.stop) {
                d.frame_ready.waitUncancelable(io, &d.mutex);
            }
            if (d.stop) return;
            std.mem.swap(PendingFrame, &frame, &d.pending);
            d.pending.fresh = false;
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
        // The restyle runs off the lock; only the copy into the published
        // buffer holds the output lock, so a reader waits for a copy, not a run.
        if (!d.core.compute(image)) continue;
        const io = d.io_state.io();
        d.out_mutex.lockUncancelable(io);
        defer d.out_mutex.unlock(io);
        d.core.publish();
    }
}
