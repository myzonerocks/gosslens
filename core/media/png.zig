//! Deterministic PNG encoding for capture output. Fixed filter choice
//! and fixed deflate options mean the same pixels always produce the
//! same bytes, so conformance can hash an encoded photo directly.

const std = @import("std");

const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

fn writeChunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: *const [4]u8, body: []const u8) !void {
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(body.len), .big);
    try out.appendSlice(gpa, &length_bytes);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, body);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(body);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try out.appendSlice(gpa, &crc_bytes);
}

/// A decoded 8-bit RGBA picture. `pixels` is owned by the caller.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};

/// Reads an 8-bit RGB or RGBA PNG back to tightly packed RGBA8. Enough to check what this module
/// wrote, which is what conformance needs when a comparison has to be per pixel rather than per
/// byte. Interlaced, paletted and 16-bit files are refused rather than half-read.
pub fn decodeRgba(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < png_signature.len or !std.mem.eql(u8, bytes[0..png_signature.len], &png_signature)) return error.NotPng;
    var width: u32 = 0;
    var height: u32 = 0;
    var channels: usize = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var at: usize = png_signature.len;
    while (at + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4 ..][0..4];
        const body_at = at + 8;
        if (body_at + len + 4 > bytes.len) return error.Truncated;
        const body = bytes[body_at..][0..len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Truncated;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            if (body[8] != 8) return error.Unsupported;
            channels = switch (body[9]) {
                2 => 3,
                6 => 4,
                else => return error.Unsupported,
            };
            if (body[12] != 0) return error.Unsupported;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
        at = body_at + len + 4;
    }
    if (width == 0 or height == 0 or channels == 0) return error.EmptyImage;

    var reader: std.Io.Reader = .fixed(idat.items);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &raw);
    defer raw = writer.toArrayList();
    var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, window);
    _ = try decompress.reader.streamRemaining(&writer.writer);
    const inflated = writer.written();

    const stride = @as(usize, width) * channels;
    if (inflated.len < (stride + 1) * height) return error.Truncated;
    const out = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(out);
    const line = try gpa.alloc(u8, stride);
    defer gpa.free(line);
    const prev = try gpa.alloc(u8, stride);
    defer gpa.free(prev);
    @memset(prev, 0);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_at = @as(usize, y) * (stride + 1);
        const filter = inflated[row_at];
        @memcpy(line, inflated[row_at + 1 ..][0..stride]);
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            const a: u32 = if (i >= channels) line[i - channels] else 0;
            const b: u32 = prev[i];
            const c: u32 = if (i >= channels) prev[i - channels] else 0;
            line[i] = switch (filter) {
                0 => line[i],
                1 => line[i] +% @as(u8, @intCast(a)),
                2 => line[i] +% @as(u8, @intCast(b)),
                3 => line[i] +% @as(u8, @intCast((a + b) / 2)),
                4 => line[i] +% @as(u8, @intCast(paeth(a, b, c))),
                else => return error.Unsupported,
            };
        }
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src = @as(usize, x) * channels;
            const dst = (@as(usize, y) * width + x) * 4;
            out[dst] = line[src];
            out[dst + 1] = line[src + 1];
            out[dst + 2] = line[src + 2];
            out[dst + 3] = if (channels == 4) line[src + 3] else 255;
        }
        @memcpy(prev, line);
    }
    return .{ .width = width, .height = height, .pixels = out };
}

