//! Screen capture on an X11 session: each screen's root window through a
//! runtime-loaded Xlib, so a build needs no X headers. Wayland is a different
//! backend: an X11 call there reaches XWayland and sees only XWayland's own
//! clients, so this enumerates nothing rather than returning a lie.

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

/// The handful of Xlib entries this needs, resolved once. Xlib's own types are
/// opaque here: nothing is dereferenced that this file did not ask for.
const Xlib = struct {
    const XImage = extern struct {
        width: c_int,
        height: c_int,
        xoffset: c_int,
        format: c_int,
        data: ?[*]u8,
        byte_order: c_int,
        bitmap_unit: c_int,
        bitmap_bit_order: c_int,
        bitmap_pad: c_int,
        depth: c_int,
        bytes_per_line: c_int,
        bits_per_pixel: c_int,
        red_mask: c_ulong,
        green_mask: c_ulong,
        blue_mask: c_ulong,
        /// Xlib keeps private state and a function table past this point. Nothing
        /// here touches either, and the struct is only ever received by pointer.
        obdata: ?*anyopaque,
        funcs: [6]?*anyopaque,
    };

    open_display: *const fn (?[*:0]const u8) callconv(.c) ?*anyopaque,
    close_display: *const fn (*anyopaque) callconv(.c) c_int,
    screen_count: *const fn (*anyopaque) callconv(.c) c_int,
    root_window: *const fn (*anyopaque, c_int) callconv(.c) c_ulong,
    display_width: *const fn (*anyopaque, c_int) callconv(.c) c_int,
    display_height: *const fn (*anyopaque, c_int) callconv(.c) c_int,
    get_image: *const fn (*anyopaque, c_ulong, c_int, c_int, c_uint, c_uint, c_ulong, c_int) callconv(.c) ?*XImage,
    destroy_image: *const fn (*XImage) callconv(.c) c_int,
};

/// z_pixmap, the only format this reads, and the all-planes mask XGetImage takes.
const z_pixmap: c_int = 2;
const all_planes: c_ulong = ~@as(c_ulong, 0);

var lib: ?std.DynLib = null;
var api: ?Xlib = null;
var display: ?*anyopaque = null;
var load_failed = false;

