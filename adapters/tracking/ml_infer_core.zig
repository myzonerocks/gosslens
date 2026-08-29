//! The synchronous bring-your-own model inference core, free of threading: it
//! loads a bounded TFLite or ONNX author model (picked by the model bytes),
//! samples the camera square into its input, invokes, and publishes outputs into
//! owned buffers. The worker wraps it off the frame thread; the web calls direct.

const std = @import("std");
const runtime = @import("runtime");
const onnx = @import("onnx");
const sampler = @import("sampler");
const ml_tensor = @import("ml_tensor");

pub const supported = true;

pub const CreateError = error{ Unsupported, InvalidModel, ModelRejected, OutOfMemory };

/// The most output tensors a byo-ml model may expose, a bound not a promise.
pub const max_outputs = 8;

/// The two model formats a lens may ship, each behind its own engine but the
/// same surface, so the core drives either identically.
const Backend = union(enum) {
    tflite: runtime.Engine,
    onnx: onnx.Engine,
};

/// How a model lays out its image input. The sampler writes interleaved RGB
/// (NHWC); an NCHW model takes the same pixels transposed to planar.
const Layout = enum { nhwc, nchw };

fn backendDeinit(b: *Backend) void {
    switch (b.*) {
        inline else => |*e| e.deinit(),
    }
}

fn backendInputCount(b: *const Backend) usize {
    return switch (b.*) {
        inline else => |*e| e.inputCount(),
    };
}

fn backendOutputCount(b: *const Backend) usize {
    return switch (b.*) {
        inline else => |*e| e.outputCount(),
    };
}

fn backendInputDims(b: *const Backend, dims: []i32) anyerror![]i32 {
    return switch (b.*) {
        inline else => |*e| e.inputDims(0, dims),
    };
}

fn backendWriteInput(b: *Backend, bytes: []const u8) anyerror!void {
    return switch (b.*) {
        inline else => |*e| e.writeInput(0, bytes),
    };
}

fn backendInvoke(b: *Backend) anyerror!void {
    return switch (b.*) {
        inline else => |*e| e.invoke(),
    };
}

fn backendOutputFloats(b: *const Backend, index: usize) anyerror![]const f32 {
    return switch (b.*) {
        inline else => |*e| e.outputFloats(index),
    };
}

