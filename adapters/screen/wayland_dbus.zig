//! The slice of D-Bus the portal calls need, over libdbus loaded at run time: a
//! session bus, a method call with string and dictionary arguments, a blocking
//! reply, and the signal the portal answers on. Loaded rather than linked because
//! a build of this engine must not need a Linux desktop's headers.

const std = @import("std");

pub const Error = error{
    NoDbus,
    NoBus,
    CallFailed,
    BadReply,
    Timeout,
};

/// A D-Bus message iterator. libdbus declares it as a struct of padding that a
/// caller allocates, and its size is part of the ABI: eight pointers and a few
/// ints, which this mirrors as an opaque block of the documented size.
pub const MessageIter = extern struct {
    bytes: [64]u8 align(@alignOf(usize)) = @splat(0),
};

/// The argument type codes D-Bus uses, as the integers libdbus takes.
pub const Type = struct {
    pub const invalid: c_int = 0;
    pub const boolean: c_int = 'b';
    pub const uint32: c_int = 'u';
    pub const string: c_int = 's';
    pub const object_path: c_int = 'o';
    pub const array: c_int = 'a';
    pub const variant: c_int = 'v';
    pub const dict_entry: c_int = 'e';
    pub const struct_begin: c_int = 'r';
    pub const unix_fd: c_int = 'h';
};

const bus_session: c_int = 0;

pub const Api = struct {
    bus_get: *const fn (c_int, ?*anyopaque) callconv(.c) ?*anyopaque,
    connection_unref: *const fn (*anyopaque) callconv(.c) void,
    connection_flush: *const fn (*anyopaque) callconv(.c) void,
    connection_read_write_dispatch: *const fn (*anyopaque, c_int) callconv(.c) c_int,
    connection_pop_message: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    connection_send_with_reply_and_block: *const fn (*anyopaque, *anyopaque, c_int, ?*anyopaque) callconv(.c) ?*anyopaque,
    bus_add_match: *const fn (*anyopaque, [*:0]const u8, ?*anyopaque) callconv(.c) void,
    message_new_method_call: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque,
    message_unref: *const fn (*anyopaque) callconv(.c) void,
    message_iter_init: *const fn (*anyopaque, *MessageIter) callconv(.c) c_int,
    message_iter_init_append: *const fn (*anyopaque, *MessageIter) callconv(.c) void,
    message_iter_append_basic: *const fn (*MessageIter, c_int, *const anyopaque) callconv(.c) c_int,
    message_iter_open_container: *const fn (*MessageIter, c_int, ?[*:0]const u8, *MessageIter) callconv(.c) c_int,
    message_iter_close_container: *const fn (*MessageIter, *MessageIter) callconv(.c) c_int,
    message_iter_get_arg_type: *const fn (*MessageIter) callconv(.c) c_int,
    message_iter_get_basic: *const fn (*MessageIter, *anyopaque) callconv(.c) void,
    message_iter_recurse: *const fn (*MessageIter, *MessageIter) callconv(.c) void,
    message_iter_next: *const fn (*MessageIter) callconv(.c) c_int,
    message_is_signal: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    message_get_type: *const fn (*anyopaque) callconv(.c) c_int,
};

var lib: ?std.DynLib = null;
var api: ?Api = null;
var load_failed = false;

