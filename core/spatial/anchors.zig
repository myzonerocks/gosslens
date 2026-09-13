//! Anchors that survive. A point agreed in a room is worth nothing forgotten,
//! and worth nothing to a second device if neither can name it, so an anchor
//! carries a purpose and a label in a versioned file.

const std = @import("std");
const math = @import("math");

pub const Error = error{ OutOfMemory, Corrupt, Full, NotFound };

/// What an anchor is for. A label is the difference between "a point" and "the
/// left edge of the whiteboard", and it is what lets a second device agree.
pub const Purpose = enum(u8) {
    unknown = 0,
    /// Placed by a host or an agent, to hang something on.
    placement = 1,
    /// A recognised feature of the room, so two devices can match on it.
    landmark = 2,
    /// A point a person marked, which outlives the session that made it.
    marked = 3,
};

pub const Anchor = struct {
    id: u64,
    /// Column-major, the same convention every platform's anchor pose uses.
    pose: [16]f32,
    purpose: Purpose = .unknown,
    /// How sure the platform was when it last saw this, zero to one. An anchor
    /// restored from a file starts at zero until something relocalizes it, so a
    /// caller cannot mistake a remembered pose for a tracked one.
    confidence: f32 = 0,
    /// Borrowed at read time, owned by the store's arena once added.
    label: []const u8 = &.{},
    created_us: i64 = 0,
    last_seen_us: i64 = 0,
};

/// A bounded store with its labels copied, so an anchor outlives the frame that
/// made it and the map file that held it.
pub fn Store(comptime max_anchors: usize, comptime label_bytes: usize) type {
    return struct {
        const Self = @This();

        anchors: [max_anchors]Anchor = undefined,
        count: usize = 0,
        arena: [label_bytes]u8 = undefined,
        used: usize = 0,
        refused: u64 = 0,

        pub fn clear(s: *Self) void {
            s.count = 0;
            s.used = 0;
        }

        pub fn items(s: *const Self) []const Anchor {
            return s.anchors[0..s.count];
        }

        pub fn find(s: *const Self, id: u64) ?usize {
            for (s.anchors[0..s.count], 0..) |a, i| {
                if (a.id == id) return i;
            }
            return null;
        }

        /// Adds or replaces by id. The same id replaces rather than duplicating,
        /// so an anchor refined by a better observation does not leave the worse
        /// one beside it to be matched instead.
        pub fn put(s: *Self, anchor: Anchor) bool {
            if (s.find(anchor.id)) |at| {
                const kept = s.anchors[at].label;
                s.anchors[at] = anchor;
                s.anchors[at].label = kept;
                if (anchor.label.len != 0) {
                    if (s.used + anchor.label.len > label_bytes) {
                        s.refused += 1;
                        return false;
                    }
                    const start = s.used;
                    @memcpy(s.arena[start..][0..anchor.label.len], anchor.label);
                    s.used += anchor.label.len;
                    s.anchors[at].label = s.arena[start..][0..anchor.label.len];
                }
                return true;
            }
            if (s.count >= max_anchors or s.used + anchor.label.len > label_bytes) {
                s.refused += 1;
                return false;
            }
            s.anchors[s.count] = anchor;
            if (anchor.label.len != 0) {
                const start = s.used;
                @memcpy(s.arena[start..][0..anchor.label.len], anchor.label);
                s.used += anchor.label.len;
                s.anchors[s.count].label = s.arena[start..][0..anchor.label.len];
            }
            s.count += 1;
            return true;
        }

        pub fn remove(s: *Self, id: u64) bool {
            const at = s.find(id) orelse return false;
            // The labels stay where they are: compacting them would move every
            // surviving slice, and an anchor store is small enough that the
            // bytes a removal leaves behind are reclaimed on the next clear.
            for (at..s.count - 1) |i| s.anchors[i] = s.anchors[i + 1];
            s.count -= 1;
            return true;
        }

        /// What a saved map costs, so a caller sizes its buffer once.
        pub fn savedSize(s: *const Self) usize {
            var total: usize = @sizeOf(Header);
            for (s.items()) |a| total += @sizeOf(Entry) + a.label.len;
            return total;
        }

        /// Writes the map. A short buffer reports the size it needed rather than
        /// a truncated file that would load as a different room.
        pub fn save(s: *const Self, out: []u8) usize {
            const needed = s.savedSize();
            if (out.len < needed) return needed;
            var header: Header = .{ .magic = magic.*, .version = version, .count = @intCast(s.count) };
            @memcpy(out[0..@sizeOf(Header)], std.mem.asBytes(&header));
            var at: usize = @sizeOf(Header);
            for (s.items()) |a| {
                var entry: Entry = .{
                    .id = a.id,
                    .pose = a.pose,
                    .purpose = @intFromEnum(a.purpose),
                    .label_len = @intCast(a.label.len),
                    .created_us = a.created_us,
                    .last_seen_us = a.last_seen_us,
                };
                @memcpy(out[at..][0..@sizeOf(Entry)], std.mem.asBytes(&entry));
                at += @sizeOf(Entry);
                @memcpy(out[at..][0..a.label.len], a.label);
                at += a.label.len;
            }
            return needed;
        }

        /// Reads a map back. Confidence is deliberately not restored: a
        /// remembered pose is not a tracked one until something relocalizes it,
        /// and a caller that cannot tell the difference will draw in the wrong
        /// place with total assurance.
        pub fn load(s: *Self, bytes: []const u8) Error!void {
            if (bytes.len < @sizeOf(Header)) return error.Corrupt;
            var header: Header = undefined;
            @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(Header)]);
            if (!std.mem.eql(u8, &header.magic, magic)) return error.Corrupt;
            if (header.version != version) return error.Corrupt;
            if (header.count > max_anchors) return error.Full;

            s.clear();
            var at: usize = @sizeOf(Header);
            for (0..header.count) |_| {
                if (at + @sizeOf(Entry) > bytes.len) return error.Corrupt;
                var entry: Entry = undefined;
                @memcpy(std.mem.asBytes(&entry), bytes[at..][0..@sizeOf(Entry)]);
                at += @sizeOf(Entry);
                if (at + entry.label_len > bytes.len) return error.Corrupt;
                const label = bytes[at..][0..entry.label_len];
                at += entry.label_len;
                const purpose: Purpose = switch (entry.purpose) {
                    0 => .unknown,
                    1 => .placement,
                    2 => .landmark,
                    3 => .marked,
                    else => return error.Corrupt,
                };
                if (!s.put(.{
                    .id = entry.id,
                    .pose = entry.pose,
                    .purpose = purpose,
                    .confidence = 0,
                    .label = label,
                    .created_us = entry.created_us,
                    .last_seen_us = entry.last_seen_us,
                })) return error.Full;
            }
        }

        /// Marks an anchor seen again, which is the only thing that raises its
        /// confidence above what a file restored.
        pub fn relocalize(s: *Self, id: u64, pose: [16]f32, confidence: f32, now_us: i64) bool {
            const at = s.find(id) orelse return false;
            s.anchors[at].pose = pose;
            s.anchors[at].confidence = @max(0, @min(1, confidence));
            s.anchors[at].last_seen_us = now_us;
            return true;
        }

        /// How much of the saved map has been found again, which is what tells a
        /// caller whether it is in the same room or only thinks it is.
        pub fn relocalizedFraction(s: *const Self) f32 {
            if (s.count == 0) return 0;
            var seen: usize = 0;
            for (s.items()) |a| {
                if (a.confidence > 0) seen += 1;
            }
            return @as(f32, @floatFromInt(seen)) / @as(f32, @floatFromInt(s.count));
        }
    };
}

