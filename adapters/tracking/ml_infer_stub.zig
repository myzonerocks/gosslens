//! Bring-your-own model inference on platforms without the compiled inference
//! stack: every entry refuses. The export layer reports the refusal as its own
//! status so an SDK can tell "not built here" from "no result yet".

const std = @import("std");
const math = @import("math");
const ml_tensor = @import("ml_tensor");

pub const supported = false;

pub const Norm = ml_tensor.Norm;
pub const CreateError = error{ Unsupported, InvalidModel, ModelRejected, OutOfMemory };

pub const max_outputs = 8;

pub const MlInfer = struct {};

pub const AudioInfer = struct {};

pub fn audioCreate(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32) CreateError!*AudioInfer {
    _ = gpa;
    _ = model_bytes;
    _ = bounds;
    _ = threads;
    return error.Unsupported;
}
pub fn audioDestroy(ai: *AudioInfer) void {
    _ = ai;
}
pub fn audioCompute(ai: *AudioInfer, window: []const f32) bool {
    _ = ai;
    _ = window;
    return false;
}
pub fn audioReadOutput(ai: *const AudioInfer, tensor: u32, index: u32) f32 {
    _ = ai;
    _ = tensor;
    _ = index;
    return 0;
}
pub fn audioArgmax(ai: *const AudioInfer, tensor: u32) u32 {
    _ = ai;
    _ = tensor;
    return 0;
}
pub fn audioOutputLen(ai: *const AudioInfer, tensor: u32) usize {
    _ = ai;
    _ = tensor;
    return 0;
}
pub fn audioOutputSlice(ai: *const AudioInfer, tensor: u32) []const f32 {
    _ = ai;
    _ = tensor;
    return &.{};
}

pub const TemporalCore = struct {};
pub const TemporalInfer = struct {};

pub fn temporalCreate(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32, frames: u32) CreateError!*TemporalInfer {
    _ = gpa;
    _ = model_bytes;
    _ = bounds;
    _ = threads;
    _ = frames;
    return error.Unsupported;
}
pub fn temporalDestroy(ti: *TemporalInfer) void {
    _ = ti;
}
pub fn temporalSubmitNv12(ti: *TemporalInfer, width: u32, height: u32, timestamp_us: i64, conversion: math.color.Conversion, y: [*]const u8, y_stride: u32, uv: [*]const u8, uv_stride: u32) void {
    _ = ti;
    _ = width;
    _ = height;
    _ = timestamp_us;
    _ = conversion;
    _ = y;
    _ = y_stride;
    _ = uv;
    _ = uv_stride;
}
pub fn temporalSetPhase(ti: *TemporalInfer, phase: f32) void {
    _ = ti;
    _ = phase;
}
pub fn temporalHasPublished(ti: *TemporalInfer) bool {
    _ = ti;
    return false;
}
pub fn temporalCopyStyle(ti: *TemporalInfer, dst: []f32) bool {
    _ = ti;
    _ = dst;
    return false;
}
pub fn temporalStyleLen(ti: *const TemporalInfer) usize {
    _ = ti;
    return 0;
}
pub fn temporalFilled(ti: *const TemporalInfer) u32 {
    _ = ti;
    return 0;
}
pub fn temporalLayoutIsNchw(ti: *const TemporalInfer) bool {
    _ = ti;
    return false;
}

pub const GenericModel = struct {};

pub fn genericCreate(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32) CreateError!*GenericModel {
    _ = gpa;
    _ = model_bytes;
    _ = bounds;
    _ = threads;
    return error.Unsupported;
}
pub fn genericDestroy(m: *GenericModel) void {
    _ = m;
}
pub fn genericWriteFloats(m: *GenericModel, index: usize, floats: []const f32) bool {
    _ = m;
    _ = index;
    _ = floats;
    return false;
}
pub fn genericInvoke(m: *GenericModel) bool {
    _ = m;
    return false;
}
pub fn genericOutput(m: *const GenericModel, index: usize) []const f32 {
    _ = m;
    _ = index;
    return &.{};
}
pub fn genericInputLen(m: *const GenericModel, index: usize) usize {
    _ = m;
    _ = index;
    return 0;
}
pub fn audioHasPublished(ai: *const AudioInfer) bool {
    _ = ai;
    return false;
}
pub fn audioInputLen(ai: *const AudioInfer) usize {
    _ = ai;
    return 0;
}

pub fn create(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32, norm: ml_tensor.Norm, aux_rgba: ?[]const u8, aux_width: u32, aux_height: u32, temporal: bool) CreateError!*MlInfer {
    _ = gpa;
    _ = model_bytes;
    _ = bounds;
    _ = threads;
    _ = norm;
    _ = aux_rgba;
    _ = aux_width;
    _ = aux_height;
    _ = temporal;
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
