//! The elementwise, reduction, shape and activation operators. The parser and
//! the graph executor live next door in onnx.zig; this file is kernels only, so
//! adding an operator never touches the protobuf reader.

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
const dimFromRight = onnx.dimFromRight;
const fillBroadcastStrides = onnx.fillBroadcastStrides;
const incrementIndex = onnx.incrementIndex;
const intAt = onnx.intAt;

/// Runs one operator if this file owns it, and answers null if it does not, so
/// the executor chains dispatchers instead of one function knowing every op.
pub fn dispatch(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!?Tensor {
    const op = node.op_type;

    if (eq(op, "Abs")) return try unaryAs(ra, try in(table, node, 0), absScalar);
    if (eq(op, "Neg")) return try unaryAs(ra, try in(table, node, 0), negScalar);
    if (eq(op, "Log")) return try unaryF32(ra, try in(table, node, 0), logScalar);
    if (eq(op, "Sin")) return try unaryF32(ra, try in(table, node, 0), sinScalar);
    if (eq(op, "Cos")) return try unaryF32(ra, try in(table, node, 0), cosScalar);
    if (eq(op, "Tan")) return try unaryF32(ra, try in(table, node, 0), tanScalar);
    if (eq(op, "Asin")) return try unaryF32(ra, try in(table, node, 0), asinScalar);
    if (eq(op, "Acos")) return try unaryF32(ra, try in(table, node, 0), acosScalar);
    if (eq(op, "Atan")) return try unaryF32(ra, try in(table, node, 0), atanScalar);
    if (eq(op, "Reciprocal")) return try unaryF32(ra, try in(table, node, 0), recipScalar);
    if (eq(op, "Sign")) return try unaryAs(ra, try in(table, node, 0), signScalar);
    if (eq(op, "Floor")) return try unaryAs(ra, try in(table, node, 0), floorScalar);
    if (eq(op, "Ceil")) return try unaryAs(ra, try in(table, node, 0), ceilScalar);
    if (eq(op, "Round")) return try unaryAs(ra, try in(table, node, 0), roundScalar);
    if (eq(op, "Erf")) return try unaryF32(ra, try in(table, node, 0), erfScalar);
    if (eq(op, "Gelu")) {
        const approximate = node.attr("approximate");
        const tanh_mode = approximate != null and std.mem.eql(u8, approximate.?.s, "tanh");
        const x = try in(table, node, 0);
        return if (tanh_mode) try unaryF32(ra, x, geluTanhScalar) else try unaryF32(ra, x, geluScalar);
    }
    if (eq(op, "Not")) return try unaryBool(ra, try in(table, node, 0), notScalar);

    if (eq(op, "Pow")) return try binaryAs(ra, try in(table, node, 0), try in(table, node, 1), powScalar);
    if (eq(op, "Mod")) {
        const fmod = node.attrInt("fmod", 0) != 0;
        const a = try in(table, node, 0);
        const b = try in(table, node, 1);
        return if (fmod) try binaryAs(ra, a, b, fmodScalar) else try binaryAs(ra, a, b, imodScalar);
    }
    if (eq(op, "Min")) return try variadic(ra, node, table, minScalar);
    if (eq(op, "Max")) return try variadic(ra, node, table, maxScalar);
    if (eq(op, "Sum")) return try variadic(ra, node, table, sumScalar);
    if (eq(op, "Mean")) return try mean(ra, node, table);

    if (eq(op, "Equal")) return try compare(ra, try in(table, node, 0), try in(table, node, 1), eqScalar);
    if (eq(op, "Greater")) return try compare(ra, try in(table, node, 0), try in(table, node, 1), gtScalar);
    if (eq(op, "GreaterOrEqual")) return try compare(ra, try in(table, node, 0), try in(table, node, 1), geScalar);
    if (eq(op, "Less")) return try compare(ra, try in(table, node, 0), try in(table, node, 1), ltScalar);
    if (eq(op, "LessOrEqual")) return try compare(ra, try in(table, node, 0), try in(table, node, 1), leScalar);
    if (eq(op, "And")) return try compare(ra, try in(table, node, 0), try in(table, node, 1), andScalar);
    if (eq(op, "Or")) return try compare(ra, try in(table, node, 0), try in(table, node, 1), orScalar);
    if (eq(op, "Xor")) return try compare(ra, try in(table, node, 0), try in(table, node, 1), xorScalar);

    if (eq(op, "ReduceMean")) return try reduce(ra, node, table, .mean);
    if (eq(op, "ReduceSum")) return try reduce(ra, node, table, .sum);
    if (eq(op, "ReduceMax")) return try reduce(ra, node, table, .max);
    if (eq(op, "ReduceMin")) return try reduce(ra, node, table, .min);
    if (eq(op, "ReduceProd")) return try reduce(ra, node, table, .prod);
    if (eq(op, "ReduceL2")) return try reduce(ra, node, table, .l2);
    if (eq(op, "ReduceSumSquare")) return try reduce(ra, node, table, .sum_square);
    if (eq(op, "ReduceLogSum")) return try reduce(ra, node, table, .log_sum);

    if (eq(op, "LayerNormalization")) return try layerNorm(ra, node, table);
    if (eq(op, "Where")) return try where(ra, node, table);
    if (eq(op, "Expand")) return try expand(ra, node, table);
    if (eq(op, "Tile")) return try tile(ra, node, table);
    if (eq(op, "CumSum")) return try cumSum(ra, node, table);
    if (eq(op, "Range")) return try range(ra, node, table);
    if (eq(op, "Trilu")) return try trilu(ra, node, table);
    if (eq(op, "OneHot")) return try oneHot(ra, node, table);
    if (eq(op, "NonZero")) return try nonZero(ra, try in(table, node, 0));
    if (eq(op, "Compress")) return try compress(ra, node, table);
    if (eq(op, "GatherND")) return try gatherND(ra, node, table);
    if (eq(op, "ScatterND")) return try scatterND(ra, node, table);
    if (eq(op, "GatherElements")) return try gatherElements(ra, node, table);
    if (eq(op, "ScatterElements") or eq(op, "Scatter")) return try scatterElements(ra, node, table);
    if (eq(op, "Einsum")) return try einsum(ra, node, table);
    if (eq(op, "MatMulInteger")) return try matMulInteger(ra, node, table);

    if (eq(op, "Elu")) return try activation(ra, node, table, .elu);
    if (eq(op, "Selu")) return try activation(ra, node, table, .selu);
    if (eq(op, "Celu")) return try activation(ra, node, table, .celu);
    if (eq(op, "HardSigmoid")) return try activation(ra, node, table, .hard_sigmoid);
    if (eq(op, "HardSwish")) return try activation(ra, node, table, .hard_swish);
    if (eq(op, "Mish")) return try activation(ra, node, table, .mish);
    if (eq(op, "Softplus")) return try activation(ra, node, table, .softplus);
    if (eq(op, "Softsign")) return try activation(ra, node, table, .softsign);
    if (eq(op, "ThresholdedRelu")) return try activation(ra, node, table, .thresholded_relu);
    if (eq(op, "PRelu")) return try prelu(ra, node, table);

    if (eq(op, "DepthToSpace")) return try depthToSpace(ra, node, table);
    if (eq(op, "SpaceToDepth")) return try spaceToDepth(ra, node, table);
    if (eq(op, "GridSample")) return try gridSample(ra, node, table);
    if (eq(op, "LogSoftmax")) return try logSoftmax(ra, node, table);

    return null;
}

// ---- scalar kernels ----

fn absScalar(x: f32) f32 {
    return @abs(x);
}
fn negScalar(x: f32) f32 {
    return -x;
}
fn logScalar(x: f32) f32 {
    return @log(x);
}
fn sinScalar(x: f32) f32 {
    return @sin(x);
}
fn cosScalar(x: f32) f32 {
    return @cos(x);
}
fn tanScalar(x: f32) f32 {
    return @tan(x);
}
fn asinScalar(x: f32) f32 {
    return std.math.asin(x);
}
fn acosScalar(x: f32) f32 {
    return std.math.acos(x);
}
fn atanScalar(x: f32) f32 {
    return std.math.atan(x);
}
fn recipScalar(x: f32) f32 {
    return 1.0 / x;
}
fn signScalar(x: f32) f32 {
    if (x > 0) return 1;
    if (x < 0) return -1;
    return 0;
}
fn floorScalar(x: f32) f32 {
    return @floor(x);
}
fn ceilScalar(x: f32) f32 {
    return @ceil(x);
}

/// ONNX Round is round-half-to-even, not the away-from-zero rounding most
/// standard libraries hand back, and a detector's box coordinates land on .5
/// often enough for the difference to be visible.
fn roundScalar(x: f32) f32 {
    const down = @floor(x);
    const frac = x - down;
    if (frac > 0.5) return down + 1;
    if (frac < 0.5) return down;
    return if (@mod(down, 2) == 0) down else down + 1;
}

fn erfScalar(x: f32) f32 {
    // Abramowitz and Stegun 7.1.26: max error 1.5e-7, below float32's own step
    // at the magnitudes erf is used at, and branch-free.
    const sign: f32 = if (x < 0) -1 else 1;
    const ax = @abs(x);
    const t = 1.0 / (1.0 + 0.3275911 * ax);
    const y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp(-ax * ax);
    return sign * y;
}

fn geluScalar(x: f32) f32 {
    return 0.5 * x * (1.0 + erfScalar(x / std.math.sqrt2));
}

fn geluTanhScalar(x: f32) f32 {
    const inner = 0.7978845608028654 * (x + 0.044715 * x * x * x);
    return 0.5 * x * (1.0 + std.math.tanh(inner));
}

fn notScalar(x: f32) f32 {
    return if (x == 0) 1 else 0;
}
fn powScalar(a: f32, b: f32) f32 {
    return std.math.pow(f32, a, b);
}
/// fmod keeps the sign of the dividend; the integer form below keeps the sign
/// of the divisor, and ONNX picks between them with the fmod attribute.
fn fmodScalar(a: f32, b: f32) f32 {
    if (b == 0) return 0;
    return a - b * @trunc(a / b);
}

/// Integer Mod takes the sign of the divisor, which is where it parts company
/// with fmod; a negative index reduced against a positive extent must land
/// inside the extent or a gather reads out of bounds.
fn imodScalar(a: f32, b: f32) f32 {
    if (b == 0) return 0;
    const r = a - b * @trunc(a / b);
    if (r != 0 and (r < 0) != (b < 0)) return r + b;
    return r;
}

fn minScalar(a: f32, b: f32) f32 {
    return @min(a, b);
}
fn maxScalar(a: f32, b: f32) f32 {
    return @max(a, b);
}
fn sumScalar(a: f32, b: f32) f32 {
    return a + b;
}
fn eqScalar(a: f32, b: f32) f32 {
    return if (a == b) 1 else 0;
}
fn gtScalar(a: f32, b: f32) f32 {
    return if (a > b) 1 else 0;
}
fn geScalar(a: f32, b: f32) f32 {
    return if (a >= b) 1 else 0;
}
fn ltScalar(a: f32, b: f32) f32 {
    return if (a < b) 1 else 0;
}
fn leScalar(a: f32, b: f32) f32 {
    return if (a <= b) 1 else 0;
}
fn andScalar(a: f32, b: f32) f32 {
    return if (a != 0 and b != 0) 1 else 0;
}
fn orScalar(a: f32, b: f32) f32 {
    return if (a != 0 or b != 0) 1 else 0;
}
fn xorScalar(a: f32, b: f32) f32 {
    return if ((a != 0) != (b != 0)) 1 else 0;
}

// ---- elementwise plumbing ----

/// Unary that keeps the input's dtype, so Abs over an index tensor stays an
/// index tensor and a later Gather does not quietly take a float.
fn unaryAs(ra: std.mem.Allocator, x: Tensor, comptime f: fn (f32) f32) Error!Tensor {
    var out = try onnx.unary(ra, x, f);
    out.dtype = x.dtype;
    return out;
}

fn unaryF32(ra: std.mem.Allocator, x: Tensor, comptime f: fn (f32) f32) Error!Tensor {
    return onnx.unary(ra, x, f);
}

fn unaryBool(ra: std.mem.Allocator, x: Tensor, comptime f: fn (f32) f32) Error!Tensor {
    var out = try onnx.unary(ra, x, f);
    out.dtype = .bool;
    return out;
}

fn binaryAs(ra: std.mem.Allocator, a: Tensor, b: Tensor, comptime f: fn (f32, f32) f32) Error!Tensor {
    var out = try onnx.binary(ra, a, b, f);
    out.dtype = if (a.dtype.isInt() and b.dtype.isInt()) a.dtype else .f32;
    return out;
}

fn compare(ra: std.mem.Allocator, a: Tensor, b: Tensor, comptime f: fn (f32, f32) f32) Error!Tensor {
    var out = try onnx.binary(ra, a, b, f);
    out.dtype = .bool;
    return out;
}

fn variadic(ra: std.mem.Allocator, node: *const Node, table: *Table, comptime f: fn (f32, f32) f32) Error!Tensor {
    if (node.inputs.len == 0) return error.TensorMissing;
    var acc = try onnx.copyTensor(ra, try in(table, node, 0));
    var i: usize = 1;
    while (i < node.inputs.len) : (i += 1) {
        acc = try binaryAs(ra, acc, try in(table, node, i), f);
    }
    return acc;
}

fn mean(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const acc = try variadic(ra, node, table, sumScalar);
    const n: f32 = @floatFromInt(node.inputs.len);
    for (acc.data) |*v| v.* /= n;
    return acc;
}

// ---- reductions ----

const ReduceKind = enum { mean, sum, max, min, prod, l2, sum_square, log_sum };

/// The axes a reduction runs over, from the attribute an older opset writes or
/// the input a newer one passes. Absent means every axis unless the node opts
/// into the empty-axes no-op.
fn reduceAxes(node: *const Node, table: *Table, rank: usize, buf: []usize) Error![]usize {
    var count: usize = 0;
    var explicit = false;
    const attr_axes = node.attrInts("axes");
    if (attr_axes.len != 0) {
        explicit = true;
        for (attr_axes) |a| {
            const ax = try normAxis(a, rank);
            buf[count] = ax;
            count += 1;
        }
    } else if (node.inputs.len > 1 and node.inputs[1].len != 0) {
        explicit = true;
        const t = try get(table, node.inputs[1]);
        for (0..t.data.len) |i| {
            const ax = try normAxis(intAt(t, i), rank);
            if (count >= buf.len) return error.TensorShapeMismatch;
            buf[count] = ax;
            count += 1;
        }
    }
    if (!explicit) {
        if (node.attrInt("noop_with_empty_axes", 0) != 0) return buf[0..0];
        for (0..rank) |d| buf[d] = d;
        return buf[0..rank];
    }
    return buf[0..count];
}

fn normAxis(a: i64, rank: usize) Error!usize {
    const r: i64 = @intCast(rank);
    const ax = if (a < 0) a + r else a;
    if (ax < 0 or ax >= r) return error.TensorShapeMismatch;
    return @intCast(ax);
}

fn reduce(ra: std.mem.Allocator, node: *const Node, table: *Table, kind: ReduceKind) Error!Tensor {
    const x = try in(table, node, 0);
    const rank = x.dims.len;
    if (rank > 8) return error.TensorShapeMismatch;
    var axes_buf: [8]usize = undefined;
    const axes = try reduceAxes(node, table, rank, &axes_buf);
    if (axes.len == 0) return onnx.copyTensor(ra, x);
    const keepdims = node.attrInt("keepdims", 1) != 0;

    var reduced: [8]bool = @splat(false);
    for (axes) |a| reduced[a] = true;

    var out_shape_buf: [8]i64 = undefined;
    var out_rank: usize = 0;
    for (0..rank) |d| {
        if (reduced[d]) {
            if (keepdims) {
                out_shape_buf[out_rank] = 1;
                out_rank += 1;
            }
        } else {
            out_shape_buf[out_rank] = @as(i64, @intCast(onnx.extent(x, d)));
            out_rank += 1;
        }
    }
    const out_shape = ra.dupe(i64, out_shape_buf[0..out_rank]) catch return error.OutOfMemory;
    var out = try newTensor(ra, out_shape);
    out.dtype = if (kind == .mean or kind == .l2 or kind == .log_sum) .f32 else x.dtype;

    const init: f32 = switch (kind) {
        .max => -std.math.floatMax(f32),
        .min => std.math.floatMax(f32),
        .prod => 1,
        else => 0,
    };
    @memset(out.data, init);

    // Strides over the kept axes, so every input element folds into its output
    // slot in one pass rather than one pass per output element.
    var strides: [8]usize = @splat(0);
    var acc: usize = 1;
    var d = out_rank;
    var src_axis = rank;
    while (src_axis > 0) {
        src_axis -= 1;
        if (reduced[src_axis] and !keepdims) {
            strides[src_axis] = 0;
            continue;
        }
        d -= 1;
        if (reduced[src_axis]) {
            strides[src_axis] = 0;
        } else {
            strides[src_axis] = acc;
        }
        acc *= @intCast(out_shape[d]);
    }

    var idx: [8]usize = @splat(0);
    var reduced_elems: usize = 1;
    for (axes) |a| reduced_elems *= onnx.extent(x, a);

    for (x.data) |v| {
        var o: usize = 0;
        for (0..rank) |dd| o += idx[dd] * strides[dd];
        const slot = &out.data[o];
        switch (kind) {
            .mean, .sum, .log_sum => slot.* += v,
            .max => slot.* = @max(slot.*, v),
            .min => slot.* = @min(slot.*, v),
            .prod => slot.* *= v,
            .l2, .sum_square => slot.* += v * v,
        }
        incrementIndex(idx[0..rank], x.dims);
    }
    switch (kind) {
        .mean => for (out.data) |*v| {
            v.* /= @floatFromInt(reduced_elems);
        },
        .l2 => for (out.data) |*v| {
            v.* = @sqrt(v.*);
        },
        .log_sum => for (out.data) |*v| {
            v.* = @log(v.*);
        },
        else => {},
    }
    return out;
}

// ---- normalization ----

fn layerNorm(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const scale = try in(table, node, 1);
    const bias: ?Tensor = if (node.inputs.len > 2 and node.inputs[2].len != 0) try in(table, node, 2) else null;
    const rank = x.dims.len;
    if (rank == 0) return error.TensorShapeMismatch;
    const axis = try normAxis(node.attrInt("axis", -1), rank);
    const epsilon = node.attrFloat("epsilon", 1e-5);

    var inner: usize = 1;
    for (axis..rank) |d| inner *= onnx.extent(x, d);
    if (inner == 0) return error.TensorShapeMismatch;
    const outer = x.data.len / inner;
    if (scale.data.len != inner) return error.TensorShapeMismatch;
    if (bias) |b| {
        if (b.data.len != inner) return error.TensorShapeMismatch;
    }

    const out = try newTensor(ra, ra.dupe(i64, x.dims) catch return error.OutOfMemory);
    for (0..outer) |o| {
        const row = x.data[o * inner ..][0..inner];
        const totals = simd.sumAndSquares(row);
        const n: f64 = @floatFromInt(inner);
        const m: f64 = @as(f64, totals.sum) / n;
        // Variance from the sums of x and x squared, so the row is read once;
        // the subtraction is done in f64 so the cancellation stays harmless.
        const var_sum = @max(0, @as(f64, totals.squares) - @as(f64, totals.sum) * m);
        const inv = 1.0 / @sqrt(var_sum / n + epsilon);
        const dst = out.data[o * inner ..][0..inner];
        for (dst, row, scale.data, 0..) |*d, v, s, i| {
            const normed: f32 = @floatCast((@as(f64, v) - m) * inv);
            d.* = normed * s + (if (bias) |b| b.data[i] else 0);
        }
    }
    return out;
}

fn logSoftmax(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const out = try onnx.softmax(ra, try in(table, node, 0), node.attrInt("axis", -1));
    for (out.data) |*v| v.* = @log(v.*);
    return out;
}

// ---- shape and indexing ----

fn where(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const c = try in(table, node, 0);
    const a = try in(table, node, 1);
    const b = try in(table, node, 2);
    const rank = @max(c.dims.len, @max(a.dims.len, b.dims.len));
    if (rank > 8) return error.TensorShapeMismatch;
    var shape_buf: [8]i64 = undefined;
    for (0..rank) |i| {
        const m = try onnx.broadcastExtent(dimFromRight(c.dims, i), try onnx.broadcastExtent(dimFromRight(a.dims, i), dimFromRight(b.dims, i)));
        shape_buf[rank - 1 - i] = m;
    }
    const shape = ra.dupe(i64, shape_buf[0..rank]) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = if (a.dtype == b.dtype) a.dtype else .f32;
    if (out.data.len == 0) return out;

    const sc = ra.alloc(usize, rank) catch return error.OutOfMemory;
    const sa = ra.alloc(usize, rank) catch return error.OutOfMemory;
    const sb = ra.alloc(usize, rank) catch return error.OutOfMemory;
    fillBroadcastStrides(c.dims, rank, shape, sc);
    fillBroadcastStrides(a.dims, rank, shape, sa);
    fillBroadcastStrides(b.dims, rank, shape, sb);

    var idx: [8]usize = @splat(0);
    for (out.data) |*o| {
        var oc: usize = 0;
        var oa: usize = 0;
        var ob: usize = 0;
        for (0..rank) |d| {
            oc += idx[d] * sc[d];
            oa += idx[d] * sa[d];
            ob += idx[d] * sb[d];
        }
        o.* = if (c.data[oc] != 0) a.data[oa] else b.data[ob];
        incrementIndex(idx[0..rank], shape);
    }
    return out;
}

fn expand(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const shape_t = try in(table, node, 1);
    const want_rank = shape_t.data.len;
    const rank = @max(x.dims.len, want_rank);
    if (rank > 8) return error.TensorShapeMismatch;
    var shape_buf: [8]i64 = undefined;
    for (0..rank) |i| {
        const wd: i64 = if (i < want_rank) @max(intAt(shape_t, want_rank - 1 - i), 0) else 1;
        shape_buf[rank - 1 - i] = try onnx.broadcastExtent(dimFromRight(x.dims, i), wd);
    }
    const shape = ra.dupe(i64, shape_buf[0..rank]) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = x.dtype;
    if (out.data.len == 0) return out;
    const sx = ra.alloc(usize, rank) catch return error.OutOfMemory;
    fillBroadcastStrides(x.dims, rank, shape, sx);
    var idx: [8]usize = @splat(0);
    for (out.data) |*o| {
        var ox: usize = 0;
        for (0..rank) |d| ox += idx[d] * sx[d];
        o.* = x.data[ox];
        incrementIndex(idx[0..rank], shape);
    }
    return out;
}

fn tile(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const reps = try in(table, node, 1);
    const rank = x.dims.len;
    if (rank > 8 or reps.data.len != rank) return error.TensorShapeMismatch;
    var shape_buf: [8]i64 = undefined;
    for (0..rank) |d| {
        const r = intAt(reps, d);
        if (r < 0) return error.TensorShapeMismatch;
        shape_buf[d] = @as(i64, @intCast(onnx.extent(x, d))) * r;
    }
    const shape = ra.dupe(i64, shape_buf[0..rank]) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = x.dtype;
    var strides: [8]usize = @splat(1);
    var acc: usize = 1;
    var d = rank;
    while (d > 0) {
        d -= 1;
        strides[d] = acc;
        acc *= onnx.extent(x, d);
    }
    var idx: [8]usize = @splat(0);
    for (out.data) |*o| {
        var ox: usize = 0;
        for (0..rank) |dd| ox += (idx[dd] % @as(usize, onnx.extent(x, dd))) * strides[dd];
        o.* = x.data[ox];
        incrementIndex(idx[0..rank], shape);
    }
    return out;
}

fn cumSum(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const rank = x.dims.len;
    const axis_t = try in(table, node, 1);
    if (axis_t.data.len == 0) return error.TensorShapeMismatch;
    const ax = try normAxis(intAt(axis_t, 0), rank);
    const exclusive = node.attrInt("exclusive", 0) != 0;
    const reverse = node.attrInt("reverse", 0) != 0;

    const out = try newTensor(ra, ra.dupe(i64, x.dims) catch return error.OutOfMemory);
    const along: usize = onnx.extent(x, ax);
    var inner: usize = 1;
    for (ax + 1..rank) |d| inner *= onnx.extent(x, d);
    const outer = if (along * inner == 0) 0 else x.data.len / (along * inner);

    for (0..outer) |o| {
        for (0..inner) |i| {
            var run: f32 = 0;
            for (0..along) |k| {
                const pos = if (reverse) along - 1 - k else k;
                const at = (o * along + pos) * inner + i;
                if (exclusive) {
                    out.data[at] = run;
                    run += x.data[at];
                } else {
                    run += x.data[at];
                    out.data[at] = run;
                }
            }
        }
    }
    return out;
}

fn range(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const start_t = try in(table, node, 0);
    const limit_t = try in(table, node, 1);
    const delta_t = try in(table, node, 2);
    if (start_t.data.len == 0 or limit_t.data.len == 0 or delta_t.data.len == 0) return error.TensorShapeMismatch;
    const start = start_t.data[0];
    const limit = limit_t.data[0];
    const delta = delta_t.data[0];
    if (delta == 0) return error.TensorShapeMismatch;
    const span = (limit - start) / delta;
    const n_f = @ceil(span);
    if (n_f <= 0) {
        var empty = try newTensor(ra, ra.dupe(i64, &[_]i64{0}) catch return error.OutOfMemory);
        empty.dtype = start_t.dtype;
        return empty;
    }
    if (n_f > @as(f32, @floatFromInt(onnx.max_tensor_elems))) return error.TensorShapeMismatch;
    const n: usize = @intFromFloat(n_f);
    var out = try newTensor(ra, ra.dupe(i64, &[_]i64{@intCast(n)}) catch return error.OutOfMemory);
    out.dtype = start_t.dtype;
    for (out.data, 0..) |*v, i| v.* = start + delta * @as(f32, @floatFromInt(i));
    return out;
}

fn trilu(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const rank = x.dims.len;
    if (rank < 2) return error.TensorShapeMismatch;
    const upper = node.attrInt("upper", 1) != 0;
    var k: i64 = 0;
    if (node.inputs.len > 1 and node.inputs[1].len != 0) {
        const kt = try get(table, node.inputs[1]);
        if (kt.data.len != 0) k = intAt(kt, 0);
    }
    const out = try onnx.copyTensor(ra, x);
    const cols: usize = onnx.extent(x, rank - 1);
    const rows: usize = onnx.extent(x, rank - 2);
    const batches = if (rows * cols == 0) 0 else x.data.len / (rows * cols);
    for (0..batches) |b| {
        for (0..rows) |r| {
            for (0..cols) |c| {
                const keep = if (upper) @as(i64, @intCast(c)) >= @as(i64, @intCast(r)) + k else @as(i64, @intCast(c)) <= @as(i64, @intCast(r)) + k;
                if (!keep) out.data[(b * rows + r) * cols + c] = 0;
            }
        }
    }
    return out;
}

fn oneHot(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const indices = try in(table, node, 0);
    const depth_t = try in(table, node, 1);
    const values = try in(table, node, 2);
    if (depth_t.data.len == 0 or values.data.len < 2) return error.TensorShapeMismatch;
    const depth_i = intAt(depth_t, 0);
    if (depth_i <= 0 or depth_i > @as(i64, @intCast(onnx.max_tensor_elems))) return error.TensorShapeMismatch;
    const depth: usize = @intCast(depth_i);
    const rank = indices.dims.len;
    if (rank >= 8) return error.TensorShapeMismatch;
    const axis = node.attrInt("axis", -1);
    const insert: usize = @intCast(if (axis < 0) axis + @as(i64, @intCast(rank)) + 1 else axis);
    if (insert > rank) return error.TensorShapeMismatch;

    var shape_buf: [8]i64 = undefined;
    var w: usize = 0;
    for (0..rank + 1) |d| {
        if (d == insert) {
            shape_buf[w] = @intCast(depth);
        } else {
            shape_buf[w] = @as(i64, @intCast(onnx.extent(indices, if (d > insert) d - 1 else d)));
        }
        w += 1;
    }
    const shape = ra.dupe(i64, shape_buf[0 .. rank + 1]) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = values.dtype;
    @memset(out.data, values.data[0]);

    var inner: usize = 1;
    for (insert..rank) |d| inner *= onnx.extent(indices, d);
    const outer = if (inner == 0) 0 else indices.data.len / inner;
    for (0..outer) |o| {
        for (0..inner) |i| {
            var v = intAt(indices, o * inner + i);
            if (v < 0) v += @intCast(depth);
            if (v < 0 or v >= @as(i64, @intCast(depth))) continue;
            out.data[(o * depth + @as(usize, @intCast(v))) * inner + i] = values.data[1];
        }
    }
    return out;
}

fn nonZero(ra: std.mem.Allocator, x: Tensor) Error!Tensor {
    const rank = @max(x.dims.len, 1);
    if (rank > 8) return error.TensorShapeMismatch;
    var nnz: usize = 0;
    for (x.data) |v| {
        if (v != 0) nnz += 1;
    }
    var out = try newTensor(ra, ra.dupe(i64, &[_]i64{ @intCast(rank), @intCast(@max(nnz, 0)) }) catch return error.OutOfMemory);
    out.dtype = .i64;
    if (nnz == 0) return out;
    var idx: [8]usize = @splat(0);
    var w: usize = 0;
    const dims = if (x.dims.len == 0) &[_]i64{1} else x.dims;
    for (x.data) |v| {
        if (v != 0) {
            for (0..rank) |d| out.data[d * nnz + w] = @floatFromInt(idx[d]);
            w += 1;
        }
        incrementIndex(idx[0..rank], dims);
    }
    return out;
}

fn compress(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const cond = try in(table, node, 1);
    const has_axis = node.attr("axis") != null;
    if (!has_axis) {
        var kept: usize = 0;
        for (cond.data, 0..) |c, i| {
            if (c != 0 and i < x.data.len) kept += 1;
        }
        var out = try newTensor(ra, ra.dupe(i64, &[_]i64{@intCast(kept)}) catch return error.OutOfMemory);
        out.dtype = x.dtype;
        var w: usize = 0;
        for (cond.data, 0..) |c, i| {
            if (c != 0 and i < x.data.len) {
                out.data[w] = x.data[i];
                w += 1;
            }
        }
        return out;
    }
    const rank = x.dims.len;
    const ax = try normAxis(node.attrInt("axis", 0), rank);
    const along: usize = onnx.extent(x, ax);
    var kept: usize = 0;
    for (cond.data, 0..) |c, i| {
        if (c != 0 and i < along) kept += 1;
    }
    var shape = ra.dupe(i64, x.dims) catch return error.OutOfMemory;
    shape[ax] = @intCast(kept);
    var out = try newTensor(ra, shape);
    out.dtype = x.dtype;
    var inner: usize = 1;
    for (ax + 1..rank) |d| inner *= onnx.extent(x, d);
    const outer = if (along * inner == 0) 0 else x.data.len / (along * inner);
    for (0..outer) |o| {
        var w: usize = 0;
        for (0..along) |k| {
            if (k >= cond.data.len or cond.data[k] == 0) continue;
            const src = (o * along + k) * inner;
            const dst = (o * kept + w) * inner;
            @memcpy(out.data[dst .. dst + inner], x.data[src .. src + inner]);
            w += 1;
        }
    }
    return out;
}

// ---- gather and scatter families ----

fn gatherND(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const data = try in(table, node, 0);
    const indices = try in(table, node, 1);
    const batch_dims: usize = @intCast(@max(node.attrInt("batch_dims", 0), 0));
    const dr = data.dims.len;
    const ir = indices.dims.len;
    if (ir == 0 or batch_dims >= dr or batch_dims >= ir) return error.TensorShapeMismatch;
    const index_depth: usize = onnx.extent(indices, ir - 1);
    if (batch_dims + index_depth > dr) return error.TensorShapeMismatch;

    var batch: usize = 1;
    for (0..batch_dims) |d| batch *= onnx.extent(data, d);
    var slice_elems: usize = 1;
    for (batch_dims + index_depth..dr) |d| slice_elems *= onnx.extent(data, d);

    var tuples: usize = 1;
    for (batch_dims..ir - 1) |d| tuples *= onnx.extent(indices, d);

    var shape_buf: [8]i64 = undefined;
    var w: usize = 0;
    for (0..ir - 1) |d| {
        if (w >= shape_buf.len) return error.TensorShapeMismatch;
        shape_buf[w] = @as(i64, @intCast(onnx.extent(indices, d)));
        w += 1;
    }
    for (batch_dims + index_depth..dr) |d| {
        if (w >= shape_buf.len) return error.TensorShapeMismatch;
        shape_buf[w] = @as(i64, @intCast(onnx.extent(data, d)));
        w += 1;
    }
    const shape = ra.dupe(i64, shape_buf[0..w]) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = data.dtype;

    // Row-major strides of the gathered axes, so one index tuple becomes one
    // offset without rebuilding the stride table per tuple.
    var strides: [8]usize = @splat(0);
    var acc: usize = slice_elems;
    var d = batch_dims + index_depth;
    while (d > batch_dims) {
        d -= 1;
        strides[d - batch_dims] = acc;
        acc *= onnx.extent(data, d);
    }
    const batch_stride = acc;

    for (0..batch) |b| {
        for (0..tuples) |t| {
            var off: usize = 0;
            var ok = true;
            for (0..index_depth) |k| {
                var v = intAt(indices, (b * tuples + t) * index_depth + k);
                const extent: i64 = @as(i64, @intCast(onnx.extent(data, batch_dims + k)));
                if (v < 0) v += extent;
                if (v < 0 or v >= extent) {
                    ok = false;
                    break;
                }
                off += @as(usize, @intCast(v)) * strides[k];
            }
            const dst = (b * tuples + t) * slice_elems;
            if (!ok) {
                @memset(out.data[dst .. dst + slice_elems], 0);
                continue;
            }
            const src = b * batch_stride + off;
            @memcpy(out.data[dst .. dst + slice_elems], data.data[src .. src + slice_elems]);
        }
    }
    return out;
}

fn scatterND(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const data = try in(table, node, 0);
    const indices = try in(table, node, 1);
    const updates = try in(table, node, 2);
    const dr = data.dims.len;
    const ir = indices.dims.len;
    if (ir == 0) return error.TensorShapeMismatch;
    const index_depth: usize = onnx.extent(indices, ir - 1);
    if (index_depth > dr) return error.TensorShapeMismatch;

    const reduction = if (node.attr("reduction")) |a| a.s else "";
    const out = try onnx.copyTensor(ra, data);

    var slice_elems: usize = 1;
    for (index_depth..dr) |d| slice_elems *= onnx.extent(data, d);
    var tuples: usize = 1;
    for (0..ir - 1) |d| tuples *= onnx.extent(indices, d);
    if (updates.data.len < tuples * slice_elems) return error.TensorShapeMismatch;

    var strides: [8]usize = @splat(0);
    var acc: usize = slice_elems;
    var d = index_depth;
    while (d > 0) {
        d -= 1;
        strides[d] = acc;
        acc *= onnx.extent(data, d);
    }

    for (0..tuples) |t| {
        var off: usize = 0;
        var ok = true;
        for (0..index_depth) |k| {
            var v = intAt(indices, t * index_depth + k);
            const extent: i64 = @as(i64, @intCast(onnx.extent(data, k)));
            if (v < 0) v += extent;
            if (v < 0 or v >= extent) {
                ok = false;
                break;
            }
            off += @as(usize, @intCast(v)) * strides[k];
        }
        if (!ok) continue;
        const src = updates.data[t * slice_elems ..][0..slice_elems];
        const dst = out.data[off..][0..slice_elems];
        if (std.mem.eql(u8, reduction, "add")) {
            for (dst, src) |*o, u| o.* += u;
        } else if (std.mem.eql(u8, reduction, "mul")) {
            for (dst, src) |*o, u| o.* *= u;
        } else if (std.mem.eql(u8, reduction, "max")) {
            for (dst, src) |*o, u| o.* = @max(o.*, u);
        } else if (std.mem.eql(u8, reduction, "min")) {
            for (dst, src) |*o, u| o.* = @min(o.*, u);
        } else {
            @memcpy(dst, src);
        }
    }
    return out;
}

fn elementStrides(dims: []const i64, out: []usize) void {
    var acc: usize = 1;
    var d = dims.len;
    while (d > 0) {
        d -= 1;
        out[d] = acc;
        acc *= @intCast(@max(dims[d], 1));
    }
}

fn gatherElements(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const data = try in(table, node, 0);
    const indices = try in(table, node, 1);
    const rank = data.dims.len;
    if (rank == 0 or rank > 8 or indices.dims.len != rank) return error.TensorShapeMismatch;
    const ax = try normAxis(node.attrInt("axis", 0), rank);

    var out = try newTensor(ra, ra.dupe(i64, indices.dims) catch return error.OutOfMemory);
    out.dtype = data.dtype;
    var strides: [8]usize = @splat(0);
    elementStrides(data.dims, strides[0..rank]);
    const extent: i64 = @as(i64, @intCast(onnx.extent(data, ax)));

    var idx: [8]usize = @splat(0);
    for (out.data, 0..) |*o, i| {
        var v = intAt(indices, i);
        if (v < 0) v += extent;
        if (v < 0 or v >= extent) return error.TensorShapeMismatch;
        var off: usize = 0;
        for (0..rank) |d| off += (if (d == ax) @as(usize, @intCast(v)) else idx[d]) * strides[d];
        o.* = data.data[off];
        incrementIndex(idx[0..rank], indices.dims);
    }
    return out;
}

fn scatterElements(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const data = try in(table, node, 0);
    const indices = try in(table, node, 1);
    const updates = try in(table, node, 2);
    const rank = data.dims.len;
    if (rank == 0 or rank > 8 or indices.dims.len != rank) return error.TensorShapeMismatch;
    if (updates.data.len < indices.data.len) return error.TensorShapeMismatch;
    const ax = try normAxis(node.attrInt("axis", 0), rank);
    const reduction = if (node.attr("reduction")) |a| a.s else "";

    const out = try onnx.copyTensor(ra, data);
    var strides: [8]usize = @splat(0);
    elementStrides(data.dims, strides[0..rank]);
    const extent: i64 = @as(i64, @intCast(onnx.extent(data, ax)));

    var idx: [8]usize = @splat(0);
    for (0..indices.data.len) |i| {
        var v = intAt(indices, i);
        if (v < 0) v += extent;
        if (v < 0 or v >= extent) return error.TensorShapeMismatch;
        var off: usize = 0;
        for (0..rank) |d| off += (if (d == ax) @as(usize, @intCast(v)) else idx[d]) * strides[d];
        const u = updates.data[i];
        if (std.mem.eql(u8, reduction, "add")) {
            out.data[off] += u;
        } else if (std.mem.eql(u8, reduction, "mul")) {
            out.data[off] *= u;
        } else if (std.mem.eql(u8, reduction, "max")) {
            out.data[off] = @max(out.data[off], u);
        } else if (std.mem.eql(u8, reduction, "min")) {
            out.data[off] = @min(out.data[off], u);
        } else {
            out.data[off] = u;
        }
        incrementIndex(idx[0..rank], indices.dims);
    }
    return out;
}

// ---- einsum ----

const max_labels = 26 * 2;

const Term = struct {
    labels: [8]u8 = @splat(0),
    len: usize = 0,
};

/// Expands one equation term to concrete labels, turning an ellipsis into the
/// batch labels the operand's rank implies. Attention writes its equations with
/// an ellipsis often enough that refusing one would refuse most real models.
fn parseTerm(text: []const u8, rank: usize, ellipsis_labels: []const u8) Error!Term {
    var t: Term = .{};
    var i: usize = 0;
    var named: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '.') continue;
        if (!std.ascii.isAlphabetic(text[i])) return error.UnsupportedOp;
        named += 1;
    }
    const has_ellipsis = std.mem.indexOf(u8, text, "...") != null;
    if (named > rank) return error.TensorShapeMismatch;
    const implied = if (has_ellipsis) rank - named else 0;
    if (implied > ellipsis_labels.len) return error.TensorShapeMismatch;

    i = 0;
    while (i < text.len) {
        if (text[i] == '.') {
            if (i + 2 >= text.len or text[i + 1] != '.' or text[i + 2] != '.') return error.UnsupportedOp;
            const start = ellipsis_labels.len - implied;
            for (ellipsis_labels[start..]) |c| {
                if (t.len >= t.labels.len) return error.TensorShapeMismatch;
                t.labels[t.len] = c;
                t.len += 1;
            }
            i += 3;
            continue;
        }
        if (t.len >= t.labels.len) return error.TensorShapeMismatch;
        t.labels[t.len] = text[i];
        t.len += 1;
        i += 1;
    }
    if (t.len != rank) return error.TensorShapeMismatch;
    return t;
}