pub const magic = "GOSSANCH";
pub const version: u32 = 1;

const Header = extern struct {
    magic: [8]u8,
    version: u32,
    count: u32,
};

const Entry = extern struct {
    id: u64,
    pose: [16]f32,
    purpose: u8,
    label_len: u16,
    created_us: i64,
    last_seen_us: i64,
};

const testing = std.testing;

test "an anchor survives a save and comes back untracked" {
    var store: Store(8, 256) = .{};
    var pose: [16]f32 = @splat(0);
    pose[0] = 1;
    pose[5] = 1;
    pose[10] = 1;
    pose[15] = 1;
    pose[12] = 1.5;

    try testing.expect(store.put(.{ .id = 1, .pose = pose, .purpose = .marked, .confidence = 0.9, .label = "whiteboard left", .created_us = 100 }));
    try testing.expect(store.put(.{ .id = 2, .pose = pose, .purpose = .placement, .confidence = 0.5, .created_us = 200 }));
    try testing.expectApproxEqAbs(@as(f32, 1), store.relocalizedFraction(), 1e-6);

    const needed = store.save(&.{});
    const buffer = try testing.allocator.alloc(u8, needed);
    defer testing.allocator.free(buffer);
    try testing.expectEqual(needed, store.save(buffer));

    var restored: Store(8, 256) = .{};
    try restored.load(buffer);
    try testing.expectEqual(@as(usize, 2), restored.count);
    try testing.expectEqualStrings("whiteboard left", restored.items()[0].label);
    try testing.expectApproxEqAbs(@as(f32, 1.5), restored.items()[0].pose[12], 1e-6);
    // A remembered pose is not a tracked one, and nothing restored says it is.
    try testing.expectApproxEqAbs(@as(f32, 0), restored.items()[0].confidence, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), restored.relocalizedFraction(), 1e-6);

    // Seeing one again is what raises it, and says how much of the room is back.
    try testing.expect(restored.relocalize(1, pose, 0.8, 999));
    try testing.expectApproxEqAbs(@as(f32, 0.5), restored.relocalizedFraction(), 1e-6);
    try testing.expect(!restored.relocalize(77, pose, 1, 999));
}

