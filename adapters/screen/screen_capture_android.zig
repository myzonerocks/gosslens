//! Screen capture on Android. MediaProjection is a Java API with a consent
//! dialog: only the app can ask, and only an Activity can receive the answer, so
//! the SDK drives the grant and hands the engine an ImageReader surface. This
//! file owns the native half, reading frames off that surface.

const std = @import("std");

pub const supported = true;

pub const max_surfaces: usize = 8;
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

/// What the SDK granted. Android gives one projection at a time, and its geometry
/// comes from the Activity rather than from here, so the SDK sets this when the
/// consent dialog returns and clears it when the projection stops.
var granted: ?CSurface = null;
var pending: ?Frame = null;

const Frame = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    timestamp_us: i64,
};

/// Called by the JNI when MediaProjection is granted, with the display geometry
/// the Activity reported. Nothing is capturable before this, which is the
/// consent flow rather than a limitation.
pub fn setGranted(width: f32, height: f32, density_scale: f32, label: []const u8) void {
    var surface: CSurface = .{
        .id = 1,
        .kind = @intFromEnum(Kind.display),
        .logical_width = width,
        .logical_height = height,
        .origin_x = 0,
        .origin_y = 0,
        .scale = if (density_scale > 0) density_scale else 1,
        .title_len = 0,
        .title = undefined,
    };
    const n = @min(label.len, max_title_bytes);
    @memcpy(surface.title[0..n], label[0..n]);
    surface.title_len = @intCast(n);
    granted = surface;
}

pub fn clearGranted() void {
    granted = null;
    pending = null;
}

/// Called by the JNI for each frame the ImageReader produced. The bytes belong to
/// the caller's buffer until the next call, which is the same latest-wins
/// discipline the Apple backend's delegate uses.
pub fn offerFrame(pixels: []const u8, width: u32, height: u32, stride: u32, timestamp_us: i64) void {
    pending = .{ .pixels = pixels, .width = width, .height = height, .stride = stride, .timestamp_us = timestamp_us };
}

/// Zero surfaces until consent is granted, which is the honest answer: a host
/// reads it and prompts rather than receiving an error it cannot act on.
pub fn enumerate(out: []CSurface) usize {
    if (out.len == 0) return 0;
    const surface = granted orelse return 0;
    out[0] = surface;
    return 1;
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
    handle: *anyopaque,
    width: u32,
    height: u32,
    last_timestamp_us: i64 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,

    /// Opens the granted projection. The scale is the SDK's to choose when it
    /// creates the virtual display, so a scale passed here narrows the request
    /// rather than overriding what Android gave.
    pub fn open(id: u64, scale: f32) ?Capture {
        const surface = granted orelse return null;
        if (id != surface.id) return null;
        const used = if (scale > 0) scale else surface.scale;
        const width: u32 = @intFromFloat(@round(surface.logical_width * used));
        const height: u32 = @intFromFloat(@round(surface.logical_height * used));
        if (width == 0 or height == 0) return null;
        // No native handle to own: the projection lives on the Java side and this
        // reads what the JNI offers, so the handle is a marker the type needs.
        return .{
            .handle = @ptrFromInt(@intFromEnum(Kind.display) + 1),
            .width = width,
            .height = height,
            .last_width = width,
            .last_height = height,
        };
    }

    pub fn read(self: *Capture, out_bgra: []u8) Read {
        const frame = pending orelse return .unchanged;
        pending = null;
        const width = frame.width;
        const height = frame.height;
        if (out_bgra.len < @as(usize, width) * height * 4) return .failed;
        if (frame.pixels.len < @as(usize, frame.stride) * height) return .failed;
        // Row by row: an ImageReader's stride is its own and rarely the tight
        // width, so one memcpy would shear the image.
        for (0..height) |y| {
            const src = frame.pixels[y * frame.stride ..][0 .. width * 4];
            @memcpy(out_bgra[y * width * 4 ..][0 .. width * 4], src);
        }
        self.last_width = width;
        self.last_height = height;
        self.last_timestamp_us = frame.timestamp_us;
        return .frame;
    }

    pub fn close(self: *Capture) void {
        _ = self;
        pending = null;
    }
};

const testing = std.testing;

test "nothing is capturable before consent, and one display after it" {
    clearGranted();
    var out: [4]CSurface = undefined;
    try testing.expectEqual(@as(usize, 0), enumerate(&out));
    try testing.expect(Capture.open(1, 0) == null);

    setGranted(1080, 2400, 2.75, "Phone display");
    try testing.expectEqual(@as(usize, 1), enumerate(&out));
    const s = view(&out[0]);
    try testing.expectEqual(Kind.display, s.kind);
    try testing.expectEqualStrings("Phone display", s.title);
    try testing.expectApproxEqAbs(@as(f32, 2.75), s.scale, 1e-6);

    var capture = Capture.open(1, 1).?;
    try testing.expectEqual(@as(u32, 1080), capture.width);
    capture.close();
    clearGranted();
}

test "a frame is copied row by row and read once" {
    clearGranted();
    setGranted(2, 2, 1, "test");
    var capture = Capture.open(1, 1).?;
    defer capture.close();

    var out: [16]u8 = @splat(0);
    // Nothing offered yet is unchanged, not a failure.
    try testing.expectEqual(Read.unchanged, capture.read(&out));

    // A stride wider than the row, which is what an ImageReader actually gives.
    const pixels = [_]u8{
        1, 2,  3,  4,  5,  6,  7,  8,  99, 99,
        9, 10, 11, 12, 13, 14, 15, 16, 99, 99,
    };
    offerFrame(&pixels, 2, 2, 10, 1234);
    try testing.expectEqual(Read.frame, capture.read(&out));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, &out);
    try testing.expectEqual(@as(i64, 1234), capture.last_timestamp_us);
    // Read once: the same frame does not come back as a new one.
    try testing.expectEqual(Read.unchanged, capture.read(&out));
    clearGranted();
}
