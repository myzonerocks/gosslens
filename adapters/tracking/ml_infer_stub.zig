//! Bring-your-own model inference on platforms without the compiled inference
//! stack: every entry refuses. The export layer reports the refusal as its own
//! status so an SDK can tell "not built here" from "no result yet".

const std = @import("std");
const math = @import("math");
const ml_tensor = @import("ml_tensor");

pub const supported = false;

pub const CreateError = error{ Unsupported, InvalidModel, ModelRejected, OutOfMemory };

pub const max_outputs = 8;

pub const MlInfer = struct {};

pub fn create(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32, aux_rgba: ?[]const u8, aux_width: u32, aux_height: u32) CreateError!*MlInfer {
    _ = gpa;
    _ = model_bytes;
    _ = bounds;
    _ = threads;
    _ = aux_rgba;
    _ = aux_width;
    _ = aux_height;
    return error.Unsupported;
}

pub fn destroy(ml: *MlInfer) void {
    _ = ml;
}

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
    _ = ml;
    _ = width;
    _ = height;
    _ = timestamp_us;
    _ = conversion;
    _ = y;
    _ = y_stride;
    _ = uv;
    _ = uv_stride;
}

pub fn readOutput(ml: *MlInfer, tensor: u32, index: u32) f32 {
    _ = ml;
    _ = tensor;
    _ = index;
    return 0;
}

pub fn hasPublished(ml: *MlInfer) bool {
    _ = ml;
    return false;
}

pub fn outputLen(ml: *MlInfer, tensor: u32) usize {
    _ = ml;
    _ = tensor;
    return 0;
}

pub fn argmaxOutput(ml: *MlInfer, tensor: u32) u32 {
    _ = ml;
    _ = tensor;
    return 0;
}

pub fn layoutIsNchw(ml: *MlInfer) bool {
    _ = ml;
    return false;
}

pub fn copyOutput(ml: *MlInfer, tensor: u32, dst: []f32) bool {
    _ = ml;
    _ = tensor;
    _ = dst;
    return false;
}

pub fn outputCount(ml: *MlInfer) u32 {
    _ = ml;
    return 0;
}
