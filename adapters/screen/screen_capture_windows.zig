//! Screen capture on Windows: each monitor through GDI, with user32 and gdi32
//! resolved at run time so a build needs no Windows SDK. GDI asks for no consent,
//! which is why a caller should tell the person their screen is being read.

const std = @import("std");

pub const supported = true;
pub const max_surfaces: usize = 128;
pub const max_title_bytes: usize = 128;

pub const CSurface = extern struct {
    id: u64,
    kind: u32,
    logical_width: f32,
    logical_height: f32,
    origin_x: f32,
    origin_y: f32,
    scale: f32,
    title_len: u32,
    title: [max_title_bytes]u8,
};

pub const Kind = enum(u32) { display = 0, window = 1, application = 2, unknown = 3 };

pub const Surface = struct {
    id: u64,
    kind: Kind,
    title: []const u8,
    logical_width: f32,
    logical_height: f32,
    origin_x: f32,
    origin_y: f32,
    scale: f32,
};

pub const Read = enum { frame, unchanged, failed };

const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

/// What EnumDisplayMonitors hands back per monitor, which is all this needs: the
/// rectangle in desktop coordinates and the handle the copy reads through.
const MonitorInfo = extern struct {
    size: u32,
    monitor: Rect,
    work: Rect,
    flags: u32,
};

const BitmapInfoHeader = extern struct {
    size: u32,
    width: i32,
    height: i32,
    planes: u16,
    bit_count: u16,
    compression: u32,
    size_image: u32,
    x_pels_per_meter: i32,
    y_pels_per_meter: i32,
    clr_used: u32,
    clr_important: u32,
};

const Gdi = struct {
    enum_display_monitors: *const fn (?*anyopaque, ?*const Rect, *const fn (?*anyopaque, ?*anyopaque, *Rect, isize) callconv(.c) c_int, isize) callconv(.c) c_int,
    get_monitor_info: *const fn (?*anyopaque, *MonitorInfo) callconv(.c) c_int,
    get_dc: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    release_dc: *const fn (?*anyopaque, *anyopaque) callconv(.c) c_int,
    create_compatible_dc: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    delete_dc: *const fn (*anyopaque) callconv(.c) c_int,
    create_compatible_bitmap: *const fn (*anyopaque, c_int, c_int) callconv(.c) ?*anyopaque,
    delete_object: *const fn (*anyopaque) callconv(.c) c_int,
    select_object: *const fn (*anyopaque, *anyopaque) callconv(.c) ?*anyopaque,
    bit_blt: *const fn (*anyopaque, c_int, c_int, c_int, c_int, *anyopaque, c_int, c_int, u32) callconv(.c) c_int,
    get_di_bits: *const fn (*anyopaque, *anyopaque, u32, u32, ?[*]u8, *BitmapInfoHeader, u32) callconv(.c) c_int,
};

/// SRCCOPY, DIB_RGB_COLORS, and BI_RGB: the three GDI constants this uses.
const srccopy: u32 = 0x00CC0020;
const dib_rgb_colors: u32 = 0;
const bi_rgb: u32 = 0;

