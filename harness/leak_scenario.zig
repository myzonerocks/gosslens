//! The lifecycle scenario as a standalone binary. The test variant gates zig
//! allocations with a debug allocator; the platform leak checker and guard
//! malloc extend the same scenario to the C and C++ heaps, and -Dasan adds
//! redzones and a free quarantine to every one of those blocks.

const std = @import("std");
const lifecycle = @import("lifecycle_proof");

pub fn main(init_args: std.process.Init) !u8 {
    if (!try lifecycle.proveHeadlessLifecycle(init_args.io)) return 1;
    std.debug.print("leak-scenario: lifecycle complete over two rounds, zig heap clean\n", .{});
    return 0;
}
