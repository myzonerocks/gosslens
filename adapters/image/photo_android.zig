//! HEIC photo encoding on Android: one HEVC intra frame through
//! AMediaCodec, muxed to HEIF by AMediaMuxer (whose HEIF output is an
//! API-34+ device capability, so an older device returns null here and
//! HEIC reports unsupported while the engine's own JPEG still serves).

const std = @import("std");
const image = @import("image");

const c = @cImport({
    @cInclude("media/NdkMediaCodec.h");
    @cInclude("media/NdkMediaMuxer.h");
    @cInclude("media/NdkMediaFormat.h");
});

pub const supported = true;

pub const Format = enum(u32) { jpeg = 1, heic = 2 };
pub const Error = error{ EncodeFailed, BufferTooSmall, DecodeFailed };

const color_format_yuv420_semiplanar: i32 = 21; // NV12 input to the encoder
const output_format_heif: c.OutputFormat = 3; // AMEDIAMUXER_OUTPUT_FORMAT_HEIF, API 34+

/// Encodes RGBA8 as a HEIC image into `out`, setting out_len. Only the
/// heic format reaches here; jpeg is the engine encoder upstream.
pub fn encode(rgba: []const u8, width: u32, height: u32, format: Format, quality: u32, out: []u8, out_len: *usize) Error!void {
    if (format != .heic) return error.EncodeFailed;
    if (width == 0 or height == 0 or width > 8192 or height > 8192) return error.EncodeFailed;

    const gpa = std.heap.c_allocator;
    // RGBA to NV12 for the encoder input, through the one image adapter.
    const luma = @as(usize, width) * height;
    const y_plane = gpa.alloc(u8, luma) catch return error.EncodeFailed;
    defer gpa.free(y_plane);
    const half_w = (width + 1) / 2;
    const half_h = (height + 1) / 2;
    const uv_plane = gpa.alloc(u8, @as(usize, half_w) * half_h * 2) catch return error.EncodeFailed;
    defer gpa.free(uv_plane);
    image.argbToNv12(rgba, width, height, .bt601, .full, y_plane, uv_plane) catch return error.EncodeFailed;

    // An in-memory fd so the muxer writes nothing to disk; the encoded
    // HEIF is read back out of it into the caller's buffer.
    const fd_rc = std.os.linux.memfd_create("goss-heic", 0);
    if (fd_rc > std.math.maxInt(i32)) return error.EncodeFailed;
    const fd: c_int = @intCast(fd_rc);
    if (fd < 0) return error.EncodeFailed;
    defer _ = std.os.linux.close(fd);

    const muxer = c.AMediaMuxer_new(fd, output_format_heif) orelse return error.EncodeFailed;
    defer _ = c.AMediaMuxer_delete(muxer);

    const codec = c.AMediaCodec_createEncoderByType("video/hevc") orelse return error.EncodeFailed;
    defer {
        _ = c.AMediaCodec_stop(codec);
        _ = c.AMediaCodec_delete(codec);
    }
    const fmt = c.AMediaFormat_new() orelse return error.EncodeFailed;
    defer _ = c.AMediaFormat_delete(fmt);
    c.AMediaFormat_setString(fmt, c.AMEDIAFORMAT_KEY_MIME, "video/hevc");
    c.AMediaFormat_setInt32(fmt, c.AMEDIAFORMAT_KEY_WIDTH, @intCast(width));
    c.AMediaFormat_setInt32(fmt, c.AMEDIAFORMAT_KEY_HEIGHT, @intCast(height));
    c.AMediaFormat_setInt32(fmt, c.AMEDIAFORMAT_KEY_COLOR_FORMAT, color_format_yuv420_semiplanar);
    c.AMediaFormat_setInt32(fmt, c.AMEDIAFORMAT_KEY_FRAME_RATE, 30);
    c.AMediaFormat_setInt32(fmt, c.AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 0);
    // A quality-to-bitrate map: a still wants a generous rate so the one
    // intra frame keeps detail; scale with the pixel count.
    const q: u32 = if (quality == 0) 90 else @min(quality, 100);
    const bitrate: i32 = @intCast(@min(@as(u64, luma) * 8 * q / 100 + 1_000_000, @as(u64, std.math.maxInt(i32))));
    c.AMediaFormat_setInt32(fmt, c.AMEDIAFORMAT_KEY_BIT_RATE, bitrate);
    if (c.AMediaCodec_configure(codec, fmt, null, null, c.AMEDIACODEC_CONFIGURE_FLAG_ENCODE) != c.AMEDIA_OK) return error.EncodeFailed;
    if (c.AMediaCodec_start(codec) != c.AMEDIA_OK) return error.EncodeFailed;

    // Feed the one NV12 frame and signal end of stream.
    {
        const index = c.AMediaCodec_dequeueInputBuffer(codec, 1_000_000);
        if (index < 0) return error.EncodeFailed;
        var cap: usize = 0;
        const buffer = c.AMediaCodec_getInputBuffer(codec, @intCast(index), &cap) orelse return error.EncodeFailed;
        const need = luma + uv_plane.len;
        if (cap < need) return error.EncodeFailed;
        @memcpy(buffer[0..luma], y_plane);
        @memcpy(buffer[luma .. luma + uv_plane.len], uv_plane);
        if (c.AMediaCodec_queueInputBuffer(codec, @intCast(index), 0, need, 0, c.AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != c.AMEDIA_OK) return error.EncodeFailed;
    }

    var track: isize = -1;
    var muxing = false;
    var info: c.AMediaCodecBufferInfo = undefined;
    var waits: u32 = 0;
    while (true) {
        const index = c.AMediaCodec_dequeueOutputBuffer(codec, &info, 100_000);
        if (index == c.AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            const out_fmt = c.AMediaCodec_getOutputFormat(codec) orelse return error.EncodeFailed;
            defer _ = c.AMediaFormat_delete(out_fmt);
            track = c.AMediaMuxer_addTrack(muxer, out_fmt);
            if (track < 0 or c.AMediaMuxer_start(muxer) != c.AMEDIA_OK) return error.EncodeFailed;
            muxing = true;
            continue;
        }
        if (index < 0) {
            if (index == c.AMEDIACODEC_INFO_TRY_AGAIN_LATER or index == c.AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
                waits += 1;
                if (waits > 200) return error.EncodeFailed;
                continue;
            }
            return error.EncodeFailed;
        }
        defer _ = c.AMediaCodec_releaseOutputBuffer(codec, @intCast(index), false);
        const codec_config = info.flags & c.AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG != 0;
        if (info.size > 0 and !codec_config and muxing) {
            var bsz: usize = 0;
            const buffer = c.AMediaCodec_getOutputBuffer(codec, @intCast(index), &bsz) orelse return error.EncodeFailed;
            if (c.AMediaMuxer_writeSampleData(muxer, @intCast(track), buffer, &info) != c.AMEDIA_OK) return error.EncodeFailed;
        }
        if (info.flags & c.AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM != 0) break;
    }
    if (!muxing) return error.EncodeFailed;
    if (c.AMediaMuxer_stop(muxer) != c.AMEDIA_OK) return error.EncodeFailed;

    // Read the muxed HEIF back out of the in-memory fd into the caller.
    const size = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
    _ = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.SET);
    out_len.* = size;
    if (out.len < size) return error.BufferTooSmall;
    var read_total: usize = 0;
    while (read_total < size) {
        const n = std.os.linux.read(fd, out[read_total..size].ptr, size - read_total);
        if (n == 0 or n > size) break;
        read_total += n;
    }
    if (read_total != size) return error.EncodeFailed;
}

pub fn encodedSize(rgba: []const u8, width: u32, height: u32, format: Format, quality: u32) Error!usize {
    // A HEIF size is only known after encoding; the caller retries with a
    // larger buffer on BufferTooSmall, so report a generous upper bound.
    _ = rgba;
    _ = format;
    _ = quality;
    return @as(usize, width) * height + 65_536;
}

pub fn decode(data: []const u8, out_rgba: []u8, out_width: *u32, out_height: *u32) Error!void {
    _ = data;
    _ = out_rgba;
    _ = out_width;
    _ = out_height;
    return error.DecodeFailed;
}

pub const Metadata = struct { orientation: u32, software: [32]u8, software_len: usize };

pub fn probeMetadata(data: []const u8) Error!Metadata {
    _ = data;
    return error.DecodeFailed;
}
