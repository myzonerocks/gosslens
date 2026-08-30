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

/// The second input plane of a two-input (reference-conditioned) model: its
/// square, the sample scratch, and the owned reference RGBA the core resamples
/// into input 1 each compute. Built by setupAux with live errdefers so a
/// partial allocation never leaks; deinit frees all three.
const AuxPlane = struct {
    sq: ml_sample.Square,
    tensor: []f32,
    nchw_scratch: []f32,
    pixels: []u8,
    width: u32,
    height: u32,

    fn deinit(self: AuxPlane, gpa: std.mem.Allocator) void {
        gpa.free(self.tensor);
        gpa.free(self.nchw_scratch);
        gpa.free(self.pixels);
    }
};

/// Builds the aux plane for a two-input model: input 1 must be one square-RGB
/// image, and the caller must ship a reference at least width*height*4 bytes.
fn setupAux(gpa: std.mem.Allocator, engine: *ml_engine.Engine, rgba: []const u8, width: u32, height: u32) CreateError!AuxPlane {
    const need = @as(usize, width) * height * 4;
    if (width == 0 or height == 0 or rgba.len < need) return error.InvalidModel;
    var dims_buf: [8]i32 = undefined;
    const dims = engine.inputDims(1, &dims_buf) catch return error.InvalidModel;
    const sq = ml_sample.detectSquareRgb(dims) orelse return error.InvalidModel;
    const tensor = gpa.alloc(f32, @as(usize, sq.side) * sq.side * 3) catch return error.OutOfMemory;
    errdefer gpa.free(tensor);
    const scratch = if (sq.layout == .nchw)
        gpa.alloc(f32, @as(usize, sq.side) * sq.side * 3) catch return error.OutOfMemory
    else
        gpa.alloc(f32, 0) catch return error.OutOfMemory;
    errdefer gpa.free(scratch);
    const pixels = gpa.dupe(u8, rgba[0..need]) catch return error.OutOfMemory;
    return .{ .sq = sq, .tensor = tensor, .nchw_scratch = scratch, .pixels = pixels, .width = width, .height = height };
}

/// The second input of a temporal model: input 1 must be a square RGB the same
/// size as input 0 (both the frame), so the previous frame swaps in cleanly.
/// `prev` holds the last frame's sampled NHWC plane, zeroed at first.
const TemporalPlane = struct {
    sq: ml_sample.Square,
    nchw_scratch: []f32,
    prev: []f32,

    fn deinit(self: TemporalPlane, gpa: std.mem.Allocator) void {
        gpa.free(self.nchw_scratch);
        gpa.free(self.prev);
    }
};

