//! Screens as a source. A captured surface is not a camera frame: it has a
//! scale factor, a logical geometry, and an origin somewhere on a desktop, and
//! an agent that says "press here" needs that point to land on a real pixel of
//! a real display. This is the arithmetic that makes that true, plus the
//! structured layer the platform already knows and nobody should infer from
//! pixels.

const std = @import("std");

/// What was captured. A window and a display need different treatment when a
/// coordinate goes back: a window moves, a display does not.
pub const SurfaceKind = enum { display, window, application, tab, unknown };

/// One thing that can be captured, as the platform reports it.
pub const Surface = struct {
    /// Stable for as long as the platform keeps it, and meaningless across
    /// runs, so it is never persisted as an identity.
    id: u64,
    kind: SurfaceKind,
    /// The platform's own name, borrowed. A caller that keeps it copies it.
    title: []const u8 = &.{},
    /// Logical points, the unit the windowing system places things in.
    logical_width: f32,
    logical_height: f32,
    /// Where the surface sits on the desktop, in logical points, so a window's
    /// coordinate maps to the desktop and not only to itself.
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    /// Backing pixels per logical point. Two on a retina display, and the
    /// reason a naive mapping lands at half the intended place.
    scale: f32 = 1,

    pub fn pixelWidth(s: Surface) u32 {
        return @intFromFloat(@round(s.logical_width * s.scale));
    }

    pub fn pixelHeight(s: Surface) u32 {
        return @intFromFloat(@round(s.logical_height * s.scale));
    }
};

pub const Point = struct { x: f32, y: f32 };

/// Where a normalized frame coordinate lands, in every unit a caller might
/// need: the surface's own logical points, its backing pixels, and the desktop.
pub const Landing = struct {
    logical: Point,
    pixel: Point,
    desktop: Point,
};

/// Maps a point in the normalized frame an agent saw back to the surface it
/// came from. Everything downstream of a screen source speaks normalized
/// coordinates, so this is the one place the scale factor and the desktop
/// origin are applied, rather than each caller applying them again.
pub fn landing(surface: Surface, normalized: Point) Landing {
    const logical: Point = .{
        .x = normalized.x * surface.logical_width,
        .y = normalized.y * surface.logical_height,
    };
    return .{
        .logical = logical,
        .pixel = .{ .x = logical.x * surface.scale, .y = logical.y * surface.scale },
        .desktop = .{ .x = surface.origin_x + logical.x, .y = surface.origin_y + logical.y },
    };
}

/// The inverse: a point on the desktop, as the normalized frame coordinate that
/// would have produced it. Outside the surface it answers null rather than a
/// number off the edge, because a caller acting on an off-surface coordinate is
/// acting on the wrong window.
pub fn normalize(surface: Surface, desktop: Point) ?Point {
    if (surface.logical_width <= 0 or surface.logical_height <= 0) return null;
    const x = (desktop.x - surface.origin_x) / surface.logical_width;
    const y = (desktop.y - surface.origin_y) / surface.logical_height;
    if (x < 0 or y < 0 or x > 1 or y > 1) return null;
    return .{ .x = x, .y = y };
}

/// A screen is static most of the time, and a static screen should cost
/// nothing. This samples a coarse grid rather than every pixel, so the check is
/// a fixed cost whatever the resolution.
pub const ChangeDetector = struct {
    /// The grid is coarse on purpose: a cursor blinking in a text field is a
    /// change, and a caller that wants to ignore it raises the threshold rather
    /// than making the grid finer.
    pub const grid = 16;

    previous: [grid * grid]u8 = @splat(0),
    primed: bool = false,

    /// Answers what fraction of the grid moved, and remembers this frame. A
    /// first frame always reads as fully changed, because nothing is known
    /// before it and reporting no change would be a lie.
    pub fn change(d: *ChangeDetector, rgba: []const u8, width: usize, height: usize, stride: usize) f32 {
        if (width == 0 or height == 0) return 0;
        var cells: [grid * grid]u8 = undefined;
        for (0..grid) |gy| {
            const y = @min(height - 1, (gy * 2 + 1) * height / (grid * 2));
            for (0..grid) |gx| {
                const x = @min(width - 1, (gx * 2 + 1) * width / (grid * 2));
                const at = y * stride + x * 4;
                if (at + 2 >= rgba.len) {
                    cells[gy * grid + gx] = 0;
                    continue;
                }
                // Luminance, so a hue shift at the same brightness still reads
                // as a change but a compression wobble does not.
                const r: u32 = rgba[at];
                const g: u32 = rgba[at + 1];
                const b: u32 = rgba[at + 2];
                cells[gy * grid + gx] = @intCast((r * 54 + g * 183 + b * 19) >> 8);
            }
        }

        if (!d.primed) {
            d.previous = cells;
            d.primed = true;
            return 1;
        }
        var moved: usize = 0;
        for (cells, d.previous) |now, was| {
            const delta = if (now > was) now - was else was - now;
            if (delta > 4) moved += 1;
        }
        d.previous = cells;
        return @as(f32, @floatFromInt(moved)) / @as(f32, @floatFromInt(cells.len));
    }

    pub fn reset(d: *ChangeDetector) void {
        d.primed = false;
    }
};

