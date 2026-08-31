//! On-device media-library primitives: the algorithmic core under a personal
//! archive. Semantic search is exact cosine k-nearest over bring-your-own
//! embedding vectors; the vault seals a blob with authenticated ChaCha20-Poly1305
//! under a host key; burst fusion picks the sharpest, most-open frame. No model here.
const std = @import("std");
const aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

/// A sealed blob carries the ciphertext followed by the 16-byte auth tag, so
/// seal output is plaintext length plus this and open output is the reverse.
pub const tag_length = aead.tag_length;
pub const key_length = aead.key_length;
pub const nonce_length = aead.nonce_length;

/// Cosine similarity of two equal-length vectors, 0 when either is the zero
/// vector. The archive's embeddings and the query are compared this way so the
/// magnitude a model happens to emit never skews the ranking.
pub fn cosine(a: []const f32, b: []const f32) f32 {
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * y;
        na += @as(f64, x) * x;
        nb += @as(f64, y) * y;
    }
    if (na == 0 or nb == 0) return 0;
    return @floatCast(dot / (@sqrt(na) * @sqrt(nb)));
}

/// Ranks count vectors of length dim, packed contiguously in corpus, against
/// query by descending cosine similarity into out_idx/out_score, ties keeping
/// the lower index; returns how many were written (min of k and count). Exact
/// linear scan: right on-device, an approximate index is the cloud's job at scale.
pub fn search(corpus: []const f32, count: usize, dim: usize, query: []const f32, out_idx: []u32, out_score: []f32) usize {
    const k = @min(out_idx.len, out_score.len);
    if (k == 0 or dim == 0 or query.len != dim) return 0;
    var kept: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const base = i * dim;
        if (base + dim > corpus.len) break;
        const score = cosine(query, corpus[base .. base + dim]);
        // Insert into the descending window; a strict comparison keeps the
        // earlier (lower) index ahead on a tie.
        if (kept < k) {
            var j = kept;
            while (j > 0 and out_score[j - 1] < score) : (j -= 1) {
                out_score[j] = out_score[j - 1];
                out_idx[j] = out_idx[j - 1];
            }
            out_score[j] = score;
            out_idx[j] = @intCast(i);
            kept += 1;
        } else if (score > out_score[k - 1]) {
            var j = k - 1;
            while (j > 0 and out_score[j - 1] < score) : (j -= 1) {
                out_score[j] = out_score[j - 1];
                out_idx[j] = out_idx[j - 1];
            }
            out_score[j] = score;
            out_idx[j] = @intCast(i);
        }
    }
    return kept;
}

/// Seals plaintext under key and nonce into out (ciphertext then tag), binding
/// aad. out must hold plaintext.len + tag_length. The caller keeps key in the
/// platform keystore and never persists it beside the blob.
pub fn seal(key: [key_length]u8, nonce: [nonce_length]u8, plaintext: []const u8, aad: []const u8, out: []u8) void {
    std.debug.assert(out.len >= plaintext.len + tag_length);
    const ct = out[0..plaintext.len];
    var tag: [tag_length]u8 = undefined;
    aead.encrypt(ct, &tag, plaintext, aad, nonce, key);
    @memcpy(out[plaintext.len .. plaintext.len + tag_length], &tag);
}

/// Opens a sealed blob (ciphertext then tag) back into out under key and nonce,
/// binding the same aad, returning the plaintext length. Errors if the key,
/// nonce, aad, or bytes were tampered, so a corrupted or forged blob never
/// decodes to plausible media.
pub fn open(key: [key_length]u8, nonce: [nonce_length]u8, sealed: []const u8, aad: []const u8, out: []u8) !usize {
    if (sealed.len < tag_length) return error.AuthenticationFailed;
    const ct_len = sealed.len - tag_length;
    std.debug.assert(out.len >= ct_len);
    var tag: [tag_length]u8 = undefined;
    @memcpy(&tag, sealed[ct_len..]);
    try aead.decrypt(out[0..ct_len], sealed[0..ct_len], tag, aad, nonce, key);
    return ct_len;
}

