//! The media contracts the core owns. Codec, container and colour identity live
//! here because an adapter that owns them makes the platform the contract: the
//! Apple backend's two-value Codec enum was the whole vocabulary the engine had.

const std = @import("std");

/// Every video codec the engine can name. A backend declares which of these it
/// encodes and decodes; naming one here does not claim a backend exists for it.
pub const VideoCodec = enum(u32) {
    h264 = 0,
    hevc = 1,
    vp8 = 2,
    vp9 = 3,
    av1 = 4,

    /// Whether a container that carries this codec must be webm rather than mp4.
    pub fn webmOnly(c: VideoCodec) bool {
        return switch (c) {
            .vp8, .vp9 => true,
            .h264, .hevc, .av1 => false,
        };
    }
};

pub const AudioCodec = enum(u32) {
    aac = 0,
    opus = 1,
    pcm = 2,
};

pub const Container = enum(u32) {
    mp4 = 0,
    mov = 1,
    webm = 2,

    /// Whether this container can carry the pair. Enforced at configuration so a
    /// recording fails before it writes a file no player will open.
    pub fn carries(k: Container, video: VideoCodec, audio: AudioCodec) bool {
        return switch (k) {
            .webm => (video == .vp8 or video == .vp9 or video == .av1) and audio == .opus,
            .mp4, .mov => !video.webmOnly() and audio != .opus,
        };
    }
};

/// How a plane's bytes are laid out. The frame path's own pixel formats, named
/// here so a descriptor crossing the media boundary carries one vocabulary.
pub const PixelFormat = enum(u32) {
    nv12 = 0,
    nv21 = 1,
    i420 = 2,
    bgra8 = 3,
    rgba8 = 4,

    pub fn planes(f: PixelFormat) u8 {
        return switch (f) {
            .nv12, .nv21 => 2,
            .i420 => 3,
            .bgra8, .rgba8 => 1,
        };
    }
};

/// The colour metadata a frame carries, never guessed. Every field is the value
/// a container writes and a decoder reads, so a round trip preserves them.
pub const ColorInfo = struct {
    primaries: Primaries = .bt709,
    transfer: Transfer = .bt709,
    matrix: Matrix = .bt709,
    range: Range = .video,
    /// Where the chroma sample sits relative to luma, which a 4:2:0 conversion
    /// needs and a guess gets wrong by half a pixel.
    siting: ChromaSiting = .left,
    bit_depth: u8 = 8,

    pub const Primaries = enum(u32) { bt709 = 0, bt601 = 1, bt2020 = 2, display_p3 = 3 };
    pub const Transfer = enum(u32) { bt709 = 0, srgb = 1, pq = 2, hlg = 3, linear = 4 };
    pub const Matrix = enum(u32) { bt709 = 0, bt601 = 1, bt2020_ncl = 2, identity = 3 };
    pub const Range = enum(u32) { video = 0, full = 1 };
    pub const ChromaSiting = enum(u32) { left = 0, center = 1, top_left = 2 };

    /// Whether the set describes high dynamic range, which decides whether a
    /// ten-bit path is required rather than merely allowed.
    pub fn isHdr(c: ColorInfo) bool {
        return c.transfer == .pq or c.transfer == .hlg;
    }

    /// A set that cannot be written: a ten-bit transfer at eight bits, or a
    /// matrix that contradicts the primaries it is paired with.
    pub fn valid(c: ColorInfo) bool {
        if (c.bit_depth != 8 and c.bit_depth != 10 and c.bit_depth != 12) return false;
        if (c.isHdr() and c.bit_depth < 10) return false;
        if (c.primaries == .bt2020 and c.matrix == .bt601) return false;
        return true;
    }
};

/// A turn and a flip, as the container records them. Kept apart from the frame
/// path's packed flags so the media layer never reads a bit field it did not set.
pub const Orientation = struct {
    quarter_turns: u2 = 0,
    mirrored: bool = false,

    pub fn isIdentity(o: Orientation) bool {
        return o.quarter_turns == 0 and !o.mirrored;
    }
};

/// A raw frame's shape, with no pointer in it: the descriptor crosses the
/// boundary and the planes are passed beside it.
pub const RawVideoDesc = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    color: ColorInfo = .{},
    orientation: Orientation = .{},

    pub fn valid(d: RawVideoDesc) bool {
        return d.width > 0 and d.height > 0 and d.color.valid();
    }
};

/// What an encoder was asked for. Zero bitrate lets the backend choose a rate
/// from the dimensions, which is the one field the engine does not insist on.
pub const EncodedVideoDesc = struct {
    width: u32,
    height: u32,
    codec: VideoCodec,
    bitrate_bps: u32 = 0,
    /// Frames per second as a rational, so 29.97 is exact rather than rounded.
    fps_num: u32 = 30,
    fps_den: u32 = 1,
    color: ColorInfo = .{},
    orientation: Orientation = .{},
    /// Frames between key frames. Zero lets the backend decide.
    keyframe_interval: u32 = 0,

    pub fn valid(d: EncodedVideoDesc) bool {
        if (d.width == 0 or d.height == 0) return false;
        if (d.fps_num == 0 or d.fps_den == 0) return false;
        if (!d.color.valid()) return false;
        // Ten-bit hdr has no h264 profile the engine ships, so refuse the pair
        // here rather than letting a backend write a file that will not play.
        if (d.color.isHdr() and d.codec == .h264) return false;
        return true;
    }
};