/// A loaded author model: its backend engine, the reused RGB input plane, and
/// an owned copy of each output tensor so a reader never touches the live
/// engine output the next invoke overwrites. Outputs read zero until publish.
pub const Core = struct {
    gpa: std.mem.Allocator,
    model_bytes: []u8,
    backend: Backend,
    layout: Layout,
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

        // A TFLite flatbuffer carries "TFL3" at offset 4; anything else is
        // treated as an ONNX protobuf and rejected by its own parser if not.
        const is_tflite = owned_bytes.len >= 8 and std.mem.eql(u8, owned_bytes[4..8], "TFL3");
        var backend: Backend = if (is_tflite)
            .{ .tflite = runtime.Engine.init(owned_bytes, threads) catch return error.InvalidModel }
        else
            .{ .onnx = onnx.Engine.init(gpa, owned_bytes) catch return error.InvalidModel };
        errdefer backendDeinit(&backend);

        const in_count = backendInputCount(&backend);
        const out_count = backendOutputCount(&backend);
        if (in_count != 1) return error.InvalidModel;
        if (out_count == 0 or out_count > max_outputs) return error.InvalidModel;

        var in_dims_buf: [8]i32 = undefined;
        const in_dims = backendInputDims(&backend, &in_dims_buf) catch return error.InvalidModel;
        if (in_dims.len != 4) return error.InvalidModel;
        var layout: Layout = undefined;
        var side: i32 = 0;
        if (in_dims[3] == 3 and in_dims[1] > 0 and in_dims[1] == in_dims[2]) {
            layout = .nhwc;
            side = in_dims[1];
        } else if (in_dims[1] == 3 and in_dims[2] > 0 and in_dims[2] == in_dims[3]) {
            layout = .nchw;
            side = in_dims[2];
        } else return error.InvalidModel;
        const input_side: u32 = @intCast(side);

        const input_tensor = gpa.alloc(f32, @as(usize, input_side) * input_side * 3) catch return error.OutOfMemory;
        errdefer gpa.free(input_tensor);
        const nchw_scratch = if (layout == .nchw)
            gpa.alloc(f32, @as(usize, input_side) * input_side * 3) catch return error.OutOfMemory
        else
            try gpa.alloc(f32, 0);
        errdefer gpa.free(nchw_scratch);

        // The largest tensor and the tensor count feed the sandbox admission,
        // so an oversized or many-tensor model never allocates its buffers.
        var output_lens: [max_outputs]usize = @splat(0);
        var largest: u64 = @as(u64, input_side) * input_side * 3 * @sizeOf(f32);
        switch (backend) {
            .tflite => |*eng| {
                for (0..out_count) |i| {
                    const tensor = runtime.c.TfLiteInterpreterGetOutputTensor(eng.interpreter, @intCast(i)) orelse return error.InvalidModel;
                    const bytes = runtime.c.TfLiteTensorByteSize(tensor);
                    output_lens[i] = bytes / @sizeOf(f32);
                    largest = @max(largest, bytes);
                }
            },
            .onnx => {
                // ONNX output shapes are dynamic; a warm-up over zeroed input
                // discovers them and validates every op resolves at load.
                @memset(input_tensor, 0);
                writeSampledInput(&backend, layout, input_side, input_tensor, nchw_scratch) catch return error.InvalidModel;
                backendInvoke(&backend) catch return error.InvalidModel;
                for (0..out_count) |i| {
                    const floats = backendOutputFloats(&backend, i) catch return error.InvalidModel;
                    output_lens[i] = floats.len;
                    largest = @max(largest, floats.len * @sizeOf(f32));
                }
            },
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
            .backend = backend,
            .layout = layout,
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
        backendDeinit(&core.backend);
        gpa.free(core.nchw_scratch);
        gpa.free(core.input_tensor);
        gpa.free(core.model_bytes);
        gpa.destroy(core);
    }

    /// Samples the frame square into the input tensor and invokes the model,
    /// leaving the result in the engine for publish(). Reuses the input plane,
    /// so a compute allocates nothing.
    pub fn compute(core: *Core, frame: sampler.Frame) bool {
        sampler.sampleRegion(frame, sampler.frameSquare(frame.width, frame.height), .unit, core.input_side, core.input_tensor);
        writeSampledInput(&core.backend, core.layout, core.input_side, core.input_tensor, core.nchw_scratch) catch return false;
        backendInvoke(&core.backend) catch return false;
        return true;
    }

    /// Copies each engine output into its owned buffer, so a concurrent reader
    /// sees a stable copy rather than the output the next invoke overwrites.
    pub fn publish(core: *Core) void {
        for (0..core.output_count) |i| {
            const src = backendOutputFloats(&core.backend, i) catch continue;
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
        return core.layout == .nchw;
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

/// Writes the sampled RGB into the model's input tensor in its own layout: an
/// NHWC model takes the interleaved sample straight through; an NCHW model
/// takes it transposed to planar channels through the scratch buffer.
fn writeSampledInput(backend: *Backend, layout: Layout, side: u32, nhwc: []const f32, nchw_scratch: []f32) anyerror!void {
    switch (layout) {
        .nhwc => try backendWriteInput(backend, std.mem.sliceAsBytes(nhwc)),
        .nchw => {
            const s: usize = side;
            const plane = s * s;
            for (0..s) |y| {
                for (0..s) |x| {
                    const px = (y * s + x) * 3;
                    nchw_scratch[0 * plane + y * s + x] = nhwc[px + 0];
                    nchw_scratch[1 * plane + y * s + x] = nhwc[px + 1];
                    nchw_scratch[2 * plane + y * s + x] = nhwc[px + 2];
                }
            }
            try backendWriteInput(backend, std.mem.sliceAsBytes(nchw_scratch));
        },
    }
}
