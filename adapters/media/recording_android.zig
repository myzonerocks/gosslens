//! Video recording on Android: AMediaCodec's input surface takes the
//! renderer's frames zero-copy, a second AAC codec takes the mixed PCM,
//! and AMediaMuxer writes both tracks into the MP4. All C NDK APIs,
//! bound directly; no vendor type escapes this file.

const std = @import("std");
const pcm = @import("pcm.zig");

const c = @cImport({
    @cInclude("media/NdkMediaCodec.h");
    @cInclude("media/NdkMediaMuxer.h");
    @cInclude("media/NdkMediaFormat.h");
    @cInclude("android/native_window.h");
});

/// How the vended native handle binds: a sampleable texture, or a
/// platform window the renderer presents into.
pub const NativeHandleKind = enum { texture, window };
pub const native_handle_kind: NativeHandleKind = .window;
/// Whether this backend muxes a submitted audio track.
pub const audio_supported = true;

/// Whether a real backend exists on this target.
pub const supported = true;

pub const Codec = enum(u32) {
    h264 = 0,
    hevc = 1,
};

pub const Config = struct {
    width: u32,
    height: u32,
    /// Zero lets the backend pick a rate fitting the dimensions.
    bitrate_bps: u32 = 0,
    codec: Codec = .h264,
    /// Whether frames arrive in real time. Kept for parity with the Apple recorder's writer
    /// pacing; this backend appends frames as they are given regardless, so it is unused here.
    realtime: bool = true,
};

pub const Error = error{
    OpenFailed,
    FrameFailed,
    FinishFailed,
};

/// One vended frame between begin and commit; on this backend every
/// frame shares the codec's single input surface.
pub const Frame = struct {
    token: *anyopaque,
    /// The ANativeWindow the renderer presents the composite into.
    native_texture: *anyopaque,
};

// The surface-input color format constant from MediaCodecInfo.
const color_format_surface: i32 = 0x7F000789;
// AACObjectLC from MediaCodecInfo.CodecProfileLevel.
const aac_profile_lc: i32 = 2;

// The muxer refuses new tracks once started, so packets that arrive
// while the second track's format is still pending wait here. Bounds
// cover the format-negotiation window, not sustained recording.
const max_pending_packets: usize = 256;
const max_pending_bytes: usize = 8 * 1024 * 1024;

