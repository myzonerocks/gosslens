//! On-device acoustic fingerprinting for music identification, model-free. Audio
//! is resampled and reduced to a constellation of spectral peaks; peak pairs pack
//! into 24-bit landmark hashes, and a snippet matches a registered track by the
//! time offset its landmarks share - the track and lag with the most agreement.
const std = @import("std");
const fft_mod = @import("fft");

/// The rate every recording is resampled to before analysis, so a reference and a
/// query fingerprint line up regardless of their capture rate. Classic for
/// fingerprinting: low enough to be cheap, wide enough to hold a voice or melody.
pub const canonical_rate: u32 = 11025;

const fft_size: usize = 1024;
const hop: usize = 512;
const half: usize = fft_size / 2;
/// Log-spaced bands the peak picker keeps one peak from per frame, so strong bass
/// never crowds out a quiet high harmonic.
const bands: usize = 6;
/// Peaks paired ahead of each anchor, and the frame window they may sit in. The
/// delta packs into six bits, so the target zone is at most 63 frames ahead.
const fan_out: usize = 5;
const target_dt_max: u32 = 63;

/// A landmark: a 24-bit hash of a peak pair (anchor bin, target bin, frame delta)
/// and the frame the anchor sat at. Time is in hops, not samples.
pub const Landmark = struct { hash: u32, t: u32 };

/// The best track a query agreed with: its id, how many landmarks lined up at one
/// offset, and that offset in hops. `votes` is the confidence signal.
pub const Match = struct { id: u32, votes: u32, offset: i64 };

const Peak = struct { t: u32, bin: u16 };

const hann: [fft_size]f32 = blk: {
    @setEvalBranchQuota(40000);
    var w: [fft_size]f32 = undefined;
    for (&w, 0..) |*v, i| {
        const p = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(fft_size));
        v.* = @floatCast(0.5 - 0.5 * @cos(p));
    }
    break :blk w;
};

/// The log-spaced bin edge between band `b` and `b+1`, spanning bins 1..half.
fn bandEdge(b: usize) usize {
    const lo: f64 = 1;
    const hi: f64 = @floatFromInt(half);
    const f = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(bands));
    const edge = lo * std.math.pow(f64, hi / lo, f);
    return @intFromFloat(edge);
}

/// Downmixes to mono and linearly resamples to the canonical rate, returning an
/// owned buffer the caller frees. An empty or rate-less input yields an empty
/// buffer rather than an error, so a silent snippet just finds no landmarks.
fn toCanonicalMono(gpa: std.mem.Allocator, samples: []const f32, frame_count: u32, sample_rate: u32, channels: u32) ![]f32 {
    if (frame_count == 0 or sample_rate == 0 or channels == 0) return gpa.alloc(f32, 0);
    const ch: usize = channels;
    const out_wide = @as(u64, frame_count) * canonical_rate / sample_rate;
    if (out_wide > std.math.maxInt(usize)) return error.OutOfMemory;
    const out_n: usize = @intCast(out_wide);
    if (out_n == 0) return gpa.alloc(f32, 0);
    const out = try gpa.alloc(f32, out_n);
    const ratio = @as(f64, @floatFromInt(sample_rate)) / @as(f64, @floatFromInt(canonical_rate));
    const last = frame_count - 1;
    for (0..out_n) |i| {
        const pos = @as(f64, @floatFromInt(i)) * ratio;
        const idx0: u32 = @min(@as(u32, @intFromFloat(pos)), last);
        const idx1: u32 = @min(idx0 + 1, last);
        const frac: f32 = @floatCast(pos - @floor(pos));
        var a: f32 = 0;
        var b: f32 = 0;
        for (0..ch) |c| {
            a += samples[@as(usize, idx0) * ch + c];
            b += samples[@as(usize, idx1) * ch + c];
        }
        const inv: f32 = 1.0 / @as(f32, @floatFromInt(ch));
        out[i] = (a * (1.0 - frac) + b * frac) * inv;
    }
    return out;
}

/// Picks the constellation peaks from canonical mono audio: one strong local peak
/// per log band per frame, above the frame's mean magnitude. Appends to `peaks`.
fn pickPeaks(mono: []const f32, peaks: *std.ArrayListUnmanaged(Peak), gpa: std.mem.Allocator) !void {
    if (mono.len < fft_size) return;
    const frames = (mono.len - fft_size) / hop + 1;
    var re: [fft_size]f32 = undefined;
    var im: [fft_size]f32 = undefined;
    var mag: [half + 1]f32 = undefined;
    for (0..frames) |f| {
        const base = f * hop;
        for (0..fft_size) |i| {
            re[i] = mono[base + i] * hann[i];
            im[i] = 0;
        }
        fft_mod.transform(fft_size, &re, &im, false);
        var mean: f32 = 0;
        for (0..half + 1) |k| {
            mag[k] = @sqrt(re[k] * re[k] + im[k] * im[k]);
            mean += mag[k];
        }
        mean /= @floatFromInt(half + 1);
        // Keep the strongest bin in each band if it stands above the frame mean.
        for (0..bands) |bnd| {
            const lo = @max(bandEdge(bnd), 1);
            const hi = @min(bandEdge(bnd + 1), half);
            var best_bin: usize = 0;
            var best_mag: f32 = 0;
            var k = lo;
            while (k < hi) : (k += 1) {
                if (mag[k] > best_mag) {
                    best_mag = mag[k];
                    best_bin = k;
                }
            }
            if (best_bin > 0 and best_mag > mean * 1.5) {
                try peaks.append(gpa, .{ .t = @intCast(f), .bin = @intCast(best_bin) });
            }
        }
    }
}

