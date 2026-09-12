//! The MCP server's stdio loop. One JSON object per line in, one per line out,
//! which is what every MCP client over stdio expects. The protocol shapes live
//! next door in server.zig so they are testable without a process.

const std = @import("std");
const server = @import("server.zig");
const abi = @import("abi");

/// The engine and session the tools run against, made on the first call that
/// needs one. A client that only lists tools pays for no renderer, and a host
/// with no renderer still gets the tools that do not need one.
const Live = struct {
    engine: ?*abi.Engine = null,
    session: ?*abi.Session = null,

    fn engineOrNull(live: *Live) ?*abi.Engine {
        if (live.engine) |e| return e;
        live.engine = abi.createEngine(std.heap.smp_allocator, .{ .texture_pool_capacity = 8, .staging_pool_capacity = 8 }) catch return null;
        return live.engine;
    }

    fn sessionOrNull(live: *Live) ?*abi.Session {
        if (live.session) |s| return s;
        const engine = live.engineOrNull() orelse return null;
        live.session = abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 }) catch return null;
        return live.session;
    }
};

/// The biggest message this reads. An MCP client sends tool arguments, not
/// payloads, so a line past this is a client doing something else.
const max_line = 1 << 20;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var stdin_buffer: [8192]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    var live: Live = .{};
    defer {
        if (live.session) |s| abi.goss_session_destroy(s);
        if (live.engine) |e| abi.goss_engine_destroy(e);
    }

    while (true) {
        // Inclusive, so the newline is consumed with the line. The exclusive
        // form leaves it in the buffer and every later read comes back empty,
        // which is a loop that never advances.
        const line = stdin.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            error.StreamTooLong => {
                // A line past the bound is skipped rather than parsed in pieces,
                // which would turn one bad message into several.
                continue;
            },
            else => return err,
        };
        if (line.len == 0) continue;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        const request = parse(arena, trimmed) catch {
            try respondError(&stdout.interface, null, -32700, "the message is not json this server can read");
            continue;
        };

        // A notification carries no id and takes no reply, which is how
        // notifications/initialized is meant to be handled.
        if (std.mem.startsWith(u8, request.method, "notifications/")) continue;

        if (std.mem.eql(u8, request.method, "initialize")) {
            try respondRaw(&stdout.interface, request.id, writeInitialize);
            continue;
        }
        if (std.mem.eql(u8, request.method, "ping")) {
            try respondRaw(&stdout.interface, request.id, writeEmpty);
            continue;
        }
        if (std.mem.eql(u8, request.method, "tools/list")) {
            try respondRaw(&stdout.interface, request.id, server.writeToolList);
            continue;
        }
        if (std.mem.eql(u8, request.method, "resources/list")) {
            try respondRaw(&stdout.interface, request.id, writeEmptyResources);
            continue;
        }
        if (std.mem.eql(u8, request.method, "tools/call")) {
            const name = request.tool_name orelse {
                try respondError(&stdout.interface, request.id, -32602, "tools/call needs a name");
                continue;
            };
            if (server.toolNamed(name) == null) {
                try respondError(&stdout.interface, request.id, -32602, "this server has no such tool");
                continue;
            }
            var out: std.Io.Writer.Allocating = .init(arena);
            const failed = runTool(&live, arena, name, request.arguments, &out.writer) catch |err| blk: {
                try out.writer.print("the tool failed: {t}", .{err});
                break :blk true;
            };
            try stdout.interface.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":", .{request.id orelse 0});
            try server.writeToolResult(&stdout.interface, out.writer.buffered(), failed);
            try stdout.interface.writeAll("}\n");
            try stdout.interface.flush();
            continue;
        }
        try respondError(&stdout.interface, request.id, -32601, "this server does not implement that method");
    }
    return 0;
}

const Request = struct {
    method: []const u8,
    id: ?i64,
    tool_name: ?[]const u8,
    arguments: ?std.json.Value,
};

