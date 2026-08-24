//! Generates lenses/reference/gif-sprite/assets/clip.gif: a small looping
//! animation - a colored bar sweeping across the frame over six frames - so a
//! render proof can play it as a video texture and see the frame change. Run
//! `zig run tools/gen_gif_asset.zig` to regenerate; output committed.

const std = @import("std");

const width: u32 = 32;
const height: u32 = 32;
const frame_count: u32 = 6;

// A four-color palette: the codes an image row references.
const palette = [_][3]u8{
    .{ 20, 20, 30 }, // 0 background
    .{ 240, 90, 70 }, // 1 bar
    .{ 90, 200, 120 }, // 2 accent
    .{ 60, 120, 240 }, // 3 accent
};

const BitWriter = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    acc: u32 = 0,
    nbits: u5 = 0,

    fn put(self: *BitWriter, code: u16, wid: u5) !void {
        self.acc |= @as(u32, code) << self.nbits;
        self.nbits += wid;
        while (self.nbits >= 8) {
            try self.out.append(self.gpa, @intCast(self.acc & 0xFF));
            self.acc >>= 8;
            self.nbits -= 8;
        }
    }

    fn flush(self: *BitWriter) !void {
        if (self.nbits > 0) {
            try self.out.append(self.gpa, @intCast(self.acc & 0xFF));
            self.acc = 0;
            self.nbits = 0;
        }
    }
};

/// Encodes indices as a GIF LZW stream that only ever emits literal codes,
/// growing the code width in lockstep with the decoder's dictionary. Simple
/// and valid; a real encoder would reuse dictionary codes to compress.
fn encodeLzw(gpa: std.mem.Allocator, indices: []const u8, min_code_size: u5) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var bw = BitWriter{ .out = &out, .gpa = gpa };

    const clear_code: u16 = @intCast(@as(u32, 1) << min_code_size);
    const end_code: u16 = clear_code + 1;
    var code_size: u5 = min_code_size + 1;
    var next_code: u16 = end_code + 1;
    var first_after_clear = true;

    try bw.put(clear_code, code_size);
    for (indices) |idx| {
        try bw.put(idx, code_size);
        if (first_after_clear) {
            first_after_clear = false;
        } else {
            next_code += 1;
            if (@as(u32, next_code) == (@as(u32, 1) << code_size) and code_size < 12) code_size += 1;
        }
        if (next_code >= 4094) {
            try bw.put(clear_code, code_size);
            code_size = min_code_size + 1;
            next_code = end_code + 1;
            first_after_clear = true;
        }
    }
    try bw.put(end_code, code_size);
    try bw.flush();
    return out.toOwnedSlice(gpa);
}

fn appendU16(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    var gifb: std.ArrayList(u8) = .empty;

    try gifb.appendSlice(gpa, "GIF89a");
    try appendU16(&gifb, gpa, @intCast(width));
    try appendU16(&gifb, gpa, @intCast(height));
    // Global color table present, 4 entries (2^(1+1)), so table size code 1.
    try gifb.append(gpa, 0x80 | 0x01);
    try gifb.append(gpa, 0); // background index
    try gifb.append(gpa, 0); // aspect ratio
    for (palette) |rgb| try gifb.appendSlice(gpa, &rgb);

    // Loop forever (NETSCAPE application extension).
    try gifb.appendSlice(gpa, &[_]u8{ 0x21, 0xFF, 0x0B });
    try gifb.appendSlice(gpa, "NETSCAPE2.0");
    try gifb.appendSlice(gpa, &[_]u8{ 0x03, 0x01, 0x00, 0x00, 0x00 });

    var f: u32 = 0;
    while (f < frame_count) : (f += 1) {
        // Graphic control extension: 8 centiseconds per frame.
        try gifb.appendSlice(gpa, &[_]u8{ 0x21, 0xF9, 0x04, 0x00, 8, 0x00, 0x00, 0x00 });

        // Image descriptor covering the whole canvas.
        try gifb.append(gpa, 0x2C);
        try appendU16(&gifb, gpa, 0);
        try appendU16(&gifb, gpa, 0);
        try appendU16(&gifb, gpa, @intCast(width));
        try appendU16(&gifb, gpa, @intCast(height));
        try gifb.append(gpa, 0x00); // no local table, no interlace

        // A vertical bar sweeping left to right, with an accent stripe.
        const bar_x = (f * width) / frame_count;
        const indices = try gpa.alloc(u8, width * height);
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                var idx: u8 = 0;
                if (x >= bar_x and x < bar_x + 5) idx = 1;
                if (y == height / 2) idx = 2;
                if (x == bar_x) idx = 3;
                indices[y * width + x] = idx;
            }
        }

        const min_code_size: u5 = 2;
        try gifb.append(gpa, min_code_size);
        const lzw = try encodeLzw(gpa, indices, min_code_size);
        // Split the LZW stream into sub-blocks of at most 255 bytes.
        var off: usize = 0;
        while (off < lzw.len) {
            const n: usize = if (lzw.len - off > 255) 255 else lzw.len - off;
            try gifb.append(gpa, @intCast(n));
            try gifb.appendSlice(gpa, lzw[off .. off + n]);
            off += n;
        }
        try gifb.append(gpa, 0x00); // sub-block terminator
    }
    try gifb.append(gpa, 0x3B); // trailer

    try std.Io.Dir.cwd().createDirPath(init.io, "lenses/reference/gif-sprite/assets");
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "lenses/reference/gif-sprite/assets/clip.gif",
        .data = gifb.items,
    });

    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    try stdout.interface.print("wrote lenses/reference/gif-sprite/assets/clip.gif ({d} bytes)\n", .{gifb.items.len});
    try stdout.interface.flush();
    return 0;
}
