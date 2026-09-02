//! The diffusion restyle rail on targets with no threads (the web): the
//! synchronous restyle core driven in place inside submit. A restyle is many
//! model passes, so a small model and a low step count are the usable
//! envelope here. The public surface mirrors diffusion.zig one to one.

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

pub const Diffusion = struct {
    gpa: std.mem.Allocator,
    core: *Core,
};

pub fn create(gpa: std.mem.Allocator, bytes: Bytes, bounds: ml_tensor.Bounds, cfg: Config, threads: i32) CreateError!*Diffusion {
    const d = gpa.create(Diffusion) catch return error.OutOfMemory;
    errdefer gpa.destroy(d);
    const core = try Core.init(gpa, bytes, bounds, cfg, threads);
    d.* = .{ .gpa = gpa, .core = core };
    return d;
}

pub fn destroy(d: *Diffusion) void {
    const gpa = d.gpa;
    d.core.deinit();
    gpa.destroy(d);
}

/// Runs one NV12 frame through the restyle loop before returning; the
/// submitted planes are only borrowed for the call, so nothing is copied.
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
    _ = timestamp_us;
    const y_len = @as(usize, y_stride) * height;
    const uv_len = @as(usize, uv_stride) * ((height + 1) / 2);
    const image: sampler.Frame = .{
        .width = width,
        .height = height,
        .pixels = .{ .nv12 = .{
            .y = y[0..y_len],
            .y_stride = y_stride,
            .uv = uv[0..uv_len],
            .uv_stride = uv_stride,
            .conversion = conversion,
        } },
    };
    if (!d.core.compute(image)) return;
    d.core.publish();
}

pub fn readOutput(d: *Diffusion, dst: []f32) bool {
    return d.core.copyOutput(dst);
}

pub fn hasPublished(d: *Diffusion) bool {
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
