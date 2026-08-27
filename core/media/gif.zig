//! GIF decoder for animated lens textures: GIF87a and GIF89a to composited
//! RGBA frames with per-frame timing. Resolves global and local color tables,
//! interlace, transparency, and all four disposal methods, decoding each
//! frame's variable-width LZW; a structurally invalid file fails with a typed error.

const std = @import("std");

pub const Decoded = struct {
    width: u32,
    height: u32,
    /// One fully composited RGBA buffer per frame, each width*height*4 bytes,
    /// in play order.
    frames: [][]u8,
    /// Each frame's on-screen time in centiseconds (1/100 s), play order.
    delays_cs: []u16,

    pub fn deinit(self: Decoded, gpa: std.mem.Allocator) void {
        for (self.frames) |frame| gpa.free(frame);
        gpa.free(self.frames);
        gpa.free(self.delays_cs);
    }
};

pub const Error = error{ Truncated, BadHeader, BadImage, TooManyCodes };

const Disposal = enum(u8) { none = 0, keep = 1, background = 2, previous = 3, _ };

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) !u8 {
        if (self.pos >= self.bytes.len) return Error.Truncated;
        const v = self.bytes[self.pos];
        self.pos += 1;
        return v;
    }

    fn word(self: *Reader) !u16 {
        if (self.pos + 2 > self.bytes.len) return Error.Truncated;
        const v = std.mem.readInt(u16, self.bytes[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    fn take(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return Error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    /// Skips a chain of GIF sub-blocks (each a length byte then that many
    /// bytes) up to and including the zero-length terminator.
    fn skipSubBlocks(self: *Reader) !void {
        while (true) {
            const len = try self.byte();
            if (len == 0) return;
            _ = try self.take(len);
        }
    }

    /// Concatenates a chain of sub-blocks into one buffer - a frame's LZW image
    /// data is split across them.
    fn readSubBlocks(self: *Reader, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        while (true) {
            const len = try self.byte();
            if (len == 0) return out.toOwnedSlice(gpa);
            try out.appendSlice(gpa, try self.take(len));
        }
    }
};

/// Decodes one frame's LZW image data into palette indices, one per pixel of
/// the frame's sub-rectangle. The GIF variable-width scheme: a clear code
/// resets the string table, codes grow one bit at a time up to twelve, and a
/// code one past the table is the previous string plus its own first byte.
fn lzwDecode(gpa: std.mem.Allocator, data: []const u8, min_code_size: u5, pixel_count: usize) ![]u8 {
    if (min_code_size < 2 or min_code_size > 11) return Error.BadImage;
    const clear_code: u16 = @intCast(@as(u32, 1) << min_code_size);
    const end_code: u16 = clear_code + 1;
    const max_codes: usize = 4096;

    const prefix = try gpa.alloc(u16, max_codes);
    defer gpa.free(prefix);
    const suffix = try gpa.alloc(u8, max_codes);
    defer gpa.free(suffix);
    const first = try gpa.alloc(u8, max_codes);
    defer gpa.free(first);
    const stack = try gpa.alloc(u8, max_codes);
    defer gpa.free(stack);

    const out = try gpa.alloc(u8, pixel_count);
    errdefer gpa.free(out);
    var out_len: usize = 0;

    var i: u16 = 0;
    while (i < clear_code) : (i += 1) {
        suffix[i] = @intCast(i);
        first[i] = @intCast(i);
    }

    var code_size: u5 = min_code_size + 1;
    var next_code: u16 = end_code + 1;
    var bit_buf: u32 = 0;
    var bit_count: u5 = 0;
    var data_pos: usize = 0;
    var prev_code: u16 = 0xFFFF;

    while (out_len < pixel_count) {
        while (bit_count < code_size) {
            if (data_pos >= data.len) return shrink(gpa, out, out_len);
            bit_buf |= @as(u32, data[data_pos]) << bit_count;
            data_pos += 1;
            bit_count += 8;
        }
        const code: u16 = @intCast(bit_buf & ((@as(u32, 1) << code_size) - 1));
        bit_buf >>= code_size;
        bit_count -= code_size;

        if (code == clear_code) {
            code_size = min_code_size + 1;
            next_code = end_code + 1;
            prev_code = 0xFFFF;
            continue;
        }
        if (code == end_code) return shrink(gpa, out, out_len);

        var sp: usize = 0;
        var cur: u16 = code;
        if (code >= next_code) {
            if (prev_code == 0xFFFF) return Error.BadImage;
            stack[sp] = first[prev_code];
            sp += 1;
            cur = prev_code;
        }
        while (cur >= clear_code) {
            if (cur >= max_codes or sp >= max_codes) return Error.TooManyCodes;
            stack[sp] = suffix[cur];
            sp += 1;
            cur = prefix[cur];
        }
        const first_byte: u8 = @intCast(cur);
        stack[sp] = first_byte;
        sp += 1;
        while (sp > 0 and out_len < pixel_count) {
            sp -= 1;
            out[out_len] = stack[sp];
            out_len += 1;
        }

        if (prev_code != 0xFFFF and next_code < max_codes) {
            prefix[next_code] = prev_code;
            suffix[next_code] = first_byte;
            first[next_code] = first[prev_code];
            next_code += 1;
            if (@as(u32, next_code) == (@as(u32, 1) << code_size) and code_size < 12) code_size += 1;
        }
        prev_code = code;
    }
    return out;
}

fn shrink(gpa: std.mem.Allocator, buf: []u8, used: usize) ![]u8 {
    if (used == buf.len) return buf;
    const out = try gpa.alloc(u8, used);
    @memcpy(out, buf[0..used]);
    gpa.free(buf);
    return out;
}

/// Paints one decoded frame's palette indices into the running canvas at its
/// sub-rectangle, honoring the interlace row order and leaving transparent
/// pixels as the composite beneath them shows through.
fn composite(canvas: []u8, cw: u32, fx: u32, fy: u32, fw: u32, fh: u32, interlaced: bool, indices: []const u8, table: []const u8, transparent: i32) void {
    var src: usize = 0;
    var row: usize = 0;
    while (row < fh) : (row += 1) {
        const dst_row = if (interlaced) interlaceRow(row, fh) else row;
        var col: usize = 0;
        while (col < fw) : (col += 1) {
            if (src >= indices.len) return;
            const idx = indices[src];
            src += 1;
            if (transparent >= 0 and @as(i32, idx) == transparent) continue;
            const pal = @as(usize, idx) * 3;
            if (pal + 2 >= table.len) continue;
            const px = ((fy + dst_row) * cw + (fx + col)) * 4;
            canvas[px + 0] = table[pal + 0];
            canvas[px + 1] = table[pal + 1];
            canvas[px + 2] = table[pal + 2];
            canvas[px + 3] = 255;
        }
    }
}

/// Clears a sub-rectangle of the canvas to transparent - the effect of the
/// restore-to-background disposal on the next frame's composite.
fn clearRect(canvas: []u8, cw: u32, fx: u32, fy: u32, fw: u32, fh: u32) void {
    var yy: usize = 0;
    while (yy < fh) : (yy += 1) {
        var xx: usize = 0;
        while (xx < fw) : (xx += 1) {
            const px = ((fy + yy) * cw + (fx + xx)) * 4;
            canvas[px + 0] = 0;
            canvas[px + 1] = 0;
            canvas[px + 2] = 0;
            canvas[px + 3] = 0;
        }
    }
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    var r = Reader{ .bytes = bytes };
    const header = try r.take(6);
    if (!std.mem.eql(u8, header[0..3], "GIF")) return Error.BadHeader;

    const width = try r.word();
    const height = try r.word();
    const fields = try r.byte();
    _ = try r.byte(); // background color index
    _ = try r.byte(); // pixel aspect ratio
    if (width == 0 or height == 0) return Error.BadHeader;

    var global_table: []const u8 = &.{};
    if (fields & 0x80 != 0) {
        const size: u5 = @intCast(fields & 0x07);
        global_table = try r.take((@as(usize, 1) << (size + 1)) * 3);
    }

    const pixels: usize = @as(usize, width) * height;
    const canvas = try gpa.alloc(u8, pixels * 4);
    defer gpa.free(canvas);
    @memset(canvas, 0);
    const previous = try gpa.alloc(u8, pixels * 4);
    defer gpa.free(previous);

    var frames: std.ArrayList([]u8) = .empty;
    errdefer {
        for (frames.items) |f| gpa.free(f);
        frames.deinit(gpa);
    }
    var delays: std.ArrayList(u16) = .empty;
    errdefer delays.deinit(gpa);

    var pending_delay: u16 = 0;
    var transparent: i32 = -1;
    var disposal: Disposal = .none;

    while (true) {
        const block = try r.byte();
        if (block == 0x3B) break; // trailer
        if (block == 0x21) { // extension
            const label = try r.byte();
            if (label == 0xF9) { // graphic control
                _ = try r.byte(); // block size, always 4
                const gce = try r.byte();
                pending_delay = try r.word();
                const t_index = try r.byte();
                _ = try r.byte(); // terminator
                disposal = @enumFromInt((gce >> 2) & 0x07);
                transparent = if (gce & 0x01 != 0) @as(i32, t_index) else -1;
            } else {
                try r.skipSubBlocks(); // application/comment/plain-text
            }
            continue;
        }
        if (block != 0x2C) return Error.BadImage; // image descriptor expected

        const fx = try r.word();
        const fy = try r.word();
        const fw = try r.word();
        const fh = try r.word();
        const img_fields = try r.byte();
        if (@as(u32, fx) + fw > width or @as(u32, fy) + fh > height) return Error.BadImage;

        var local_table: []const u8 = &.{};
        if (img_fields & 0x80 != 0) {
            const size: u5 = @intCast(img_fields & 0x07);
            local_table = try r.take((@as(usize, 1) << (size + 1)) * 3);
        }
        const table = if (local_table.len != 0) local_table else global_table;
        if (table.len == 0) return Error.BadImage;
        const interlaced = img_fields & 0x40 != 0;

        // Restore-to-previous snapshots the canvas before this frame draws, so
        // the disposal after it can roll the change back.
        if (disposal == .previous) @memcpy(previous, canvas);

        const min_code_size: u5 = @intCast(try r.byte());
        const lzw = try r.readSubBlocks(gpa);
        defer gpa.free(lzw);
        const indices = try lzwDecode(gpa, lzw, min_code_size, @as(usize, fw) * fh);
        defer gpa.free(indices);

        composite(canvas, width, fx, fy, fw, fh, interlaced, indices, table, transparent);

        const frame = try gpa.alloc(u8, pixels * 4);
        var frame_owned = false;
        errdefer if (!frame_owned) gpa.free(frame);
        @memcpy(frame, canvas);
        try frames.append(gpa, frame);
        frame_owned = true;
        try delays.append(gpa, pending_delay);

        switch (disposal) {
            .background => clearRect(canvas, width, fx, fy, fw, fh),
            .previous => @memcpy(canvas, previous),
            else => {}, // none / keep leave the canvas for the next frame
        }
        pending_delay = 0;
        transparent = -1;
        disposal = .none;
    }

    if (frames.items.len == 0) return Error.BadImage;
    const owned_frames = try frames.toOwnedSlice(gpa);
    errdefer {
        for (owned_frames) |f| gpa.free(f);
        gpa.free(owned_frames);
    }
    const owned_delays = try delays.toOwnedSlice(gpa);
    return .{
        .width = width,
        .height = height,
        .frames = owned_frames,
        .delays_cs = owned_delays,
    };
}

/// The output row a GIF's four-pass interlace maps a decoded row to.
fn interlaceRow(row: usize, height: usize) usize {
    const p1 = (height + 7) / 8;
    const p2 = (height + 3) / 8;
    const p3 = (height + 1) / 4;
    if (row < p1) return row * 8;
    if (row < p1 + p2) return (row - p1) * 8 + 4;
    if (row < p1 + p2 + p3) return (row - p1 - p2) * 4 + 2;
    return (row - p1 - p2 - p3) * 2 + 1;
}

test "decodes a two-frame gif with a global palette" {
    const gpa = std.testing.allocator;
    // A 2x1 GIF89a: frame 0 red, frame 1 green, hand-assembled.
    const bytes = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2,    0,    1,    0, // 2x1 logical screen
        0x80, 0,    0, // global table flag, size code 0 -> 2 entries
        255,  0,    0, // color 0 red
        0,    255,  0, // color 1 green
        0x21, 0xF9, 4, 0, 10, 0, 0, 0, // GCE, 10cs delay
        0x2C, 0, 0, 0, 0, 2, 0, 1, 0, 0, // image descriptor 2x1
        2, 2, 0x04, 0x0A, 0x00, // lzw: clear, 0, 0, end
        0x21, 0xF9, 4, 0, 10, 0, 0, 0,
        0x2C, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x4C, 0x0A, 0x00, // lzw: clear, 1, 1, end
        0x3B,
    };
    const decoded = try decode(gpa, &bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(usize, 2), decoded.frames.len);
    try std.testing.expectEqual(@as(u16, 10), decoded.delays_cs[0]);
    try std.testing.expectEqual(@as(u8, 255), decoded.frames[0][0]); // frame 0 red
    try std.testing.expectEqual(@as(u8, 0), decoded.frames[0][1]);
    try std.testing.expectEqual(@as(u8, 255), decoded.frames[1][1]); // frame 1 green
}

test "rejects a non-gif header" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(Error.BadHeader, decode(gpa, "not a gif at all!!"));
}

test "rejects a frame outside the logical screen" {
    const gpa = std.testing.allocator;
    const bytes = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 2, 0, 0x80, 0, 0,
        0, 0, 0, 255, 255, 255,
        0x2C, 0, 0, 0, 0, 4, 0, 4, 0, 0, // 4x4 frame in a 2x2 screen
        2, 2, 0x04, 0x0A, 0x00,
        0x3B,
    };
    try std.testing.expectError(Error.BadImage, decode(gpa, &bytes));
}
