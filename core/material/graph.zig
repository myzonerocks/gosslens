//! A node-based material graph: typed nodes wired by their inputs into a
//! DAG that lowers to shader source. This module is the data model and
//! its validation; lowering to the shader backends comes next.

const std = @import("std");

/// The value a node's single output carries. A wire only connects
/// matching types; the validator rejects a mismatch.
pub const ValueType = enum { float, vec2, vec3, vec4, sampler };

/// The node operations. Sources take no inputs and carry a declared or
/// fixed output type; ops derive their output type from their inputs.
pub const NodeKind = enum {
    uv, // () -> vec2, the fragment texture coordinate
    time, // () -> float, seconds
    constant, // () -> value_type, from params
    uniform, // () -> value_type, host-set by name
    texture, // () -> sampler, bound by name
    sample, // (sampler, vec2) -> vec4
    add, // (T, T) -> T, T any non-sampler
    multiply, // (T, T) -> T
    mix, // (T, T, float) -> T
    saturate, // (T) -> T
    output, // (vec4) -> the material colour, the graph root
};

pub const Node = struct {
    kind: NodeKind,
    /// Node indices this node reads, in the order its kind expects.
    inputs: []const u32 = &.{},
    /// The output type of a constant or uniform source; ignored for ops,
    /// whose type is derived, and for uv/time/texture, whose type is fixed.
    value_type: ValueType = .vec4,
    /// A constant's literal value; unused by other kinds.
    params: [4]f32 = .{ 0, 0, 0, 0 },
    /// The binding name for a uniform or texture node; empty otherwise.
    name: []const u8 = "",
};

pub const Graph = struct {
    nodes: []const Node,
    /// The single output node's index; it must have kind == .output.
    root: u32,
};

pub const Error = error{
    RootOutOfRange,
    RootNotOutput,
    MultipleOutputs,
    InputOutOfRange,
    WrongInputCount,
    TypeMismatch,
    Cycle,
    OutOfMemory,
};

const ResolveState = enum { unseen, on_stack, done };

/// How many inputs a kind reads.
fn arity(kind: NodeKind) usize {
    return switch (kind) {
        .uv, .time, .constant, .uniform, .texture => 0,
        .saturate, .output => 1,
        .sample, .add, .multiply => 2,
        .mix => 3,
    };
}

/// The fixed output type of a source kind, or null for a kind whose type
/// is declared (constant/uniform) or derived (the ops).
fn fixedOutput(kind: NodeKind) ?ValueType {
    return switch (kind) {
        .uv => .vec2,
        .time => .float,
        .texture => .sampler,
        .sample => .vec4,
        else => null,
    };
}

/// Validates the graph: the root is the one output node, every input is
/// in range with the right count and type, and the graph is acyclic.
/// Fills each node's resolved output type into out_types (len == nodes).
pub fn validate(gpa: std.mem.Allocator, graph: Graph, out_types: []ValueType) Error!void {
    const nodes = graph.nodes;
    std.debug.assert(out_types.len == nodes.len);
    if (graph.root >= nodes.len) return error.RootOutOfRange;
    if (nodes[graph.root].kind != .output) return error.RootNotOutput;

    var output_count: usize = 0;
    for (nodes) |node| {
        if (node.kind == .output) output_count += 1;
        if (node.inputs.len != arity(node.kind)) return error.WrongInputCount;
        for (node.inputs) |in| if (in >= nodes.len) return error.InputOutOfRange;
    }
    if (output_count != 1) return error.MultipleOutputs;

    // A DFS from the root resolves each reachable node's output type once
    // its inputs are known, and the on-stack mark catches any cycle.
    const state = try gpa.alloc(ResolveState, nodes.len);
    defer gpa.free(state);
    @memset(state, .unseen);
    try resolve(graph, graph.root, state, out_types);
}

fn resolve(graph: Graph, index: u32, state: []ResolveState, out_types: []ValueType) Error!void {
    switch (state[index]) {
        .done => return,
        .on_stack => return error.Cycle,
        .unseen => {},
    }
    state[index] = .on_stack;
    const node = graph.nodes[index];
    for (node.inputs) |in| try resolve(graph, in, state, out_types);

    out_types[index] = try outputType(node, out_types);
    state[index] = .done;
}