fn setupTemporal(gpa: std.mem.Allocator, engine: *ml_engine.Engine, input_side: u32) CreateError!TemporalPlane {
    var dims_buf: [8]i32 = undefined;
    const dims = engine.inputDims(1, &dims_buf) catch return error.InvalidModel;
    const sq = ml_sample.detectSquareRgb(dims) orelse return error.InvalidModel;
    if (sq.side != input_side) return error.InvalidModel;
    const scratch = if (sq.layout == .nchw)
        gpa.alloc(f32, @as(usize, sq.side) * sq.side * 3) catch return error.OutOfMemory
    else
        gpa.alloc(f32, 0) catch return error.OutOfMemory;
    errdefer gpa.free(scratch);
    const prev = gpa.alloc(f32, @as(usize, sq.side) * sq.side * 3) catch return error.OutOfMemory;
    @memset(prev, 0);
    return .{ .sq = sq, .nchw_scratch = scratch, .prev = prev };
}

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
    /// An optional second input plane: a bundled reference image the model is
    /// conditioned on (makeup, style, or identity transfer). Set only when the
    /// model declares two square-RGB inputs. aux_pixels is the owned reference
    /// RGBA the core resamples into input 1 each compute.
    aux_sq: ?ml_sample.Square = null,
    aux_tensor: []f32 = &.{},
    aux_nchw_scratch: []f32 = &.{},
    aux_pixels: []u8 = &.{},
    aux_width: u32 = 0,
    aux_height: u32 = 0,
    /// Temporal mode: input 1 is the PREVIOUS frame, held here as the last
    /// frame's sampled NHWC plane and swapped in each compute, so a two-input
    /// model fuses the current and previous frame (interpolation, temporal
    /// denoise). Mutually exclusive with the reference aux above.
    temporal: bool = false,
    prev_input1: []f32 = &.{},
    prev_valid: bool = false,
    output_count: u32,
    outputs: [max_outputs][]f32,
    published: bool = false,

    /// Loads the model under the sandbox bounds. Rejects a model whose input is
    /// not one square RGB image (NHWC or NCHW), whose output count is outside
    /// the bound, or whose bytes or tensors exceed the bounds.
    pub fn init(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32, aux_rgba: ?[]const u8, aux_width: u32, aux_height: u32, temporal: bool) CreateError!*Core {
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
        if (in_count < 1 or in_count > 2) return error.InvalidModel;
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

        // A two-input model reads a second plane: a temporal model takes the
        // previous frame, otherwise a bundled reference. A one-input model
        // leaves both null.
        var aux: ?AuxPlane = null;
        errdefer if (aux) |a| a.deinit(gpa);
        var temp: ?TemporalPlane = null;
        errdefer if (temp) |t| t.deinit(gpa);
        if (in_count == 2) {
            if (temporal) {
                temp = try setupTemporal(gpa, &engine, input_side);
            } else {
                aux = try setupAux(gpa, &engine, aux_rgba orelse return error.InvalidModel, aux_width, aux_height);
            }
        }

        // The largest tensor and the tensor count feed the sandbox admission,
        // so an oversized or many-tensor model never allocates its buffers. A
        // warm-up over zeroed input discovers every output length across both
        // backends and validates that each op resolves at load.
        var output_lens: [max_outputs]usize = @splat(0);
        var largest: u64 = @as(u64, input_side) * input_side * 3 * @sizeOf(f32);
        @memset(input_tensor, 0);
        ml_sample.writeSampled(&engine, 0, in_sq, input_tensor, nchw_scratch) catch return error.InvalidModel;
        if (aux) |a| {
            const ref = sampler.Frame{ .pixels = .{ .rgba8 = a.pixels }, .width = a.width, .height = a.height };
            ml_sample.writeFrame(&engine, 1, a.sq, ref, a.tensor, a.nchw_scratch) catch return error.InvalidModel;
            largest = @max(largest, a.tensor.len * @sizeOf(f32));
        }
        if (temp) |t| {
            ml_sample.writeSampled(&engine, 1, t.sq, t.prev, t.nchw_scratch) catch return error.InvalidModel;
            largest = @max(largest, t.prev.len * @sizeOf(f32));
        }
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
            .aux_sq = if (aux) |a| a.sq else if (temp) |t| t.sq else null,
            .aux_tensor = if (aux) |a| a.tensor else &.{},
            .aux_nchw_scratch = if (aux) |a| a.nchw_scratch else if (temp) |t| t.nchw_scratch else &.{},
            .aux_pixels = if (aux) |a| a.pixels else &.{},
            .aux_width = if (aux) |a| a.width else 0,
            .aux_height = if (aux) |a| a.height else 0,
            .temporal = temporal,
            .prev_input1 = if (temp) |t| t.prev else &.{},
            .output_count = @intCast(out_count),
            .outputs = outputs,
        };
        return core;
    }

    pub fn deinit(core: *Core) void {
        const gpa = core.gpa;
        for (core.outputs[0..core.output_count]) |buf| gpa.free(buf);
        core.engine.deinit();
        gpa.free(core.aux_tensor);
        gpa.free(core.aux_nchw_scratch);
        gpa.free(core.aux_pixels);
        gpa.free(core.prev_input1);
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
        if (core.aux_sq) |sq| {
            if (core.temporal) {
                // Input 1 is the previous frame; the first frame is its own
                // previous so a cold start is not a black plane.
                const src = if (core.prev_valid) core.prev_input1 else core.input_tensor;
                ml_sample.writeSampled(&core.engine, 1, sq, src, core.aux_nchw_scratch) catch return false;
            } else {
                const ref = sampler.Frame{ .pixels = .{ .rgba8 = core.aux_pixels }, .width = core.aux_width, .height = core.aux_height };
                ml_sample.writeFrame(&core.engine, 1, sq, ref, core.aux_tensor, core.aux_nchw_scratch) catch return false;
            }
        }
        core.engine.invoke() catch return false;
        if (core.temporal) {
            @memcpy(core.prev_input1, core.input_tensor);
            core.prev_valid = true;
        }
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

/// A synchronous audio inference core: loads a bounded author model whose single
/// input is a 1-D window of PCM samples, writes a window in, invokes, and reads
/// scalar outputs, driving a lens parameter from the microphone. Sandboxed like
/// the frame core; run directly at tick since an audio window is small.
pub const AudioCore = struct {
    gpa: std.mem.Allocator,
    model_bytes: []u8,
    engine: ml_engine.Engine,
    input_len: usize,
    input_scratch: []f32,
    output_count: u32,
    outputs: [max_outputs][]f32,
    published: bool = false,

    /// The largest window a bounded audio model may take, so a hostile shape
    /// never allocates an unbounded buffer.
    const max_input_len: usize = 1 << 20;

    pub fn init(gpa: std.mem.Allocator, model_bytes: []const u8, bounds: ml_tensor.Bounds, threads: i32) CreateError!*AudioCore {
        const self = gpa.create(AudioCore) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);
        if (model_bytes.len > bounds.max_model_bytes) return error.ModelRejected;
        const owned = gpa.dupe(u8, model_bytes) catch return error.OutOfMemory;
        errdefer gpa.free(owned);
        var engine = ml_engine.Engine.init(gpa, owned, threads) catch return error.InvalidModel;
        errdefer engine.deinit();
        const in_count = engine.inputCount();
        const out_count = engine.outputCount();
        if (in_count != 1) return error.InvalidModel;
        if (out_count == 0 or out_count > max_outputs) return error.InvalidModel;
        var dims_buf: [8]i32 = undefined;
        const in_dims = engine.inputDims(0, &dims_buf) catch return error.InvalidModel;
        var in_len: usize = 1;
        for (in_dims) |d| {
            if (d <= 0) return error.InvalidModel;
            in_len *= @intCast(d);
        }
        if (in_len == 0 or in_len > max_input_len) return error.InvalidModel;
        const scratch = gpa.alloc(f32, in_len) catch return error.OutOfMemory;
        errdefer gpa.free(scratch);
        @memset(scratch, 0);
        // A warm-up over silence discovers every output length and validates the
        // ops resolve, so a broken model is rejected at load, not at the mic.
        engine.writeInput(0, std.mem.sliceAsBytes(scratch)) catch return error.InvalidModel;
        engine.invoke() catch return error.InvalidModel;
        var output_lens: [max_outputs]usize = @splat(0);
        var largest: u64 = @as(u64, in_len) * @sizeOf(f32);
        for (0..out_count) |i| {
            const floats = engine.outputFloats(i) catch return error.InvalidModel;
            output_lens[i] = floats.len;
            largest = @max(largest, floats.len * @sizeOf(f32));
        }
        if (!bounds.admits(owned.len, in_count + out_count, largest)) return error.ModelRejected;
        var outputs: [max_outputs][]f32 = @splat(&.{});
        var built: usize = 0;
        errdefer for (outputs[0..built]) |buf| gpa.free(buf);
        for (0..out_count) |i| {
            outputs[i] = gpa.alloc(f32, output_lens[i]) catch return error.OutOfMemory;
            @memset(outputs[i], 0);
            built += 1;
        }
        self.* = .{
            .gpa = gpa,
            .model_bytes = owned,
            .engine = engine,
            .input_len = in_len,
            .input_scratch = scratch,
            .output_count = @intCast(out_count),
            .outputs = outputs,
        };
        return self;
    }

    pub fn deinit(self: *AudioCore) void {
        const gpa = self.gpa;
        for (self.outputs[0..self.output_count]) |buf| gpa.free(buf);
        self.engine.deinit();
        gpa.free(self.input_scratch);
        gpa.free(self.model_bytes);
        gpa.destroy(self);
    }

    /// Writes a window of PCM into the model input (padded or truncated to its
    /// length), invokes, and copies the outputs into owned buffers. False on a
    /// backend error, leaving the last published outputs intact.
    pub fn compute(self: *AudioCore, window: []const f32) bool {
        const n = @min(window.len, self.input_len);
        @memcpy(self.input_scratch[0..n], window[0..n]);
        if (n < self.input_len) @memset(self.input_scratch[n..], 0);
        self.engine.writeInput(0, std.mem.sliceAsBytes(self.input_scratch)) catch return false;
        self.engine.invoke() catch return false;
        for (0..self.output_count) |i| {
            const floats = self.engine.outputFloats(i) catch return false;
            const m = @min(floats.len, self.outputs[i].len);
            @memcpy(self.outputs[i][0..m], floats[0..m]);
        }
        self.published = true;
        return true;
    }

    pub fn readOutput(self: *const AudioCore, tensor: u32, index: u32) f32 {
        if (tensor >= self.output_count) return 0;
        const buf = self.outputs[tensor];
        if (index >= buf.len) return 0;
        const v = buf[index];
        return if (v == v) v else 0;
    }

    pub fn argmaxOutput(self: *const AudioCore, tensor: u32) u32 {
        if (tensor >= self.output_count) return 0;
        const buf = self.outputs[tensor];
        var best: u32 = 0;
        var best_v: f32 = -std.math.inf(f32);
        for (buf, 0..) |v, i| {
            if (v == v and v > best_v) {
                best_v = v;
                best = @intCast(i);
            }
        }
        return best;
    }

    pub fn outputLen(self: *const AudioCore, tensor: u32) usize {
        if (tensor >= self.output_count) return 0;
        return self.outputs[tensor].len;
    }

    /// The whole published output tensor, for a consumer that reads a sequence
    /// (a caption's logits) rather than one element. Empty when out of range.
    pub fn outputSlice(self: *const AudioCore, tensor: u32) []const f32 {
        if (tensor >= self.output_count) return &.{};
        return self.outputs[tensor];
    }

    pub fn hasPublished(self: *const AudioCore) bool {
        return self.published;
    }

    pub fn inputLen(self: *const AudioCore) usize {
        return self.input_len;
    }
};

