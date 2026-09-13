//! The PipeWire side of Wayland screen capture: the portal hands over a descriptor
//! and a node id, and frames arrive as buffers on that node. Format negotiation
//! speaks SPA pods, which are a byte layout rather than a C API, so a pod is built
//! here as a size, a type and a body, which is checkable where a macro is not.

const std = @import("std");

pub const Error = error{
    NoPipeWire,
    ConnectFailed,
    StreamFailed,
    NoFormat,
};

/// SPA type ids, from the documented enum. Only the ones a video format needs.
pub const SpaType = struct {
    pub const none: u32 = 1;
    pub const bool_: u32 = 2;
    pub const id: u32 = 3;
    pub const int: u32 = 4;
    pub const rectangle: u32 = 7;
    pub const fraction: u32 = 8;
    pub const object: u32 = 15;
    pub const choice: u32 = 16;
};

/// The SPA media type and subtype a screen stream uses, and the video format ids
/// for the two orders a compositor vends.
pub const Media = struct {
    pub const video: u32 = 2;
    pub const raw: u32 = 1;
    pub const format_bgra: u32 = 12;
    pub const format_rgba: u32 = 11;
    pub const format_bgrx: u32 = 14;
    pub const format_rgbx: u32 = 13;
};

/// Object ids inside a format pod, from spa/param/video/format.h.
const Prop = struct {
    const media_type: u32 = 1;
    const media_subtype: u32 = 2;
    const video_format: u32 = 1;
    const video_size: u32 = 3;
    const video_framerate: u32 = 4;
};

const param_enum_format: u32 = 3;

/// Writes SPA pods into a caller's buffer. Every pod is an eight byte header, a
/// body, and padding to eight: a container's size counts its body only, which is
/// why each open remembers where its size word sits.
pub const PodBuilder = struct {
    buffer: []u8,
    at: usize = 0,

    pub fn init(buffer: []u8) PodBuilder {
        return .{ .buffer = buffer };
    }

    fn write(b: *PodBuilder, raw: []const u8) Error!void {
        if (b.at + raw.len > b.buffer.len) return error.NoFormat;
        @memcpy(b.buffer[b.at .. b.at + raw.len], raw);
        b.at += raw.len;
    }

    fn writeU32(b: *PodBuilder, value: u32) Error!void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, value, .little);
        try b.write(&tmp);
    }

    /// Pads to the eight byte boundary every pod body ends on.
    fn pad(b: *PodBuilder) Error!void {
        while (b.at % 8 != 0) try b.write(&[_]u8{0});
    }

    /// Opens a pod, answering where its size word is so the close can fill it in.
    fn open(b: *PodBuilder, pod_type: u32) Error!usize {
        const size_at = b.at;
        try b.writeU32(0);
        try b.writeU32(pod_type);
        return size_at;
    }

    fn close(b: *PodBuilder, size_at: usize) Error!void {
        try b.pad();
        const body = b.at - size_at - 8;
        std.mem.writeInt(u32, b.buffer[size_at..][0..4], @intCast(body), .little);
    }

    /// An object pod: the type and id of the object, then its properties.
    pub fn openObject(b: *PodBuilder, object_type: u32, object_id: u32) Error!usize {
        const size_at = try b.open(SpaType.object);
        try b.writeU32(object_type);
        try b.writeU32(object_id);
        return size_at;
    }

    pub fn closeObject(b: *PodBuilder, size_at: usize) Error!void {
        try b.close(size_at);
    }

    /// One property: its key, its flags, then the value pod.
    fn propertyHeader(b: *PodBuilder, key: u32) Error!void {
        try b.writeU32(key);
        try b.writeU32(0);
    }

    pub fn propId(b: *PodBuilder, key: u32, value: u32) Error!void {
        try b.propertyHeader(key);
        const size_at = try b.open(SpaType.id);
        try b.writeU32(value);
        try b.close(size_at);
    }

    pub fn propInt(b: *PodBuilder, key: u32, value: i32) Error!void {
        try b.propertyHeader(key);
        const size_at = try b.open(SpaType.int);
        try b.writeU32(@bitCast(value));
        try b.close(size_at);
    }

    pub fn propRectangle(b: *PodBuilder, key: u32, width: u32, height: u32) Error!void {
        try b.propertyHeader(key);
        const size_at = try b.open(SpaType.rectangle);
        try b.writeU32(width);
        try b.writeU32(height);
        try b.close(size_at);
    }

    pub fn propFraction(b: *PodBuilder, key: u32, num: u32, den: u32) Error!void {
        try b.propertyHeader(key);
        const size_at = try b.open(SpaType.fraction);
        try b.writeU32(num);
        try b.writeU32(den);
        try b.close(size_at);
    }

    pub fn bytes(b: *const PodBuilder) []const u8 {
        return b.buffer[0..b.at];
    }
};