fn paeth(a: u32, b: u32, c: u32) u32 {
    const p = @as(i32, @intCast(a)) + @as(i32, @intCast(b)) - @as(i32, @intCast(c));
    const pa = @abs(p - @as(i32, @intCast(a)));
    const pb = @abs(p - @as(i32, @intCast(b)));
    const pc = @abs(p - @as(i32, @intCast(c)));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Color tagging the PNG carries: the sRGB marker, or explicit cHRM
/// primaries plus gAMA for wide-gamut output. All optional; none is the
/// untagged default.
pub const ColorTags = struct {
    srgb: bool = false,
    chrm: ?[32]u8 = null,
    gama: ?[4]u8 = null,
};

pub const EncodeOptions = struct {
    /// 8 or 16 bits per channel. 16 widens each 8-bit sample so the file
    /// is a genuine 16-bit container, ready for the HDR capture target.
    bit_depth: u8 = 8,
    color: ColorTags = .{},
};

/// Encodes tightly packed RGBA8 pixels as a PNG, appending to `out`.
/// Every scanline uses the up filter - cheap, effective on camera
/// frames, and one fixed choice keeps the output deterministic.
pub fn encodeRgba(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pixels: []const u8, width: u32, height: u32) !void {
    return encodeRgbaOpts(gpa, out, pixels, width, height, .{});
}

/// The general path: bit depth and color tags on top of encodeRgba.
pub fn encodeRgbaOpts(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pixels: []const u8, width: u32, height: u32, opts: EncodeOptions) !void {
    if (width == 0 or height == 0) return error.EmptyImage;
    if (opts.bit_depth != 8 and opts.bit_depth != 16) return error.Unsupported;
    const src_row = @as(usize, width) * 4;
    if (pixels.len != src_row * height) return error.SizeMismatch;
    const bytes_per_sample: usize = if (opts.bit_depth == 16) 2 else 1;
    const row_bytes = src_row * bytes_per_sample;

    try out.appendSlice(gpa, &png_signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = opts.bit_depth;
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try writeChunk(out, gpa, "IHDR", &ihdr);

    // Color chunks sit between IHDR and IDAT. sRGB and cHRM/gAMA are
    // mutually exclusive by intent: sRGB for the default, the explicit
    // primaries for wide gamut.
    if (opts.color.srgb) {
        try writeChunk(out, gpa, "sRGB", &.{0}); // perceptual intent
    } else {
        if (opts.color.chrm) |chrm| try writeChunk(out, gpa, "cHRM", &chrm);
        if (opts.color.gama) |gama| try writeChunk(out, gpa, "gAMA", &gama);
    }

    // Filtered scanlines: one filter byte then the row minus the row
    // above (zero above the first row). At 16-bit each sample expands to
    // big-endian first, then the byte-wise filter runs the same way.
    const filtered = try gpa.alloc(u8, (row_bytes + 1) * height);
    defer gpa.free(filtered);
    const widened: []u8 = if (opts.bit_depth == 16) try gpa.alloc(u8, row_bytes * height) else &.{};
    defer if (widened.len > 0) gpa.free(widened);
    const rows: []const u8 = if (opts.bit_depth == 16) blk: {
        for (0..pixels.len) |i| {
            widened[i * 2] = pixels[i];
            widened[i * 2 + 1] = pixels[i];
        }
        break :blk widened;
    } else pixels;
    for (0..height) |y| {
        const row = rows[y * row_bytes ..][0..row_bytes];
        const dst = filtered[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        dst[0] = 2; // up filter
        if (y == 0) {
            @memcpy(dst[1..], row);
        } else {
            const above = rows[(y - 1) * row_bytes ..][0..row_bytes];
            for (row, above, dst[1..]) |cur, up, *b| b.* = cur -% up;
        }
    }

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer compressed.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    // On the heap, never the stack: the deflate state is a quarter of a megabyte,
    // and a stack frame that size overflows any thread but the main one - which is
    // exactly how a capture from a worker thread took the process down.
    const compress = try gpa.create(std.compress.flate.Compress);
    defer gpa.destroy(compress);
    compress.* = try std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .level_6);
    try compress.writer.writeAll(filtered);
    try compress.finish();

    try writeChunk(out, gpa, "IDAT", compressed.written());
    try writeChunk(out, gpa, "IEND", &.{});
}

/// Streams a PNG a horizontal band at a time, so a huge tiled capture
/// holds only one band, not the whole raw frame. The up filter carries
/// its previous row across bands and the deflate stream is continuous, so
/// the bytes match encodeRgbaOpts. Init in place (see begin).
pub const StreamEncoder = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    compressed: std.Io.Writer.Allocating,
    /// By pointer, not by value: the deflate state is a quarter of a megabyte, and
    /// this struct is declared on a caller's stack.
    compress: *std.compress.flate.Compress,
    window: []u8,
    filt: []u8,
    prev: []u8,
    wide: []u8,
    src_row: usize,
    row_bytes: usize,
    bit_depth: u8,
    started: bool,

    pub fn begin(self: *StreamEncoder, gpa: std.mem.Allocator, out: *std.ArrayList(u8), width: u32, height: u32, opts: EncodeOptions) !void {
        if (width == 0 or height == 0) return error.EmptyImage;
        if (opts.bit_depth != 8 and opts.bit_depth != 16) return error.Unsupported;
        const src_row = @as(usize, width) * 4;
        const bytes_per_sample: usize = if (opts.bit_depth == 16) 2 else 1;
        const row_bytes = src_row * bytes_per_sample;

        try out.appendSlice(gpa, &png_signature);
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], width, .big);
        std.mem.writeInt(u32, ihdr[4..8], height, .big);
        ihdr[8] = opts.bit_depth;
        ihdr[9] = 6;
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = 0;
        try writeChunk(out, gpa, "IHDR", &ihdr);
        if (opts.color.srgb) {
            try writeChunk(out, gpa, "sRGB", &.{0});
        } else {
            if (opts.color.chrm) |chrm| try writeChunk(out, gpa, "cHRM", &chrm);
            if (opts.color.gama) |gama| try writeChunk(out, gpa, "gAMA", &gama);
        }

        self.gpa = gpa;
        self.out = out;
        self.src_row = src_row;
        self.row_bytes = row_bytes;
        self.bit_depth = opts.bit_depth;
        self.started = false;
        self.compressed = try .initCapacity(gpa, 4096);
        errdefer self.compressed.deinit();
        self.window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        errdefer gpa.free(self.window);
        self.filt = try gpa.alloc(u8, row_bytes + 1);
        errdefer gpa.free(self.filt);
        self.prev = try gpa.alloc(u8, row_bytes);
        errdefer gpa.free(self.prev);
        self.wide = if (opts.bit_depth == 16) try gpa.alloc(u8, row_bytes) else &.{};
        errdefer if (self.wide.len > 0) gpa.free(self.wide);
        self.compress = try gpa.create(std.compress.flate.Compress);
        errdefer gpa.destroy(self.compress);
        self.compress.* = try std.compress.flate.Compress.init(&self.compressed.writer, self.window, .zlib, .level_6);
    }

    /// Filters and compresses `band_height` rows of tightly packed RGBA8.
    pub fn writeBand(self: *StreamEncoder, pixels: []const u8, band_height: u32) !void {
        if (pixels.len != self.src_row * band_height) return error.SizeMismatch;
        var y: u32 = 0;
        while (y < band_height) : (y += 1) {
            const src = pixels[@as(usize, y) * self.src_row ..][0..self.src_row];
            // The output row: widened big-endian samples at 16-bit, else
            // the source bytes directly.
            const row: []const u8 = if (self.bit_depth == 16) blk: {
                for (src, 0..) |b, i| {
                    self.wide[i * 2] = b;
                    self.wide[i * 2 + 1] = b;
                }
                break :blk self.wide;
            } else src;
            self.filt[0] = 2; // up filter
            if (!self.started) {
                @memcpy(self.filt[1..], row);
                self.started = true;
            } else {
                for (row, self.prev, self.filt[1..]) |cur, up, *b| b.* = cur -% up;
            }
            @memcpy(self.prev, row);
            try self.compress.writer.writeAll(self.filt);
        }
    }

    pub fn finish(self: *StreamEncoder) !void {
        try self.compress.finish();
        try writeChunk(self.out, self.gpa, "IDAT", self.compressed.written());
        try writeChunk(self.out, self.gpa, "IEND", &.{});
    }

    pub fn deinit(self: *StreamEncoder) void {
        self.gpa.destroy(self.compress);
        self.compressed.deinit();
        self.gpa.free(self.window);
        self.gpa.free(self.filt);
        self.gpa.free(self.prev);
        if (self.wide.len > 0) self.gpa.free(self.wide);
    }
};

