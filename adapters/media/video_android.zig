//! Video decode on Android: AMediaExtractor demuxes the file and
//! AMediaCodec decodes the video track to YUV, converted to BGRA
//! through the one image adapter. No output surface, so frames land in
//! CPU buffers a live texture uploads. No vendor type crosses this file.

const std = @import("std");
const image = @import("image");

const c = @cImport({
    @cInclude("media/NdkMediaExtractor.h");
    @cInclude("media/NdkMediaCodec.h");
    @cInclude("media/NdkMediaFormat.h");
});

/// Whether a real decoder exists on this target.
pub const supported = true;

pub const Read = enum { frame, end, failed };

// The MediaCodec color-format constants a YUV420 output reports.
const color_yuv420_planar: i32 = 19; // I420
const color_yuv420_semiplanar: i32 = 21; // NV12
const color_yuv420_flexible: i32 = 0x7F420888;

pub const Decoder = struct {
    handle: *anyopaque,
    width: u32,
    height: u32,

    const State = struct {
        extractor: *c.AMediaExtractor,
        codec: *c.AMediaCodec,
        track: usize,
        width: u32,
        height: u32,
        stride_y: u32,
        stride_uv: u32,
        kind: image.Yuv420,
        input_done: bool = false,
        failed: bool = false,
        fd: c_int,
    };

    // A ?Decoder body cannot arm errdefers, so the fallible build lives
    // here and open() wraps it; every acquired handle has live cover.
    fn openInner(path: []const u8) error{OpenFailed}!Decoder {
        var path_buf: [1024]u8 = undefined;
        if (path.len >= path_buf.len) return error.OpenFailed;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..path.len :0];
        const fd_rc = std.os.linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
        if (fd_rc > std.math.maxInt(i32)) return error.OpenFailed;
        const fd: c_int = @intCast(fd_rc);
        if (fd < 0) return error.OpenFailed;
        errdefer _ = std.os.linux.close(fd);

        const size = blk: {
            const end = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
            _ = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.SET);
            break :blk end;
        };
        const ex = c.AMediaExtractor_new() orelse return error.OpenFailed;
        errdefer _ = c.AMediaExtractor_delete(ex);
        if (c.AMediaExtractor_setDataSourceFd(ex, fd, 0, @intCast(size)) != c.AMEDIA_OK) return error.OpenFailed;

        const tracks = c.AMediaExtractor_getTrackCount(ex);
        var track: usize = 0;
        var found = false;
        var width: u32 = 0;
        var height: u32 = 0;
        var mime_z: [*:0]const u8 = undefined;
        while (track < tracks) : (track += 1) {
            const fmt = c.AMediaExtractor_getTrackFormat(ex, track) orelse continue;
            defer _ = c.AMediaFormat_delete(fmt);
            var mime: [*c]const u8 = undefined;
            if (!c.AMediaFormat_getString(fmt, c.AMEDIAFORMAT_KEY_MIME, &mime)) continue;
            if (std.mem.startsWith(u8, std.mem.span(mime), "video/")) {
                var w: i32 = 0;
                var h: i32 = 0;
                _ = c.AMediaFormat_getInt32(fmt, c.AMEDIAFORMAT_KEY_WIDTH, &w);
                _ = c.AMediaFormat_getInt32(fmt, c.AMEDIAFORMAT_KEY_HEIGHT, &h);
                if (w <= 0 or h <= 0) return error.OpenFailed;
                width = @intCast(w);
                height = @intCast(h);
                mime_z = mime;
                found = true;
                break;
            }
        }
        if (!found) return error.OpenFailed;
        if (c.AMediaExtractor_selectTrack(ex, track) != c.AMEDIA_OK) return error.OpenFailed;

        const codec = c.AMediaCodec_createDecoderByType(mime_z) orelse return error.OpenFailed;
        errdefer _ = c.AMediaCodec_delete(codec);
        const cfg = c.AMediaExtractor_getTrackFormat(ex, track) orelse return error.OpenFailed;
        defer _ = c.AMediaFormat_delete(cfg);
        // Ask for a flexible YUV420 so the output is one of the layouts the
        // image adapter converts; null surface keeps frames on the CPU.
        c.AMediaFormat_setInt32(cfg, c.AMEDIAFORMAT_KEY_COLOR_FORMAT, color_yuv420_flexible);
        if (c.AMediaCodec_configure(codec, cfg, null, null, 0) != c.AMEDIA_OK) return error.OpenFailed;
        if (c.AMediaCodec_start(codec) != c.AMEDIA_OK) return error.OpenFailed;

        const gpa = std.heap.c_allocator;
        const state = gpa.create(State) catch return error.OpenFailed;
        state.* = .{
            .extractor = ex,
            .codec = codec,
            .track = track,
            .width = width,
            .height = height,
            .stride_y = width,
            .stride_uv = width,
            .kind = .nv12,
            .fd = fd,
        };
        return .{ .handle = state, .width = width, .height = height };
    }

    pub fn open(path: []const u8) ?Decoder {
        return openInner(path) catch null;
    }

    /// Feeds encoded samples and drains one decoded frame into out_bgra
    /// (width*height*4). Ends when the stream drains after end of input.
    pub fn read(self: *Decoder, out_bgra: []u8) Read {
        const state: *State = @ptrCast(@alignCast(self.handle));
        if (state.failed) return .failed;
        if (out_bgra.len < @as(usize, state.width) * state.height * 4) return .failed;

        var guard: u32 = 0;
        while (true) {
            guard += 1;
            if (guard > 4096) {
                state.failed = true;
                return .failed;
            }
            if (!state.input_done) feedInput(state);

            var info: c.AMediaCodecBufferInfo = undefined;
            const index = c.AMediaCodec_dequeueOutputBuffer(state.codec, &info, 10_000);
            if (index == c.AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
                const fmt = c.AMediaCodec_getOutputFormat(state.codec) orelse {
                    state.failed = true;
                    return .failed;
                };
                defer _ = c.AMediaFormat_delete(fmt);
                readOutputGeometry(state, fmt);
                continue;
            }
            if (index == c.AMEDIACODEC_INFO_TRY_AGAIN_LATER or index == c.AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
                if (state.input_done and index == c.AMEDIACODEC_INFO_TRY_AGAIN_LATER) return .end;
                continue;
            }
            if (index < 0) {
                state.failed = true;
                return .failed;
            }
            defer _ = c.AMediaCodec_releaseOutputBuffer(state.codec, @intCast(index), false);
            if (info.flags & c.AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM != 0) return .end;
            if (info.size == 0) continue;
            var cap: usize = 0;
            const buffer = c.AMediaCodec_getOutputBuffer(state.codec, @intCast(index), &cap) orelse {
                state.failed = true;
                return .failed;
            };
            const y = buffer + @as(usize, @intCast(info.offset));
            const uv = y + (@as(usize, state.stride_y) * state.height);
            image.yuv420ToBgra(state.kind, y, state.stride_y, uv, state.stride_uv, out_bgra.ptr, state.width * 4, state.width, state.height) catch {
                state.failed = true;
                return .failed;
            };
            return .frame;
        }
    }

    fn feedInput(state: *State) void {
        const index = c.AMediaCodec_dequeueInputBuffer(state.codec, 10_000);
        if (index < 0) return;
        var cap: usize = 0;
        const buffer = c.AMediaCodec_getInputBuffer(state.codec, @intCast(index), &cap) orelse return;
        const sample = c.AMediaExtractor_readSampleData(state.extractor, buffer, cap);
        if (sample < 0) {
            _ = c.AMediaCodec_queueInputBuffer(state.codec, @intCast(index), 0, 0, 0, c.AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
            state.input_done = true;
            return;
        }
        const pts = c.AMediaExtractor_getSampleTime(state.extractor);
        _ = c.AMediaCodec_queueInputBuffer(state.codec, @intCast(index), 0, @intCast(sample), @intCast(@max(pts, 0)), 0);
        _ = c.AMediaExtractor_advance(state.extractor);
    }

    fn readOutputGeometry(state: *State, fmt: *c.AMediaFormat) void {
        var color: i32 = color_yuv420_semiplanar;
        _ = c.AMediaFormat_getInt32(fmt, c.AMEDIAFORMAT_KEY_COLOR_FORMAT, &color);
        state.kind = switch (color) {
            color_yuv420_planar => .i420,
            else => .nv12,
        };
        var stride: i32 = 0;
        if (c.AMediaFormat_getInt32(fmt, c.AMEDIAFORMAT_KEY_STRIDE, &stride) and stride > 0) {
            state.stride_y = @intCast(stride);
            state.stride_uv = if (state.kind == .i420) @intCast(@divTrunc(stride, 2)) else @intCast(stride);
        }
    }

    pub fn reset(self: *Decoder) bool {
        const state: *State = @ptrCast(@alignCast(self.handle));
        if (c.AMediaExtractor_seekTo(state.extractor, 0, c.AMEDIAEXTRACTOR_SEEK_PREVIOUS_SYNC) != c.AMEDIA_OK) return false;
        _ = c.AMediaCodec_flush(state.codec);
        state.input_done = false;
        state.failed = false;
        return true;
    }

    pub fn close(self: *Decoder) void {
        const state: *State = @ptrCast(@alignCast(self.handle));
        _ = c.AMediaCodec_stop(state.codec);
        _ = c.AMediaCodec_delete(state.codec);
        _ = c.AMediaExtractor_delete(state.extractor);
        _ = std.os.linux.close(state.fd);
        std.heap.c_allocator.destroy(state);
    }
};

pub const Probe = struct { frames: u32, width: u32, height: u32, duration_us: i64 };

pub fn probe(path: []const u8) error{OpenFailed}!Probe {
    _ = path;
    return error.OpenFailed;
}

pub fn exportFrame(path: []const u8, frame_index: u32, out_bgra: []u8) error{OpenFailed}!struct { width: u32, height: u32 } {
    _ = path;
    _ = frame_index;
    _ = out_bgra;
    return error.OpenFailed;
}
