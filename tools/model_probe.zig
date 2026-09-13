//! Loads a real model, plans it, and runs it, printing what it needs, what it
//! costs and what it kept. It is how the sides in the model proofs were chosen:
//! a naive interpreter's budget is a measurement, never a guess.

// Usage: model-probe -- <model.onnx> [side] [runs] [picture] [unit|symmetric|byte]

const std = @import("std");
const onnx = @import("onnx");
const stb = @import("stb");

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
    const picture = args.next();
    // The same vocabulary the lens manifest uses, plus the byte range it does not
    // have, because a model that wants 0..255 is the question this argument answers.
    const range = args.next() orelse "unit";

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

    // A real picture, sampled into the input tensor the model declared. Without one
    // the tensor holds zeros, and a detector finds nothing in a blank frame, which
    // says nothing about whether it works.
    if (picture) |pic| {
        const encoded = try std.Io.Dir.cwd().readFileAlloc(init.io, pic, gpa, .limited(64 << 20));
        defer gpa.free(encoded);
        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        const pixels = stb.stbi_load_from_memory(encoded.ptr, @intCast(encoded.len), &w, &h, &channels, 4) orelse {
            std.debug.print("model-probe: {s} would not decode\n", .{pic});
            return error.UndecodablePicture;
        };
        const image: struct { width: usize, height: usize, pixels: [*c]u8 } = .{
            .width = @intCast(w),
            .height = @intCast(h),
            .pixels = pixels,
        };
        const declared = try engine.inputDims(0, &dims_buf);
        const nhwc = declared.len == 4 and declared[3] == 3;
        const edge: usize = @intCast(if (nhwc) declared[1] else declared[2]);
        const floats = try gpa.alloc(f32, edge * edge * 3);
        defer gpa.free(floats);
        for (0..edge) |y| {
            const sy = y * image.height / edge;
            for (0..edge) |x| {
                const sx = x * image.width / edge;
                const at = (sy * image.width + sx) * 4;
                inline for (0..3) |c| {
                    const raw = @as(f32, @floatFromInt(image.pixels[at + c]));
                    const v = if (std.mem.eql(u8, range, "byte"))
                        raw
                    else if (std.mem.eql(u8, range, "symmetric"))
                        raw / 127.5 - 1.0
                    else
                        raw / 255.0;
                    if (nhwc) floats[(y * edge + x) * 3 + c] = v else floats[c * edge * edge + y * edge + x] = v;
                }
            }
        }
        try engine.writeInput(0, std.mem.sliceAsBytes(floats));
        std.debug.print("model-probe: fed {s} at {d}x{d} as {s}\n", .{ pic, image.width, image.height, range });
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
    std.debug.print("model-probe: {d}us an inference, {d} pool growths\n", .{ best_us, engine.pool_growths });
    // Every output, not the first: a detector's boxes, classes, scores and count are
    // four tensors, and reporting one of them says nothing about which to read.
    var out_dims_buf: [8]i32 = undefined;
    for (0..engine.outputCount()) |i| {
        const out_dims = try engine.outputDims(i, &out_dims_buf);
        std.debug.print("model-probe: output {d}", .{i});
        for (out_dims) |d| std.debug.print(" {d}", .{d});
        const values = engine.outputFloats(i) catch &[_]f32{};
        // The first few rather than the first: a box is four numbers and which four
        // is the question a caller actually has.
        if (values.len != 0) {
            std.debug.print(", first", .{});
            for (values[0..@min(values.len, 8)]) |v| std.debug.print(" {d:.4}", .{v});
        }
        std.debug.print("\n", .{});
    }
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