test "the same id refines rather than duplicating, and a bad file is refused" {
    var store: Store(4, 64) = .{};
    const pose: [16]f32 = @splat(0);
    try testing.expect(store.put(.{ .id = 7, .pose = pose, .label = "door" }));
    try testing.expect(store.put(.{ .id = 7, .pose = pose, .confidence = 0.4 }));
    try testing.expectEqual(@as(usize, 1), store.count);
    // Replacing without a label keeps the one it had, so an anchor does not lose
    // its name to a refinement that did not carry one.
    try testing.expectEqualStrings("door", store.items()[0].label);

    try testing.expect(store.remove(7));
    try testing.expectEqual(@as(usize, 0), store.count);
    try testing.expect(!store.remove(7));

    var broken: Store(4, 64) = .{};
    try testing.expectError(error.Corrupt, broken.load(&[_]u8{ 1, 2, 3 }));
    var header = [_]u8{0} ** 16;
    @memcpy(header[0..8], magic);
    header[8] = 9;
    try testing.expectError(error.Corrupt, broken.load(&header));
}

test "the store refuses past its bounds and counts what it turned away" {
    var store: Store(2, 8) = .{};
    const pose: [16]f32 = @splat(0);
    try testing.expect(store.put(.{ .id = 1, .pose = pose, .label = "abcd" }));
    try testing.expect(store.put(.{ .id = 2, .pose = pose, .label = "efgh" }));
    // Out of slots and out of label room, both counted.
    try testing.expect(!store.put(.{ .id = 3, .pose = pose }));
    try testing.expect(!store.put(.{ .id = 4, .pose = pose, .label = "ijkl" }));
    try testing.expectEqual(@as(u64, 2), store.refused);
    try testing.expectEqual(@as(usize, 2), store.count);
}