/// Zig's std carries no dynamic loading for Windows, so the three kernel32 entries
/// this needs are declared here rather than a backend being unable to build at all.
const Module = *opaque {};
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?Module;
extern "kernel32" fn GetProcAddress(module: Module, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(module: Module) callconv(.winapi) i32;

/// The entry point a name resolves to, cast to the signature the table declares.
fn lookup(comptime T: type, module: Module, comptime name: [:0]const u8) ?T {
    return @ptrCast(@alignCast(GetProcAddress(module, name.ptr) orelse return null));
}

var user32: ?Module = null;
var gdi32: ?Module = null;
var api: ?Gdi = null;
var load_failed = false;

/// Monitors found by the last enumeration, in the order Windows reported them.
/// The index is the id, because a monitor handle is not stable across a display
/// change and an index is what a caller can hold.
var monitors: [max_surfaces]Rect = undefined;
var monitor_count: usize = 0;

fn ready() ?*Gdi {
    if (api) |*a| return a;
    if (load_failed) return null;
    const u = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse {
        load_failed = true;
        return null;
    };
    const g = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("gdi32.dll")) orelse {
        _ = FreeLibrary(u);
        load_failed = true;
        return null;
    };
    var resolved: Gdi = undefined;
    const from_user32 = .{
        .{ "enum_display_monitors", "EnumDisplayMonitors" },
        .{ "get_monitor_info", "GetMonitorInfoW" },
        .{ "get_dc", "GetDC" },
        .{ "release_dc", "ReleaseDC" },
    };
    const from_gdi32 = .{
        .{ "create_compatible_dc", "CreateCompatibleDC" },
        .{ "delete_dc", "DeleteDC" },
        .{ "create_compatible_bitmap", "CreateCompatibleBitmap" },
        .{ "delete_object", "DeleteObject" },
        .{ "select_object", "SelectObject" },
        .{ "bit_blt", "BitBlt" },
        .{ "get_di_bits", "GetDIBits" },
    };
    inline for (from_user32) |pair| {
        @field(resolved, pair[0]) = lookup(@TypeOf(@field(resolved, pair[0])), u, pair[1]) orelse {
            _ = FreeLibrary(u);
            _ = FreeLibrary(g);
            load_failed = true;
            return null;
        };
    }
    inline for (from_gdi32) |pair| {
        @field(resolved, pair[0]) = lookup(@TypeOf(@field(resolved, pair[0])), g, pair[1]) orelse {
            _ = FreeLibrary(u);
            _ = FreeLibrary(g);
            load_failed = true;
            return null;
        };
    }
    user32 = u;
    gdi32 = g;
    api = resolved;
    return &api.?;
}

/// EnumDisplayMonitors calls this once per monitor. It records the rectangle and
/// keeps going until the table is full, which is the same bound every backend has.
fn onMonitor(_: ?*anyopaque, _: ?*anyopaque, rect: *Rect, _: isize) callconv(.c) c_int {
    if (monitor_count >= monitors.len) return 0;
    monitors[monitor_count] = rect.*;
    monitor_count += 1;
    return 1;
}

/// The consent entries the platform that has them calls. A desktop grant is not a
/// frame handed in from outside: X reads the root window, GDI blits the monitor, and
/// the portal streams on its own node. They take the call and change nothing so the
/// JNI layer compiles against one seam on every target.
pub fn setGranted(width: f32, height: f32, density_scale: f32, label: []const u8) void {
    _ = .{ width, height, density_scale, label };
}

pub fn clearGranted() void {}

pub fn offerFrame(pixels: []const u8, width: u32, height: u32, stride: u32, timestamp_us: i64) void {
    _ = .{ pixels, width, height, stride, timestamp_us };
}

pub fn enumerate(out: []CSurface) usize {
    if (out.len == 0) return 0;
    const api_ref = ready() orelse return 0;
    monitor_count = 0;
    if (api_ref.enum_display_monitors(null, null, onMonitor, 0) == 0 and monitor_count == 0) return 0;
    const count = @min(monitor_count, out.len);
    for (0..count) |i| {
        const r = monitors[i];
        var entry: CSurface = std.mem.zeroes(CSurface);
        entry.id = i + 1;
        entry.kind = @intFromEnum(Kind.display);
        entry.logical_width = @floatFromInt(r.right - r.left);
        entry.logical_height = @floatFromInt(r.bottom - r.top);
        // Desktop coordinates, which is what a point sent back maps onto.
        entry.origin_x = @floatFromInt(r.left);
        entry.origin_y = @floatFromInt(r.top);
        // GDI reports physical pixels for a process that is per-monitor DPI aware,
        // and a scaled process sees its own virtualised size either way: one is the
        // honest factor for what this reads.
        entry.scale = 1;
        const title = std.fmt.bufPrint(&entry.title, "Display {d}", .{i}) catch "Display";
        entry.title_len = @intCast(title.len);
        out[i] = entry;
    }
    return count;
}

pub fn view(raw: *const CSurface) Surface {
    const len = @min(raw.title_len, max_title_bytes);
    return .{
        .id = raw.id,
        .kind = switch (raw.kind) {
            0 => .display,
            1 => .window,
            2 => .application,
            else => .unknown,
        },
        .title = raw.title[0..len],
        .logical_width = raw.logical_width,
        .logical_height = raw.logical_height,
        .origin_x = raw.origin_x,
        .origin_y = raw.origin_y,
        .scale = raw.scale,
    };
}

