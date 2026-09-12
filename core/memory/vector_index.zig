//! The on-device index. A phone-sized corpus of embeddings that must answer a
//! nearest-neighbour query inside a frame, take inserts and deletes while it is
//! being queried, and stay inside a memory budget it was given rather than one
//! it discovers. The exact search stays beside it as the oracle the approximate
//! path is measured against, because a recall number nobody computed is a hope.

const std = @import("std");

pub const Error = error{ OutOfMemory, DimensionMismatch, Full, NotFound, Corrupt };

/// How two vectors are compared. Cosine is what an embedding model's output
/// wants; the index stores normalized copies so cosine is a dot product and the
/// hot loop has no divide in it.
pub const Metric = enum { cosine, euclidean };

pub const Match = struct {
    id: u64,
    score: f32,
};

/// Exact search, kept for small corpora and as the oracle. It is not a fallback
/// that nobody runs: the recall proof compares the approximate path against
/// this on the same corpus and the same queries.
pub fn exactSearch(
    vectors: []const f32,
    ids: []const u64,
    live: []const bool,
    dim: usize,
    query: []const f32,
    metric: Metric,
    out: []Match,
) usize {
    if (dim == 0 or query.len < dim or out.len == 0) return 0;
    var found: usize = 0;
    for (ids, 0..) |id, i| {
        if (i < live.len and !live[i]) continue;
        const base = i * dim;
        if (base + dim > vectors.len) break;
        const score = similarity(vectors[base..][0..dim], query[0..dim], metric);
        found = insertSorted(out, found, .{ .id = id, .score = score });
    }
    return found;
}

/// Higher is better for both metrics, so one comparison orders either: cosine
/// is the dot product of normalized vectors, and euclidean is negated so a
/// nearer neighbour still sorts first.
pub fn similarity(a: []const f32, b: []const f32, metric: Metric) f32 {
    switch (metric) {
        .cosine => {
            var dot: f32 = 0;
            for (a, b) |x, y| dot += x * y;
            return dot;
        },
        .euclidean => {
            var acc: f32 = 0;
            for (a, b) |x, y| {
                const d = x - y;
                acc += d * d;
            }
            return -acc;
        },
    }
}

/// Keeps the best results in order without a sort per insert. The list is short
/// (k is single digits in practice) so a linear insert beats a heap and has no
/// allocation at all.
fn insertSorted(out: []Match, count: usize, candidate: Match) usize {
    var at = count;
    if (at == out.len) {
        if (candidate.score <= out[at - 1].score) return count;
        at -= 1;
    }
    while (at > 0 and out[at - 1].score < candidate.score) : (at -= 1) out[at] = out[at - 1];
    out[at] = candidate;
    return @min(count + 1, out.len);
}

/// Normalizes in place so cosine similarity is a dot product. A zero vector
/// stays zero rather than becoming a NaN, and scores against it are zero, which
/// is the honest answer for a vector with no direction.
pub fn normalize(v: []f32) void {
    var acc: f32 = 0;
    for (v) |x| acc += x * x;
    if (acc <= 0) return;
    const inv = 1.0 / @sqrt(acc);
    for (v) |*x| x.* *= inv;
}

const testing = std.testing;

test "exact search orders by similarity and skips what was deleted" {
    const dim = 2;
    var vectors = [_]f32{
        1, 0, // east
        0, 1, // north
        0.7071, 0.7071, // north east
        -1, 0, // west
    };
    const ids = [_]u64{ 10, 20, 30, 40 };
    var live = [_]bool{ true, true, true, true };
    var out: [3]Match = undefined;

    const query = [_]f32{ 1, 0 };
    var n = exactSearch(&vectors, &ids, &live, dim, &query, .cosine, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u64, 10), out[0].id);
    try testing.expectEqual(@as(u64, 30), out[1].id);
    // North and west tie at nothing and something negative, so north comes next.
    try testing.expectEqual(@as(u64, 20), out[2].id);

    // A deleted vector is not a result, however close it is.
    live[0] = false;
    n = exactSearch(&vectors, &ids, &live, dim, &query, .cosine, &out);
    try testing.expectEqual(@as(u64, 30), out[0].id);

    // Euclidean orders the same way here but by distance, negated so nearer is
    // still first.
    live[0] = true;
    _ = exactSearch(&vectors, &ids, &live, dim, &query, .euclidean, &out);
    try testing.expectEqual(@as(u64, 10), out[0].id);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].score, 1e-6);
}

test "the result list keeps only the best and never grows past its bound" {
    var out: [2]Match = undefined;
    var n: usize = 0;
    n = insertSorted(&out, n, .{ .id = 1, .score = 0.5 });
    n = insertSorted(&out, n, .{ .id = 2, .score = 0.9 });
    n = insertSorted(&out, n, .{ .id = 3, .score = 0.1 });
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 2), out[0].id);
    try testing.expectEqual(@as(u64, 1), out[1].id);

    // A better score displaces the worst, a worse one is refused.
    n = insertSorted(&out, n, .{ .id = 4, .score = 0.7 });
    try testing.expectEqual(@as(u64, 4), out[1].id);
    n = insertSorted(&out, n, .{ .id = 5, .score = 0.01 });
    try testing.expectEqual(@as(u64, 4), out[1].id);
}

test "normalizing makes cosine a dot product and leaves a zero vector alone" {
    var v = [_]f32{ 3, 4 };
    normalize(&v);
    try testing.expectApproxEqAbs(@as(f32, 0.6), v[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), v[1], 1e-6);

    var zero = [_]f32{ 0, 0 };
    normalize(&zero);
    try testing.expectEqual(@as(f32, 0), zero[0]);
    try testing.expect(!std.math.isNan(zero[1]));
}
