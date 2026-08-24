//! Generates lenses/reference/env-map/assets/sky.png: a small equirect
//! environment - a blue sky over a warm ground with a single bright sun at
//! one longitude, so it is not rotationally symmetric and a yaw visibly pans
//! it. Run `zig run tools/gen_env_asset.zig` to regenerate; output committed.

const std = @import("std");

const width: u32 = 128;
const height: u32 = 64;

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc ^= byte;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0xEDB88320 else crc >> 1;
        }
    }
    return crc ^ 0xFFFFFFFF;
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |x| {
        a = (a + x) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writeChunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, ctype: []const u8, data: []const u8) !void {
    var len4: [4]u8 = undefined;
    std.mem.writeInt(u32, &len4, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len4);
    try out.appendSlice(gpa, ctype);
    try out.appendSlice(gpa, data);
    var typed: std.ArrayList(u8) = .empty;
    defer typed.deinit(gpa);
    try typed.appendSlice(gpa, ctype);
    try typed.appendSlice(gpa, data);
    var crc4: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc4, crc32(typed.items), .big);
    try out.appendSlice(gpa, &crc4);
}

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0 + 0.5);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();

    // Filtered scanlines: each row is a filter byte (0, none) then RGBA.
    var raw: std.ArrayList(u8) = .empty;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        try raw.append(gpa, 0);
        const lat: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height));
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const lon: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width));
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            if (lat < 0.5) {
                // Sky: zenith blue fading to a pale horizon.
                const t = lat / 0.5;
                r = 0.2 + 0.65 * t;
                g = 0.45 + 0.5 * t;
                b = 0.9;
            } else {
                // Ground: warm earth darkening downward.
                const t = (lat - 0.5) / 0.5;
                r = 0.55 - 0.25 * t;
                g = 0.4 - 0.2 * t;
                b = 0.25 - 0.15 * t;
            }
            // A bright sun near one longitude and just above the horizon,
            // breaking the symmetry so a yaw pans the environment.
            const dl = lon - 0.25;
            const dv = lat - 0.42;
            const d2 = dl * dl + dv * dv;
            const sun = std.math.clamp(1.0 - d2 * 90.0, 0.0, 1.0);
            r += sun;
            g += sun * 0.95;
            b += sun * 0.7;
            try raw.append(gpa, clamp8(r));
            try raw.append(gpa, clamp8(g));
            try raw.append(gpa, clamp8(b));
            try raw.append(gpa, 255);
        }
    }

    // zlib stream: header, one stored deflate block per 65535 bytes, adler.
    var zlib: std.ArrayList(u8) = .empty;
    try zlib.append(gpa, 0x78);
    try zlib.append(gpa, 0x01);
    var off: usize = 0;
    while (off < raw.items.len) {
        const remaining = raw.items.len - off;
        const block: usize = if (remaining > 65535) 65535 else remaining;
        const final: u8 = if (off + block >= raw.items.len) 1 else 0;
        try zlib.append(gpa, final);
        var len2: [2]u8 = undefined;
        std.mem.writeInt(u16, &len2, @intCast(block), .little);
        try zlib.appendSlice(gpa, &len2);
        std.mem.writeInt(u16, &len2, @intCast(~@as(u16, @intCast(block))), .little);
        try zlib.appendSlice(gpa, &len2);
        try zlib.appendSlice(gpa, raw.items[off .. off + block]);
        off += block;
    }
    var adler4: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler4, adler32(raw.items), .big);
    try zlib.appendSlice(gpa, &adler4);

    var png: std.ArrayList(u8) = .empty;
    try png.appendSlice(gpa, &[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 });
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(&png, gpa, "IHDR", &ihdr);
    try writeChunk(&png, gpa, "IDAT", zlib.items);
    try writeChunk(&png, gpa, "IEND", &.{});

    try std.Io.Dir.cwd().createDirPath(init.io, "lenses/reference/env-map/assets");
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "lenses/reference/env-map/assets/sky.png",
        .data = png.items,
    });

    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    try stdout.interface.print("wrote lenses/reference/env-map/assets/sky.png ({d} bytes)\n", .{png.items.len});
    try stdout.interface.flush();
    return 0;
}
