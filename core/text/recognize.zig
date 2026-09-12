//! Turning a recogniser's output into text: the CTC decode, the character
//! geometry that comes out of it, and the line and paragraph grouping that makes
//! a paragraph come back as a paragraph rather than fifteen fragments.

const std = @import("std");
const region = @import("region.zig");

const Quad = region.Quad;
const Point = region.Point;
const Region = region.Region;

/// One decoded character: which code point, how sure, and where in the region
/// it sits. The extent is along the rectified crop, so an overlay can underline
/// one word rather than the whole line.
pub const Char = struct {
    codepoint: u21,
    confidence: f32,
    /// Start and end along the crop's reading axis, normalized to it.
    start: f32,
    end: f32,
};

/// What a region says. The text is a slice of the caller's buffer, so recognition
/// allocates nothing and the caller decides the lifetime.
pub const Reading = struct {
    text: []const u8,
    chars: []const Char,
    confidence: f32,
    direction: region.Direction = .left_to_right,
    script: region.Script = .unknown,
};

/// The blank class a CTC model reserves. Every real recogniser puts it at zero.
pub const blank_class: usize = 0;

pub const Dictionary = struct {
    /// One entry per class after the blank, newline separated, exactly as the
    /// model's own dictionary file ships.
    entries: []const []const u8,

    /// Parses a dictionary file into entries the caller owns. The file is one
    /// token per line and the blank is not in it, which is why class one is
    /// entry zero.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        var rows = std.mem.splitScalar(u8, text, '\n');
        while (rows.next()) |line| {
            const token = std.mem.trimEnd(u8, line, "\r");
            if (token.len == 0) continue;
            try list.append(gpa, token);
        }
        return list.toOwnedSlice(gpa);
    }

    pub fn at(d: Dictionary, class: usize) []const u8 {
        if (class == blank_class or class - 1 >= d.entries.len) return &.{};
        return d.entries[class - 1];
    }
};

/// Greedy CTC over a [steps][classes] score grid: take the best class per step,
/// drop repeats, drop blanks. Greedy rather than beam because a beam buys
/// accuracy only with a language model, and an engine that guesses at language
/// is worse than one that reports what it saw.
pub fn decode(
    scores: []const f32,
    steps: usize,
    classes: usize,
    dict: Dictionary,
    text_out: []u8,
    chars_out: []Char,
) Reading {
    if (steps == 0 or classes == 0 or scores.len < steps * classes) {
        return .{ .text = text_out[0..0], .chars = chars_out[0..0], .confidence = 0 };
    }

    var written: usize = 0;
    var char_count: usize = 0;
    var previous: usize = blank_class;
    var total_confidence: f32 = 0;
    var run_start: usize = 0;

    for (0..steps) |t| {
        const row = scores[t * classes ..][0..classes];
        var best: usize = 0;
        var best_score: f32 = row[0];
        for (row, 0..) |v, c| {
            if (v > best_score) {
                best_score = v;
                best = c;
            }
        }
        if (best != previous) run_start = t;
        defer previous = best;
        if (best == blank_class or best == previous) continue;

        const token = dict.at(best);
        if (token.len == 0 or written + token.len > text_out.len or char_count >= chars_out.len) continue;
        @memcpy(text_out[written..][0..token.len], token);
        written += token.len;

        // The run this class holds is its extent along the crop, which is what
        // lets a caller box one character rather than the whole reading.
        var run_end = t + 1;
        while (run_end < steps and argmaxAt(scores, run_end, classes) == best) run_end += 1;
        chars_out[char_count] = .{
            .codepoint = firstCodepoint(token),
            .confidence = best_score,
            .start = @as(f32, @floatFromInt(run_start)) / @as(f32, @floatFromInt(steps)),
            .end = @as(f32, @floatFromInt(run_end)) / @as(f32, @floatFromInt(steps)),
        };
        char_count += 1;
        total_confidence += best_score;
    }

    return .{
        .text = text_out[0..written],
        .chars = chars_out[0..char_count],
        .confidence = if (char_count == 0) 0 else total_confidence / @as(f32, @floatFromInt(char_count)),
        .script = scriptOf(text_out[0..written]),
    };
}

fn argmaxAt(scores: []const f32, step: usize, classes: usize) usize {
    const row = scores[step * classes ..][0..classes];
    var best: usize = 0;
    var best_score: f32 = row[0];
    for (row, 0..) |v, c| {
        if (v > best_score) {
            best_score = v;
            best = c;
        }
    }
    return best;
}

