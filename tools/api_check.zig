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
    .{ .op = "goss_session_submit_source_hardware_buffer", .why = "no platform hardware buffer in a browser; a page source arrives as a texture" },
};

const Exception = struct { op: []const u8, why: []const u8 };

fn excepted(list: []const Exception, op: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e.op, op)) return true;
    }
    return false;
}

/// Header enums each SDK mirrors as its own enum. A value added in the header
/// and missed in one SDK is silent: Kotlin reads an ordinal, so a missing case
/// shifts every reason after it, and nothing in a build would say so. The
/// prefix is the header's; the case spellings are derived from the tail.
const mirrored_enums = [_][]const u8{
    "GOSS_NODE_REASON_",
    "GOSS_NODE_STATE_",
    "GOSS_DEGRADE_",
    "GOSS_THERMAL_",
};

/// Every `Java_com_gosslens_Gosslens_<name>` in the JNI file, names only. A
/// binding with no Kotlin declaration is reachable from Zig and from nothing an
/// app can call, which the op-level check cannot see because the op IS bound.
fn collectJniNames(arena: Allocator, jni: []const u8) !std.ArrayList([]const u8) {
    const prefix = "Java_com_gosslens_Gosslens_";
    var names: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, jni, at, prefix)) |start| {
        at = start + prefix.len;
        var end = at;
        while (end < jni.len and isIdentChar(jni[end])) end += 1;
        const name = jni[at..end];
        if (name.len == 0 or seen.contains(name)) continue;
        try seen.put(arena, name, {});
        try names.append(arena, name);
    }
    return names;
}

/// Every `external fun <name>` Kotlin declares, names only.
fn collectKotlinExternals(arena: Allocator, kotlin: []const u8) !std.ArrayList([]const u8) {
    const marker = "external fun ";
    var names: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, kotlin, at, marker)) |start| {
        at = start + marker.len;
        var end = at;
        while (end < kotlin.len and isIdentChar(kotlin[end])) end += 1;
        const name = kotlin[at..end];
        if (name.len == 0 or seen.contains(name)) continue;
        try seen.put(arena, name, {});
        try names.append(arena, name);
    }
    return names;
}

/// The tail of a header enum member, spelled the way each SDK spells a case.
/// CONSTRAINT_FAILED stays itself for Kotlin, becomes constraintFailed for
/// Swift and ConstraintFailed for TypeScript.
fn spellCase(arena: Allocator, tail: []const u8, comptime style: enum { kotlin, lower_camel, upper_camel }) ![]const u8 {
    if (style == .kotlin) return tail;
    var out: std.ArrayList(u8) = .empty;
    var upper_next = style == .upper_camel;
    for (tail) |ch| {
        if (ch == '_') {
            upper_next = true;
            continue;
        }
        try out.append(arena, if (upper_next) std.ascii.toUpper(ch) else std.ascii.toLower(ch));
        upper_next = false;
    }
    return out.items;
}

