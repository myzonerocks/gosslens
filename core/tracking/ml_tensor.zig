//! The shape and type of a tensor a bring-your-own model exposes, and the
//! bounds the engine holds an author model to. A lens declares its model's
//! tensors so the engine binds textures and signals to them; the bounds keep
//! an untrusted model sandboxed, so a hostile or oversized one never loads.

const std = @import("std");

/// The element type of a tensor, the subset a lens I/O binding needs.
pub const DType = enum(u8) { f32, u8, i32 };

pub fn dtypeSize(d: DType) u32 {
    return switch (d) {
        .f32, .i32 => 4,
        .u8 => 1,
    };
}

/// A tensor's dimensions, up to four (a batched image is the common shape).
/// rank names how many of dims are meaningful; the rest are ignored.
pub const Shape = struct {
    dims: [4]u32 = .{ 0, 0, 0, 0 },
    rank: u8 = 0,

    pub fn elementCount(self: Shape) u64 {
        if (self.rank == 0) return 0;
        var n: u64 = 1;
        for (self.dims[0..@min(self.rank, 4)]) |d| n *= d;
        return n;
    }

    pub fn byteCount(self: Shape, dtype: DType) u64 {
        return self.elementCount() * dtypeSize(dtype);
    }
};

/// Builds a Shape from a model's reported dimensions (the runtime hands these
/// back as ints). Up to four dims are kept; a non-positive dim reads as zero,
/// the unknown-size case a bound then rejects.
pub fn shapeFromDims(dims: []const i32) Shape {
    var s: Shape = .{};
    const n = @min(dims.len, 4);
    for (0..n) |i| s.dims[i] = if (dims[i] > 0) @intCast(dims[i]) else 0;
    s.rank = @intCast(n);
    return s;
}

/// How an ml.infer input plane is normalized, matching how the model was
/// exported: symmetric maps rgb to [-1,1] instead of [0,1], and mean/std_dev
/// subtract and divide per channel afterward (an ImageNet-style export).
pub const Norm = struct {
    symmetric: bool = false,
    mean: [3]f32 = .{ 0, 0, 0 },
    std_dev: [3]f32 = .{ 1, 1, 1 },
};

/// The sandbox an author model runs under. A model past any bound never loads,
/// so a lens cannot smuggle in a net that exhausts memory or stalls the frame.
pub const Bounds = struct {
    max_model_bytes: usize = 32 * 1024 * 1024,
    max_tensors: u8 = 16,
    max_tensor_bytes: u64 = 64 * 1024 * 1024,

    /// Whether a model within these counts and sizes is allowed to load.
    pub fn admits(self: Bounds, model_bytes: usize, tensor_count: usize, largest_tensor_bytes: u64) bool {
        return model_bytes <= self.max_model_bytes and
            tensor_count <= self.max_tensors and
            largest_tensor_bytes <= self.max_tensor_bytes;
    }
};

const t = std.testing;

test "a shape reports its element and byte counts" {
    const s = Shape{ .dims = .{ 1, 224, 224, 3 }, .rank = 4 };
    try t.expectEqual(@as(u64, 1 * 224 * 224 * 3), s.elementCount());
    try t.expectEqual(@as(u64, 1 * 224 * 224 * 3 * 4), s.byteCount(.f32));
    try t.expectEqual(@as(u64, 1 * 224 * 224 * 3), s.byteCount(.u8));
    try t.expectEqual(@as(u64, 0), (Shape{}).elementCount());
}

test "bounds admit a model within limits and reject one past any of them" {
    const b = Bounds{ .max_model_bytes = 1000, .max_tensors = 4, .max_tensor_bytes = 500 };
    try t.expect(b.admits(800, 3, 400));
    try t.expect(!b.admits(1200, 3, 400));
    try t.expect(!b.admits(800, 5, 400));
    try t.expect(!b.admits(800, 3, 600));
}

test "a shape builds from reported dims, keeping four and zeroing unknowns" {
    const s = shapeFromDims(&[_]i32{ 1, 224, 224, 3 });
    try t.expectEqual(@as(u8, 4), s.rank);
    try t.expectEqual(@as(u64, 1 * 224 * 224 * 3), s.elementCount());
    // A dynamic (non-positive) dim reads as zero, which a bound then rejects.
    const dyn = shapeFromDims(&[_]i32{ -1, 10 });
    try t.expectEqual(@as(u32, 0), dyn.dims[0]);
    try t.expectEqual(@as(u64, 0), dyn.elementCount());
}
