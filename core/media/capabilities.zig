//! Which backend serves a request, decided from declared capability rather than
//! from a compile-time constant. The adapters each exported `supported` and
//! `audio_supported` as the whole answer, so the engine could not say what a
//! target encodes, only whether a backend existed at all.

const std = @import("std");
const types = @import("types.zig");

/// What one backend declares it can do. Measured and written down per platform
/// floor, never inferred: a backend that claims hevc on a device whose encoder
/// refuses it produces a recording that fails at the first frame.
pub const Backend = struct {
    /// For diagnostics only. No selection reads it, so a host cannot pin a
    /// backend by name and make its own platform the contract again.
    name: []const u8,
    video: []const VideoProfile,
    audio: []const types.AudioCodec,
    containers: []const types.Container,
    /// Whether this backend takes a platform texture or buffer with no copy.
    zero_copy: bool = false,
    /// Lower wins when two backends both serve a request. Hardware sits below
    /// software so native is preferred without naming it.
    rank: u8 = 100,

    pub const VideoProfile = struct {
        codec: types.VideoCodec,
        max_width: u32,
        max_height: u32,
        max_bit_depth: u8 = 8,
        /// The highest transfer this profile writes, so an hdr request does not
        /// land on a backend that would silently tone-map it.
        hdr: bool = false,
    };

    fn servesVideo(b: Backend, want: types.EncodedVideoDesc) bool {
        for (b.video) |p| {
            if (p.codec != want.codec) continue;
            if (want.width > p.max_width or want.height > p.max_height) continue;
            if (want.color.bit_depth > p.max_bit_depth) continue;
            if (want.color.isHdr() and !p.hdr) continue;
            return true;
        }
        return false;
    }

    fn servesAudio(b: Backend, want: types.AudioCodec) bool {
        for (b.audio) |c| {
            if (c == want) return true;
        }
        return false;
    }

    fn servesContainer(b: Backend, want: types.Container) bool {
        for (b.containers) |k| {
            if (k == want) return true;
        }
        return false;
    }
};

/// One request, exactly as a host configured it.
pub const Request = struct {
    video: types.EncodedVideoDesc,
    audio: ?types.AudioCodec = null,
    container: types.Container,
    /// Set when the caller needs the no-copy path, which rules out every backend
    /// that would make the engine read the frame back.
    require_zero_copy: bool = false,
};

pub const Error = error{
    /// No registered backend serves the request. The caller degrades or tells the
    /// host, rather than trying one and finding out at the first frame.
    NoBackend,
};

/// Picks the backend for a request. Deterministic: the lowest rank that serves
/// it, and among equal ranks the one registered first, so the same request on the
/// same build always lands on the same backend.
pub fn select(backends: []const Backend, req: Request) Error!usize {
    var best: ?usize = null;
    for (backends, 0..) |b, i| {
        if (req.require_zero_copy and !b.zero_copy) continue;
        if (!b.servesContainer(req.container)) continue;
        if (!b.servesVideo(req.video)) continue;
        if (req.audio) |a| {
            if (!b.servesAudio(a)) continue;
        }
        const current = best orelse {
            best = i;
            continue;
        };
        if (b.rank < backends[current].rank) best = i;
    }
    return best orelse error.NoBackend;
}

const t = std.testing;

const hardware: Backend = .{
    .name = "hardware",
    .video = &.{
        .{ .codec = .h264, .max_width = 4096, .max_height = 2160 },
        .{ .codec = .hevc, .max_width = 4096, .max_height = 2160, .max_bit_depth = 10, .hdr = true },
    },
    .audio = &.{.aac},
    .containers = &.{ .mp4, .mov },
    .zero_copy = true,
    .rank = 10,
};

const software: Backend = .{
    .name = "software",
    .video = &.{
        .{ .codec = .h264, .max_width = 1920, .max_height = 1080 },
        .{ .codec = .vp9, .max_width = 1920, .max_height = 1080 },
    },
    .audio = &.{ .opus, .pcm },
    .containers = &.{ .webm, .mp4 },
    .rank = 50,
};

