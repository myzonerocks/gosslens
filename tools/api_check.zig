//! The public-contract gate. The frozen header, abi_functions, docs/API.md and
//! the three SDK surfaces describe one operation set, and nothing checked that
//! they agreed until this existed.

//! A drift in any direction is a defect a consumer finds first: an op no SDK
//! wraps cannot be called, an op the header omits is invisible, and an op with
//! no row in API.md has no agreed name, which is how one operation ends up
//! spelled three ways.

//! Exceptions are named below, in code, with the reason. An exception with no
//! reason is drift wearing a waiver's clothes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_file_bytes: usize = 8 << 20;

/// Operations no SDK wraps, each with why. goss_alloc and goss_free exist for
/// an embedder that needs scratch inside the module's own heap; an SDK has its
/// platform allocator and never calls them.
const no_wrapper_anywhere = [_]Exception{
    .{ .op = "goss_alloc", .why = "embedder-only scratch allocation; an SDK uses its platform allocator" },
    .{ .op = "goss_free", .why = "embedder-only scratch allocation; an SDK uses its platform allocator" },
};

/// Operations the web SDK does not wrap, each with the reason the web target
/// reaches the capability another way or not at all. A row here is a statement
/// about the platform, not a todo.
const no_ts_wrapper = [_]Exception{
    .{ .op = "goss_engine_recording_start", .why = "the browser records through MediaRecorder off the canvas stream; the engine encoder is native-only" },
    .{ .op = "goss_engine_recording_stop", .why = "paired with recording_start" },
    .{ .op = "goss_engine_recording_set_realtime", .why = "paired with recording_start" },
    .{ .op = "goss_engine_capture_live_frame", .why = "the page reads the composited canvas directly" },
    .{ .op = "goss_engine_render_to_live_texture", .why = "no external-texture path on the web target" },
    .{ .op = "goss_engine_request_screenshot", .why = "the page owns file output; the SDK exports a PNG off the canvas" },
    .{ .op = "goss_session_activate_lens_from_directory", .why = "no filesystem in the page; a bundle stages in through provide_lens_asset" },
    .{ .op = "goss_session_submit_hardware_buffer", .why = "no platform hardware buffer in a browser" },
};

const Exception = struct { op: []const u8, why: []const u8 };

fn excepted(list: []const Exception, op: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e.op, op)) return true;
    }
    return false;
}

const Check = struct {
    arena: Allocator,
    io: Io,
    violations: std.ArrayList([]const u8) = .empty,

    fn flag(c: *Check, comptime fmt: []const u8, args: anytype) !void {
        try c.violations.append(c.arena, try std.fmt.allocPrint(c.arena, fmt, args));
    }

    fn read(c: *Check, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(max_file_bytes)) catch {
            std.debug.print("api-check: cannot read {s}\n", .{path});
            return error.MissingInput;
        };
    }

    /// Every file under a directory tree, concatenated, so a name can be looked
    /// for across a whole SDK without caring which file holds it.
    fn readTree(c: *Check, root: []const u8, extensions: []const []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var dir = std.Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true }) catch {
            std.debug.print("api-check: cannot open {s}\n", .{root});
            return error.MissingInput;
        };
        defer dir.close(c.io);
        var walker = dir.walk(c.arena) catch return error.MissingInput;
        defer walker.deinit();
        while (walker.next(c.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            var matches = false;
            for (extensions) |ext| {
                if (std.mem.endsWith(u8, entry.path, ext)) matches = true;
            }
            if (!matches) continue;
            const full = try std.fmt.allocPrint(c.arena, "{s}/{s}", .{ root, entry.path });
            const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, full, c.arena, .limited(max_file_bytes)) catch continue;
            try out.appendSlice(c.arena, bytes);
            try out.append(c.arena, '\n');
        }
        return out.items;
    }
};

/// Every `goss_<name>(` in a text, deduplicated, in first-seen order. The
/// header declares each op exactly once and abi_functions names each exactly
/// once, so this reads both.
fn collectOps(arena: Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var ops: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "goss_")) |start| {
        at = start + 5;
        // A match inside a longer identifier is not an operation name.
        if (start > 0 and isIdentChar(text[start - 1])) continue;
        var end = start;
        while (end < text.len and isIdentChar(text[end])) end += 1;
        if (end >= text.len or text[end] != '(') continue;
        const name = text[start..end];
        if (seen.contains(name)) continue;
        try seen.put(arena, name, {});
        try ops.append(arena, name);
    }
    return ops;
}

fn isIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}

