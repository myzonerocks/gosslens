//! Prints the ABI surface as deterministic text and checks it against the
//! tracked baseline. The baseline commits with the code, so any change to an
//! exported layout or symbol shows up in review as a diff to
//! tools/abi-baseline.txt, and an unintended change fails the gate.
//!
//!   abi_dump --print                       write the current surface to stdout
//!   abi_dump --check <baseline>            exit 1 if the surface or header minor drift
//!   abi_dump --update <baseline> <header>  rewrite both from the derived surface

const std = @import("std");
const abi = @import("abi");

const abi_types = abi.abi_surface_types;

/// What each surface struct is called in the frozen header, because an SDK
/// compiles against that spelling and most but not all of them are the zig name
/// in snake case.
const header_names = [abi_types.len][]const u8{
    "goss_frame_desc",     "goss_landmarks",       "goss_engine_config",
    "goss_session_config", "goss_renderer_desc",   "goss_frame_planes",
    "goss_face_result",    "goss_hand_result",     "goss_pose_result",
    "goss_lens_signals",   "goss_camera_controls", "goss_recording_policy",
    "goss_capture_ui",     "goss_caption_segment", "goss_capture_guidance",
    "goss_node_report",    "goss_engine_report",   "goss_session_report",
    "goss_annotation", "goss_capture_config", "goss_clip_info",
    "goss_egress_config", "goss_egress_decision", "goss_event",
    "goss_footprint", "goss_media_capabilities", "goss_occupant",
    "goss_placement", "goss_recording_config", "goss_recording_report",
    "goss_screen_surface", "goss_shared_landmark", "goss_text_entry",
    "goss_world_anchor", "goss_world_light", "goss_world_plane",
    "goss_world_state",
};

const abi_functions = abi.abi_functions;

fn writeSurface(w: anytype) !void {
    try w.print("abi {d}.{d}\n", .{ abi.abi_major, abi.abi_minor });
    inline for (abi_types) |T| {
        try w.print("type {s} size={d} align={d}\n", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
        inline for (comptime std.meta.fieldNames(T)) |name| {
            try w.print("  field {s} offset={d} size={d}\n", .{ name, @offsetOf(T, name), @sizeOf(@FieldType(T, name)) });
        }
    }
    for (abi_functions) |f| {
        try w.print("fn {s}\n", .{f});
    }
}

/// One field of a struct as the header declares it, laid out by the same rules
/// the compiler applies to an extern struct.
const CField = struct { name: []const u8, offset: usize, size: usize };

/// The size and alignment of a type the header may name: a scalar, a struct the
/// header declares itself, or an enum, which crosses the ABI as an int.
fn cShape(arena: std.mem.Allocator, text: []const u8, spelling: []const u8, depth: u8) ?[2]usize {
    if (cScalar(spelling)) |shape| return shape;
    if (depth == 0) return null;
    var size: usize = 0;
    var alignment: usize = 1;
    // A struct the header declares is laid out; anything else the header names is
    // one of its enums, which crosses as an int.
    if (headerLayout(arena, text, spelling, &size, &alignment, depth - 1)) |_| {
        return .{ size, alignment };
    } else |_| {}
    if (std.mem.startsWith(u8, spelling, "goss_")) return .{ 4, 4 };
    return null;
}

/// The size and alignment of a scalar the header may name.
fn cScalar(spelling: []const u8) ?[2]usize {
    const table = [_]struct { name: []const u8, size: usize }{
        .{ .name = "uint8_t", .size = 1 },  .{ .name = "int8_t", .size = 1 },
        .{ .name = "char", .size = 1 },     .{ .name = "uint16_t", .size = 2 },
        .{ .name = "int16_t", .size = 2 },  .{ .name = "uint32_t", .size = 4 },
        .{ .name = "int32_t", .size = 4 },  .{ .name = "float", .size = 4 },
        .{ .name = "uint64_t", .size = 8 }, .{ .name = "int64_t", .size = 8 },
        .{ .name = "double", .size = 8 },   .{ .name = "size_t", .size = 8 },
        .{ .name = "bool", .size = 1 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, spelling)) return .{ entry.size, entry.size };
    }
    return null;
}