fn einsum(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const eqn_attr = node.attr("equation") orelse return error.UnsupportedOp;
    var eqn_buf: [128]u8 = undefined;
    if (eqn_attr.s.len > eqn_buf.len) return error.UnsupportedOp;
    var n: usize = 0;
    for (eqn_attr.s) |c| {
        if (c == ' ') continue;
        eqn_buf[n] = c;
        n += 1;
    }
    const eqn = eqn_buf[0..n];
    if (node.inputs.len == 0 or node.inputs.len > 2) return error.UnsupportedOp;

    const arrow = std.mem.indexOf(u8, eqn, "->");
    const lhs = if (arrow) |a| eqn[0..a] else eqn;
    var terms_text: [2][]const u8 = .{ lhs, &.{} };
    var term_count: usize = 1;
    if (std.mem.indexOfScalar(u8, lhs, ',')) |comma| {
        terms_text[0] = lhs[0..comma];
        terms_text[1] = lhs[comma + 1 ..];
        term_count = 2;
    }
    if (term_count != node.inputs.len) return error.TensorShapeMismatch;

    var operands: [2]Tensor = undefined;
    for (0..term_count) |i| operands[i] = try in(table, node, i);

    // Batch labels an ellipsis stands for, picked from a range no equation
    // writes by hand so they cannot collide with a named index.
    const ellipsis_pool = "\x01\x02\x03\x04\x05\x06\x07\x08";
    var terms: [2]Term = undefined;
    var ellipsis_rank: usize = 0;
    for (0..term_count) |i| {
        var named: usize = 0;
        for (terms_text[i]) |c| {
            if (c != '.') named += 1;
        }
        if (std.mem.indexOf(u8, terms_text[i], "...") != null and operands[i].dims.len >= named) {
            ellipsis_rank = @max(ellipsis_rank, operands[i].dims.len - named);
        }
    }
    if (ellipsis_rank > ellipsis_pool.len) return error.TensorShapeMismatch;
    const ellipsis_labels = ellipsis_pool[0..ellipsis_rank];
    for (0..term_count) |i| terms[i] = try parseTerm(terms_text[i], operands[i].dims.len, ellipsis_labels);

    var extent: [256]usize = @splat(0);
    var seen: [256]u8 = @splat(0);
    for (0..term_count) |i| {
        for (0..terms[i].len) |d| {
            const label = terms[i].labels[d];
            const e: usize = @intCast(@max(operands[i].dims[d], 1));
            if (seen[label] != 0 and extent[label] != e and extent[label] != 1 and e != 1) return error.TensorShapeMismatch;
            extent[label] = @max(extent[label], e);
            seen[label] += 1;
        }
    }

    var out_labels: [16]u8 = undefined;
    var out_rank: usize = 0;
    if (arrow) |a| {
        const rhs_text = eqn[a + 2 ..];
        var i: usize = 0;
        while (i < rhs_text.len) {
            if (rhs_text[i] == '.') {
                if (i + 2 >= rhs_text.len) return error.UnsupportedOp;
                for (ellipsis_labels) |c| {
                    out_labels[out_rank] = c;
                    out_rank += 1;
                }
                i += 3;
                continue;
            }
            if (out_rank >= out_labels.len) return error.TensorShapeMismatch;
            out_labels[out_rank] = rhs_text[i];
            out_rank += 1;
            i += 1;
        }
    } else {
        for (ellipsis_labels) |c| {
            out_labels[out_rank] = c;
            out_rank += 1;
        }
        var c: u8 = 'A';
        while (c <= 'z') : (c += 1) {
            if (!std.ascii.isAlphabetic(c)) continue;
            if (seen[c] == 1) {
                if (out_rank >= out_labels.len) return error.TensorShapeMismatch;
                out_labels[out_rank] = c;
                out_rank += 1;
            }
        }
    }

    var sum_labels: [16]u8 = undefined;
    var sum_rank: usize = 0;
    for (0..256) |label| {
        if (seen[label] == 0) continue;
        var in_out = false;
        for (out_labels[0..out_rank]) |c| {
            if (c == label) in_out = true;
        }
        if (in_out) continue;
        if (sum_rank >= sum_labels.len) return error.TensorShapeMismatch;
        sum_labels[sum_rank] = @intCast(label);
        sum_rank += 1;
    }

    var shape_buf: [16]i64 = undefined;
    for (0..out_rank) |d| shape_buf[d] = @intCast(extent[out_labels[d]]);
    const shape = ra.dupe(i64, shape_buf[0..out_rank]) catch return error.OutOfMemory;
    const out = try newTensor(ra, shape);

    var strides: [2][8]usize = @splat(@splat(0));
    for (0..term_count) |i| elementStrides(operands[i].dims, strides[i][0..operands[i].dims.len]);

    var pos: [256]usize = @splat(0);
    var out_idx: [16]usize = @splat(0);
    for (out.data) |*o| {
        for (0..out_rank) |d| pos[out_labels[d]] = out_idx[d];
        var sum_idx: [16]usize = @splat(0);
        var acc: f32 = 0;
        while (true) {
            for (0..sum_rank) |d| pos[sum_labels[d]] = sum_idx[d];
            var product: f32 = 1;
            for (0..term_count) |i| {
                var off: usize = 0;
                for (0..terms[i].len) |d| {
                    const label = terms[i].labels[d];
                    const e: usize = @intCast(@max(operands[i].dims[d], 1));
                    off += (if (e == 1) 0 else pos[label]) * strides[i][d];
                }
                product *= operands[i].data[off];
            }
            acc += product;
            if (sum_rank == 0) break;
            var d = sum_rank;
            var carried = true;
            while (d > 0) {
                d -= 1;
                sum_idx[d] += 1;
                if (sum_idx[d] < extent[sum_labels[d]]) {
                    carried = false;
                    break;
                }
                sum_idx[d] = 0;
            }
            if (carried) break;
        }
        o.* = acc;
        if (out_rank == 0) break;
        incrementIndex(out_idx[0..out_rank], shape);
    }
    return out;
}