/// Packs an anchor and a target peak into a 24-bit landmark hash: nine bits of
/// each bin and six of the frame delta.
fn packHash(anchor_bin: u16, target_bin: u16, dt: u32) u32 {
    const a: u32 = @as(u32, anchor_bin) & 0x1FF;
    const b: u32 = @as(u32, target_bin) & 0x1FF;
    return (a << 15) | (b << 6) | (dt & 0x3F);
}

/// Fingerprints a recording into an owned array of landmarks the caller frees.
/// Peaks are paired anchor-to-target within a forward frame window, so the hashes
/// encode local time-frequency structure that survives noise and level changes.
pub fn fingerprint(gpa: std.mem.Allocator, samples: []const f32, frame_count: u32, sample_rate: u32, channels: u32) ![]Landmark {
    const mono = try toCanonicalMono(gpa, samples, frame_count, sample_rate, channels);
    defer gpa.free(mono);

    var peaks: std.ArrayListUnmanaged(Peak) = .empty;
    defer peaks.deinit(gpa);
    try pickPeaks(mono, &peaks, gpa);

    var marks: std.ArrayListUnmanaged(Landmark) = .empty;
    errdefer marks.deinit(gpa);
    const p = peaks.items;
    for (p, 0..) |anchor, i| {
        var paired: usize = 0;
        var j = i + 1;
        while (j < p.len and paired < fan_out) : (j += 1) {
            const dt = p[j].t - anchor.t;
            if (dt == 0) continue;
            if (dt > target_dt_max) break;
            try marks.append(gpa, .{ .hash = packHash(anchor.bin, p[j].bin, dt), .t = anchor.t });
            paired += 1;
        }
    }
    return marks.toOwnedSlice(gpa);
}

/// A catalog of registered tracks queried by fingerprint. Landmarks are stored in
/// one flat array kept sorted by hash, so a query binary-searches each hash and
/// votes the time offset it shares - O(Q log M) over Q query and M catalog marks.
pub const Database = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    sorted: bool = true,

    const Entry = struct { hash: u32, track: u32, t: u32 };

    pub fn init(gpa: std.mem.Allocator) Database {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Database) void {
        self.entries.deinit(self.gpa);
    }

    /// Registers a track's landmarks under `id`. Re-adding an id just layers more
    /// landmarks in, so a longer reference can be built from several snippets.
    pub fn add(self: *Database, id: u32, marks: []const Landmark) !void {
        try self.entries.ensureUnusedCapacity(self.gpa, marks.len);
        for (marks) |m| self.entries.appendAssumeCapacity(.{ .hash = m.hash, .track = id, .t = m.t });
        self.sorted = false;
    }

    pub fn clear(self: *Database) void {
        self.entries.clearRetainingCapacity();
        self.sorted = true;
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return a.hash < b.hash;
    }

    fn ensureSorted(self: *Database) void {
        if (self.sorted) return;
        std.mem.sort(Entry, self.entries.items, {}, lessThan);
        self.sorted = true;
    }

    /// Matches a query fingerprint against the catalog, returning the track and
    /// offset with the most landmark agreement, or null below `min_votes`. The
    /// offset histogram is a scratch map allocated and freed here.
    pub fn match(self: *Database, query: []const Landmark, min_votes: u32) !?Match {
        self.ensureSorted();
        const items = self.entries.items;
        if (items.len == 0 or query.len == 0) return null;

        // Frame indices widen to i64 before the subtraction, so the offset can
        // never overflow or trip a narrowing cast on a caller's frame count.
        const Key = struct { track: u32, offset: i64 };
        var votes = std.AutoHashMap(Key, u32).init(self.gpa);
        defer votes.deinit();

        for (query) |q| {
            // Binary-search the contiguous run of catalog entries with this hash.
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (items[mid].hash < q.hash) lo = mid + 1 else hi = mid;
            }
            var k = lo;
            while (k < items.len and items[k].hash == q.hash) : (k += 1) {
                const off = @as(i64, items[k].t) - @as(i64, q.t);
                const key = Key{ .track = items[k].track, .offset = off };
                const gop = try votes.getOrPut(key);
                gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
            }
        }

        var best: ?Match = null;
        var it = votes.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr.*;
            if (best == null or v > best.?.votes) {
                best = .{ .id = e.key_ptr.track, .votes = v, .offset = e.key_ptr.offset };
            }
        }
        if (best) |m| {
            if (m.votes >= min_votes) return m;
        }
        return null;
    }
};

const t = std.testing;

