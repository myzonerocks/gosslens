//! A model on either inference backend, chosen by the model bytes: a TFLite net
//! on the tracking runtime or an ONNX net on the self-contained ONNX engine.
//! Callers write and read tensors by index, so the byo-ml core and the diffusion
//! loop drive their models through it (the bytes must outlive the engine).

const std = @import("std");
const runtime = @import("runtime");
const onnx = @import("onnx");

pub const Error = error{ InvalidModel, OutOfMemory };

pub const Engine = struct {
    backend: union(enum) {
        tflite: runtime.Engine,
        onnx: onnx.Engine,
    },

    /// Loads model_bytes on the backend its own bytes name: a TFLite flatbuffer
    /// carries "TFL3" at offset 4, anything else is parsed as an ONNX protobuf.
    pub fn init(gpa: std.mem.Allocator, model_bytes: []const u8, threads: i32) Error!Engine {
        const is_tflite = model_bytes.len >= 8 and std.mem.eql(u8, model_bytes[4..8], "TFL3");
        if (is_tflite) {
            return .{ .backend = .{ .tflite = runtime.Engine.init(model_bytes, threads) catch return error.InvalidModel } };
        }
        return .{ .backend = .{ .onnx = onnx.Engine.init(gpa, model_bytes) catch return error.InvalidModel } };
    }

    pub fn deinit(self: *Engine) void {
        switch (self.backend) {
            inline else => |*e| e.deinit(),
        }
    }

    pub fn inputCount(self: *const Engine) usize {
        return switch (self.backend) {
            inline else => |*e| e.inputCount(),
        };
    }

    pub fn outputCount(self: *const Engine) usize {
        return switch (self.backend) {
            inline else => |*e| e.outputCount(),
        };
    }

    pub fn inputDims(self: *const Engine, index: usize, dims: []i32) anyerror![]i32 {
        return switch (self.backend) {
            inline else => |*e| e.inputDims(index, dims),
        };
    }

    pub fn outputDims(self: *const Engine, index: usize, dims: []i32) anyerror![]i32 {
        return switch (self.backend) {
            inline else => |*e| e.outputDims(index, dims),
        };
    }

    /// Writes one input tensor from raw float32 bytes; the length must match the
    /// tensor's byte size exactly, so a preprocessing mismatch fails loudly.
    /// Declares a concrete shape for one input. Only the ONNX backend needs
    /// this: a TFLite flatbuffer carries its own shapes, and a caller asking to
    /// change one is told so rather than silently ignored.
    pub fn resizeInput(self: *Engine, index: usize, dims: []const i64) anyerror!void {
        return switch (self.backend) {
            .onnx => |*e| e.resizeInput(index, dims),
            .tflite => error.Unsupported,
        };
    }

    /// Whether an input carries no usable shape of its own, which is what a
    /// symbolic spatial dim looks like once it is read.
    pub fn inputNeedsShape(self: *const Engine, index: usize) bool {
        var dims_buf: [8]i32 = undefined;
        const dims = self.inputDims(index, &dims_buf) catch return false;
        if (dims.len < 3) return false;
        var unit: usize = 0;
        for (dims) |d| {
            if (d <= 1) unit += 1;
        }
        return unit + 1 >= dims.len;
    }

    pub fn writeInput(self: *Engine, index: usize, bytes: []const u8) anyerror!void {
        return switch (self.backend) {
            inline else => |*e| e.writeInput(index, bytes),
        };
    }

    pub fn invoke(self: *Engine) anyerror!void {
        return switch (self.backend) {
            inline else => |*e| e.invoke(),
        };
    }

    pub fn outputFloats(self: *const Engine, index: usize) anyerror![]const f32 {
        return switch (self.backend) {
            inline else => |*e| e.outputFloats(index),
        };
    }
};

/// Names the operators a model needs that neither backend implements, one per
/// line, and answers the full size so a short buffer is a known truncation
/// rather than a silent one. A TFLite model reports nothing missing: its
/// operator set is the vendor runtime's, not this engine's.
pub fn missingOps(gpa: std.mem.Allocator, model_bytes: []const u8, out: []u8) usize {
    if (model_bytes.len >= 8 and std.mem.eql(u8, model_bytes[4..8], "TFL3")) return 0;
    return onnx.missingOps(gpa, model_bytes, out) catch 0;
}
