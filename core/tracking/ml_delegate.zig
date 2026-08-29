//! The inference delegate scheduler: which accelerator the runtime tries for a
//! model on a given target, and the CPU delegate it always falls back to. The
//! decision is pure so it is unit-tested here; the runtime binding creates the
//! actual delegates in this order and keeps the first that builds.

const std = @import("std");

/// What a caller asks for. `auto` takes the platform's accelerator when there is
/// one; `cpu` forces the portable XNNPACK path, which is what the deterministic
/// conformance run and any accelerator-less target use.
pub const Accelerator = enum { auto, cpu };

/// A concrete delegate. nnapi is Android's NPU/GPU/DSP path, coreml is Apple's
/// Neural Engine path, xnnpack is the tuned CPU path that is always available.
pub const Backend = enum { nnapi, coreml, xnnpack };

/// At most an accelerator plus the CPU fallback.
pub const max_backends = 2;

/// The delegates to try for `requested` on this target, most accelerated first
/// and always ending at xnnpack. `auto` puts the platform accelerator ahead of
/// the CPU path; a target with none, or `cpu`, yields xnnpack alone.
pub fn delegateOrderFor(requested: Accelerator, os_tag: std.Target.Os.Tag, is_android: bool, buf: *[max_backends]Backend) []Backend {
    var n: usize = 0;
    if (requested == .auto) {
        if (is_android) {
            buf[n] = .nnapi;
            n += 1;
        } else switch (os_tag) {
            .ios, .tvos => {
                buf[n] = .coreml;
                n += 1;
            },
            else => {},
        }
    }
    buf[n] = .xnnpack;
    n += 1;
    return buf[0..n];
}

const testing = std.testing;

test "android auto tries nnapi then falls back to cpu" {
    var buf: [max_backends]Backend = undefined;
    const order = delegateOrderFor(.auto, .linux, true, &buf);
    try testing.expectEqualSlices(Backend, &.{ .nnapi, .xnnpack }, order);
}

test "ios auto tries coreml then falls back to cpu" {
    var buf: [max_backends]Backend = undefined;
    const order = delegateOrderFor(.auto, .ios, false, &buf);
    try testing.expectEqualSlices(Backend, &.{ .coreml, .xnnpack }, order);
}

test "a target with no accelerator resolves to cpu alone" {
    var buf: [max_backends]Backend = undefined;
    const order = delegateOrderFor(.auto, .macos, false, &buf);
    try testing.expectEqualSlices(Backend, &.{.xnnpack}, order);
}

test "cpu forces xnnpack even where an accelerator exists" {
    var buf: [max_backends]Backend = undefined;
    const order = delegateOrderFor(.cpu, .ios, false, &buf);
    try testing.expectEqualSlices(Backend, &.{.xnnpack}, order);
}
