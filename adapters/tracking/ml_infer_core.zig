//! The synchronous bring-your-own model inference core, free of threading: it
//! loads a bounded TFLite or ONNX author model (picked by the model bytes),
//! samples the camera square into its input, invokes, and publishes outputs into
//! owned buffers. The worker wraps it off the frame thread; the web calls direct.

const std = @import("std");
const ml_engine = @import("ml_engine");
const ml_sample = @import("ml_sample");
const sampler = @import("sampler");
const ml_tensor = @import("ml_tensor");

pub const supported = true;

pub const CreateError = error{ Unsupported, InvalidModel, ModelRejected, OutOfMemory };

/// The most output tensors a byo-ml model may expose, a bound not a promise.
pub const max_outputs = 8;

/// A loaded author model: its backend engine, the reused RGB input plane, and
/// an owned copy of each output tensor so a reader never touches the live
/// engine output the next invoke overwrites. Outputs read zero until publish.
pub const Core = struct {
    gpa: std.mem.Allocator,
    model_bytes: []u8,
    engine: ml_engine.Engine,
    in_sq: ml_sample.Square,
    input_side: u32,
    input_tensor: []f32,
    /// Planar scratch the NHWC sample transposes into for an NCHW model; empty
    /// for an NHWC model, which writes its input tensor straight through.
    nchw_scratch: []f32,
    output_count: u32,
    outputs: [max_outputs][]f32,
    published: bool = false,

    /// Loads the model under the sandbox bounds. Rejects a model whose input is
    /// not one square RGB image (NHWC or NCHW), whose output count is outside
    /// the bound, or whose bytes or tensors exceed the bounds.
    pub fn init(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32) CreateError!*Core {
        const core = gpa.create(Core) catch return error.OutOfMemory;
        errdefer gpa.destroy(core);

        // Guard the model size before building anything, so an oversized model
        // never runs a warm-up pass to discover its shapes.
        if (model_bytes.len > bounds.max_model_bytes) return error.ModelRejected;

        const owned_bytes = gpa.dupe(u8, model_bytes) catch return error.OutOfMemory;
        errdefer gpa.free(owned_bytes);

        var engine = ml_engine.Engine.init(gpa, owned_bytes, threads) catch return error.InvalidModel;
        errdefer engine.deinit();

        const in_count = engine.inputCount();
        const out_count = engine.outputCount();
        if (in_count != 1) return error.InvalidModel;
        if (out_count == 0 or out_count > max_outputs) return error.InvalidModel;

        var in_dims_buf: [8]i32 = undefined;
        const in_dims = engine.inputDims(0, &in_dims_buf) catch return error.InvalidModel;
        const in_sq = ml_sample.detectSquareRgb(in_dims) orelse return error.InvalidModel;
        const input_side: u32 = in_sq.side;

        const input_tensor = gpa.alloc(f32, @as(usize, input_side) * input_side * 3) catch return error.OutOfMemory;
        errdefer gpa.free(input_tensor);
        const nchw_scratch = if (in_sq.layout == .nchw)
            gpa.alloc(f32, @as(usize, input_side) * input_side * 3) catch return error.OutOfMemory
        else
            try gpa.alloc(f32, 0);
        errdefer gpa.free(nchw_scratch);

        // The largest tensor and the tensor count feed the sandbox admission,
        // so an oversized or many-tensor model never allocates its buffers. A
        // warm-up over zeroed input discovers every output length across both
        // backends and validates that each op resolves at load.
        var output_lens: [max_outputs]usize = @splat(0);
        var largest: u64 = @as(u64, input_side) * input_side * 3 * @sizeOf(f32);
        @memset(input_tensor, 0);
        ml_sample.writeSampled(&engine, 0, in_sq, input_tensor, nchw_scratch) catch return error.InvalidModel;
        engine.invoke() catch return error.InvalidModel;
        for (0..out_count) |i| {
            const floats = engine.outputFloats(i) catch return error.InvalidModel;
            output_lens[i] = floats.len;
            largest = @max(largest, floats.len * @sizeOf(f32));
        }
        if (!bounds.admits(owned_bytes.len, in_count + out_count, largest)) return error.ModelRejected;

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
            .in_sq = in_sq,
            .input_side = input_side,
            .input_tensor = input_tensor,
            .nchw_scratch = nchw_scratch,
            .output_count = @intCast(out_count),
            .outputs = outputs,
        };
        return core;
    }

    pub fn deinit(core: *Core) void {
        const gpa = core.gpa;
        for (core.outputs[0..core.output_count]) |buf| gpa.free(buf);
        core.engine.deinit();
        gpa.free(core.nchw_scratch);
        gpa.free(core.input_tensor);
        gpa.free(core.model_bytes);
        gpa.destroy(core);
    }

    /// Samples the frame square into the input tensor and invokes the model,
    /// leaving the result in the engine for publish(). Reuses the input plane,
    /// so a compute allocates nothing.
    pub fn compute(core: *Core, frame: sampler.Frame) bool {
        ml_sample.writeFrame(&core.engine, 0, core.in_sq, frame, core.input_tensor, core.nchw_scratch) catch return false;
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

    /// The element count of an output tensor, so a mask reader can size its
    /// copy; zero for an out-of-range tensor.
    pub fn outputLen(core: *const Core, tensor: u32) usize {
        if (tensor >= core.output_count) return 0;
        return core.outputs[tensor].len;
    }

    /// Whether the model's image tensors are channel-first (NCHW). A style
    /// output is read in the same layout the input declared.
    pub fn layoutIsNchw(core: *const Core) bool {
        return core.in_sq.layout == .nchw;
    }

    /// The index of the largest finite element of an output tensor, a
    /// classifier's predicted class; zero before the first publish or when the
    /// tensor holds no finite value.
    pub fn argmaxOutput(core: *const Core, tensor: u32) u32 {
        if (!core.published or tensor >= core.output_count) return 0;
        const buf = core.outputs[tensor];
        var best: usize = 0;
        var best_val = -std.math.inf(f32);
        for (buf, 0..) |v, i| {
            if (std.math.isFinite(v) and v > best_val) {
                best_val = v;
                best = i;
            }
        }
        return @intCast(best);
    }

    /// Copies a whole output tensor from the published copy into dst, for a
    /// consumer that reads a full mask rather than one element. False before the
    /// first publish or on a length mismatch, so a stale read never lands.
    pub fn copyOutput(core: *const Core, tensor: u32, dst: []f32) bool {
        if (!core.published or tensor >= core.output_count) return false;
        const buf = core.outputs[tensor];
        if (buf.len != dst.len) return false;
        @memcpy(dst, buf);
        return true;
    }
};

