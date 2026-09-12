//! Mux and demux contracts: the track and sample model, the header, the index,
//! and the fragment boundary. The adapter had no container model, so a pause, an
//! interruption and a multi-clip recording had nothing to be recorded against.

const std = @import("std");
const types = @import("types.zig");
const packet = @import("packet.zig");

pub const TrackKind = enum(u32) { video = 0, audio = 1 };

/// One track a muxer writes or a demuxer found.
pub const Track = struct {
    kind: TrackKind,
    index: u32,
    timebase: packet.Timebase,
    video: ?types.EncodedVideoDesc = null,
    audio: ?types.EncodedAudioDesc = null,

    pub fn valid(tr: Track) bool {
        if (!tr.timebase.valid()) return false;
        return switch (tr.kind) {
            .video => tr.video != null and tr.video.?.valid() and tr.audio == null,
            .audio => tr.audio != null and tr.audio.?.valid() and tr.video == null,
        };
    }
};

/// A declared break in a track's timeline, which a muxer handles rather than
/// writing a file whose timestamps jump with nothing to explain them.
pub const Discontinuity = enum(u32) {
    /// A pause and resume: the clock holds, so the output has no gap.
    pause = 0,
    /// The camera went away and came back.
    camera_lost = 1,
    /// The audio route changed, so the sample rate or channel count may have.
    audio_route = 2,
    /// The app was backgrounded.
    backgrounded = 3,
    /// Thermal pressure stopped the encoder.
    thermal = 4,
};

pub const Error = error{
    InvalidState,
    /// A track, packet or boundary that the model refuses.
    InvalidArgument,
    Unsupported,
    Backend,
    OutOfMemory,
};

/// What a muxer has done so far. Tracks are added before the header; packets
/// only after it; the index only at the end. Out of order is refused by name.
pub const MuxState = enum(u32) {
    /// Tracks may be added. No bytes written.
    declaring = 0,
    /// Header written, tracks frozen, packets accepted.
    writing = 1,
    /// Index and trailer written. Nothing more.
    finalized = 2,
    errored = 3,
};

/// The muxer's rules, free of any backend. A clip counter lives here because
/// pause and resume producing clip boundaries is a property of the model, not of
/// whichever library writes the bytes.
pub const Muxer = struct {
    state: MuxState = .declaring,
    track_count: u32 = 0,
    /// Clips the pause and resume pairs have produced, counting from one.
    clip_count: u32 = 1,
    /// Packets written since the header, across every track.
    packets: u64 = 0,
    /// The highest presentation time written, in microseconds, which is the
    /// duration a host reads and the floor the next packet must not go under.
    last_pts_us: i64 = 0,

    pub fn addTrack(m: *Muxer, tr: Track) Error!u32 {
        if (m.state != .declaring) return error.InvalidState;
        if (!tr.valid()) return error.InvalidArgument;
        const index = m.track_count;
        m.track_count += 1;
        return index;
    }

    /// Freezes the tracks and writes the header. A file with no track is refused
    /// here rather than produced and found unplayable.
    pub fn writeHeader(m: *Muxer) Error!void {
        if (m.state != .declaring) return error.InvalidState;
        if (m.track_count == 0) return error.InvalidArgument;
        m.state = .writing;
    }

    pub fn writePacket(m: *Muxer, p: packet.Packet) Error!void {
        if (m.state != .writing) return error.InvalidState;
        if (!p.valid()) return error.InvalidArgument;
        if (p.track >= m.track_count) return error.InvalidArgument;
        const pts_us = p.ptsMicros();
        // A packet that goes backwards in time is the symptom of a clock that was
        // not held across a pause, which is the defect this model exists to stop.
        if (pts_us < m.last_pts_us) return error.InvalidArgument;
        m.last_pts_us = pts_us;
        m.packets += 1;
    }

    /// A declared break. Counted as a clip boundary for a pause, which is what
    /// makes multi-clip recording fall out of pause and resume.
    pub fn note(m: *Muxer, kind: Discontinuity) Error!void {
        if (m.state != .writing) return error.InvalidState;
        if (kind == .pause) m.clip_count += 1;
    }

    pub fn finalize(m: *Muxer) Error!void {
        switch (m.state) {
            .writing => m.state = .finalized,
            .finalized => {},
            .declaring, .errored => return error.InvalidState,
        }
    }

    pub fn fail(m: *Muxer) void {
        m.state = .errored;
    }

    pub fn durationUs(m: Muxer) i64 {
        return m.last_pts_us;
    }
};

