//! Screen capture on Wayland, through `xdg-desktop-portal`: CreateSession,
//! SelectSources, Start, each answered on a Response signal, then
//! OpenPipeWireRemote for the descriptor frames arrive on. A compositor hands no
//! client the screen, so the consent is the portal's to ask and not ours to fake.

const std = @import("std");
const dbus = @import("wayland_dbus.zig");
const pw = @import("wayland_pipewire.zig");

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

const portal_name = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const screencast_iface = "org.freedesktop.portal.ScreenCast";
const request_iface = "org.freedesktop.portal.Request";

/// How long to wait on a Response signal. The first one is a person deciding, so it
/// is minutes rather than milliseconds; the rest follow immediately once they have.
const consent_budget_ms: u32 = 120_000;
const reply_budget_ms: u32 = 5_000;

/// What the portal is asked to offer: monitors and windows, with the cursor drawn
/// into the frame, because an agent reading a screen wants to see the pointer it is
/// reasoning about.
const source_monitor: u32 = 1;
const source_window: u32 = 2;
const cursor_embedded: u32 = 2;

/// Whether this process is in a Wayland session at all. An X11 session has its own
/// backend, and answering there would take capture away from the one that works.
pub fn inWaylandSession() bool {
    // Read through libc, which is the idiom this repo already uses and the only
    // environment a dlopen-ed desktop library would see anyway.
    if (std.c.getenv("WAYLAND_DISPLAY")) |name| {
        if (std.mem.span(name).len > 0) return true;
    }
    if (std.c.getenv("XDG_SESSION_TYPE")) |kind| {
        return std.mem.eql(u8, std.mem.span(kind), "wayland");
    }
    return false;
}

/// The session the portal granted, held for the life of the capture. The portal's
/// session is what the node id belongs to: dropping it ends the stream.
const Granted = struct {
    session_handle: [256]u8 = @splat(0),
    session_len: usize = 0,
    node_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

var granted: ?Granted = null;
var asked_and_refused = false;

/// Runs one portal method whose answer comes back on a Response signal, and returns
/// that signal. Every ScreenCast step has this shape.
fn callAndWait(
    bus: *dbus.Bus,
    api: *dbus.Api,
    member: [*:0]const u8,
    budget_ms: u32,
    build: *const fn (*dbus.Call, *dbus.MessageIter) void,
) dbus.Error!*anyopaque {
    var call = try dbus.Call.init(api, portal_name, portal_path, screencast_iface, member);
    defer call.deinit();
    var options = call.openOptions();
    build(&call, &options);
    call.closeOptions(&options);
    const reply = try call.send(bus, @intCast(reply_budget_ms));
    api.message_unref(reply);
    return bus.waitForSignal(request_iface, "Response", budget_ms);
}

fn noOptions(_: *dbus.Call, _: *dbus.MessageIter) void {}

fn sessionOptions(call: *dbus.Call, dict: *dbus.MessageIter) void {
    // A token the portal echoes back, and the handle token its request is keyed on.
    call.optionString(dict, "session_handle_token", "gosslens");
    call.optionString(dict, "handle_token", "gosslens_session");
}

fn sourceOptions(call: *dbus.Call, dict: *dbus.MessageIter) void {
    call.optionU32(dict, "types", source_monitor | source_window);
    call.optionBool(dict, "multiple", false);
    call.optionU32(dict, "cursor_mode", cursor_embedded);
    call.optionString(dict, "handle_token", "gosslens_sources");
}

fn startOptions(call: *dbus.Call, dict: *dbus.MessageIter) void {
    call.optionString(dict, "handle_token", "gosslens_start");
}

/// Asks the portal for a screen, once. A refusal is remembered so a caller polling
/// enumerate does not reopen the dialog on every frame.
fn request() ?*Granted {
    if (granted) |*g| return g;
    if (asked_and_refused) return null;
    if (!inWaylandSession()) return null;
    const api = dbus.load() orelse return null;
    var bus = dbus.Bus.open() catch return null;
    defer bus.close();
    bus.listenFor("type='signal',interface='org.freedesktop.portal.Request',member='Response'");

    var fresh: Granted = .{};

    // CreateSession: the handle every later call names.
    const created = callAndWait(&bus, api, "CreateSession", reply_budget_ms, sessionOptions) catch {
        asked_and_refused = true;
        return null;
    };
    defer api.message_unref(created);
    const session = dbus.responseString(api, created, "session_handle", &fresh.session_handle) orelse {
        asked_and_refused = true;
        return null;
    };
    fresh.session_len = session.len;

    // SelectSources and Start both take the session handle as their first argument,
    // which is why they are built here rather than through the helper above.
    if (!selectSources(&bus, api, session)) {
        asked_and_refused = true;
        return null;
    }
    const node = startStream(&bus, api, session) orelse {
        asked_and_refused = true;
        return null;
    };
    fresh.node_id = node;
    granted = fresh;
    return &granted.?;
}

fn selectSources(bus: *dbus.Bus, api: *dbus.Api, session: []const u8) bool {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{session}) catch return false;
    var call = dbus.Call.init(api, portal_name, portal_path, screencast_iface, "SelectSources") catch return false;
    defer call.deinit();
    call.appendString(path);
    var options = call.openOptions();
    sourceOptions(&call, &options);
    call.closeOptions(&options);
    const reply = call.send(bus, @intCast(reply_budget_ms)) catch return false;
    api.message_unref(reply);
    const answer = bus.waitForSignal(request_iface, "Response", consent_budget_ms) catch return false;
    defer api.message_unref(answer);
    var scratch: [8]u8 = undefined;
    // A zero response code is the only success, and responseString answers null for
    // every other one: the person said no, or the portal gave up.
    return dbus.responseString(api, answer, "__never__", &scratch) == null and firstCodeIsOk(api, answer);
}