/// MatMulInteger: the operands are exact integers held in float storage, so the
/// accumulation runs in i64 and the result is exact, which a float accumulator
/// stops being past 2^24 on any real channel count.
fn matMulInteger(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const a = try in(table, node, 0);
    const b = try in(table, node, 1);
    const a_zero: f32 = if (node.inputs.len > 2 and node.inputs[2].len != 0) blk: {
        const t = try get(table, node.inputs[2]);
        break :blk if (t.data.len != 0) t.data[0] else 0;
    } else 0;
    const b_zero_t: ?Tensor = if (node.inputs.len > 3 and node.inputs[3].len != 0) try get(table, node.inputs[3]) else null;

    if (a.dims.len < 2 or b.dims.len < 2) return error.TensorShapeMismatch;
    const m: usize = onnx.extent(a, a.dims.len - 2);
    const k: usize = onnx.extent(a, a.dims.len - 1);
    const kb: usize = onnx.extent(b, b.dims.len - 2);
    const n: usize = onnx.extent(b, b.dims.len - 1);
    if (k != kb) return error.TensorShapeMismatch;

    var shape_buf: [8]i64 = undefined;
    const rank = a.dims.len;
    if (rank > 8) return error.TensorShapeMismatch;
    for (0..rank) |d| shape_buf[d] = @as(i64, @intCast(onnx.extent(a, d)));
    shape_buf[rank - 1] = @intCast(n);
    const shape = ra.dupe(i64, shape_buf[0..rank]) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = .i32;

    const batches = if (m * k == 0) 0 else a.data.len / (m * k);
    const b_batches = if (k * n == 0) 0 else b.data.len / (k * n);
    for (0..batches) |bi| {
        const ab = a.data[bi * m * k ..][0 .. m * k];
        const bb = b.data[(if (b_batches > 1) bi else 0) * k * n ..][0 .. k * n];
        for (0..m) |i| {
            for (0..n) |j| {
                const b_zero: i64 = if (b_zero_t) |t| (if (t.data.len == 1) intAt(t, 0) else intAt(t, j)) else 0;
                var acc: i64 = 0;
                for (0..k) |kk| {
                    const av: i64 = @intFromFloat(ab[i * k + kk] - a_zero);
                    const bv: i64 = @intFromFloat(bb[kk * n + j]);
                    acc += av * (bv - b_zero);
                }
                out.data[bi * m * n + i * n + j] = @floatFromInt(acc);
            }
        }
    }
    return out;
}

