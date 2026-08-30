//! A logic graph: a small value-flow of math, logic and utility nodes a lens
//! authors as visual scripting. Each node reads earlier nodes, a trigger
//! signal, or a parameter, and the output node yields the value that drives a
//! parameter each tick. Evaluated on the cpu, deterministically.

const std = @import("std");
const trigger = @import("trigger");

pub const Op = enum {
    constant,
    signal,
    param,
    add,
    sub,
    mul,
    div,
    min,
    max,
    clamp,
    lerp,
    gt,
    lt,
    eq,
    logic_and,
    logic_or,
    logic_not,
    select,
    // Math-transform and vector nodes. Every one is built from IEEE-754-exact
    // operations (arithmetic, floor/ceil/round/trunc, sqrt), so a graph stays
    // bit-identical across platforms; transcendentals whose last bit differs
    // between libm implementations are deliberately left out.
    neg,
    abs,
    floor,
    ceil,
    round,
    trunc,
    frac,
    sign,
    sqrt,
    mod,
    hypot,
    step,
    smoothstep,
};

/// One graph node. a, b and c reference an earlier node by index, or -1 to
/// take the matching literal instead, so an input is either wired or a
/// constant with no extra node.
pub const Node = struct {
    op: Op,
    a: i32 = -1,
    b: i32 = -1,
    c: i32 = -1,
    a_lit: f32 = 0,
    b_lit: f32 = 0,
    c_lit: f32 = 0,
    constant: f32 = 0,
    signal: trigger.Signal = .{ .kind = .tap },
    param_index: u16 = 0,
};

pub const Graph = struct {
    nodes: []const Node,
    output: usize,

    /// Evaluates the graph against the current signals, writing each node's
    /// value into scratch (at least nodes.len long) and returning the output.
    pub fn eval(self: Graph, scratch: []f32, signals: trigger.Signals) f32 {
        for (self.nodes, 0..) |node, i| {
            scratch[i] = evalNode(node, scratch, signals);
        }
        return if (self.output < self.nodes.len) scratch[self.output] else 0;
    }
};

fn ref(idx: i32, lit: f32, scratch: []const f32) f32 {
    if (idx < 0) return lit;
    const u: usize = @intCast(idx);
    return if (u < scratch.len) scratch[u] else lit;
}

fn evalNode(node: Node, scratch: []const f32, signals: trigger.Signals) f32 {
    const a = ref(node.a, node.a_lit, scratch);
    const b = ref(node.b, node.b_lit, scratch);
    const c = ref(node.c, node.c_lit, scratch);
    return switch (node.op) {
        .constant => node.constant,
        .signal => @floatCast(trigger.signalValue(node.signal, signals)),
        .param => if (node.param_index < signals.params.len) @floatCast(signals.params[node.param_index]) else 0,
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => if (b != 0) a / b else 0,
        .min => @min(a, b),
        .max => @max(a, b),
        .clamp => std.math.clamp(a, b, c),
        .lerp => a + (b - a) * c,
        .gt => if (a > b) @as(f32, 1) else 0,
        .lt => if (a < b) @as(f32, 1) else 0,
        .eq => if (a == b) @as(f32, 1) else 0,
        .logic_and => if (a != 0 and b != 0) @as(f32, 1) else 0,
        .logic_or => if (a != 0 or b != 0) @as(f32, 1) else 0,
        .logic_not => if (a == 0) @as(f32, 1) else 0,
        .select => if (a != 0) b else c,
        .neg => -a,
        .abs => @abs(a),
        .floor => @floor(a),
        .ceil => @ceil(a),
        .round => @round(a),
        .trunc => @trunc(a),
        .frac => a - @floor(a),
        .sign => std.math.sign(a),
        .sqrt => if (a > 0) @sqrt(a) else 0,
        .mod => if (b != 0) a - b * @floor(a / b) else 0,
        .hypot => @sqrt(a * a + b * b),
        .step => if (b >= a) @as(f32, 1) else 0,
        .smoothstep => blk: {
            if (b == a) break :blk if (c >= a) @as(f32, 1) else 0;
            const s = std.math.clamp((c - a) / (b - a), 0, 1);
            break :blk s * s * (3 - 2 * s);
        },
    };
}

