//! No screen capture on this target. The seam exists so every caller compiles
//! everywhere; `supported` being false is the answer, and a host reads it from
//! the capability report rather than discovering it from a failure.

const std = @import("std");

pub const supported = false;

pub const max_surfaces: usize = 0;
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

/// The consent entries the platform that has them calls. Here they take the
/// call and change nothing, so the JNI layer compiles against one seam on every
/// target rather than one per platform.
pub fn setGranted(width: f32, height: f32, density_scale: f32, label: []const u8) void {
    _ = .{ width, height, density_scale, label };
}

pub fn clearGranted() void {}

pub fn offerFrame(pixels: []const u8, width: u32, height: u32, stride: u32, timestamp_us: i64) void {
    _ = .{ pixels, width, height, stride, timestamp_us };
}

pub fn enumerate(out: []CSurface) usize {
    _ = out;
    return 0;
}

pub fn view(raw: *const CSurface) Surface {
    return .{
        .id = raw.id,
        .kind = .unknown,
        .title = &.{},
        .logical_width = 0,
        .logical_height = 0,
        .origin_x = 0,
        .origin_y = 0,
        .scale = 1,
    };
}

pub const Capture = struct {
    handle: *anyopaque,
    width: u32 = 0,
    height: u32 = 0,
    last_timestamp_us: i64 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,

    pub fn open(id: u64, scale: f32) ?Capture {
        _ = id;
        _ = scale;
        return null;
    }

    pub fn read(self: *Capture, out_bgra: []u8) Read {
        _ = self;
        _ = out_bgra;
        return .failed;
    }

    pub fn close(self: *Capture) void {
        _ = self;
    }
};
