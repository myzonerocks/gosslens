//! The MCP server's stdio loop. One JSON object per line in, one per line out,
//! which is what every MCP client over stdio expects. The protocol shapes live
//! next door in server.zig so they are testable without a process.

const std = @import("std");
const server = @import("server.zig");
const abi = @import("abi");

/// The biggest message this reads. An MCP client sends tool arguments, not
/// payloads, so a line past this is a client doing something else.
const max_line = 1 << 20;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var stdin_buffer: [8192]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);

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

        // A notification has no id and takes no reply, which is how
        // notifications/initialized is meant to be handled.
        // A notification carries no id and takes no reply.
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
            // The tools reach the engine through the same C ABI every SDK uses.
            // Until a session is attached they report that rather than pretending.
            try stdout.interface.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":", .{request.id orelse 0});
            try server.writeToolResult(
                &stdout.interface,
                "no engine session is attached to this server yet; start gosslens with a session and call again",
                true,
            );
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
};

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
    if (root.object.get("params")) |params| {
        if (params == .object) {
            if (params.object.get("name")) |n| {
                if (n == .string) tool_name = n.string;
            }
        }
    }
    return .{ .method = method.string, .id = id, .tool_name = tool_name };
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
