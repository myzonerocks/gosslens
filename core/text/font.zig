//! A compact built-in 8x8 bitmap font and a string rasterizer, so a lens
//! draws text with no font file. Glyphs are eight rows of eight bits (high
//! bit leftmost) covering space, digits, upper- and lowercase, and punctuation.
//! rasterize lays a string into an RGBA buffer to upload like a sprite.

const std = @import("std");

pub const glyph_px = 8;

/// Eight rows for `ch`, the high bit of each the leftmost column. Unknown
/// characters (and space) return an empty glyph.
fn glyph(ch: u8) [8]u8 {
    return switch (ch) {
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        '!' => .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 },
        '.' => .{ 0, 0, 0, 0, 0, 0, 0x18, 0x18 },
        ',' => .{ 0, 0, 0, 0, 0, 0x18, 0x18, 0x30 },
        '-' => .{ 0, 0, 0, 0x7E, 0, 0, 0, 0 },
        ':' => .{ 0, 0x18, 0x18, 0, 0, 0x18, 0x18, 0 },
        '?' => .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00 },
        '0' => .{ 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00 },
        '1' => .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 },
        '2' => .{ 0x3C, 0x66, 0x06, 0x0C, 0x30, 0x60, 0x7E, 0x00 },
        '3' => .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 },
        '4' => .{ 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00 },
        '5' => .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 },
        '6' => .{ 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00 },
        '7' => .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00 },
        '8' => .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 },
        '9' => .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00 },
        'A' => .{ 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00 },
        'B' => .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 },
        'C' => .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 },
        'D' => .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 },
        'E' => .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 },
        'F' => .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 },
        'G' => .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3C, 0x00 },
        'H' => .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 },
        'I' => .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
        'J' => .{ 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38, 0x00 },
        'K' => .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 },
        'L' => .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 },
        'M' => .{ 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00 },
        'N' => .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 },
        'O' => .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 },
        'P' => .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 },
        'Q' => .{ 0x3C, 0x66, 0x66, 0x66, 0x6E, 0x3C, 0x0E, 0x00 },
        'R' => .{ 0x7C, 0x66, 0x66, 0x7C, 0x78, 0x6C, 0x66, 0x00 },
        'S' => .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 },
        'T' => .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 },
        'U' => .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 },
        'V' => .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 },
        'W' => .{ 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00 },
        'X' => .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 },
        'Y' => .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 },
        'Z' => .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 },
        'a' => .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 },
        'b' => .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 },
        'c' => .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 },
        'd' => .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 },
        'e' => .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 },
        'f' => .{ 0x1C, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x30, 0x00 },
        'g' => .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x7C },
        'h' => .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 },
        'i' => .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 },
        'j' => .{ 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0x6C, 0x6C, 0x38 },
        'k' => .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 },
        'l' => .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
        'm' => .{ 0x00, 0x00, 0x66, 0x7F, 0x6B, 0x6B, 0x63, 0x00 },
        'n' => .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 },
        'o' => .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 },
        'p' => .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 },
        'q' => .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 },
        'r' => .{ 0x00, 0x00, 0x7C, 0x66, 0x60, 0x60, 0x60, 0x00 },
        's' => .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 },
        't' => .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x1C, 0x00 },
        'u' => .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 },
        'v' => .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 },
        'w' => .{ 0x00, 0x00, 0x63, 0x6B, 0x6B, 0x7F, 0x36, 0x00 },
        'x' => .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 },
        'y' => .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x7C },
        'z' => .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 },
        else => .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
}

/// The pixel size of `text` at integer `scale` (each glyph cell is
/// glyph_px*scale). Monospace, one row per line: a newline starts a new
/// line, so width is the longest line and height is the line count.
pub fn measure(text: []const u8, scale: u32) struct { w: u32, h: u32 } {
    const s = @max(scale, 1);
    var lines: u32 = 1;
    var max_len: u32 = 0;
    var cur: u32 = 0;
    for (text) |ch| {
        if (ch == '\n') {
            lines += 1;
            if (cur > max_len) max_len = cur;
            cur = 0;
        } else cur += 1;
    }
    if (cur > max_len) max_len = cur;
    return .{ .w = max_len * glyph_px * s, .h = lines * glyph_px * s };
}