/// An array bound the header writes as a product of macros and literals, each
/// resolved from the header's own define so a count and a layout cannot drift.
fn resolveCount(text: []const u8, spelling: []const u8) ?usize {
    var product: usize = 1;
    var factors = std.mem.splitScalar(u8, spelling, '*');
    var saw = false;
    while (factors.next()) |factor| {
        const term = std.mem.trim(u8, factor, " \t");
        if (term.len == 0) continue;
        product *= resolveTerm(text, term) orelse return null;
        saw = true;
    }
    return if (saw) product else null;
}

/// One factor of a bound: a literal, or a macro the header defines.
fn resolveTerm(text: []const u8, spelling: []const u8) ?usize {
    const digits = std.mem.trimEnd(u8, spelling, "uU");
    if (std.fmt.parseInt(usize, digits, 10)) |n| return n else |_| {}
    var needle: [128]u8 = undefined;
    // The space matters: without it GOSS_HAND_MAX also matches a longer define
    // that starts with it, and the bound comes back quietly wrong.
    const key = std.fmt.bufPrint(&needle, "#define {s} ", .{spelling}) catch return null;
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    var i = at + key.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    var value: usize = 0;
    var saw = false;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        value = value * 10 + (text[i] - '0');
        saw = true;
    }
    return if (saw) value else null;
}

/// The header's own layout for one struct: its fields in order, at the offsets a
/// C compiler would put them, and the size it would report.
fn headerLayout(arena: std.mem.Allocator, text: []const u8, name: []const u8, out_size: *usize, out_align: *usize, depth: u8) ![]CField {
    var open_buf: [160]u8 = undefined;
    const open = try std.fmt.bufPrint(&open_buf, "typedef struct {s} {{", .{name});
    const start = std.mem.indexOf(u8, text, open) orelse return error.TypedefMissing;
    const body_at = start + open.len;
    const end = std.mem.indexOfPos(u8, text, body_at, "}") orelse return error.TypedefUnterminated;

    var fields: std.ArrayList(CField) = .empty;
    var offset: usize = 0;
    var widest: usize = 1;
    // Comments go first and the split comes after: a header comment can carry a
    // semicolon, and splitting on that turns the rest of one comment into a field
    // nobody declared.
    const body = try stripComments(arena, text[body_at..end]);
    var lines = std.mem.splitScalar(u8, body, ';');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");
        if (trimmed.len == 0) continue;

        // Every dimension, multiplied: a landmark table is declared as a count by
        // three, and taking only the first bound undercounts it by a factor of three.
        var count: usize = 1;
        var decl = trimmed;
        while (std.mem.lastIndexOfScalar(u8, decl, '[')) |bracket| {
            const close = std.mem.indexOfScalarPos(u8, decl, bracket, ']') orelse return error.BadArray;
            count *= resolveCount(text, std.mem.trim(u8, decl[bracket + 1 .. close], " \t")) orelse return error.BadArrayBound;
            decl = std.mem.trim(u8, decl[0..bracket], " \t");
        }
        const space = std.mem.lastIndexOfAny(u8, decl, " \t*") orelse return error.BadField;
        const field_name = decl[space + 1 ..];
        const spelling = std.mem.trim(u8, decl[0..space], " \t");
        const pointer = std.mem.indexOfScalar(u8, decl, '*') != null;
        const shape = if (pointer) [2]usize{ 8, 8 } else cShape(arena, text, spelling, depth) orelse return error.UnknownCType;

        offset = std.mem.alignForward(usize, offset, shape[1]);
        try fields.append(arena, .{ .name = field_name, .offset = offset, .size = shape[0] * count });
        offset += shape[0] * count;
        widest = @max(widest, shape[1]);
    }
    out_size.* = std.mem.alignForward(usize, offset, widest);
    out_align.* = widest;
    return fields.items;
}

