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
    io: std.Io,
    engine: ?*abi.Engine = null,
    session: ?*abi.Session = null,
    /// Rising, because a frame and a world both carry one and a timestamp that
    /// never moves reads as the same submission twice.
    stamp_us: i64 = 0,
    /// Whether a renderer came up on this host, which is what a frame needs.
    renderer_up: bool = false,

    fn nextTimestamp(live: *Live) i64 {
        live.stamp_us += 33_333;
        return live.stamp_us;
    }

    fn engineOrNull(live: *Live) ?*abi.Engine {
        if (live.engine) |e| return e;
        const engine = abi.createEngine(std.heap.smp_allocator, .{ .texture_pool_capacity = 8, .staging_pool_capacity = 8 }) catch return null;
        // A frame becomes a texture, so it needs a renderer. There is no window
        // here, which bgfx accepts: where the host gives one, every frame tool is
        // real, and where it does not, the tools that need one say so by name.
        const desc: abi.RendererDesc = .{ .native_window_handle = null, .width = 64, .height = 64 };
        live.renderer_up = abi.goss_engine_init_renderer(engine, &desc) == .ok;
        live.engine = engine;
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

    var live: Live = .{ .io = init.io };
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
    if (std.mem.eql(u8, name, "model_support")) return modelSupport(live, arena, arguments, w);
    if (std.mem.eql(u8, name, "engine_report")) return engineReport(live, w);
    if (std.mem.eql(u8, name, "remember")) return remember(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "search_memory")) return searchMemory(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "read_perception")) return readPerception(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "read_text")) return readText(live, w);
    if (std.mem.eql(u8, name, "open_screen")) return openScreen(live, arguments, w);
    if (std.mem.eql(u8, name, "screen_point")) return screenPoint(live, arguments, w);
    if (std.mem.eql(u8, name, "open_clip")) return openClip(live, arguments, w);
    if (std.mem.eql(u8, name, "annotate")) return annotate(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "submit_image")) return submitImage(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "submit_world")) return submitWorld(live, arguments, w);
    if (std.mem.eql(u8, name, "submit_world_mesh")) return submitWorldMesh(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "floor_plane")) return floorPlane(live, w);
    if (std.mem.eql(u8, name, "place_on")) return placeOn(live, arguments, w);
    if (std.mem.eql(u8, name, "measure_between")) return measureBetween(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "path_across_world")) return pathAcrossWorld(arena, live, arguments, w);
    if (std.mem.eql(u8, name, "align_shared")) return alignShared(live, arguments, w);
    try w.print("{s} is declared and not wired", .{name});
    return true;
}