/// Greedy word-wraps `text` to at most `max_cols` monospace columns per line,
/// breaking at spaces where a word fits and hard-breaking a word longer than a
/// full line, while preserving the caller's own newlines. `max_cols` 0 returns
/// the text unchanged. The caller owns and frees the returned bytes.
pub fn wrap(gpa: std.mem.Allocator, text: []const u8, max_cols: u32) ![]u8 {
    if (max_cols == 0) return gpa.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var col: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\n') {
            try out.append(gpa, '\n');
            col = 0;
            i += 1;
        } else if (ch == ' ') {
            // A run of spaces collapses at a line start; otherwise decide by the
            // next word: keep it on this line if the space plus the word fits,
            // else wrap here and drop the space.
            var j = i + 1;
            while (j < text.len and text[j] != ' ' and text[j] != '\n') j += 1;
            const word_len: u32 = @intCast(j - (i + 1));
            if (col == 0) {
                i += 1;
            } else if (col + 1 + word_len > max_cols) {
                try out.append(gpa, '\n');
                col = 0;
                i += 1;
            } else {
                try out.append(gpa, ' ');
                col += 1;
                i += 1;
            }
        } else {
            if (col >= max_cols) {
                try out.append(gpa, '\n');
                col = 0;
            }
            try out.append(gpa, ch);
            col += 1;
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Rasterizes `text` into a freshly allocated RGBA buffer: each glyph
/// pixel set to `color`, every other pixel fully transparent. The caller
/// owns and frees the returned bytes.
pub const Raster = struct { rgba: []u8, width: u32, height: u32 };

pub fn rasterize(gpa: std.mem.Allocator, text: []const u8, scale: u32, color: [4]u8) !Raster {
    const s = @max(scale, 1);
    const dim = measure(text, s);
    const width = @max(dim.w, 1);
    const height = @max(dim.h, 1);
    const rgba = try gpa.alloc(u8, width * height * 4);
    @memset(rgba, 0);
    var col: u32 = 0;
    var line: u32 = 0;
    for (text) |ch| {
        if (ch == '\n') {
            line += 1;
            col = 0;
            continue;
        }
        const rows = glyph(ch);
        const base_x = col * glyph_px * s;
        const base_y = line * glyph_px * s;
        col += 1;
        for (rows, 0..) |row, ry| {
            var bit: u3 = 0;
            while (true) : (bit += 1) {
                if ((row & (@as(u8, 0x80) >> bit)) != 0) {
                    // Fill the scale*scale block for this set bit.
                    var dy: u32 = 0;
                    while (dy < s) : (dy += 1) {
                        var dx: u32 = 0;
                        while (dx < s) : (dx += 1) {
                            const px = base_x + @as(u32, bit) * s + dx;
                            const py = base_y + @as(u32, @intCast(ry)) * s + dy;
                            const idx = (py * width + px) * 4;
                            rgba[idx + 0] = color[0];
                            rgba[idx + 1] = color[1];
                            rgba[idx + 2] = color[2];
                            rgba[idx + 3] = color[3];
                        }
                    }
                }
                if (bit == 7) break;
            }
        }
    }
    return .{ .rgba = rgba, .width = width, .height = height };
}

fn lerpU8(a: u8, b: u8, tc: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(std.math.clamp(af * (1.0 - tc) + bf * tc, 0.0, 255.0));
}

fn nearMask(mask: []const bool, width: u32, height: u32, x: u32, y: u32, radius: u32) bool {
    const x0 = x -| radius;
    const y0 = y -| radius;
    const x1 = @min(x + radius, width - 1);
    const y1 = @min(y + radius, height - 1);
    var yy = y0;
    while (yy <= y1) : (yy += 1) {
        var xx = x0;
        while (xx <= x1) : (xx += 1) {
            if (mask[yy * width + xx]) return true;
        }
    }
    return false;
}

/// Rasterizes `text` with a vertical `gradient` (null holds `color`), an
/// The vertical bow offset in pixels (up positive) for the glyph at column
/// `col` of `cols`, along a parabola that is zero at the ends and `bow_px` at
/// the middle, so a bent baseline arcs its text evenly. Zero for a lone glyph.
pub fn arcBow(col: usize, cols: usize, bow_px: i32) i32 {
    if (cols <= 1 or bow_px == 0) return 0;
    const frac = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(cols - 1));
    const parab = 1.0 - (2.0 * frac - 1.0) * (2.0 * frac - 1.0);
    return @intFromFloat(@round(@as(f32, @floatFromInt(bow_px)) * parab));
}