/// Blanks the comments a header field line may carry, so a word inside one is
/// never read as a type or a name.
fn stripComments(arena: std.mem.Allocator, line: []const u8) ![]u8 {
    const copy = try arena.dupe(u8, line);
    var i: usize = 0;
    while (i < copy.len) {
        if (i + 1 < copy.len and copy[i] == '/' and copy[i + 1] == '*') {
            while (i < copy.len and !(i + 1 < copy.len and copy[i] == '*' and copy[i + 1] == '/')) : (i += 1) copy[i] = ' ';
            if (i + 1 < copy.len) {
                copy[i] = ' ';
                copy[i + 1] = ' ';
                i += 2;
            }
            continue;
        }
        if (i + 1 < copy.len and copy[i] == '/' and copy[i + 1] == '/') {
            while (i < copy.len) : (i += 1) copy[i] = ' ';
            break;
        }
        i += 1;
    }
    return copy;
}

/// The SDKs that decode a report out of raw bytes say how big they think it
/// is, and this compares that number to the struct the engine writes. Both read
/// fields at offsets worked out by hand, so a struct that grows corrupts them
/// silently, which is what the C side is now gated against.
fn checkReportSizes(arena: std.mem.Allocator, io: std.Io) !u8 {
    const wants = [_]struct { name: []const u8, size: usize }{
        .{ .name = "ENGINE_REPORT_BYTES", .size = @sizeOf(abi.EngineReport) },
        .{ .name = "SESSION_REPORT_BYTES", .size = @sizeOf(abi.SessionReport) },
        // The major each SDK says it was built against. It is what the engine's own
        // check compares, so an SDK recording the wrong one would pass a check that
        // tests nothing.
        .{ .name = "GOSS_ABI_MAJOR", .size = abi.abi_major },
    };
    const sources = [_][]const u8{
        "sdk/kotlin/src/main/kotlin/com/gosslens/Gosslens.kt",
        "sdk/ts/src/index.ts",
    };
    var failures: u8 = 0;
    for (sources) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 << 20)) catch |err| {
            std.debug.print("abi_dump: cannot read {s}: {t}\n", .{ path, err });
            failures +|= 1;
            continue;
        };
        for (wants) |want| {
            const declared = declaredNumber(text, want.name) orelse {
                std.debug.print("abi_dump: {s} does not name {s}\n", .{ path, want.name });
                failures +|= 1;
                continue;
            };
            if (declared != want.size) {
                std.debug.print("abi_dump: {s} says {s} is {d} and the engine writes {d}\n", .{ path, want.name, declared, want.size });
                failures +|= 1;
            }
        }
    }
    return failures;
}

/// The number a source assigns to a name, whichever way its language spells an
/// assignment.
fn declaredNumber(text: []const u8, name: []const u8) ?usize {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, name)) |found| {
        at = found + name.len;
        var i = at;
        while (i < text.len and text[i] == ' ') i += 1;
        // A typed declaration spells the type between the name and the value, as
        // Kotlin's `NAME: Int = 0` does. Reading up to the assignment is what lets
        // this see a constant the old scan read straight past.
        if (i < text.len and text[i] == ':') {
            while (i < text.len and text[i] != '=' and text[i] != '\n') i += 1;
        }
        var assigned = false;
        while (i < text.len and (text[i] == ' ' or text[i] == '=')) : (i += 1) {
            if (text[i] == '=') assigned = true;
        }
        if (!assigned and i == at) continue;
        // A use is not a declaration: `NAME shl 16` would otherwise read as 16.
        if (i < text.len and !std.ascii.isDigit(text[i])) continue;
        var value: usize = 0;
        var saw = false;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            value = value * 10 + (text[i] - '0');
            saw = true;
        }
        if (saw) return value;
    }
    return null;
}

/// Proves the header an SDK compiles against lays every surface struct out the
/// way the engine writes it. The baseline records the zig side only, so without
/// this a field added to the header in the wrong place, or a type widened on one
/// side, is a silent corruption every SDK inherits.
fn checkHeaderLayout(arena: std.mem.Allocator, text: []const u8) !u8 {
    var failures: u8 = 0;
    inline for (abi_types, 0..) |T, index| {
        failures +|= try checkOneLayout(T, arena, text, header_names[index]);
    }
    return failures;
}

