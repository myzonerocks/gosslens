//! On-device QR codec, both directions first-class: encode a payload to a QR to
//! share a lens, unlock, or join a session, and decode one from the camera to
//! scan-to-unlock. Versions 1-4 at level L, byte mode, all eight masks,
//! Reed-Solomon over GF(256). Algorithmic and deterministic, no model.
const std = @import("std");

pub const max_version = 4;
pub const max_size = 17 + 4 * max_version; // v4 is 33x33

// GF(256) with primitive polynomial x^8+x^4+x^3+x^2+1 (0x11d), the QR field.
var gf_exp: [512]u8 = undefined;
var gf_log: [256]u8 = undefined;
var gf_ready = false;

fn gfInit() void {
    if (gf_ready) return;
    var x: u16 = 1;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        gf_exp[i] = @intCast(x);
        gf_log[@intCast(x)] = @intCast(i);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11d;
    }
    // Mirror the table so a product index up to 510 needs no modulo.
    i = 255;
    while (i < 512) : (i += 1) gf_exp[i] = gf_exp[i - 255];
    gf_ready = true;
}

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return gf_exp[@as(usize, gf_log[a]) + gf_log[b]];
}

fn gfDiv(a: u8, b: u8) u8 {
    if (a == 0) return 0;
    return gf_exp[@as(usize, gf_log[a]) + 255 - gf_log[b]];
}

/// Version parameters at level L: matrix size, total codewords, and the split
/// into error-correction and data codewords (single block for v1-4 at L).
const VersionInfo = struct { size: usize, total: usize, ec: usize, data: usize, align_pos: ?usize };
const versions = [max_version]VersionInfo{
    .{ .size = 21, .total = 26, .ec = 7, .data = 19, .align_pos = null },
    .{ .size = 25, .total = 44, .ec = 10, .data = 34, .align_pos = 18 },
    .{ .size = 29, .total = 70, .ec = 15, .data = 55, .align_pos = 22 },
    .{ .size = 33, .total = 100, .ec = 20, .data = 80, .align_pos = 26 },
};

fn vinfo(version: usize) VersionInfo {
    return versions[version - 1];
}

/// The Reed-Solomon generator polynomial for `n` error-correction codewords.
fn rsGenerator(n: usize, out: []u8) void {
    out[0] = 1;
    var len: usize = 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Multiply the current polynomial by (x - alpha^i).
        var j: usize = len;
        out[j] = 0;
        len += 1;
        while (j > 0) : (j -= 1) {
            out[j] = out[j - 1] ^ gfMul(out[j], gf_exp[i]);
        }
        out[0] = gfMul(out[0], gf_exp[i]);
    }
}

/// The `n` error-correction codewords for `data`, by synthetic division of
/// data(x)*x^n by the generator. The generator from rsGenerator is ascending
/// (constant first), so its term of degree (n-j) is gen[n-j].
fn rsEncode(data: []const u8, n: usize, out: []u8) void {
    var gen: [32]u8 = undefined;
    rsGenerator(n, gen[0 .. n + 1]);
    var work: [512]u8 = undefined;
    @memcpy(work[0..data.len], data);
    @memset(work[data.len .. data.len + n], 0);
    for (0..data.len) |i| {
        const factor = work[i];
        if (factor == 0) continue;
        var j: usize = 1;
        while (j <= n) : (j += 1) work[i + j] ^= gfMul(gen[n - j], factor);
    }
    @memcpy(out[0..n], work[data.len .. data.len + n]);
}

/// Evaluates polynomial p (ascending: p[0] the constant term) at x.
fn polyEval(p: []const u8, x: u8) u8 {
    var y: u8 = 0;
    var i: usize = p.len;
    while (i > 0) : (i -= 1) y = gfMul(y, x) ^ p[i - 1];
    return y;
}

