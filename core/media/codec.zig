//! Encoder and decoder contracts as explicit state machines. The adapter's
//! surface was open, feed, finish with three error values, so a frame fed after
//! finish, a finish with no frames, or a feed on an errored handle were all
//! undefined rather than refused.

const std = @import("std");
const types = @import("types.zig");
const packet = @import("packet.zig");

/// Where a codec is in its life. A call that does not belong in the current
/// state is refused by name, so a backend never has to guess what a host meant.
pub const State = enum(u32) {
    /// Created and described, nothing fed yet.
    configured = 0,
    /// At least one frame in, more accepted.
    running = 1,
    /// No more input; the backend is handing back what it still holds.
    draining = 2,
    /// Drained and finalized. Nothing more comes out.
    flushed = 3,
    /// A failure the caller has not cleared. Every call but reset is refused.
    errored = 4,
};

pub const Error = error{
    /// The call does not belong in the current state.
    InvalidState,
    /// The descriptor was refused before any backend work.
    InvalidConfiguration,
    /// The backend refused the configuration it was handed.
    Unsupported,
    /// The backend failed while running; the machine is errored until reset.
    Backend,
    OutOfMemory,
};

/// The transitions, held apart from any backend so the rules are testable on
/// their own and every backend obeys the same ones.
pub const Machine = struct {
    state: State = .configured,

    /// Accepting input: from configured it starts the run, from running it stays.
    pub fn feed(m: *Machine) Error!void {
        switch (m.state) {
            .configured, .running => m.state = .running,
            .draining, .flushed, .errored => return error.InvalidState,
        }
    }

    /// End of input. A codec that was never fed still drains, so a zero-frame
    /// recording finalizes to an empty file rather than refusing to close.
    pub fn drain(m: *Machine) Error!void {
        switch (m.state) {
            .configured, .running => m.state = .draining,
            .draining => {},
            .flushed, .errored => return error.InvalidState,
        }
    }

    /// The drain produced its last packet.
    pub fn finish(m: *Machine) Error!void {
        switch (m.state) {
            .draining => m.state = .flushed,
            .flushed => {},
            .configured, .running, .errored => return error.InvalidState,
        }
    }

    /// A backend failure. Recorded rather than returned and forgotten, so a host
    /// that keeps calling gets InvalidState instead of undefined behaviour.
    pub fn fail(m: *Machine) void {
        m.state = .errored;
    }

    /// Back to configured, the one call an errored machine accepts.
    pub fn reset(m: *Machine) void {
        m.state = .configured;
    }

    pub fn acceptsInput(m: Machine) bool {
        return m.state == .configured or m.state == .running;
    }

    pub fn producesOutput(m: Machine) bool {
        return m.state == .running or m.state == .draining;
    }
};

/// What an encoder was asked to make, checked before any backend sees it.
pub const EncoderConfig = struct {
    video: types.EncodedVideoDesc,
    audio: ?types.EncodedAudioDesc = null,
    container: types.Container,

    pub fn check(c: EncoderConfig) Error!void {
        if (!c.video.valid()) return error.InvalidConfiguration;
        const audio = c.audio orelse {
            // A video-only file still has to be a pair the container carries, so
            // check against the codec's own default audio rather than skipping.
            if (!c.container.carries(c.video.codec, if (c.container == .webm) .opus else .aac)) return error.InvalidConfiguration;
            return;
        };
        if (!audio.valid()) return error.InvalidConfiguration;
        if (!c.container.carries(c.video.codec, audio.codec)) return error.InvalidConfiguration;
    }
};

/// What a decoder found, filled from a demuxed stream rather than requested. The
/// demuxer that fills it is demux.zig; until that existed this said so with nothing
/// behind it.
pub const DecoderConfig = struct {
    video: types.EncodedVideoDesc,
    audio: ?types.EncodedAudioDesc = null,
    timebase: packet.Timebase,

    pub fn check(c: DecoderConfig) Error!void {
        if (!c.video.valid()) return error.InvalidConfiguration;
        if (!c.timebase.valid()) return error.InvalidConfiguration;
        if (c.audio) |a| {
            if (!a.valid()) return error.InvalidConfiguration;
        }
    }
};

