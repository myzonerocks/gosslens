//! Control flow: If, Loop and Scan. Every body runs through a bounded,
//! non-recursive-in-structure executor with a hard depth and iteration cap,
//! because a model is untrusted input and a body that nests or never terminates
//! must fail rather than run the process out of stack or time.

const std = @import("std");
const onnx = @import("onnx.zig");

const Tensor = onnx.Tensor;
const Node = onnx.Node;
const Error = onnx.Error;
const Table = std.StringHashMapUnmanaged(Tensor);

const get = onnx.get;
const in = onnx.in;
const eq = onnx.eq;
const newTensor = onnx.newTensor;

pub fn dispatchMulti(ra: std.mem.Allocator, node: *const Node, table: *Table, depth: u8) Error!bool {
    if (eq(node.op_type, "If")) {
        try runIf(ra, node, table, depth);
        return true;
    }
    if (eq(node.op_type, "Loop")) {
        try runLoop(ra, node, table, depth);
        return true;
    }
    if (eq(node.op_type, "Scan")) {
        try runScan(ra, node, table, depth);
        return true;
    }
    return false;
}

/// A body sees the outer tensors plus its own, which is what makes a captured
/// weight visible inside a branch without the branch declaring it as an input.
fn bodyTable(ra: std.mem.Allocator, outer: *Table, sub: *const onnx.Subgraph) Error!Table {
    var inner: Table = .empty;
    inner.ensureTotalCapacity(ra, @intCast(outer.count() + sub.initializers.len + sub.nodes.len + 4)) catch return error.OutOfMemory;
    var it = outer.iterator();
    while (it.next()) |entry| inner.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    for (sub.initializers) |ini| inner.putAssumeCapacity(ini.name, ini.tensor);
    return inner;
}

fn subgraphOf(node: *const Node, name: []const u8) Error!*const onnx.Subgraph {
    const attr = node.attr(name) orelse return error.UnsupportedOp;
    return attr.g orelse error.UnsupportedOp;
}

fn runIf(ra: std.mem.Allocator, node: *const Node, table: *Table, depth: u8) Error!void {
    const cond = try in(table, node, 0);
    if (cond.data.len == 0) return error.TensorShapeMismatch;
    const taken = if (cond.data[0] != 0) try subgraphOf(node, "then_branch") else try subgraphOf(node, "else_branch");

    var inner = try bodyTable(ra, table, taken);
    try onnx.runNodes(ra, taken.nodes, &inner, depth + 1, taken.output_names);
    if (taken.output_names.len < node.outputs.len) return error.TensorShapeMismatch;
    for (node.outputs, 0..) |out_name, i| {
        if (out_name.len == 0) continue;
        const v = inner.get(taken.output_names[i]) orelse return error.InvokeFailed;
        table.put(ra, out_name, v) catch return error.OutOfMemory;
    }
}

/// Loop's body signature is (iteration, condition, carried...) in and
/// (condition, carried..., scanned...) out. The trip count and the condition
/// are both optional and either one alone terminates.
fn runLoop(ra: std.mem.Allocator, node: *const Node, table: *Table, depth: u8) Error!void {
    const body = try subgraphOf(node, "body");
    if (body.input_names.len < 2) return error.TensorShapeMismatch;
    const carried = body.input_names.len - 2;
    if (body.output_names.len < 1 + carried) return error.TensorShapeMismatch;
    const scanned = body.output_names.len - 1 - carried;

    var max_trips: usize = onnx.max_loop_iterations;
    if (node.inputs.len > 0 and node.inputs[0].len != 0) {
        const t = try get(table, node.inputs[0]);
        if (t.data.len != 0) {
            const v = onnx.intAt(t, 0);
            if (v < 0) return error.TensorShapeMismatch;
            max_trips = @min(max_trips, @as(usize, @intCast(v)));
        }
    }
    var keep_going = true;
    if (node.inputs.len > 1 and node.inputs[1].len != 0) {
        const t = try get(table, node.inputs[1]);
        if (t.data.len != 0) keep_going = t.data[0] != 0;
    }

    var state: [8]Tensor = undefined;
    if (carried > state.len) return error.TensorShapeMismatch;
    for (0..carried) |i| state[i] = try in(table, node, 2 + i);

    // Scanned outputs are concatenated along a new leading axis, so each
    // iteration's slice is stashed and stitched once the trip count is known.
    var collected: [8]std.ArrayList(f32) = @splat(.empty);
    var collected_dims: [8][]const i64 = @splat(&.{});
    if (scanned > collected.len) return error.TensorShapeMismatch;

    var trip: usize = 0;
    while (trip < max_trips and keep_going) : (trip += 1) {
        var inner = try bodyTable(ra, table, body);
        var iter = try newTensor(ra, ra.dupe(i64, &[_]i64{}) catch return error.OutOfMemory);
        iter.dtype = .i64;
        iter.data[0] = @floatFromInt(trip);
        var cond_t = try newTensor(ra, ra.dupe(i64, &[_]i64{}) catch return error.OutOfMemory);
        cond_t.dtype = .bool;
        cond_t.data[0] = if (keep_going) 1 else 0;
        inner.put(ra, body.input_names[0], iter) catch return error.OutOfMemory;
        inner.put(ra, body.input_names[1], cond_t) catch return error.OutOfMemory;
        for (0..carried) |i| inner.put(ra, body.input_names[2 + i], state[i]) catch return error.OutOfMemory;

        try onnx.runNodes(ra, body.nodes, &inner, depth + 1, body.output_names);

        const next_cond = inner.get(body.output_names[0]) orelse return error.InvokeFailed;
        keep_going = next_cond.data.len != 0 and next_cond.data[0] != 0;
        for (0..carried) |i| state[i] = inner.get(body.output_names[1 + i]) orelse return error.InvokeFailed;
        for (0..scanned) |i| {
            const slice = inner.get(body.output_names[1 + carried + i]) orelse return error.InvokeFailed;
            collected[i].appendSlice(ra, slice.data) catch return error.OutOfMemory;
            collected_dims[i] = slice.dims;
        }
    }

    for (node.outputs, 0..) |out_name, i| {
        if (out_name.len == 0) continue;
        if (i < carried) {
            table.put(ra, out_name, state[i]) catch return error.OutOfMemory;
            continue;
        }
        const s = i - carried;
        if (s >= scanned) return error.TensorShapeMismatch;
        table.put(ra, out_name, try stack(ra, collected[s].items, collected_dims[s], trip)) catch return error.OutOfMemory;
    }
}