/// Corrects `codewords` (data followed by ec, index 0 the highest degree) in
/// place using syndrome decoding; returns false when the errors exceed capacity.
/// Positions are degrees e = nn-1-index, so X_k = alpha^e locates an error.
fn rsDecode(codewords: []u8, n_ec: usize) bool {
    const nn = codewords.len;
    // Syndromes S_i = C(alpha^i), i = 0..n_ec-1.
    var synd: [32]u8 = @splat(0);
    var has_error = false;
    for (0..n_ec) |i| {
        var s: u8 = 0;
        for (codewords) |c| s = gfMul(s, gf_exp[i]) ^ c;
        synd[i] = s;
        if (s != 0) has_error = true;
    }
    if (!has_error) return true;
    // Berlekamp-Massey for the error locator lambda (ascending, lambda[0]=1);
    // standard form with an explicit shift m and the saved polynomial b_poly.
    var lambda: [33]u8 = @splat(0);
    var b_poly: [33]u8 = @splat(0);
    lambda[0] = 1;
    b_poly[0] = 1;
    var ll: usize = 0;
    var mshift: usize = 1;
    var bb: u8 = 1;
    for (0..n_ec) |n| {
        var delta: u8 = synd[n];
        var j: usize = 1;
        while (j <= ll) : (j += 1) delta ^= gfMul(lambda[j], synd[n - j]);
        if (delta == 0) {
            mshift += 1;
        } else if (2 * ll <= n) {
            const saved: [33]u8 = lambda;
            const coef = gfDiv(delta, bb);
            var i: usize = 0;
            while (i + mshift < 33) : (i += 1) lambda[i + mshift] ^= gfMul(coef, b_poly[i]);
            ll = n + 1 - ll;
            b_poly = saved;
            bb = delta;
            mshift = 1;
        } else {
            const coef = gfDiv(delta, bb);
            var i: usize = 0;
            while (i + mshift < 33) : (i += 1) lambda[i + mshift] ^= gfMul(coef, b_poly[i]);
            mshift += 1;
        }
    }
    if (ll == 0 or ll > n_ec / 2) return false;
    // Chien search over degree positions e = 0..nn-1: lambda(alpha^-e) == 0.
    var err_deg: [32]usize = undefined;
    var err_count: usize = 0;
    for (0..nn) |e| {
        const xinv = gf_exp[(255 - (e % 255)) % 255];
        if (polyEval(lambda[0 .. ll + 1], xinv) == 0) {
            if (err_count >= ll) return false;
            err_deg[err_count] = e;
            err_count += 1;
        }
    }
    if (err_count != ll) return false;
    // Error evaluator omega = (S * lambda) mod x^n_ec (ascending).
    var omega: [33]u8 = @splat(0);
    for (0..n_ec) |i| {
        var s: u8 = 0;
        var j: usize = 0;
        while (j <= i) : (j += 1) if (j <= ll) {
            s ^= gfMul(synd[i - j], lambda[j]);
        };
        omega[i] = s;
    }
    // Forney: magnitude at degree e is X * omega(X^-1) / lambda'(X^-1), X=alpha^e.
    for (err_deg[0..err_count]) |e| {
        const x = gf_exp[e % 255];
        const xinv = gfDiv(1, x);
        const num = polyEval(omega[0..n_ec], xinv);
        // lambda' keeps the odd-index terms; its value at xinv.
        var den: u8 = 0;
        var j: usize = 1;
        while (j <= ll) : (j += 2) den ^= gfMul(lambda[j], gf_exp[(gf_log[xinv] * (j - 1)) % 255]);
        if (den == 0) return false;
        const mag = gfMul(x, gfDiv(num, den));
        const index = nn - 1 - e;
        codewords[index] ^= mag;
    }
    // Verify the correction actually cleared the syndromes.
    for (0..n_ec) |i| {
        var s: u8 = 0;
        for (codewords) |c| s = gfMul(s, gf_exp[i]) ^ c;
        if (s != 0) return false;
    }
    return true;
}

fn maskBit(mask: u8, r: usize, c: usize) bool {
    return switch (mask) {
        0 => (r + c) % 2 == 0,
        1 => r % 2 == 0,
        2 => c % 3 == 0,
        3 => (r + c) % 3 == 0,
        4 => (r / 2 + c / 3) % 2 == 0,
        5 => (r * c) % 2 + (r * c) % 3 == 0,
        6 => ((r * c) % 2 + (r * c) % 3) % 2 == 0,
        else => ((r + c) % 2 + (r * c) % 3) % 2 == 0,
    };
}

pub const Matrix = struct {
    size: usize,
    /// 1 dark, 0 light.
    m: [max_size][max_size]u1 = undefined,
    /// True where a module is a function pattern (not data).
    func: [max_size][max_size]bool = undefined,
};