/// optional down-right `shadow`, and an optional `stroke` outline. The glyph
/// coverage is drawn into a mask, then composited main over stroke over shadow.
/// `bend` bows the baseline along an arc (positive up, negative down).
pub fn rasterizeRich(gpa: std.mem.Allocator, text: []const u8, scale: u32, color: [4]u8, gradient: ?[3]u8, shadow: bool, stroke: ?[3]u8, bend: f32) !Raster {
    const s = @max(scale, 1);
    const dim = measure(text, s);
    const margin = 2 * s;
    // A bent baseline bows each glyph up or down along a parabolic arc; reserve
    // vertical room for the bow on both sides so the arc fits the buffer.
    const cols = @max(dim.w / (glyph_px * s), 1);
    const bow_px: i32 = @intFromFloat(bend * @as(f32, @floatFromInt(dim.h)) * 0.5);
    const extra: u32 = @intCast(@abs(bow_px));
    const width = @max(dim.w + 2 * margin, 1);
    const height = @max(dim.h + 2 * margin + 2 * extra, 1);
    const mask = try gpa.alloc(bool, width * height);
    defer gpa.free(mask);
    @memset(mask, false);
    var col: u32 = 0;
    var line: u32 = 0;
    for (text) |ch| {
        if (ch == '\n') {
            line += 1;
            col = 0;
            continue;
        }
        const rows = glyph(ch);
        const base_x = margin + col * glyph_px * s;
        // The arc lifts (or drops) this glyph off the straight baseline by its
        // column's place along the bow; the reserved `extra` room keeps base_y
        // in range at the peak.
        const arc = arcBow(col, cols, bow_px);
        const base_y: u32 = @intCast(@max(@as(i32, @intCast(margin + extra + line * glyph_px * s)) - arc, 0));
        col += 1;
        for (rows, 0..) |row, ry| {
            var bit: u3 = 0;
            while (true) : (bit += 1) {
                if ((row & (@as(u8, 0x80) >> bit)) != 0) {
                    var dy: u32 = 0;
                    while (dy < s) : (dy += 1) {
                        var dx: u32 = 0;
                        while (dx < s) : (dx += 1) {
                            mask[(base_y + @as(u32, @intCast(ry)) * s + dy) * width + (base_x + @as(u32, bit) * s + dx)] = true;
                        }
                    }
                }
                if (bit == 7) break;
            }
        }
    }
    const rgba = try gpa.alloc(u8, width * height * 4);
    @memset(rgba, 0);
    const so = @max(s * 3 / 2, 1);
    const h_denom: f32 = @floatFromInt(@max(dim.h, 1));
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = (y * width + x) * 4;
            if (mask[y * width + x]) {
                const tc = std.math.clamp(@as(f32, @floatFromInt(y -| margin)) / h_denom, 0.0, 1.0);
                const g = gradient orelse .{ color[0], color[1], color[2] };
                rgba[idx + 0] = lerpU8(color[0], g[0], tc);
                rgba[idx + 1] = lerpU8(color[1], g[1], tc);
                rgba[idx + 2] = lerpU8(color[2], g[2], tc);
                rgba[idx + 3] = color[3];
            } else if (stroke != null and nearMask(mask, width, height, x, y, s)) {
                rgba[idx + 0] = stroke.?[0];
                rgba[idx + 1] = stroke.?[1];
                rgba[idx + 2] = stroke.?[2];
                rgba[idx + 3] = 255;
            } else if (shadow and x >= so and y >= so and mask[(y - so) * width + (x - so)]) {
                rgba[idx + 3] = 160;
            }
        }
    }
    return .{ .rgba = rgba, .width = width, .height = height };
}