/// Sharpness of a luminance frame as the variance of its Laplacian: a focused
/// frame has strong high-frequency edges and a blurred one does not, so this
/// separates the sharp shot from the smeared one in a burst without a model.
pub fn sharpness(luma: []const u8, width: usize, height: usize) f64 {
    if (width < 3 or height < 3 or luma.len < width * height) return 0;
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    var n: f64 = 0;
    var y: usize = 1;
    while (y < height - 1) : (y += 1) {
        var x: usize = 1;
        while (x < width - 1) : (x += 1) {
            const c = @as(i32, luma[y * width + x]);
            const lap = @as(i32, luma[y * width + x - 1]) + luma[y * width + x + 1] +
                luma[(y - 1) * width + x] + luma[(y + 1) * width + x] - 4 * c;
            const l: f64 = @floatFromInt(lap);
            sum += l;
            sum_sq += l * l;
            n += 1;
        }
    }
    if (n == 0) return 0;
    const mean = sum / n;
    return sum_sq / n - mean * mean;
}

/// Picks the best frame of a burst: count luminance frames of width*height,
/// frame_stride bytes apart, scored by normalized sharpness blended with a host
/// openness score (eyes-open, smile) weighted by openness_weight in 0..1.
/// Returns the winning frame index for best-take fusion; ties keep the earlier.
pub fn bestTake(frames: []const u8, frame_stride: usize, count: usize, width: usize, height: usize, openness: []const f32, openness_weight: f32) usize {
    if (count == 0) return 0;
    var max_sharp: f64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = i * frame_stride;
        if (off + width * height > frames.len) break;
        const s = sharpness(frames[off .. off + width * height], width, height);
        if (s > max_sharp) max_sharp = s;
    }
    const w: f64 = @max(0, @min(1, openness_weight));
    var best_idx: usize = 0;
    var best_score: f64 = -1;
    i = 0;
    while (i < count) : (i += 1) {
        const off = i * frame_stride;
        if (off + width * height > frames.len) break;
        const norm = if (max_sharp > 0) sharpness(frames[off .. off + width * height], width, height) / max_sharp else 0;
        const open_s: f64 = if (i < openness.len) @max(0, @min(1, openness[i])) else 0;
        const score = (1 - w) * norm + w * open_s;
        if (score > best_score) {
            best_score = score;
            best_idx = i;
        }
    }
    return best_idx;
}

const t = std.testing;

test "search ranks nearest by cosine and keeps top-k in order" {
    // Three 2-D vectors; a query aligned with the second should rank it first.
    const corpus = [_]f32{ 1, 0, 0, 1, 0.9, 0.1 };
    const query = [_]f32{ 0, 2 };
    var idx: [2]u32 = undefined;
    var score: [2]f32 = undefined;
    const n = search(&corpus, 3, 2, &query, &idx, &score);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(@as(u32, 1), idx[0]);
    try t.expect(score[0] > score[1]);
}

test "seal round-trips under the key and rejects tampering" {
    const key = [_]u8{7} ** key_length;
    const nonce = [_]u8{3} ** nonce_length;
    const plain = "a private capture blob";
    const aad = "capture-2026";
    var sealed: [64]u8 = undefined;
    seal(key, nonce, plain, aad, sealed[0 .. plain.len + tag_length]);
    var opened: [64]u8 = undefined;
    const n = try open(key, nonce, sealed[0 .. plain.len + tag_length], aad, opened[0..plain.len]);
    try t.expectEqualStrings(plain, opened[0..n]);
    // A flipped ciphertext byte must fail authentication.
    sealed[0] ^= 0xff;
    try t.expectError(error.AuthenticationFailed, open(key, nonce, sealed[0 .. plain.len + tag_length], aad, opened[0..plain.len]));
}

test "best-take prefers the sharp frame, then honors openness" {
    // Two 4x4 frames: a flat one and a checkerboard (high Laplacian variance).
    const flat = [_]u8{128} ** 16;
    const sharp = [_]u8{ 0, 255, 0, 255, 255, 0, 255, 0, 0, 255, 0, 255, 255, 0, 255, 0 };
    var frames: [32]u8 = undefined;
    @memcpy(frames[0..16], &flat);
    @memcpy(frames[16..32], &sharp);
    const open_none = [_]f32{ 0, 0 };
    try t.expectEqual(@as(usize, 1), bestTake(&frames, 16, 2, 4, 4, &open_none, 0));
    // With all weight on openness, the flat-but-open frame wins.
    const open_first = [_]f32{ 1, 0 };
    try t.expectEqual(@as(usize, 0), bestTake(&frames, 16, 2, 4, 4, &open_first, 1));
}