const t = std.testing;

fn hdTrack() Track {
    return .{
        .kind = .video,
        .index = 0,
        .timebase = .microseconds,
        .video = .{ .width = 1920, .height = 1080, .codec = .h264 },
    };
}

test "tracks are declared, then frozen by the header" {
    var m: Muxer = .{};
    try t.expectEqual(@as(u32, 0), try m.addTrack(hdTrack()));
    try m.writeHeader();
    try t.expectEqual(MuxState.writing, m.state);
    // A track after the header would change a header already written.
    try t.expectError(error.InvalidState, m.addTrack(hdTrack()));
}

test "a file with no track is refused rather than written" {
    var m: Muxer = .{};
    try t.expectError(error.InvalidArgument, m.writeHeader());
    try t.expectEqual(MuxState.declaring, m.state);
}

test "a track that carries both kinds of description is not a track" {
    var m: Muxer = .{};
    var both = hdTrack();
    both.audio = .{ .codec = .aac };
    try t.expectError(error.InvalidArgument, m.addTrack(both));
    var neither = hdTrack();
    neither.video = null;
    try t.expectError(error.InvalidArgument, m.addTrack(neither));
}

test "a packet before the header or on an unknown track is refused" {
    const bytes = [_]u8{ 1, 2 };
    const p: packet.Packet = .{ .payload = &bytes, .timebase = .microseconds, .pts = 0, .dts = 0 };
    var m: Muxer = .{};
    try t.expectError(error.InvalidState, m.writePacket(p));
    _ = try m.addTrack(hdTrack());
    try m.writeHeader();
    try m.writePacket(p);
    var wrong_track = p;
    wrong_track.track = 7;
    try t.expectError(error.InvalidArgument, m.writePacket(wrong_track));
}

test "a packet that goes backwards in time is the unheld clock, and is refused" {
    const bytes = [_]u8{1};
    var m: Muxer = .{};
    _ = try m.addTrack(hdTrack());
    try m.writeHeader();
    try m.writePacket(.{ .payload = &bytes, .timebase = .microseconds, .pts = 1_000, .dts = 1_000 });
    try m.writePacket(.{ .payload = &bytes, .timebase = .microseconds, .pts = 2_000, .dts = 2_000 });
    try t.expectError(error.InvalidArgument, m.writePacket(.{ .payload = &bytes, .timebase = .microseconds, .pts = 1_500, .dts = 1_500 }));
    // The same stamp twice is fine: two tracks can share an instant.
    try m.writePacket(.{ .payload = &bytes, .timebase = .microseconds, .pts = 2_000, .dts = 2_000 });
    try t.expectEqual(@as(i64, 2_000), m.durationUs());
}

test "pause and resume produce the clip boundaries, other breaks do not" {
    const bytes = [_]u8{1};
    var m: Muxer = .{};
    _ = try m.addTrack(hdTrack());
    try m.writeHeader();
    try m.writePacket(.{ .payload = &bytes, .timebase = .microseconds, .pts = 0, .dts = 0 });
    try t.expectEqual(@as(u32, 1), m.clip_count);
    try m.note(.pause);
    try t.expectEqual(@as(u32, 2), m.clip_count);
    // A camera loss is a break in one clip, not the start of another.
    try m.note(.camera_lost);
    try m.note(.thermal);
    try t.expectEqual(@as(u32, 2), m.clip_count);
}

test "finalize is idempotent and refuses a file that never opened" {
    var m: Muxer = .{};
    try t.expectError(error.InvalidState, m.finalize());
    _ = try m.addTrack(hdTrack());
    try m.writeHeader();
    try m.finalize();
    try m.finalize();
    try t.expectEqual(MuxState.finalized, m.state);
    const bytes = [_]u8{1};
    try t.expectError(error.InvalidState, m.writePacket(.{ .payload = &bytes, .timebase = .microseconds, .pts = 9_000, .dts = 9_000 }));
}

test "a failed muxer refuses its own finalize, so an abort cannot write a trailer" {
    var m: Muxer = .{};
    _ = try m.addTrack(hdTrack());
    try m.writeHeader();
    m.fail();
    try t.expectError(error.InvalidState, m.finalize());
    try t.expectError(error.InvalidState, m.note(.pause));
}
