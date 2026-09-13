//! Video recording behind the media adapter boundary: the platform
//! backend encodes and muxes hardware-side, fed zero-copy from pool
//! textures the renderer composites into. No vendor type crosses this
//! file's surface.

const std = @import("std");
const media = @import("media");

/// How the vended native handle binds: a sampleable texture, or a
/// platform window the renderer presents into.
pub const NativeHandleKind = enum { texture, window };
pub const native_handle_kind: NativeHandleKind = .texture;

/// What this backend actually does, declared rather than assumed. The values come
/// from what recording_apple.mm configures: an AVAssetWriter over MPEG-4 taking
/// h264 or hevc, fed BGRA pixel buffers from its own pool, with hevc carrying the
/// ten-bit hdr path. The engine asks this instead of reading two booleans.
pub const backend: media.Backend = .{
    .name = "avassetwriter",
    .video = &.{
        .{ .codec = .h264, .max_width = 4096, .max_height = 2304 },
        .{ .codec = .hevc, .max_width = 4096, .max_height = 2304, .max_bit_depth = 10, .hdr = true },
    },
    .audio = &.{.aac},
    .containers = &.{ .mp4, .mov },
    .zero_copy = true,
    .rank = 10,
};

/// Derived from the declaration above, so these stay true by construction rather
/// than being a second place to keep in step. They remain because 131 call sites
/// read them; the declaration is the contract now.
pub const supported = backend.video.len > 0;
pub const audio_supported = backend.audio.len > 0;

/// One vocabulary: the codec a host names is the core's, not this file's.
pub const Codec = media.VideoCodec;

pub const Config = struct {
    width: u32,
    height: u32,
    /// Zero lets the backend pick a rate fitting the dimensions.
    bitrate_bps: u32 = 0,
    codec: Codec = .h264,
};

pub const Error = error{
    OpenFailed,
    FrameFailed,
    FinishFailed,
};

extern fn goss_recording_open(path: [*]const u8, path_len: usize, width: u32, height: u32, bitrate_bps: u32, codec: u32) ?*anyopaque;
extern fn goss_recording_begin_frame(handle: *anyopaque, out_frame: *?*anyopaque, out_metal_texture: *?*anyopaque) i32;
extern fn goss_recording_commit_frame(handle: *anyopaque, frame_token: *anyopaque, timestamp_us: i64) i32;
extern fn goss_recording_abort_frame(handle: *anyopaque, frame_token: *anyopaque) void;
extern fn goss_recording_finish(handle: *anyopaque) i32;
extern fn goss_recording_submit_audio(handle: *anyopaque, samples: [*]const f32, frame_count: u32, sample_rate: u32, channels: u32, timestamp_us: i64) i32;
extern fn goss_recording_probe(path: [*]const u8, path_len: usize, out_frames: ?*u32, out_width: ?*u32, out_height: ?*u32, out_duration_us: ?*i64) i32;
extern fn goss_recording_export_frame(path: [*]const u8, path_len: usize, frame_index: u32, out_bgra: [*]u8, capacity: usize, out_width: ?*u32, out_height: ?*u32) i32;

/// One vended frame between begin and commit/abort; several may be in
/// flight while the GPU catches up to the frames that vended them.
pub const Frame = struct {
    token: *anyopaque,
    /// The native (Metal) texture the renderer composites into.
    native_texture: *anyopaque,
};

pub const Recording = struct {
    handle: *anyopaque,
    config: Config,
    /// Frames appended so far; pool-slot warmups are not counted.
    committed: u32 = 0,

    pub fn start(path: []const u8, config: Config) Error!Recording {
        const handle = goss_recording_open(path.ptr, path.len, config.width, config.height, config.bitrate_bps, @intFromEnum(config.codec)) orelse return error.OpenFailed;
        return .{ .handle = handle, .config = config };
    }

    pub fn beginFrame(recording: *Recording) Error!Frame {
        var token: ?*anyopaque = null;
        var texture: ?*anyopaque = null;
        if (goss_recording_begin_frame(recording.handle, &token, &texture) != 0) return error.FrameFailed;
        return .{
            .token = token orelse return error.FrameFailed,
            .native_texture = texture orelse return error.FrameFailed,
        };
    }

    /// Appends the frame; the token is consumed either way.
    pub fn commitFrame(recording: *Recording, frame: Frame, timestamp_us: i64) Error!void {
        if (goss_recording_commit_frame(recording.handle, frame.token, timestamp_us) != 0) return error.FrameFailed;
        recording.committed += 1;
    }

    /// Appends interleaved f32 PCM to the audio track at the same
    /// microsecond clock the video frames ride.
    pub fn submitAudio(recording: *Recording, samples: []const f32, frame_count: u32, sample_rate: u32, channels: u32, timestamp_us: i64) Error!void {
        if (samples.len < @as(usize, frame_count) * channels) return error.FrameFailed;
        if (goss_recording_submit_audio(recording.handle, samples.ptr, frame_count, sample_rate, channels, timestamp_us) != 0) return error.FrameFailed;
    }

    /// Releases a vended frame without appending it.
    pub fn abortFrame(recording: *Recording, frame: Frame) void {
        goss_recording_abort_frame(recording.handle, frame.token);
    }

    /// Finalizes the container; the recording is unusable afterwards.
    pub fn finish(recording: *Recording) Error!void {
        if (goss_recording_finish(recording.handle) != 0) return error.FinishFailed;
    }
};

pub const Probe = struct {
    frames: u32,
    width: u32,
    height: u32,
    duration_us: i64,
};

/// Decodes a finished file and reports its real shape - the harness's
/// round-trip proof, not a production surface.
pub fn probe(path: []const u8) Error!Probe {
    var result: Probe = .{ .frames = 0, .width = 0, .height = 0, .duration_us = 0 };
    if (goss_recording_probe(path.ptr, path.len, &result.frames, &result.width, &result.height, &result.duration_us) != 0) {
        return error.OpenFailed;
    }
    return result;
}

/// Copies one decoded frame's BGRA pixels out of a finished file - the
/// harness's by-eye artifact, not a production surface.
pub fn exportFrame(path: []const u8, frame_index: u32, out_bgra: []u8) Error!struct { width: u32, height: u32 } {
    var width: u32 = 0;
    var height: u32 = 0;
    if (goss_recording_export_frame(path.ptr, path.len, frame_index, out_bgra.ptr, out_bgra.len, &width, &height) != 0) {
        return error.OpenFailed;
    }
    return .{ .width = width, .height = height };
}

extern fn goss_recording_probe_audio(path: [*]const u8, path_len: usize, out_duration_us: ?*i64) i32;

/// Reports the finished file's audio track duration - the harness's
/// A/V alignment proof surface.
pub fn probeAudio(path: []const u8) Error!i64 {
    var duration_us: i64 = 0;
    if (goss_recording_probe_audio(path.ptr, path.len, &duration_us) != 0) return error.OpenFailed;
    return duration_us;
}
