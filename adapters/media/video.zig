//! Video decode behind the media adapter boundary: the platform
//! backend streams a file's frames off the hardware decoder, one at a
//! time, so a live texture pulls the next frame in O(1). Looping asks
//! the backend to rewind. No vendor type crosses this file's surface.

const std = @import("std");

/// Whether a real decoder exists on this target.
pub const supported = true;

extern fn goss_video_open(path: [*]const u8, path_len: usize, out_width: *u32, out_height: *u32) ?*anyopaque;
extern fn goss_video_read(handle: *anyopaque, out_bgra: [*]u8, capacity: usize, out_width: ?*u32, out_height: ?*u32) i32;
extern fn goss_video_reset(handle: *anyopaque) i32;
extern fn goss_video_close(handle: *anyopaque) void;

/// The outcome of pulling one frame: a frame landed, the stream ended
/// (the caller loops by resetting), or the decoder failed.
pub const Read = enum { frame, end, failed };

/// A streaming decoder over one video file. Frames come out BGRA, the
/// pixel order the platform decoders vend, uploaded to a matching
/// texture so no per-pixel swap is needed.
pub const Decoder = struct {
    handle: *anyopaque,
    width: u32,
    height: u32,

    pub fn open(path: []const u8) ?Decoder {
        var width: u32 = 0;
        var height: u32 = 0;
        const handle = goss_video_open(path.ptr, path.len, &width, &height) orelse return null;
        if (width == 0 or height == 0) {
            goss_video_close(handle);
            return null;
        }
        return .{ .handle = handle, .width = width, .height = height };
    }

    /// Pulls the next frame into out_bgra, which must hold width*height*4
    /// bytes. At end of stream the buffer is left untouched.
    pub fn read(self: *Decoder, out_bgra: []u8) Read {
        return switch (goss_video_read(self.handle, out_bgra.ptr, out_bgra.len, null, null)) {
            0 => .frame,
            1 => .end,
            else => .failed,
        };
    }

    /// Rewinds to the first frame so playback can loop.
    pub fn reset(self: *Decoder) bool {
        return goss_video_reset(self.handle) == 0;
    }

    pub fn close(self: *Decoder) void {
        goss_video_close(self.handle);
    }
};

extern fn goss_media_boundary_probe(mode: u32) i32;

// The boundary guard proof: a deliberate NSException (mode 0) and a
// deliberate C++ throw (mode 1) behind the shim must both surface as
// the failure status, never unwind into Zig; mode 2 throws nothing.
test "a throw behind the media boundary surfaces as a status" {
    // Deliberate: the caught exception logs to stderr, so this runs only under
    // GOSS_PROBES (the ci sets it) and stays out of the everyday test output.
    if (std.c.getenv("GOSS_PROBES") == null) return error.SkipZigTest;
    try std.testing.expectEqual(@as(i32, -1), goss_media_boundary_probe(0));
    try std.testing.expectEqual(@as(i32, -1), goss_media_boundary_probe(1));
    try std.testing.expectEqual(@as(i32, 0), goss_media_boundary_probe(2));
}