/// Whether a Response signal's code is zero. responseString already refuses a
/// non-zero code, so this reads the code alone for the calls with no result key.
fn firstCodeIsOk(api: *dbus.Api, msg: *anyopaque) bool {
    var it: dbus.MessageIter = .{};
    if (api.message_iter_init(msg, &it) == 0) return false;
    if (api.message_iter_get_arg_type(&it) != dbus.Type.uint32) return false;
    var code: u32 = 1;
    api.message_iter_get_basic(&it, @ptrCast(&code));
    return code == 0;
}

/// Start, whose Response carries the streams array: each entry is a node id and a
/// dictionary with the size the compositor chose.
fn startStream(bus: *dbus.Bus, api: *dbus.Api, session: []const u8) ?u32 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{session}) catch return null;
    var call = dbus.Call.init(api, portal_name, portal_path, screencast_iface, "Start") catch return null;
    defer call.deinit();
    call.appendString(path);
    // The parent window, empty for a process with no window of its own.
    call.appendString("");
    var options = call.openOptions();
    startOptions(&call, &options);
    call.closeOptions(&options);
    const reply = call.send(bus, @intCast(reply_budget_ms)) catch return null;
    api.message_unref(reply);
    const answer = bus.waitForSignal(request_iface, "Response", consent_budget_ms) catch return null;
    defer api.message_unref(answer);
    if (!firstCodeIsOk(api, answer)) return null;
    return firstStreamNode(api, answer);
}