test "hardware wins by rank without being named" {
    const chosen = try select(&.{ software, hardware }, .{
        .video = .{ .width = 1920, .height = 1080, .codec = .h264 },
        .audio = .aac,
        .container = .mp4,
    });
    try t.expectEqualStrings("hardware", (&[_]Backend{ software, hardware })[chosen].name);
}

test "a request past the hardware profile falls to software" {
    // vp9 is software only here, so the container and codec pick it.
    const set = [_]Backend{ hardware, software };
    const chosen = try select(&set, .{
        .video = .{ .width = 1280, .height = 720, .codec = .vp9 },
        .audio = .opus,
        .container = .webm,
    });
    try t.expectEqualStrings("software", set[chosen].name);
}

test "a resolution past every profile has no backend" {
    const set = [_]Backend{ hardware, software };
    try t.expectError(error.NoBackend, select(&set, .{
        .video = .{ .width = 8192, .height = 4320, .codec = .h264 },
        .audio = .aac,
        .container = .mp4,
    }));
}

test "hdr needs a profile that declares it, not merely the bit depth" {
    const set = [_]Backend{ hardware, software };
    const hdr: types.EncodedVideoDesc = .{
        .width = 3840,
        .height = 2160,
        .codec = .hevc,
        .color = .{ .transfer = .pq, .bit_depth = 10, .primaries = .bt2020, .matrix = .bt2020_ncl },
    };
    const chosen = try select(&set, .{ .video = hdr, .audio = .aac, .container = .mov });
    try t.expectEqualStrings("hardware", set[chosen].name);
    // The same request over h264, which no profile here writes at ten bits.
    var as_h264 = hdr;
    as_h264.codec = .h264;
    try t.expectError(error.NoBackend, select(&set, .{ .video = as_h264, .audio = .aac, .container = .mp4 }));
}

test "a zero-copy requirement rules out a backend that would copy" {
    const set = [_]Backend{software};
    try t.expectError(error.NoBackend, select(&set, .{
        .video = .{ .width = 1280, .height = 720, .codec = .h264 },
        .audio = .opus,
        .container = .mp4,
        .require_zero_copy = true,
    }));
}

test "an audio codec a backend does not encode rules it out" {
    const set = [_]Backend{hardware};
    try t.expectError(error.NoBackend, select(&set, .{
        .video = .{ .width = 1920, .height = 1080, .codec = .h264 },
        .audio = .opus,
        .container = .mp4,
    }));
    // Video only: the same backend serves it.
    _ = try select(&set, .{ .video = .{ .width = 1920, .height = 1080, .codec = .h264 }, .container = .mp4 });
}

test "selection is deterministic across equal ranks" {
    const first: Backend = .{ .name = "first", .video = &.{.{ .codec = .h264, .max_width = 1920, .max_height = 1080 }}, .audio = &.{.aac}, .containers = &.{.mp4}, .rank = 30 };
    const second: Backend = .{ .name = "second", .video = &.{.{ .codec = .h264, .max_width = 1920, .max_height = 1080 }}, .audio = &.{.aac}, .containers = &.{.mp4}, .rank = 30 };
    const set = [_]Backend{ first, second };
    const req: Request = .{ .video = .{ .width = 1920, .height = 1080, .codec = .h264 }, .audio = .aac, .container = .mp4 };
    // Registered order breaks the tie, the same way every time.
    try t.expectEqualStrings("first", set[try select(&set, req)].name);
    try t.expectEqualStrings("first", set[try select(&set, req)].name);
}

test "an empty registry has no backend rather than a default" {
    try t.expectError(error.NoBackend, select(&.{}, .{
        .video = .{ .width = 640, .height = 480, .codec = .h264 },
        .container = .mp4,
    }));
}
