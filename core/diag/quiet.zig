//! Silences the C stderr for the span of a call, and puts it back. A vendor shim
//! logs a caught exception with fprintf, so a test that deliberately causes one
//! writes to stderr, and zig's test stdio mode fails the step on any unexpected
//! stderr however the tests themselves reported.

const std = @import("std");

/// The saved descriptor, restored by `restore`. Null when the redirect could not
/// be made, in which case the call still runs and the log still appears.
pub const Quiet = struct {
    saved: ?c_int = null,

    pub fn start() Quiet {
        const stderr_fd: c_int = 2;
        const saved = std.c.dup(stderr_fd);
        if (saved < 0) return .{};
        const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (null_fd < 0) {
            _ = std.c.close(saved);
            return .{};
        }
        _ = std.c.dup2(null_fd, stderr_fd);
        _ = std.c.close(null_fd);
        return .{ .saved = saved };
    }

    pub fn restore(q: *Quiet) void {
        const saved = q.saved orelse return;
        _ = std.c.dup2(saved, 2);
        _ = std.c.close(saved);
        q.saved = null;
    }
};

test "a redirect is made and put back" {
    var q = Quiet.start();
    try std.testing.expect(q.saved != null);
    q.restore();
    try std.testing.expect(q.saved == null);
    // Restoring twice is a no-op rather than a double close.
    q.restore();
}