/// One struct: its fields in the header against the fields the compiler reports.
fn checkOneLayout(comptime T: type, arena: std.mem.Allocator, text: []const u8, name: []const u8) !u8 {
    var failures: u8 = 0;
    var c_size: usize = 0;
    var c_align: usize = 1;
    const c_fields = headerLayout(arena, text, name, &c_size, &c_align, 4) catch |err| {
        std.debug.print("abi_dump: cannot read {s} out of the header: {t}\n", .{ name, err });
        return 1;
    };
    const z_fields = comptime std.meta.fieldNames(T);
    if (c_fields.len != z_fields.len) {
        std.debug.print("abi_dump: {s} has {d} fields in the header and {d} in {s}\n", .{ name, c_fields.len, z_fields.len, @typeName(T) });
        return 1;
    }
    if (c_size != @sizeOf(T)) {
        std.debug.print("abi_dump: {s} is {d} bytes in the header and {d} in {s}\n", .{ name, c_size, @sizeOf(T), @typeName(T) });
        failures +|= 1;
    }
    if (c_align != @alignOf(T)) {
        std.debug.print("abi_dump: {s} aligns to {d} in the header and {d} in {s}\n", .{ name, c_align, @alignOf(T), @typeName(T) });
        failures +|= 1;
    }
    inline for (z_fields, 0..) |z_name, i| {
        const want = @offsetOf(T, z_name);
        if (!std.mem.eql(u8, c_fields[i].name, z_name)) {
            std.debug.print("abi_dump: {s} field {d} is '{s}' in the header and '{s}' in {s}\n", .{ name, i, c_fields[i].name, z_name, @typeName(T) });
            failures +|= 1;
        } else if (c_fields[i].offset != want) {
            std.debug.print("abi_dump: {s}.{s} is at {d} in the header and {d} in {s}\n", .{ name, z_name, c_fields[i].offset, want, @typeName(T) });
            failures +|= 1;
        } else if (c_fields[i].size != @sizeOf(@FieldType(T, z_name))) {
            std.debug.print("abi_dump: {s}.{s} is {d} bytes in the header and {d} in {s}\n", .{ name, z_name, c_fields[i].size, @sizeOf(@FieldType(T, z_name)), @typeName(T) });
            failures +|= 1;
        }
    }
    return failures;
}

const minor_key = "#define GOSS_ABI_MINOR";

// Reads the minor the header currently declares, so the check can prove the
// public contract matches the derived surface.
fn headerMinor(text: []const u8) ?u16 {
    const at = std.mem.indexOf(u8, text, minor_key) orelse return null;
    var i = at + minor_key.len;
    while (i < text.len and !std.ascii.isDigit(text[i])) i += 1;
    var v: u16 = 0;
    var saw = false;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        v = v * 10 + (text[i] - '0');
        saw = true;
    }
    return if (saw) v else null;
}

// Splices the derived minor into the header in place of whatever digits the
// define currently holds, leaving the trailing u and the rest untouched.
fn stampHeaderMinor(arena: std.mem.Allocator, text: []const u8, minor: u16) ![]const u8 {
    const at = std.mem.indexOf(u8, text, minor_key) orelse return error.MinorNotFound;
    var ds = at + minor_key.len;
    while (ds < text.len and !std.ascii.isDigit(text[ds])) ds += 1;
    var de = ds;
    while (de < text.len and std.ascii.isDigit(text[de])) de += 1;
    if (de == ds) return error.MinorNotFound;
    var buf: std.Io.Writer.Allocating = .init(arena);
    try buf.writer.writeAll(text[0..ds]);
    try buf.writer.print("{d}", .{minor});
    try buf.writer.writeAll(text[de..]);
    return buf.writer.buffered();
}

/// Whether two surface dumps declare the same version, read off the first line
/// each one writes.
fn sameMinorLine(a: []const u8, b: []const u8) bool {
    const ae = std.mem.indexOfScalar(u8, a, '\n') orelse a.len;
    const be = std.mem.indexOfScalar(u8, b, '\n') orelse b.len;
    return std.mem.eql(u8, a[0..ae], b[0..be]);
}

