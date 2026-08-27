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

const abi_functions = abi.abi_functions;

fn writeSurface(w: anytype) !void {
    try w.print("abi {d}.{d}\n", .{ abi.abi_major, abi.abi_minor });
    inline for (abi_types) |T| {
        try w.print("type {s} size={d} align={d}\n", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
        inline for (@typeInfo(T).@"struct".fields) |field| {
            try w.print("  field {s} offset={d} size={d}\n", .{ field.name, @offsetOf(T, field.name), @sizeOf(field.type) });
        }
    }
    for (abi_functions) |f| {
        try w.print("fn {s}\n", .{f});
    }
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
        const stamped = stampHeaderMinor(arena, header, abi.abi_minor) catch {
            std.debug.print("abi_dump: {s} not found in {s}\n", .{ minor_key, header_path });
            return 1;
        };
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
