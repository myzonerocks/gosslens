//! The synchronous segmentation inference core, free of any threading:
//! build the engine, sample a frame, invoke, read the mask. The host and
//! android wrap it in a worker thread (segmentation.zig); the web tier
//! calls it directly on its single thread.

const std = @import("std");
const runtime = @import("runtime");
const sampler = @import("sampler");
const transpose_conv_bias = @import("transpose_conv_bias");

pub const supported = true;

pub const CreateError = error{ Unsupported, InvalidModel, OutOfMemory };

/// The canonical grid every reader gets a mask on, regardless of the
/// model's native resolution. Downstream textures are sized to this, so
/// a model that infers at another resolution is resampled onto it.
pub const mask_side = 256;
pub const mask_len = mask_side * mask_side;
/// More classes than any pinned model carries; a bound, not a promise.
/// Portrait segmenters emit a handful, scene segmenters like deeplab
/// carry twenty-one, so the ceiling sits above the widest we vendor.
pub const max_classes = 32;

/// compute() samples and invokes; publish() lifts the result into
/// `values`, kept separate so a worker holds its mask lock only across
/// the cheap publish, not the whole inference. Readers see zeros until
/// the first publish.
pub const Core = struct {
    gpa: std.mem.Allocator,
    model_bytes: []u8,
    engine: runtime.Engine,
    /// One for the selfie/hair segmenters, six for the multiclass model,
    /// twenty-one for the deeplab scene segmenter - read off the model's
    /// own output tensor at create.
    class_count: u32,
    /// The model's native square input side and output plane size, which
    /// need not be the canonical 256: deeplab infers 257 x 257.
    input_side: u32,
    out_width: u32,
    out_height: u32,
    /// input_side * input_side * 3 RGB floats.
    input_tensor: []f32,
    /// out_width * out_height * class_count floats, interleaved per pixel
    /// the way the model emits them - one probability per class.
    values: []f32,
    published: bool = false,

    pub fn init(gpa: std.mem.Allocator, model_bytes: []const u8, threads: i32) CreateError!*Core {
        const core = gpa.create(Core) catch return error.OutOfMemory;
        errdefer gpa.destroy(core);

        const owned_bytes = gpa.dupe(u8, model_bytes) catch return error.OutOfMemory;
        errdefer gpa.free(owned_bytes);

        // The custom upsample op the selfie and hair segmenters both need
        // to load at all.
        var engine = runtime.Engine.initWithCustomOps(owned_bytes, threads, &.{transpose_conv_bias.register}) catch
            return error.InvalidModel;
        errdefer engine.deinit();
        if (engine.inputCount() != 1 or engine.outputCount() != 1) return error.InvalidModel;

        // The model names its own resolution. Input is a square NHWC RGB
        // plane; anything else is a model this core does not drive.
        var in_dims_buf: [8]i32 = undefined;
        const in_dims = engine.inputDims(0, &in_dims_buf) catch return error.InvalidModel;
        if (in_dims.len != 4) return error.InvalidModel;
        if (in_dims[1] <= 0 or in_dims[1] != in_dims[2] or in_dims[3] != 3) return error.InvalidModel;
        const input_side: u32 = @intCast(in_dims[1]);

        // Output is NHWC one probability plane per class; the class count
        // is the channel axis, the plane its height and width.
        var out_dims_buf: [8]i32 = undefined;
        const out_dims = engine.outputDims(0, &out_dims_buf) catch return error.InvalidModel;
        if (out_dims.len != 4) return error.InvalidModel;
        if (out_dims[1] <= 0 or out_dims[2] <= 0 or out_dims[3] <= 0) return error.InvalidModel;
        const out_height: u32 = @intCast(out_dims[1]);
        const out_width: u32 = @intCast(out_dims[2]);
        const class_count: u32 = @intCast(out_dims[3]);
        if (class_count > max_classes) return error.InvalidModel;

        const output_floats = runtime.c.TfLiteTensorByteSize(runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, 0).?) / @sizeOf(f32);
        if (output_floats != @as(usize, out_width) * out_height * class_count) return error.InvalidModel;

        const input_tensor = gpa.alloc(f32, @as(usize, input_side) * input_side * 3) catch return error.OutOfMemory;
        errdefer gpa.free(input_tensor);

        const values = gpa.alloc(f32, output_floats) catch return error.OutOfMemory;
        errdefer gpa.free(values);
        @memset(values, 0);

        core.* = .{
            .gpa = gpa,
            .model_bytes = owned_bytes,
            .engine = engine,
            .class_count = class_count,
            .input_side = input_side,
            .out_width = out_width,
            .out_height = out_height,
            .input_tensor = input_tensor,
            .values = values,
        };
        return core;
    }

    pub fn deinit(core: *Core) void {
        const gpa = core.gpa;
        core.engine.deinit();
        gpa.free(core.values);
        gpa.free(core.input_tensor);
        gpa.free(core.model_bytes);
        gpa.destroy(core);
    }

    /// Samples the frame square into the input tensor and invokes the
    /// model, leaving the mask in the engine's output for publish().
    pub fn compute(core: *Core, frame: sampler.Frame) bool {
        sampler.sampleRegion(frame, sampler.frameSquare(frame.width, frame.height), .unit, core.input_side, core.input_tensor);
        core.engine.writeInput(0, std.mem.sliceAsBytes(core.input_tensor)) catch return false;
        core.engine.invoke() catch return false;
        return true;
    }

    /// Copies the engine output into `values`, softmaxing the multiclass
    /// model's per-pixel logits so every reader sees probabilities.
    pub fn publish(core: *Core) void {
        const mask = core.engine.outputFloats(0) catch return;
        if (mask.len != core.values.len) return;
        if (core.class_count == 1) {
            // The single-class segmenters bake their sigmoid into the model.
            @memcpy(core.values, mask);
        } else {
            const stride = core.class_count;
            var at: usize = 0;
            while (at < mask.len) : (at += stride) {
                const pixel = mask[at..][0..stride];
                var max_logit = pixel[0];
                for (pixel[1..]) |value| max_logit = @max(max_logit, value);
                var sum: f32 = 0;
                const out_pixel = core.values[at..][0..stride];
                for (pixel, out_pixel) |value, *out_value| {
                    out_value.* = @exp(value - max_logit);
                    sum += out_value.*;
                }
                for (out_pixel) |*out_value| out_value.* /= sum;
            }
        }
        core.published = true;
    }

    /// One class plane's probability at a canonical-grid pixel, resampled
    /// from the model's native plane. A model that already infers at the
    /// canonical side reads straight through, byte for byte.
    fn classAt(core: *const Core, class_index: u32, pixel: usize) f32 {
        const stride = core.class_count;
        if (core.out_width == mask_side and core.out_height == mask_side) {
            return core.values[pixel * stride + class_index];
        }
        const cx: f32 = @floatFromInt(pixel % mask_side);
        const cy: f32 = @floatFromInt(pixel / mask_side);
        const fx = (cx + 0.5) * @as(f32, @floatFromInt(core.out_width)) / mask_side - 0.5;
        const fy = (cy + 0.5) * @as(f32, @floatFromInt(core.out_height)) / mask_side - 0.5;
        const x0 = clampIndex(@floor(fx), core.out_width);
        const x1 = clampIndex(@floor(fx) + 1, core.out_width);
        const y0 = clampIndex(@floor(fy), core.out_height);
        const y1 = clampIndex(@floor(fy) + 1, core.out_height);
        const tx = std.math.clamp(fx - @floor(fx), 0, 1);
        const ty = std.math.clamp(fy - @floor(fy), 0, 1);
        const row0 = y0 * core.out_width;
        const row1 = y1 * core.out_width;
        const v00 = core.values[(row0 + x0) * stride + class_index];
        const v10 = core.values[(row0 + x1) * stride + class_index];
        const v01 = core.values[(row1 + x0) * stride + class_index];
        const v11 = core.values[(row1 + x1) * stride + class_index];
        const top = v00 + (v10 - v00) * tx;
        const bottom = v01 + (v11 - v01) * tx;
        return top + (bottom - top) * ty;
    }

    fn clampIndex(coord: f32, extent: u32) usize {
        if (coord <= 0) return 0;
        const last = extent - 1;
        if (coord >= @as(f32, @floatFromInt(last))) return last;
        return @intFromFloat(coord);
    }

    /// The subject mask: a single-class model's own output, or one minus
    /// the multiclass background class. False until the first publish.
    pub fn subjectMask(core: *const Core, out: *[mask_len]f32) bool {
        if (!core.published) return false;
        if (core.class_count == 1) {
            for (out, 0..) |*value, at| value.* = core.classAt(0, at);
            return true;
        }
        for (out, 0..) |*value, at| value.* = 1.0 - core.classAt(0, at);
        return true;
    }

    /// One class's mask plane. False until the first publish, or for a
    /// class the model does not have.
    pub fn classMask(core: *const Core, class_index: u32, out: *[mask_len]f32) bool {
        if (!core.published) return false;
        if (class_index >= core.class_count) return false;
        for (out, 0..) |*value, at| value.* = core.classAt(class_index, at);
        return true;
    }
};
