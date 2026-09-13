//! Screen capture on Linux, which is two backends rather than one: a Wayland
//! session hands capture to `xdg-desktop-portal`, and an X session reads the root
//! window through Xlib. The same binary runs on both, so the choice is made at run
//! time from the session the process is actually in.

const std = @import("std");
const wayland = @import("screen_capture_wayland.zig");
const x11 = @import("screen_capture_x11.zig");

pub const supported = true;
pub const max_surfaces: usize = x11.max_surfaces;
pub const max_title_bytes: usize = x11.max_title_bytes;

pub const CSurface = x11.CSurface;
pub const Kind = x11.Kind;
pub const Surface = x11.Surface;
pub const Read = x11.Read;

/// Which backend this session belongs to, decided once. A Wayland session with
/// XWayland would let the X path open a display and see only XWayland's own
/// clients, so the session kind decides rather than what happens to load.
fn onWayland() bool {
    return wayland.inWaylandSession();
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
    if (onWayland()) {
        var theirs: [1]wayland.CSurface = undefined;
        const count = wayland.enumerate(theirs[0..@min(out.len, 1)]);
        if (count == 0) return 0;
        out[0] = @bitCast(theirs[0]);
        return 1;
    }
    return x11.enumerate(out);
}

pub fn view(raw: *const CSurface) Surface {
    return x11.view(raw);
}

/// One capture, whichever backend opened it. The two hold different state, so the
/// union carries which one is live rather than a pointer nobody owns.
pub const Capture = struct {
    backend: union(enum) {
        wayland: wayland.Capture,
        x11: x11.Capture,
    },
    width: u32,
    height: u32,
    last_timestamp_us: i64 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,

    pub fn open(id: u64, scale: f32) ?Capture {
        if (onWayland()) {
            const c = wayland.Capture.open(id, scale) orelse return null;
            return .{ .backend = .{ .wayland = c }, .width = c.width, .height = c.height, .last_width = c.width, .last_height = c.height };
        }
        const c = x11.Capture.open(id, scale) orelse return null;
        return .{ .backend = .{ .x11 = c }, .width = c.width, .height = c.height, .last_width = c.width, .last_height = c.height };
    }

    pub fn read(c: *Capture, out_bgra: []u8) Read {
        const result = switch (c.backend) {
            .wayland => |*w| w.read(out_bgra),
            .x11 => |*x| x.read(out_bgra),
        };
        if (result == .frame) {
            c.last_width = c.width;
            c.last_height = c.height;
            c.last_timestamp_us +%= 1;
        }
        return result;
    }

    pub fn close(c: *Capture) void {
        switch (c.backend) {
            .wayland => |*w| w.close(),
            .x11 => |*x| x.close(),
        }
        c.* = undefined;
    }
};

const t = std.testing;

test "a host in no graphical session captures nothing, and says so rather than crashing" {
    var surfaces: [2]CSurface = undefined;
    const count = enumerate(&surfaces);
    try t.expect(count <= surfaces.len);
    try t.expect(Capture.open(0, 0) == null);
}
