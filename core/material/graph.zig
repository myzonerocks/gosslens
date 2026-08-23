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
    subtract, // (T, T) -> T
    multiply, // (T, T) -> T
    divide, // (T, T) -> T
    power, // (T, T) -> T
    min, // (T, T) -> T
    max, // (T, T) -> T
    dot, // (vecN, vecN) -> float
    normalize, // (vecN) -> vecN
    saturate, // (T) -> T
    split, // (vecN) -> float, channel in params[0] (0..3)
    combine3, // (float, float, float) -> vec3
    combine4, // (float, float, float, float) -> vec4
    mix, // (T, T, float) -> T
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

fn isVector(value: ValueType) bool {
    return value == .vec2 or value == .vec3 or value == .vec4;
}

const ResolveState = enum { unseen, on_stack, done };

/// How many inputs a kind reads.
fn arity(kind: NodeKind) usize {
    return switch (kind) {
        .uv, .time, .constant, .uniform, .texture => 0,
        .saturate, .normalize, .split, .output => 1,
        .sample, .add, .subtract, .multiply, .divide, .power, .min, .max, .dot => 2,
        .mix, .combine3 => 3,
        .combine4 => 4,
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
        .saturate, .normalize => {
            const a = out_types[in[0]];
            if (a == .sampler) return error.TypeMismatch;
            if (node.kind == .normalize and !isVector(a)) return error.TypeMismatch;
            return a;
        },
        .add, .subtract, .multiply, .divide, .power, .min, .max => {
            const a = out_types[in[0]];
            if (a == .sampler or a != out_types[in[1]]) return error.TypeMismatch;
            return a;
        },
        .dot => {
            const a = out_types[in[0]];
            if (!isVector(a) or a != out_types[in[1]]) return error.TypeMismatch;
            return .float;
        },
        .split => {
            if (!isVector(out_types[in[0]])) return error.TypeMismatch;
            return .float;
        },
        .combine3, .combine4 => {
            for (in) |i| if (out_types[i] != .float) return error.TypeMismatch;
            return if (node.kind == .combine3) .vec3 else .vec4;
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

fn glType(value: ValueType) []const u8 {
    return switch (value) {
        .float => "float",
        .vec2 => "vec2",
        .vec3 => "vec3",
        .vec4 => "vec4",
        .sampler => "sampler2D",
    };
}

/// The swizzle that narrows a vec4 uniform down to a smaller type, since
/// bgfx carries every uniform as a vec4.
fn swizzle(value: ValueType) []const u8 {
    return switch (value) {
        .float => ".x",
        .vec2 => ".xy",
        .vec3 => ".xyz",
        else => "",
    };
}

fn emitConstant(node: Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const p = node.params;
    switch (node.value_type) {
        .float => try writer.print("{d}", .{p[0]}),
        .vec2 => try writer.print("vec2({d}, {d})", .{ p[0], p[1] }),
        .vec3 => try writer.print("vec3({d}, {d}, {d})", .{ p[0], p[1], p[2] }),
        .vec4, .sampler => try writer.print("vec4({d}, {d}, {d}, {d})", .{ p[0], p[1], p[2], p[3] }),
    }
}

/// Appends the nodes reachable from the root in dependency order, inputs
/// before the nodes that read them, using the DFS post-order.
fn topoOrder(gpa: std.mem.Allocator, graph: Graph, index: u32, seen: []bool, order: *std.ArrayList(u32)) error{OutOfMemory}!void {
    if (seen[index]) return;
    seen[index] = true;
    for (graph.nodes[index].inputs) |in| try topoOrder(gpa, graph, in, seen, order);
    try order.append(gpa, index);
}

fn emitStatement(graph: Graph, types: []const ValueType, index: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const node = graph.nodes[index];
    const in = node.inputs;
    try writer.print("\t{s} n{d} = ", .{ glType(types[index]), index });
    switch (node.kind) {
        .uv => try writer.writeAll("v_texcoord0"),
        .time => try writer.writeAll("u_time.x"),
        .constant => try emitConstant(node, writer),
        .uniform => try writer.print("u_{s}{s}", .{ node.name, swizzle(node.value_type) }),
        .sample => try writer.print("texture2D(s_{s}, n{d})", .{ graph.nodes[in[0]].name, in[1] }),
        .add => try writer.print("n{d} + n{d}", .{ in[0], in[1] }),
        .subtract => try writer.print("n{d} - n{d}", .{ in[0], in[1] }),
        .multiply => try writer.print("n{d} * n{d}", .{ in[0], in[1] }),
        .divide => try writer.print("n{d} / n{d}", .{ in[0], in[1] }),
        .power => try writer.print("pow(n{d}, n{d})", .{ in[0], in[1] }),
        .min => try writer.print("min(n{d}, n{d})", .{ in[0], in[1] }),
        .max => try writer.print("max(n{d}, n{d})", .{ in[0], in[1] }),
        .dot => try writer.print("dot(n{d}, n{d})", .{ in[0], in[1] }),
        .normalize => try writer.print("normalize(n{d})", .{in[0]}),
        .split => try writer.print("n{d}.{c}", .{ in[0], "xyzw"[@min(3, @as(usize, @intFromFloat(node.params[0])))] }),
        .combine3 => try writer.print("vec3(n{d}, n{d}, n{d})", .{ in[0], in[1], in[2] }),
        .combine4 => try writer.print("vec4(n{d}, n{d}, n{d}, n{d})", .{ in[0], in[1], in[2], in[3] }),
        .mix => try writer.print("mix(n{d}, n{d}, n{d})", .{ in[0], in[1], in[2] }),
        .saturate => try writer.print("clamp(n{d}, 0.0, 1.0)", .{in[0]}),
        .texture, .output => unreachable,
    }
    try writer.writeAll(";\n");
}

/// Lowers a validated graph to a bgfx fragment shader. `types` is the
/// resolved output type per node that validate() filled. Samplers and
/// uniforms are declared up front, then the reachable nodes emit in
/// dependency order and the output writes gl_FragColor.
pub fn emitFragment(gpa: std.mem.Allocator, graph: Graph, types: []const ValueType, writer: *std.Io.Writer) error{OutOfMemory}!void {
    writer.writeAll("$input v_texcoord0\n\n#include <bgfx_shader.sh>\n\n") catch return error.OutOfMemory;
    var next_sampler: u32 = 0;
    var uses_time = false;
    for (graph.nodes) |node| {
        switch (node.kind) {
            .texture => {
                writer.print("SAMPLER2D(s_{s}, {d});\n", .{ node.name, next_sampler }) catch return error.OutOfMemory;
                next_sampler += 1;
            },
            .uniform => writer.print("uniform vec4 u_{s};\n", .{node.name}) catch return error.OutOfMemory,
            .time => uses_time = true,
            else => {},
        }
    }
    if (uses_time) writer.writeAll("uniform vec4 u_time;\n") catch return error.OutOfMemory;

    writer.writeAll("\nvoid main()\n{\n") catch return error.OutOfMemory;
    const seen = try gpa.alloc(bool, graph.nodes.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    try topoOrder(gpa, graph, graph.root, seen, &order);
    for (order.items) |index| {
        switch (graph.nodes[index].kind) {
            .texture, .output => {},
            else => emitStatement(graph, types, index, writer) catch return error.OutOfMemory,
        }
    }
    writer.print("\tgl_FragColor = n{d};\n}}\n", .{graph.nodes[graph.root].inputs[0]}) catch return error.OutOfMemory;
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

test "the graph lowers to a bgfx fragment shader" {
    // uv -> sample(albedo) -> multiply(tint) -> output
    const nodes = [_]Node{
        .{ .kind = .uv }, // 0
        .{ .kind = .texture, .name = "albedo" }, // 1
        .{ .kind = .sample, .inputs = &.{ 1, 0 } }, // 2
        .{ .kind = .constant, .value_type = .vec4, .params = .{ 1, 0.5, 0.2, 1 } }, // 3
        .{ .kind = .multiply, .inputs = &.{ 2, 3 } }, // 4
        .{ .kind = .output, .inputs = &.{4} }, // 5
    };
    const graph: Graph = .{ .nodes = &nodes, .root = 5 };
    var types: [nodes.len]ValueType = undefined;
    try validate(t.allocator, graph, &types);

    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try emitFragment(t.allocator, graph, &types, &out.writer);
    const src = out.writer.buffered();

    try t.expect(std.mem.indexOf(u8, src, "$input v_texcoord0") != null);
    try t.expect(std.mem.indexOf(u8, src, "SAMPLER2D(s_albedo, 0);") != null);
    try t.expect(std.mem.indexOf(u8, src, "vec2 n0 = v_texcoord0;") != null);
    try t.expect(std.mem.indexOf(u8, src, "vec4 n2 = texture2D(s_albedo, n0);") != null);
    try t.expect(std.mem.indexOf(u8, src, "vec4 n4 = n2 * n3;") != null);
    try t.expect(std.mem.indexOf(u8, src, "gl_FragColor = n4;") != null);
}

test "vector algebra nodes validate and lower" {
    const nodes = [_]Node{
        .{ .kind = .uniform, .value_type = .vec3, .name = "normal" }, // 0 -> vec3
        .{ .kind = .normalize, .inputs = &.{0} }, // 1 -> vec3
        .{ .kind = .dot, .inputs = &.{ 1, 1 } }, // 2 -> float
        .{ .kind = .split, .inputs = &.{0}, .params = .{ 1, 0, 0, 0 } }, // 3 -> float (normal.y)
        .{ .kind = .combine4, .inputs = &.{ 2, 3, 2, 3 } }, // 4 -> vec4
        .{ .kind = .output, .inputs = &.{4} }, // 5
    };
    const graph: Graph = .{ .nodes = &nodes, .root = 5 };
    var types: [nodes.len]ValueType = undefined;
    try validate(t.allocator, graph, &types);
    try t.expectEqual(ValueType.vec3, types[1]); // normalize keeps the vector
    try t.expectEqual(ValueType.float, types[2]); // dot collapses to a scalar

    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try emitFragment(t.allocator, graph, &types, &out.writer);
    const src = out.writer.buffered();
    try t.expect(std.mem.indexOf(u8, src, "normalize(n0)") != null);
    try t.expect(std.mem.indexOf(u8, src, "dot(n1, n1)") != null);
    try t.expect(std.mem.indexOf(u8, src, "n0.y") != null);
    try t.expect(std.mem.indexOf(u8, src, "vec4(n2, n3, n2, n3)") != null);
}

test "dot needs matching vectors" {
    const bad = [_]Node{
        .{ .kind = .uniform, .value_type = .float, .name = "a" }, // 0 float
        .{ .kind = .dot, .inputs = &.{ 0, 0 } }, // 1 dot of scalars is invalid
        .{ .kind = .combine4, .inputs = &.{ 1, 1, 1, 1 } }, // 2
        .{ .kind = .output, .inputs = &.{2} }, // 3
    };
    try expectError(&bad, 3, error.TypeMismatch);
}
