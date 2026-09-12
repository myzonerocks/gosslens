//! The MCP protocol surface: the tool list, the server info, and the result and
//! error shapes a client reads. The stdio loop lives in main.zig; these shapes
//! are here so they are testable without a process.

const std = @import("std");

pub const protocol_version = "2025-06-18";
pub const server_name = "gosslens";

/// One callable thing, with the schema a client needs to call it. The schema is
/// written out rather than derived, because a client reads it before it has ever
/// run the tool and a wrong schema is a tool nobody can use.
const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// The JSON schema of the arguments, as a literal.
    schema: []const u8,
};

const tools = [_]Tool{
    .{
        .name = "open_clip",
        .description = "Open a video file as a source of frames. The graph cannot tell a clip from a camera, so everything else here works on it.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the video file."}},"required":["path"]}
        ,
    },
    .{
        .name = "read_perception",
        .description = "What the engine currently sees, as one record: the frame's geometry and timing, the faces, hands and bodies it found, what the frame says, and the engine's own state.",
        .schema =
        \\{"type":"object","properties":{"sections":{"type":"array","items":{"type":"string"},"description":"Which sections to read; omit for everything in scope."}}}
        ,
    },
    .{
        .name = "read_text",
        .description = "What the frame says: every recognised region with its quadrilateral, its confidence and a track id that survives a frame.",
        .schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "annotate",
        .description = "Draw back into the frame. An annotation is addressed by id, so moving one every frame leaks nothing, and carries a lifetime because the failure mode of an overlay is annotations nobody removed.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"integer"},"kind":{"type":"integer","description":"0 box, 1 label, 2 point."},"rect":{"type":"array","items":{"type":"number"},"minItems":4,"maxItems":4,"description":"Normalized left, top, width, height."},"text":{"type":"string"}},"required":["id","kind"]}
        ,
    },
    .{
        .name = "remember",
        .description = "Put an embedding into the memory plane under an id. The same id replaces rather than duplicating.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"integer"},"embedding":{"type":"array","items":{"type":"number"}}},"required":["id","embedding"]}
        ,
    },
    .{
        .name = "search_memory",
        .description = "The nearest remembered embeddings to a query, fewer than asked on a smaller memory rather than padded.",
        .schema =
        \\{"type":"object","properties":{"embedding":{"type":"array","items":{"type":"number"}},"k":{"type":"integer","default":8}},"required":["embedding"]}
        ,
    },
    .{
        .name = "model_support",
        .description = "Which operators a model needs that this build does not implement, so a failure is a precise list rather than the word unsupported.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
    },
    .{
        .name = "engine_report",
        .description = "What the engine is doing: the renderer backend, the pool high-water marks, how many frames it has drawn and how far it has degraded.",
        .schema =
        \\{"type":"object","properties":{}}
        ,
    },
};

/// A JSON string, escaped. Every string this server emits goes through here,
/// because a recognised sign is untrusted input and a quote in it must not end
/// the message.
fn writeJsonString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{ch}),
            else => try w.writeByte(ch),
        }
    }
    try w.writeByte('"');
}

/// The tool list, as the protocol wants it.
pub fn writeToolList(w: *std.Io.Writer) !void {
    try w.writeAll("{\"tools\":[");
    for (tools, 0..) |tool, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonString(w, tool.name);
        try w.writeAll(",\"description\":");
        try writeJsonString(w, tool.description);
        try w.writeAll(",\"inputSchema\":");
        try w.writeAll(tool.schema);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// The version is passed in rather than imported, so this file carries the
/// protocol and nothing else: its tests need no engine and no renderer.
pub fn writeServerInfo(w: *std.Io.Writer, major: u16, minor: u16) !void {
    try w.print(
        "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}},\"resources\":{{}}}},\"serverInfo\":{{\"name\":\"{s}\",\"version\":\"{d}.{d}\"}},\"instructions\":",
        .{ protocol_version, server_name, major, minor },
    );
    try writeJsonString(w,
        \\Tools over a gosslens session. Open a camera, a clip or a screen; read what the engine sees as one record; read what the frame says; search the memory plane; draw back into the frame. Everything runs on this device and no tool here sends a frame anywhere. A session's scope governs what each tool will answer.
    );
    try w.writeAll("}");
}

/// A tool's result, in the content shape the protocol specifies. isError is the
/// protocol's way of telling a model a call failed without failing the
/// transport, which is what lets it try something else.
pub fn writeToolResult(w: *std.Io.Writer, text: []const u8, is_error: bool) !void {
    try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.print("}}],\"isError\":{s}}}", .{if (is_error) "true" else "false"});
}

pub fn writeError(w: *std.Io.Writer, code: i32, message: []const u8) !void {
    try w.print("{{\"code\":{d},\"message\":", .{code});
    try writeJsonString(w, message);
    try w.writeAll("}");
}

pub fn toolNamed(name: []const u8) ?Tool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

const testing = std.testing;

test "the tool list is the shape a client reads before it calls anything" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeToolList(&out.writer);
    const text = out.writer.buffered();

    // Every tool named, each with a schema, and the whole thing one object.
    try testing.expect(std.mem.startsWith(u8, text, "{\"tools\":["));
    try testing.expect(std.mem.endsWith(u8, text, "]}"));
    for (tools) |tool| {
        try testing.expect(std.mem.indexOf(u8, text, tool.name) != null);
    }
    try testing.expectEqual(tools.len, std.mem.count(u8, text, "\"inputSchema\":"));
    // A tool with no description is a tool a model will misuse.
    for (tools) |tool| try testing.expect(tool.description.len > 40);
}

test "the server announces the version it speaks and the abi it is" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeServerInfo(&out.writer, 0, 152);
    const text = out.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, text, protocol_version) != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"tools\":{}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "gosslens") != null);
    // The instructions say what the tools do and where they run, which is what a
    // model reads before deciding whether to use any of them.
    try testing.expect(std.mem.indexOf(u8, text, "Tools over a gosslens session") != null);
    try testing.expect(std.mem.indexOf(u8, text, "no tool here sends a frame anywhere") != null);
}

test "a recognised sign with a quote in it stays valid json" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // What a camera saw is untrusted input: a quote must not end the message.
    try writeToolResult(&out.writer, "read \"SALE 50%\"\nline two", false);
    const text = out.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "\\\"SALE") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"isError\":false") != null);

    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    try writeToolResult(&err.writer, "no clip is open", true);
    try testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "\"isError\":true") != null);
}

test "an unknown tool is not a tool" {
    try testing.expect(toolNamed("read_text") != null);
    try testing.expect(toolNamed("rm_rf") == null);
}