pub const Mesh = struct { positions: [][3]f32, indices: []u32 };

fn emitBox(gpa: std.mem.Allocator, pos: *std.ArrayList([3]f32), idx: *std.ArrayList(u32), cx: f32, cy: f32, hw: f32, hh: f32, hd: f32) !void {
    const base: u32 = @intCast(pos.items.len);
    const verts = [8][3]f32{
        .{ cx - hw, cy - hh, -hd }, .{ cx + hw, cy - hh, -hd }, .{ cx + hw, cy + hh, -hd }, .{ cx - hw, cy + hh, -hd },
        .{ cx - hw, cy - hh, hd },  .{ cx + hw, cy - hh, hd },  .{ cx + hw, cy + hh, hd },  .{ cx - hw, cy + hh, hd },
    };
    for (verts) |v| try pos.append(gpa, v);
    const faces = [12][3]u32{
        .{ 4, 5, 6 }, .{ 4, 6, 7 }, .{ 0, 2, 1 }, .{ 0, 3, 2 }, .{ 0, 4, 7 }, .{ 0, 7, 3 },
        .{ 1, 2, 6 }, .{ 1, 6, 5 }, .{ 3, 7, 6 }, .{ 3, 6, 2 }, .{ 0, 1, 5 }, .{ 0, 5, 4 },
    };
    for (faces) |f| {
        try idx.append(gpa, base + f[0]);
        try idx.append(gpa, base + f[1]);
        try idx.append(gpa, base + f[2]);
    }
}

/// Extrudes `text` into a 3D block mesh: one box per set glyph bit, laid out in
/// a normalized [-1, 1] square (the caller's model matrix places and rotates
/// it) and given `depth` in z, so the letters read as solid extruded type.
pub fn extrudeMesh(gpa: std.mem.Allocator, text: []const u8, depth: f32) !Mesh {
    var lines: u32 = 1;
    var max_len: u32 = 0;
    var cur: u32 = 0;
    for (text) |ch| {
        if (ch == '\n') {
            lines += 1;
            if (cur > max_len) max_len = cur;
            cur = 0;
        } else cur += 1;
    }
    if (cur > max_len) max_len = cur;
    if (max_len == 0) max_len = 1;
    const grid_w: f32 = @floatFromInt(max_len * glyph_px);
    const grid_h: f32 = @floatFromInt(lines * glyph_px);
    var pos: std.ArrayList([3]f32) = .empty;
    errdefer pos.deinit(gpa);
    var idx: std.ArrayList(u32) = .empty;
    errdefer idx.deinit(gpa);
    const hw = 1.0 / grid_w;
    const hh = 1.0 / grid_h;
    var col: u32 = 0;
    var line: u32 = 0;
    for (text) |ch| {
        if (ch == '\n') {
            line += 1;
            col = 0;
            continue;
        }
        const rows = glyph(ch);
        for (rows, 0..) |row, ry| {
            var bit: u3 = 0;
            while (true) : (bit += 1) {
                if ((row & (@as(u8, 0x80) >> bit)) != 0) {
                    const bx: f32 = @floatFromInt(col * glyph_px + bit);
                    const by: f32 = @floatFromInt(line * glyph_px + @as(u32, @intCast(ry)));
                    try emitBox(gpa, &pos, &idx, (bx + 0.5) / grid_w * 2.0 - 1.0, 1.0 - (by + 0.5) / grid_h * 2.0, hw, hh, depth);
                }
                if (bit == 7) break;
            }
        }
        col += 1;
    }
    const positions = try pos.toOwnedSlice(gpa);
    errdefer gpa.free(positions);
    const indices = try idx.toOwnedSlice(gpa);
    return .{ .positions = positions, .indices = indices };
}

