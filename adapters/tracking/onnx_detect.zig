//! Detector post-processing: the ops that turn a raw head into boxes, plus a
//! Zig-side decode so a caller gets boxes without wiring a graph to do it.

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
const intAt = onnx.intAt;

pub fn dispatch(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!?Tensor {
    const op = node.op_type;
    // TopK and NonMaxSuppression write their own outputs; the executor asks
    // this file first, so a multi-output op is handled before dispatch runs.
    if (eq(op, "ArgMax")) return try argExtreme(ra, node, table, true);
    if (eq(op, "ArgMin")) return try argExtreme(ra, node, table, false);
    if (eq(op, "RoiAlign")) return try roiAlign(ra, node, table);
    return null;
}

/// The ops with more than one output. Returning false means the executor keeps
/// looking, which is how one chain of dispatchers stays additive.
pub fn dispatchMulti(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!bool {
    if (eq(node.op_type, "TopK")) {
        try topK(ra, node, table);
        return true;
    }
    if (eq(node.op_type, "NonMaxSuppression")) {
        try nonMaxSuppression(ra, node, table);
        return true;
    }
    return false;
}

fn normAxis(a: i64, rank: usize) Error!usize {
    const r: i64 = @intCast(rank);
    const ax = if (a < 0) a + r else a;
    if (ax < 0 or ax >= r) return error.TensorShapeMismatch;
    return @intCast(ax);
}

fn argExtreme(ra: std.mem.Allocator, node: *const Node, table: *Table, want_max: bool) Error!Tensor {
    const x = try in(table, node, 0);
    const rank = x.dims.len;
    if (rank == 0) return error.TensorShapeMismatch;
    const ax = try normAxis(node.attrInt("axis", 0), rank);
    const keepdims = node.attrInt("keepdims", 1) != 0;
    const last_index = node.attrInt("select_last_index", 0) != 0;

    const along: usize = @intCast(@max(x.dims[ax], 1));
    var inner: usize = 1;
    for (ax + 1..rank) |d| inner *= @intCast(@max(x.dims[d], 1));
    const outer = if (along * inner == 0) 0 else x.data.len / (along * inner);

    var shape_buf: [8]i64 = undefined;
    var w: usize = 0;
    for (0..rank) |d| {
        if (d == ax) {
            if (keepdims) {
                shape_buf[w] = 1;
                w += 1;
            }
        } else {
            shape_buf[w] = @max(x.dims[d], 1);
            w += 1;
        }
    }
    const shape = ra.dupe(i64, shape_buf[0..w]) catch return error.OutOfMemory;
    var out = try newTensor(ra, shape);
    out.dtype = .i64;

    for (0..outer) |o| {
        for (0..inner) |i| {
            var best: f32 = x.data[(o * along) * inner + i];
            var best_at: usize = 0;
            for (1..along) |k| {
                const v = x.data[(o * along + k) * inner + i];
                const better = if (want_max) v > best else v < best;
                const tied = v == best and last_index;
                if (better or tied) {
                    best = v;
                    best_at = k;
                }
            }
            out.data[o * inner + i] = @floatFromInt(best_at);
        }
    }
    return out;
}

/// TopK sorts descending by default and stably, so two equal scores keep their
/// input order; an unstable sort here makes a detector's output depend on the
/// standard library's pivot choice.
fn topK(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!void {
    const x = try in(table, node, 0);
    const rank = x.dims.len;
    if (rank == 0 or node.outputs.len < 1) return error.TensorShapeMismatch;
    const ax = try normAxis(node.attrInt("axis", -1), rank);
    const largest = node.attrInt("largest", 1) != 0;
    const sorted = node.attrInt("sorted", 1) != 0;

    const along: usize = @intCast(@max(x.dims[ax], 1));
    var k: usize = along;
    if (node.inputs.len > 1 and node.inputs[1].len != 0) {
        const kt = try get(table, node.inputs[1]);
        if (kt.data.len == 0) return error.TensorShapeMismatch;
        const kv = intAt(kt, 0);
        if (kv < 0 or kv > @as(i64, @intCast(along))) return error.TensorShapeMismatch;
        k = @intCast(kv);
    }

    var inner: usize = 1;
    for (ax + 1..rank) |d| inner *= @intCast(@max(x.dims[d], 1));
    const outer = if (along * inner == 0) 0 else x.data.len / (along * inner);

    var shape = ra.dupe(i64, x.dims) catch return error.OutOfMemory;
    shape[ax] = @intCast(k);
    const values = try newTensor(ra, shape);
    var indices = try newTensor(ra, ra.dupe(i64, shape) catch return error.OutOfMemory);
    indices.dtype = .i64;

    const order = ra.alloc(u32, along) catch return error.OutOfMemory;
    for (0..outer) |o| {
        for (0..inner) |i| {
            for (order, 0..) |*slot, j| slot.* = @intCast(j);
            const Ctx = struct {
                data: []const f32,
                base: usize,
                inner: usize,
                largest: bool,
                fn lessThan(c: @This(), a: u32, b: u32) bool {
                    const va = c.data[(c.base + a) * c.inner];
                    const vb = c.data[(c.base + b) * c.inner];
                    if (va == vb) return a < b;
                    return if (c.largest) va > vb else va < vb;
                }
            };
            const ctx: Ctx = .{ .data = x.data[i..], .base = o * along, .inner = inner, .largest = largest };
            std.mem.sortUnstable(u32, order, ctx, Ctx.lessThan);
            if (!sorted) std.mem.sortUnstable(u32, order[0..k], {}, std.sort.asc(u32));
            for (0..k) |j| {
                const src = order[j];
                values.data[(o * k + j) * inner + i] = x.data[(o * along + src) * inner + i];
                indices.data[(o * k + j) * inner + i] = @floatFromInt(src);
            }
        }
    }
    table.put(ra, node.outputs[0], values) catch return error.OutOfMemory;
    if (node.outputs.len > 1 and node.outputs[1].len != 0) {
        table.put(ra, node.outputs[1], indices) catch return error.OutOfMemory;
    }
}

/// Intersection over union in whatever corner order the boxes arrive in, which
/// for the ONNX op is either corners or centre-and-size by attribute.
fn iou(a: [4]f32, b: [4]f32) f32 {
    const ax0 = @min(a[0], a[2]);
    const ay0 = @min(a[1], a[3]);
    const ax1 = @max(a[0], a[2]);
    const ay1 = @max(a[1], a[3]);
    const bx0 = @min(b[0], b[2]);
    const by0 = @min(b[1], b[3]);
    const bx1 = @max(b[0], b[2]);
    const by1 = @max(b[1], b[3]);
    const ix = @max(0, @min(ax1, bx1) - @max(ax0, bx0));
    const iy = @max(0, @min(ay1, by1) - @max(ay0, by0));
    const inter = ix * iy;
    const union_area = (ax1 - ax0) * (ay1 - ay0) + (bx1 - bx0) * (by1 - by0) - inter;
    if (union_area <= 0) return 0;
    return inter / union_area;
}

fn boxAt(boxes: Tensor, batch: usize, count: usize, i: usize, centred: bool) [4]f32 {
    const base = (batch * count + i) * 4;
    const v: [4]f32 = .{ boxes.data[base], boxes.data[base + 1], boxes.data[base + 2], boxes.data[base + 3] };
    if (!centred) return v;
    const half_w = v[2] / 2;
    const half_h = v[3] / 2;
    return .{ v[0] - half_w, v[1] - half_h, v[0] + half_w, v[1] + half_h };
}

const Candidate = struct { score: f32, index: u32 };

fn scoreDesc(_: void, a: Candidate, b: Candidate) bool {
    if (a.score == b.score) return a.index < b.index;
    return a.score > b.score;
}

fn nonMaxSuppression(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!void {
    const boxes = try in(table, node, 0);
    const scores = try in(table, node, 1);
    if (boxes.dims.len != 3 or scores.dims.len != 3) return error.TensorShapeMismatch;
    const batches: usize = @intCast(@max(boxes.dims[0], 1));
    const count: usize = @intCast(@max(boxes.dims[1], 1));
    const classes: usize = @intCast(@max(scores.dims[1], 1));
    const centred = node.attrInt("center_point_box", 0) != 0;

    var max_per_class: usize = count;
    if (node.inputs.len > 2 and node.inputs[2].len != 0) {
        const t = try get(table, node.inputs[2]);
        if (t.data.len != 0) {
            const v = intAt(t, 0);
            max_per_class = if (v < 0) 0 else @min(count, @as(usize, @intCast(v)));
        }
    }
    var iou_threshold: f32 = 0;
    if (node.inputs.len > 3 and node.inputs[3].len != 0) {
        const t = try get(table, node.inputs[3]);
        if (t.data.len != 0) iou_threshold = t.data[0];
    }
    var score_threshold: f32 = -std.math.floatMax(f32);
    if (node.inputs.len > 4 and node.inputs[4].len != 0) {
        const t = try get(table, node.inputs[4]);
        if (t.data.len != 0) score_threshold = t.data[0];
    }

    var kept: std.ArrayList([3]i64) = .empty;
    const cands = ra.alloc(Candidate, count) catch return error.OutOfMemory;
    const suppressed = ra.alloc(bool, count) catch return error.OutOfMemory;
    for (0..batches) |b| {
        for (0..classes) |c| {
            var n: usize = 0;
            for (0..count) |i| {
                const s = scores.data[(b * classes + c) * count + i];
                if (s <= score_threshold) continue;
                cands[n] = .{ .score = s, .index = @intCast(i) };
                n += 1;
            }
            std.mem.sortUnstable(Candidate, cands[0..n], {}, scoreDesc);
            @memset(suppressed[0..n], false);
            var taken: usize = 0;
            for (0..n) |i| {
                if (suppressed[i]) continue;
                if (taken >= max_per_class) break;
                const box_i = boxAt(boxes, b, count, cands[i].index, centred);
                kept.append(ra, .{ @intCast(b), @intCast(c), @intCast(cands[i].index) }) catch return error.OutOfMemory;
                taken += 1;
                for (i + 1..n) |j| {
                    if (suppressed[j]) continue;
                    if (iou(box_i, boxAt(boxes, b, count, cands[j].index, centred)) > iou_threshold) suppressed[j] = true;
                }
            }
        }
    }

    var out = try newTensor(ra, ra.dupe(i64, &[_]i64{ @intCast(kept.items.len), 3 }) catch return error.OutOfMemory);
    out.dtype = .i64;
    for (kept.items, 0..) |row, i| {
        for (0..3) |d| out.data[i * 3 + d] = @floatFromInt(row[d]);
    }
    if (node.outputs.len == 0) return error.InvokeFailed;
    table.put(ra, node.outputs[0], out) catch return error.OutOfMemory;
}

fn roiAlign(ra: std.mem.Allocator, node: *const Node, table: *Table) Error!Tensor {
    const x = try in(table, node, 0);
    const rois = try in(table, node, 1);
    const batch_indices = try in(table, node, 2);
    if (x.dims.len != 4 or rois.dims.len != 2 or rois.dims[1] != 4) return error.TensorShapeMismatch;

    const out_h: usize = @intCast(@max(node.attrInt("output_height", 1), 1));
    const out_w: usize = @intCast(@max(node.attrInt("output_width", 1), 1));
    const sampling: usize = @intCast(@max(node.attrInt("sampling_ratio", 0), 0));
    const spatial_scale = node.attrFloat("spatial_scale", 1.0);
    const avg = if (node.attr("mode")) |a| !std.mem.eql(u8, a.s, "max") else true;
    // Half-pixel is the default and the only offset that lines a pooled cell up
    // with the pixel grid; output_half_pixel exists for models trained the old way.
    const half_pixel = if (node.attr("coordinate_transformation_mode")) |a|
        !std.mem.eql(u8, a.s, "output_half_pixel")
    else
        true;

    const channels: usize = @intCast(@max(x.dims[1], 1));
    const h: usize = @intCast(@max(x.dims[2], 1));
    const w: usize = @intCast(@max(x.dims[3], 1));
    const n: usize = @intCast(@max(rois.dims[0], 1));

    const shape = ra.dupe(i64, &[_]i64{ @intCast(n), @intCast(channels), @intCast(out_h), @intCast(out_w) }) catch return error.OutOfMemory;
    const out = try newTensor(ra, shape);

    for (0..n) |r| {
        const bi_raw = intAt(batch_indices, @min(r, batch_indices.data.len -| 1));
        if (bi_raw < 0 or bi_raw >= @as(i64, @intCast(@max(x.dims[0], 1)))) return error.TensorShapeMismatch;
        const bi: usize = @intCast(bi_raw);
        const offset: f32 = if (half_pixel) 0.5 else 0;
        const x0 = rois.data[r * 4 + 0] * spatial_scale - offset;
        const y0 = rois.data[r * 4 + 1] * spatial_scale - offset;
        const x1 = rois.data[r * 4 + 2] * spatial_scale - offset;
        const y1 = rois.data[r * 4 + 3] * spatial_scale - offset;
        const roi_w = @max(x1 - x0, if (half_pixel) @as(f32, 0) else @as(f32, 1));
        const roi_h = @max(y1 - y0, if (half_pixel) @as(f32, 0) else @as(f32, 1));
        const bin_w = roi_w / @as(f32, @floatFromInt(out_w));
        const bin_h = roi_h / @as(f32, @floatFromInt(out_h));
        const grid_h = if (sampling > 0) sampling else @max(1, @as(usize, @intFromFloat(@ceil(bin_h))));
        const grid_w = if (sampling > 0) sampling else @max(1, @as(usize, @intFromFloat(@ceil(bin_w))));

        for (0..channels) |c| {
            const plane = (bi * channels + c) * h * w;
            for (0..out_h) |py| {
                for (0..out_w) |px| {
                    var acc: f32 = if (avg) 0 else -std.math.floatMax(f32);
                    var taken: usize = 0;
                    for (0..grid_h) |gy| {
                        for (0..grid_w) |gx| {
                            const sy = y0 + (@as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(gy)) + 0.5) / @as(f32, @floatFromInt(grid_h))) * bin_h;
                            const sx = x0 + (@as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(gx)) + 0.5) / @as(f32, @floatFromInt(grid_w))) * bin_w;
                            const v = bilinear(x.data[plane..][0 .. h * w], w, h, sx, sy);
                            if (avg) acc += v else acc = @max(acc, v);
                            taken += 1;
                        }
                    }
                    const dst = ((r * channels + c) * out_h + py) * out_w + px;
                    out.data[dst] = if (avg and taken != 0) acc / @as(f32, @floatFromInt(taken)) else acc;
                }
            }
        }
    }
    return out;
}