pub const Recording = struct {
    handle: *anyopaque,
    config: Config,
    committed: u32 = 0,

    const StreamKind = enum { video, audio };

    const Pending = struct {
        kind: StreamKind,
        info: c.AMediaCodecBufferInfo,
        bytes: []u8,
    };

    const State = struct {
        codec: *c.AMediaCodec,
        muxer: *c.AMediaMuxer,
        window: *anyopaque,
        fd: c_int,
        track: i32 = -1,
        audio_codec: ?*c.AMediaCodec = null,
        audio_track: i32 = -1,
        audio_rate: u32 = 0,
        audio_channels: u32 = 0,
        audio_frames: u64 = 0,
        pending: [max_pending_packets]Pending = undefined,
        pending_count: usize = 0,
        pending_bytes: usize = 0,
        muxing: bool = false,
        failed: bool = false,
    };

    pub fn start(path: []const u8, config: Config) Error!Recording {
        var path_buf: [1024]u8 = undefined;
        if (path.len >= path_buf.len) return error.OpenFailed;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..path.len :0];
        const open_rc = std.os.linux.open(path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
        if (open_rc > std.math.maxInt(i32)) return error.OpenFailed;
        const fd: c_int = @intCast(open_rc);
        if (fd < 0) return error.OpenFailed;
        errdefer _ = std.os.linux.close(fd);

        const mime: [:0]const u8 = if (config.codec == .hevc) "video/hevc" else "video/avc";
        const codec = c.AMediaCodec_createEncoderByType(mime.ptr) orelse return error.OpenFailed;
        errdefer _ = c.AMediaCodec_delete(codec);

        const format = c.AMediaFormat_new() orelse return error.OpenFailed;
        defer _ = c.AMediaFormat_delete(format);
        c.AMediaFormat_setString(format, c.AMEDIAFORMAT_KEY_MIME, mime.ptr);
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_WIDTH, @intCast(config.width));
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_HEIGHT, @intCast(config.height));
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_COLOR_FORMAT, color_format_surface);
        const bitrate: i32 = if (config.bitrate_bps == 0) 8_000_000 else @intCast(config.bitrate_bps);
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_BIT_RATE, bitrate);
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_FRAME_RATE, 30);
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 1);
        if (c.AMediaCodec_configure(codec, format, null, null, c.AMEDIACODEC_CONFIGURE_FLAG_ENCODE) != c.AMEDIA_OK) {
            return error.OpenFailed;
        }
        var window: ?*c.ANativeWindow = null;
        if (c.AMediaCodec_createInputSurface(codec, &window) != c.AMEDIA_OK or window == null) {
            return error.OpenFailed;
        }
        // createInputSurface returns a reference the caller owns; it is
        // released on every later failure here and in finish's teardown.
        errdefer c.ANativeWindow_release(window);
        if (c.AMediaCodec_start(codec) != c.AMEDIA_OK) return error.OpenFailed;

        const muxer = c.AMediaMuxer_new(fd, c.AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4) orelse return error.OpenFailed;
        errdefer _ = c.AMediaMuxer_delete(muxer);

        const gpa = std.heap.c_allocator;
        const state = gpa.create(State) catch return error.OpenFailed;
        state.* = .{ .codec = codec, .muxer = muxer, .window = @ptrCast(window.?), .fd = fd };
        return .{ .handle = state, .config = config };
    }

    /// Every frame rides the codec's one input surface; the token is
    /// the surface itself.
    pub fn beginFrame(recording: *Recording) Error!Frame {
        const state: *State = @ptrCast(@alignCast(recording.handle));
        if (state.failed) return error.FrameFailed;
        return .{ .token = recording.handle, .native_texture = state.window };
    }

    /// Drains whatever the encoders have ready into the muxer; the
    /// surface path stamps its own presentation times.
    pub fn commitFrame(recording: *Recording, frame: Frame, timestamp_us: i64) Error!void {
        _ = frame;
        _ = timestamp_us;
        const state: *State = @ptrCast(@alignCast(recording.handle));
        if (state.failed) return error.FrameFailed;
        try drain(state, false);
        if (state.audio_codec != null) try drainAudio(state, false);
        recording.committed += 1;
    }

    /// Appends interleaved f32 PCM to the AAC track. The encoder stands
    /// up on the first call, so a session that never submits audio muxes
    /// video-only exactly as before; audio arriving after the muxer has
    /// already started without its track is refused, and counted upstream.
    pub fn submitAudio(recording: *Recording, samples: []const f32, frame_count: u32, sample_rate: u32, channels: u32, timestamp_us: i64) Error!void {
        _ = timestamp_us;
        const state: *State = @ptrCast(@alignCast(recording.handle));
        if (state.failed) return error.FrameFailed;
        if (frame_count == 0) return;
        if (channels == 0 or channels > 8) return error.FrameFailed;
        if (sample_rate < 8_000 or sample_rate > 192_000) return error.FrameFailed;
        if (state.audio_codec == null) {
            if (state.muxing) return error.FrameFailed;
            try createAudioCodec(state, sample_rate, channels);
        }
        if (sample_rate != state.audio_rate or channels != state.audio_channels) return error.FrameFailed;
        const codec = state.audio_codec.?;

        var offset: usize = 0;
        // frame_count and channels are caller-supplied; bound the sample
        // span by the buffer actually handed in so a mismatch cannot slice
        // past its end.
        const total = @min(@as(usize, frame_count) * channels, samples.len);
        while (offset < total) {
            const index = c.AMediaCodec_dequeueInputBuffer(codec, 10_000);
            if (index < 0) {
                state.failed = true;
                return error.FrameFailed;
            }
            var capacity: usize = 0;
            const buffer = c.AMediaCodec_getInputBuffer(codec, @intCast(index), &capacity) orelse {
                state.failed = true;
                return error.FrameFailed;
            };
            const slots = @min((capacity / 2), total - offset);
            const out: [*]i16 = @ptrCast(@alignCast(buffer));
            const chunk_frames: u32 = @intCast(slots / channels);
            const written = pcm.f32ToS16(samples[offset..][0 .. chunk_frames * channels], chunk_frames, channels, out[0..slots]);
            const ts: u64 = @intCast(pcm.framesToDurationUs(state.audio_frames, state.audio_rate));
            if (c.AMediaCodec_queueInputBuffer(codec, @intCast(index), 0, written * 2, ts, 0) != c.AMEDIA_OK) {
                state.failed = true;
                return error.FrameFailed;
            }
            state.audio_frames += written / channels;
            offset += written;
            if (written == 0) break;
        }
        try drainAudio(state, false);
    }

    pub fn abortFrame(recording: *Recording, frame: Frame) void {
        _ = recording;
        _ = frame;
    }

    pub fn finish(recording: *Recording) Error!void {
        const state: *State = @ptrCast(@alignCast(recording.handle));
        defer {
            _ = c.AMediaCodec_stop(state.codec);
            _ = c.AMediaCodec_delete(state.codec);
            if (state.audio_codec) |ac| {
                _ = c.AMediaCodec_stop(ac);
                _ = c.AMediaCodec_delete(ac);
            }
            _ = c.AMediaMuxer_delete(state.muxer);
            c.ANativeWindow_release(@ptrCast(state.window));
            _ = std.os.linux.close(state.fd);
            freePending(state);
            std.heap.c_allocator.destroy(state);
        }
        if (state.failed) return error.FinishFailed;
        if (state.audio_codec) |ac| {
            const index = c.AMediaCodec_dequeueInputBuffer(ac, 100_000);
            if (index >= 0) {
                const ts: u64 = @intCast(pcm.framesToDurationUs(state.audio_frames, state.audio_rate));
                _ = c.AMediaCodec_queueInputBuffer(ac, @intCast(index), 0, 0, ts, c.AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
                try drainAudio(state, true);
            }
        }
        if (c.AMediaCodec_signalEndOfInputStream(state.codec) != c.AMEDIA_OK) return error.FinishFailed;
        try drain(state, true);
        if (state.muxing) {
            if (c.AMediaMuxer_stop(state.muxer) != c.AMEDIA_OK) return error.FinishFailed;
        }
    }

    fn createAudioCodec(state: *State, sample_rate: u32, channels: u32) Error!void {
        const codec = c.AMediaCodec_createEncoderByType("audio/mp4a-latm") orelse return error.FrameFailed;
        errdefer _ = c.AMediaCodec_delete(codec);
        const format = c.AMediaFormat_new() orelse return error.FrameFailed;
        defer _ = c.AMediaFormat_delete(format);
        c.AMediaFormat_setString(format, c.AMEDIAFORMAT_KEY_MIME, "audio/mp4a-latm");
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_SAMPLE_RATE, @intCast(sample_rate));
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_CHANNEL_COUNT, @intCast(channels));
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_AAC_PROFILE, aac_profile_lc);
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_BIT_RATE, 128_000);
        if (c.AMediaCodec_configure(codec, format, null, null, c.AMEDIACODEC_CONFIGURE_FLAG_ENCODE) != c.AMEDIA_OK) {
            return error.FrameFailed;
        }
        if (c.AMediaCodec_start(codec) != c.AMEDIA_OK) return error.FrameFailed;
        state.audio_codec = codec;
        state.audio_rate = sample_rate;
        state.audio_channels = channels;
    }

    /// The muxer starts once every expected track has registered: the
    /// video track always, and the audio track whenever the encoder
    /// exists. Packets buffered while waiting flush in arrival order.
    fn maybeStartMuxer(state: *State) Error!void {
        if (state.muxing) return;
        if (state.track < 0) return;
        if (state.audio_codec != null and state.audio_track < 0) return;
        if (c.AMediaMuxer_start(state.muxer) != c.AMEDIA_OK) {
            state.failed = true;
            return error.FrameFailed;
        }
        state.muxing = true;
        var i: usize = 0;
        while (i < state.pending_count) : (i += 1) {
            var entry = &state.pending[i];
            const track: i32 = if (entry.kind == .video) state.track else state.audio_track;
            entry.info.offset = 0;
            if (c.AMediaMuxer_writeSampleData(state.muxer, @intCast(track), entry.bytes.ptr, &entry.info) != c.AMEDIA_OK) {
                state.failed = true;
                freePending(state);
                return error.FrameFailed;
            }
        }
        freePending(state);
    }

    /// Writes a packet, or holds a copy until the muxer can start. The
    /// pending window is format negotiation only, so its bounds fail
    /// closed rather than grow.
    fn writeOrBuffer(state: *State, kind: StreamKind, buffer: [*]const u8, info: *const c.AMediaCodecBufferInfo) Error!void {
        if (state.muxing) {
            const track: i32 = if (kind == .video) state.track else state.audio_track;
            var write_info = info.*;
            if (c.AMediaMuxer_writeSampleData(state.muxer, @intCast(track), buffer, &write_info) != c.AMEDIA_OK) {
                state.failed = true;
                return error.FrameFailed;
            }
            return;
        }
        const size: usize = @intCast(info.size);
        if (state.pending_count >= max_pending_packets or state.pending_bytes + size > max_pending_bytes) {
            state.failed = true;
            return error.FrameFailed;
        }
        const gpa = std.heap.c_allocator;
        const bytes = gpa.alloc(u8, size) catch {
            state.failed = true;
            return error.FrameFailed;
        };
        const start_at: usize = @intCast(info.offset);
        @memcpy(bytes, buffer[start_at .. start_at + size]);
        state.pending[state.pending_count] = .{ .kind = kind, .info = info.*, .bytes = bytes };
        state.pending_count += 1;
        state.pending_bytes += size;
    }

    fn freePending(state: *State) void {
        const gpa = std.heap.c_allocator;
        var i: usize = 0;
        while (i < state.pending_count) : (i += 1) gpa.free(state.pending[i].bytes);
        state.pending_count = 0;
        state.pending_bytes = 0;
    }

    fn drain(state: *State, until_eos: bool) Error!void {
        var info: c.AMediaCodecBufferInfo = undefined;
        // Bound the end-of-stream wait so a codec that goes quiet after the
        // EOS signal cannot hang finish and engine destroy forever; each
        // miss costs a 10ms timeout, so the cap is a few seconds of wait.
        var eos_waits: u32 = 0;
        const max_eos_waits: u32 = 500;
        while (true) {
            const index = c.AMediaCodec_dequeueOutputBuffer(state.codec, &info, if (until_eos) 10_000 else 0);
            if (index == c.AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
                const format = c.AMediaCodec_getOutputFormat(state.codec) orelse {
                    state.failed = true;
                    return error.FrameFailed;
                };
                defer _ = c.AMediaFormat_delete(format);
                state.track = @intCast(c.AMediaMuxer_addTrack(state.muxer, format));
                if (state.track < 0) {
                    state.failed = true;
                    return error.FrameFailed;
                }
                try maybeStartMuxer(state);
                continue;
            }
            if (index < 0) {
                // Only "try again later" and the deprecated buffers-changed
                // status are transient; any other negative is a real codec
                // error that must fail rather than spin.
                if (index != c.AMEDIACODEC_INFO_TRY_AGAIN_LATER and
                    index != c.AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED)
                {
                    state.failed = true;
                    return error.FrameFailed;
                }
                if (!until_eos) return;
                eos_waits += 1;
                if (eos_waits > max_eos_waits) {
                    state.failed = true;
                    return error.FrameFailed;
                }
                continue;
            }
            eos_waits = 0;
            defer _ = c.AMediaCodec_releaseOutputBuffer(state.codec, @intCast(index), false);
            if (info.size > 0) {
                var buffer_size: usize = 0;
                const buffer = c.AMediaCodec_getOutputBuffer(state.codec, @intCast(index), &buffer_size) orelse {
                    state.failed = true;
                    return error.FrameFailed;
                };
                try writeOrBuffer(state, .video, buffer, &info);
            }
            if (info.flags & c.AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM != 0) return;
        }
    }

    /// The audio mirror of drain: registers the AAC track on format
    /// change and routes packets through the same write-or-buffer path,
    /// so both streams share one muxer-start discipline.
    fn drainAudio(state: *State, until_eos: bool) Error!void {
        const codec = state.audio_codec orelse return;
        var info: c.AMediaCodecBufferInfo = undefined;
        var eos_waits: u32 = 0;
        const max_eos_waits: u32 = 500;
        while (true) {
            const index = c.AMediaCodec_dequeueOutputBuffer(codec, &info, if (until_eos) 10_000 else 0);
            if (index == c.AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
                const format = c.AMediaCodec_getOutputFormat(codec) orelse {
                    state.failed = true;
                    return error.FrameFailed;
                };
                defer _ = c.AMediaFormat_delete(format);
                state.audio_track = @intCast(c.AMediaMuxer_addTrack(state.muxer, format));
                if (state.audio_track < 0) {
                    state.failed = true;
                    return error.FrameFailed;
                }
                try maybeStartMuxer(state);
                continue;
            }
            if (index < 0) {
                if (index != c.AMEDIACODEC_INFO_TRY_AGAIN_LATER and
                    index != c.AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED)
                {
                    state.failed = true;
                    return error.FrameFailed;
                }
                if (!until_eos) return;
                eos_waits += 1;
                if (eos_waits > max_eos_waits) {
                    state.failed = true;
                    return error.FrameFailed;
                }
                continue;
            }
            eos_waits = 0;
            defer _ = c.AMediaCodec_releaseOutputBuffer(codec, @intCast(index), false);
            const codec_config = info.flags & c.AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG != 0;
            if (info.size > 0 and !codec_config) {
                var buffer_size: usize = 0;
                const buffer = c.AMediaCodec_getOutputBuffer(codec, @intCast(index), &buffer_size) orelse {
                    state.failed = true;
                    return error.FrameFailed;
                };
                try writeOrBuffer(state, .audio, buffer, &info);
            }
            if (info.flags & c.AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM != 0) return;
        }
    }
};

pub const Probe = struct {
    frames: u32,
    width: u32,
    height: u32,
    duration_us: i64,
};

/// Decode-back probing is a host-harness proof surface; on device the
/// host app owns playback verification.
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