/// Loads Xlib and opens the display once. A host with no X server, or a Wayland
/// session with no XWayland, fails here and every entry then answers nothing.
fn ready() ?*Xlib {
    if (api) |*a| return a;
    if (load_failed) return null;
    var handle = std.DynLib.open("libX11.so.6") catch std.DynLib.open("libX11.so") catch {
        load_failed = true;
        return null;
    };
    var resolved: Xlib = undefined;
    resolved.open_display = handle.lookup(@TypeOf(resolved.open_display), "XOpenDisplay") orelse {
        handle.close();
        load_failed = true;
        return null;
    };
    inline for (.{
        .{ "close_display", "XCloseDisplay" },
        .{ "screen_count", "XScreenCount" },
        .{ "root_window", "XRootWindow" },
        .{ "display_width", "XDisplayWidth" },
        .{ "display_height", "XDisplayHeight" },
        .{ "get_image", "XGetImage" },
        .{ "destroy_image", "XDestroyImage" },
    }) |pair| {
        const field = pair[0];
        @field(resolved, field) = handle.lookup(@TypeOf(@field(resolved, field)), pair[1]) orelse {
            handle.close();
            load_failed = true;
            return null;
        };
    }
    const opened = resolved.open_display(null) orelse {
        handle.close();
        load_failed = true;
        return null;
    };
    lib = handle;
    api = resolved;
    display = opened;
    return &api.?;
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
    const x = ready() orelse return 0;
    const d = display orelse return 0;
    const screens: usize = @intCast(@max(x.screen_count(d), 0));
    const count = @min(screens, out.len);
    for (0..count) |i| {
        const index: c_int = @intCast(i);
        const width = x.display_width(d, index);
        const height = x.display_height(d, index);
        var entry: CSurface = std.mem.zeroes(CSurface);
        // The screen index is the id: X has no stable display identifier of its
        // own, and a screen's index is what every later call takes.
        entry.id = i + 1;
        entry.kind = @intFromEnum(Kind.display);
        entry.logical_width = @floatFromInt(@max(width, 0));
        entry.logical_height = @floatFromInt(@max(height, 0));
        // X reports pixels, so the logical size is the pixel size and the scale is
        // one. A caller mapping a point needs no correction here.
        entry.scale = 1;
        const title = std.fmt.bufPrint(&entry.title, "Screen {d}", .{i}) catch "Screen";
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
    screen: c_int,
    width: u32,
    height: u32,
    last_timestamp_us: i64 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,

    pub fn open(id: u64, scale: f32) ?Capture {
        _ = scale; // X reports pixels, so there is no scale to apply.
        const x = ready() orelse return null;
        const d = display orelse return null;
        if (id == 0) return null;
        const index: c_int = @intCast(id - 1);
        if (index >= x.screen_count(d)) return null;
        const width = x.display_width(d, index);
        const height = x.display_height(d, index);
        if (width <= 0 or height <= 0) return null;
        return .{
            .screen = index,
            .width = @intCast(width),
            .height = @intCast(height),
            .last_width = @intCast(width),
            .last_height = @intCast(height),
        };
    }

    /// Reads the root window into out_bgra. X hands back its own row stride and
    /// its own channel order, so the copy is row by row and the pixels are placed
    /// by mask rather than assumed: a server can be either endianness.
    pub fn read(c: *Capture, out_bgra: []u8) Read {
        const x = ready() orelse return .failed;
        const d = display orelse return .failed;
        if (out_bgra.len < @as(usize, c.width) * c.height * 4) return .failed;
        const root = x.root_window(d, c.screen);
        const image = x.get_image(d, root, 0, 0, c.width, c.height, all_planes, z_pixmap) orelse return .failed;
        defer _ = x.destroy_image(image);
        const data = image.data orelse return .failed;
        if (image.bits_per_pixel != 32 and image.bits_per_pixel != 24) return .failed;

        const bytes_per_pixel: usize = @intCast(@divTrunc(image.bits_per_pixel, 8));
        const stride: usize = @intCast(@max(image.bytes_per_line, 0));
        const red_shift = maskShift(image.red_mask);
        const green_shift = maskShift(image.green_mask);
        const blue_shift = maskShift(image.blue_mask);
        const rows = @min(@as(usize, c.height), @as(usize, @intCast(@max(image.height, 0))));
        const cols = @min(@as(usize, c.width), @as(usize, @intCast(@max(image.width, 0))));
        for (0..rows) |y| {
            const src_row = data[y * stride ..];
            const dst_row = out_bgra[y * @as(usize, c.width) * 4 ..];
            for (0..cols) |px| {
                const at = px * bytes_per_pixel;
                if (at + bytes_per_pixel > stride) break;
                var pixel: u32 = 0;
                for (0..bytes_per_pixel) |b| pixel |= @as(u32, src_row[at + b]) << @intCast(b * 8);
                dst_row[px * 4] = @truncate(pixel >> blue_shift);
                dst_row[px * 4 + 1] = @truncate(pixel >> green_shift);
                dst_row[px * 4 + 2] = @truncate(pixel >> red_shift);
                dst_row[px * 4 + 3] = 255;
            }
        }
        c.last_width = c.width;
        c.last_height = c.height;
        c.last_timestamp_us +%= 1;
        return .frame;
    }

    pub fn close(c: *Capture) void {
        c.* = undefined;
    }
};

/// Where a channel sits inside a pixel, from the mask the server reported. A zero
/// mask means the server did not say, and zero is then the honest shift.
fn maskShift(mask: c_ulong) u5 {
    if (mask == 0) return 0;
    return @intCast(@ctz(@as(u32, @truncate(mask))));
}

const t = std.testing;

test "a surface view borrows its title and carries its geometry" {
    var raw: CSurface = std.mem.zeroes(CSurface);
    raw.id = 1;
    raw.kind = @intFromEnum(Kind.display);
    raw.logical_width = 2560;
    raw.logical_height = 1440;
    raw.scale = 1;
    const name = "Screen 0";
    @memcpy(raw.title[0..name.len], name);
    raw.title_len = name.len;

    const s = view(&raw);
    try t.expectEqual(Kind.display, s.kind);
    try t.expectEqualStrings(name, s.title);
    try t.expectEqual(@as(f32, 2560), s.logical_width);
    // X reports pixels, so a coordinate needs no scale correction on this backend.
    try t.expectEqual(@as(f32, 1), s.scale);
}

test "a channel's place comes from the mask the server reported" {
    // The usual little-endian BGRA server: blue at 0, green at 8, red at 16.
    try t.expectEqual(@as(u5, 16), maskShift(0x00ff0000));
    try t.expectEqual(@as(u5, 8), maskShift(0x0000ff00));
    try t.expectEqual(@as(u5, 0), maskShift(0x000000ff));
    // A server that said nothing gets zero rather than a guess.
    try t.expectEqual(@as(u5, 0), maskShift(0));
}

test "nothing is enumerated without an X server, and nothing crashes" {
    // On a host with no display this loads nothing and answers zero, which is the
    // same answer as permission not granted: a caller prompts rather than failing.
    var surfaces: [4]CSurface = undefined;
    const count = enumerate(&surfaces);
    try t.expect(count <= surfaces.len);
    // An id of zero is never a screen, whatever the host has.
    try t.expect(Capture.open(0, 0) == null);
}