/// Field spellings that changed on the zig side without changing a byte, each with
/// why. A C caller compiles against the header and never sees the zig name, so these
/// must not move the version; an entry with no reason is drift wearing a waiver's
/// clothes, and an entry outlives its use once the baseline carries the new name.
const declared_renames = [_]struct { from: []const u8, to: []const u8, why: []const u8 }{
    .{
        .from = "landmark_count_out",
        .to = "landmark_count",
        .why = "the header always said landmark_count; the zig field took the header's name so the layout gate can match names positionally",
    },
};

/// Whether the surface moved in a way a caller can feel. Listing a struct that was
/// always there changes the dump and changes nothing a caller allocates, so the
/// comparison is over the entries both dumps carry: a renamed or reordered field
/// shows up there, and a newly tracked type does not.
fn callerVisibleChange(arena: std.mem.Allocator, previous: []const u8, current: []const u8) !bool {
    var forward = previous;
    for (declared_renames) |rename| {
        forward = try std.mem.replaceOwned(u8, arena, forward, rename.from, rename.to);
    }
    var old_entries = try entryMap(arena, forward);
    var new_entries = try entryMap(arena, current);
    var it = old_entries.iterator();
    while (it.next()) |entry| {
        const fresh = new_entries.get(entry.key_ptr.*) orelse return true;
        if (!std.mem.eql(u8, fresh, entry.value_ptr.*)) return true;
    }
    return false;
}