const t = std.testing;

test "measure sizes a monospace line" {
    const m = measure("ABC", 2);
    try t.expectEqual(@as(u32, 3 * 8 * 2), m.w);
    try t.expectEqual(@as(u32, 8 * 2), m.h);
}

test "wrap breaks at word boundaries and hard-breaks long words" {
    // Each word fits but three of them exceed eight columns, so it wraps twice.
    const a = try wrap(t.allocator, "hello world foo", 8);
    defer t.allocator.free(a);
    try t.expectEqualStrings("hello\nworld\nfoo", a);

    // A pair that fits exactly on one line stays on it.
    const b = try wrap(t.allocator, "hello world", 11);
    defer t.allocator.free(b);
    try t.expectEqualStrings("hello world", b);

    // A single word longer than a line hard-breaks into full-width chunks.
    const c = try wrap(t.allocator, "abcdefghij", 4);
    defer t.allocator.free(c);
    try t.expectEqualStrings("abcd\nefgh\nij", c);

    // An author's own newline is preserved, and each side wraps within it.
    const d = try wrap(t.allocator, "one two\nthree four", 7);
    defer t.allocator.free(d);
    try t.expectEqualStrings("one two\nthree\nfour", d);

    // No column budget returns the text untouched.
    const e = try wrap(t.allocator, "unchanged text here", 0);
    defer t.allocator.free(e);
    try t.expectEqualStrings("unchanged text here", e);
}

test "measure and rasterize handle multiple lines" {
    // Two lines, the longer one four glyphs wide, so width is 4 cells and
    // height two rows.
    const m = measure("HI\nFOUR", 1);
    try t.expectEqual(@as(u32, 4 * 8), m.w);
    try t.expectEqual(@as(u32, 2 * 8), m.h);

    const out = try rasterize(t.allocator, "A\nB", 1, .{ 0, 255, 0, 255 });
    defer t.allocator.free(out.rgba);
    try t.expectEqual(@as(u32, 8), out.width);
    try t.expectEqual(@as(u32, 16), out.height); // two lines tall
    // 'B' sits on the second line (row 8): its row 0 is 0x7C, column 1 set.
    try t.expectEqual(@as(u8, 255), out.rgba[((8 + 0) * 8 + 1) * 4 + 3]);
    try t.expectEqual(@as(u8, 255), out.rgba[((8 + 0) * 8 + 1) * 4 + 1]); // green
}

test "rasterize sets glyph pixels opaque and leaves gaps clear" {
    const out = try rasterize(t.allocator, "I", 1, .{ 255, 0, 0, 255 });
    defer t.allocator.free(out.rgba);
    try t.expectEqual(@as(u32, 8), out.width);
    try t.expectEqual(@as(u32, 8), out.height);
    // 'I' row 0 is 0x3C: columns 2..5 set, so a lit red pixel there and a
    // clear one in column 0.
    try t.expectEqual(@as(u8, 255), out.rgba[(0 * 8 + 2) * 4 + 3]); // set: opaque
    try t.expectEqual(@as(u8, 255), out.rgba[(0 * 8 + 2) * 4 + 0]); // set: red
    try t.expectEqual(@as(u8, 0), out.rgba[(0 * 8 + 0) * 4 + 3]); // gap: transparent
}

test "a blank line still rasterizes without crashing" {
    const out = try rasterize(t.allocator, "", 1, .{ 255, 255, 255, 255 });
    defer t.allocator.free(out.rgba);
    try t.expect(out.width >= 1 and out.height >= 1);
}

