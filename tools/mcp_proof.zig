//! Drives the built MCP server over a pipe the way a client does: every declared
//! tool called, the feeding ones first so the questions have something to answer
//! over. A server that lists tools and answers one sentence to all of them passes
//! a schema test and is useless to a model, and only running them says so.

const std = @import("std");

const requests = [_][]const u8{
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}
    ,
    \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ,
    \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    ,
    \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"remember","arguments":{"id":7,"embedding":[1,0,0,0]}}}
    ,
    \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_memory","arguments":{"embedding":[1,0,0,0],"k":3}}}
    ,
    \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"engine_report","arguments":{}}}
    ,
    \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"read_perception","arguments":{}}}
    ,
    \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_text","arguments":{}}}
    ,
    \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"annotate","arguments":{"id":3,"kind":1,"rect":[0.1,0.1,0.2,0.2],"text":"here"}}}
    ,
    \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"open_screen","arguments":{}}}
    ,
    \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"screen_point","arguments":{"screen":0,"x":0.5,"y":0.5}}}
    ,
    \\{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"open_clip","arguments":{"path":"third_party/models/does-not-exist.mp4"}}}
    ,
    \\{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"model_support","arguments":{"path":"third_party/models/does-not-exist.onnx"}}}
    ,
    \\{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}
    ,
    // The feeding tools, and then the questions that only answer once something has
    // been fed. A tool nobody drives is a tool nobody has proven.
    \\{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"submit_image","arguments":{"path":"sdk/ts/demo/res/lookup_origin.png"}}}
    ,
    \\{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"submit_world","arguments":{"planes":[{"id":10,"x":0,"y":0,"z":0,"extent_x":4,"extent_z":4,"kind":1},{"id":20,"x":0,"y":0.75,"z":0,"extent_x":1.2,"extent_z":0.8,"kind":4}],"anchors":[{"id":1,"x":0,"y":0,"z":0},{"id":2,"x":1,"y":0,"z":0},{"id":3,"x":0,"y":1,"z":0}]}}}
    ,
    \\{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"floor_plane","arguments":{}}}
    ,
    \\{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"place_on","arguments":{"width":0.1,"depth":0.1,"height":0.12}}}
    ,
    \\{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"measure_between","arguments":{"from":[0,0,0],"to":[3,4,0],"from_accuracy_m":0.01,"to_accuracy_m":0.02}}}
    ,
    \\{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"submit_world_mesh","arguments":{"vertices":[0,0,0,2,0,0,0,0,2,2,0,2],"indices":[0,1,2,1,3,2]}}}
    ,
    \\{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"path_across_world","arguments":{"start":[0.2,0,0.2],"goal":[1.8,0,1.8]}}}
    ,
    \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"align_shared","arguments":{"landmarks":[{"id":1,"x":2,"y":0,"z":0},{"id":2,"x":2,"y":0,"z":-1},{"id":3,"x":2,"y":1,"z":0}]}}}
    ,
    // Read again, now that a frame has been submitted: the record must say so.
    \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"read_perception","arguments":{}}}
    ,
    // The section list, which this tool declared and ignored: asking for one section
    // must answer that one and leave the rest out.
    \\{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"read_perception","arguments":{"sections":["world"]}}}
    ,
};

var failures: usize = 0;

/// The line answering the narrowed read, which is the last request the proof sends.
fn narrowedRead(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"id\":23") != null) return line;
    }
    return null;
}

/// The line answering the tools/list request, which is where the server says what it
/// has. Scoped to that line because "name" appears in every tool call too.
fn toolsListLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"id\":2") == null) continue;
        if (std.mem.indexOf(u8, line, "\"tools\"") == null) continue;
        return line;
    }
    return null;
}