fn placeFinder(mat: *Matrix, r0: usize, c0: usize) void {
    var dr: i32 = -1;
    while (dr <= 7) : (dr += 1) {
        var dc: i32 = -1;
        while (dc <= 7) : (dc += 1) {
            const r = @as(i32, @intCast(r0)) + dr;
            const c = @as(i32, @intCast(c0)) + dc;
            if (r < 0 or c < 0 or r >= @as(i32, @intCast(mat.size)) or c >= @as(i32, @intCast(mat.size))) continue;
            const ur: usize = @intCast(r);
            const uc: usize = @intCast(c);
            mat.func[ur][uc] = true;
            const inner = dr >= 0 and dr <= 6 and dc >= 0 and dc <= 6;
            const ring = dr == 0 or dr == 6 or dc == 0 or dc == 6;
            const core = dr >= 2 and dr <= 4 and dc >= 2 and dc <= 4;
            mat.m[ur][uc] = if (inner and (ring or core)) 1 else 0;
        }
    }
}

fn placeFunctionPatterns(mat: *Matrix, version: usize) void {
    const size = mat.size;
    for (0..size) |r| for (0..size) |c| {
        mat.func[r][c] = false;
        mat.m[r][c] = 0;
    };
    placeFinder(mat, 0, 0);
    placeFinder(mat, 0, size - 7);
    placeFinder(mat, size - 7, 0);
    // Timing patterns.
    var i: usize = 8;
    while (i < size - 8) : (i += 1) {
        mat.func[6][i] = true;
        mat.m[6][i] = if (i % 2 == 0) 1 else 0;
        mat.func[i][6] = true;
        mat.m[i][6] = if (i % 2 == 0) 1 else 0;
    }
    // Dark module.
    mat.func[size - 8][8] = true;
    mat.m[size - 8][8] = 1;
    // Alignment pattern (single, for v2-4).
    if (vinfo(version).align_pos) |p| {
        var dr: i32 = -2;
        while (dr <= 2) : (dr += 1) {
            var dc: i32 = -2;
            while (dc <= 2) : (dc += 1) {
                const ur: usize = @intCast(@as(i32, @intCast(p)) + dr);
                const uc: usize = @intCast(@as(i32, @intCast(p)) + dc);
                mat.func[ur][uc] = true;
                const ring = dr == -2 or dr == 2 or dc == -2 or dc == 2;
                const center = dr == 0 and dc == 0;
                mat.m[ur][uc] = if (ring or center) 1 else 0;
            }
        }
    }
    // Reserve exactly the two format-info copies so data placement skips them
    // and nothing else - over-reserving would steal data modules and shift the
    // later codewords.
    for (0..15) |k| {
        const p1 = fmtPos1(k);
        mat.func[p1[0]][p1[1]] = true;
        const p2 = fmtPos2(k, size);
        mat.func[p2[0]][p2[1]] = true;
    }
}

// BCH(15,5) format info, XOR-masked per the spec, EC level L (bits 01).
fn formatBits(mask: u8) u15 {
    // 5 data bits: EC level L (01) then the 3 mask bits.
    const data: u15 = (@as(u15, 0b01) << 3) | @as(u15, mask & 0b111);
    // Remainder of (data << 10) divided by the BCH generator 0x537, reducing the
    // five bit positions above the degree-10 generator (bits 14 down to 10).
    var rem: u20 = @as(u20, data) << 10;
    var i: i32 = 4;
    while (i >= 0) : (i -= 1) {
        if (rem & (@as(u20, 1) << @intCast(i + 10)) != 0) rem ^= @as(u20, 0x537) << @intCast(i);
    }
    const v: u15 = (@as(u15, data) << 10) | @as(u15, @intCast(rem & 0x3ff));
    return v ^ 0x5412;
}

fn placeFormat(mat: *Matrix, mask: u8) void {
    const bits = formatBits(mask);
    const size = mat.size;
    // Bit 0 is LSB, placed per the spec's two copies.
    for (0..15) |k| {
        const bit: u1 = @intCast((bits >> @intCast(k)) & 1);
        // Copy 1 around the top-left finder.
        const p1 = fmtPos1(k);
        mat.m[p1[0]][p1[1]] = bit;
        // Copy 2 along the top-right and bottom-left.
        const p2 = fmtPos2(k, size);
        mat.m[p2[0]][p2[1]] = bit;
    }
}