/// The format a screen stream is asked for: any size the compositor likes, at or
/// under the frame rate a caller wants, in one of the orders this engine can read
/// without a conversion pass.
pub fn buildEnumFormat(buffer: []u8, max_fps: u32) Error![]const u8 {
    var b = PodBuilder.init(buffer);
    const object = try b.openObject(param_enum_format, param_enum_format);
    try b.propId(Prop.media_type, Media.video);
    try b.propId(Prop.media_subtype, Media.raw);
    // BGRA is what every consumer of this seam reads, so it is asked for first.
    try b.propId(Prop.video_format, Media.format_bgra);
    try b.propRectangle(Prop.video_size, 0, 0);
    try b.propFraction(Prop.video_framerate, max_fps, 1);
    try b.closeObject(object);
    return b.bytes();
}

/// The entries of libpipewire this needs. The stream is driven from its own thread
/// loop, which is how PipeWire is meant to be used from a host with its own loop.
pub const Api = struct {
    init: *const fn (?*c_int, ?*anyopaque) callconv(.c) void,
    thread_loop_new: *const fn (?[*:0]const u8, ?*anyopaque) callconv(.c) ?*anyopaque,
    thread_loop_destroy: *const fn (*anyopaque) callconv(.c) void,
    thread_loop_start: *const fn (*anyopaque) callconv(.c) c_int,
    thread_loop_stop: *const fn (*anyopaque) callconv(.c) void,
    thread_loop_lock: *const fn (*anyopaque) callconv(.c) void,
    thread_loop_unlock: *const fn (*anyopaque) callconv(.c) void,
    thread_loop_get_loop: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    context_new: *const fn (*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque,
    context_destroy: *const fn (*anyopaque) callconv(.c) void,
    context_connect_fd: *const fn (*anyopaque, c_int, ?*anyopaque, usize) callconv(.c) ?*anyopaque,
    core_disconnect: *const fn (*anyopaque) callconv(.c) c_int,
    stream_new: *const fn (*anyopaque, [*:0]const u8, ?*anyopaque) callconv(.c) ?*anyopaque,
    stream_destroy: *const fn (*anyopaque) callconv(.c) void,
    stream_add_listener: *const fn (*anyopaque, *anyopaque, *const anyopaque, ?*anyopaque) callconv(.c) void,
    stream_connect: *const fn (*anyopaque, c_int, u32, u32, ?[*]const *const anyopaque, u32) callconv(.c) c_int,
    stream_disconnect: *const fn (*anyopaque) callconv(.c) c_int,
    stream_dequeue_buffer: *const fn (*anyopaque) callconv(.c) ?*Buffer,
    stream_queue_buffer: *const fn (*anyopaque, *Buffer) callconv(.c) c_int,
    properties_new: *const fn ([*:0]const u8, ...) callconv(.c) ?*anyopaque,
};

/// The parts of a PipeWire buffer this reads: the data pointer, its stride, and
/// how many bytes the producer actually wrote.
pub const ChunkInfo = extern struct {
    offset: u32,
    stride: i32,
    size: u32,
    flags: i32,
};

pub const DataInfo = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    map_offset: u32,
    max_size: u32,
    data: ?[*]u8,
    chunk: ?*ChunkInfo,
};

pub const SpaBuffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?*anyopaque,
    datas: ?[*]DataInfo,
};

pub const Buffer = extern struct {
    buffer: ?*SpaBuffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
};

/// The direction and flags a consumer stream connects with.
pub const direction_input: c_int = 0;
pub const id_any: u32 = 0xffffffff;
pub const flag_autoconnect: u32 = 1 << 0;
pub const flag_map_buffers: u32 = 1 << 2;

var lib: ?std.DynLib = null;
var api: ?Api = null;
var load_failed = false;

pub fn load() ?*Api {
    if (api) |*a| return a;
    if (load_failed) return null;
    var handle = std.DynLib.open("libpipewire-0.3.so.0") catch std.DynLib.open("libpipewire-0.3.so") catch {
        load_failed = true;
        return null;
    };
    var resolved: Api = undefined;
    inline for (.{
        .{ "init", "pw_init" },
        .{ "thread_loop_new", "pw_thread_loop_new" },
        .{ "thread_loop_destroy", "pw_thread_loop_destroy" },
        .{ "thread_loop_start", "pw_thread_loop_start" },
        .{ "thread_loop_stop", "pw_thread_loop_stop" },
        .{ "thread_loop_lock", "pw_thread_loop_lock" },
        .{ "thread_loop_unlock", "pw_thread_loop_unlock" },
        .{ "thread_loop_get_loop", "pw_thread_loop_get_loop" },
        .{ "context_new", "pw_context_new" },
        .{ "context_destroy", "pw_context_destroy" },
        .{ "context_connect_fd", "pw_context_connect_fd" },
        .{ "core_disconnect", "pw_core_disconnect" },
        .{ "stream_new", "pw_stream_new" },
        .{ "stream_destroy", "pw_stream_destroy" },
        .{ "stream_add_listener", "pw_stream_add_listener" },
        .{ "stream_connect", "pw_stream_connect" },
        .{ "stream_disconnect", "pw_stream_disconnect" },
        .{ "stream_dequeue_buffer", "pw_stream_dequeue_buffer" },
        .{ "stream_queue_buffer", "pw_stream_queue_buffer" },
        .{ "properties_new", "pw_properties_new" },
    }) |pair| {
        @field(resolved, pair[0]) = handle.lookup(@TypeOf(@field(resolved, pair[0])), pair[1]) orelse {
            handle.close();
            load_failed = true;
            return null;
        };
    }
    lib = handle;
    api = resolved;
    return &api.?;
}