/// Two devices agreeing on a point. Neither can send a pose and be understood:
/// each has its own origin, wherever tracking started. What crosses is landmarks
/// and the distances between them, and a device recognising enough of those
/// solves for the transform between the two origins.
pub const shared = struct {
    /// One landmark as it crosses between devices. No pose, because a pose is
    /// meaningless in another origin; the id and the label are what both sides
    /// recognise, and the position is in the sender's own frame, used only for the
    /// distances between landmarks.
    pub const Landmark = extern struct {
        id: u64,
        x: f32,
        y: f32,
        z: f32,
        /// How sure the sender was, so a receiver weights a confident landmark
        /// over a guess rather than treating them alike.
        confidence: f32,
    };

    /// The transform from the sender's origin to the receiver's, and how well it
    /// fit. A transform nobody measured the fit of is a transform nobody should
    /// draw through.
    pub const Alignment = struct {
        /// Column-major, the same convention the anchor poses use.
        transform: [16]f32,
        /// Root mean square of the residual distances, in metres. Zero landmarks
        /// matched means no alignment rather than the identity.
        rms_error: f32,
        matched: usize,

        pub const none: Alignment = .{ .transform = identity, .rms_error = 0, .matched = 0 };

        /// Whether this is worth drawing through. Three matches is the minimum that
        /// fixes a rigid transform in three dimensions, and a fit worse than the
        /// tolerance is a disagreement rather than an agreement.
        pub fn usable(a: Alignment, tolerance: f32) bool {
            return a.matched >= 3 and a.rms_error <= tolerance;
        }
    };

    const identity: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

    /// The most landmarks one alignment reads. They arrive from another device, so
    /// the count is bounded here rather than trusted.
    const max_shared_landmarks = 64;

    /// Solves for the rigid transform taking the sender's landmarks onto the
    /// receiver's, over the ids both sides recognise. Translation from the
    /// centroids and rotation from the cross-covariance, which is the closed-form
    /// answer for matched point sets and needs no iteration.
    pub fn align_(mine: []const Landmark, theirs: []const Landmark) Alignment {
        var matched: usize = 0;
        var my_centre: [3]f32 = .{ 0, 0, 0 };
        var their_centre: [3]f32 = .{ 0, 0, 0 };
        for (mine) |a| {
            for (theirs) |b| {
                if (a.id != b.id) continue;
                my_centre[0] += a.x;
                my_centre[1] += a.y;
                my_centre[2] += a.z;
                their_centre[0] += b.x;
                their_centre[1] += b.y;
                their_centre[2] += b.z;
                matched += 1;
                break;
            }
        }
        if (matched < 3) return .none;
        const n: f32 = @floatFromInt(matched);
        for (0..3) |i| {
            my_centre[i] /= n;
            their_centre[i] /= n;
        }

        // The shared fit: Horn's method over the weighted clouds, which the engine
        // already had. Confidence is the weight, so a landmark one side was sure of
        // pulls harder than a guess.
        var pairs: [max_shared_landmarks]math.fit.WeightedPoint = undefined;
        var pair_count: usize = 0;
        for (mine) |a| {
            for (theirs) |b| {
                if (a.id != b.id) continue;
                if (pair_count >= pairs.len) break;
                pairs[pair_count] = .{
                    .source = .{ a.x, a.y, a.z },
                    .target = .{ b.x, b.y, b.z },
                    .weight = @max(0, @min(a.confidence, b.confidence)),
                };
                pair_count += 1;
                break;
            }
        }
        const fitted = math.fit.fitSimilarity(pairs[0..pair_count]) orelse return .none;

        // Two devices measuring the same room in metres agree on scale, so the fit's
        // scale is divided out rather than carried: a rigid transform is the physical
        // answer, and a scale fitted from noise would stretch the other origin.
        var transform: [16]f32 = undefined;
        for (0..4) |c| {
            // Copied to an array first: a vector cannot be indexed by a value the
            // compiler does not know.
            const column: [4]f32 = fitted.cols[c];
            for (0..4) |r| transform[c * 4 + r] = column[r];
        }
        var scale: f32 = 0;
        for (0..3) |c| {
            const col = [3]f32{ transform[c * 4], transform[c * 4 + 1], transform[c * 4 + 2] };
            scale += @sqrt(col[0] * col[0] + col[1] * col[1] + col[2] * col[2]);
        }
        scale /= 3;
        if (scale > 1e-6) {
            for (0..3) |c| {
                for (0..3) |r| transform[c * 4 + r] /= scale;
            }
            // The translation follows the unscaled rotation, so it is rebuilt rather
            // than divided: dividing it would move the origin by the scale error.
            const turned = rotate(transform, my_centre);
            transform[12] = their_centre[0] - turned[0];
            transform[13] = their_centre[1] - turned[1];
            transform[14] = their_centre[2] - turned[2];
        }

        var squared: f32 = 0;
        for (mine) |a| {
            for (theirs) |b| {
                if (a.id != b.id) continue;
                const moved = rotate(transform, .{ a.x, a.y, a.z });
                const dx = moved[0] + transform[12] - b.x;
                const dy = moved[1] + transform[13] - b.y;
                const dz = moved[2] + transform[14] - b.z;
                squared += dx * dx + dy * dy + dz * dz;
                break;
            }
        }
        return .{
            .transform = transform,
            .rms_error = @sqrt(squared / n),
            .matched = matched,
        };
    }

    /// Moves a pose from the sender's origin into the receiver's, which is the
    /// only thing an alignment is for. The whole transform, so a pose arrives
    /// turned as well as moved.
    pub fn apply(a: Alignment, pose: [16]f32) [16]f32 {
        var out: [16]f32 = @splat(0);
        for (0..4) |c| {
            for (0..4) |r| {
                var sum: f32 = 0;
                for (0..4) |k| sum += a.transform[k * 4 + r] * pose[c * 4 + k];
                out[c * 4 + r] = sum;
            }
        }
        return out;
    }

    /// A direction through a column-major transform, translation excluded: the
    /// rotation alone, which is what a centroid and a residual both need.
    fn rotate(m: [16]f32, v: [3]f32) [3]f32 {
        return .{
            m[0] * v[0] + m[4] * v[1] + m[8] * v[2],
            m[1] * v[0] + m[5] * v[1] + m[9] * v[2],
            m[2] * v[0] + m[6] * v[1] + m[10] * v[2],
        };
    }

};

const shared_testing = std.testing;