fn check(ok: bool, what: []const u8) void {
    if (ok) {
        std.debug.print("mcp-proof: PROOF {s}\n", .{what});
        return;
    }
    failures += 1;
    std.debug.print("mcp-proof: FAILED {s}\n", .{what});
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.next();
    const binary = args.next() orelse {
        std.debug.print("mcp-proof: usage: mcp-proof <path to gosslens-mcp>\n", .{});
        return 2;
    };

    var child = try std.process.spawn(io, .{
        .argv = &.{binary},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    {
        var buffer: [4096]u8 = undefined;
        var w = child.stdin.?.writer(io, &buffer);
        for (requests) |request| {
            try w.interface.writeAll(request);
            try w.interface.writeByte('\n');
        }
        try w.interface.flush();
    }
    // Closed so the server sees end of stream and exits of its own accord,
    // rather than the proof waiting on a process that is waiting on the proof.
    child.stdin.?.close(io);
    child.stdin = null;

    var read_buffer: [1 << 16]u8 = undefined;
    var r = child.stdout.?.reader(io, &read_buffer);
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = r.interface.streamRemaining(&out.writer) catch {}; // failure ignored: a short read is the server having said all it had
    const text = out.writer.buffered();
    _ = try child.wait(io);

    check(std.mem.indexOf(u8, text, "2025-06-18") != null, "the server answers initialize with the protocol version it speaks");
    check(std.mem.indexOf(u8, text, "\"serverInfo\"") != null, "initialize carries the server's own name and version");

    // Every tool the server declares, driven, read off the server's own list rather
    // than a list typed here: a tool added to one and not the other is exactly the
    // declared-and-unproven surface this whole proof exists to refuse.
    const declared = toolsListLine(text) orelse {
        check(false, "the server answers tools/list");
        return 1;
    };
    var names: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, declared, at, "\"name\":\"")) |found| {
        const start = found + "\"name\":\"".len;
        const end = std.mem.indexOfScalarPos(u8, declared, start, '"') orelse break;
        const name = declared[start..end];
        at = end;
        names += 1;
        var called: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&called, "\"name\":\"{s}\"", .{name}) catch continue;
        var driven = false;
        for (requests) |request| {
            if (std.mem.indexOf(u8, request, needle) != null) driven = true;
        }
        check(driven, name);
    }
    check(names != 0, "the tools list names at least one tool");

    // The wiring proof: an embedding put in through the server comes back out of
    // the same session by id, which only a live engine can do.
    check(std.mem.indexOf(u8, text, "remembered 7 at 4 dimensions") != null, "remember reaches the memory plane of a real session");
    check(std.mem.indexOf(u8, text, "7 at 1.0000") != null, "search_memory finds what remember put there, at the distance of an exact match");
    check(std.mem.indexOf(u8, text, "renderer backend") != null, "engine_report reads the engine's own counters");
    check(std.mem.indexOf(u8, text, "model plan ") != null, "engine_report says what a model rail costs and whether it is steady");
    check(std.mem.indexOf(u8, text, "annotation 3 placed") != null, "annotate draws back into the frame through the session");

    // A missing precondition is an answer. The blanket refusal this replaced was
    // not: it said the same thing whether the host had no screen, the session no
    // frame, or the path no file.
    check(std.mem.indexOf(u8, text, "no engine session is attached") == null, "no tool answers the one blanket refusal any more");
    // A session with no frame answers the record anyway, saying it has submitted
    // none. That is the honest answer: a reader learns the state rather than
    // getting an error it cannot act on.
    check(std.mem.indexOf(u8, text, "frames_submitted\\\":0") != null, "read_perception answers the record, saying it has seen no frame yet");
    check(std.mem.indexOf(u8, text, "\\\"schema\\\":1") != null, "the record a model reads carries the schema it was written against");
    // A section projected as its own tag number is not an answer a model can act
    // on. These are the sections this wave added, and the record has to name their
    // fields rather than report how many bytes it is carrying.
    check(std.mem.indexOf(u8, text, "tracking_state") != null, "the record names the world's tracking state rather than reporting a tag and a byte count");
    check(std.mem.indexOf(u8, text, "anchor_count") != null, "the record names how many anchors the room has");
    // A narrowed read answers the section asked for and not the others. The faces
    // section rides every full read, so its absence from the narrowed one is the proof
    // that the list was honoured rather than dropped.
    if (narrowedRead(text)) |narrow| {
        // Field names rather than quoted section names: the record rides inside a JSON
        // string, so its own quotes are escaped and a check written with plain ones
        // matches nothing. That is what made this fail on a record that was correct.
        const answered = std.mem.indexOf(u8, narrow, "tracking_state") != null;
        check(answered, "a read asking for one section answers that section");
        if (!answered) std.debug.print("mcp-proof: the narrowed read answered {s}\n", .{narrow[0..@min(narrow.len, 400)]});
        check(std.mem.indexOf(u8, narrow, "frames_submitted") == null, "a read asking for one section leaves the others out");
    } else {
        check(false, "the server answers a narrowed read");
    }
    check(std.mem.indexOf(u8, text, "cannot read third_party/models/does-not-exist.onnx") != null, "model_support names the file it could not read");
    check(std.mem.indexOf(u8, text, "that clip would not open") != null, "open_clip refuses a path that is not a clip, and says which way");
    check(std.mem.indexOf(u8, text, "is declared and not wired") == null, "no declared tool is left unwired");

    // The feeding tools, proven by what the questions answer afterwards rather than
    // by the submissions reporting success to themselves.
    check(std.mem.indexOf(u8, text, "submitted 1 planes") != null or std.mem.indexOf(u8, text, "submitted 2 planes") != null, "submit_world takes a room");
    check(std.mem.indexOf(u8, text, "plane 10 is the floor") != null, "floor_plane names the floor out of the room that was submitted");
    check(std.mem.indexOf(u8, text, "still free") != null, "place_on answers where a cup fits, with the room each surface keeps");
    check(std.mem.indexOf(u8, text, "5.0000 metres") != null, "measure_between answers five metres across a three-four-five triangle");
    check(std.mem.indexOf(u8, text, "give or take") != null, "the measurement carries its uncertainty");
    check(std.mem.indexOf(u8, text, "triangles") != null, "submit_world_mesh takes scanned geometry");
    check(std.mem.indexOf(u8, text, " -> ") != null, "path_across_world routes across the mesh it was given");
    check(std.mem.indexOf(u8, text, "aligned over 3 landmarks") != null, "align_shared solves over the landmarks both devices recognise");
    // The frame: submitted as a png, and the record afterwards says it has one.
    // The frame, and the pair that must agree: either it landed and the record counts
    // it, or this host would not give a renderer and the record says it has seen
    // nothing. What a proof refuses is the two disagreeing.
    const frame_landed = std.mem.indexOf(u8, text, " from sdk/ts/demo/res/") != null;
    const frame_refused = std.mem.indexOf(u8, text, "would not bring up a renderer") != null;
    check(frame_landed or frame_refused, "submit_image either submits the png or names the renderer it needs");
    check(std.mem.count(u8, text, "frames_submitted") >= 2, "the record is readable before and after the attempt");
    if (frame_landed) {
        check(std.mem.indexOf(u8, text, "frames_submitted\\\":1") != null, "the record counts the frame the server submitted");
    } else {
        check(std.mem.indexOf(u8, text, "frames_submitted\\\":0") != null, "the record says it has seen no frame, agreeing with the refusal");
    }
    check(std.mem.indexOf(u8, text, "-32602") != null, "a tool this server does not have is a protocol error, not a result");

    if (failures != 0) {
        std.debug.print("mcp-proof: {d} of the server's promises do not hold\n", .{failures});
        return 1;
    }
    std.debug.print("mcp-proof: every declared tool answers from the engine\n", .{});
    return 0;
}