// ---- activations ----

const ActivationKind = enum { elu, selu, celu, hard_sigmoid, hard_swish, mish, softplus, softsign, thresholded_relu };

fn activation(ra: std.mem.Allocator, node: *const Node, table: *Table, kind: ActivationKind) Error!Tensor {
    const x = try in(table, node, 0);
    const out = try onnx.copyTensor(ra, x);
    switch (kind) {
        .elu => {
            const alpha = node.attrFloat("alpha", 1.0);
            for (out.data) |*v| v.* = if (v.* >= 0) v.* else alpha * (@exp(v.*) - 1);
        },
        .selu => {
            const alpha = node.attrFloat("alpha", 1.6732632423543772);
            const gamma = node.attrFloat("gamma", 1.0507009873554805);
            for (out.data) |*v| v.* = gamma * (if (v.* > 0) v.* else alpha * (@exp(v.*) - 1));
        },
        .celu => {
            const alpha = node.attrFloat("alpha", 1.0);
            if (alpha == 0) return error.TensorShapeMismatch;
            for (out.data) |*v| v.* = @max(0, v.*) + @min(0, alpha * (@exp(v.* / alpha) - 1));
        },
        .hard_sigmoid => {
            const alpha = node.attrFloat("alpha", 0.2);
            const beta = node.attrFloat("beta", 0.5);
            for (out.data) |*v| v.* = @max(0, @min(1, alpha * v.* + beta));
        },
        .hard_swish => for (out.data) |*v| {
            v.* = v.* * @max(0, @min(1, v.* / 6.0 + 0.5));
        },
        .mish => for (out.data) |*v| {
            v.* = v.* * std.math.tanh(@log(1 + @exp(v.*)));
        },
        .softplus => for (out.data) |*v| {
            v.* = @log(1 + @exp(v.*));
        },
        .softsign => for (out.data) |*v| {
            v.* = v.* / (1 + @abs(v.*));
        },
        .thresholded_relu => {
            const alpha = node.attrFloat("alpha", 1.0);
            for (out.data) |*v| v.* = if (v.* > alpha) v.* else 0;
        },
    }
    return out;
}