const t = std.testing;

test "the run walks configured, running, draining, flushed" {
    var m: Machine = .{};
    try t.expectEqual(State.configured, m.state);
    try m.feed();
    try t.expectEqual(State.running, m.state);
    try m.feed();
    try t.expectEqual(State.running, m.state);
    try m.drain();
    try t.expectEqual(State.draining, m.state);
    try m.finish();
    try t.expectEqual(State.flushed, m.state);
}

test "a feed after the drain is refused rather than undefined" {
    var m: Machine = .{};
    try m.feed();
    try m.drain();
    try t.expectError(error.InvalidState, m.feed());
    try m.finish();
    try t.expectError(error.InvalidState, m.feed());
    try t.expectError(error.InvalidState, m.drain());
}

test "a codec that was never fed still drains to an empty file" {
    var m: Machine = .{};
    try m.drain();
    try m.finish();
    try t.expectEqual(State.flushed, m.state);
}

test "drain and finish are idempotent, so a double close is not an error" {
    var m: Machine = .{};
    try m.feed();
    try m.drain();
    try m.drain();
    try m.finish();
    try m.finish();
    try t.expectEqual(State.flushed, m.state);
}

test "an errored machine refuses everything until it is reset" {
    var m: Machine = .{};
    try m.feed();
    m.fail();
    try t.expectError(error.InvalidState, m.feed());
    try t.expectError(error.InvalidState, m.drain());
    try t.expectError(error.InvalidState, m.finish());
    m.reset();
    try m.feed();
    try t.expectEqual(State.running, m.state);
}

test "input and output windows are the states, not a separate flag" {
    var m: Machine = .{};
    try t.expect(m.acceptsInput());
    try t.expect(!m.producesOutput());
    try m.feed();
    try t.expect(m.acceptsInput() and m.producesOutput());
    try m.drain();
    try t.expect(!m.acceptsInput() and m.producesOutput());
    try m.finish();
    try t.expect(!m.acceptsInput() and !m.producesOutput());
}

test "an encoder configuration the container cannot carry is refused" {
    const hd: types.EncodedVideoDesc = .{ .width = 1920, .height = 1080, .codec = .h264 };
    try (EncoderConfig{ .video = hd, .audio = .{ .codec = .aac }, .container = .mp4 }).check();
    try t.expectError(error.InvalidConfiguration, (EncoderConfig{ .video = hd, .audio = .{ .codec = .opus }, .container = .mp4 }).check());
    const vp9: types.EncodedVideoDesc = .{ .width = 1920, .height = 1080, .codec = .vp9 };
    try (EncoderConfig{ .video = vp9, .audio = .{ .codec = .opus }, .container = .webm }).check();
    try t.expectError(error.InvalidConfiguration, (EncoderConfig{ .video = vp9, .audio = .{ .codec = .opus }, .container = .mp4 }).check());
}

test "a video-only configuration is still checked against the container" {
    const vp9: types.EncodedVideoDesc = .{ .width = 640, .height = 480, .codec = .vp9 };
    try (EncoderConfig{ .video = vp9, .container = .webm }).check();
    // vp9 has no mp4 mapping the engine writes, audio or not.
    try t.expectError(error.InvalidConfiguration, (EncoderConfig{ .video = vp9, .container = .mp4 }).check());
}

test "a decoder configuration needs a timebase" {
    const hd: types.EncodedVideoDesc = .{ .width = 1280, .height = 720, .codec = .h264 };
    try (DecoderConfig{ .video = hd, .timebase = .microseconds }).check();
    try t.expectError(error.InvalidConfiguration, (DecoderConfig{ .video = hd, .timebase = .{ .num = 1, .den = 0 } }).check());
    try t.expectError(error.InvalidConfiguration, (DecoderConfig{ .video = hd, .timebase = .microseconds, .audio = .{ .codec = .opus, .sample_rate = 44_100 } }).check());
}
