//! Sampling the camera square into a model's square RGB input, in the channel
//! order the model declared. Shared by the byo-ml inference core and the
//! diffusion restyle core, so both feed a model the same way.

const std = @import("std");
const sampler = @import("sampler");
const ml_engine = @import("ml_engine");

pub const Layout = enum { nhwc, nchw };

pub const Square = struct { layout: Layout, side: u32 };

/// Reads a square-RGB input's channel order and side from its dims, or null if
/// the model's input is not one square three-channel plane.
pub fn detectSquareRgb(in_dims: []const i32) ?Square {
    if (in_dims.len != 4) return null;
    if (in_dims[3] == 3 and in_dims[1] > 0 and in_dims[1] == in_dims[2]) return .{ .layout = .nhwc, .side = @intCast(in_dims[1]) };
    if (in_dims[1] == 3 and in_dims[2] > 0 and in_dims[2] == in_dims[3]) return .{ .layout = .nchw, .side = @intCast(in_dims[2]) };
    return null;
}

/// Samples the frame square into nhwc_scratch (interleaved RGB in [0,1]) and
/// writes it to input `index` in the model's layout.
pub fn writeFrame(engine: *ml_engine.Engine, index: usize, sq: Square, frame: sampler.Frame, nhwc_scratch: []f32, nchw_scratch: []f32) anyerror!void {
    sampler.sampleRegion(frame, sampler.frameSquare(frame.width, frame.height), .unit, sq.side, nhwc_scratch);
    try writeSampled(engine, index, sq, nhwc_scratch, nchw_scratch);
}

/// Writes an already-sampled interleaved RGB plane to input `index`; an NCHW
/// model takes it transposed to planar channels through nchw_scratch.
pub fn writeSampled(engine: *ml_engine.Engine, index: usize, sq: Square, nhwc: []const f32, nchw_scratch: []f32) anyerror!void {
    switch (sq.layout) {
        .nhwc => try engine.writeInput(index, std.mem.sliceAsBytes(nhwc)),
        .nchw => {
            const s: usize = sq.side;
            const plane = s * s;
            for (0..s) |y| {
                for (0..s) |x| {
                    const px = (y * s + x) * 3;
                    nchw_scratch[0 * plane + y * s + x] = nhwc[px + 0];
                    nchw_scratch[1 * plane + y * s + x] = nhwc[px + 1];
                    nchw_scratch[2 * plane + y * s + x] = nhwc[px + 2];
                }
            }
            try engine.writeInput(index, std.mem.sliceAsBytes(nchw_scratch));
        },
    }
}

/// Packs a three-channel model output image into BGRA the dynamic texture
/// takes, reading either channel order, each value clamped and NaN-guarded.
pub fn packRgbToBgra(rgb: []const f32, side: u32, nchw: bool, bgra: []u8) void {
    const s: usize = side;
    const plane = s * s;
    for (0..plane) |i| {
        const rv = if (nchw) rgb[0 * plane + i] else rgb[i * 3 + 0];
        const gv = if (nchw) rgb[1 * plane + i] else rgb[i * 3 + 1];
        const bv = if (nchw) rgb[2 * plane + i] else rgb[i * 3 + 2];
        bgra[i * 4 + 0] = toU8(bv);
        bgra[i * 4 + 1] = toU8(gv);
        bgra[i * 4 + 2] = toU8(rv);
        bgra[i * 4 + 3] = 255;
    }
}

fn toU8(v: f32) u8 {
    if (!(v > 0)) return 0;
    if (v >= 1) return 255;
    return @intFromFloat(v * 255.0);
}