test "two devices with a shared room agree on where a point is" {
    // The same three landmarks, seen from an origin two metres along x.
    const mine = [_]shared.Landmark{
        .{ .id = 1, .x = 0, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 2, .x = 1, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 3, .x = 0, .y = 0, .z = 1, .confidence = 1 },
    };
    const theirs = [_]shared.Landmark{
        .{ .id = 1, .x = 2, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 2, .x = 3, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 3, .x = 2, .y = 0, .z = 1, .confidence = 1 },
    };
    const alignment = shared.align_(&mine, &theirs);
    try shared_testing.expectEqual(@as(usize, 3), alignment.matched);
    try shared_testing.expectApproxEqAbs(@as(f32, 2), alignment.transform[12], 1e-5);
    try shared_testing.expectApproxEqAbs(@as(f32, 0), alignment.rms_error, 1e-5);
    try shared_testing.expect(alignment.usable(0.05));

    // A pose in my origin lands where they would see it.
    var pose: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.5, 0, 0, 1 };
    const moved = shared.apply(alignment, pose);
    try shared_testing.expectApproxEqAbs(@as(f32, 2.5), moved[12], 1e-5);
    pose[12] = 0;
}

test "two devices facing different ways agree, and a pose arrives turned" {
    // Four landmarks in a room, and a second device whose origin is turned a
    // quarter turn about y and stands two metres along x. A translation-only
    // answer cannot fit this at all, which is what it used to report.
    const mine = [_]shared.Landmark{
        .{ .id = 1, .x = 0, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 2, .x = 1, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 3, .x = 0, .y = 1, .z = 0, .confidence = 1 },
        .{ .id = 4, .x = 0, .y = 0, .z = 1, .confidence = 1 },
    };
    // A quarter turn about y takes (x, y, z) to (z, y, -x), then two along x.
    var theirs: [4]shared.Landmark = undefined;
    for (mine, 0..) |m, i| {
        theirs[i] = .{ .id = m.id, .x = m.z + 2, .y = m.y, .z = -m.x, .confidence = 1 };
    }

    const alignment = shared.align_(&mine, &theirs);
    try shared_testing.expectEqual(@as(usize, 4), alignment.matched);
    try shared_testing.expectApproxEqAbs(@as(f32, 0), alignment.rms_error, 1e-4);
    try shared_testing.expect(alignment.usable(0.01));

    // The rotation itself, column-major: x goes to -z and z goes to x.
    try shared_testing.expectApproxEqAbs(@as(f32, 0), alignment.transform[0], 1e-4);
    try shared_testing.expectApproxEqAbs(@as(f32, -1), alignment.transform[2], 1e-4);
    try shared_testing.expectApproxEqAbs(@as(f32, 1), alignment.transform[8], 1e-4);
    try shared_testing.expectApproxEqAbs(@as(f32, 2), alignment.transform[12], 1e-4);

    // A pose arrives turned as well as moved: a thing facing along my x faces
    // along their negative z.
    const pose: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1 };
    const moved = shared.apply(alignment, pose);
    try shared_testing.expectApproxEqAbs(@as(f32, 2), moved[12], 1e-4);
    try shared_testing.expectApproxEqAbs(@as(f32, -1), moved[14], 1e-4);
    try shared_testing.expectApproxEqAbs(@as(f32, -1), moved[2], 1e-4);
}

test "too few landmarks is no alignment, and a bad fit is a disagreement" {
    const mine = [_]shared.Landmark{
        .{ .id = 1, .x = 0, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 2, .x = 1, .y = 0, .z = 0, .confidence = 1 },
    };
    const theirs = [_]shared.Landmark{
        .{ .id = 1, .x = 5, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 2, .x = 6, .y = 0, .z = 0, .confidence = 1 },
    };
    // Two points cannot fix a rigid transform, and the answer says so rather than
    // returning the identity as though the origins already agreed.
    const weak = shared.align_(&mine, &theirs);
    try shared_testing.expectEqual(@as(usize, 0), weak.matched);
    try shared_testing.expect(!weak.usable(1.0));

    // Three that do not actually describe one room: the fit is the disagreement.
    const scattered_mine = [_]shared.Landmark{
        .{ .id = 1, .x = 0, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 2, .x = 1, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 3, .x = 0, .y = 1, .z = 0, .confidence = 1 },
    };
    const scattered_theirs = [_]shared.Landmark{
        .{ .id = 1, .x = 0, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 2, .x = 4, .y = 0, .z = 0, .confidence = 1 },
        .{ .id = 3, .x = 0, .y = 9, .z = 0, .confidence = 1 },
    };
    const bad = shared.align_(&scattered_mine, &scattered_theirs);
    try shared_testing.expectEqual(@as(usize, 3), bad.matched);
    try shared_testing.expect(bad.rms_error > 1.0);
    try shared_testing.expect(!bad.usable(0.05));
}
