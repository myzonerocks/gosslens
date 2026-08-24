//! Video decode for targets whose hardware backend has not landed: a
//! deterministic synthetic clip stands in so the playback path - the
//! clock, the frame advance, the loop - runs and tests everywhere the
//! real decoder does not. A moving band marks each frame.

const std = @import("std");

/// Whether a real decoder exists on this target.
pub const supported = false;

const stub_width: u32 = 64;
const stub_height: u32 = 48;
const stub_frames: u32 = 24;

pub const Read = enum { frame, end, failed };

pub const Decoder = struct {
    handle: *anyopaque,
    width: u32,
    height: u32,
    cursor: u32,

    pub fn open(path: []const u8) ?Decoder {
        _ = path;
        return .{ .handle = @ptrFromInt(@alignOf(usize)), .width = stub_width, .height = stub_height, .cursor = 0 };
    }

    /// Paints frame `cursor` as a solid field with a bright band whose
    /// column tracks the frame, then advances. Ends after the clip's
    /// frame count so the caller exercises the loop.
    pub fn read(self: *Decoder, out_bgra: []u8) Read {
        if (out_bgra.len < @as(usize, stub_width) * stub_height * 4) return .failed;
        if (self.cursor >= stub_frames) return .end;
        const band = (self.cursor * stub_width) / stub_frames;
        for (0..stub_height) |y| {
            for (0..stub_width) |x| {
                const at = (y * stub_width + x) * 4;
                const on = x >= band and x < band + 6;
                out_bgra[at + 0] = if (on) 240 else 32;
                out_bgra[at + 1] = @intCast((self.cursor * 9) % 256);
                out_bgra[at + 2] = if (on) 240 else 64;
                out_bgra[at + 3] = 255;
            }
        }
        self.cursor += 1;
        return .frame;
    }

    pub fn reset(self: *Decoder) bool {
        self.cursor = 0;
        return true;
    }

    pub fn close(self: *Decoder) void {
        _ = self;
    }
};

test "the synthetic decoder advances then loops" {
    var d = Decoder.open("clip.mp4") orelse return error.OpenFailed;
    defer d.close();
    const buf = try std.testing.allocator.alloc(u8, @as(usize, d.width) * d.height * 4);
    defer std.testing.allocator.free(buf);

    const first = try std.testing.allocator.dupe(u8, buf[0..buf.len]);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqual(Read.frame, d.read(first));

    var count: u32 = 1;
    while (d.read(buf) == .frame) count += 1;
    try std.testing.expectEqual(stub_frames, count);
    // The band moved, so a later frame differs from the first.
    const mid = try std.testing.allocator.alloc(u8, buf.len);
    defer std.testing.allocator.free(mid);
    try std.testing.expect(d.reset());
    try std.testing.expectEqual(Read.frame, d.read(mid));
    _ = d.read(mid);
    _ = d.read(mid);
    try std.testing.expect(!std.mem.eql(u8, first, mid));
}