test "lowercase draws its own glyph, distinct from uppercase" {
    const lower = try rasterize(t.allocator, "a", 1, .{ 9, 9, 9, 255 });
    defer t.allocator.free(lower.rgba);
    const upper = try rasterize(t.allocator, "A", 1, .{ 9, 9, 9, 255 });
    defer t.allocator.free(upper.rgba);
    // A real lowercase 'a' is not the uppercase 'A' glyph.
    try t.expect(!std.mem.eql(u8, upper.rgba, lower.rgba));
    // ...but a known lowercase glyph is non-empty (it drew something).
    var any: u8 = 0;
    for (lower.rgba) |b| any |= b;
    try t.expect(any != 0);
}

test "extruded text builds a non-empty two-sided box mesh" {
    const mesh = try extrudeMesh(t.allocator, "GO", 0.06);
    defer t.allocator.free(mesh.positions);
    defer t.allocator.free(mesh.indices);
    try t.expect(mesh.positions.len > 0);
    try t.expect(mesh.indices.len % 3 == 0);
    var has_front = false;
    var has_back = false;
    for (mesh.positions) |v| {
        if (v[2] > 0.0) has_front = true;
        if (v[2] < 0.0) has_back = true;
    }
    // Genuinely extruded: vertices sit on both the front and back faces.
    try t.expect(has_front and has_back);
}

test "rich text adds stroke and shadow coverage beyond the plain glyphs" {
    const plain = try rasterize(t.allocator, "A", 4, .{ 255, 255, 255, 255 });
    defer t.allocator.free(plain.rgba);
    const rich = try rasterizeRich(t.allocator, "A", 4, .{ 255, 255, 255, 255 }, .{ 255, 0, 0 }, true, .{ 0, 0, 0 }, 0);
    defer t.allocator.free(rich.rgba);
    var plain_set: u32 = 0;
    var pi: usize = 3;
    while (pi < plain.rgba.len) : (pi += 4) {
        if (plain.rgba[pi] > 0) plain_set += 1;
    }
    var rich_set: u32 = 0;
    var ri: usize = 3;
    while (ri < rich.rgba.len) : (ri += 4) {
        if (rich.rgba[ri] > 0) rich_set += 1;
    }
    // The stroke outline and drop shadow add covered pixels around the glyph.
    try t.expect(rich_set > plain_set);
    // The gradient darkens the base of the glyph, so the fill is not flat.
    const rich_flat = try rasterizeRich(t.allocator, "A", 4, .{ 255, 255, 255, 255 }, null, false, null, 0);
    defer t.allocator.free(rich_flat.rgba);
    try t.expect(!std.mem.eql(u8, rich.rgba, rich_flat.rgba));
}

test "a bent baseline arcs the middle glyphs off the straight line" {
    // The parabola is zero at the ends and peaks in the middle, up for a
    // positive bow and down for a negative one, and flat for a lone glyph.
    try t.expectEqual(@as(i32, 0), arcBow(0, 5, 20));
    try t.expectEqual(@as(i32, 0), arcBow(4, 5, 20));
    try t.expectEqual(@as(i32, 20), arcBow(2, 5, 20));
    try t.expectEqual(@as(i32, -20), arcBow(2, 5, -20));
    try t.expectEqual(@as(i32, 0), arcBow(0, 1, 20));

    // A bent render is taller than the straight one (it reserves bow room) and
    // differs from it, while a zero bend is byte-identical to the straight rich.
    const straight = try rasterizeRich(t.allocator, "CURVE", 4, .{ 255, 255, 255, 255 }, null, false, null, 0);
    defer t.allocator.free(straight.rgba);
    const bent = try rasterizeRich(t.allocator, "CURVE", 4, .{ 255, 255, 255, 255 }, null, false, null, 0.8);
    defer t.allocator.free(bent.rgba);
    try t.expect(bent.height > straight.height);
    try t.expect(!(bent.width == straight.width and std.mem.eql(u8, bent.rgba, straight.rgba)));
}
