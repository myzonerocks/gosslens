//! The headless lifecycle scenario as a standalone binary. The test
//! variant gates zig allocations with a debug allocator; wrapping this
//! binary in the platform's malloc leak checker extends the identical
//! scenario to the C and C++ heaps the vendored engines allocate on.

const std = @import("std");
const lifecycle = @import("lifecycle_proof");

pub fn main(init_args: std.process.Init) !u8 {
    _ = init_args;
    if (!try lifecycle.proveHeadlessLifecycle()) return 1;
    std.debug.print("leak-scenario: headless lifecycle complete, zig heap clean\n", .{});
    return 0;
}