/// Runs one tool, and answers whether it failed. What it writes is what a model
/// reads either way: a missing precondition is an answer, an empty result is not.
fn runTool(live: *Live, arena: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    if (std.mem.eql(u8, name, "model_support")) return modelSupport(arena, arguments, w);
    if (std.mem.eql(u8, name, "engine_report")) return engineReport(live, w);
    if (std.mem.eql(u8, name, "remember")) return remember(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "search_memory")) return searchMemory(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "read_perception")) return readPerception(arena, live, w);
    if (std.mem.eql(u8, name, "read_text")) return readText(live, w);
    if (std.mem.eql(u8, name, "open_screen")) return openScreen(live, arguments, w);
    if (std.mem.eql(u8, name, "screen_point")) return screenPoint(live, arguments, w);
    if (std.mem.eql(u8, name, "open_clip")) return openClip(live, arguments, w);
    if (std.mem.eql(u8, name, "annotate")) return annotate(arena, live, arguments, w);
    try w.print("{s} is declared and not wired", .{name});
    return true;
}

fn modelSupport(arena: std.mem.Allocator, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const path = stringArg(arguments, "path") orelse {
        try w.writeAll("model_support needs a path");
        return true;
    };
    const bytes = std.fs.cwd().readFileAlloc(arena, path, 512 << 20) catch {
        try w.print("cannot read {s}", .{path});
        return true;
    };
    var missing: [4096]u8 = undefined;
    var needed: usize = 0;
    if (abi.goss_ml_op_support(bytes.ptr, bytes.len, &missing, missing.len, &needed) != .ok) {
        try w.print("{s} is not a model this build can read", .{path});
        return true;
    }
    if (needed == 0) {
        try w.print("{s} needs no operator this build lacks", .{path});
        return false;
    }
    try w.print("{s} needs operators this build lacks: {s}", .{ path, missing[0..@min(needed, missing.len)] });
    return false;
}

fn engineReport(live: *Live, w: *std.Io.Writer) !bool {
    const engine = live.engineOrNull() orelse {
        try w.writeAll("no engine on this host");
        return true;
    };
    var report: abi.EngineReport = undefined;
    if (abi.goss_engine_read_report(engine, &report) != .ok) {
        try w.writeAll("the engine would not report");
        return true;
    }
    try w.print(
        "renderer backend {d}; textures {d} of {d} live, peak {d}, {d} exhausted; staging {d} of {d} live, peak {d}; vendor heap {d} bytes",
        .{
            report.renderer_backend,      report.texture_pool_live, report.texture_pool_capacity,
            report.texture_pool_peak,     report.texture_pool_exhausted,
            report.staging_pool_live,     report.staging_pool_capacity, report.staging_pool_peak,
            report.bgfx_live_bytes,
        },
    );
    if (live.session) |s| {
        var session_report: abi.SessionReport = undefined;
        if (abi.goss_session_read_report(s, &session_report) == .ok) {
            try w.print("; {d} frames submitted, {d} rendered, degrade level {d}", .{
                session_report.frames_submitted, session_report.frames_rendered, session_report.degrade_level,
            });
        }
    }
    return false;
}

fn remember(arena: std.mem.Allocator, live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const id = intArg(arguments, "id") orelse {
        try w.writeAll("remember needs an id");
        return true;
    };
    const values = try floatsArg(arena, arguments, "embedding") orelse {
        try w.writeAll("remember needs an embedding");
        return true;
    };
    if (values.len == 0) {
        try w.writeAll("the embedding is empty");
        return true;
    }
    // Opened on the first remember at the width that arrived, so a caller does
    // not declare a dimension it has already shown.
    _ = abi.goss_session_memory_open(s, @intCast(values.len), 4096);
    const status = abi.goss_session_memory_remember(s, @bitCast(id), values.ptr, @intCast(values.len));
    if (status != .ok) {
        try w.print("the memory refused it: {t}", .{status});
        return true;
    }
    try w.print("remembered {d} at {d} dimensions", .{ id, values.len });
    return false;
}

fn searchMemory(arena: std.mem.Allocator, live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const values = try floatsArg(arena, arguments, "embedding") orelse {
        try w.writeAll("search_memory needs an embedding");
        return true;
    };
    var ids: [32]u64 = undefined;
    var scores: [32]f32 = undefined;
    var count: u32 = 0;
    const want: u32 = @intCast(@min(ids.len, @max(1, intArg(arguments, "k") orelse 8)));
    const status = abi.goss_session_memory_search(s, values.ptr, @intCast(values.len), want, &ids, &scores, &count);
    if (status != .ok) {
        try w.print("the memory would not answer: {t}", .{status});
        return true;
    }
    if (count == 0) {
        try w.writeAll("the memory holds nothing like it");
        return false;
    }
    for (0..count) |i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{d} at {d:.4}", .{ ids[i], scores[i] });
    }
    return false;
}