fn firstCodepoint(token: []const u8) u21 {
    const len = std.unicode.utf8ByteSequenceLength(token[0]) catch return token[0];
    if (len > token.len) return token[0];
    return std.unicode.utf8Decode(token[0..len]) catch token[0];
}

/// The script the decoded text belongs to, from the code point ranges alone. It
/// is a hint for choosing a recogniser next frame, never a claim about language.
pub fn scriptOf(text: []const u8) region.Script {
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x4E00 and cp <= 0x9FFF) return .han;
        if (cp >= 0x3040 and cp <= 0x30FF) return .kana;
        if (cp >= 0xAC00 and cp <= 0xD7AF) return .hangul;
        if (cp >= 0x0400 and cp <= 0x04FF) return .cyrillic;
        if (cp >= 0x0600 and cp <= 0x06FF) return .arabic;
        if (cp >= 0x0900 and cp <= 0x097F) return .devanagari;
        if (cp >= 0x0E00 and cp <= 0x0E7F) return .thai;
        if (cp >= 0x0590 and cp <= 0x05FF) return .hebrew;
    }
    for (text) |b| {
        if (std.ascii.isAlphabetic(b)) return .latin;
    }
    return .unknown;
}

/// A run of regions that read as one line, then one paragraph. The indices point
/// back into the caller's region slice, so grouping copies nothing.
pub const Group = struct {
    first: u32,
    count: u32,
};

pub const GroupOptions = struct {
    /// How much two regions must overlap vertically to be the same line, as a
    /// fraction of the shorter one's height.
    line_overlap: f32 = 0.5,
    /// The gap that ends a paragraph, as a multiple of the line height.
    paragraph_gap: f32 = 1.8,
};

/// Sorts regions into reading order and reports where each line starts. The
/// order is written into order_out, so the caller's regions are not moved.
pub fn lines(regions: []const Region, opts: GroupOptions, order_out: []u32, lines_out: []Group) usize {
    const n = @min(regions.len, order_out.len);
    if (n == 0) return 0;
    for (0..n) |i| order_out[i] = @intCast(i);

    const Ctx = struct {
        regions: []const Region,
        fn lessThan(c: @This(), a: u32, b: u32) bool {
            const ca = c.regions[a].quad.centre();
            const cb = c.regions[b].quad.centre();
            const ha = c.regions[a].quad.extent().h;
            const hb = c.regions[b].quad.extent().h;
            // Same line when the centres are within half the shorter height:
            // read left to right; otherwise top to bottom.
            if (@abs(ca.y - cb.y) < @min(ha, hb) * 0.5) return ca.x < cb.x;
            return ca.y < cb.y;
        }
    };
    std.mem.sortUnstable(u32, order_out[0..n], Ctx{ .regions = regions }, Ctx.lessThan);

    var count: usize = 0;
    var start: usize = 0;
    for (1..n + 1) |i| {
        const ends = i == n or !sameLine(regions[order_out[i - 1]], regions[order_out[i]], opts);
        if (!ends) continue;
        if (count >= lines_out.len) break;
        lines_out[count] = .{ .first = @intCast(start), .count = @intCast(i - start) };
        count += 1;
        start = i;
    }
    return count;
}

fn sameLine(a: Region, b: Region, opts: GroupOptions) bool {
    const ca = a.quad.centre();
    const cb = b.quad.centre();
    const ha = a.quad.extent().h;
    const hb = b.quad.extent().h;
    const shorter = @min(ha, hb);
    if (shorter <= 0) return false;
    const overlap = shorter - @abs(ca.y - cb.y);
    return overlap / shorter >= opts.line_overlap;
}

