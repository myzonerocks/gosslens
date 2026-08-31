//! On-device EAN-13 / UPC-A barcode decoding: a camera scanline is binarized and
//! its bar/space runs are read against the EAN symbol tables to recover the 13
//! digits and pass the EAN checksum. Algorithmic, deterministic, no model, so a
//! lens reads a product code with nothing gated in. The encoder is here for tests.
const std = @import("std");

/// The 95 modules of an EAN-13 symbol: start(3) + 6 left digits(7) + center(5)
/// + 6 right digits(7) + end(3).
pub const symbol_modules = 95;

// Left digits in odd parity (L) and even parity (G); right digits (R). Each is a
// 7-module pattern, 1 a bar (dark), 0 a space (light).
const l_code = [10]u7{ 0b0001101, 0b0011001, 0b0010011, 0b0111101, 0b0100011, 0b0110001, 0b0101111, 0b0111011, 0b0110111, 0b0001011 };
const g_code = [10]u7{ 0b0100111, 0b0110011, 0b0011011, 0b0100001, 0b0011101, 0b0111001, 0b0000101, 0b0010001, 0b0001001, 0b0010111 };
const r_code = [10]u7{ 0b1110010, 0b1100110, 0b1101100, 0b1000010, 0b1011100, 0b1001110, 0b1010000, 0b1000100, 0b1001000, 0b1110100 };

// The parity of the six left digits encodes the first digit: L is 0, G is 1.
const parity_pattern = [10]u6{ 0b000000, 0b001011, 0b001101, 0b001110, 0b010011, 0b011001, 0b011100, 0b010101, 0b010110, 0b011010 };

fn setBits(out: []u8, at: usize, pattern: u7) void {
    var i: usize = 0;
    while (i < 7) : (i += 1) out[at + i] = @intCast((pattern >> @intCast(6 - i)) & 1);
}

/// Encodes 13 digits (0..9 each) into the 95-module symbol. Used by tests and the
/// conformance proof to round-trip a known code; the first digit rides the parity.
pub fn encode(digits: [13]u8, out: *[symbol_modules]u8) void {
    @memset(out, 0);
    // Start guard 101.
    out[0] = 1;
    out[2] = 1;
    const parity = parity_pattern[digits[0] % 10];
    var at: usize = 3;
    var k: usize = 0;
    while (k < 6) : (k += 1) {
        const d = digits[1 + k] % 10;
        const use_g = (parity >> @intCast(5 - k)) & 1 == 1;
        setBits(out, at, if (use_g) g_code[d] else l_code[d]);
        at += 7;
    }
    // Center guard 01010.
    out[at + 1] = 1;
    out[at + 3] = 1;
    at += 5;
    k = 0;
    while (k < 6) : (k += 1) {
        setBits(out, at, r_code[digits[7 + k] % 10]);
        at += 7;
    }
    // End guard 101.
    out[at] = 1;
    out[at + 2] = 1;
}

fn read7(bits: []const u8, at: usize) u7 {
    var v: u7 = 0;
    var i: usize = 0;
    while (i < 7) : (i += 1) v = (v << 1) | @as(u7, @intCast(bits[at + i] & 1));
    return v;
}

/// True when the 13 digits satisfy the EAN-13 checksum (the last digit).
pub fn checksumOk(digits: [13]u8) bool {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < 12) : (i += 1) sum += @as(u32, digits[i]) * (if (i % 2 == 0) @as(u32, 1) else 3);
    const check = (10 - (sum % 10)) % 10;
    return check == digits[12];
}

/// Decodes a 95-module symbol into 13 digits, or null when a digit fails to match
/// a symbol, the parity is not a valid first digit, or the checksum fails.
pub fn decodeSymbol(bits: []const u8) ?[13]u8 {
    if (bits.len < symbol_modules) return null;
    var digits: [13]u8 = @splat(0);
    var parity: u6 = 0;
    var at: usize = 3;
    var k: usize = 0;
    while (k < 6) : (k += 1) {
        const pat = read7(bits, at);
        const dl = matchIn(&l_code, pat);
        const dg = matchIn(&g_code, pat);
        if (dl) |d| {
            digits[1 + k] = d;
        } else if (dg) |d| {
            digits[1 + k] = d;
            parity |= @as(u6, 1) << @intCast(5 - k);
        } else return null;
        at += 7;
    }
    var first: ?u8 = null;
    for (parity_pattern, 0..) |p, d| {
        if (p == parity) first = @intCast(d);
    }
    digits[0] = first orelse return null;
    at += 5; // center guard
    k = 0;
    while (k < 6) : (k += 1) {
        const d = matchIn(&r_code, read7(bits, at)) orelse return null;
        digits[7 + k] = d;
        at += 7;
    }
    if (!checksumOk(digits)) return null;
    return digits;
}

