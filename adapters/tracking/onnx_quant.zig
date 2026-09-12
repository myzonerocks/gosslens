//! Quantization. Weights arrive as uint8 or int8 with a scale and a zero point,
//! per tensor or per output channel, and the integer kernels accumulate in i32
//! exactly, because a float accumulator stops being exact past 2^24 and a real
//! convolution's channel count reaches that.

const std = @import("std");
const onnx = @import("onnx.zig");
const simd = @import("onnx_simd.zig");

const Tensor = onnx.Tensor;
const DType = onnx.DType;
const Node = onnx.Node;
const Error = onnx.Error;
const Table = std.StringHashMapUnmanaged(Tensor);

const get = onnx.get;
const in = onnx.in;
const eq = onnx.eq;
const newTensor = onnx.newTensor;

pub fn dispatch(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!?Tensor {
    const op = node.op_type;
    if (eq(op, "QuantizeLinear")) return try quantizeLinear(ra, node, table);
    if (eq(op, "DequantizeLinear")) return try dequantizeLinear(ra, node, table);
    if (eq(op, "QLinearMatMul")) return try qLinearMatMul(ra, node, table);
    if (eq(op, "QLinearConv")) return try qLinearConv(ra, node, table);
    if (eq(op, "ConvInteger")) return try convInteger(ra, node, table);
    if (eq(op, "QLinearAdd")) return try qLinearAdd(ra, node, table);
    if (eq(op, "QLinearGlobalAveragePool")) return try qLinearGlobalAveragePool(ra, node, table);
    return null;
}

/// DynamicQuantizeLinear has three outputs, so it writes the table itself.
pub fn dispatchMulti(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!bool {
    if (eq(node.op_type, "DynamicQuantizeLinear")) {
        try dynamicQuantizeLinear(ra, node, table);
        return true;
    }
    return false;
}

/// Scale and zero point per element, whichever axis they are declared along. A
/// per-channel scale is one number per output channel and a per-tensor scale is
/// one number for all of them, and the same walk serves both.
const Affine = struct {
    scale: Tensor,
    zero: ?Tensor,
    axis: usize,
    blocks: usize,

    fn scaleAt(a: Affine, channel: usize) f32 {
        if (a.scale.data.len <= 1) return if (a.scale.data.len == 1) a.scale.data[0] else 1;
        return a.scale.data[channel % a.scale.data.len];
    }

    fn zeroAt(a: Affine, channel: usize) f32 {
        const z = a.zero orelse return 0;
        if (z.data.len == 0) return 0;
        if (z.data.len == 1) return z.data[0];
        return z.data[channel % z.data.len];
    }
};

fn affineFrom(node: *const Node, table: *Table, scale_idx: usize, zero_idx: usize, rank: usize) Error!Affine {
    const scale = try in(table, node, scale_idx);
    const zero: ?Tensor = if (node.inputs.len > zero_idx and node.inputs[zero_idx].len != 0) try get(table, node.inputs[zero_idx]) else null;
    var axis = node.attrInt("axis", 1);
    if (axis < 0) axis += @intCast(rank);
    if (axis < 0 or (rank != 0 and axis >= @as(i64, @intCast(rank)))) axis = 0;
    return .{ .scale = scale, .zero = zero, .axis = @intCast(axis), .blocks = @max(scale.data.len, 1) };
}

/// Walks a tensor once, handing each element its channel index along an axis,
/// which is what a per-channel scale is indexed by.
fn channelOf(dims: []const i64, axis: usize, flat: usize) usize {
    var inner: usize = 1;
    for (axis + 1..dims.len) |d| inner *= @intCast(@max(dims[d], 1));
    const extent: usize = if (axis < dims.len) @intCast(@max(dims[axis], 1)) else 1;
    if (inner == 0 or extent == 0) return 0;
    return (flat / inner) % extent;
}

fn quantizeLinear(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const affine = try affineFrom(node, table, 1, 2, x.dims.len);
    const want: DType = if (affine.zero) |z| z.dtype else .u8;
    var out = try newTensor(ra, ra.dupe(i64, x.dims) catch return error.OutOfMemory);
    out.dtype = want;
    const per_tensor = affine.scale.data.len <= 1;
    for (x.data, 0..) |v, i| {
        const c = if (per_tensor) 0 else channelOf(x.dims, affine.axis, i);
        const s = affine.scaleAt(c);
        if (s == 0) return error.TensorShapeMismatch;
        out.data[i] = want.clamp(@round(v / s) + affine.zeroAt(c));
    }
    return out;
}

fn dequantizeLinear(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const affine = try affineFrom(node, table, 1, 2, x.dims.len);
    const out = try newTensor(ra, ra.dupe(i64, x.dims) catch return error.OutOfMemory);
    const per_tensor = affine.scale.data.len <= 1;
    for (x.data, 0..) |v, i| {
        const c = if (per_tensor) 0 else channelOf(x.dims, affine.axis, i);
        out.data[i] = (v - affine.zeroAt(c)) * affine.scaleAt(c);
    }
    return out;
}

/// The whole point of a dynamic quantizer: the range comes from the data, and
/// zero must be representable or a padded convolution's pad value drifts.
fn dynamicQuantizeLinear(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!void {
    const x = try in(table, node, 0);
    if (node.outputs.len < 3) return error.TensorShapeMismatch;
    var lo: f32 = 0;
    var hi: f32 = 0;
    for (x.data) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const scale = if (hi == lo) @as(f32, 1) else (hi - lo) / 255.0;
    const zero = @max(0, @min(255, @round(-lo / scale)));

    var q = try newTensor(ra, ra.dupe(i64, x.dims) catch return error.OutOfMemory);
    q.dtype = .u8;
    for (x.data, 0..) |v, i| q.data[i] = @max(0, @min(255, @round(v / scale) + zero));

    var s = try newTensor(ra, ra.dupe(i64, &[_]i64{}) catch return error.OutOfMemory);
    s.data[0] = scale;
    var z = try newTensor(ra, ra.dupe(i64, &[_]i64{}) catch return error.OutOfMemory);
    z.dtype = .u8;
    z.data[0] = zero;

    table.put(ra, node.outputs[0], q) catch return error.OutOfMemory;
    table.put(ra, node.outputs[1], s) catch return error.OutOfMemory;
    table.put(ra, node.outputs[2], z) catch return error.OutOfMemory;
}

fn scalarAt(t: ?Tensor, i: usize, default: f32) f32 {
    const v = t orelse return default;
    if (v.data.len == 0) return default;
    if (v.data.len == 1) return v.data[0];
    return v.data[i % v.data.len];
}

fn optional(node: *const Node, table: *Table, idx: usize) Error!?Tensor {
    if (node.inputs.len <= idx or node.inputs[idx].len == 0) return null;
    return try get(table, node.inputs[idx]);
}

/// Adds two quantized tensors in the real domain and requantizes, which is what
/// every int8 residual connection in the proof set is made of. The operands
/// carry different scales, so adding the codes directly would be wrong.
fn qLinearAdd(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const a = try in(table, node, 0);
    const a_scale = try in(table, node, 1);
    const a_zero = try optional(node, table, 2);
    const b = try in(table, node, 3);
    const b_scale = try in(table, node, 4);
    const b_zero = try optional(node, table, 5);
    const y_scale = try in(table, node, 6);
    const y_zero = try optional(node, table, 7);
    if (a_scale.data.len == 0 or b_scale.data.len == 0 or y_scale.data.len == 0) return error.TensorShapeMismatch;
    if (y_scale.data[0] == 0) return error.TensorShapeMismatch;

    const az = scalarAt(a_zero, 0, 0);
    const bz = scalarAt(b_zero, 0, 0);
    const yz = scalarAt(y_zero, 0, 0);
    const want: DType = if (y_zero) |z| z.dtype else .u8;

    const rank = @max(a.dims.len, b.dims.len);
    var shape = ra.alloc(i64, rank) catch return error.OutOfMemory;
    for (0..rank) |i| {
        const ad = onnx.dimFromRight(a.dims, i);
        const bd = onnx.dimFromRight(b.dims, i);
        if (ad != bd and ad != 1 and bd != 1) return error.TensorShapeMismatch;
        shape[rank - 1 - i] = @max(ad, bd);
    }
    var out = try newTensor(ra, shape);
    out.dtype = want;
    const sa = ra.alloc(usize, rank) catch return error.OutOfMemory;
    const sb = ra.alloc(usize, rank) catch return error.OutOfMemory;
    onnx.fillBroadcastStrides(a.dims, rank, shape, sa);
    onnx.fillBroadcastStrides(b.dims, rank, shape, sb);

    const idx = ra.alloc(usize, rank) catch return error.OutOfMemory;
    @memset(idx, 0);
    for (out.data) |*o| {
        var oa: usize = 0;
        var ob: usize = 0;
        for (0..rank) |d| {
            oa += idx[d] * sa[d];
            ob += idx[d] * sb[d];
        }
        const real = (a.data[oa] - az) * a_scale.data[0] + (b.data[ob] - bz) * b_scale.data[0];
        o.* = want.clamp(@round(real / y_scale.data[0] + yz));
        onnx.incrementIndex(idx, shape);
    }
    return out;
}

/// Averages each plane in the real domain and requantizes. Summing codes and
/// dividing would carry the input zero point into the result.
fn qLinearGlobalAveragePool(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const x_scale = try in(table, node, 1);
    const x_zero = try optional(node, table, 2);
    const y_scale = try in(table, node, 3);
    const y_zero = try optional(node, table, 4);
    if (x.dims.len != 4) return error.TensorShapeMismatch;
    if (x_scale.data.len == 0 or y_scale.data.len == 0 or y_scale.data[0] == 0) return error.TensorShapeMismatch;

    const batch: usize = @intCast(@max(x.dims[0], 1));
    const channels: usize = @intCast(@max(x.dims[1], 1));
    const plane: usize = @intCast(@max(x.dims[2], 1) * @max(x.dims[3], 1));
    const xz = scalarAt(x_zero, 0, 0);
    const yz = scalarAt(y_zero, 0, 0);
    const want: DType = if (y_zero) |z| z.dtype else .u8;

    const shape = ra.dupe(i64, &[_]i64{ @intCast(batch), @intCast(channels), 1, 1 }) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = want;
    for (0..batch) |b| {
        for (0..channels) |c| {
            var acc: f64 = 0;
            const base = (b * channels + c) * plane;
            for (x.data[base .. base + plane]) |v| acc += v - xz;
            const real = @as(f32, @floatCast(acc / @as(f64, @floatFromInt(plane)))) * x_scale.data[0];
            out.data[b * channels + c] = want.clamp(@round(real / y_scale.data[0] + yz));
        }
    }
    return out;
}

fn qLinearMatMul(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const a = try in(table, node, 0);
    const a_scale = try in(table, node, 1);
    const a_zero = try optional(node, table, 2);
    const b = try in(table, node, 3);
    const b_scale = try in(table, node, 4);
    const b_zero = try optional(node, table, 5);
    const y_scale = try in(table, node, 6);
    const y_zero = try optional(node, table, 7);

    if (a.dims.len < 2 or b.dims.len < 2) return error.TensorShapeMismatch;
    const m: usize = @intCast(@max(a.dims[a.dims.len - 2], 1));
    const k: usize = @intCast(@max(a.dims[a.dims.len - 1], 1));
    const n: usize = @intCast(@max(b.dims[b.dims.len - 1], 1));
    if (@as(usize, @intCast(@max(b.dims[b.dims.len - 2], 1))) != k) return error.TensorShapeMismatch;

    var shape = ra.dupe(i64, a.dims) catch return error.OutOfMemory;
    shape[shape.len - 1] = @intCast(n);
    var out = try newTensor(ra, shape);
    out.dtype = if (y_zero) |z| z.dtype else .u8;

    const az: i64 = @intFromFloat(scalarAt(a_zero, 0, 0));
    const as_ = a_scale.data[0];
    const ys = y_scale.data[0];
    if (ys == 0) return error.TensorShapeMismatch;
    const yz = scalarAt(y_zero, 0, 0);

    const batches = if (m * k == 0) 0 else a.data.len / (m * k);
    const b_batches = if (k * n == 0) 0 else b.data.len / (k * n);
    for (0..batches) |bi| {
        const ab = a.data[bi * m * k ..][0 .. m * k];
        const bb = b.data[(if (b_batches > 1) bi else 0) * k * n ..][0 .. k * n];
        for (0..m) |i| {
            for (0..j_span(n)) |j| {
                const bz: i64 = @intFromFloat(scalarAt(b_zero, j, 0));
                var acc: i64 = 0;
                for (0..k) |kk| {
                    const av: i64 = @intFromFloat(ab[i * k + kk]);
                    const bv: i64 = @intFromFloat(bb[kk * n + j]);
                    acc += (av - az) * (bv - bz);
                }
                const scaled = @as(f32, @floatFromInt(acc)) * as_ * scalarAt(b_scale, j, 1) / ys + yz;
                out.data[bi * m * n + i * n + j] = out.dtype.clamp(@round(scaled));
            }
        }
    }
    return out;
}

fn j_span(n: usize) usize {
    return n;
}

const ConvGeometry = struct {
    batch: usize,
    in_channels: usize,
    in_h: usize,
    in_w: usize,
    out_channels: usize,
    kernel_h: usize,
    kernel_w: usize,
    out_h: usize,
    out_w: usize,
    stride_h: usize,
    stride_w: usize,
    pad_top: i64,
    pad_left: i64,
    dilation_h: usize,
    dilation_w: usize,
    group: usize,
};

fn geometryOf(node: *const Node, x: Tensor, w: Tensor) Error!ConvGeometry {
    if (x.dims.len != 4 or w.dims.len != 4) return error.TensorShapeMismatch;
    const strides = node.attrInts("strides");
    const pads = node.attrInts("pads");
    const dilations = node.attrInts("dilations");
    const group: usize = @intCast(@max(node.attrInt("group", 1), 1));

    var g: ConvGeometry = .{
        .batch = @intCast(@max(x.dims[0], 1)),
        .in_channels = @intCast(@max(x.dims[1], 1)),
        .in_h = @intCast(@max(x.dims[2], 1)),
        .in_w = @intCast(@max(x.dims[3], 1)),
        .out_channels = @intCast(@max(w.dims[0], 1)),
        .kernel_h = @intCast(@max(w.dims[2], 1)),
        .kernel_w = @intCast(@max(w.dims[3], 1)),
        .out_h = 0,
        .out_w = 0,
        .stride_h = if (strides.len > 0) @intCast(@max(strides[0], 1)) else 1,
        .stride_w = if (strides.len > 1) @intCast(@max(strides[1], 1)) else 1,
        .pad_top = if (pads.len > 0) pads[0] else 0,
        .pad_left = if (pads.len > 1) pads[1] else 0,
        .dilation_h = if (dilations.len > 0) @intCast(@max(dilations[0], 1)) else 1,
        .dilation_w = if (dilations.len > 1) @intCast(@max(dilations[1], 1)) else 1,
        .group = group,
    };
    const pad_bottom: i64 = if (pads.len > 2) pads[2] else g.pad_top;
    const pad_right: i64 = if (pads.len > 3) pads[3] else g.pad_left;
    const eff_h: i64 = @as(i64, @intCast((g.kernel_h - 1) * g.dilation_h + 1));
    const eff_w: i64 = @as(i64, @intCast((g.kernel_w - 1) * g.dilation_w + 1));
    const oh = @divFloor(@as(i64, @intCast(g.in_h)) + g.pad_top + pad_bottom - eff_h, @as(i64, @intCast(g.stride_h))) + 1;
    const ow = @divFloor(@as(i64, @intCast(g.in_w)) + g.pad_left + pad_right - eff_w, @as(i64, @intCast(g.stride_w))) + 1;
    if (oh <= 0 or ow <= 0) return error.TensorShapeMismatch;
    g.out_h = @intCast(oh);
    g.out_w = @intCast(ow);
    if (g.out_channels % g.group != 0 or g.in_channels % g.group != 0) return error.TensorShapeMismatch;
    return g;
}

/// The shared integer convolution. Padding contributes the input zero point,
/// not a literal zero, which is the single most common way a hand-written int8
/// convolution comes out subtly wrong at the borders.
fn integerConv(
    ra: std.mem.Allocator,
    g: ConvGeometry,
    x: Tensor,
    w: Tensor,
    x_zero: i64,
    w_zero: ?Tensor,
    out_dtype: DType,
    dequant: ?struct { x_scale: f32, w_scale: Tensor, y_scale: f32, y_zero: f32, bias: ?Tensor },
) Error!Tensor {
    const shape = ra.dupe(i64, &[_]i64{ @intCast(g.batch), @intCast(g.out_channels), @intCast(g.out_h), @intCast(g.out_w) }) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = out_dtype;

    const in_per_group = g.in_channels / g.group;
    const out_per_group = g.out_channels / g.group;

    // The accumulator is a plane of i32 the whole output channel is built in,
    // so the inner loop is one vectorized multiply-add over a contiguous input
    // row rather than six nested scalar loops.
    const acc_plane = ra.alloc(i32, g.out_h * g.out_w) catch return error.OutOfMemory;
    const unit_x = g.stride_w == 1 and g.dilation_w == 1;

    for (0..g.batch) |b| {
        for (0..g.out_channels) |oc| {
            const grp = oc / out_per_group;
            const wz: i64 = if (w_zero) |z| blk: {
                if (z.data.len == 0) break :blk 0;
                break :blk @intFromFloat(if (z.data.len == 1) z.data[0] else z.data[oc % z.data.len]);
            } else 0;
            @memset(acc_plane, 0);
            for (0..in_per_group) |ic| {
                const src_c = grp * in_per_group + ic;
                const in_plane = x.data[((b * g.in_channels + src_c) * g.in_h) * g.in_w ..][0 .. g.in_h * g.in_w];
                for (0..g.kernel_h) |ky| {
                    for (0..g.kernel_w) |kx| {
                        const wv: i32 = @intCast(@as(i64, @intFromFloat(w.data[((oc * in_per_group + ic) * g.kernel_h + ky) * g.kernel_w + kx])) - wz);
                        if (wv == 0) continue;
                        for (0..g.out_h) |oy| {
                            const iy = @as(i64, @intCast(oy * g.stride_h)) - g.pad_top + @as(i64, @intCast(ky * g.dilation_h));
                            if (iy < 0 or iy >= @as(i64, @intCast(g.in_h))) continue;
                            const in_row = in_plane[@as(usize, @intCast(iy)) * g.in_w ..][0..g.in_w];
                            const acc_row = acc_plane[oy * g.out_w ..][0..g.out_w];
                            if (unit_x) {
                                // A padded column contributes the input zero
                                // point against itself, which is zero, so the
                                // pad test leaves the inner loop entirely.
                                const shift = @as(i64, @intCast(kx * g.dilation_w)) - g.pad_left;
                                const first: usize = @intCast(@max(0, -shift));
                                const last: usize = @intCast(@max(0, @min(@as(i64, @intCast(g.out_w)), @as(i64, @intCast(g.in_w)) - shift)));
                                if (last <= first) continue;
                                const src_start: usize = @intCast(@as(i64, @intCast(first)) + shift);
                                simd.axpyInt(acc_row[first..last], in_row[src_start..][0 .. last - first], @intCast(x_zero), wv);
                                continue;
                            }
                            for (0..g.out_w) |ox| {
                                const ix = @as(i64, @intCast(ox * g.stride_w)) - g.pad_left + @as(i64, @intCast(kx * g.dilation_w));
                                if (ix < 0 or ix >= @as(i64, @intCast(g.in_w))) continue;
                                acc_row[ox] += wv * (@as(i32, @intFromFloat(in_row[@as(usize, @intCast(ix))])) - @as(i32, @intCast(x_zero)));
                            }
                        }
                    }
                }
            }
            for (0..g.out_h * g.out_w) |i| {
                const dst = (b * g.out_channels + oc) * g.out_h * g.out_w + i;
                if (dequant) |d| {
                    const bias: f32 = if (d.bias) |bt| (if (oc < bt.data.len) bt.data[oc] else 0) else 0;
                    const ws = if (d.w_scale.data.len <= 1) (if (d.w_scale.data.len == 1) d.w_scale.data[0] else 1) else d.w_scale.data[oc % d.w_scale.data.len];
                    const real = (@as(f32, @floatFromInt(acc_plane[i])) + bias) * d.x_scale * ws;
                    out.data[dst] = out_dtype.clamp(@round(real / d.y_scale + d.y_zero));
                } else {
                    out.data[dst] = @floatFromInt(acc_plane[i]);
                }
            }
        }
    }
    return out;
}

fn qLinearConv(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const x_scale = try in(table, node, 1);
    const x_zero = try optional(node, table, 2);
    const w = try in(table, node, 3);
    const w_scale = try in(table, node, 4);
    const w_zero = try optional(node, table, 5);
    const y_scale = try in(table, node, 6);
    const y_zero = try optional(node, table, 7);
    const bias = try optional(node, table, 8);

    const g = try geometryOf(node, x, w);
    if (y_scale.data.len == 0 or y_scale.data[0] == 0) return error.TensorShapeMismatch;
    return integerConv(
        ra,
        g,
        x,
        w,
        @intFromFloat(scalarAt(x_zero, 0, 0)),
        w_zero,
        if (y_zero) |z| z.dtype else .u8,
        .{
            .x_scale = x_scale.data[0],
            .w_scale = w_scale,
            .y_scale = y_scale.data[0],
            .y_zero = scalarAt(y_zero, 0, 0),
            .bias = bias,
        },
    );
}

fn convInteger(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const w = try in(table, node, 1);
    const x_zero = try optional(node, table, 2);
    const w_zero = try optional(node, table, 3);
    const g = try geometryOf(node, x, w);
    return integerConv(ra, g, x, w, @intFromFloat(scalarAt(x_zero, 0, 0)), w_zero, .i32, null);
}
