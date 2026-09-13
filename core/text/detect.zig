//! Turning a detector's probability map into text regions. This is the half of
//! detection no model does: threshold, find the connected blobs, fit an oriented
//! box to each, score it by the probability inside, and grow it back out to the
//! ink a shrunk training label cut off.

const std = @import("std");
const region = @import("region.zig");

const Point = region.Point;
const Quad = region.Quad;
const Region = region.Region;

pub const Options = struct {
    /// Where the probability map is cut. A detector trained with differentiable
    /// binarization is sharp around this, so it is not a sensitive knob.
    threshold: f32 = 0.3,
    /// The mean probability a blob must carry to survive, which is what rejects
    /// a smear of weak activation that happens to be connected.
    box_threshold: f32 = 0.5,
    /// How far a surviving box grows, recovering the margin the training label
    /// shrank away.
    unclip_ratio: f32 = 1.5,
    /// Regions below this many pixels on their short side are dropped: too
    /// small to recognise, and the common shape of a false positive.
    min_side_px: f32 = 3,
    max_regions: usize = 256,
};

/// The blob walk needs somewhere to put its frontier and its labels. The caller
/// owns it, so detection allocates nothing per frame.
pub const Scratch = struct {
    labels: []i32,
    frontier: []u32,

    pub fn init(gpa: std.mem.Allocator, width: usize, height: usize) !Scratch {
        return .{
            .labels = try gpa.alloc(i32, width * height),
            .frontier = try gpa.alloc(u32, width * height),
        };
    }

    pub fn deinit(s: Scratch, gpa: std.mem.Allocator) void {
        gpa.free(s.labels);
        gpa.free(s.frontier);
    }
};

/// Reads a [height][width] probability map and writes the regions it holds.
/// Answers how many landed; the caller's slice bounds the count, and a map with
/// more regions than that keeps the strongest.
pub fn regionsFrom(
    map: []const f32,
    width: usize,
    height: usize,
    opts: Options,
    scratch: Scratch,
    out: []Region,
) usize {
    if (width == 0 or height == 0 or map.len < width * height) return 0;
    if (scratch.labels.len < width * height or scratch.frontier.len < width * height) return 0;
    @memset(scratch.labels, 0);

    var found: usize = 0;
    var next_label: i32 = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const at = y * width + x;
            if (scratch.labels[at] != 0 or map[at] < opts.threshold) continue;
            next_label += 1;
            if (found >= out.len or found >= opts.max_regions) return found;

            // A breadth-first flood rather than recursion: a blob follows the
            // frame's own content, and recursion never follows untrusted shape.
            var head: usize = 0;
            var tail: usize = 0;
            scratch.frontier[tail] = @intCast(at);
            tail += 1;
            scratch.labels[at] = next_label;

            var sum: f32 = 0;
            var count: usize = 0;
            var min_x: f32 = @floatFromInt(x);
            var max_x: f32 = @floatFromInt(x);
            var min_y: f32 = @floatFromInt(y);
            var max_y: f32 = @floatFromInt(y);
            var sum_x: f32 = 0;
            var sum_y: f32 = 0;
            var sum_xx: f32 = 0;
            var sum_yy: f32 = 0;
            var sum_xy: f32 = 0;

            while (head < tail) {
                const here: usize = scratch.frontier[head];
                head += 1;
                const hx = here % width;
                const hy = here / width;
                const fx: f32 = @floatFromInt(hx);
                const fy: f32 = @floatFromInt(hy);
                sum += map[here];
                count += 1;
                min_x = @min(min_x, fx);
                max_x = @max(max_x, fx);
                min_y = @min(min_y, fy);
                max_y = @max(max_y, fy);
                sum_x += fx;
                sum_y += fy;
                sum_xx += fx * fx;
                sum_yy += fy * fy;
                sum_xy += fx * fy;

                const neighbours = [_][2]i64{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
                for (neighbours) |d| {
                    const nx = @as(i64, @intCast(hx)) + d[0];
                    const ny = @as(i64, @intCast(hy)) + d[1];
                    if (nx < 0 or ny < 0 or nx >= @as(i64, @intCast(width)) or ny >= @as(i64, @intCast(height))) continue;
                    const nat = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
                    if (scratch.labels[nat] != 0 or map[nat] < opts.threshold) continue;
                    scratch.labels[nat] = next_label;
                    scratch.frontier[tail] = @intCast(nat);
                    tail += 1;
                }
            }

            if (count == 0) continue;
            const score = sum / @as(f32, @floatFromInt(count));
            if (score < opts.box_threshold) continue;
            if (@min(max_x - min_x, max_y - min_y) + 1 < opts.min_side_px) continue;

            const quad = orientedBox(.{
                .count = count,
                .sum_x = sum_x,
                .sum_y = sum_y,
                .sum_xx = sum_xx,
                .sum_yy = sum_yy,
                .sum_xy = sum_xy,
                .min_x = min_x,
                .max_x = max_x,
                .min_y = min_y,
                .max_y = max_y,
            }, width, height);

            out[found] = .{
                .quad = quad.expand(opts.unclip_ratio),
                .confidence = score,
            };
            found += 1;
        }
    }
    return found;
}

