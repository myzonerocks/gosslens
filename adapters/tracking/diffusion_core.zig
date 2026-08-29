//! The synchronous latent-diffusion restyle core: an optional VAE-encoder, a
//! UNet, and a VAE-decoder on an engine few-step schedule. With an encoder it
//! restyles the camera frame (img2img); without one it starts from seeded noise
//! (text to image). Denoises a few UNet steps and decodes RGB for a sprite.

const std = @import("std");
const ml_engine = @import("ml_engine");
const ml_sample = @import("ml_sample");
const sampler = @import("sampler");
const schedule = @import("diffusion_schedule");
const flow = @import("optical_flow");
const ml_tensor = @import("ml_tensor");

pub const supported = true;

pub const CreateError = error{ InvalidModel, ModelRejected, OutOfMemory };

/// The bundle's three model files plus an optional precomputed text embedding
/// (the conditioning the UNet's third input reads), all bytes the caller keeps
/// alive for the core's life.
pub const Bytes = struct {
    encoder: []const u8,
    unet: []const u8,
    decoder: []const u8,
    text_embedding: []const u8 = &.{},
};

/// The sampler's few-step run: how many denoising steps, how much of the source
/// frame to bury under noise (0 keeps it, 1 fully restyles), the seed for the
/// deterministic noise, and the temporal coherence (0 off, else how strongly the
/// flow-warped previous frame holds the restyle steady against flicker).
pub const Config = struct {
    steps: u32 = 4,
    strength: f32 = 0.6,
    seed: u64 = 0,
    coherence: f32 = 0,
};