/// Groups lines into paragraphs on the vertical gap between them, so a caller
/// gets a block of prose as one thing.
pub fn paragraphs(regions: []const Region, order: []const u32, line_groups: []const Group, opts: GroupOptions, out: []Group) usize {
    if (line_groups.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    for (1..line_groups.len + 1) |i| {
        var ends = i == line_groups.len;
        if (!ends) {
            const previous = lineCentre(regions, order, line_groups[i - 1]);
            const here = lineCentre(regions, order, line_groups[i]);
            const height = lineHeight(regions, order, line_groups[i - 1]);
            ends = height > 0 and (here.y - previous.y) > height * opts.paragraph_gap;
        }
        if (!ends) continue;
        if (count >= out.len) break;
        out[count] = .{ .first = @intCast(start), .count = @intCast(i - start) };
        count += 1;
        start = i;
    }
    return count;
}

fn lineCentre(regions: []const Region, order: []const u32, group: Group) Point {
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (0..group.count) |i| {
        const c = regions[order[group.first + i]].quad.centre();
        cx += c.x;
        cy += c.y;
    }
    const n: f32 = @floatFromInt(@max(group.count, 1));
    return .{ .x = cx / n, .y = cy / n };
}

fn lineHeight(regions: []const Region, order: []const u32, group: Group) f32 {
    var acc: f32 = 0;
    for (0..group.count) |i| acc += regions[order[group.first + i]].quad.extent().h;
    return acc / @as(f32, @floatFromInt(@max(group.count, 1)));
}

const testing = std.testing;

test "ctc drops blanks and repeats and keeps the character extents" {
    const entries = [_][]const u8{ "a", "b", "c" };
    const dict: Dictionary = .{ .entries = &entries };
    // Six steps over four classes: blank, a, b, c. The reading is "ab": a runs
    // two steps, a blank separates, b runs two.
    const scores = [_]f32{
        0.1, 0.9, 0.0, 0.0,
        0.1, 0.8, 0.1, 0.0,
        0.9, 0.1, 0.0, 0.0,
        0.1, 0.0, 0.9, 0.0,
        0.2, 0.0, 0.7, 0.1,
        0.9, 0.0, 0.1, 0.0,
    };
    var text_buf: [16]u8 = undefined;
    var chars: [8]Char = undefined;
    const reading = decode(&scores, 6, 4, dict, &text_buf, &chars);
    try testing.expectEqualStrings("ab", reading.text);
    try testing.expectEqual(@as(usize, 2), reading.chars.len);
    try testing.expectEqual(@as(u21, 'a'), reading.chars[0].codepoint);
    try testing.expectApproxEqAbs(@as(f32, 0), reading.chars[0].start, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 6.0), reading.chars[0].end, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3.0 / 6.0), reading.chars[1].start, 1e-6);
    try testing.expectEqual(region.Script.latin, reading.script);
}

test "a repeated character survives when a blank separates it" {
    const entries = [_][]const u8{"l"};
    const dict: Dictionary = .{ .entries = &entries };
    // l, l with no blank is one l; l, blank, l is two.
    const one = [_]f32{ 0.1, 0.9, 0.1, 0.9 };
    const two = [_]f32{ 0.1, 0.9, 0.9, 0.1, 0.1, 0.9 };
    var text_buf: [8]u8 = undefined;
    var chars: [8]Char = undefined;
    try testing.expectEqualStrings("l", decode(&one, 2, 2, dict, &text_buf, &chars).text);
    var text_buf2: [8]u8 = undefined;
    try testing.expectEqualStrings("ll", decode(&two, 3, 2, dict, &text_buf2, &chars).text);
}

test "regions group into lines and paragraphs in reading order" {
    const regions = [_]Region{
        // Second line, right word first in the input, to prove it is sorted.
        .{ .quad = boxAt(0.5, 0.30), .confidence = 1 },
        .{ .quad = boxAt(0.1, 0.30), .confidence = 1 },
        .{ .quad = boxAt(0.1, 0.10), .confidence = 1 },
        .{ .quad = boxAt(0.5, 0.10), .confidence = 1 },
        // A third line far below: a new paragraph.
        .{ .quad = boxAt(0.1, 0.80), .confidence = 1 },
    };
    var order: [8]u32 = undefined;
    var line_groups: [8]Group = undefined;
    const line_count = lines(&regions, .{}, &order, &line_groups);
    try testing.expectEqual(@as(usize, 3), line_count);
    // The first line reads left to right whatever order it arrived in.
    try testing.expectEqual(@as(u32, 2), order[0]);
    try testing.expectEqual(@as(u32, 3), order[1]);

    var paragraph_groups: [8]Group = undefined;
    const paragraph_count = paragraphs(&regions, &order, line_groups[0..line_count], .{}, &paragraph_groups);
    try testing.expectEqual(@as(usize, 2), paragraph_count);
    try testing.expectEqual(@as(u32, 2), paragraph_groups[0].count);
    try testing.expectEqual(@as(u32, 1), paragraph_groups[1].count);
}

fn boxAt(x: f32, y: f32) Quad {
    return .{ .corners = .{
        .{ .x = x, .y = y },
        .{ .x = x + 0.3, .y = y },
        .{ .x = x + 0.3, .y = y + 0.04 },
        .{ .x = x, .y = y + 0.04 },
    } };
}