/// The node's output type, after type-checking its inputs against its
/// kind. Inputs are already resolved into out_types by the DFS.
fn outputType(node: Node, out_types: []const ValueType) Error!ValueType {
    const in = node.inputs;
    switch (node.kind) {
        .uv, .time, .texture, .sample => return fixedOutput(node.kind).?,
        .constant, .uniform => return node.value_type,
        .saturate => {
            if (out_types[in[0]] == .sampler) return error.TypeMismatch;
            return out_types[in[0]];
        },
        .add, .multiply => {
            const a = out_types[in[0]];
            if (a == .sampler or a != out_types[in[1]]) return error.TypeMismatch;
            return a;
        },
        .mix => {
            const a = out_types[in[0]];
            if (a == .sampler or a != out_types[in[1]]) return error.TypeMismatch;
            if (out_types[in[2]] != .float) return error.TypeMismatch;
            return a;
        },
        .output => {
            if (out_types[in[0]] != .vec4) return error.TypeMismatch;
            return .vec4;
        },
    }
}

const t = std.testing;

fn expectValid(nodes: []const Node, root: u32) !void {
    var types: [16]ValueType = undefined;
    try validate(t.allocator, .{ .nodes = nodes, .root = root }, types[0..nodes.len]);
}

fn expectError(nodes: []const Node, root: u32, want: Error) !void {
    var types: [16]ValueType = undefined;
    try t.expectError(want, validate(t.allocator, .{ .nodes = nodes, .root = root }, types[0..nodes.len]));
}

test "a texture-sampled, tinted material validates" {
    // uv -> sample(tex) -> multiply(tint) -> output
    const nodes = [_]Node{
        .{ .kind = .uv }, // 0
        .{ .kind = .texture, .name = "albedo" }, // 1
        .{ .kind = .sample, .inputs = &.{ 1, 0 } }, // 2 -> vec4
        .{ .kind = .constant, .value_type = .vec4, .params = .{ 1, 0.5, 0.2, 1 } }, // 3
        .{ .kind = .multiply, .inputs = &.{ 2, 3 } }, // 4 -> vec4
        .{ .kind = .output, .inputs = &.{4} }, // 5
    };
    try expectValid(&nodes, 5);
}

test "a cycle is rejected" {
    const nodes = [_]Node{
        .{ .kind = .saturate, .inputs = &.{2} }, // 0 <- 2
        .{ .kind = .saturate, .inputs = &.{0} }, // 1 <- 0
        .{ .kind = .saturate, .inputs = &.{1} }, // 2 <- 1 (cycle)
        .{ .kind = .output, .inputs = &.{0} }, // 3
    };
    try expectError(&nodes, 3, error.Cycle);
}

test "a type mismatch on a reachable node is rejected" {
    // add(vec2, float) has mismatched operands, and it feeds the output
    // so the walk reaches it; a dead mismatched node would not be checked.
    const nodes = [_]Node{
        .{ .kind = .uv }, // 0 -> vec2
        .{ .kind = .time }, // 1 -> float
        .{ .kind = .add, .inputs = &.{ 0, 1 } }, // 2 mismatched
        .{ .kind = .output, .inputs = &.{2} }, // 3
    };
    try expectError(&nodes, 3, error.TypeMismatch);
}

test "the output must take a vec4" {
    const nodes = [_]Node{
        .{ .kind = .time }, // 0 -> float
        .{ .kind = .output, .inputs = &.{0} }, // 1 wants vec4
    };
    try expectError(&nodes, 1, error.TypeMismatch);
}

test "a dangling input and a bad root are rejected" {
    const dangling = [_]Node{
        .{ .kind = .constant, .value_type = .vec4 }, // 0
        .{ .kind = .output, .inputs = &.{7} }, // 1 -> out of range
    };
    try expectError(&dangling, 1, error.InputOutOfRange);

    const not_output = [_]Node{
        .{ .kind = .uv }, // 0
        .{ .kind = .output, .inputs = &.{0} }, // 1, but root points at 0
    };
    try expectError(&not_output, 0, error.RootNotOutput);
}

test "exactly one output node is allowed" {
    const two = [_]Node{
        .{ .kind = .constant, .value_type = .vec4 }, // 0
        .{ .kind = .output, .inputs = &.{0} }, // 1
        .{ .kind = .output, .inputs = &.{0} }, // 2
    };
    try expectError(&two, 1, error.MultipleOutputs);
}
