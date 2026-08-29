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
