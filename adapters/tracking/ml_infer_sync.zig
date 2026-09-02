//! The bring-your-own model rail on targets with no threads (the web): the
//! same synchronous inference core the threaded worker wraps, driven directly
//! inside submit, so a frame's inference completes before the call returns.
//! The public surface mirrors ml_infer.zig one to one.

const std = @import("std");
const math = @import("math");
const sampler = @import("sampler");
const ml_tensor = @import("ml_tensor");
const core_mod = @import("ml_infer_core");

pub const supported = core_mod.supported;
pub const Norm = ml_tensor.Norm;
pub const CreateError = core_mod.CreateError;
pub const Core = core_mod.Core;
pub const max_outputs = core_mod.max_outputs;

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
pub fn audioHasPublished(ai: *const AudioInfer) bool {
    return ai.hasPublished();
}
pub fn audioInputLen(ai: *const AudioInfer) usize {
    return ai.inputLen();
}

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

/// The synchronous frame worker: the core alone, computed in place. The
/// submitted planes are only borrowed for the call, so nothing is copied.
pub const MlInfer = struct {
    gpa: std.mem.Allocator,
    core: *Core,
};

pub fn create(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32, norm: ml_tensor.Norm, aux_rgba: ?[]const u8, aux_width: u32, aux_height: u32, temporal: bool) CreateError!*MlInfer {
    const ml = gpa.create(MlInfer) catch return error.OutOfMemory;
    errdefer gpa.destroy(ml);
    const core = try Core.init(gpa, model_bytes, bounds, threads, norm, aux_rgba, aux_width, aux_height, temporal);
    ml.* = .{ .gpa = gpa, .core = core };
    return ml;
}

pub fn destroy(ml: *MlInfer) void {
    const gpa = ml.gpa;
    ml.core.deinit();
    gpa.destroy(ml);
}

/// Runs one NV12 frame through the model before returning, so the newest
/// published output is this frame's own inference.
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
    _ = timestamp_us;
    const image = nv12Frame(width, height, conversion, y, y_stride, uv, uv_stride);
    if (!ml.core.compute(image)) return;
    ml.core.publish();
}

fn nv12Frame(width: u32, height: u32, conversion: math.color.Conversion, y: [*]const u8, y_stride: u32, uv: [*]const u8, uv_stride: u32) sampler.Frame {
    const y_len = @as(usize, y_stride) * height;
    const uv_len = @as(usize, uv_stride) * ((height + 1) / 2);
    return .{
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
}

pub fn readOutput(ml: *MlInfer, tensor: u32, index: u32) f32 {
    return ml.core.readOutput(tensor, index);
}

pub fn hasPublished(ml: *MlInfer) bool {
    return ml.core.published;
}

pub fn outputLen(ml: *MlInfer, tensor: u32) usize {
    return ml.core.outputLen(tensor);
}

pub fn argmaxOutput(ml: *MlInfer, tensor: u32) u32 {
    return ml.core.argmaxOutput(tensor);
}

pub fn layoutIsNchw(ml: *MlInfer) bool {
    return ml.core.layoutIsNchw();
}

pub fn copyOutput(ml: *MlInfer, tensor: u32, dst: []f32) bool {
    return ml.core.copyOutput(tensor, dst);
}

pub fn outputCount(ml: *MlInfer) u32 {
    return ml.core.output_count;
}

pub const TemporalCore = core_mod.TemporalCore;

/// The synchronous fusion worker: feeds the ring and fuses in place once it
/// holds a full set of distinct frames.
pub const TemporalInfer = struct {
    gpa: std.mem.Allocator,
    core: *TemporalCore,
};

pub fn temporalCreate(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32, frames: u32) CreateError!*TemporalInfer {
    const ti = gpa.create(TemporalInfer) catch return error.OutOfMemory;
    errdefer gpa.destroy(ti);
    const core = try TemporalCore.init(gpa, model_bytes, bounds, threads, frames);
    ti.* = .{ .gpa = gpa, .core = core };
    return ti;
}

pub fn temporalDestroy(ti: *TemporalInfer) void {
    const gpa = ti.gpa;
    ti.core.deinit();
    gpa.destroy(ti);
}

pub fn temporalSubmitNv12(ti: *TemporalInfer, width: u32, height: u32, timestamp_us: i64, conversion: math.color.Conversion, y: [*]const u8, y_stride: u32, uv: [*]const u8, uv_stride: u32) void {
    const image = nv12Frame(width, height, conversion, y, y_stride, uv, uv_stride);
    _ = ti.core.feed(image, timestamp_us);
    if (!ti.core.ready()) return;
    if (!ti.core.compute()) return;
    ti.core.publish();
}

pub fn temporalSetPhase(ti: *TemporalInfer, phase: f32) void {
    ti.core.setPhase(phase);
}

pub fn temporalHasPublished(ti: *TemporalInfer) bool {
    return ti.core.published;
}

pub fn temporalCopyStyle(ti: *TemporalInfer, dst: []f32) bool {
    return ti.core.copyStyle(dst);
}

pub fn temporalStyleLen(ti: *const TemporalInfer) usize {
    return ti.core.styleLen();
}

pub fn temporalFilled(ti: *const TemporalInfer) u32 {
    return ti.core.filled;
}

pub fn temporalLayoutIsNchw(ti: *const TemporalInfer) bool {
    return ti.core.layoutIsNchw();
}