/// What the operating system already knows about an element on the screen. An
/// agent reading a screen should not have to infer a button from pixels when
/// the accessibility tree names it.
pub const Role = enum(u8) {
    unknown = 0,
    button,
    link,
    text_field,
    static_text,
    image,
    checkbox,
    radio,
    menu,
    menu_item,
    list,
    list_item,
    tab,
    slider,
    window,
    toolbar,
    table,
    cell,
};

/// One element, in the same normalized space as everything else the engine
/// reports, so an element rect and a detected text region are comparable.
pub const Element = struct {
    role: Role,
    /// Normalized against the captured surface, left, top, width, height.
    rect: [4]f32,
    /// Borrowed from the platform; a caller that keeps it copies it.
    label: []const u8 = &.{},
    value: []const u8 = &.{},
    enabled: bool = true,
    focused: bool = false,
    /// The element's parent in the tree, or itself at the root, so a caller can
    /// walk up without the engine shipping pointers across the boundary.
    parent: u32 = 0,
};

/// Whether a point falls inside an element, used to answer "what is under this
/// coordinate" without the caller redoing the rectangle arithmetic.
pub fn hit(elements: []const Element, p: Point) ?usize {
    var best: ?usize = null;
    var best_area: f32 = std.math.floatMax(f32);
    for (elements, 0..) |e, i| {
        if (p.x < e.rect[0] or p.y < e.rect[1]) continue;
        if (p.x > e.rect[0] + e.rect[2] or p.y > e.rect[1] + e.rect[3]) continue;
        // The smallest element containing the point is the one meant, which is
        // what makes a button inside a toolbar inside a window answer "button".
        const area = e.rect[2] * e.rect[3];
        if (area < best_area) {
            best_area = area;
            best = i;
        }
    }
    return best;
}

const testing = std.testing;

test "a normalized point lands on a real pixel of a real display" {
    // A retina window, offset onto a second display.
    const surface: Surface = .{
        .id = 1,
        .kind = .window,
        .logical_width = 800,
        .logical_height = 600,
        .origin_x = 1920,
        .origin_y = 100,
        .scale = 2,
    };
    try testing.expectEqual(@as(u32, 1600), surface.pixelWidth());
    try testing.expectEqual(@as(u32, 1200), surface.pixelHeight());

    const l = landing(surface, .{ .x = 0.5, .y = 0.25 });
    try testing.expectApproxEqAbs(@as(f32, 400), l.logical.x, 1e-4);
    // The scale factor is the difference between pressing the button and
    // pressing whatever is at half its position.
    try testing.expectApproxEqAbs(@as(f32, 800), l.pixel.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 300), l.pixel.y, 1e-4);
    // And the desktop point carries the window's own origin.
    try testing.expectApproxEqAbs(@as(f32, 2320), l.desktop.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 250), l.desktop.y, 1e-4);

    const back = normalize(surface, l.desktop).?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), back.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), back.y, 1e-5);
    // A point on another display is not this surface's to answer for.
    try testing.expect(normalize(surface, .{ .x = 10, .y = 10 }) == null);
}

test "a static screen reports no change and a moved region does" {
    const w = 64;
    const h = 64;
    var frame: [w * h * 4]u8 = @splat(30);
    var detector: ChangeDetector = .{};
    // Nothing is known before the first frame, so it reads as fully changed.
    try testing.expectApproxEqAbs(@as(f32, 1), detector.change(&frame, w, h, w * 4), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), detector.change(&frame, w, h, w * 4), 1e-6);

    // A bright quarter appears: about a quarter of the grid moves.
    for (0..h / 2) |y| {
        for (0..w / 2) |x| {
            const at = (y * w + x) * 4;
            frame[at] = 240;
            frame[at + 1] = 240;
            frame[at + 2] = 240;
        }
    }
    const moved = detector.change(&frame, w, h, w * 4);
    try testing.expect(moved > 0.2 and moved < 0.3);
    try testing.expectApproxEqAbs(@as(f32, 0), detector.change(&frame, w, h, w * 4), 1e-6);
}

test "the smallest element under a point is the one meant" {
    const elements = [_]Element{
        .{ .role = .window, .rect = .{ 0, 0, 1, 1 } },
        .{ .role = .toolbar, .rect = .{ 0, 0, 1, 0.1 }, .parent = 0 },
        .{ .role = .button, .rect = .{ 0.02, 0.02, 0.06, 0.06 }, .label = "Save", .parent = 1 },
    };
    const at = hit(&elements, .{ .x = 0.05, .y = 0.05 }).?;
    try testing.expectEqual(Role.button, elements[at].role);
    try testing.expectEqualStrings("Save", elements[at].label);

    // Outside the toolbar but inside the window.
    const outer = hit(&elements, .{ .x = 0.5, .y = 0.5 }).?;
    try testing.expectEqual(Role.window, elements[outer].role);
    try testing.expect(hit(&elements, .{ .x = 1.5, .y = 0.5 }) == null);
}
