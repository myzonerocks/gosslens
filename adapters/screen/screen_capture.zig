//! Screen capture behind the adapter boundary: the backend enumerates what can
//! be captured and streams a surface's frames as BGRA, the order every screen API
//! vends. No vendor type crosses this surface, and a throw behind it arrives as a
//! status rather than unwinding into Zig.

const std = @import("std");

/// Whether a real screen capture exists on this target.
pub const supported = true;

/// The most surfaces one enumeration returns. A desktop has a handful of
/// displays and tens of windows; past this a caller wants a filter, not a
/// longer list.
pub const max_surfaces: usize = 128;
pub const max_title_bytes: usize = 128;

extern fn goss_screen_enumerate(out: [*]CSurface, capacity: usize, out_count: *u32) i32;
extern fn goss_screen_open(id: u64, scale: f32, out_width: *u32, out_height: *u32) ?*anyopaque;
extern fn goss_screen_read(handle: *anyopaque, out_bgra: [*]u8, capacity: usize, out_width: ?*u32, out_height: ?*u32, out_timestamp_us: ?*i64) i32;
extern fn goss_screen_close(handle: *anyopaque) void;

/// The flat struct the shim fills. It is extern because it crosses the boundary;
/// the Zig-facing type below borrows its title rather than copying it, so
/// enumeration allocates nothing.
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

/// The outcome of pulling one frame: a frame landed, nothing changed since the
/// last read, or the capture failed. Nothing-changed is its own answer because a
/// screen is static most of the time and a caller should not pay for a copy to
/// discover that.
pub const Read = enum { frame, unchanged, failed };

/// Fills out with what the platform will let this process capture. A host that
/// has not been granted permission gets zero surfaces rather than an error, so
/// the permission state reads as "nothing to capture" and a caller prompts.
pub fn enumerate(out: []CSurface) usize {
    if (out.len == 0) return 0;
    var count: u32 = 0;
    if (goss_screen_enumerate(out.ptr, out.len, &count) != 0) return 0;
    return @min(count, out.len);
}

/// The Zig view of one enumerated entry, borrowing its title from the buffer the
/// caller still owns.
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

/// A live capture of one surface. Frames come out BGRA at the backing pixel
/// size, which is the logical size times the scale the surface reported.
pub const Capture = struct {
    handle: *anyopaque,
    width: u32,
    height: u32,
    last_timestamp_us: i64 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,

    /// Opens a surface at a scale. Passing zero takes the surface's own scale,
    /// which is what a caller wants unless it is deliberately capturing small.
    pub fn open(id: u64, scale: f32) ?Capture {
        var width: u32 = 0;
        var height: u32 = 0;
        const handle = goss_screen_open(id, scale, &width, &height) orelse return null;
        if (width == 0 or height == 0) {
            goss_screen_close(handle);
            return null;
        }
        return .{ .handle = handle, .width = width, .height = height, .last_width = width, .last_height = height };
    }

    /// Pulls the newest frame into out_bgra, which must hold width*height*4
    /// bytes. A window that moved between reads changes size, and the frame's own
    /// dimensions land on the capture rather than being assumed.
    pub fn read(self: *Capture, out_bgra: []u8) Read {
        var w: u32 = 0;
        var h: u32 = 0;
        var ts: i64 = -1;
        const status = goss_screen_read(self.handle, out_bgra.ptr, out_bgra.len, &w, &h, &ts);
        if (status == 0) {
            if (w != 0 and h != 0) {
                self.last_width = w;
                self.last_height = h;
            }
            if (ts >= 0) self.last_timestamp_us = ts;
        }
        return switch (status) {
            0 => .frame,
            1 => .unchanged,
            else => .failed,
        };
    }

    pub fn close(self: *Capture) void {
        goss_screen_close(self.handle);
    }
};

const testing = std.testing;

test "an enumerated surface reads back as the view the engine uses" {
    var raw: CSurface = .{
        .id = 42,
        .kind = 1,
        .logical_width = 800,
        .logical_height = 600,
        .origin_x = 1920,
        .origin_y = 0,
        .scale = 2,
        .title_len = 5,
        .title = undefined,
    };
    @memcpy(raw.title[0..5], "Notes");
    const s = view(&raw);
    try testing.expectEqual(Kind.window, s.kind);
    try testing.expectEqualStrings("Notes", s.title);
    try testing.expectApproxEqAbs(@as(f32, 2), s.scale, 1e-6);

    // A title longer than the buffer is clamped rather than read past.
    raw.title_len = max_title_bytes + 10;
    try testing.expectEqual(max_title_bytes, view(&raw).title.len);

    // A kind this build does not know is unknown, not a guess.
    raw.kind = 99;
    try testing.expectEqual(Kind.unknown, view(&raw).kind);
}

test "an empty buffer enumerates nothing rather than calling the platform" {
    var none: [0]CSurface = undefined;
    try testing.expectEqual(@as(usize, 0), enumerate(&none));
}