/// PRelu's slope broadcasts against the channel axis, which for a 4-D feature
/// map is axis 1 and not the trailing axis ordinary broadcasting would pick.
fn prelu(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const slope = try in(table, node, 1);
    const out = try onnx.copyTensor(ra, x);
    if (slope.data.len == 1) {
        const a = slope.data[0];
        for (out.data) |*v| v.* = if (v.* >= 0) v.* else a * v.*;
        return out;
    }
    if (x.dims.len < 2) return error.TensorShapeMismatch;
    const channels: usize = onnx.extent(x, 1);
    if (slope.data.len != channels) return error.TensorShapeMismatch;
    var plane: usize = 1;
    for (2..x.dims.len) |d| plane *= onnx.extent(x, d);
    const batch = if (channels * plane == 0) 0 else x.data.len / (channels * plane);
    for (0..batch) |b| {
        for (0..channels) |c| {
            const a = slope.data[c];
            const base = (b * channels + c) * plane;
            for (out.data[base .. base + plane]) |*v| v.* = if (v.* >= 0) v.* else a * v.*;
        }
    }
    return out;
}

// ---- spatial rearrangement ----

fn depthToSpace(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    if (x.dims.len != 4) return error.TensorShapeMismatch;
    const bs: usize = @intCast(@max(node.attrInt("blocksize", 0), 0));
    if (bs == 0) return error.TensorShapeMismatch;
    const crd = if (node.attr("mode")) |a| std.mem.eql(u8, a.s, "CRD") else false;

    const n: usize = onnx.extent(x, 0);
    const c: usize = onnx.extent(x, 1);
    const h: usize = onnx.extent(x, 2);
    const w: usize = onnx.extent(x, 3);
    if (c % (bs * bs) != 0) return error.TensorShapeMismatch;
    const oc = c / (bs * bs);

    const shape = ra.dupe(i64, &[_]i64{ @intCast(n), @intCast(oc), @intCast(h * bs), @intCast(w * bs) }) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = x.dtype;
    for (0..n) |bn| {
        for (0..oc) |co| {
            for (0..h) |y| {
                for (0..bs) |by| {
                    for (0..w) |xx| {
                        for (0..bs) |bx| {
                            const src_c = if (crd) co * bs * bs + by * bs + bx else (by * bs + bx) * oc + co;
                            const src = ((bn * c + src_c) * h + y) * w + xx;
                            const dst = ((bn * oc + co) * (h * bs) + y * bs + by) * (w * bs) + xx * bs + bx;
                            out.data[dst] = x.data[src];
                        }
                    }
                }
            }
        }
    }
    return out;
}