pub const Capture = struct {
    rect: Rect,
    width: u32,
    height: u32,
    last_timestamp_us: i64 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,

    pub fn open(id: u64, scale: f32) ?Capture {
        _ = scale; // GDI reads pixels, so there is no scale to apply.
        _ = ready() orelse return null;
        if (id == 0 or id > monitor_count) return null;
        const r = monitors[id - 1];
        const width = r.right - r.left;
        const height = r.bottom - r.top;
        if (width <= 0 or height <= 0) return null;
        return .{
            .rect = r,
            .width = @intCast(width),
            .height = @intCast(height),
            .last_width = @intCast(width),
            .last_height = @intCast(height),
        };
    }

    /// Blits the monitor into a memory bitmap and reads it out as BGRA, which is
    /// GDI's own order. Every handle is released on the way out, including on the
    /// failure paths: a leaked DC survives the process's own exit on Windows.
    pub fn read(c: *Capture, out_bgra: []u8) Read {
        const g = ready() orelse return .failed;
        if (out_bgra.len < @as(usize, c.width) * c.height * 4) return .failed;
        const screen_dc = g.get_dc(null) orelse return .failed;
        defer _ = g.release_dc(null, screen_dc);
        const mem_dc = g.create_compatible_dc(screen_dc) orelse return .failed;
        defer _ = g.delete_dc(mem_dc);
        const bitmap = g.create_compatible_bitmap(screen_dc, @intCast(c.width), @intCast(c.height)) orelse return .failed;
        defer _ = g.delete_object(bitmap);
        const previous = g.select_object(mem_dc, bitmap);
        defer if (previous) |p| {
            _ = g.select_object(mem_dc, p);
        };
        if (g.bit_blt(mem_dc, 0, 0, @intCast(c.width), @intCast(c.height), screen_dc, c.rect.left, c.rect.top, srccopy) == 0) {
            return .failed;
        }
        var header: BitmapInfoHeader = std.mem.zeroes(BitmapInfoHeader);
        header.size = @sizeOf(BitmapInfoHeader);
        header.width = @intCast(c.width);
        // Negative height asks for a top-down image, which is the order every
        // consumer of this seam expects; positive would arrive upside down.
        header.height = -@as(i32, @intCast(c.height));
        header.planes = 1;
        header.bit_count = 32;
        header.compression = bi_rgb;
        const lines = g.get_di_bits(mem_dc, bitmap, 0, c.height, out_bgra.ptr, &header, dib_rgb_colors);
        if (lines <= 0) return .failed;
        // GDI leaves the fourth byte undefined for a 32-bit blit, so the alpha is
        // written rather than trusted: a consumer compositing this would otherwise
        // read whatever the driver left.
        var at: usize = 3;
        while (at < @as(usize, c.width) * c.height * 4) : (at += 4) out_bgra[at] = 255;
        c.last_width = c.width;
        c.last_height = c.height;
        c.last_timestamp_us +%= 1;
        return .frame;
    }

    pub fn close(c: *Capture) void {
        c.* = undefined;
    }
};

const t = std.testing;

test "a surface view borrows its title and keeps its desktop origin" {
    var raw: CSurface = std.mem.zeroes(CSurface);
    raw.id = 2;
    raw.kind = @intFromEnum(Kind.display);
    raw.logical_width = 1920;
    raw.logical_height = 1080;
    raw.origin_x = -1920;
    raw.scale = 1;
    const name = "Display 1";
    @memcpy(raw.title[0..name.len], name);
    raw.title_len = name.len;

    const s = view(&raw);
    try t.expectEqual(Kind.display, s.kind);
    try t.expectEqualStrings(name, s.title);
    // A monitor to the left of the primary has a negative origin, which is what
    // puts a point sent back onto the right screen.
    try t.expectEqual(@as(f32, -1920), s.origin_x);
}

test "a monitor the enumeration never reported is not a surface" {
    monitor_count = 0;
    try t.expect(Capture.open(0, 0) == null);
    try t.expect(Capture.open(1, 0) == null);
}

test "the monitor callback fills the table and stops at its bound" {
    monitor_count = 0;
    var r: Rect = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    try t.expectEqual(@as(c_int, 1), onMonitor(null, null, &r, 0));
    try t.expectEqual(@as(usize, 1), monitor_count);
    monitor_count = monitors.len;
    // Past the bound the enumeration stops rather than writing off the end.
    try t.expectEqual(@as(c_int, 0), onMonitor(null, null, &r, 0));
    monitor_count = 0;
}
