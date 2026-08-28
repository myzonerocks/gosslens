//! The target-independent leak gate. The engine and session lifecycle
//! allocate and free with no renderer, so this proof runs on every
//! platform's `zig build ci`, not only the macOS conformance host. A
//! leak in session setup or the session registry surfaces here.

const std = @import("std");
const abi = @import("abi");

/// Repeated create, tick, pull, and destroy over one engine, watched by
/// a debug allocator so any allocation left behind across the cycles
/// fails the proof. Returns false on a leak, true when the whole run
/// frees to nothing.
pub fn proveHeadlessLifecycle() !bool {
    var check: std.heap.DebugAllocator(.{}) = .init;
    const leak_gpa = check.allocator();
    {
        const engine = try abi.createEngine(leak_gpa, .{ .texture_pool_capacity = 4, .staging_pool_capacity = 4 });
        defer abi.destroyEngine(engine);
        var cycle: usize = 0;
        while (cycle < 32) : (cycle += 1) {
            const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            var signals = std.mem.zeroes(abi.LensSignals);
            signals.has_face = true;
            var t: u32 = 0;
            while (t < 4) : (t += 1) _ = abi.goss_session_tick_lens(session, 33_333, &signals);
            var block: [256]i16 = undefined;
            _ = abi.goss_session_pull_audio(session, &block, 256);
        }
    }
    if (check.deinit() == .leak) {
        std.debug.print("lifecycle: FAIL the headless engine and session lifecycle leaked across create/tick/destroy cycles\n", .{});
        return false;
    }
    return true;
}

test "the headless engine and session lifecycle leaks nothing" {
    try std.testing.expect(try proveHeadlessLifecycle());
}