/// True when the text names the op as a whole identifier. Used for the SDK
/// sweep, where a wrapper may call it, declare it extern, or list it in a
/// binding table, and any of those means the op is reachable.
fn namesOp(text: []const u8, op: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, op)) |start| {
        at = start + op.len;
        const before_ok = start == 0 or !isIdentChar(text[start - 1]);
        const after_ok = at >= text.len or !isIdentChar(text[at]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var c: Check = .{ .arena = arena, .io = init.io };

    const header = try c.read("include/gosslens.h");
    const abi_source = try c.read("core/abi/abi.zig");
    const api_doc = try c.read("docs/API.md");

    const header_ops = try collectOps(arena, header);

    // abi_functions is the engine's own list, the one the ABI minor stamps
    // from. Read just that array so a goss_ name mentioned in a comment
    // elsewhere in abi.zig cannot stand in for a real export.
    const list_start = std.mem.indexOf(u8, abi_source, "pub const abi_functions = [_][]const u8{") orelse {
        std.debug.print("api-check: abi_functions not found in core/abi/abi.zig\n", .{});
        return 2;
    };
    const list_end = std.mem.indexOfPos(u8, abi_source, list_start, "\n};") orelse abi_source.len;
    const abi_ops = try collectOps(arena, abi_source[list_start..list_end]);

    // Both directions: the header and the engine's list describe one surface.
    for (header_ops.items) |op| {
        if (!namesOp(abi_source[list_start..list_end], op)) {
            try c.flag("{s} is declared in include/gosslens.h but is not in abi_functions", .{op});
        }
    }
    for (abi_ops.items) |op| {
        if (!namesOp(header, op)) {
            try c.flag("{s} is in abi_functions but is not declared in include/gosslens.h", .{op});
        }
    }

    // Every op carries its own literal row in the tracked contract. A row that
    // abbreviates a sibling with a suffix (`_clear_geofence`) reads fine and
    // cannot be checked, so the full name has to appear.
    for (header_ops.items) |op| {
        if (!namesOp(api_doc, op)) {
            try c.flag("{s} has no row naming it in docs/API.md", .{op});
        }
    }

    // Each SDK has to be able to reach every op.
    const swift = try c.readTree("sdk/swift/Sources", &.{".swift"});
    const jni = try c.read("adapters/android/jni.zig");
    const ts = try c.readTree("sdk/ts/src", &.{".ts"});

    for (header_ops.items) |op| {
        if (excepted(&no_wrapper_anywhere, op)) continue;
        if (!namesOp(swift, op)) try c.flag("{s} has no Swift wrapper under sdk/swift/Sources", .{op});
        if (!namesOp(jni, op)) try c.flag("{s} is not bound in adapters/android/jni.zig, so Kotlin cannot reach it", .{op});
        if (!namesOp(ts, op) and !excepted(&no_ts_wrapper, op)) {
            try c.flag("{s} has no TypeScript wrapper under sdk/ts/src", .{op});
        }
    }

    // An exception that no longer applies is drift in the other direction: the
    // wrapper exists, so the waiver is stale and hides the next real gap.
    for (no_ts_wrapper) |e| {
        if (namesOp(ts, e.op)) {
            try c.flag("{s} is listed as having no TypeScript wrapper but one exists; drop the exception", .{e.op});
        }
    }
    for (no_wrapper_anywhere) |e| {
        if (!namesOp(header, e.op)) {
            try c.flag("{s} is excepted from SDK coverage but is no longer in the header; drop the exception", .{e.op});
        }
    }

    if (c.violations.items.len != 0) {
        for (c.violations.items) |v| std.debug.print("api-check: {s}\n", .{v});
        std.debug.print("api-check: {d} violation(s) across {d} operations\n", .{ c.violations.items.len, header_ops.items.len });
        return 1;
    }
    std.debug.print("api-check: {d} operations agree across the header, abi_functions, docs/API.md, and all three SDKs\n", .{header_ops.items.len});
    return 0;
}

test "an operation name is read only as a whole identifier" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\goss_engine_create(const goss_engine_config *config);
        \\my_goss_engine_create(void);
        \\goss_engine_create(again);
    ;
    const ops = try collectOps(arena, text);
    try std.testing.expectEqual(@as(usize, 1), ops.items.len);
    try std.testing.expectEqualStrings("goss_engine_create", ops.items[0]);
}

test "a name inside a longer identifier does not count as coverage" {
    try std.testing.expect(namesOp("call goss_abi_version() first", "goss_abi_version"));
    try std.testing.expect(!namesOp("wrap_goss_abi_version_shim()", "goss_abi_version"));
    try std.testing.expect(namesOp("`goss_session_brush_end`", "goss_session_brush_end"));
}
