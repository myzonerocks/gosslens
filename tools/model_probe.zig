//! Loads a real model, plans it, and runs it, printing what it needs, what it
//! costs and what it kept. It is how the sides in the model proofs were chosen:
//! a naive interpreter's budget is a measurement, never a guess.
//!
//!   model-probe -- <model.onnx> [side] [runs]

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
    if (side > 0) try engine.resizeInput(0, &[_]i64{ 1, 3, side, side });

    var dims_buf: [8]i32 = undefined;
    const in_dims = try engine.inputDims(0, &dims_buf);
    std.debug.print("model-probe: {s} input", .{path});
    for (in_dims) |d| std.debug.print(" {d}", .{d});
    std.debug.print(", {d} inputs, {d} outputs, plan {d} bytes\n", .{ engine.inputCount(), engine.outputCount(), engine.planBytes() });

    var best_us: u64 = std.math.maxInt(u64);
    for (0..runs) |_| {
        const started = std.Io.Timestamp.now(init.io, .awake);
        try engine.invoke();
        const cost: u64 = @intCast(@divTrunc(started.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds, 1000));
        best_us = @min(best_us, cost);
    }
    var out_dims_buf: [8]i32 = undefined;
    const out_dims = try engine.outputDims(0, &out_dims_buf);
    std.debug.print("model-probe: {d}us an inference, output", .{best_us});
    for (out_dims) |d| std.debug.print(" {d}", .{d});
    std.debug.print(", {d} pool growths\n", .{engine.pool_growths});
}
