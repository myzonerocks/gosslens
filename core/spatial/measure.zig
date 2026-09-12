//! Measurement with its uncertainty attached. A distance reported as a number is
//! a number; a distance reported with the accuracy the platform claimed is a
//! measurement, and the difference matters the moment anyone acts on it. Every
//! result here carries both, and the uncertainty compounds the way the geometry
//! says rather than being quoted once and forgotten.

const std = @import("std");

/// Metres, always. The one unit, so nothing downstream has to ask which.
pub const Metres = f32;

/// What the platform claims about a point it gave us. Depth from a stereo pair at
/// three metres is not depth from a lidar at half a metre, and a measurement
/// built from either should say so.
pub const Accuracy = struct {
    /// One standard deviation, in metres. Zero means the platform reported none,
    /// which is not the same as claiming zero error.
    sigma: Metres = 0,
    /// Whether the platform reported an accuracy at all. A measurement built
    /// from an unreported accuracy is honest about being unbounded.
    reported: bool = false,

    pub const unknown: Accuracy = .{};

    pub fn of(sigma: Metres) Accuracy {
        return .{ .sigma = @max(0, sigma), .reported = true };
    }
};

pub const Point = struct {
    x: Metres,
    y: Metres,
    z: Metres,
    accuracy: Accuracy = .unknown,
};

/// A measurement and what is known about it. `known` is false when any input
/// carried no accuracy, so a caller can refuse to act on a number nobody
/// vouched for rather than reading sigma zero as certainty.
pub const Measurement = struct {
    value: Metres,
    sigma: Metres,
    known: bool,

    /// The value with its uncertainty as a range, which is the form a person
    /// reads and a decision uses.
    pub fn low(m: Measurement) Metres {
        return m.value - m.sigma;
    }

    pub fn high(m: Measurement) Metres {
        return m.value + m.sigma;
    }
};

/// Point to point. The uncertainties add in quadrature because the two errors are
/// independent: adding them directly would overstate the doubt, and ignoring one
/// would understate it.
pub fn distance(a: Point, b: Point) Measurement {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const dz = b.z - a.z;
    const d = @sqrt(dx * dx + dy * dy + dz * dz);
    return .{
        .value = d,
        .sigma = @sqrt(a.accuracy.sigma * a.accuracy.sigma + b.accuracy.sigma * b.accuracy.sigma),
        .known = a.accuracy.reported and b.accuracy.reported,
    };
}

/// The area of a polygon on a plane, by the shoelace formula over its own two
/// axes. The uncertainty is the perimeter times the worst point's sigma, which is
/// how far the boundary could be wrong all the way round.
pub fn area(points: []const Point) Measurement {
    if (points.len < 3) return .{ .value = 0, .sigma = 0, .known = false };
    var acc: f32 = 0;
    var perimeter: f32 = 0;
    var worst: Metres = 0;
    var known = true;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        acc += p.x * q.z - q.x * p.z;
        const dx = q.x - p.x;
        const dz = q.z - p.z;
        perimeter += @sqrt(dx * dx + dz * dz);
        worst = @max(worst, p.accuracy.sigma);
        if (!p.accuracy.reported) known = false;
    }
    return .{ .value = @abs(acc) / 2, .sigma = perimeter * worst, .known = known };
}

/// The volume of an axis-aligned box, and the uncertainty that follows from its
/// three extents each being uncertain. The first-order term is what matters at
/// any sigma small against the box, which is every case worth measuring.
pub fn boxVolume(width: Measurement, depth: Measurement, height: Measurement) Measurement {
    const v = width.value * depth.value * height.value;
    const dv = @abs(depth.value * height.value) * width.sigma +
        @abs(width.value * height.value) * depth.sigma +
        @abs(width.value * depth.value) * height.sigma;
    return .{ .value = v, .sigma = dv, .known = width.known and depth.known and height.known };
}

/// Whether two measurements agree inside what either claims. Two rulers that
/// disagree by less than their own doubt have not disagreed.
pub fn agree(a: Measurement, b: Measurement) bool {
    return @abs(a.value - b.value) <= a.sigma + b.sigma;
}

const testing = std.testing;

test "a distance carries the doubt of both its ends" {
    const a: Point = .{ .x = 0, .y = 0, .z = 0, .accuracy = Accuracy.of(0.01) };
    const b: Point = .{ .x = 3, .y = 4, .z = 0, .accuracy = Accuracy.of(0.02) };
    const d = distance(a, b);
    try testing.expectApproxEqAbs(@as(Metres, 5), d.value, 1e-5);
    // Quadrature, not a sum: the errors are independent.
    try testing.expectApproxEqAbs(@as(Metres, 0.0223607), d.sigma, 1e-6);
    try testing.expect(d.known);
    try testing.expectApproxEqAbs(@as(Metres, 5) - d.sigma, d.low(), 1e-6);

    // An unreported accuracy is not zero error, and the result says so.
    const bare: Point = .{ .x = 3, .y = 4, .z = 0 };
    const unsure = distance(a, bare);
    try testing.expectApproxEqAbs(@as(Metres, 5), unsure.value, 1e-5);
    try testing.expect(!unsure.known);
}

test "an area's doubt is its boundary's, all the way round" {
    const corners = [_]Point{
        .{ .x = 0, .y = 0, .z = 0, .accuracy = Accuracy.of(0.01) },
        .{ .x = 2, .y = 0, .z = 0, .accuracy = Accuracy.of(0.01) },
        .{ .x = 2, .y = 0, .z = 1, .accuracy = Accuracy.of(0.01) },
        .{ .x = 0, .y = 0, .z = 1, .accuracy = Accuracy.of(0.01) },
    };
    const a = area(&corners);
    try testing.expectApproxEqAbs(@as(Metres, 2), a.value, 1e-5);
    // A six metre perimeter at a centimetre is six centimetres of doubt.
    try testing.expectApproxEqAbs(@as(Metres, 0.06), a.sigma, 1e-5);
    try testing.expect(a.known);

    // Two points are not a region, and the answer says so rather than guessing.
    const sparse = area(corners[0..2]);
    try testing.expectEqual(@as(Metres, 0), sparse.value);
    try testing.expect(!sparse.known);
}

test "a volume compounds the doubt of all three extents" {
    const w: Measurement = .{ .value = 2, .sigma = 0.01, .known = true };
    const d: Measurement = .{ .value = 1, .sigma = 0.01, .known = true };
    const h: Measurement = .{ .value = 0.5, .sigma = 0.01, .known = true };
    const v = boxVolume(w, d, h);
    try testing.expectApproxEqAbs(@as(Metres, 1), v.value, 1e-5);
    // 0.5*0.01 + 1*0.01 + 2*0.01
    try testing.expectApproxEqAbs(@as(Metres, 0.035), v.sigma, 1e-5);
    try testing.expect(v.known);

    // One unvouched extent makes the whole volume unvouched.
    const bare: Measurement = .{ .value = 0.5, .sigma = 0, .known = false };
    try testing.expect(!boxVolume(w, d, bare).known);
}

test "two measurements that differ by less than their doubt have not disagreed" {
    const a: Measurement = .{ .value = 1.00, .sigma = 0.02, .known = true };
    const b: Measurement = .{ .value = 1.03, .sigma = 0.02, .known = true };
    try testing.expect(agree(a, b));
    const far: Measurement = .{ .value = 1.10, .sigma = 0.01, .known = true };
    try testing.expect(!agree(a, far));
}
