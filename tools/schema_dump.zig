//! Prints the snapshot record's schema as deterministic text and checks it
//! against the tracked baseline, so reordering or dropping a field shows up in
//! review rather than as a consumer reading the wrong bytes.

// Usage: schema_dump --print | --check <baseline> | --update <baseline>

const std = @import("std");
const perception = @import("perception");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.next();
    const mode = args.next() orelse {
        std.debug.print("schema-dump: usage: schema_dump --print | --check <baseline> | --update <baseline>\n", .{});
        return 2;
    };

    var text: std.Io.Writer.Allocating = .init(arena);
    try perception.schema.write(&text.writer);
    const current = text.writer.buffered();

    if (std.mem.eql(u8, mode, "--print")) {
        std.debug.print("{s}", .{current});
        return 0;
    }

    const baseline_path = args.next() orelse "tools/snapshot-baseline.txt";
    if (std.mem.eql(u8, mode, "--update")) {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = baseline_path, .data = current });
        std.debug.print("schema-dump: wrote {s}\n", .{baseline_path});
        return 0;
    }
    if (!std.mem.eql(u8, mode, "--check")) {
        std.debug.print("schema-dump: unknown mode {s}\n", .{mode});
        return 2;
    }

    const baseline = std.Io.Dir.cwd().readFileAlloc(init.io, baseline_path, arena, .limited(1 << 20)) catch {
        std.debug.print("schema-dump: {s} is missing; run `zig build schema-update`\n", .{baseline_path});
        return 1;
    };
    if (std.mem.eql(u8, baseline, current)) {
        std.debug.print("schema-dump: the snapshot schema matches {s}\n", .{baseline_path});
        return 0;
    }
    // Name the first line that differs, so a reader is sent to a field rather
    // than to a file.
    var want = std.mem.splitScalar(u8, baseline, '\n');
    var got = std.mem.splitScalar(u8, current, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const a = want.next();
        const b = got.next();
        if (a == null and b == null) break;
        if (a == null or b == null or !std.mem.eql(u8, a.?, b.?)) {
            std.debug.print("schema-dump: the snapshot schema drifted at line {d}\n  baseline: {s}\n  current:  {s}\n", .{
                line, a orelse "(end)", b orelse "(end)",
            });
            break;
        }
    }
    std.debug.print("schema-dump: run `zig build schema-update` if the change is intended\n", .{});
    return 1;
}
