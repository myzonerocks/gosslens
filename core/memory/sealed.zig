//! Sealing what the engine remembers. The index and the log are the most
//! sensitive things on the device: an index of embeddings is a record of what a
//! camera saw, and a log is a record of when. Both go to disk sealed under a key
//! the host holds, so a file lifted off the device is bytes rather than a diary.

const std = @import("std");
const library = @import("library");

pub const Error = error{ OutOfMemory, Corrupt, AuthenticationFailed };

pub const key_length = library.key_length;
pub const nonce_length = library.nonce_length;
pub const tag_length = library.tag_length;

/// What kind of thing is inside, bound into the authenticated data so a sealed
/// index cannot be opened as a sealed log and read as one.
pub const Content = enum(u8) {
    index = 1,
    event_log = 2,
};

/// The header of a sealed file, in the clear because a reader needs it before it
/// can open anything. It is authenticated, so changing any of it fails the open
/// rather than silently reinterpreting the bytes.
pub const Header = extern struct {
    magic: [8]u8,
    version: u32,
    content: u32,
    nonce: [nonce_length]u8,
    plaintext_len: u64,
};

pub const magic = "GOSSEAL1";
pub const version: u32 = 1;

/// What a sealed blob costs: the header, the plaintext, and the tag.
pub fn sealedSize(plaintext_len: usize) usize {
    return @sizeOf(Header) + plaintext_len + tag_length;
}

/// Seals plaintext into out. The nonce is the caller's, because a nonce reused
/// under one key breaks the cipher, and only the caller knows what it has
/// already written.
pub fn seal(
    key: [key_length]u8,
    nonce: [nonce_length]u8,
    content: Content,
    plaintext: []const u8,
    out: []u8,
) Error!usize {
    const needed = sealedSize(plaintext.len);
    if (out.len < needed) return error.OutOfMemory;
    var header: Header = .{
        .magic = magic.*,
        .version = version,
        .content = @intFromEnum(content),
        .nonce = nonce,
        .plaintext_len = plaintext.len,
    };
    @memcpy(out[0..@sizeOf(Header)], std.mem.asBytes(&header));
    // The header is the authenticated data, so its kind, its version and its
    // declared length are all covered: a file relabelled is a file that fails.
    library.seal(key, nonce, plaintext, out[0..@sizeOf(Header)], out[@sizeOf(Header)..]);
    return needed;
}

/// Opens a sealed blob. A wrong key, a changed byte, a relabelled kind or a
/// truncated write all fail here rather than producing plausible plaintext.
pub fn open(key: [key_length]u8, expect: Content, sealed: []const u8, out: []u8) Error!usize {
    if (sealed.len < @sizeOf(Header) + tag_length) return error.Corrupt;
    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), sealed[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &header.magic, magic)) return error.Corrupt;
    if (header.version != version) return error.Corrupt;
    if (header.content != @intFromEnum(expect)) return error.Corrupt;
    const body = sealed[@sizeOf(Header)..];
    if (body.len < tag_length) return error.Corrupt;
    const plaintext_len = body.len - tag_length;
    if (plaintext_len != header.plaintext_len) return error.Corrupt;
    if (out.len < plaintext_len) return error.OutOfMemory;
    _ = library.open(key, header.nonce, body, sealed[0..@sizeOf(Header)], out) catch return error.AuthenticationFailed;
    return plaintext_len;
}

const testing = std.testing;

test "a sealed memory opens under its key and under nothing else" {
    const key: [key_length]u8 = @splat(7);
    const nonce: [nonce_length]u8 = @splat(3);
    const plaintext = "an index of what the camera saw";

    const buffer = try testing.allocator.alloc(u8, sealedSize(plaintext.len));
    defer testing.allocator.free(buffer);
    const n = try seal(key, nonce, .index, plaintext, buffer);
    try testing.expectEqual(buffer.len, n);
    // The plaintext must not be in the file, which is the whole point.
    try testing.expect(std.mem.indexOf(u8, buffer, "camera") == null);

    const out = try testing.allocator.alloc(u8, plaintext.len);
    defer testing.allocator.free(out);
    try testing.expectEqual(plaintext.len, try open(key, .index, buffer, out));
    try testing.expectEqualStrings(plaintext, out);

    var wrong: [key_length]u8 = @splat(7);
    wrong[0] = 8;
    try testing.expectError(error.AuthenticationFailed, open(wrong, .index, buffer, out));
}

test "a relabelled, tampered or truncated file fails rather than reading as something" {
    const key: [key_length]u8 = @splat(9);
    const nonce: [nonce_length]u8 = @splat(1);
    const plaintext = "when it saw it";
    const buffer = try testing.allocator.alloc(u8, sealedSize(plaintext.len));
    defer testing.allocator.free(buffer);
    _ = try seal(key, nonce, .event_log, plaintext, buffer);
    const out = try testing.allocator.alloc(u8, plaintext.len);
    defer testing.allocator.free(out);

    // Opened as the wrong kind: refused before the cipher is even asked.
    try testing.expectError(error.Corrupt, open(key, .index, buffer, out));

    // One byte of ciphertext changed.
    const tampered = try testing.allocator.dupe(u8, buffer);
    defer testing.allocator.free(tampered);
    tampered[@sizeOf(Header) + 2] ^= 0xFF;
    try testing.expectError(error.AuthenticationFailed, open(key, .event_log, tampered, out));

    // The header is authenticated too, so relabelling it in place fails the tag
    // rather than quietly changing what the file claims to be.
    const relabelled = try testing.allocator.dupe(u8, buffer);
    defer testing.allocator.free(relabelled);
    relabelled[12] = @intFromEnum(Content.index);
    try testing.expect(open(key, .index, relabelled, out) == error.AuthenticationFailed or
        open(key, .index, relabelled, out) == error.Corrupt);

    try testing.expectError(error.Corrupt, open(key, .event_log, buffer[0..8], out));
}