fn fmtPos1(k: usize) [2]usize {
    // Around the top-left finder, k=0..14 low to high.
    const coords = [15][2]usize{
        .{ 8, 0 }, .{ 8, 1 }, .{ 8, 2 }, .{ 8, 3 }, .{ 8, 4 }, .{ 8, 5 }, .{ 8, 7 }, .{ 8, 8 },
        .{ 7, 8 }, .{ 5, 8 }, .{ 4, 8 }, .{ 3, 8 }, .{ 2, 8 }, .{ 1, 8 }, .{ 0, 8 },
    };
    return coords[k];
}

fn fmtPos2(k: usize, size: usize) [2]usize {
    if (k < 8) return .{ size - 1 - k, 8 };
    return .{ 8, size - 15 + k };
}

/// Walks the data-module positions in the standard right-to-left zigzag,
/// skipping the timing column and function modules, calling `visit` per module.
fn walkData(mat: *const Matrix, ctx: anytype, comptime visit: fn (@TypeOf(ctx), usize, usize) void) void {
    const size = mat.size;
    var col: i32 = @intCast(size - 1);
    var upward = true;
    while (col > 0) : (col -= 2) {
        if (col == 6) col -= 1; // skip timing column
        var row: i32 = if (upward) @intCast(size - 1) else 0;
        var count: usize = 0;
        while (count < size) : (count += 1) {
            var dc: i32 = 0;
            while (dc < 2) : (dc += 1) {
                const c: usize = @intCast(col - dc);
                const r: usize = @intCast(row);
                if (!mat.func[r][c]) visit(ctx, r, c);
            }
            row += if (upward) -1 else 1;
        }
        upward = !upward;
    }
}

const Placer = struct { mat: *Matrix, bits: []const u1, idx: *usize };
fn placeBit(p: Placer, r: usize, c: usize) void {
    const bit: u1 = if (p.idx.* < p.bits.len) p.bits[p.idx.*] else 0;
    p.mat.m[r][c] = bit;
    p.idx.* += 1;
}

const Reader = struct { mat: *const Matrix, bits: []u1, idx: *usize };
fn readBit(rd: Reader, r: usize, c: usize) void {
    if (rd.idx.* < rd.bits.len) rd.bits[rd.idx.*] = rd.mat.m[r][c];
    rd.idx.* += 1;
}

/// Encodes `payload` (byte mode) into a QR matrix at the smallest fitting version
/// (1-4), masked with `mask`. Returns error.TooLong past v4-L capacity.
pub fn encode(payload: []const u8, mask: u8, out: *Matrix) !void {
    gfInit();
    // Pick the smallest version whose data capacity holds the byte-mode segment
    // (4 mode bits + 8 count bits + 8*len + 4 terminator, rounded to codewords).
    var version: usize = 1;
    while (version <= max_version) : (version += 1) {
        const cap = vinfo(version).data;
        if (2 + payload.len + 1 <= cap) break;
    }
    if (version > max_version) return error.TooLong;
    const vi = vinfo(version);
    // Build the data bitstream.
    var bitbuf: [max_size * max_size]u1 = undefined;
    var nb: usize = 0;
    appendBits(&bitbuf, &nb, 0b0100, 4); // byte mode
    appendBits(&bitbuf, &nb, @intCast(payload.len), 8);
    for (payload) |ch| appendBits(&bitbuf, &nb, ch, 8);
    // Terminator + pad to a byte boundary.
    var term: usize = @min(4, vi.data * 8 - nb);
    while (term > 0) : (term -= 1) {
        bitbuf[nb] = 0;
        nb += 1;
    }
    while (nb % 8 != 0) : (nb += 1) bitbuf[nb] = 0;
    var data: [256]u8 = undefined;
    var nbytes: usize = nb / 8;
    for (0..nbytes) |i| {
        var v: u8 = 0;
        for (0..8) |k| v = (v << 1) | @as(u8, bitbuf[i * 8 + k]);
        data[i] = v;
    }
    // Pad codewords 0xEC, 0x11 to fill the data capacity.
    var pad: u8 = 0xEC;
    while (nbytes < vi.data) : (nbytes += 1) {
        data[nbytes] = pad;
        pad = if (pad == 0xEC) 0x11 else 0xEC;
    }
    // Reed-Solomon error correction.
    var ec: [32]u8 = undefined;
    rsEncode(data[0..vi.data], vi.ec, ec[0..vi.ec]);
    var code: [256]u8 = undefined;
    @memcpy(code[0..vi.data], data[0..vi.data]);
    @memcpy(code[vi.data .. vi.data + vi.ec], ec[0..vi.ec]);
    // Expand codewords to a bit list, MSB first.
    var codebits: [max_size * max_size]u1 = undefined;
    for (0..vi.total) |i| for (0..8) |k| {
        codebits[i * 8 + k] = @intCast((code[i] >> @intCast(7 - k)) & 1);
    };
    // Build the matrix.
    out.size = vi.size;
    placeFunctionPatterns(out, version);
    var idx: usize = 0;
    walkData(out, Placer{ .mat = out, .bits = codebits[0 .. vi.total * 8], .idx = &idx }, placeBit);
    // Apply the mask to data modules only.
    for (0..vi.size) |r| for (0..vi.size) |c| {
        if (!out.func[r][c] and maskBit(mask, r, c)) out.m[r][c] ^= 1;
    };
    placeFormat(out, mask);
}