fn modelSupport(live: *Live, arena: std.mem.Allocator, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const path = stringArg(arguments, "path") orelse {
        try w.writeAll("model_support needs a path");
        return true;
    };
    const bytes = std.Io.Dir.cwd().readFileAlloc(live.io, path, arena, .limited(512 << 20)) catch {
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
            // What a model rail costs and whether it is steady, which is the
            // difference between a reading an agent can plan against and a byte
            // count that happens to be true this frame.
            try w.print("; model plan {d} bytes, {d} growths", .{
                session_report.ml_plan_bytes, session_report.ml_plan_growths,
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

/// The sections the caller named, or every one when it named none. A name this
/// build does not know is skipped rather than failing the read, so a newer agent
/// asking for a section this engine lacks still gets the ones it has.
fn selectFrom(arguments: ?std.json.Value) u32 {
    const names = arrayArg(arguments, "sections") orelse return abi.goss_perception_select_all();
    var mask: u32 = 0;
    for (names) |value| {
        const name = switch (value) {
            .string => |text| text,
            else => continue,
        };
        inline for (comptime std.meta.fieldNames(abi.PerceptionSelect), 0..) |field, bit| {
            if (comptime std.mem.startsWith(u8, field, "_")) continue;
            if (std.mem.eql(u8, name, field)) mask |= @as(u32, 1) << @intCast(bit);
        }
    }
    // An empty or wholly unrecognised list is a caller asking for nothing, which is not
    // an answer; give it everything rather than an empty record it cannot read.
    return if (mask == 0) abi.goss_perception_select_all() else mask;
}

fn readPerception(arena: std.mem.Allocator, live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    // The json projection, because a model reads text. The mask comes from the
    // engine rather than from here, and the session narrows it to its own scope.
    const select = selectFrom(arguments);
    var needed: usize = 0;
    _ = abi.goss_session_perception_json(s, select, null, 0, &needed);
    if (needed == 0) {
        try w.writeAll("the record is empty, which means the session's scope allows no section");
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
    // The scale the caller asked for, which the schema declares and this ignored: an
    // agent setting it got the surface's own scale and no word that its number was
    // dropped. Zero still means the surface's own, as the schema says.
    const asked_scale = floatArg(arguments, "scale") orelse 0;
    const scale = if (asked_scale > 0) asked_scale else surface.scale;
    var screen: u32 = 0;
    const status = abi.goss_session_open_screen(s, wanted, scale, &screen);
    if (status != .ok) {
        try w.print("the screen would not open: {t}", .{status});
        return true;
    }
    try w.print("screen {d} open at {d:.0}x{d:.0} logical, scale {d:.2}, origin {d:.0},{d:.0}", .{
        screen, surface.logical_width, surface.logical_height, scale, surface.origin_x, surface.origin_y,
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
    // A box by default, which is kind one. Defaulting to zero meant the engine's
    // "no such kind" value, so an agent omitting it asked for nothing drawable.
    desc.kind = @intCast(@max(1, intArg(arguments, "kind") orelse 1));
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

/// A PNG as the session's frame. Without this the server had a session nothing
/// had ever fed, so every tool that reads a frame answered that it had none: the
/// protocol is the input path, the same way a clip arrives as a path.
fn submitImage(arena: std.mem.Allocator, live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const path = stringArg(arguments, "path") orelse {
        try w.writeAll("submit_image needs a path");
        return true;
    };
    const bytes = std.Io.Dir.cwd().readFileAlloc(live.io, path, arena, .limited(256 << 20)) catch {
        try w.print("cannot read {s}", .{path});
        return true;
    };
    // Decoded through the engine rather than here: the decoder it carries for its
    // own assets is the one every caller should reach, and a second copy of a
    // module in one compile is a collision this repo has a rule about.
    var width: u32 = 0;
    var height: u32 = 0;
    var needed: usize = 0;
    _ = abi.goss_engine_decode_png(bytes.ptr, bytes.len, null, 0, &width, &height, &needed);
    if (needed == 0) {
        try w.print("{s} is not a png the engine can read; it decodes png, so a jpeg has to be converted first", .{path});
        return true;
    }
    const rgba = try arena.alloc(u8, needed);
    if (abi.goss_engine_decode_png(bytes.ptr, bytes.len, rgba.ptr, rgba.len, &width, &height, &needed) != .ok) {
        try w.print("{s} would not decode", .{path});
        return true;
    }
    var desc = std.mem.zeroes(abi.FrameDesc);
    desc.width = width;
    desc.height = height;
    // 4 is rgba8, which is what the decoder writes. The header names them.
    desc.pixel_format = 4;
    desc.color_range = 1;
    desc.timestamp_us = live.nextTimestamp();
    const status = abi.goss_session_submit_frame_rgba_copy(s, &desc, rgba.ptr, width * 4);
    if (status == .renderer_unavailable or !live.renderer_up) {
        try w.writeAll("this host would not bring up a renderer, and a frame becomes a texture, so nothing that reads a frame will answer here");
        return true;
    }
    if (status != .ok) {
        try w.print("the frame was refused: {t}", .{status});
        return true;
    }
    try w.print("submitted {d}x{d} from {s}", .{ width, height, path });
    return false;
}

/// The room: planes and anchors, which is what every spatial answer is computed
/// over. A caller with no platform world session submits what it knows.
fn submitWorld(live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    var planes: [32]abi.WorldPlane = undefined;
    var plane_count: usize = 0;
    if (arrayArg(arguments, "planes")) |items| {
        for (items) |item| {
            if (plane_count >= planes.len) break;
            if (item != .object) continue;
            const fields = item.object;
            var pose = identity16;
            pose[12] = numberFrom(fields.get("x")) orelse 0;
            pose[13] = numberFrom(fields.get("y")) orelse 0;
            pose[14] = numberFrom(fields.get("z")) orelse 0;
            planes[plane_count] = .{
                .id = @intFromFloat(@max(0, numberFrom(fields.get("id")) orelse 0)),
                .pose = pose,
                .extent_x = numberFrom(fields.get("extent_x")) orelse 1,
                .extent_z = numberFrom(fields.get("extent_z")) orelse 1,
                .classification = @intFromFloat(@max(0, numberFrom(fields.get("kind")) orelse 0)),
            };
            plane_count += 1;
        }
    }
    var anchors: [32]abi.WorldAnchor = undefined;
    var anchor_count: usize = 0;
    if (arrayArg(arguments, "anchors")) |items| {
        for (items) |item| {
            if (anchor_count >= anchors.len) break;
            if (item != .object) continue;
            const fields = item.object;
            var pose = identity16;
            pose[12] = numberFrom(fields.get("x")) orelse 0;
            pose[13] = numberFrom(fields.get("y")) orelse 0;
            pose[14] = numberFrom(fields.get("z")) orelse 0;
            anchors[anchor_count] = .{
                .id = @intFromFloat(@max(0, numberFrom(fields.get("id")) orelse 0)),
                .pose = pose,
            };
            anchor_count += 1;
        }
    }
    if (plane_count == 0 and anchor_count == 0) {
        try w.writeAll("submit_world needs planes, anchors, or both");
        return true;
    }
    const state: abi.WorldState = .{
        .tracking_state = 2,
        .world_from_camera = identity16,
        .projection = identity16,
        .timestamp_us = live.nextTimestamp(),
    };
    const status = abi.goss_session_submit_world(
        s,
        &state,
        if (plane_count == 0) null else &planes,
        plane_count,
        if (anchor_count == 0) null else &anchors,
        anchor_count,
        null,
    );
    if (status != .ok) {
        try w.print("the room was refused: {t}", .{status});
        return true;
    }
    try w.print("submitted {d} planes and {d} anchors", .{ plane_count, anchor_count });
    return false;
}

fn submitWorldMesh(arena: std.mem.Allocator, live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const vertices = try floatsArg(arena, arguments, "vertices") orelse {
        try w.writeAll("submit_world_mesh needs vertices");
        return true;
    };
    const index_floats = try floatsArg(arena, arguments, "indices") orelse {
        try w.writeAll("submit_world_mesh needs indices");
        return true;
    };
    if (vertices.len % 3 != 0 or index_floats.len % 3 != 0) {
        try w.writeAll("vertices come in threes and indices in triangles");
        return true;
    }
    const indices = try arena.alloc(u32, index_floats.len);
    for (index_floats, 0..) |v, i| indices[i] = @intFromFloat(@max(0, v));
    const status = abi.goss_session_submit_world_mesh(s, vertices.ptr, vertices.len / 3, indices.ptr, indices.len);
    if (status != .ok) {
        try w.print("the mesh was refused: {t}", .{status});
        return true;
    }
    try w.print("submitted {d} vertices and {d} triangles", .{ vertices.len / 3, indices.len / 3 });
    return false;
}

fn floorPlane(live: *Live, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    var id: u64 = 0;
    if (abi.goss_session_floor_plane(s, &id) != .ok) {
        try w.writeAll("no surface a thing can rest on has been submitted yet");
        return true;
    }
    var kind: u32 = 0;
    var bearing: u32 = 0;
    _ = abi.goss_session_plane_kind(s, id, &kind, &bearing);
    try w.print("plane {d} is the floor, kind {d}", .{ id, kind });
    return false;
}

fn placeOn(live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    var item: abi.Footprint = .{
        .width = floatArg(arguments, "width") orelse 0,
        .depth = floatArg(arguments, "depth") orelse 0,
        .height = floatArg(arguments, "height") orelse 0,
    };
    if (!(item.width > 0) or !(item.depth > 0)) {
        try w.writeAll("place_on needs a width and a depth in metres");
        return true;
    }
    var occupants: [32]abi.Occupant = undefined;
    var occupant_count: usize = 0;
    if (arrayArg(arguments, "occupants")) |items| {
        for (items) |entry| {
            if (occupant_count >= occupants.len) break;
            if (entry != .object) continue;
            const fields = entry.object;
            occupants[occupant_count] = .{
                .plane_id = @intFromFloat(@max(0, numberFrom(fields.get("plane_id")) orelse 0)),
                .x = numberFrom(fields.get("x")) orelse 0,
                .z = numberFrom(fields.get("z")) orelse 0,
                .width = numberFrom(fields.get("width")) orelse 0,
                .depth = numberFrom(fields.get("depth")) orelse 0,
            };
            occupant_count += 1;
        }
    }
    var out: [16]abi.Placement = undefined;
    var found: usize = 0;
    const status = abi.goss_session_place_on(
        s,
        &item,
        if (occupant_count == 0) null else &occupants,
        occupant_count,
        &out,
        out.len,
        &found,
    );
    if (status != .ok and status != .again) {
        try w.print("the placement query was refused: {t}", .{status});
        return true;
    }
    if (found == 0) {
        try w.writeAll("nothing submitted can hold it");
        return false;
    }
    for (out[0..@min(found, out.len)], 0..) |p, i| {
        if (i != 0) try w.writeAll("\n");
        try w.print("plane {d} at {d:.2},{d:.2},{d:.2}, {d:.3} of it still free", .{
            p.plane_id, p.position[0], p.position[1], p.position[2], p.free_fraction,
        });
    }
    return false;
}

fn measureBetween(arena: std.mem.Allocator, live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const from = try floatsArg(arena, arguments, "from") orelse null;
    const to = try floatsArg(arena, arguments, "to") orelse null;
    if (from == null or to == null or from.?.len < 3 or to.?.len < 3) {
        try w.writeAll("measure_between needs two points of three numbers each");
        return true;
    }
    var metres: f32 = 0;
    var sigma: f32 = 0;
    var known: u32 = 0;
    const status = abi.goss_session_measure_between(
        s,
        from.?.ptr,
        floatArg(arguments, "from_accuracy_m") orelse 0,
        to.?.ptr,
        floatArg(arguments, "to_accuracy_m") orelse 0,
        &metres,
        &sigma,
        &known,
    );
    if (status != .ok) {
        try w.print("the measurement was refused: {t}", .{status});
        return true;
    }
    if (known == 0) {
        try w.print("{d:.4} metres, and nobody vouched for an accuracy, so the doubt is unbounded", .{metres});
        return false;
    }
    try w.print("{d:.4} metres, give or take {d:.4}", .{ metres, sigma });
    return false;
}

fn pathAcrossWorld(arena: std.mem.Allocator, live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    const start = try floatsArg(arena, arguments, "start") orelse null;
    const goal = try floatsArg(arena, arguments, "goal") orelse null;
    if (start == null or goal == null or start.?.len < 3 or goal.?.len < 3) {
        try w.writeAll("path_across_world needs a start and a goal of three numbers each");
        return true;
    }
    var points: [256 * 3]f32 = undefined;
    var count: usize = 0;
    // The op takes the two points as arrays of three, which is what it reads.
    const from: *const [3]f32 = start.?[0..3];
    const to: *const [3]f32 = goal.?[0..3];
    const status = abi.goss_session_path_across_world(s, from, to, &points, 256, &count);
    if (status != .ok) {
        try w.writeAll("no route: either no mesh has been submitted, or the ground does not connect those two points");
        return true;
    }
    for (0..@min(count, 256)) |i| {
        if (i != 0) try w.writeAll(" -> ");
        try w.print("{d:.2},{d:.2},{d:.2}", .{ points[i * 3], points[i * 3 + 1], points[i * 3 + 2] });
    }
    return false;
}

fn alignShared(live: *Live, arguments: ?std.json.Value, w: *std.Io.Writer) !bool {
    const s = live.sessionOrNull() orelse {
        try w.writeAll("no session on this host");
        return true;
    };
    var theirs: [64]abi.SharedLandmark = undefined;
    var count: usize = 0;
    if (arrayArg(arguments, "landmarks")) |items| {
        for (items) |entry| {
            if (count >= theirs.len) break;
            if (entry != .object) continue;
            const fields = entry.object;
            theirs[count] = .{
                .id = @intFromFloat(@max(0, numberFrom(fields.get("id")) orelse 0)),
                .x = numberFrom(fields.get("x")) orelse 0,
                .y = numberFrom(fields.get("y")) orelse 0,
                .z = numberFrom(fields.get("z")) orelse 0,
                .confidence = numberFrom(fields.get("confidence")) orelse 1,
            };
            count += 1;
        }
    }
    if (count == 0) {
        try w.writeAll("align_shared needs the other device's landmarks");
        return true;
    }
    var transform: [16]f32 = undefined;
    var rms: f32 = 0;
    var matched: u32 = 0;
    if (abi.goss_session_align_shared(s, &theirs, count, &transform, &rms, &matched) != .ok) {
        try w.print("no alignment: {d} of the {d} landmarks were recognised here, and three is the minimum that fixes a rigid transform", .{ matched, count });
        return true;
    }
    try w.print("aligned over {d} landmarks at {d:.5}m of residual; the other origin sits at {d:.3},{d:.3},{d:.3} in this one", .{
        matched, rms, transform[12], transform[13], transform[14],
    });
    return false;
}

/// A JSON array argument, for the tools that take a list of objects.
fn arrayArg(arguments: ?std.json.Value, key: []const u8) ?[]std.json.Value {
    const object = objectArgs(arguments) orelse return null;
    const v = object.get(key) orelse return null;
    return if (v == .array) v.array.items else null;
}

/// One number out of a JSON field, whichever way it was written.
fn numberFrom(value: ?std.json.Value) ?f32 {
    const v = value orelse return null;
    return switch (v) {
        .float => @floatCast(v.float),
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

const identity16: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

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