/// Each dump entry by the name it declares: a type with its fields, or one function.
fn entryMap(arena: std.mem.Allocator, text: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var start: ?usize = null;
    var key: []const u8 = "";
    var at: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        defer at += line.len + 1;
        if (std.mem.startsWith(u8, line, "  ")) continue;
        if (start) |from| try map.put(arena, key, text[from..at]);
        start = null;
        if (std.mem.startsWith(u8, line, "type ") or std.mem.startsWith(u8, line, "fn ")) {
            start = at;
            const head = line[0 .. std.mem.indexOfScalar(u8, line, '(') orelse line.len];
            key = std.mem.trim(u8, head, " ");
        }
    }
    if (start) |from| try map.put(arena, key, text[from..]);
    return map;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();

    var surface: std.Io.Writer.Allocating = .init(arena);
    try writeSurface(&surface.writer);
    const current = surface.writer.buffered();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.next();
    const mode = args.next() orelse "--print";

    if (std.mem.eql(u8, mode, "--print")) {
        var out_buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
        try stdout.interface.writeAll(current);
        try stdout.interface.flush();
        return 0;
    }

    if (std.mem.eql(u8, mode, "--check")) {
        const path = args.next() orelse {
            std.debug.print("abi_dump: --check needs a baseline path\n", .{});
            return 2;
        };
        const baseline = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(1 << 20)) catch |err| {
            std.debug.print("abi_dump: cannot read {s}: {t}\n", .{ path, err });
            return 1;
        };
        if (!std.mem.eql(u8, baseline, current)) {
            std.debug.print("abi_dump: ABI surface differs from {s}\n", .{path});
            std.debug.print("---- current ----\n{s}", .{current});
            std.debug.print("---- baseline ----\n{s}", .{baseline});
            std.debug.print("An intended change must update the baseline in the same PR.\n", .{});
            return 1;
        }
        const declared = headerMinor(header_text) orelse {
            std.debug.print("abi_dump: {s} not found in the header\n", .{minor_key});
            return 1;
        };
        if (declared != abi.abi_minor) {
            std.debug.print("abi_dump: header GOSS_ABI_MINOR is {d} but the derived surface is {d}; run zig build abi-update\n", .{ declared, abi.abi_minor });
            return 1;
        }
        const layout_failures = try checkHeaderLayout(arena, header_text);
        if (layout_failures != 0) {
            std.debug.print("abi_dump: the header and the engine disagree about {d} things a caller allocates\n", .{layout_failures});
            return 1;
        }
        const size_failures = try checkReportSizes(arena, init.io);
        if (size_failures != 0) {
            std.debug.print("abi_dump: {d} sdk report sizes do not match the structs the engine writes\n", .{size_failures});
            return 1;
        }
        for (abi_functions) |f| {
            const name = functionName(f);
            if (std.mem.indexOf(u8, header_text, name) == null) {
                std.debug.print("abi_dump: {s} is exported but not declared in the header\n", .{name});
                return 1;
            }
        }
        return 0;
    }

    if (std.mem.eql(u8, mode, "--update")) {
        const baseline_path = args.next() orelse "tools/abi-baseline.txt";
        const header_path = args.next() orelse "include/gosslens.h";
        // Read and stamp the header before writing anything, so a header that
        // cannot be stamped leaves neither file half-written.
        const header = std.Io.Dir.cwd().readFileAlloc(init.io, header_path, arena, .limited(1 << 20)) catch |err| {
            std.debug.print("abi_dump: cannot read {s}: {t}\n", .{ header_path, err });
            return 1;
        };
        // The same layout proof the check runs, before anything is written: a
        // baseline stamped over a header that disagrees would make the
        // disagreement the new truth.
        const layout_failures = try checkHeaderLayout(arena, header);
        if (layout_failures != 0) {
            std.debug.print("abi_dump: refusing to stamp: the header and the engine disagree about {d} things a caller allocates\n", .{layout_failures});
            return 1;
        }
        const stamped = stampHeaderMinor(arena, header, abi.abi_minor) catch {
            std.debug.print("abi_dump: {s} not found in {s}\n", .{ minor_key, header_path });
            return 1;
        };
        // A surface that moved while the version stood still is an ABI change a
        // host cannot detect: it sizes a struct or looks for a symbol by the
        // minor it was built against. Refusing here is what makes the version
        // mean something, rather than a number somebody remembers to bump.
        if (std.Io.Dir.cwd().readFileAlloc(init.io, baseline_path, arena, .limited(1 << 20))) |previous| {
            if (try callerVisibleChange(arena, previous, current) and sameMinorLine(previous, current)) {
                std.debug.print("abi_dump: the ABI surface changed but abi_minor is still {d}\n", .{abi.abi_minor});
                std.debug.print("Raise abi_minor in core/abi/abi.zig, then run zig build abi-update again.\n", .{});
                return 1;
            }
        } else |_| {}
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = baseline_path, .data = current });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = header_path, .data = stamped });
        std.debug.print("abi-update: wrote {s} and stamped GOSS_ABI_MINOR={d} in {s}\n", .{ baseline_path, abi.abi_minor, header_path });
        return 0;
    }

    std.debug.print("abi_dump: unknown mode '{s}'\n", .{mode});
    return 2;
}

const build_options = @import("build_options");
const header_text = build_options.gosslens_header;

// abi.abi_functions and the frozen header are kept in step by this test: a
// symbol exported but never declared in the header an SDK compiles against
// is a build break here, not a silent drift.
fn functionName(signature: []const u8) []const u8 {
    const paren = std.mem.indexOfScalar(u8, signature, '(') orelse unreachable;
    var start = paren;
    while (start > 0 and (std.ascii.isAlphanumeric(signature[start - 1]) or signature[start - 1] == '_')) start -= 1;
    return signature[start..paren];
}

