//! Fails the build when a linked wasm artifact is missing the engine: the
//! export section must carry goss_abi_version and a healthy count of goss_*
//! functions. A lazy archive link that drops the Zig object ships a wasm of
//! vendor symbols only; this check turns that into a build error.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("wasm-exports-check: usage: wasm_exports_check <artifact.wasm>\n", .{});
        return 2;
    };
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(256 * 1024 * 1024));
    defer gpa.free(data);
    if (data.len < 8 or !std.mem.eql(u8, data[0..4], "\x00asm")) {
        std.debug.print("wasm-exports-check: {s} is not a wasm binary\n", .{path});
        return 1;
    }

    var goss_count: usize = 0;
    var has_abi_version = false;
    var pos: usize = 8;
    while (pos < data.len) {
        const section = data[pos];
        pos += 1;
        const size = try uleb(data, &pos);
        const section_end = pos + size;
        if (section == 7) {
            var count = try uleb(data, &pos);
            while (count > 0) : (count -= 1) {
                const name_len = try uleb(data, &pos);
                if (pos + name_len > data.len) return error.Truncated;
                const name = data[pos .. pos + name_len];
                pos += name_len;
                pos += 1; // export kind
                _ = try uleb(data, &pos);
                if (std.mem.startsWith(u8, name, "goss_")) goss_count += 1;
                if (std.mem.eql(u8, name, "goss_abi_version")) has_abi_version = true;
            }
        }
        pos = section_end;
    }

    if (!has_abi_version or goss_count < 100) {
        std.debug.print("wasm-exports-check: {s} exports {d} goss_* symbols (abi_version {}); the engine object was dropped at link\n", .{ path, goss_count, has_abi_version });
        return 1;
    }
    return 0;
}

fn uleb(data: []const u8, pos: *usize) !usize {
    var result: usize = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        result |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
        if (shift > 34) return error.Overflow;
    }
    return error.Truncated;
}