const Moments = struct {
    count: usize,
    sum_x: f32,
    sum_y: f32,
    sum_xx: f32,
    sum_yy: f32,
    sum_xy: f32,
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
};

/// The blob's dominant axis from its second moments, and the box that bounds it
/// along that axis. Text on a tilted sign gives a tilted box, which is what the
/// rectifier needs; an axis-aligned bound would carry the neighbours in with it.
fn orientedBox(m: Moments, width: usize, height: usize) Quad {
    const n: f32 = @floatFromInt(m.count);
    const mean_x = m.sum_x / n;
    const mean_y = m.sum_y / n;
    const var_x = m.sum_xx / n - mean_x * mean_x;
    const var_y = m.sum_yy / n - mean_y * mean_y;
    const cov = m.sum_xy / n - mean_x * mean_y;

    // Half the arctangent of the covariance against the variance difference is
    // the principal axis; with no covariance it degenerates to axis-aligned,
    // which is the right answer for upright text.
    const theta: f32 = if (@abs(cov) < 1e-6 and @abs(var_x - var_y) < 1e-6)
        0
    else
        0.5 * std.math.atan2(2 * cov, var_x - var_y);
    const ct = @cos(theta);
    const st = @sin(theta);

    // Extents along the two axes, taken from the bounding box's corners rotated
    // into the blob's own frame, which needs no second pass over the pixels.
    var half_along: f32 = 0;
    var half_across: f32 = 0;
    const corners = [_][2]f32{
        .{ m.min_x, m.min_y }, .{ m.max_x, m.min_y },
        .{ m.max_x, m.max_y }, .{ m.min_x, m.max_y },
    };
    for (corners) |c| {
        const dx = c[0] - mean_x;
        const dy = c[1] - mean_y;
        half_along = @max(half_along, @abs(dx * ct + dy * st));
        half_across = @max(half_across, @abs(-dx * st + dy * ct));
    }

    const fw: f32 = @floatFromInt(width);
    const fh: f32 = @floatFromInt(height);
    var points: [4]Point = undefined;
    const offsets = [_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    for (offsets, 0..) |o, i| {
        const along = o[0] * half_along;
        const across = o[1] * half_across;
        points[i] = .{
            .x = (mean_x + along * ct - across * st + 0.5) / fw,
            .y = (mean_y + along * st + across * ct + 0.5) / fh,
        };
    }
    return Quad.ordered(points);
}

const testing = std.testing;

test "a probability map becomes one region per blob, weak blobs dropped" {
    const w = 32;
    const h = 16;
    var map: [w * h]f32 = @splat(0);
    // A strong horizontal bar and a weak one; only the strong one survives.
    for (4..12) |y| {
        for (3..20) |x| map[y * w + x] = 0.9;
    }
    for (4..12) |y| {
        for (24..30) |x| map[y * w + x] = 0.35;
    }

    var scratch = try Scratch.init(testing.allocator, w, h);
    defer scratch.deinit(testing.allocator);
    var out: [8]Region = undefined;
    const n = regionsFrom(&map, w, h, .{}, scratch, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectApproxEqAbs(@as(f32, 0.9), out[0].confidence, 1e-5);

    // The region sits over the bar it came from, grown by the unclip ratio.
    const c = out[0].quad.centre();
    try testing.expectApproxEqAbs(@as(f32, 11.5 / 32.0), c.x, 0.03);
    try testing.expectApproxEqAbs(@as(f32, 8.0 / 16.0), c.y, 0.03);
    try testing.expect(out[0].quad.extent().w > out[0].quad.extent().h);
}

test "detection finds nothing in an empty map and allocates nothing per frame" {
    const w = 24;
    const h = 24;
    const map: [w * h]f32 = @splat(0.05);
    var scratch = try Scratch.init(testing.allocator, w, h);
    defer scratch.deinit(testing.allocator);
    var out: [4]Region = undefined;
    try testing.expectEqual(@as(usize, 0), regionsFrom(&map, w, h, .{}, scratch, &out));

    // A map of solid probability is one region, not one per pixel.
    const solid: [w * h]f32 = @splat(0.95);
    try testing.expectEqual(@as(usize, 1), regionsFrom(&solid, w, h, .{}, scratch, &out));
}

test "a tilted bar gives a tilted box, not an axis-aligned one that swallows its neighbours" {
    const w = 40;
    const h = 40;
    var map: [w * h]f32 = @splat(0);
    // A diagonal stroke: every step right moves one down.
    for (5..35) |i| {
        const x = i;
        const y = i;
        for (0..3) |t| {
            if (y + t < h) map[(y + t) * w + x] = 0.95;
        }
    }
    var scratch = try Scratch.init(testing.allocator, w, h);
    defer scratch.deinit(testing.allocator);
    var out: [4]Region = undefined;
    try testing.expectEqual(@as(usize, 1), regionsFrom(&map, w, h, .{ .unclip_ratio = 1.0 }, scratch, &out));
    // Forty-five degrees, and far longer than it is wide.
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), out[0].quad.angle(), 0.1);
    const size = out[0].quad.extent();
    try testing.expect(size.w > size.h * 4);
}