/// Loads libdbus once. A host without it is a host with no session bus to reach,
/// and every caller then answers nothing rather than failing to start.
pub fn load() ?*Api {
    if (api) |*a| return a;
    if (load_failed) return null;
    var handle = std.DynLib.open("libdbus-1.so.3") catch std.DynLib.open("libdbus-1.so") catch {
        load_failed = true;
        return null;
    };
    var resolved: Api = undefined;
    inline for (.{
        .{ "bus_get", "dbus_bus_get" },
        .{ "connection_unref", "dbus_connection_unref" },
        .{ "connection_flush", "dbus_connection_flush" },
        .{ "connection_read_write_dispatch", "dbus_connection_read_write_dispatch" },
        .{ "connection_pop_message", "dbus_connection_pop_message" },
        .{ "connection_send_with_reply_and_block", "dbus_connection_send_with_reply_and_block" },
        .{ "bus_add_match", "dbus_bus_add_match" },
        .{ "message_new_method_call", "dbus_message_new_method_call" },
        .{ "message_unref", "dbus_message_unref" },
        .{ "message_iter_init", "dbus_message_iter_init" },
        .{ "message_iter_init_append", "dbus_message_iter_init_append" },
        .{ "message_iter_append_basic", "dbus_message_iter_append_basic" },
        .{ "message_iter_open_container", "dbus_message_iter_open_container" },
        .{ "message_iter_close_container", "dbus_message_iter_close_container" },
        .{ "message_iter_get_arg_type", "dbus_message_iter_get_arg_type" },
        .{ "message_iter_get_basic", "dbus_message_iter_get_basic" },
        .{ "message_iter_recurse", "dbus_message_iter_recurse" },
        .{ "message_iter_next", "dbus_message_iter_next" },
        .{ "message_is_signal", "dbus_message_is_signal" },
        .{ "message_get_type", "dbus_message_get_type" },
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

/// A session-bus connection, unreffed on close. libdbus hands out a shared
/// connection for the session bus, so closing it means dropping this reference.
pub const Bus = struct {
    api: *Api,
    conn: *anyopaque,

    pub fn open() Error!Bus {
        const a = load() orelse return error.NoDbus;
        const conn = a.bus_get(bus_session, null) orelse return error.NoBus;
        return .{ .api = a, .conn = conn };
    }

    pub fn close(b: *Bus) void {
        b.api.connection_unref(b.conn);
        b.* = undefined;
    }

    /// Asks to hear one signal interface, which the portal answers its requests on.
    pub fn listenFor(b: *Bus, rule: [*:0]const u8) void {
        b.api.bus_add_match(b.conn, rule, null);
        b.api.connection_flush(b.conn);
    }

    /// Pumps the bus until a signal on the named interface and member arrives, or
    /// the budget runs out. The budget is a real number of milliseconds because a
    /// portal that is waiting on a person can take as long as the person does.
    pub fn waitForSignal(b: *Bus, interface: [*:0]const u8, member: [*:0]const u8, budget_ms: u32) Error!*anyopaque {
        var waited: u32 = 0;
        while (waited < budget_ms) : (waited += 50) {
            if (b.api.connection_read_write_dispatch(b.conn, 50) == 0) return error.CallFailed;
            while (b.api.connection_pop_message(b.conn)) |msg| {
                if (b.api.message_is_signal(msg, interface, member) != 0) return msg;
                b.api.message_unref(msg);
            }
        }
        return error.Timeout;
    }
};

/// One outgoing method call, with the argument appenders the portal needs.
pub const Call = struct {
    api: *Api,
    msg: *anyopaque,
    args: MessageIter = .{},
    /// libdbus refuses an append only when it cannot allocate, and a half-built
    /// message sent anyway fails later as a protocol error nobody can read. Every
    /// append folds its answer in here and send refuses on it.
    truncated: bool = false,

    pub fn init(a: *Api, destination: [*:0]const u8, path: [*:0]const u8, interface: [*:0]const u8, member: [*:0]const u8) Error!Call {
        const msg = a.message_new_method_call(destination, path, interface, member) orelse return error.CallFailed;
        var call: Call = .{ .api = a, .msg = msg };
        a.message_iter_init_append(msg, &call.args);
        return call;
    }

    pub fn deinit(c: *Call) void {
        c.api.message_unref(c.msg);
        c.* = undefined;
    }

    pub fn appendString(c: *Call, value: [*:0]const u8) void {
        var p: [*:0]const u8 = value;
        c.truncated = c.truncated or 0 == c.api.message_iter_append_basic(&c.args, Type.string, @ptrCast(&p));
    }

    /// Opens the `a{sv}` the portal takes as its options argument. Every portal
    /// method has one, and an empty one is still required.
    pub fn openOptions(c: *Call) MessageIter {
        var dict: MessageIter = .{};
        c.truncated = c.truncated or 0 == c.api.message_iter_open_container(&c.args, Type.array, "{sv}", &dict);
        return dict;
    }

    pub fn closeOptions(c: *Call, dict: *MessageIter) void {
        c.truncated = c.truncated or 0 == c.api.message_iter_close_container(&c.args, dict);
    }

    /// One `{sv}` entry whose value is a string.
    pub fn optionString(c: *Call, dict: *MessageIter, key: [*:0]const u8, value: [*:0]const u8) void {
        var entry: MessageIter = .{};
        c.truncated = c.truncated or 0 == c.api.message_iter_open_container(dict, Type.dict_entry, null, &entry);
        var k: [*:0]const u8 = key;
        c.truncated = c.truncated or 0 == c.api.message_iter_append_basic(&entry, Type.string, @ptrCast(&k));
        var variant: MessageIter = .{};
        c.truncated = c.truncated or 0 == c.api.message_iter_open_container(&entry, Type.variant, "s", &variant);
        var v: [*:0]const u8 = value;
        c.truncated = c.truncated or 0 == c.api.message_iter_append_basic(&variant, Type.string, @ptrCast(&v));
        c.truncated = c.truncated or 0 == c.api.message_iter_close_container(&entry, &variant);
        c.truncated = c.truncated or 0 == c.api.message_iter_close_container(dict, &entry);
    }

    /// One `{sv}` entry whose value is a u32, which is how the portal takes the
    /// source kinds and the cursor mode.
    pub fn optionU32(c: *Call, dict: *MessageIter, key: [*:0]const u8, value: u32) void {
        var entry: MessageIter = .{};
        c.truncated = c.truncated or 0 == c.api.message_iter_open_container(dict, Type.dict_entry, null, &entry);
        var k: [*:0]const u8 = key;
        c.truncated = c.truncated or 0 == c.api.message_iter_append_basic(&entry, Type.string, @ptrCast(&k));
        var variant: MessageIter = .{};
        c.truncated = c.truncated or 0 == c.api.message_iter_open_container(&entry, Type.variant, "u", &variant);
        var v: u32 = value;
        c.truncated = c.truncated or 0 == c.api.message_iter_append_basic(&variant, Type.uint32, @ptrCast(&v));
        c.truncated = c.truncated or 0 == c.api.message_iter_close_container(&entry, &variant);
        c.truncated = c.truncated or 0 == c.api.message_iter_close_container(dict, &entry);
    }

    pub fn optionBool(c: *Call, dict: *MessageIter, key: [*:0]const u8, value: bool) void {
        var entry: MessageIter = .{};
        c.truncated = c.truncated or 0 == c.api.message_iter_open_container(dict, Type.dict_entry, null, &entry);
        var k: [*:0]const u8 = key;
        c.truncated = c.truncated or 0 == c.api.message_iter_append_basic(&entry, Type.string, @ptrCast(&k));
        var variant: MessageIter = .{};
        c.truncated = c.truncated or 0 == c.api.message_iter_open_container(&entry, Type.variant, "b", &variant);
        var v: c_int = if (value) 1 else 0;
        c.truncated = c.truncated or 0 == c.api.message_iter_append_basic(&variant, Type.boolean, @ptrCast(&v));
        c.truncated = c.truncated or 0 == c.api.message_iter_close_container(&entry, &variant);
        c.truncated = c.truncated or 0 == c.api.message_iter_close_container(dict, &entry);
    }

    /// Sends and blocks for the reply. The caller owns the reply and unrefs it.
    pub fn send(c: *Call, bus: *Bus, timeout_ms: c_int) Error!*anyopaque {
        if (c.truncated) return error.CallFailed;
        return bus.api.connection_send_with_reply_and_block(bus.conn, c.msg, timeout_ms, null) orelse error.CallFailed;
    }
};

/// The first string argument of a message, copied into the caller's buffer. The
/// portal answers handles and file URIs this way, and a handle is the path every
/// later signal is keyed on.
pub fn firstString(a: *Api, msg: *anyopaque, out: []u8) ?[]const u8 {
    var it: MessageIter = .{};
    if (a.message_iter_init(msg, &it) == 0) return null;
    const kind = a.message_iter_get_arg_type(&it);
    if (kind != Type.string and kind != Type.object_path) return null;
    var raw: ?[*:0]const u8 = null;
    a.message_iter_get_basic(&it, @ptrCast(&raw));
    const value = raw orelse return null;
    const text = std.mem.span(value);
    const len = @min(text.len, out.len);
    @memcpy(out[0..len], text[0..len]);
    return out[0..len];
}

/// Walks a portal Response signal for one `a{sv}` result key whose value is a
/// string. The signal is `(u response, a{sv} results)`, so the dictionary is the
/// second argument and the response code is the first.
pub fn responseString(a: *Api, msg: *anyopaque, key: []const u8, out: []u8) ?[]const u8 {
    var it: MessageIter = .{};
    if (a.message_iter_init(msg, &it) == 0) return null;
    if (a.message_iter_get_arg_type(&it) != Type.uint32) return null;
    var code: u32 = 1;
    a.message_iter_get_basic(&it, @ptrCast(&code));
    // Non-zero is the person having said no, or the portal having given up. Either
    // way there is no result to read.
    if (code != 0) return null;
    if (a.message_iter_next(&it) == 0) return null;
    if (a.message_iter_get_arg_type(&it) != Type.array) return null;

    var dict: MessageIter = .{};
    a.message_iter_recurse(&it, &dict);
    while (a.message_iter_get_arg_type(&dict) == Type.dict_entry) {
        var entry: MessageIter = .{};
        a.message_iter_recurse(&dict, &entry);
        var raw_key: ?[*:0]const u8 = null;
        a.message_iter_get_basic(&entry, @ptrCast(&raw_key));
        const this_key = if (raw_key) |k| std.mem.span(k) else "";
        if (std.mem.eql(u8, this_key, key) and a.message_iter_next(&entry) != 0) {
            var variant: MessageIter = .{};
            a.message_iter_recurse(&entry, &variant);
            if (a.message_iter_get_arg_type(&variant) == Type.string) {
                var raw_value: ?[*:0]const u8 = null;
                a.message_iter_get_basic(&variant, @ptrCast(&raw_value));
                if (raw_value) |v| {
                    const text = std.mem.span(v);
                    const len = @min(text.len, out.len);
                    @memcpy(out[0..len], text[0..len]);
                    return out[0..len];
                }
            }
        }
        if (a.message_iter_next(&dict) == 0) break;
    }
    return null;
}

/// The path part of a `file://` URI, with percent escapes undone. The portal hands
/// back a URI and a file is opened by path, so this is the one conversion between.
pub fn pathFromFileUri(uri: []const u8, out: []u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];
    // An authority of "localhost" is allowed and means this machine.
    if (std.mem.startsWith(u8, rest, "localhost/")) rest = rest["localhost".len..];
    if (rest.len == 0 or rest[0] != '/') return null;

    var written: usize = 0;
    var at: usize = 0;
    while (at < rest.len) {
        if (written >= out.len) return null;
        if (rest[at] == '%' and at + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[at + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(rest[at + 2], 16) catch return null;
            out[written] = @intCast(hi * 16 + lo);
            written += 1;
            at += 3;
            continue;
        }
        out[written] = rest[at];
        written += 1;
        at += 1;
    }
    return out[0..written];
}

const t = std.testing;

test "a file uri becomes a path, with escapes undone" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("/tmp/shot.png", pathFromFileUri("file:///tmp/shot.png", &buf).?);
    // The portal writes into a run directory whose name can carry spaces.
    try t.expectEqualStrings("/run/user/1000/a b.png", pathFromFileUri("file:///run/user/1000/a%20b.png", &buf).?);
    // localhost is a legal authority and means this machine.
    try t.expectEqualStrings("/tmp/x.png", pathFromFileUri("file://localhost/tmp/x.png", &buf).?);
    // Anything that is not a file URI is not a path.
    try t.expect(pathFromFileUri("https://example.com/x.png", &buf) == null);
    try t.expect(pathFromFileUri("file://", &buf) == null);
}

test "a truncating buffer refuses rather than writing a half path" {
    var small: [4]u8 = undefined;
    try t.expect(pathFromFileUri("file:///tmp/shot.png", &small) == null);
}

test "the iterator block is the size libdbus documents" {
    // libdbus allocates DBusMessageIter in the caller's frame, so its size is part
    // of the ABI: too small and libdbus writes past what this reserved.
    try t.expect(@sizeOf(MessageIter) >= 56);
    try t.expectEqual(@alignOf(usize), @alignOf(MessageIter));
}