/// Every `<prefix><TAIL> = ` member of one header enum, tails only.
fn collectEnumTails(arena: Allocator, header: []const u8, prefix: []const u8) !std.ArrayList([]const u8) {
    var tails: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, header, at, prefix)) |start| {
        at = start + prefix.len;
        if (start > 0 and isIdentChar(header[start - 1])) continue;
        var end = at;
        while (end < header.len and isIdentChar(header[end])) end += 1;
        // A member, not a use: the declaration assigns a value.
        const rest = std.mem.trimStart(u8, header[end..], " \t");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        try tails.append(arena, header[at..end]);
    }
    return tails;
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

    // Every op has an implementation, not merely a declaration. The list, the
    // header and all four wrappers can agree on a name nothing implements: one
    // did, and it only surfaced as an android compile error, because no host
    // build compiles the JNI that calls it.
    for (header_ops.items) |op| {
        const exported = try std.fmt.allocPrint(arena, "pub export fn {s}(", .{op});
        if (std.mem.indexOf(u8, abi_source, exported) == null) {
            try c.flag("{s} is declared everywhere and implemented nowhere: no `pub export fn` in core/abi/abi.zig", .{op});
        }
    }

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

    const kotlin = try c.read("sdk/kotlin/src/main/kotlin/com/gosslens/Gosslens.kt");

    // A JNI binding Kotlin never declares is reachable from nothing an app can
    // call, and a Kotlin declaration with no binding fails at load rather than at
    // build. The op-level check above sees neither, because the op is bound.
    const jni_names = try collectJniNames(arena, jni);
    const kotlin_names = try collectKotlinExternals(arena, kotlin);
    // Set membership, not a word search: the JNI symbol prefixes the name with
    // an underscore, which a word-boundary match reads as one long identifier.
    var kotlin_set: std.StringHashMapUnmanaged(void) = .empty;
    for (kotlin_names.items) |name| try kotlin_set.put(arena, name, {});
    var jni_set: std.StringHashMapUnmanaged(void) = .empty;
    for (jni_names.items) |name| try jni_set.put(arena, name, {});
    for (jni_names.items) |name| {
        if (!kotlin_set.contains(name)) try c.flag("the JNI binds {s} and Kotlin declares no external fun for it", .{name});
    }
    for (kotlin_names.items) |name| {
        if (!jni_set.contains(name)) try c.flag("Kotlin declares external fun {s} and the JNI binds nothing for it", .{name});
    }

    // Every value of a mirrored enum reaches all three SDKs, spelled each one's
    // way. The Kotlin reader decodes by ordinal, so a missing case there does not
    // fail to compile, it mislabels every value after the gap.
    for (mirrored_enums) |prefix| {
        const tails = try collectEnumTails(arena, header, prefix);
        if (tails.items.len == 0) {
            try c.flag("{s} names no enum member in include/gosslens.h; drop it from mirrored_enums or fix the prefix", .{prefix});
            continue;
        }
        for (tails.items) |tail| {
            const as_kotlin = try spellCase(arena, tail, .kotlin);
            const as_swift = try spellCase(arena, tail, .lower_camel);
            const as_ts = try spellCase(arena, tail, .upper_camel);
            if (!namesOp(kotlin, as_kotlin)) try c.flag("{s}{s} has no Kotlin case '{s}'", .{ prefix, tail, as_kotlin });
            if (!namesOp(swift, as_swift)) try c.flag("{s}{s} has no Swift case '{s}'", .{ prefix, tail, as_swift });
            if (!namesOp(ts, as_ts)) try c.flag("{s}{s} has no TypeScript case '{s}'", .{ prefix, tail, as_ts });
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

test "a header enum member is spelled each SDK's way" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("CONSTRAINT_FAILED", try spellCase(a, "CONSTRAINT_FAILED", .kotlin));
    try std.testing.expectEqualStrings("constraintFailed", try spellCase(a, "CONSTRAINT_FAILED", .lower_camel));
    try std.testing.expectEqualStrings("ConstraintFailed", try spellCase(a, "CONSTRAINT_FAILED", .upper_camel));
    // A single word still lowercases its tail.
    try std.testing.expectEqualStrings("none", try spellCase(a, "NONE", .lower_camel));
    try std.testing.expectEqualStrings("None", try spellCase(a, "NONE", .upper_camel));
}

test "enum members are collected, uses of the same name are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const header =
        "    GOSS_NODE_REASON_NONE = 0,\n" ++
        "    GOSS_NODE_REASON_OUT_OF_MEMORY = 1,\n" ++
        "    if (r == GOSS_NODE_REASON_NONE) return;\n";
    const tails = try collectEnumTails(a, header, "GOSS_NODE_REASON_");
    try std.testing.expectEqual(@as(usize, 2), tails.items.len);
    try std.testing.expectEqualStrings("NONE", tails.items[0]);
    try std.testing.expectEqualStrings("OUT_OF_MEMORY", tails.items[1]);
}

test "JNI names and Kotlin externals are collected, and only those" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const jni =
        "export fn Java_com_gosslens_Gosslens_nativeAbiVersion(env: *JniEnv) i32 {}\n" ++
        "export fn Java_com_gosslens_Gosslens_nativeCapabilities(env: *JniEnv) i64 {}\n" ++
        "// Java_com_gosslens_Gosslens_nativeAbiVersion named twice is still one\n";
    const names = try collectJniNames(a, jni);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("nativeAbiVersion", names.items[0]);

    const kotlin =
        "    internal external fun nativeAbiVersion(): Int\n" ++
        "    fun abiVersion(): Int = Gosslens.nativeAbiVersion()\n";
    const externals = try collectKotlinExternals(a, kotlin);
    try std.testing.expectEqual(@as(usize, 1), externals.items.len);
    try std.testing.expectEqualStrings("nativeAbiVersion", externals.items[0]);
}
