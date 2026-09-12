//! Recording for targets whose backend has not landed: same surface,
//! every operation reports the capability honestly absent.

const media = @import("media");

/// How the vended native handle binds: a sampleable texture, or a
/// platform window the renderer presents into.
pub const NativeHandleKind = enum { texture, window };
pub const native_handle_kind: NativeHandleKind = .texture;

/// A backend that declares nothing, which is the honest declaration for a target
/// whose encoder has not landed. Selection finds no backend and the caller hears
/// that, rather than reading a false boolean and trying.
pub const backend: media.Backend = .{
    .name = "none",
    .video = &.{},
    .audio = &.{},
    .containers = &.{},
};

pub const supported = backend.video.len > 0;
pub const audio_supported = backend.audio.len > 0;

pub const Codec = media.VideoCodec;

pub const Config = struct {
    width: u32,
    height: u32,
    bitrate_bps: u32 = 0,
    codec: Codec = .h264,
};

pub const Error = error{
    OpenFailed,
    FrameFailed,
    FinishFailed,
};

pub const Frame = struct {
    token: *anyopaque,
    native_texture: *anyopaque,
};

pub const Recording = struct {
    handle: *anyopaque,
    config: Config,
    committed: u32 = 0,

    pub fn start(path: []const u8, config: Config) Error!Recording {
        _ = path;
        _ = config;
        return error.OpenFailed;
    }

    pub fn beginFrame(recording: *Recording) Error!Frame {
        _ = recording;
        return error.FrameFailed;
    }

    pub fn commitFrame(recording: *Recording, frame: Frame, timestamp_us: i64) Error!void {
        _ = recording;
        _ = frame;
        _ = timestamp_us;
        return error.FrameFailed;
    }

    pub fn submitAudio(recording: *Recording, samples: []const f32, frame_count: u32, sample_rate: u32, channels: u32, timestamp_us: i64) Error!void {
        _ = recording;
        _ = samples;
        _ = frame_count;
        _ = sample_rate;
        _ = channels;
        _ = timestamp_us;
        return error.FrameFailed;
    }

    pub fn abortFrame(recording: *Recording, frame: Frame) void {
        _ = recording;
        _ = frame;
    }

    pub fn finish(recording: *Recording) Error!void {
        _ = recording;
        return error.FinishFailed;
    }
};

pub const Probe = struct {
    frames: u32,
    width: u32,
    height: u32,
    duration_us: i64,
};

pub fn probe(path: []const u8) Error!Probe {
    _ = path;
    return error.OpenFailed;
}

pub fn exportFrame(path: []const u8, frame_index: u32, out_bgra: []u8) Error!struct { width: u32, height: u32 } {
    _ = path;
    _ = frame_index;
    _ = out_bgra;
    return error.OpenFailed;
}

pub fn probeAudio(path: []const u8) Error!i64 {
    _ = path;
    return error.OpenFailed;
}
