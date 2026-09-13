//! The media harness: the checks that belong to the contracts rather than to a
//! rendered frame, so they need no window and no GPU. What needs a real
//! composite stays in conformance beside the other rendered proofs.

const std = @import("std");
const media = @import("media");

const Result = struct {
    passed: u32 = 0,
    failed: u32 = 0,

    fn ok(self: *Result, comptime what: []const u8, args: anytype) void {
        self.passed += 1;
        std.debug.print("media: PROOF " ++ what ++ "\n", args);
    }

    fn no(self: *Result, comptime what: []const u8, args: anytype) void {
        self.failed += 1;
        std.debug.print("media: FAIL " ++ what ++ "\n", args);
    }
};

/// What a timebase guarantees: a tick survives a round trip exactly, a microsecond
/// lands within half a tick. It cannot be exact both ways, because one second is
/// 29.97 ticks at 1001/30000. Asserting exactness both ways looks like a bug in
/// the conversion and is a bug in the expectation.
fn proveTimebaseRoundTrips(r: *Result) void {
    const rates = [_]media.Timebase{
        .{ .num = 1, .den = 90_000 },
        .{ .num = 1001, .den = 30_000 },
        .{ .num = 1001, .den = 24_000 },
        .{ .num = 1, .den = 1_000_000 },
    };
    for (rates) |tb| {
        // A tick is exact out and back, at the start and a long way in.
        for ([_]i64{ 1, 30, 90_000, 1_000_000 }) |ticks| {
            const back = tb.fromMicros(tb.toMicros(ticks));
            if (back != ticks) {
                r.no("tick {d} in {d}/{d} came back as {d}", .{ ticks, tb.num, tb.den, back });
                return;
            }
        }
        // A microsecond lands within half a tick period, which is the most a
        // quantising timebase can promise.
        const half_tick_us = @divTrunc(tb.toMicros(1), 2) + 1;
        for ([_]i64{ 1_000_000, 33_333, 1_234_567 }) |us| {
            const landed = tb.toMicros(tb.fromMicros(us));
            const off = if (landed > us) landed - us else us - landed;
            if (off > half_tick_us) {
                r.no("{d}us in {d}/{d} landed {d}us away, past half a tick", .{ us, tb.num, tb.den, off });
                return;
            }
        }
    }
    r.ok("a tick round trips exactly and a microsecond lands within half a tick, at 90kHz, 29.97, 23.976 and microseconds", .{});
}

/// A container refuses a codec pair it cannot carry, which is what stops a file
/// being written that no player opens.
fn proveContainerRefusesWhatItCannotCarry(r: *Result) void {
    const bad = [_]struct { k: media.Container, v: media.VideoCodec, a: media.AudioCodec }{
        .{ .k = .mp4, .v = .vp9, .a = .aac },
        .{ .k = .mp4, .v = .h264, .a = .opus },
        .{ .k = .webm, .v = .h264, .a = .opus },
        .{ .k = .mov, .v = .vp8, .a = .aac },
    };
    for (bad) |c| {
        if (c.k.carries(c.v, c.a)) {
            r.no("{t} claimed it carries {t} with {t}", .{ c.k, c.v, c.a });
            return;
        }
    }
    if (!media.Container.mp4.carries(.h264, .aac) or !media.Container.webm.carries(.vp9, .opus)) {
        r.no("a container refused a pair it does carry", .{});
        return;
    }
    r.ok("every container refuses the pairs it cannot carry and accepts the ones it can", .{});
}

/// The codec state machine refuses a call the state does not allow, rather than
/// leaving it undefined, which is what the adapter's three error values did.
fn proveCodecStatesRefuseOutOfOrder(r: *Result) void {
    var m: media.CodecMachine = .{};
    m.feed() catch return r.no("a fresh machine refused its first feed", .{});
    m.drain() catch return r.no("a running machine refused its drain", .{});
    if (m.feed()) |_| return r.no("a draining machine accepted a feed", .{}) else |_| {}
    m.finish() catch return r.no("a draining machine refused its finish", .{});
    if (m.drain()) |_| return r.no("a flushed machine accepted a drain", .{}) else |_| {}
    m.fail();
    if (m.finish()) |_| return r.no("an errored machine accepted a finish", .{}) else |_| {}
    m.reset();
    m.feed() catch return r.no("a reset machine refused a feed", .{});
    r.ok("the codec machine refuses every call its state does not allow, and reset clears an error", .{});
}