fn appendBits(buf: []u1, n: *usize, value: u32, count: usize) void {
    var k: usize = count;
    while (k > 0) : (k -= 1) {
        buf[n.*] = @intCast((value >> @intCast(k - 1)) & 1);
        n.* += 1;
    }
}

/// Decodes a QR matrix (any of versions 1-4, level L, byte mode) into the payload
/// written to `out`, returning its length, or null on any structural failure.
pub fn decode(mat: *const Matrix, out: []u8) ?usize {
    gfInit();
    const version = (mat.size - 17) / 4;
    if (version < 1 or version > max_version) return null;
    const vi = vinfo(version);
    // Read the format info (first copy) and recover the mask.
    var fmt: u15 = 0;
    for (0..15) |k| {
        const p = fmtPos1(k);
        fmt |= @as(u15, mat.m[p[0]][p[1]]) << @intCast(k);
    }
    fmt ^= 0x5412;
    const mask: u8 = @intCast((fmt >> 10) & 0b111);
    // Unmask into a working copy, then read the data modules in zigzag.
    var work = mat.*;
    for (0..vi.size) |r| for (0..vi.size) |c| {
        if (!work.func[r][c] and maskBit(mask, r, c)) work.m[r][c] ^= 1;
    };
    var bits: [max_size * max_size]u1 = undefined;
    var idx: usize = 0;
    walkData(&work, Reader{ .mat = &work, .bits = bits[0 .. vi.total * 8], .idx = &idx }, readBit);
    var code: [256]u8 = undefined;
    for (0..vi.total) |i| {
        var v: u8 = 0;
        for (0..8) |k| v = (v << 1) | @as(u8, bits[i * 8 + k]);
        code[i] = v;
    }
    // Reed-Solomon correct, then read the byte-mode segment.
    if (!rsDecode(code[0..vi.total], vi.ec)) return null;
    var bit: usize = 0;
    const readN = struct {
        fn f(c: []const u8, at: *usize, n: usize) u32 {
            var v: u32 = 0;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const pos = at.* + k;
                v = (v << 1) | @as(u32, (c[pos / 8] >> @intCast(7 - (pos % 8))) & 1);
            }
            at.* += n;
            return v;
        }
    }.f;
    const mode = readN(code[0..vi.data], &bit, 4);
    if (mode != 0b0100) return null; // only byte mode
    const len = readN(code[0..vi.data], &bit, 8);
    if (len > out.len or len > vi.data) return null;
    for (0..len) |i| out[i] = @intCast(readN(code[0..vi.data], &bit, 8));
    return len;
}

/// Renders a matrix into an 8-bit luminance frame: `scale` pixels per module and
/// a `quiet` light border, 0 dark and 255 light. For tests and the proof.
pub fn render(mat: *const Matrix, scale: usize, quiet: usize, frame: []u8, width: usize) void {
    @memset(frame, 255);
    for (0..mat.size) |r| for (0..mat.size) |c| {
        if (mat.m[r][c] == 1) {
            for (0..scale) |dy| for (0..scale) |dx| {
                const y = quiet + r * scale + dy;
                const x = quiet + c * scale + dx;
                frame[y * width + x] = 0;
            };
        }
    };
}