pub const Core = struct {
    gpa: std.mem.Allocator,
    enc_bytes: []u8,
    unet_bytes: []u8,
    dec_bytes: []u8,
    enc: ?ml_engine.Engine,
    unet: ml_engine.Engine,
    dec: ml_engine.Engine,
    sched: schedule.Schedule,
    cfg: Config,

    in_sq: ml_sample.Square,
    latent_len: usize,
    unet_inputs: usize,
    out_side: u32,
    out_nchw: bool,

    nhwc_scratch: []f32,
    nchw_scratch: []f32,
    latent: []f32,
    latent_t: []f32,
    noise: []f32,
    timestep: []f32,
    cond: []f32,
    work_rgb: []f32,
    out_rgb: []f32,
    published: bool = false,

    // Temporal-coherence scratch, non-empty only when coherence is on and an
    // encoder is present (img2img). The flow runs at the output resolution.
    coherence: f32,
    flow_gray_prev: []f32,
    flow_gray_curr: []f32,
    flow_u: []f32,
    flow_v: []f32,
    warped_prev: []f32,
    prev_out: []f32,
    has_prev: bool = false,

    pub fn init(gpa: std.mem.Allocator, bytes: Bytes, bounds: ml_tensor.Bounds, cfg: Config, threads: i32) CreateError!*Core {
        if (bytes.encoder.len > bounds.max_model_bytes or bytes.unet.len > bounds.max_model_bytes or bytes.decoder.len > bounds.max_model_bytes) {
            return error.ModelRejected;
        }
        const core = gpa.create(Core) catch return error.OutOfMemory;
        errdefer gpa.destroy(core);

        const enc_bytes = gpa.dupe(u8, bytes.encoder) catch return error.OutOfMemory;
        errdefer gpa.free(enc_bytes);
        const unet_bytes = gpa.dupe(u8, bytes.unet) catch return error.OutOfMemory;
        errdefer gpa.free(unet_bytes);
        const dec_bytes = gpa.dupe(u8, bytes.decoder) catch return error.OutOfMemory;
        errdefer gpa.free(dec_bytes);

        var unet = ml_engine.Engine.init(gpa, unet_bytes, threads) catch return error.InvalidModel;
        errdefer unet.deinit();
        var dec = ml_engine.Engine.init(gpa, dec_bytes, threads) catch return error.InvalidModel;
        errdefer dec.deinit();

        // The UNet takes the latent (input 0), optionally a timestep (input 1)
        // and a conditioning embedding (input 2); the decoder takes the latent.
        const unet_inputs = unet.inputCount();
        if (unet_inputs == 0 or unet_inputs > 3 or unet.outputCount() == 0) return error.InvalidModel;
        if (dec.inputCount() != 1 or dec.outputCount() == 0) return error.InvalidModel;

        var dims_buf: [8]i32 = undefined;

        // With an encoder the loop restyles the camera frame (img2img); without
        // one it generates from pure noise, and the latent length comes from the
        // UNet's own latent input.
        var enc_opt: ?ml_engine.Engine = null;
        errdefer if (enc_opt) |*e| e.deinit();
        var in_sq: ml_sample.Square = .{ .layout = .nhwc, .side = 0 };
        var latent_len: usize = 0;
        if (bytes.encoder.len > 0) {
            enc_opt = ml_engine.Engine.init(gpa, enc_bytes, threads) catch return error.InvalidModel;
            const enc = &enc_opt.?;
            if (enc.inputCount() != 1 or enc.outputCount() == 0) return error.InvalidModel;
            const in_dims = enc.inputDims(0, &dims_buf) catch return error.InvalidModel;
            in_sq = ml_sample.detectSquareRgb(in_dims) orelse return error.InvalidModel;
        } else {
            latent_len = tensorLen(&unet, 0, &dims_buf);
            if (latent_len == 0) return error.InvalidModel;
        }

        const side: usize = in_sq.side;
        const nhwc_scratch = if (side > 0) gpa.alloc(f32, side * side * 3) catch return error.OutOfMemory else try gpa.alloc(f32, 0);
        errdefer gpa.free(nhwc_scratch);
        const nchw_scratch = if (side > 0 and in_sq.layout == .nchw) gpa.alloc(f32, side * side * 3) catch return error.OutOfMemory else try gpa.alloc(f32, 0);
        errdefer gpa.free(nchw_scratch);

        // Warm the encoder over a zeroed frame to learn the latent length.
        if (enc_opt) |*enc| {
            @memset(nhwc_scratch, 0);
            ml_sample.writeSampled(enc, 0, in_sq, nhwc_scratch, nchw_scratch) catch return error.InvalidModel;
            enc.invoke() catch return error.InvalidModel;
            latent_len = (enc.outputFloats(0) catch return error.InvalidModel).len;
            if (latent_len == 0) return error.InvalidModel;
        }

        const latent = gpa.alloc(f32, latent_len) catch return error.OutOfMemory;
        errdefer gpa.free(latent);
        const latent_t = gpa.alloc(f32, latent_len) catch return error.OutOfMemory;
        errdefer gpa.free(latent_t);
        const noise = gpa.alloc(f32, latent_len) catch return error.OutOfMemory;
        errdefer gpa.free(noise);

        // The timestep and conditioning buffers match the UNet's own input
        // lengths, filled per step; conditioning comes from the bundle or zero.
        const timestep_len = if (unet_inputs >= 2) tensorLen(&unet, 1, &dims_buf) else 0;
        const timestep = gpa.alloc(f32, timestep_len) catch return error.OutOfMemory;
        errdefer gpa.free(timestep);
        const cond_len = if (unet_inputs >= 3) tensorLen(&unet, 2, &dims_buf) else 0;
        const cond = gpa.alloc(f32, cond_len) catch return error.OutOfMemory;
        errdefer gpa.free(cond);
        @memset(cond, 0);
        if (cond_len > 0 and bytes.text_embedding.len >= cond_len * @sizeOf(f32)) {
            for (0..cond_len) |i| cond[i] = @bitCast(std.mem.readInt(u32, bytes.text_embedding[i * 4 ..][0..4], .little));
        }

        // Warm the UNet and decoder to validate their latent I/O lengths match.
        @memset(latent, 0);
        try warmUnet(&unet, unet_inputs, latent, timestep, cond, latent_len);
        dec.writeInput(0, std.mem.sliceAsBytes(latent)) catch return error.InvalidModel;
        dec.invoke() catch return error.InvalidModel;
        const dec_out = dec.outputFloats(0) catch return error.InvalidModel;
        var out_dims_buf: [8]i32 = undefined;
        const out_dims = dec.outputDims(0, &out_dims_buf) catch return error.InvalidModel;
        const out_sq = ml_sample.detectSquareRgb(out_dims) orelse return error.InvalidModel;
        if (dec_out.len != @as(usize, out_sq.side) * out_sq.side * 3) return error.InvalidModel;

        // Admission: the three model sizes and the largest live tensor stay
        // within the sandbox bounds before any per-frame buffer is trusted.
        const total_bytes = enc_bytes.len + unet_bytes.len + dec_bytes.len;
        const largest: u64 = @max(latent_len, @as(usize, out_sq.side) * out_sq.side * 3) * @sizeOf(f32);
        if (!bounds.admits(total_bytes, unet_inputs + 3, largest)) return error.ModelRejected;

        const work_rgb = gpa.alloc(f32, dec_out.len) catch return error.OutOfMemory;
        errdefer gpa.free(work_rgb);
        const out_rgb = gpa.alloc(f32, dec_out.len) catch return error.OutOfMemory;
        errdefer gpa.free(out_rgb);
        @memset(out_rgb, 0);

        // Temporal coherence needs a camera to move against, so it runs only in
        // img2img (an encoder present); its buffers are empty otherwise.
        const coherence: f32 = if (enc_opt != null) std.math.clamp(cfg.coherence, 0, 1) else 0;
        const out_grid: usize = @as(usize, out_sq.side) * out_sq.side;
        const flow_gray_prev = if (coherence > 0) gpa.alloc(f32, out_grid) catch return error.OutOfMemory else try gpa.alloc(f32, 0);
        errdefer gpa.free(flow_gray_prev);
        const flow_gray_curr = if (coherence > 0) gpa.alloc(f32, out_grid) catch return error.OutOfMemory else try gpa.alloc(f32, 0);
        errdefer gpa.free(flow_gray_curr);
        const flow_u = if (coherence > 0) gpa.alloc(f32, out_grid) catch return error.OutOfMemory else try gpa.alloc(f32, 0);
        errdefer gpa.free(flow_u);
        const flow_v = if (coherence > 0) gpa.alloc(f32, out_grid) catch return error.OutOfMemory else try gpa.alloc(f32, 0);
        errdefer gpa.free(flow_v);
        const warped_prev = if (coherence > 0) gpa.alloc(f32, dec_out.len) catch return error.OutOfMemory else try gpa.alloc(f32, 0);
        errdefer gpa.free(warped_prev);
        const prev_out = if (coherence > 0) gpa.alloc(f32, dec_out.len) catch return error.OutOfMemory else try gpa.alloc(f32, 0);
        errdefer gpa.free(prev_out);

        core.* = .{
            .gpa = gpa,
            .enc_bytes = enc_bytes,
            .unet_bytes = unet_bytes,
            .dec_bytes = dec_bytes,
            .enc = enc_opt,
            .unet = unet,
            .dec = dec,
            .sched = schedule.Schedule.init(1000, 0.00085, 0.012),
            .cfg = cfg,
            .in_sq = in_sq,
            .latent_len = latent_len,
            .unet_inputs = unet_inputs,
            .out_side = out_sq.side,
            .out_nchw = out_sq.layout == .nchw,
            .nhwc_scratch = nhwc_scratch,
            .nchw_scratch = nchw_scratch,
            .latent = latent,
            .latent_t = latent_t,
            .noise = noise,
            .timestep = timestep,
            .cond = cond,
            .work_rgb = work_rgb,
            .out_rgb = out_rgb,
            .coherence = coherence,
            .flow_gray_prev = flow_gray_prev,
            .flow_gray_curr = flow_gray_curr,
            .flow_u = flow_u,
            .flow_v = flow_v,
            .warped_prev = warped_prev,
            .prev_out = prev_out,
        };
        return core;
    }

    pub fn deinit(core: *Core) void {
        const gpa = core.gpa;
        gpa.free(core.prev_out);
        gpa.free(core.warped_prev);
        gpa.free(core.flow_v);
        gpa.free(core.flow_u);
        gpa.free(core.flow_gray_curr);
        gpa.free(core.flow_gray_prev);
        gpa.free(core.out_rgb);
        gpa.free(core.work_rgb);
        gpa.free(core.cond);
        gpa.free(core.timestep);
        gpa.free(core.noise);
        gpa.free(core.latent_t);
        gpa.free(core.latent);
        gpa.free(core.nchw_scratch);
        gpa.free(core.nhwc_scratch);
        core.dec.deinit();
        core.unet.deinit();
        if (core.enc) |*e| e.deinit();
        gpa.free(core.dec_bytes);
        gpa.free(core.unet_bytes);
        gpa.free(core.enc_bytes);
        gpa.destroy(core);
    }

    /// Runs the full restyle over one frame, leaving the decoded RGB in
    /// work_rgb for publish(). Reuses every buffer, so a compute allocates
    /// nothing. False on any model failure, leaving the last result intact.
    pub fn compute(core: *Core, frame: sampler.Frame) bool {
        const train_last = core.sched.train_steps - 1;
        var t_start: usize = train_last;
        if (core.enc) |*enc| {
            // img2img: encode the frame, then bury the latent under noise up to
            // the strength (0 keeps the frame, 1 approaches pure noise).
            ml_sample.writeFrame(enc, 0, core.in_sq, frame, core.nhwc_scratch, core.nchw_scratch) catch return false;
            enc.invoke() catch return false;
            const latent_out = enc.outputFloats(0) catch return false;
            if (latent_out.len != core.latent_len) return false;
            @memcpy(core.latent, latent_out);
            schedule.fillNoise(core.noise, core.cfg.seed);
            const strength = std.math.clamp(core.cfg.strength, 0, 1);
            t_start = @intFromFloat(strength * @as(f32, @floatFromInt(train_last)));
            core.sched.addNoise(core.latent, core.noise, t_start, core.latent_t);
        } else {
            // text to image: start from pure noise and denoise the whole range.
            schedule.fillNoise(core.latent_t, core.cfg.seed);
        }

        const steps = @max(@min(core.cfg.steps, schedule.max_steps), 1);
        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            const t = t_start * (steps - i) / steps;
            const t_prev = if (i + 1 < steps) t_start * (steps - i - 1) / steps else 0;
            core.unet.writeInput(0, std.mem.sliceAsBytes(core.latent_t)) catch return false;
            if (core.unet_inputs >= 2) {
                @memset(core.timestep, @floatFromInt(t));
                core.unet.writeInput(1, std.mem.sliceAsBytes(core.timestep)) catch return false;
            }
            if (core.unet_inputs >= 3) core.unet.writeInput(2, std.mem.sliceAsBytes(core.cond)) catch return false;
            core.unet.invoke() catch return false;
            const np = core.unet.outputFloats(0) catch return false;
            if (np.len != core.latent_len) return false;
            core.sched.ddimStep(core.latent_t, np, t, t_prev, core.latent_t);
        }

        core.dec.writeInput(0, std.mem.sliceAsBytes(core.latent_t)) catch return false;
        core.dec.invoke() catch return false;
        const rgb = core.dec.outputFloats(0) catch return false;
        if (rgb.len != core.work_rgb.len) return false;
        @memcpy(core.work_rgb, rgb);
        if (core.coherence > 0) core.stabilize();
        return true;
    }

    /// Warps the previous output by the flow between the last camera frame and
    /// this one, then blends the fresh decode toward it, so a per-frame restyle
    /// holds steady where content is still and follows it where it moves. The
    /// first frame just seeds the history. img2img only; keeps its own buffers.
    fn stabilize(core: *Core) void {
        const side: usize = core.out_side;
        const channels: usize = 3;
        flow.toGrayResampled(core.nhwc_scratch, core.in_sq.side, false, channels, side, core.flow_gray_curr);
        if (core.has_prev) {
            flow.lucasKanade(core.flow_gray_prev, core.flow_gray_curr, side, 2, 1e-3, core.flow_u, core.flow_v);
            flow.warp(core.prev_out, side, core.out_nchw, channels, core.flow_u, core.flow_v, core.warped_prev);
            flow.blend(core.work_rgb, core.warped_prev, core.coherence);
        }
        @memcpy(core.prev_out, core.work_rgb);
        @memcpy(core.flow_gray_prev, core.flow_gray_curr);
        core.has_prev = true;
    }

    /// Copies the freshly computed image into the published buffer, so a reader
    /// sees a stable frame rather than one a concurrent compute overwrites.
    pub fn publish(core: *Core) void {
        @memcpy(core.out_rgb, core.work_rgb);
        core.published = true;
    }

    /// Copies the published RGB image into dst; false before the first publish
    /// or on a size mismatch, so a stale read never lands.
    pub fn copyOutput(core: *const Core, dst: []f32) bool {
        if (!core.published or dst.len != core.out_rgb.len) return false;
        @memcpy(dst, core.out_rgb);
        return true;
    }

    pub fn outputLen(core: *const Core) usize {
        return core.out_rgb.len;
    }
};

fn tensorLen(engine: *ml_engine.Engine, index: usize, dims_buf: []i32) usize {
    const dims = engine.inputDims(index, dims_buf) catch return 0;
    var n: usize = 1;
    for (dims) |d| n *= @intCast(@max(d, 0));
    if (dims.len == 0) return 0;
    return n;
}

fn warmUnet(unet: *ml_engine.Engine, inputs: usize, latent: []const f32, timestep: []f32, cond: []const f32, latent_len: usize) CreateError!void {
    unet.writeInput(0, std.mem.sliceAsBytes(latent)) catch return error.InvalidModel;
    if (inputs >= 2) {
        @memset(timestep, 0);
        unet.writeInput(1, std.mem.sliceAsBytes(timestep)) catch return error.InvalidModel;
    }
    if (inputs >= 3) unet.writeInput(2, std.mem.sliceAsBytes(cond)) catch return error.InvalidModel;
    unet.invoke() catch return error.InvalidModel;
    const out = unet.outputFloats(0) catch return error.InvalidModel;
    if (out.len != latent_len) return error.InvalidModel;
}