fn spaceToDepth(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    if (x.dims.len != 4) return error.TensorShapeMismatch;
    const bs: usize = @intCast(@max(node.attrInt("blocksize", 0), 0));
    if (bs == 0) return error.TensorShapeMismatch;
    const n: usize = onnx.extent(x, 0);
    const c: usize = onnx.extent(x, 1);
    const h: usize = onnx.extent(x, 2);
    const w: usize = onnx.extent(x, 3);
    if (h % bs != 0 or w % bs != 0) return error.TensorShapeMismatch;
    const oh = h / bs;
    const ow = w / bs;
    const oc = c * bs * bs;

    const shape = ra.dupe(i64, &[_]i64{ @intCast(n), @intCast(oc), @intCast(oh), @intCast(ow) }) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = x.dtype;
    for (0..n) |bn| {
        for (0..c) |ci| {
            for (0..bs) |by| {
                for (0..bs) |bx| {
                    const dst_c = (by * bs + bx) * c + ci;
                    for (0..oh) |y| {
                        for (0..ow) |xx| {
                            const src = ((bn * c + ci) * h + y * bs + by) * w + xx * bs + bx;
                            const dst = ((bn * oc + dst_c) * oh + y) * ow + xx;
                            out.data[dst] = x.data[src];
                        }
                    }
                }
            }
        }
    }
    return out;
}