fn readPerception(arena: std.mem.Allocator, live: *Live, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    // The json projection, because a model reads text. The mask comes from the
    // engine rather than from here, and the session narrows it to its own scope.
    const select = abi.goss_perception_select_all();
    var needed: usize = 0;
    _ = abi.goss_session_perception_json(s, select, null, 0, &needed);
    if (needed == 0) {
        try w.writeAll("the engine has seen nothing yet; submit a frame first");
        return true;
    }
    const buffer = try arena.alloc(u8, needed);
    if (abi.goss_session_perception_json(s, select, buffer.ptr, buffer.len, &needed) != .ok) {
        try w.writeAll("the record would not project");
        return true;
    }
    try w.writeAll(buffer[0..@min(needed, buffer.len)]);
    return false;
}

fn readText(live: *Live, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    var count: u32 = 0;
    var refused: u64 = 0;
    if (abi.goss_session_text_count(s, &count, &refused) != .ok) {
        try w.writeAll("the text rail is not enabled on this session");
        return true;
    }
    if (count == 0) {
        try w.writeAll("the frame says nothing");
        return false;
    }
    for (0..count) |i| {
        var entry: abi.TextEntry = undefined;
        if (abi.goss_session_text_at(s, @intCast(i), &entry) != .ok) continue;
        var text: [512]u8 = undefined;
        var text_len: usize = 0;
        _ = abi.goss_session_text_string(s, @intCast(i), &text, text.len, &text_len);
        if (i != 0) try w.writeAll("\n");
        try w.print("\"{s}\" at {d:.3},{d:.3} track {d} confidence {d:.2}", .{
            text[0..@min(text_len, text.len)], entry.quad[0], entry.quad[1], entry.track_id, entry.confidence,
        });
    }
    if (refused != 0) try w.print("\n{d} refused for want of room", .{refused});
    return false;
}

fn openScreen(live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const engine = live.engineOrNull().?;
    var count: u32 = 0;
    if (abi.goss_engine_screen_count(engine, &count) != .ok or count == 0) {
        try w.writeAll("no surface is available: this host has granted no screen capture, or the platform offers none");
        return true;
    }
    var surface: abi.ScreenSurface = undefined;
    if (abi.goss_engine_screen_at(engine, 0, &surface) != .ok) {
        try w.writeAll("the host listed a surface it would not describe");
        return true;
    }
    const wanted: u64 = if (intArg(arguments, "surface_id")) |id| @bitCast(id) else surface.id;
    var screen: u32 = 0;
    const status = abi.goss_session_open_screen(s, wanted, surface.scale, &screen);
    if (status != .ok) {
        try w.print("the screen would not open: {t}", .{status});
        return true;
    }
    try w.print("screen {d} open at {d:.0}x{d:.0} logical, scale {d:.2}, origin {d:.0},{d:.0}", .{
        screen, surface.logical_width, surface.logical_height, surface.scale, surface.origin_x, surface.origin_y,
    });
    return false;
}

fn screenPoint(live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const screen: u32 = @intCast(@max(0, intArg(arguments, "screen") orelse 0));
    const x = floatArg(arguments, "x") orelse 0.5;
    const y = floatArg(arguments, "y") orelse 0.5;
    var logical: [2]f32 = undefined;
    var pixel: [2]f32 = undefined;
    var desktop: [2]f32 = undefined;
    if (abi.goss_session_screen_point(s, screen, x, y, &logical, &pixel, &desktop) != .ok) {
        try w.writeAll("that screen is not open, or the point is off it");
        return true;
    }
    try w.print("logical {d:.1},{d:.1}; pixels {d:.1},{d:.1}; desktop {d:.1},{d:.1}", .{
        logical[0], logical[1], pixel[0], pixel[1], desktop[0], desktop[1],
    });
    return false;
}

fn openClip(live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const path = stringArg(arguments, "path") orelse {
        try w.writeAll("open_clip needs a path");
        return true;
    };
    var clip: u32 = 0;
    const status = abi.goss_session_open_clip(s, path.ptr, path.len, &clip);
    if (status != .ok) {
        try w.print("that clip would not open: {t}", .{status});
        return true;
    }
    try w.print("clip {d} open from {s}", .{ clip, path });
    return false;
}