fn bilinear(plane: []const f32, w: usize, h: usize, fx: f32, fy: f32) f32 {
    if (fx < -1 or fy < -1 or fx > @as(f32, @floatFromInt(w)) or fy > @as(f32, @floatFromInt(h))) return 0;
    const cx = @max(0, fx);
    const cy = @max(0, fy);
    const x0: usize = @intFromFloat(@floor(cx));
    const y0: usize = @intFromFloat(@floor(cy));
    const x1 = @min(x0 + 1, w - 1);
    const y1 = @min(y0 + 1, h - 1);
    const tx = cx - @floor(cx);
    const ty = cy - @floor(cy);
    const cx0 = @min(x0, w - 1);
    const cy0 = @min(y0, h - 1);
    const v00 = plane[cy0 * w + cx0];
    const v10 = plane[cy0 * w + x1];
    const v01 = plane[y1 * w + cx0];
    const v11 = plane[y1 * w + x1];
    return (v00 * (1 - tx) + v10 * tx) * (1 - ty) + (v01 * (1 - tx) + v11 * tx) * ty;
}

// ---- Zig-side detection decode ----

/// How a detector head lays its numbers out. Anchor-free heads emit the box
/// directly; anchor heads emit an offset against a prior that must be applied
/// before anything is comparable.
pub const BoxFormat = enum {
    /// Centre, size, objectness, then per-class scores: the common one-stage layout.
    xywh_obj_classes,
    /// Centre and size with per-class scores and no objectness column.
    xywh_classes,
    /// Two corners with per-class scores.
    xyxy_classes,
};