/// Locates an axis-aligned QR in a luminance frame by its three finder patterns
/// and samples the module grid into `out`, then decodes it. Null when no QR is
/// found or it does not decode. `lum` is width*height 8-bit luminance.
pub fn scan(lum: []const u8, width: usize, height: usize, out: []u8) ?usize {
    // Threshold at the global mean.
    var sum: u64 = 0;
    for (lum[0 .. width * height]) |p| sum += p;
    const thresh: u8 = @intCast(sum / (width * height));
    // Find the dark bounding box (the symbol plus its border trimmed to modules).
    var min_x: usize = width;
    var min_y: usize = height;
    var max_x: usize = 0;
    var max_y: usize = 0;
    var any = false;
    for (0..height) |y| for (0..width) |x| {
        if (lum[y * width + x] < thresh) {
            any = true;
            if (x < min_x) min_x = x;
            if (y < min_y) min_y = y;
            if (x > max_x) max_x = x;
            if (y > max_y) max_y = y;
        }
    };
    if (!any) return null;
    const span_x = max_x - min_x + 1;
    const span_y = max_y - min_y + 1;
    // Estimate the module count from the top-left finder's run: the first dark
    // run on the top edge row is 7 modules wide.
    const finder_run = darkRun(lum, width, min_x, min_y, thresh);
    if (finder_run == 0) return null;
    const module_px = finder_run / 7;
    if (module_px == 0) return null;
    const est = (span_x + module_px / 2) / module_px;
    // Snap to a supported version size.
    var size: usize = 0;
    for (1..max_version + 1) |v| {
        if (@as(i64, @intCast(vinfo(v).size)) - @as(i64, @intCast(est)) <= 2 and @as(i64, @intCast(vinfo(v).size)) - @as(i64, @intCast(est)) >= -2) size = vinfo(v).size;
    }
    if (size == 0) return null;
    var mat = Matrix{ .size = size };
    placeFunctionPatterns(&mat, (size - 17) / 4);
    for (0..size) |r| for (0..size) |c| {
        const cy = min_y + (span_y * (2 * r + 1)) / (2 * size);
        const cx = min_x + (span_x * (2 * c + 1)) / (2 * size);
        mat.m[r][c] = if (lum[cy * width + cx] < thresh) 1 else 0;
    };
    return decode(&mat, out);
}

fn darkRun(lum: []const u8, width: usize, x0: usize, y0: usize, thresh: u8) usize {
    var run: usize = 0;
    var x = x0;
    while (x < width and lum[y0 * width + x] < thresh) : (x += 1) run += 1;
    return run;
}

const t = std.testing;

test "encode then decode round-trips a byte payload across masks and versions" {
    const cases = [_][]const u8{ "GOSS", "https://goss.rocks/x", "unlock:studio-42-neon-lens-code-abcdef" };
    for (cases) |payload| {
        for (0..8) |mask| {
            var mat: Matrix = undefined;
            try encode(payload, @intCast(mask), &mat);
            var out: [128]u8 = undefined;
            const len = decode(&mat, &out) orelse return error.DecodeFailed;
            try t.expectEqualSlices(u8, payload, out[0..len]);
        }
    }
}

test "reed-solomon corrects a handful of byte errors" {
    var mat: Matrix = undefined;
    try encode("recover me", 3, &mat);
    // Flip a few data modules; RS at level L corrects up to ec/2 codewords.
    mat.m[10][10] ^= 1;
    mat.m[12][14] ^= 1;
    mat.m[9][15] ^= 1;
    var out: [64]u8 = undefined;
    const len = decode(&mat, &out) orelse return error.DecodeFailed;
    try t.expectEqualSlices(u8, "recover me", out[0..len]);
}

test "scan locates and decodes a rendered QR from a luminance frame" {
    var mat: Matrix = undefined;
    try encode("scan-me", 2, &mat);
    const scale = 6;
    const quiet = 4 * scale;
    const width = quiet * 2 + mat.size * scale;
    const height = width;
    const frame = try t.allocator.alloc(u8, width * height);
    defer t.allocator.free(frame);
    render(&mat, scale, quiet, frame, width);
    var out: [64]u8 = undefined;
    const len = scan(frame, width, height, &out) orelse return error.ScanFailed;
    try t.expectEqualSlices(u8, "scan-me", out[0..len]);
}