/// A muxer refuses a packet that goes backwards, which is the symptom of a clock
/// that was not held across a pause.
fn proveMuxerRefusesBackwardsTime(r: *Result) void {
    var mux: media.Muxer = .{};
    _ = mux.addTrack(.{
        .kind = .video,
        .index = 0,
        .timebase = .microseconds,
        .video = .{ .width = 640, .height = 480, .codec = .h264 },
    }) catch return r.no("a muxer refused a valid track", .{});
    mux.writeHeader() catch return r.no("a muxer refused its header", .{});
    const bytes = [_]u8{1};
    mux.writePacket(.{ .payload = &bytes, .timebase = .microseconds, .pts = 2_000, .dts = 2_000 }) catch
        return r.no("a muxer refused a first packet", .{});
    if (mux.writePacket(.{ .payload = &bytes, .timebase = .microseconds, .pts = 1_000, .dts = 1_000 })) |_| {
        return r.no("a muxer accepted a packet that went backwards in time", .{});
    } else |_| {}
    mux.note(.pause) catch return r.no("a muxer refused a declared pause", .{});
    if (mux.clip_count != 2) return r.no("a pause produced {d} clips rather than 2", .{mux.clip_count});
    mux.finalize() catch return r.no("a muxer refused its finalize", .{});
    r.ok("a muxer refuses a backwards packet, counts a pause as a clip boundary, and finalizes once", .{});
}

/// The clock removes a pause from the output and does not count it as drift,
/// which is the whole reason it exists.
fn provePauseIsNotDrift(r: *Result) void {
    var clock: media.Clock = .{};
    _ = clock.map(0) catch return r.no("the clock refused its first stamp", .{});
    _ = clock.map(33_333) catch return r.no("the clock refused a second stamp", .{});
    clock.pause(40_000) catch return r.no("the clock refused a pause", .{});
    // A frame during the pause has no place in the output.
    if (clock.map(50_000)) |_| return r.no("the clock placed a frame submitted while paused", .{}) else |_| {}
    clock.resume_(10_040_000) catch return r.no("the clock refused a resume", .{});
    const out = clock.map(10_073_333) catch return r.no("the clock refused the frame after a resume", .{});
    if (out >= 10_000_000) return r.no("the output grew to {d}us across a 10s pause", .{out});
    if (clock.driftUs() >= 1_000_000) return r.no("the pause counted as {d}us of drift", .{clock.driftUs()});
    r.ok("a ten second pause leaves {d}us of output and {d}us of drift", .{ out, clock.driftUs() });
}

/// Backend selection is deterministic and refuses rather than guessing, so a
/// request no backend serves is heard before a file is open.
fn proveSelectionIsDeterministic(r: *Result) void {
    const hw: media.Backend = .{
        .name = "hardware",
        .video = &.{.{ .codec = .h264, .max_width = 4096, .max_height = 2160 }},
        .audio = &.{.aac},
        .containers = &.{.mp4},
        .zero_copy = true,
        .rank = 10,
    };
    const sw: media.Backend = .{
        .name = "software",
        .video = &.{.{ .codec = .h264, .max_width = 1920, .max_height = 1080 }},
        .audio = &.{.aac},
        .containers = &.{.mp4},
        .rank = 50,
    };
    const set = [_]media.Backend{ sw, hw };
    const req: media.Request = .{ .video = .{ .width = 1920, .height = 1080, .codec = .h264 }, .audio = .aac, .container = .mp4 };
    var last: ?usize = null;
    for (0..8) |_| {
        const pick = media.selectBackend(&set, req) catch return r.no("no backend served a request both serve", .{});
        if (last) |l| {
            if (l != pick) return r.no("selection picked {d} then {d} for one request", .{ l, pick });
        }
        last = pick;
    }
    if (!std.mem.eql(u8, set[last.?].name, "hardware")) {
        return r.no("selection picked {s} over the lower-ranked hardware backend", .{set[last.?].name});
    }
    // A request past every profile is refused, not served by the nearest thing.
    if (media.selectBackend(&set, .{ .video = .{ .width = 8192, .height = 4320, .codec = .h264 }, .audio = .aac, .container = .mp4 })) |_| {
        return r.no("a request past every profile was served anyway", .{});
    } else |_| {}
    r.ok("selection is stable across eight identical requests, prefers the lower rank, and refuses what nothing serves", .{});
}

/// A demuxer refuses a seek past the end rather than clamping it, which is what
/// lets a scrubber trust the position it reads back.
fn proveSeekRefusesRatherThanClamps(r: *Result) void {
    var d: media.Demuxer = .{};
    d.parsed(1, 5_000_000) catch return r.no("a demuxer refused a valid header", .{});
    d.seek(2_500_000, .exact) catch return r.no("a demuxer refused a seek inside its duration", .{});
    if (d.position_us != 2_500_000) return r.no("a seek landed at {d}us rather than the target", .{d.position_us});
    if (d.seek(6_000_000, .exact)) |_| return r.no("a seek past the end was accepted, so it clamped", .{}) else |_| {}
    if (d.position_us != 2_500_000) return r.no("a refused seek moved the position to {d}us", .{d.position_us});
    r.ok("a seek lands where it was asked and a seek past the end is refused with the position unmoved", .{});
}