pub const Detection = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    score: f32,
    class_id: u16,
};

pub const DecodeOptions = struct {
    format: BoxFormat = .xywh_obj_classes,
    score_threshold: f32 = 0.25,
    iou_threshold: f32 = 0.45,
    max_out: usize = 100,
    /// Divides the box coordinates, so a head emitting pixels against its own
    /// input size lands in the normalized space the rest of the engine uses.
    scale_x: f32 = 1,
    scale_y: f32 = 1,
};

/// Turns a raw head into boxes: threshold, pick the best class, then suppress.
/// Writes into out and answers how many survived, so the caller owns the memory
/// and the decode makes no allocation of its own.
pub fn decode(raw: []const f32, boxes_count: usize, stride: usize, opts: DecodeOptions, scratch: []Candidate, out: []Detection) usize {
    const class_offset: usize = switch (opts.format) {
        .xywh_obj_classes => 5,
        .xywh_classes, .xyxy_classes => 4,
    };
    if (stride <= class_offset or boxes_count * stride > raw.len) return 0;
    const classes = stride - class_offset;

    var n: usize = 0;
    for (0..boxes_count) |i| {
        if (n >= scratch.len or n >= out.len) break;
        const row = raw[i * stride ..][0..stride];
        const objectness: f32 = if (opts.format == .xywh_obj_classes) row[4] else 1;
        if (objectness < opts.score_threshold) continue;
        var best: f32 = 0;
        var best_class: usize = 0;
        for (0..classes) |c| {
            if (row[class_offset + c] > best) {
                best = row[class_offset + c];
                best_class = c;
            }
        }
        const score = best * objectness;
        if (score < opts.score_threshold) continue;
        var det: Detection = switch (opts.format) {
            .xyxy_classes => .{ .x0 = row[0], .y0 = row[1], .x1 = row[2], .y1 = row[3], .score = score, .class_id = @intCast(best_class) },
            else => .{
                .x0 = row[0] - row[2] / 2,
                .y0 = row[1] - row[3] / 2,
                .x1 = row[0] + row[2] / 2,
                .y1 = row[1] + row[3] / 2,
                .score = score,
                .class_id = @intCast(best_class),
            },
        };
        det.x0 /= opts.scale_x;
        det.x1 /= opts.scale_x;
        det.y0 /= opts.scale_y;
        det.y1 /= opts.scale_y;
        out[n] = det;
        scratch[n] = .{ .score = score, .index = @intCast(n) };
        n += 1;
    }

    std.mem.sortUnstable(Candidate, scratch[0..n], {}, scoreDesc);
    var accepted: usize = 0;
    for (0..n) |i| {
        const a = out[scratch[i].index];
        var dropped = accepted >= opts.max_out;
        var j: usize = 0;
        while (!dropped and j < i) : (j += 1) {
            if (scratch[j].score < 0) continue;
            const b = out[scratch[j].index];
            if (b.class_id != a.class_id) continue;
            if (iou(.{ a.x0, a.y0, a.x1, a.y1 }, .{ b.x0, b.y0, b.x1, b.y1 }) > opts.iou_threshold) dropped = true;
        }
        if (dropped) {
            scratch[i].score = -1;
            continue;
        }
        accepted += 1;
    }

    // Suppression is recorded on the detection itself, so compaction walks in
    // index order and the slot being written is never past the slot being read.
    for (0..n) |i| {
        if (scratch[i].score < 0) out[scratch[i].index].score = -1;
    }
    var kept: usize = 0;
    for (0..n) |i| {
        if (out[i].score < 0) continue;
        out[kept] = out[i];
        kept += 1;
    }
    std.mem.sortUnstable(Detection, out[0..kept], {}, detScoreDesc);
    return kept;
}

fn detScoreDesc(_: void, a: Detection, b: Detection) bool {
    if (a.score == b.score) return a.class_id < b.class_id;
    return a.score > b.score;
}

pub const Scratch = Candidate;