const t = std.testing;

test "a graph computes clamp(pointer.x * 2, 0, 1)" {
    const nodes = [_]Node{
        .{ .op = .signal, .signal = .{ .kind = .pointer_x } },
        .{ .op = .mul, .a = 0, .b_lit = 2.0 },
        .{ .op = .clamp, .a = 1, .b_lit = 0.0, .c_lit = 1.0 },
    };
    const g = Graph{ .nodes = &nodes, .output = 2 };
    var scratch: [3]f32 = undefined;
    try t.expectApproxEqAbs(@as(f32, 0.6), g.eval(&scratch, .{ .pointer_x = 0.3 }), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0), g.eval(&scratch, .{ .pointer_x = 0.9 }), 1e-6);
}

test "logic gates a value through a select node" {
    const nodes = [_]Node{
        .{ .op = .signal, .signal = .{ .kind = .tap } },
        .{ .op = .select, .a = 0, .b_lit = 1.0, .c_lit = 0.0 },
    };
    const g = Graph{ .nodes = &nodes, .output = 1 };
    var scratch: [2]f32 = undefined;
    try t.expectApproxEqAbs(@as(f32, 1.0), g.eval(&scratch, .{ .tap = true }), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.0), g.eval(&scratch, .{ .tap = false }), 1e-6);
}

test "the same graph and signals evaluate the same" {
    const nodes = [_]Node{ .{ .op = .constant, .constant = 3 }, .{ .op = .add, .a = 0, .b_lit = 4 } };
    const g = Graph{ .nodes = &nodes, .output = 1 };
    var s1: [2]f32 = undefined;
    var s2: [2]f32 = undefined;
    try t.expectEqual(g.eval(&s1, .{}), g.eval(&s2, .{}));
    try t.expectApproxEqAbs(@as(f32, 7.0), g.eval(&s1, .{}), 1e-6);
}

test "math-transform nodes compute exactly" {
    const nodes = [_]Node{
        .{ .op = .neg, .a_lit = 2.5 },
        .{ .op = .abs, .a = 0 },
        .{ .op = .floor, .a_lit = 2.7 },
        .{ .op = .frac, .a_lit = 2.75 },
        .{ .op = .mod, .a_lit = 7.0, .b_lit = 3.0 },
        .{ .op = .sign, .a_lit = -4.0 },
    };
    const g = Graph{ .nodes = &nodes, .output = 0 };
    var s: [nodes.len]f32 = undefined;
    _ = g.eval(&s, .{});
    try t.expectEqual(@as(f32, -2.5), s[0]);
    try t.expectEqual(@as(f32, 2.5), s[1]);
    try t.expectEqual(@as(f32, 2.0), s[2]);
    try t.expectApproxEqAbs(@as(f32, 0.75), s[3], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0), s[4], 1e-6);
    try t.expectEqual(@as(f32, -1.0), s[5]);
}

test "hypot is a vector magnitude and smoothstep ramps between edges" {
    const nodes = [_]Node{
        .{ .op = .hypot, .a_lit = 3.0, .b_lit = 4.0 },
        .{ .op = .smoothstep, .a_lit = 0.0, .b_lit = 1.0, .c_lit = 0.5 },
        .{ .op = .step, .a_lit = 0.5, .b_lit = 0.5 },
    };
    const g = Graph{ .nodes = &nodes, .output = 0 };
    var s: [nodes.len]f32 = undefined;
    _ = g.eval(&s, .{});
    try t.expectApproxEqAbs(@as(f32, 5.0), s[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5), s[1], 1e-6);
    try t.expectEqual(@as(f32, 1.0), s[2]);
}