fn reflect(v: i64, n: i64) i64 {
    if (n <= 1) return 0;
    const period = 2 * (n - 1);
    var r = @mod(v, period);
    if (r < 0) r += period;
    return if (r >= n) period - r else r;
}

fn samplePad(x: Tensor, base: usize, w: usize, h: usize, ix: i64, iy: i64, padding: u2) f32 {
    var px = ix;
    var py = iy;
    switch (padding) {
        0 => if (px < 0 or py < 0 or px >= @as(i64, @intCast(w)) or py >= @as(i64, @intCast(h))) return 0,
        1 => {
            px = @max(0, @min(@as(i64, @intCast(w)) - 1, px));
            py = @max(0, @min(@as(i64, @intCast(h)) - 1, py));
        },
        else => {
            px = reflect(px, @intCast(w));
            py = reflect(py, @intCast(h));
        },
    }
    return x.data[base + @as(usize, @intCast(py)) * w + @as(usize, @intCast(px))];
}

fn gridSample(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const grid = try in(table, node, 1);
    if (x.dims.len != 4 or grid.dims.len != 4) return error.TensorShapeMismatch;
    if (grid.dims[3] != 2) return error.TensorShapeMismatch;

    const mode_str = if (node.attr("mode")) |a| a.s else "bilinear";
    const nearest = std.mem.eql(u8, mode_str, "nearest");
    const pad_str = if (node.attr("padding_mode")) |a| a.s else "zeros";
    const padding: u2 = if (std.mem.eql(u8, pad_str, "border")) 1 else if (std.mem.eql(u8, pad_str, "reflection")) 2 else 0;
    const align_corners = node.attrInt("align_corners", 0) != 0;

    const n: usize = onnx.extent(x, 0);
    const c: usize = onnx.extent(x, 1);
    const h: usize = onnx.extent(x, 2);
    const w: usize = onnx.extent(x, 3);
    const oh: usize = onnx.extent(grid, 1);
    const ow: usize = onnx.extent(grid, 2);

    const shape = ra.dupe(i64, &[_]i64{ @intCast(n), @intCast(c), @intCast(oh), @intCast(ow) }) catch return error.OutOfMemory;
    const out = try newTensor(ra, shape);

    for (0..n) |bn| {
        for (0..oh) |y| {
            for (0..ow) |xx| {
                const g = ((bn * oh + y) * ow + xx) * 2;
                const gx = grid.data[g];
                const gy = grid.data[g + 1];
                const fx = denormalize(gx, w, align_corners);
                const fy = denormalize(gy, h, align_corners);
                for (0..c) |ci| {
                    const base = (bn * c + ci) * h * w;
                    const dst = ((bn * c + ci) * oh + y) * ow + xx;
                    if (nearest) {
                        out.data[dst] = samplePad(x, base, w, h, @intFromFloat(@round(fx)), @intFromFloat(@round(fy)), padding);
                        continue;
                    }
                    const x0: i64 = @intFromFloat(@floor(fx));
                    const y0: i64 = @intFromFloat(@floor(fy));
                    const tx = fx - @floor(fx);
                    const ty = fy - @floor(fy);
                    const v00 = samplePad(x, base, w, h, x0, y0, padding);
                    const v10 = samplePad(x, base, w, h, x0 + 1, y0, padding);
                    const v01 = samplePad(x, base, w, h, x0, y0 + 1, padding);
                    const v11 = samplePad(x, base, w, h, x0 + 1, y0 + 1, padding);
                    out.data[dst] = (v00 * (1 - tx) + v10 * tx) * (1 - ty) + (v01 * (1 - tx) + v11 * tx) * ty;
                }
            }
        }
    }
    return out;
}

fn denormalize(v: f32, extent: usize, align_corners: bool) f32 {
    const n: f32 = @floatFromInt(extent);
    if (align_corners) return (v + 1) * (n - 1) / 2;
    return ((v + 1) * n - 1) / 2;
}
