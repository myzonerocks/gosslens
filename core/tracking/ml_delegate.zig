//! The inference delegate scheduler: which accelerator the runtime tries for a
//! model on a given target, and the CPU delegate it always falls back to. The
//! decision is pure so it is unit-tested here; the runtime binding creates the
//! actual delegates in this order and keeps the first that builds.

const std = @import("std");

/// What a caller asks for: `auto` unless somebody says otherwise, `cpu` for the
/// portable XNNPACK path the conformance run uses, `neural` for the platform's
/// accelerator by name. On Apple `auto` is not the accelerator - see the note
/// on delegateOrderFor for what the CoreML delegate does on a device.
pub const Accelerator = enum { auto, cpu, neural };

/// A concrete delegate. nnapi is Android's NPU/GPU/DSP path, coreml is Apple's
/// Neural Engine path, xnnpack is the tuned CPU path that is always available.
pub const Backend = enum { nnapi, coreml, xnnpack };

/// At most an accelerator plus the CPU fallback.
pub const max_backends = 2;

/// The delegates to try for `requested`, most accelerated first and always
/// ending at xnnpack. Apple's accelerator is opt-in: tflite's CoreML delegate
/// builds against the face landmark model and then segfaults at invoke on
/// iPhone W, and a crash cannot be caught and fallen back from.
pub fn delegateOrderFor(requested: Accelerator, os_tag: std.Target.Os.Tag, is_android: bool, buf: *[max_backends]Backend) []Backend {
    var n: usize = 0;
    // Android's own accelerator is the default; Apple's is opt-in, for the
    // reason written on Accelerator above.
    const wants_accelerator = requested == .neural or (requested == .auto and is_android);
    if (wants_accelerator) {
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

test "ios auto runs on the cpu path, because coreml crashes at invoke on device" {
    var buf: [max_backends]Backend = undefined;
    const order = delegateOrderFor(.auto, .ios, false, &buf);
    try testing.expectEqualSlices(Backend, &.{.xnnpack}, order);
}

test "ios asked for the neural engine still gets it, ahead of the cpu" {
    var buf: [max_backends]Backend = undefined;
    const order = delegateOrderFor(.neural, .ios, false, &buf);
    try testing.expectEqualSlices(Backend, &.{ .coreml, .xnnpack }, order);
}

test "android auto still leads with its own accelerator" {
    var buf: [max_backends]Backend = undefined;
    const order = delegateOrderFor(.auto, .linux, true, &buf);
    try testing.expectEqualSlices(Backend, &.{ .nnapi, .xnnpack }, order);
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
