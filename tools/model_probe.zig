//! Loads a real model, plans it, and runs it, printing what it needs, what it
//! costs and what it kept. It is how the sides in the model proofs were chosen:
//! a naive interpreter's budget is a measurement, never a guess.

// Usage: model-probe -- <model.onnx> [side] [runs]

const std = @import("std");
const onnx = @import("onnx");

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("model-probe: usage: model-probe <model.onnx> [side] [runs]\n", .{});
        return error.MissingArgument;
    };
    const side: i64 = if (args.next()) |a| try std.fmt.parseInt(i64, a, 10) else 0;
    const runs: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 3;

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(512 << 20)) catch |err| {
        std.debug.print("model-probe: {s}: {t}\n", .{ path, err });
        return err;
    };
    defer gpa.free(bytes);

    var missing_buf: [4096]u8 = undefined;
    const missing = try onnx.missingOps(gpa, bytes, &missing_buf);
    if (missing != 0) {
        std.debug.print("model-probe: {s} needs operators this build lacks:\n{s}\n", .{ path, missing_buf[0..@min(missing, missing_buf.len)] });
        return error.UnsupportedModel;
    }

    var engine = try onnx.Engine.init(gpa, bytes);
    defer engine.deinit();
    var dims_buf: [8]i32 = undefined;
    if (side > 0) {
        // The declared layout decides where the side goes. A detector exported
        // from TensorFlow is NHWC, and resizing it as NCHW hands every kernel a
        // shape the weights do not match.
        const declared = try engine.inputDims(0, &dims_buf);
        const nhwc = declared.len == 4 and declared[3] == 3;
        if (nhwc) {
            try engine.resizeInput(0, &[_]i64{ 1, side, side, 3 });
        } else {
            try engine.resizeInput(0, &[_]i64{ 1, 3, side, side });
        }
    }

    const in_dims = try engine.inputDims(0, &dims_buf);
    std.debug.print("model-probe: {s} input", .{path});
    for (in_dims) |d| std.debug.print(" {d}", .{d});
    std.debug.print(", {d} inputs, {d} outputs, plan {d} bytes\n", .{ engine.inputCount(), engine.outputCount(), engine.planBytes() });

    var best_us: u64 = std.math.maxInt(u64);
    for (0..runs) |_| {
        const started = std.Io.Timestamp.now(init.io, .awake);
        engine.invoke() catch |err| {
            std.debug.print("model-probe: {t} at node {d}, op {s}", .{ err, engine.failed_node, engine.failed_op });
            if (engine.failed_input.len != 0) std.debug.print(", input '{s}' was never produced", .{engine.failed_input});
            std.debug.print("\n", .{});
            reportBody(gpa, &engine);
            return err;
        };
        const cost: u64 = @intCast(@divTrunc(started.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds, 1000));
        best_us = @min(best_us, cost);
    }
    var out_dims_buf: [8]i32 = undefined;
    const out_dims = try engine.outputDims(0, &out_dims_buf);
    std.debug.print("model-probe: {d}us an inference, output", .{best_us});
    for (out_dims) |d| std.debug.print(" {d}", .{d});
    std.debug.print(", {d} pool growths\n", .{engine.pool_growths});
}

/// When the node that failed carries a body, says which node inside it asks for
/// a name nothing in scope produces. A control-flow node reports itself and not
/// its body, so without this a Loop that will not run is one line with nothing
/// under it.
fn reportBody(gpa: std.mem.Allocator, engine: *onnx.Engine) void {
    if (engine.failed_node >= engine.nodes.len) return;
    const node = &engine.nodes[engine.failed_node];
    for (node.attrs) |*a| {
        const body = a.g orelse continue;
        std.debug.print("model-probe: body '{s}': {d} nodes, {d} initializers, inputs", .{ a.name, body.nodes.len, body.initializers.len });
        for (body.input_names) |n| std.debug.print(" '{s}'", .{n});
        std.debug.print("\n", .{});

        var scope: std.StringHashMapUnmanaged(void) = .empty;
        defer scope.deinit(gpa);
        var it = engine.initializers.iterator();
        while (it.next()) |entry| scope.put(gpa, entry.key_ptr.*, {}) catch return;
        for (engine.inputs) |slot| scope.put(gpa, slot.name, {}) catch return;
        // Everything the outer graph produced before this node is in scope too,
        // which is what makes a captured value visible inside a body.
        for (engine.nodes[0..engine.failed_node]) |*earlier| {
            for (earlier.outputs) |out| scope.put(gpa, out, {}) catch return;
        }
        for (body.initializers) |ini| scope.put(gpa, ini.name, {}) catch return;
        for (body.input_names) |n| scope.put(gpa, n, {}) catch return;

        for (body.nodes, 0..) |*inner, i| {
            for (inner.inputs) |name| {
                if (name.len == 0) continue;
                if (scope.contains(name)) continue;
                std.debug.print("model-probe: body node {d} ({s}) asks for '{s}', which nothing in scope produces\n", .{ i, inner.op_type, name });
            }
            for (inner.outputs) |out| scope.put(gpa, out, {}) catch return;
        }
    }
}
