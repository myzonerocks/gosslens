//! The synchronous bring-your-own model inference core, free of threading:
//! load a bounded author model on the tracking runtime, sample the camera
//! square into its RGB input, invoke, publish outputs into owned buffers. The
//! worker wraps it off the frame thread; the web tier calls it on one thread.

const std = @import("std");
const runtime = @import("runtime");
const sampler = @import("sampler");
const ml_tensor = @import("ml_tensor");

pub const supported = true;

pub const CreateError = error{ Unsupported, InvalidModel, ModelRejected, OutOfMemory };

/// The most output tensors a byo-ml model may expose, a bound not a promise.
pub const max_outputs = 8;

/// A loaded author model: its engine, the reused RGB input plane, and an owned
/// copy of each output tensor so a reader never touches the live engine output
/// the next invoke overwrites. Outputs read as zero until the first publish.
pub const Core = struct {
    gpa: std.mem.Allocator,
    model_bytes: []u8,
    engine: runtime.Engine,
    input_side: u32,
    input_tensor: []f32,
    output_count: u32,
    outputs: [max_outputs][]f32,
    published: bool = false,

    /// Loads the model under the sandbox bounds. Rejects a model whose input
    /// is not one square NHWC RGB plane, whose output count is outside the
    /// bound, or whose bytes or tensors exceed the bounds.
    pub fn init(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32) CreateError!*Core {
        const core = gpa.create(Core) catch return error.OutOfMemory;
        errdefer gpa.destroy(core);

        const owned_bytes = gpa.dupe(u8, model_bytes) catch return error.OutOfMemory;
        errdefer gpa.free(owned_bytes);

        var engine = runtime.Engine.init(owned_bytes, threads) catch return error.InvalidModel;
        errdefer engine.deinit();

        const in_count = engine.inputCount();
        const out_count = engine.outputCount();
        if (in_count != 1) return error.InvalidModel;
        if (out_count == 0 or out_count > max_outputs) return error.InvalidModel;

        var in_dims_buf: [8]i32 = undefined;
        const in_dims = engine.inputDims(0, &in_dims_buf) catch return error.InvalidModel;
        if (in_dims.len != 4) return error.InvalidModel;
        if (in_dims[1] <= 0 or in_dims[1] != in_dims[2] or in_dims[3] != 3) return error.InvalidModel;
        const input_side: u32 = @intCast(in_dims[1]);

        // The largest tensor and the tensor count feed the sandbox admission,
        // so an oversized or many-tensor model never allocates its buffers.
        var output_lens: [max_outputs]usize = @splat(0);
        var largest: u64 = @as(u64, input_side) * input_side * 3 * @sizeOf(f32);
        for (0..out_count) |i| {
            const tensor = runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, @intCast(i)) orelse return error.InvalidModel;
            const bytes = runtime.c.TfLiteTensorByteSize(tensor);
            output_lens[i] = bytes / @sizeOf(f32);
            largest = @max(largest, bytes);
        }
        if (!bounds.admits(owned_bytes.len, in_count + out_count, largest)) return error.ModelRejected;

        const input_tensor = gpa.alloc(f32, @as(usize, input_side) * input_side * 3) catch return error.OutOfMemory;
        errdefer gpa.free(input_tensor);

        var outputs: [max_outputs][]f32 = @splat(&.{});
        var built: usize = 0;
        errdefer for (outputs[0..built]) |buf| gpa.free(buf);
        for (0..out_count) |i| {
            outputs[i] = gpa.alloc(f32, output_lens[i]) catch return error.OutOfMemory;
            @memset(outputs[i], 0);
            built += 1;
        }

        core.* = .{
            .gpa = gpa,
            .model_bytes = owned_bytes,
            .engine = engine,
            .input_side = input_side,
            .input_tensor = input_tensor,
            .output_count = @intCast(out_count),
            .outputs = outputs,
        };
        return core;
    }

    pub fn deinit(core: *Core) void {
        const gpa = core.gpa;
        for (core.outputs[0..core.output_count]) |buf| gpa.free(buf);
        core.engine.deinit();
        gpa.free(core.input_tensor);
        gpa.free(core.model_bytes);
        gpa.destroy(core);
    }

    /// Samples the frame square into the input tensor and invokes the model,
    /// leaving the result in the engine for publish(). Reuses the input plane,
    /// so a compute allocates nothing.
    pub fn compute(core: *Core, frame: sampler.Frame) bool {
        sampler.sampleRegion(frame, sampler.frameSquare(frame.width, frame.height), .unit, core.input_side, core.input_tensor);
        core.engine.writeInput(0, std.mem.sliceAsBytes(core.input_tensor)) catch return false;
        core.engine.invoke() catch return false;
        return true;
    }

    /// Copies each engine output into its owned buffer, so a concurrent reader
    /// sees a stable copy rather than the output the next invoke overwrites.
    pub fn publish(core: *Core) void {
        for (0..core.output_count) |i| {
            const src = core.engine.outputFloats(i) catch continue;
            const dst = core.outputs[i];
            if (src.len == dst.len) @memcpy(dst, src);
        }
        core.published = true;
    }

    /// One output tensor element from the published copy, guarded against an
    /// out-of-range read and a non-finite value an untrusted model may emit;
    /// zero before the first publish or outside the tensor.
    pub fn readOutput(core: *const Core, tensor: u32, index: u32) f32 {
        if (!core.published or tensor >= core.output_count) return 0;
        const buf = core.outputs[tensor];
        if (index >= buf.len) return 0;
        const value = buf[index];
        if (!std.math.isFinite(value)) return 0;
        return value;
    }
};