/// The frame cache is bounded and hands every evicted frame back, so a scrub does
/// not leak one decoded frame per step past capacity.
fn proveCacheIsBoundedAndLeaksNothing(r: *Result) void {
    const Cache = media.FrameCache(u32);
    var cache = Cache.init(std.heap.page_allocator, 4) catch return r.no("the cache would not allocate", .{});
    defer cache.deinit(std.heap.page_allocator);
    var handed_back: u32 = 0;
    for (0..64) |i| {
        if (cache.put(@intCast(i * 1000), @intCast(i))) |_| handed_back += 1;
    }
    if (cache.count() != 4) return r.no("the cache holds {d} frames at a capacity of 4", .{cache.count()});
    // Sixty-four stores into four slots: everything past the first four comes back.
    if (handed_back != 60) return r.no("the cache handed back {d} frames rather than 60", .{handed_back});
    var out: [4]u32 = undefined;
    if (cache.drain(&out) != 4) return r.no("draining did not hand back every held frame", .{});
    r.ok("the cache holds its bound over 64 stores and hands back all {d} frames it displaced", .{handed_back});
}

/// Colour metadata that cannot be written is refused at the boundary, never
/// guessed at, and the conversion follows the matrix rather than the primaries.
fn proveColorIsValidatedNotGuessed(r: *Result) void {
    if ((media.ColorInfo{ .transfer = .pq, .bit_depth = 8 }).valid()) {
        return r.no("a ten-bit transfer at eight bits was accepted", .{});
    }
    if ((media.ColorInfo{ .primaries = .bt2020, .matrix = .bt601 }).valid()) {
        return r.no("bt2020 primaries with a bt601 matrix were accepted", .{});
    }
    if (media.matrixStandard(.{ .primaries = .display_p3, .matrix = .bt709 }) != .bt709) {
        return r.no("a display-p3 frame with bt709 coefficients did not convert as bt709", .{});
    }
    // Video-range black is code 16, and reading it as full range lifts it.
    const black = media.yuvToRgb8(.{}, 16, 128, 128);
    if (black[0] != 0 or black[1] != 0 or black[2] != 0) {
        return r.no("video-range black came out as {d},{d},{d}", .{ black[0], black[1], black[2] });
    }
    const lifted = media.yuvToRgb8(.{ .range = .full }, 16, 128, 128);
    if (lifted[0] == 0) return r.no("the same code was black under both ranges, so the range did nothing", .{});
    r.ok("colour is validated rather than guessed, follows the matrix not the primaries, and the range changes the result", .{});
}

/// An encoder configuration is checked before a backend sees it, so a file that
/// cannot be written is refused rather than half-produced.
fn proveConfigurationFailsClosed(r: *Result) void {
    const hd: media.EncodedVideoDesc = .{ .width = 1920, .height = 1080, .codec = .h264 };
    (media.EncoderConfig{ .video = hd, .audio = .{ .codec = .aac }, .container = .mp4 }).check() catch
        return r.no("a valid configuration was refused", .{});
    const bad = [_]media.EncoderConfig{
        .{ .video = hd, .audio = .{ .codec = .opus }, .container = .mp4 },
        .{ .video = .{ .width = 0, .height = 1080, .codec = .h264 }, .container = .mp4 },
        .{ .video = .{ .width = 1920, .height = 1080, .codec = .h264, .color = .{ .transfer = .pq, .bit_depth = 10 } }, .container = .mp4 },
    };
    for (bad, 0..) |cfg, i| {
        if (cfg.check()) |_| return r.no("configuration {d} was accepted and should not be", .{i}) else |_| {}
    }
    r.ok("an unwritable configuration is refused before any backend sees it", .{});
}

pub fn main() !void {
    var r: Result = .{};
    proveTimebaseRoundTrips(&r);
    proveContainerRefusesWhatItCannotCarry(&r);
    proveCodecStatesRefuseOutOfOrder(&r);
    proveMuxerRefusesBackwardsTime(&r);
    provePauseIsNotDrift(&r);
    proveSelectionIsDeterministic(&r);
    proveSeekRefusesRatherThanClamps(&r);
    proveCacheIsBoundedAndLeaksNothing(&r);
    proveColorIsValidatedNotGuessed(&r);
    proveConfigurationFailsClosed(&r);
    std.debug.print("media: {d} proofs, {d} failures\n", .{ r.passed, r.failed });
    if (r.failed != 0) std.process.exit(1);
}