// Builds a mono buffer of a few stacked sinusoids so a fingerprint has structure.
fn tones(buf: []f32, sr: u32, freqs: []const f32, phase: usize) void {
    for (buf, 0..) |*v, i| {
        var s: f32 = 0;
        for (freqs) |fr| s += @sin(2.0 * std.math.pi * fr * @as(f32, @floatFromInt(i + phase)) / @as(f32, @floatFromInt(sr)));
        v.* = s / @as(f32, @floatFromInt(freqs.len));
    }
}

// A rising staircase melody: the fundamental steps up every note, and with its
// two harmonics gives each time segment a distinct spectral signature, so the
// fingerprint carries real temporal structure a match can localise in time.
fn melody(buf: []f32, sr: u32, base: f32, step: f32, note_len: usize) void {
    for (buf, 0..) |*v, i| {
        const seg: f32 = @floatFromInt(i / note_len);
        const f0 = base + seg * step;
        const p = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr));
        const s = @sin(2.0 * std.math.pi * f0 * p) +
            0.5 * @sin(2.0 * std.math.pi * 2.0 * f0 * p) +
            0.3 * @sin(2.0 * std.math.pi * 3.0 * f0 * p);
        v.* = s / 1.8;
    }
}

test "a fingerprint is deterministic and non-empty for structured audio" {
    const gpa = t.allocator;
    const sr: u32 = 11025;
    var buf: [sr]f32 = undefined; // one second
    tones(&buf, sr, &[_]f32{ 440, 880, 1600, 2500 }, 0);
    const a = try fingerprint(gpa, &buf, sr, sr, 1);
    defer gpa.free(a);
    const b = try fingerprint(gpa, &buf, sr, sr, 1);
    defer gpa.free(b);
    try t.expect(a.len > 0);
    try t.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try t.expectEqual(x.hash, y.hash);
        try t.expectEqual(x.t, y.t);
    }
}

test "a query snippet identifies its source track over a decoy" {
    const gpa = t.allocator;
    const sr: u32 = 11025;

    const note_len = sr / 5; // a fresh note every 0.2 s
    const song = try gpa.alloc(f32, sr * 5); // five seconds
    defer gpa.free(song);
    melody(song, sr, 200, 40, note_len);

    const decoy = try gpa.alloc(f32, sr * 5);
    defer gpa.free(decoy);
    melody(decoy, sr, 190, 33, note_len);

    var db = Database.init(gpa);
    defer db.deinit();
    const song_fp = try fingerprint(gpa, song, sr * 5, sr, 1);
    defer gpa.free(song_fp);
    const decoy_fp = try fingerprint(gpa, decoy, sr * 5, sr, 1);
    defer gpa.free(decoy_fp);
    try db.add(1, song_fp);
    try db.add(2, decoy_fp);

    // A two-second snippet cut from the middle of track 1, with mild noise added.
    const start = sr * 2;
    const snippet = try gpa.alloc(f32, sr * 2);
    defer gpa.free(snippet);
    var seed: u32 = 12345;
    for (snippet, 0..) |*v, i| {
        seed = seed *% 1664525 +% 1013904223;
        const noise = (@as(f32, @floatFromInt(seed >> 16)) / 32768.0 - 1.0) * 0.05;
        v.* = song[start + i] + noise;
    }
    const q = try fingerprint(gpa, snippet, sr * 2, sr, 1);
    defer gpa.free(q);

    const m = try db.match(q, 5);
    try t.expect(m != null);
    try t.expectEqual(@as(u32, 1), m.?.id);
    // The snippet began two seconds in, so the winning offset is near that lag in
    // hops (2 s * 11025 / 512 hops), positive because the reference leads.
    const expected: i64 = @intCast(start / hop);
    try t.expect(@abs(m.?.offset - expected) <= 2);
}

test "unrelated audio finds no confident match" {
    const gpa = t.allocator;
    const sr: u32 = 11025;
    const song = try gpa.alloc(f32, sr * 4);
    defer gpa.free(song);
    tones(song, sr, &[_]f32{ 440, 880, 1320 }, 0);

    var db = Database.init(gpa);
    defer db.deinit();
    const fp = try fingerprint(gpa, song, sr * 4, sr, 1);
    defer gpa.free(fp);
    try db.add(7, fp);

    const other = try gpa.alloc(f32, sr * 2);
    defer gpa.free(other);
    tones(other, sr, &[_]f32{ 517, 1234, 2011 }, 0);
    const q = try fingerprint(gpa, other, sr * 2, sr, 1);
    defer gpa.free(q);

    const m = try db.match(q, 5);
    try t.expect(m == null);
}

test "the canonical resampler downmixes and changes rate" {
    const gpa = t.allocator;
    // Two channels at 22050 halve to mono at 11025: the frame count halves.
    const stereo: [8]f32 = .{ 1, -1, 1, -1, 1, -1, 1, -1 }; // 4 frames, mono sums to 0
    const mono = try toCanonicalMono(gpa, &stereo, 4, 22050, 2);
    defer gpa.free(mono);
    try t.expectEqual(@as(usize, 2), mono.len);
    for (mono) |v| try t.expectApproxEqAbs(@as(f32, 0), v, 1e-6);
}