/// Copies one buffer's pixels into BGRA at the caller's own stride. A producer's
/// stride is its own, so the copy is row by row, and a row the producer did not
/// write is left alone rather than filled with whatever the mapping held.
pub fn copyFrame(buffer: *Buffer, width: u32, height: u32, out_bgra: []u8) bool {
    const spa = buffer.buffer orelse return false;
    if (spa.n_datas == 0) return false;
    const datas = spa.datas orelse return false;
    const data = datas[0];
    const source = data.data orelse return false;
    const chunk = data.chunk orelse return false;
    const stride: usize = @intCast(@max(chunk.stride, 0));
    if (stride == 0) return false;
    const rows = @min(height, if (stride > 0) chunk.size / @as(u32, @intCast(stride)) else 0);
    const row_bytes = @as(usize, width) * 4;
    if (out_bgra.len < row_bytes * height) return false;
    for (0..rows) |y| {
        const src = source[chunk.offset + y * stride ..];
        const copy = @min(row_bytes, stride);
        @memcpy(out_bgra[y * row_bytes ..][0..copy], src[0..copy]);
    }
    return rows > 0;
}

const t = std.testing;

test "an enum format pod is a well formed object with the properties asked for" {
    var buffer: [256]u8 = undefined;
    const pod = try buildEnumFormat(&buffer, 30);
    // A pod is a size then a type, and the size counts the body alone.
    try t.expect(pod.len >= 16);
    const size = std.mem.readInt(u32, pod[0..4], .little);
    const pod_type = std.mem.readInt(u32, pod[4..8], .little);
    try t.expectEqual(SpaType.object, pod_type);
    try t.expectEqual(pod.len - 8, size);
    // Every pod body ends on an eight byte boundary.
    try t.expectEqual(@as(usize, 0), pod.len % 8);
    // The object says video, raw, and the order this engine reads.
    const body = pod[8..];
    const object_type = std.mem.readInt(u32, body[0..4], .little);
    try t.expectEqual(param_enum_format, object_type);
    try t.expect(std.mem.indexOfScalar(u8, body, Media.format_bgra) != null);
}

test "a pod builder refuses rather than writing past its buffer" {
    var tiny: [8]u8 = undefined;
    try t.expectError(error.NoFormat, buildEnumFormat(&tiny, 30));
}

test "a frame copies row by row at the producer's own stride" {
    // A producer with a wider stride than the visible width: the copy must take the
    // visible bytes from each row rather than reading straight through.
    const width: u32 = 2;
    const height: u32 = 2;
    const stride: usize = 16;
    var source = [_]u8{0} ** (stride * height);
    // Row 0 visible bytes, then padding the copy must skip.
    @memcpy(source[0..8], &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    @memcpy(source[stride .. stride + 8], &[_]u8{ 9, 10, 11, 12, 13, 14, 15, 16 });
    var chunk: ChunkInfo = .{ .offset = 0, .stride = @intCast(stride), .size = @intCast(stride * height), .flags = 0 };
    var datas = [_]DataInfo{.{
        .type = 0,
        .flags = 0,
        .fd = -1,
        .map_offset = 0,
        .max_size = @intCast(source.len),
        .data = &source,
        .chunk = &chunk,
    }};
    var spa: SpaBuffer = .{ .n_metas = 0, .n_datas = 1, .metas = null, .datas = &datas };
    var buffer: Buffer = .{ .buffer = &spa, .user_data = null, .size = 0, .requested = 0 };

    var out = [_]u8{0} ** (4 * 2 * 2);
    try t.expect(copyFrame(&buffer, width, height, &out));
    try t.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, out[0..8]);
    try t.expectEqualSlices(u8, &[_]u8{ 9, 10, 11, 12, 13, 14, 15, 16 }, out[8..16]);
}

test "a buffer with nothing in it is not a frame" {
    var spa: SpaBuffer = .{ .n_metas = 0, .n_datas = 0, .metas = null, .datas = null };
    var buffer: Buffer = .{ .buffer = &spa, .user_data = null, .size = 0, .requested = 0 };
    var out = [_]u8{0} ** 16;
    try t.expect(!copyFrame(&buffer, 2, 2, &out));
}