fn stack(ra: std.mem.Allocator, flat: []const f32, inner_dims: []const i64, count: usize) Error!Tensor {
    var shape = ra.alloc(i64, inner_dims.len + 1) catch return error.OutOfMemory;
    shape[0] = @intCast(count);
    for (inner_dims, 1..) |d, i| shape[i] = @max(d, 1);
    const out = try newTensor(ra, shape);
    if (out.data.len != flat.len) return error.TensorShapeMismatch;
    @memcpy(out.data, flat);
    return out;
}

/// Scan walks a slice of each scan input per iteration instead of a trip count,
/// which is how a sequence model reads a time axis without an explicit loop.
fn runScan(ra: std.mem.Allocator, node: *const Node, table: *Table, depth: u8) Error!void {
    const body = try subgraphOf(node, "body");
    const scan_inputs: usize = @intCast(@max(node.attrInt("num_scan_inputs", 0), 0));
    if (scan_inputs == 0 or scan_inputs > node.inputs.len) return error.TensorShapeMismatch;
    const carried = node.inputs.len - scan_inputs;
    if (body.input_names.len < carried + scan_inputs) return error.TensorShapeMismatch;
    if (body.output_names.len < carried) return error.TensorShapeMismatch;
    const scan_outputs = body.output_names.len - carried;

    var state: [8]Tensor = undefined;
    if (carried > state.len or scan_inputs > 8 or scan_outputs > 8) return error.TensorShapeMismatch;
    for (0..carried) |i| state[i] = try in(table, node, i);

    var sequences: [8]Tensor = undefined;
    var slice_elems: [8]usize = @splat(0);
    var length: usize = 0;
    for (0..scan_inputs) |i| {
        sequences[i] = try in(table, node, carried + i);
        if (sequences[i].dims.len == 0) return error.TensorShapeMismatch;
        const n: usize = @intCast(@max(sequences[i].dims[0], 1));
        if (i == 0) length = n else if (n != length) return error.TensorShapeMismatch;
        slice_elems[i] = if (n == 0) 0 else sequences[i].data.len / n;
    }
    if (length > onnx.max_loop_iterations) return error.ModelRejected;

    var collected: [8]std.ArrayList(f32) = @splat(.empty);
    var collected_dims: [8][]const i64 = @splat(&.{});

    for (0..length) |step| {
        var inner = try bodyTable(ra, table, body);
        for (0..carried) |i| inner.put(ra, body.input_names[i], state[i]) catch return error.OutOfMemory;
        for (0..scan_inputs) |i| {
            const dims = ra.dupe(i64, sequences[i].dims[1..]) catch return error.OutOfMemory;
            const slice: Tensor = .{
                .dims = dims,
                .data = sequences[i].data[step * slice_elems[i] ..][0..slice_elems[i]],
                .dtype = sequences[i].dtype,
            };
            inner.put(ra, body.input_names[carried + i], slice) catch return error.OutOfMemory;
        }
        try onnx.runNodes(ra, body.nodes, &inner, depth + 1, body.output_names);
        for (0..carried) |i| state[i] = inner.get(body.output_names[i]) orelse return error.InvokeFailed;
        for (0..scan_outputs) |i| {
            const slice = inner.get(body.output_names[carried + i]) orelse return error.InvokeFailed;
            collected[i].appendSlice(ra, slice.data) catch return error.OutOfMemory;
            collected_dims[i] = slice.dims;
        }
    }

    for (node.outputs, 0..) |out_name, i| {
        if (out_name.len == 0) continue;
        if (i < carried) {
            table.put(ra, out_name, state[i]) catch return error.OutOfMemory;
            continue;
        }
        const s = i - carried;
        if (s >= scan_outputs) return error.TensorShapeMismatch;
        table.put(ra, out_name, try stack(ra, collected[s].items, collected_dims[s], length)) catch return error.OutOfMemory;
    }
}
