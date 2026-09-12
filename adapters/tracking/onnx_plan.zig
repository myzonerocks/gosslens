//! Load-time graph work: which operators a model needs, folding away what is
//! already known, and planning one buffer so inference allocates nothing.

const std = @import("std");
const onnx = @import("onnx.zig");

const Tensor = onnx.Tensor;
const Node = onnx.Node;
const Error = onnx.Error;
const Table = std.StringHashMapUnmanaged(Tensor);

/// Every operator the engine implements. The test below reads the dispatchers'
/// own source and fails if this list and the code disagree, so a new operator
/// cannot be added without appearing in the support report.
pub const supported_ops = [_][]const u8{
    "Abs",           "Acos",                    "Add",              "And",             "ArgMax",
    "ArgMin",        "Asin",                    "Atan",             "AveragePool",     "BatchNormalization",
    "Cast",          "CastLike",                "Ceil",             "Celu",            "Clip",
    "Compress",      "Concat",                  "Conv",             "ConvInteger",     "ConvTranspose",
    "Cos",           "CumSum",                  "DepthToSpace",     "DequantizeLinear", "Div",
    "DynamicQuantizeLinear", "Einsum",          "Elu",              "Equal",           "Erf",
    "Exp",           "Expand",                  "Flatten",          "Floor",           "Gather",
    "GatherElements", "GatherND",               "Gelu",             "Gemm",            "GlobalAveragePool",
    "Greater",       "GreaterOrEqual",          "GridSample",       "HardSigmoid",     "HardSwish",
    "Identity",      "If",                      "InstanceNormalization", "LayerNormalization", "LeakyRelu",
    "Less",          "LessOrEqual",             "Log",              "LogSoftmax",      "Loop",
    "MatMul",        "MatMulInteger",           "Max",              "MaxPool",         "Mean",
    "Min",           "Mish",                    "Mod",              "Mul",             "Neg",
    "NonMaxSuppression", "NonZero",             "Not",              "OneHot",          "Or",
    "PRelu",         "Pad",                     "Pow",              "QLinearConv",     "QLinearMatMul",
    "QuantizeLinear", "Range",                  "Reciprocal",       "ReduceL2",        "ReduceLogSum",
    "ReduceMax",     "ReduceMean",              "ReduceMin",        "ReduceProd",      "ReduceSum",
    "ReduceSumSquare", "Relu",                  "Reshape",          "Resize",          "RoiAlign",
    "Round",         "Scan",                    "Scatter",          "ScatterElements", "ScatterND",
    "Selu",          "Shape",                   "Sigmoid",          "Sign",            "Sin",
    "Slice",         "Softmax",              "SpaceToDepth",                 "Softplus",         "Softsign",        "Split",
    "Sqrt",          "Squeeze",                 "Sub",              "Sum",             "Tan",
    "Tanh",          "ThresholdedRelu",         "Tile",             "TopK",            "Transpose",
    "Trilu",         "Unsqueeze",               "Where",            "Xor",
};

