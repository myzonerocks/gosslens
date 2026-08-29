//! Diffusion restyle on platforms without the compiled inference stack: every
//! entry refuses, so an SDK can tell "not built here" from "no result yet".

const std = @import("std");
const math = @import("math");
const ml_tensor = @import("ml_tensor");

pub const supported = false;

pub const CreateError = error{ InvalidModel, ModelRejected, OutOfMemory };

pub const Bytes = struct {
    encoder: []const u8,
    unet: []const u8,
    decoder: []const u8,
    text_embedding: []const u8 = &.{},
};

pub const Config = struct {
    steps: u32 = 4,
    strength: f32 = 0.6,
    seed: u64 = 0,
    coherence: f32 = 0,
};

pub const Diffusion = struct {};

pub fn create(gpa: std.mem.Allocator, bytes: Bytes, bounds: ml_tensor.Bounds, cfg: Config, threads: i32) CreateError!*Diffusion {
    _ = gpa;
    _ = bytes;
    _ = bounds;
    _ = cfg;
    _ = threads;
    return error.InvalidModel;
}

pub fn destroy(d: *Diffusion) void {
    _ = d;
}

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
    _ = d;
    _ = width;
    _ = height;
    _ = timestamp_us;
    _ = conversion;
    _ = y;
    _ = y_stride;
    _ = uv;
    _ = uv_stride;
}

pub fn readOutput(d: *Diffusion, dst: []f32) bool {
    _ = d;
    _ = dst;
    return false;
}

pub fn hasPublished(d: *Diffusion) bool {
    _ = d;
    return false;
}

pub fn outputLen(d: *Diffusion) usize {
    _ = d;
    return 0;
}

pub fn outputSide(d: *Diffusion) u32 {
    _ = d;
    return 0;
}

pub fn outputIsNchw(d: *Diffusion) bool {
    _ = d;
    return false;
}