test "every exported function is declared in the frozen public header" {
    for (abi_functions) |f| {
        const name = functionName(f);
        if (std.mem.indexOf(u8, header_text, name) == null) {
            std.debug.print("abi_dump: {s} is exported but not declared in include/gosslens.h\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "surface text is deterministic and complete" {
    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try writeSurface(&first.writer);
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try writeSurface(&second.writer);

    try std.testing.expectEqualStrings(first.writer.buffered(), second.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, first.writer.buffered(), "type") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.writer.buffered(), "goss_abi_version") != null);
}

test "a surface that moved while the version stood still is refused" {
    const before = "abi 0.174\ntype abi.SessionReport size=80 align=8\n";
    const grown = "abi 0.174\ntype abi.SessionReport size=88 align=8\n";
    const bumped = "abi 0.175\ntype abi.SessionReport size=88 align=8\n";
    try std.testing.expect(sameMinorLine(before, grown));
    try std.testing.expect(!sameMinorLine(before, bumped));
}

test "the header parser lays a struct out the way a c compiler would" {
    const text =
        \\#define SMALL_COUNT 3u
        \\typedef struct tiny {
        \\    uint32_t a;
        \\    uint64_t b;
        \\    float c[SMALL_COUNT * 2];
        \\    bool d;
        \\} tiny;
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var size: usize = 0;
    var alignment: usize = 1;
    const fields = try headerLayout(arena.allocator(), text, "tiny", &size, &alignment, 4);

    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqual(@as(usize, 0), fields[0].offset);
    // Eight-aligned, so four bytes of padding sit between a and b.
    try std.testing.expectEqual(@as(usize, 8), fields[1].offset);
    try std.testing.expectEqual(@as(usize, 16), fields[2].offset);
    try std.testing.expectEqual(@as(usize, 24), fields[2].size);
    try std.testing.expectEqual(@as(usize, 40), fields[3].offset);
    try std.testing.expectEqual(@as(usize, 8), alignment);
    try std.testing.expectEqual(@as(usize, 48), size);
}

test "a struct embedded by value is laid out, not mistaken for an enum" {
    const text =
        \\#define PAIR 2u
        \\typedef struct inner {
        \\    uint64_t x;
        \\    uint32_t y;
        \\} inner;
        \\typedef struct outer {
        \\    uint32_t head;
        \\    inner parts[PAIR];
        \\} outer;
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var size: usize = 0;
    var alignment: usize = 1;
    const fields = try headerLayout(arena.allocator(), text, "outer", &size, &alignment, 4);
    // inner is 16 bytes after its own tail padding, so the pair is 32, and head
    // is followed by four bytes of padding to reach inner's eight-byte alignment.
    try std.testing.expectEqual(@as(usize, 8), fields[1].offset);
    try std.testing.expectEqual(@as(usize, 32), fields[1].size);
    try std.testing.expectEqual(@as(usize, 40), size);
}

test "a bound the header never defines fails instead of guessing" {
    const text =
        \\typedef struct nope {
        \\    float values[NOT_DEFINED_ANYWHERE];
        \\} nope;
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var size: usize = 0;
    var alignment: usize = 1;
    try std.testing.expectError(error.BadArrayBound, headerLayout(arena.allocator(), text, "nope", &size, &alignment, 4));
}

test "a typed declaration is a value and a use of the name is not" {
    // Kotlin spells the type between the name and the value, which read as absent
    // and left the engine's own major unchecked on that SDK.
    try std.testing.expectEqual(@as(?usize, 0), declaredNumber("const val GOSS_ABI_MAJOR: Int = 0", "GOSS_ABI_MAJOR"));
    try std.testing.expectEqual(@as(?usize, 120), declaredNumber("const val ENGINE_REPORT_BYTES: Int = 120", "ENGINE_REPORT_BYTES"));
    try std.testing.expectEqual(@as(?usize, 7), declaredNumber("export const N = 7;", "N"));
    try std.testing.expectEqual(@as(?usize, 4), declaredNumber("#define N 4", "N"));
    // A use carries a number that is not the declaration's.
    try std.testing.expectEqual(@as(?usize, null), declaredNumber("nativeAbiCheck(GOSS_ABI_MAJOR shl 16)", "GOSS_ABI_MAJOR"));
}

test "a define is read by its whole name, not by a prefix of a longer one" {
    const text =
        \\#define COUNT_LONGER 9u
        \\#define COUNT 2u
        \\typedef struct pick {
        \\    float values[COUNT];
        \\} pick;
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var size: usize = 0;
    var alignment: usize = 1;
    const fields = try headerLayout(arena.allocator(), text, "pick", &size, &alignment, 4);
    try std.testing.expectEqual(@as(usize, 8), fields[0].size);
}