pub const EncodedAudioDesc = struct {
    codec: AudioCodec,
    sample_rate: u32 = 48_000,
    channels: u8 = 1,
    bitrate_bps: u32 = 0,

    pub fn valid(d: EncodedAudioDesc) bool {
        if (d.sample_rate == 0 or d.channels == 0 or d.channels > 8) return false;
        // Opus resamples everything to 48k internally; asking it for another rate
        // is a configuration that silently does something else.
        if (d.codec == .opus and d.sample_rate != 48_000) return false;
        return true;
    }
};

const t = std.testing;

test "a container refuses a pair it cannot carry" {
    try t.expect(Container.mp4.carries(.h264, .aac));
    try t.expect(Container.webm.carries(.vp9, .opus));
    // vp9 in mp4 and opus in mov are both the kind of file that writes fine and
    // opens nowhere, so the configuration is refused instead.
    try t.expect(!Container.mp4.carries(.vp9, .aac));
    try t.expect(!Container.mov.carries(.h264, .opus));
    try t.expect(!Container.webm.carries(.h264, .opus));
}

test "colour metadata that cannot be written is invalid" {
    try t.expect((ColorInfo{}).valid());
    try t.expect((ColorInfo{ .transfer = .pq, .bit_depth = 10 }).valid());
    // A ten-bit transfer at eight bits is the common mistake; so is bt2020
    // primaries with a bt601 matrix.
    try t.expect(!(ColorInfo{ .transfer = .pq, .bit_depth = 8 }).valid());
    try t.expect(!(ColorInfo{ .transfer = .hlg, .bit_depth = 8 }).valid());
    try t.expect(!(ColorInfo{ .primaries = .bt2020, .matrix = .bt601 }).valid());
    try t.expect(!(ColorInfo{ .bit_depth = 9 }).valid());
}

test "hdr is the transfer, not the primaries" {
    try t.expect((ColorInfo{ .transfer = .pq, .bit_depth = 10 }).isHdr());
    try t.expect((ColorInfo{ .transfer = .hlg, .bit_depth = 10 }).isHdr());
    // Wide primaries at an sdr transfer are wide gamut, not high range.
    try t.expect(!(ColorInfo{ .primaries = .bt2020, .bit_depth = 10 }).isHdr());
    try t.expect(!(ColorInfo{ .primaries = .display_p3 }).isHdr());
}

test "an encoder configuration is checked before a backend sees it" {
    try t.expect((EncodedVideoDesc{ .width = 1920, .height = 1080, .codec = .h264 }).valid());
    try t.expect(!(EncodedVideoDesc{ .width = 0, .height = 1080, .codec = .h264 }).valid());
    try t.expect(!(EncodedVideoDesc{ .width = 1920, .height = 1080, .codec = .h264, .fps_den = 0 }).valid());
    // Hdr over h264 is a pair the engine ships no profile for.
    try t.expect(!(EncodedVideoDesc{ .width = 1920, .height = 1080, .codec = .h264, .color = .{ .transfer = .pq, .bit_depth = 10 } }).valid());
    try t.expect((EncodedVideoDesc{ .width = 1920, .height = 1080, .codec = .hevc, .color = .{ .transfer = .pq, .bit_depth = 10 } }).valid());
}

test "opus at a rate it does not run is refused" {
    try t.expect((EncodedAudioDesc{ .codec = .opus }).valid());
    try t.expect((EncodedAudioDesc{ .codec = .aac, .sample_rate = 44_100 }).valid());
    try t.expect(!(EncodedAudioDesc{ .codec = .opus, .sample_rate = 44_100 }).valid());
    try t.expect(!(EncodedAudioDesc{ .codec = .pcm, .channels = 0 }).valid());
}

test "plane counts and webm-only codecs" {
    try t.expectEqual(@as(u8, 2), PixelFormat.nv12.planes());
    try t.expectEqual(@as(u8, 3), PixelFormat.i420.planes());
    try t.expectEqual(@as(u8, 1), PixelFormat.rgba8.planes());
    try t.expect(VideoCodec.vp9.webmOnly());
    try t.expect(!VideoCodec.av1.webmOnly());
}

test "an identity orientation is the default" {
    try t.expect((Orientation{}).isIdentity());
    try t.expect(!(Orientation{ .quarter_turns = 1 }).isIdentity());
    try t.expect(!(Orientation{ .mirrored = true }).isIdentity());
}
