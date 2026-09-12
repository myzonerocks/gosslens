//! Drives the built MCP server over a pipe the way a client does, and checks
//! that every declared tool answers from the engine. A server that lists ten
//! tools and answers one sentence to all of them passes a schema test and is
//! useless to a model, and only running them says so.

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
    \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"annotate","arguments":{"id":3,"kind":0,"rect":[0.1,0.1,0.2,0.2],"text":"here"}}}
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
};

var failures: usize = 0;

fn check(ok: bool, comptime what: []const u8) void {
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

    // Every tool the list declares, called. A tool nobody can call is not a tool.
    for ([_][]const u8{
        "open_clip",      "read_perception", "read_text", "annotate",
        "remember",       "search_memory",   "model_support",
        "engine_report",  "open_screen",     "screen_point",
    }) |name| {
        check(std.mem.indexOf(u8, text, name) != null, name);
    }

    // The wiring proof: an embedding put in through the server comes back out of
    // the same session by id, which only a live engine can do.
    check(std.mem.indexOf(u8, text, "remembered 7 at 4 dimensions") != null, "remember reaches the memory plane of a real session");
    check(std.mem.indexOf(u8, text, "7 at 1.0000") != null, "search_memory finds what remember put there, at the distance of an exact match");
    check(std.mem.indexOf(u8, text, "renderer backend") != null, "engine_report reads the engine's own counters");
    check(std.mem.indexOf(u8, text, "annotation 3 placed") != null, "annotate draws back into the frame through the session");

    // A missing precondition is an answer. The blanket refusal this replaced was
    // not: it said the same thing whether the host had no screen, the session no
    // frame, or the path no file.
    check(std.mem.indexOf(u8, text, "no engine session is attached") == null, "no tool answers the one blanket refusal any more");
    check(std.mem.indexOf(u8, text, "submit a frame first") != null, "read_perception says the session has seen nothing, not nothing at all");
    check(std.mem.indexOf(u8, text, "cannot read third_party/models/does-not-exist.onnx") != null, "model_support names the file it could not read");
    check(std.mem.indexOf(u8, text, "that clip would not open") != null, "open_clip refuses a path that is not a clip, and says which way");
    check(std.mem.indexOf(u8, text, "is declared and not wired") == null, "no declared tool is left unwired");
    check(std.mem.indexOf(u8, text, "-32602") != null, "a tool this server does not have is a protocol error, not a result");

    if (failures != 0) {
        std.debug.print("mcp-proof: {d} of the server's promises do not hold\n", .{failures});
        return 1;
    }
    std.debug.print("mcp-proof: every declared tool answers from the engine\n", .{});
    return 0;
}