fn matchIn(table: *const [10]u7, pat: u7) ?u8 {
    for (table, 0..) |code, d| {
        if (code == pat) return @intCast(d);
    }
    return null;
}

/// Scans one luminance row for a barcode: thresholds against the row mean, walks
/// the bar/space runs to estimate a module width, resamples the run band into the
/// 95-module symbol, and decodes it (trying both scan directions). Null when the
/// row carries no readable symbol. `lum` is width*height 8-bit luminance.
pub fn scanRow(lum: []const u8, width: usize, height: usize, row: usize) ?[13]u8 {
    if (row >= height or width < symbol_modules) return null;
    const line = lum[row * width ..][0..width];
    // Threshold at the row mean, a robust global cut for a lit barcode.
    var sum: u64 = 0;
    for (line) |p| sum += p;
    const thresh: u8 = @intCast(sum / width);
    var bits = std.mem.zeroes([2048]u8);
    const n = @min(width, bits.len);
    var dark_span: usize = 0;
    for (0..n) |x| {
        const dark: u8 = if (line[x] < thresh) 1 else 0;
        bits[x] = dark;
        dark_span += dark;
    }
    // A barcode row is neither all-light nor all-dark; skip a blank row fast.
    if (dark_span == 0 or dark_span == n) return null;
    return decodeBand(bits[0..n]);
}

/// Finds the symbol inside a binarized line by its run structure and samples it.
/// Tries the line as-is and reversed, so orientation does not matter.
fn decodeBand(bits: []const u8) ?[13]u8 {
    if (sampleAndDecode(bits, false)) |d| return d;
    return sampleAndDecode(bits, true);
}

fn sampleAndDecode(bits: []const u8, reversed: bool) ?[13]u8 {
    // Trim the quiet zone: the first dark module starts the symbol, the last ends
    // it. The span between is 95 modules wide for a full symbol.
    var lo: usize = 0;
    var hi: usize = bits.len;
    while (lo < bits.len and get(bits, lo, reversed) == 0) lo += 1;
    while (hi > lo and get(bits, hi - 1, reversed) == 0) hi -= 1;
    const span = hi - lo;
    if (span < symbol_modules) return null;
    // Resample the span into 95 modules at each module's center.
    var sym: [symbol_modules]u8 = undefined;
    var m: usize = 0;
    while (m < symbol_modules) : (m += 1) {
        const center = lo + (span * (2 * m + 1)) / (2 * symbol_modules);
        sym[m] = get(bits, center, reversed);
    }
    return decodeSymbol(&sym);
}

fn get(bits: []const u8, i: usize, reversed: bool) u8 {
    return if (reversed) bits[bits.len - 1 - i] else bits[i];
}

const t = std.testing;

test "encode then decode round-trips a valid EAN-13" {
    // 4006381333931 is a standard EAN-13 with a correct check digit.
    const digits = [13]u8{ 4, 0, 0, 6, 3, 8, 1, 3, 3, 3, 9, 3, 1 };
    try t.expect(checksumOk(digits));
    var sym: [symbol_modules]u8 = undefined;
    encode(digits, &sym);
    const decoded = decodeSymbol(&sym) orelse return error.DecodeFailed;
    try t.expectEqualSlices(u8, &digits, &decoded);
}

test "a corrupted symbol fails to decode" {
    const digits = [13]u8{ 4, 0, 0, 6, 3, 8, 1, 3, 3, 3, 9, 3, 1 };
    var sym: [symbol_modules]u8 = undefined;
    encode(digits, &sym);
    sym[10] ^= 1; // flip a module inside the first left digit
    sym[11] ^= 1;
    try t.expect(decodeSymbol(&sym) == null);
}

test "scanRow reads the symbol from a rendered luminance row" {
    const digits = [13]u8{ 4, 0, 0, 6, 3, 8, 1, 3, 3, 3, 9, 3, 1 };
    var sym: [symbol_modules]u8 = undefined;
    encode(digits, &sym);
    // Render at 4 pixels per module with an 8-pixel light quiet zone each side.
    const scale = 4;
    const quiet = 8;
    const width = quiet * 2 + symbol_modules * scale;
    var lum = try t.allocator.alloc(u8, width);
    defer t.allocator.free(lum);
    @memset(lum, 255);
    for (0..symbol_modules) |mm| {
        if (sym[mm] == 1) {
            const start = quiet + mm * scale;
            for (start..start + scale) |x| lum[x] = 0;
        }
    }
    const decoded = scanRow(lum, width, 1, 0) orelse return error.ScanFailed;
    try t.expectEqualSlices(u8, &digits, &decoded);
}

test "the checksum rejects a bad last digit" {
    var digits = [13]u8{ 4, 0, 0, 6, 3, 8, 1, 3, 3, 3, 9, 3, 1 };
    try t.expect(checksumOk(digits));
    digits[12] = 2;
    try t.expect(!checksumOk(digits));
}