pub fn isSupported(op: []const u8) bool {
    for (supported_ops) |name| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

/// Writes the operators a model needs that this engine does not implement, one
/// per line, and answers how many bytes the full answer takes. A caller with a
/// short buffer learns the size rather than a truncated list it cannot trust.
pub fn missingOps(nodes: []const Node, out: []u8) usize {
    var written: usize = 0;
    var needed: usize = 0;
    for (nodes, 0..) |node, i| {
        if (isSupported(node.op_type)) continue;
        var already = false;
        for (nodes[0..i]) |prior| {
            if (std.mem.eql(u8, prior.op_type, node.op_type)) already = true;
        }
        if (already) continue;
        const line_len = node.op_type.len + 1;
        needed += line_len;
        if (written + line_len <= out.len) {
            @memcpy(out[written..][0..node.op_type.len], node.op_type);
            out[written + node.op_type.len] = '\n';
            written += line_len;
        }
    }
    return needed;
}

// ---- lifetimes ----

/// The node index after which a value is dead. A graph output never dies, so
/// its slot is never handed to anything else.
pub const Lifetimes = struct {
    last_use: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn build(a: std.mem.Allocator, nodes: []const Node, outputs: []const []const u8) Error!Lifetimes {
        var lt: Lifetimes = .{};
        lt.last_use.ensureTotalCapacity(a, @intCast(nodes.len * 4 + outputs.len + 4)) catch return error.OutOfMemory;
        for (nodes, 0..) |node, i| {
            for (node.inputs) |name| {
                if (name.len == 0) continue;
                lt.last_use.put(a, name, @intCast(i)) catch return error.OutOfMemory;
            }
        }
        for (outputs) |name| lt.last_use.put(a, name, std.math.maxInt(u32)) catch return error.OutOfMemory;
        return lt;
    }

    pub fn diesAfter(lt: *const Lifetimes, name: []const u8, node_index: usize) bool {
        const at = lt.last_use.get(name) orelse return true;
        return at == node_index;
    }
};

// ---- one buffer, reused ----

/// A fixed-buffer allocator with a free list, so a tensor whose last reader has
/// run hands its bytes back for the next one. Allocation after load never
/// reaches the general allocator, which is what makes a frame's cost a number
/// rather than a hope.
pub const Pool = struct {
    buffer: []u8,
    blocks: []Block,
    used: usize = 0,
    high_water: usize = 0,
    exhausted: u32 = 0,

    pub const Block = struct { offset: usize, len: usize, free: bool };

    pub fn init(buffer: []u8, blocks: []Block) Pool {
        var p: Pool = .{ .buffer = buffer, .blocks = blocks };
        p.reset();
        return p;
    }

    pub fn reset(p: *Pool) void {
        p.used = 0;
        if (p.blocks.len != 0) {
            p.blocks[0] = .{ .offset = 0, .len = p.buffer.len, .free = true };
            p.used = 1;
        }
    }

    pub fn allocator(p: *Pool) std.mem.Allocator {
        return .{ .ptr = p, .vtable = &.{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        } };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const p: *Pool = @ptrCast(@alignCast(ctx));
        const want = alignment.toByteUnits();
        var i: usize = 0;
        while (i < p.used) : (i += 1) {
            const b = p.blocks[i];
            if (!b.free) continue;
            const base = std.mem.alignForward(usize, @intFromPtr(p.buffer.ptr) + b.offset, want);
            const pad = base - (@intFromPtr(p.buffer.ptr) + b.offset);
            if (b.len < pad + len) continue;
            return p.carve(i, pad, len) orelse continue;
        }
        p.exhausted += 1;
        return null;
    }

    /// Splits one free block into the padding before, the allocation, and the
    /// remainder after, keeping the block list sorted by offset.
    fn carve(p: *Pool, index: usize, pad: usize, len: usize) ?[*]u8 {
        const b = p.blocks[index];
        const tail = b.len - pad - len;
        var extra: usize = 0;
        if (pad != 0) extra += 1;
        if (tail != 0) extra += 1;
        if (p.used + extra > p.blocks.len) return null;

        var at = index;
        if (pad != 0) {
            std.mem.copyBackwards(Block, p.blocks[at + 2 .. p.used + 1], p.blocks[at + 1 .. p.used]);
            p.blocks[at] = .{ .offset = b.offset, .len = pad, .free = true };
            p.blocks[at + 1] = .{ .offset = b.offset + pad, .len = b.len - pad, .free = true };
            p.used += 1;
            at += 1;
        }
        const here = p.blocks[at];
        if (tail != 0) {
            std.mem.copyBackwards(Block, p.blocks[at + 2 .. p.used + 1], p.blocks[at + 1 .. p.used]);
            p.blocks[at] = .{ .offset = here.offset, .len = len, .free = false };
            p.blocks[at + 1] = .{ .offset = here.offset + len, .len = tail, .free = true };
            p.used += 1;
        } else {
            p.blocks[at].free = false;
        }
        const end = p.blocks[at].offset + len;
        p.high_water = @max(p.high_water, end);
        return p.buffer.ptr + p.blocks[at].offset;
    }

    fn indexOf(p: *Pool, ptr: [*]u8) ?usize {
        const offset = @intFromPtr(ptr) - @intFromPtr(p.buffer.ptr);
        for (0..p.used) |i| {
            if (p.blocks[i].offset == offset and !p.blocks[i].free) return i;
        }
        return null;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const p: *Pool = @ptrCast(@alignCast(ctx));
        const i = p.indexOf(memory.ptr) orelse return false;
        return new_len <= p.blocks[i].len;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        if (resizeFn(ctx, memory, alignment, new_len, ra)) return memory.ptr;
        return null;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const p: *Pool = @ptrCast(@alignCast(ctx));
        const i = p.indexOf(memory.ptr) orelse return;
        p.blocks[i].free = true;
        p.coalesce();
    }

    fn coalesce(p: *Pool) void {
        var i: usize = 0;
        while (i + 1 < p.used) {
            if (p.blocks[i].free and p.blocks[i + 1].free) {
                p.blocks[i].len += p.blocks[i + 1].len;
                std.mem.copyForwards(Block, p.blocks[i + 1 .. p.used - 1], p.blocks[i + 2 .. p.used]);
                p.used -= 1;
                continue;
            }
            i += 1;
        }
    }
};

// ---- load-time rewriting ----

pub const Optimization = struct {
    folded: u32 = 0,
    eliminated: u32 = 0,
    fused: u32 = 0,
};

fn producedBy(nodes: []const Node, name: []const u8) ?usize {
    for (nodes, 0..) |n, i| {
        for (n.outputs) |o| {
            if (std.mem.eql(u8, o, name)) return i;
        }
    }
    return null;
}

/// Drops every node no declared output depends on. A training graph carries
/// losses and debug taps a camera frame should never pay for.
pub fn eliminateDead(a: std.mem.Allocator, nodes: []const Node, outputs: []const []const u8, stats: *Optimization) Error![]const Node {
    const live = a.alloc(bool, nodes.len) catch return error.OutOfMemory;
    @memset(live, false);
    var wanted: std.ArrayList([]const u8) = .empty;
    for (outputs) |o| wanted.append(a, o) catch return error.OutOfMemory;

    var head: usize = 0;
    while (head < wanted.items.len) : (head += 1) {
        const name = wanted.items[head];
        const at = producedBy(nodes, name) orelse continue;
        if (live[at]) continue;
        live[at] = true;
        for (nodes[at].inputs) |i| {
            if (i.len != 0) wanted.append(a, i) catch return error.OutOfMemory;
        }
    }

    var kept: std.ArrayList(Node) = .empty;
    for (nodes, 0..) |n, i| {
        if (live[i]) {
            kept.append(a, n) catch return error.OutOfMemory;
        } else {
            stats.eliminated += 1;
        }
    }
    return kept.toOwnedSlice(a) catch return error.OutOfMemory;
}

/// Conv followed by batch normalization is one convolution once the four
/// batchnorm constants are folded into the weights and the bias, which is the
/// single biggest saving on any exported vision model.
pub fn fuseConvBatchNorm(
    a: std.mem.Allocator,
    nodes: []const Node,
    initializers: *std.StringHashMapUnmanaged(Tensor),
    stats: *Optimization,
) Error![]const Node {
    var kept: std.ArrayList(Node) = .empty;
    var skip = a.alloc(bool, nodes.len) catch return error.OutOfMemory;
    @memset(skip, false);

    for (nodes, 0..) |node, i| {
        if (skip[i]) continue;
        if (!std.mem.eql(u8, node.op_type, "Conv") or node.outputs.len != 1) {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        }
        const bn_at = nextConsumer(nodes, i, node.outputs[0]) orelse {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        };
        const bn = nodes[bn_at];
        if (!std.mem.eql(u8, bn.op_type, "BatchNormalization") or bn.inputs.len < 5 or
            countConsumers(nodes, node.outputs[0]) != 1)
        {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        }
        const w = initializers.get(node.inputs[1]) orelse {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        };
        const scale = initializers.get(bn.inputs[1]);
        const shift = initializers.get(bn.inputs[2]);
        const mean = initializers.get(bn.inputs[3]);
        const variance = initializers.get(bn.inputs[4]);
        if (scale == null or shift == null or mean == null or variance == null) {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        }
        const epsilon = bn.attrFloat("epsilon", 1e-5);
        const channels: usize = @intCast(@max(w.dims[0], 1));
        const per_channel = if (channels == 0) 0 else w.data.len / channels;

        const new_w = a.alloc(f32, w.data.len) catch return error.OutOfMemory;
        const new_b = a.alloc(f32, channels) catch return error.OutOfMemory;
        const old_bias: ?Tensor = if (node.inputs.len > 2 and node.inputs[2].len != 0) initializers.get(node.inputs[2]) else null;
        for (0..channels) |c| {
            const factor = scale.?.data[c % scale.?.data.len] / @sqrt(variance.?.data[c % variance.?.data.len] + epsilon);
            for (0..per_channel) |k| new_w[c * per_channel + k] = w.data[c * per_channel + k] * factor;
            const b0: f32 = if (old_bias) |ob| (if (c < ob.data.len) ob.data[c] else 0) else 0;
            new_b[c] = (b0 - mean.?.data[c % mean.?.data.len]) * factor + shift.?.data[c % shift.?.data.len];
        }

        const w_name = std.fmt.allocPrint(a, "{s}.fused_w", .{node.outputs[0]}) catch return error.OutOfMemory;
        const b_name = std.fmt.allocPrint(a, "{s}.fused_b", .{node.outputs[0]}) catch return error.OutOfMemory;
        initializers.put(a, w_name, .{ .dims = w.dims, .data = new_w }) catch return error.OutOfMemory;
        initializers.put(a, b_name, .{ .dims = a.dupe(i64, &[_]i64{@intCast(channels)}) catch return error.OutOfMemory, .data = new_b }) catch return error.OutOfMemory;

        const inputs = a.alloc([]const u8, 3) catch return error.OutOfMemory;
        inputs[0] = node.inputs[0];
        inputs[1] = w_name;
        inputs[2] = b_name;
        kept.append(a, .{
            .op_type = node.op_type,
            .inputs = inputs,
            .outputs = bn.outputs[0..1],
            .attrs = node.attrs,
        }) catch return error.OutOfMemory;
        skip[bn_at] = true;
        stats.fused += 1;
    }
    return kept.toOwnedSlice(a) catch return error.OutOfMemory;
}

fn nextConsumer(nodes: []const Node, after: usize, name: []const u8) ?usize {
    for (nodes[after + 1 ..], after + 1..) |n, i| {
        for (n.inputs) |in_name| {
            if (std.mem.eql(u8, in_name, name)) return i;
        }
    }
    return null;
}

fn countConsumers(nodes: []const Node, name: []const u8) usize {
    var count: usize = 0;
    for (nodes) |n| {
        for (n.inputs) |in_name| {
            if (std.mem.eql(u8, in_name, name)) count += 1;
        }
    }
    return count;
}

/// Runs every node whose inputs are all already known and turns its result into
/// an initializer. Shape arithmetic is the usual beneficiary: a graph that
/// computes its own reshape target does it once at load rather than per frame.
pub fn foldConstants(
    a: std.mem.Allocator,
    nodes: []const Node,
    initializers: *std.StringHashMapUnmanaged(Tensor),
    fed_inputs: []const []const u8,
    stats: *Optimization,
) Error![]const Node {
    var kept: std.ArrayList(Node) = .empty;
    for (nodes, 0..) |node, at| {
        var foldable = node.inputs.len != 0 and node.outputs.len == 1;
        for (node.inputs) |name| {
            if (name.len == 0) continue;
            if (initializers.get(name) == null) foldable = false;
            for (fed_inputs) |fed| {
                if (std.mem.eql(u8, fed, name)) foldable = false;
            }
        }
        // Control flow and the data-dependent shapes stay put: folding them
        // would bake in an answer that depends on the frame.
        if (foldable and (std.mem.eql(u8, node.op_type, "If") or std.mem.eql(u8, node.op_type, "Loop") or
            std.mem.eql(u8, node.op_type, "Scan") or std.mem.eql(u8, node.op_type, "NonZero"))) foldable = false;
        if (!foldable) {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        }

        var scratch: Table = .empty;
        for (node.inputs) |name| {
            if (name.len == 0) continue;
            scratch.put(a, name, initializers.get(name).?) catch return error.OutOfMemory;
        }
        onnx.runNodes(a, nodes[at .. at + 1], &scratch, 0) catch {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        };
        const produced = scratch.get(node.outputs[0]) orelse {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        };
        initializers.put(a, node.outputs[0], produced) catch return error.OutOfMemory;
        stats.folded += 1;
    }
    return kept.toOwnedSlice(a) catch return error.OutOfMemory;
}