const t = std.testing;

test "streaming in bands matches the one-shot encode byte for byte" {
    const w: u32 = 6;
    const h: u32 = 5;
    var pixels: [6 * 5 * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast((i * 7) & 0xFF);
    var one: std.ArrayList(u8) = .empty;
    defer one.deinit(t.allocator);
    try encodeRgbaOpts(t.allocator, &one, &pixels, w, h, .{});
    // Stream the same pixels in a 2-row band then a 3-row band.
    var streamed: std.ArrayList(u8) = .empty;
    defer streamed.deinit(t.allocator);
    var enc: StreamEncoder = undefined;
    try enc.begin(t.allocator, &streamed, w, h, .{});
    defer enc.deinit();
    try enc.writeBand(pixels[0 .. 2 * w * 4], 2);
    try enc.writeBand(pixels[2 * w * 4 ..], 3);
    try enc.finish();
    try t.expectEqualSlices(u8, one.items, streamed.items);
}

test "a known 2x2 image round-trips through the std decoder-free checks" {
    // Without a decoder in std, assert the structural invariants: the
    // signature, chunk framing, IHDR fields, and determinism.
    const pixels = [16]u8{
        255, 0,   0,   255, 0, 255, 0, 255,
        0,   0,   255, 255, 9, 9,   9, 255,
    };
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(t.allocator);
    try encodeRgba(t.allocator, &a, &pixels, 2, 2);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(t.allocator);
    try encodeRgba(t.allocator, &b, &pixels, 2, 2);
    try t.expectEqualSlices(u8, a.items, b.items);
    try t.expectEqualSlices(u8, &png_signature, a.items[0..8]);
    try t.expectEqualSlices(u8, "IHDR", a.items[12..16]);
    const w = std.mem.readInt(u32, a.items[16..20], .big);
    const h = std.mem.readInt(u32, a.items[20..24], .big);
    try t.expectEqual(@as(u32, 2), w);
    try t.expectEqual(@as(u32, 2), h);
    try t.expectEqualSlices(u8, "IEND", a.items[a.items.len - 8 ..][0..4]);
}

test "size mismatch and empty refuse" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    const px = [4]u8{ 1, 2, 3, 4 };
    try t.expectError(error.SizeMismatch, encodeRgba(t.allocator, &out, &px, 2, 2));
    try t.expectError(error.EmptyImage, encodeRgba(t.allocator, &out, &px, 0, 1));
}

test "a decoded PNG is the pixels that were encoded" {
    const gpa = std.testing.allocator;
    var pixels: [4 * 3 * 4]u8 = undefined;
    for (&pixels, 0..) |*b, i| b.* = @intCast((i * 37) % 251);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encodeRgba(gpa, &out, &pixels, 4, 3);
    const back = try decodeRgba(gpa, out.items);
    defer back.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 4), back.width);
    try std.testing.expectEqual(@as(u32, 3), back.height);
    try std.testing.expectEqualSlices(u8, &pixels, back.pixels);
}