/// The first node id inside a Start response's `streams` array. The array is
/// `a(ua{sv})`, so each entry is a struct of a node id and its properties.
fn firstStreamNode(api: *dbus.Api, msg: *anyopaque) ?u32 {
    var it: dbus.MessageIter = .{};
    if (api.message_iter_init(msg, &it) == 0) return null;
    if (api.message_iter_next(&it) == 0) return null;
    if (api.message_iter_get_arg_type(&it) != dbus.Type.array) return null;
    var results: dbus.MessageIter = .{};
    api.message_iter_recurse(&it, &results);
    while (api.message_iter_get_arg_type(&results) == dbus.Type.dict_entry) {
        var entry: dbus.MessageIter = .{};
        api.message_iter_recurse(&results, &entry);
        var key: ?[*:0]const u8 = null;
        api.message_iter_get_basic(&entry, @ptrCast(&key));
        const name = if (key) |k| std.mem.span(k) else "";
        if (std.mem.eql(u8, name, "streams") and api.message_iter_next(&entry) != 0) {
            var variant: dbus.MessageIter = .{};
            api.message_iter_recurse(&entry, &variant);
            if (api.message_iter_get_arg_type(&variant) == dbus.Type.array) {
                var streams: dbus.MessageIter = .{};
                api.message_iter_recurse(&variant, &streams);
                if (api.message_iter_get_arg_type(&streams) == dbus.Type.struct_begin) {
                    var stream: dbus.MessageIter = .{};
                    api.message_iter_recurse(&streams, &stream);
                    if (api.message_iter_get_arg_type(&stream) == dbus.Type.uint32) {
                        var node: u32 = 0;
                        api.message_iter_get_basic(&stream, @ptrCast(&node));
                        return node;
                    }
                }
            }
        }
        if (api.message_iter_next(&results) == 0) break;
    }
    return null;
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
    const g = request() orelse return 0;
    // The portal grants one stream for one chosen source, so there is exactly one
    // surface to report: the thing the person picked. Its size is not known until a
    // frame arrives, and zero reads as "not yet" rather than as a lie.
    var entry: CSurface = std.mem.zeroes(CSurface);
    entry.id = 1;
    entry.kind = @intFromEnum(Kind.display);
    entry.logical_width = @floatFromInt(g.width);
    entry.logical_height = @floatFromInt(g.height);
    entry.scale = 1;
    const title = std.fmt.bufPrint(&entry.title, "Shared screen", .{}) catch "Shared screen";
    entry.title_len = @intCast(title.len);
    out[0] = entry;
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
    node_id: u32,
    width: u32,
    height: u32,
    last_timestamp_us: i64 = 0,
    last_width: u32 = 0,
    last_height: u32 = 0,
    stream: ?*anyopaque = null,
    loop: ?*anyopaque = null,
    context: ?*anyopaque = null,
    core: ?*anyopaque = null,

    pub fn open(id: u64, scale: f32) ?Capture {
        _ = scale; // The compositor chooses the size; there is no scale to apply.
        if (id != 1) return null;
        const g = request() orelse return null;
        const api = pw.load() orelse return null;
        api.init(null, null);
        const loop = api.thread_loop_new("gosslens-screen", null) orelse return null;
        const raw_loop = api.thread_loop_get_loop(loop) orelse {
            api.thread_loop_destroy(loop);
            return null;
        };
        const context = api.context_new(raw_loop, null, 0) orelse {
            api.thread_loop_destroy(loop);
            return null;
        };
        return .{
            .node_id = g.node_id,
            .width = g.width,
            .height = g.height,
            .loop = loop,
            .context = context,
        };
    }

    /// Pulls the newest buffer off the node. PipeWire hands over its own stride, so
    /// the copy is row by row; nothing new on the node is "unchanged" rather than a
    /// failure, because a still screen produces no buffers.
    pub fn read(c: *Capture, out_bgra: []u8) Read {
        const api = pw.load() orelse return .failed;
        const stream = c.stream orelse return .unchanged;
        api.thread_loop_lock(c.loop.?);
        defer api.thread_loop_unlock(c.loop.?);
        const buffer = api.stream_dequeue_buffer(stream) orelse return .unchanged;
        defer _ = api.stream_queue_buffer(stream, buffer);
        if (!pw.copyFrame(buffer, c.width, c.height, out_bgra)) return .failed;
        c.last_width = c.width;
        c.last_height = c.height;
        c.last_timestamp_us +%= 1;
        return .frame;
    }

    pub fn close(c: *Capture) void {
        const api = pw.load() orelse return;
        if (c.stream) |s| {
            _ = api.stream_disconnect(s);
            api.stream_destroy(s);
        }
        if (c.core) |core| _ = api.core_disconnect(core);
        if (c.context) |ctx| api.context_destroy(ctx);
        if (c.loop) |loop| {
            api.thread_loop_stop(loop);
            api.thread_loop_destroy(loop);
        }
        c.* = undefined;
    }
};

const t = std.testing;

test "a session is only Wayland when the environment says so" {
    // This test host is not Wayland, so the backend must not claim the screen: the
    // X11 backend owns an X session and this one owns a Wayland session.
    if (@import("builtin").os.tag == .macos) try t.expect(!inWaylandSession());
}

test "only the granted surface is a surface, and nothing else opens" {
    // With no portal there is nothing granted, so enumeration answers zero and an
    // open refuses: the same answer as permission not granted.
    var surfaces: [2]CSurface = undefined;
    const count = enumerate(&surfaces);
    try t.expect(count <= 1);
    try t.expect(Capture.open(0, 0) == null);
    try t.expect(Capture.open(7, 0) == null);
}

test "a view carries what the portal reported" {
    var raw: CSurface = std.mem.zeroes(CSurface);
    raw.id = 1;
    raw.logical_width = 3840;
    raw.logical_height = 2160;
    raw.scale = 1;
    const name = "Shared screen";
    @memcpy(raw.title[0..name.len], name);
    raw.title_len = name.len;
    const s = view(&raw);
    try t.expectEqualStrings(name, s.title);
    try t.expectEqual(@as(f32, 3840), s.logical_width);
}