fn annotate(arena: std.mem.Allocator, live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const id = intArg(arguments, "id") orelse {
        try w.writeAll("annotate needs an id");
        return true;
    };
    // An overlay nobody removes is the failure mode, so one placed through this
    // server lasts a bounded number of frames unless the caller says otherwise.
    var desc = std.mem.zeroes(abi.AnnotationDesc);
    desc.id = @intCast(@max(0, id));
    desc.kind = @intCast(@max(0, intArg(arguments, "kind") orelse 0));
    desc.colour = .{ 255, 255, 255, 255 };
    desc.opacity = 1;
    desc.lifetime_kind = 1;
    desc.lifetime_value = intArg(arguments, "frames") orelse 120;
    if (try floatsArg(arena, arguments, "rect")) |rect| {
        for (0..@min(rect.len, 4)) |i| desc.rect[i] = rect[i];
    }
    const text = stringArg(arguments, "text") orelse "";
    const status = abi.goss_session_annotate(s, &desc, if (text.len == 0) null else text.ptr, text.len);
    if (status != .ok) {
        try w.print("the annotation was refused: {t}", .{status});
        return true;
    }
    try w.print("annotation {d} placed for {d} frames", .{ desc.id, desc.lifetime_value });
    return false;
}

fn stringArg(arguments: ?std.json.Value, key: []const u8) ?[]const u8 {
    const object = objectArgs(arguments) orelse return null;
    const v = object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn intArg(arguments: ?std.json.Value, key: []const u8) ?i64 {
    const object = objectArgs(arguments) orelse return null;
    const v = object.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        else => null,
    };
}

fn floatArg(arguments: ?std.json.Value, key: []const u8) ?f32 {
    const object = objectArgs(arguments) orelse return null;
    const v = object.get(key) orelse return null;
    return switch (v) {
        .float => @floatCast(v.float),
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

fn floatsArg(arena: std.mem.Allocator, arguments: ?std.json.Value, key: []const u8) !?[]f32 {
    const object = objectArgs(arguments) orelse return null;
    const v = object.get(key) orelse return null;
    if (v != .array) return null;
    const out = try arena.alloc(f32, v.array.items.len);
    for (v.array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => @floatCast(item.float),
            .integer => @floatFromInt(item.integer),
            else => 0,
        };
    }
    return out;
}

fn objectArgs(arguments: ?std.json.Value) ?std.json.ObjectMap {
    const args = arguments orelse return null;
    return if (args == .object) args.object else null;
}

/// Reads just the three things this server acts on. A full parse is not needed
/// to route a message, and a smaller reader is a smaller surface for a client
/// that sends something strange.
fn parse(arena: std.mem.Allocator, text: []const u8) !Request {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
    const root = parsed.value;
    if (root != .object) return error.BadMessage;
    const method = root.object.get("method") orelse return error.BadMessage;
    if (method != .string) return error.BadMessage;

    var id: ?i64 = null;
    if (root.object.get("id")) |v| {
        if (v == .integer) id = v.integer;
    }
    var tool_name: ?[]const u8 = null;
    var arguments: ?std.json.Value = null;
    if (root.object.get("params")) |params| {
        if (params == .object) {
            if (params.object.get("name")) |n| {
                if (n == .string) tool_name = n.string;
            }
            arguments = params.object.get("arguments");
        }
    }
    return .{ .method = method.string, .id = id, .tool_name = tool_name, .arguments = arguments };
}

fn writeInitialize(w: *std.Io.Writer) !void {
    try server.writeServerInfo(w, abi.abi_major, abi.abi_minor);
}

fn writeEmpty(w: *std.Io.Writer) !void {
    try w.writeAll("{}");
}

fn writeEmptyResources(w: *std.Io.Writer) !void {
    try w.writeAll("{\"resources\":[]}");
}

fn respondRaw(w: *std.Io.Writer, id: ?i64, body: *const fn (*std.Io.Writer) anyerror!void) !void {
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":", .{id orelse 0});
    try body(w);
    try w.writeAll("}\n");
    try w.flush();
}

fn respondError(w: *std.Io.Writer, id: ?i64, code: i32, message: []const u8) !void {
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":", .{id orelse 0});
    try server.writeError(w, code, message);
    try w.writeAll("}\n");
    try w.flush();
}
