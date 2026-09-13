//! What a caller is allowed to see and do. It opens fully permissive: this
//! engine had callers before scopes existed, and a default that silently denied
//! them would break working code rather than protect anything. A host that wants
//! a narrow scope says so.

const std = @import("std");
const snapshot = @import("snapshot.zig");

/// What an agent may do back to the frame or the device. Reading is covered by
/// the snapshot sections; these are the things that change something.
pub const Verb = enum(u5) {
    annotate,
    /// Ask for a frame out of the engine, which is the one that leaves the device
    /// if a host forwards it.
    egress,
    record,
    /// Write into the memory plane, which is a record of what the camera saw.
    remember,
    search_memory,
    open_clip,
    capture_screen,
    /// Everything below is appended, never reordered: a host storing a verb mask
    /// keeps its meaning across versions.
    /// Feed the engine pixels, from a camera, a clip, a screen or a decoded file.
    submit_frame,
    /// Feed it the room and where the device is in it: planes, anchors, a mesh,
    /// depth, orientation, location, the camera's own intrinsics.
    submit_world,
    submit_audio,
    /// Mixed audio leaving the engine, which is the ear's equivalent of egress.
    audio_out,
    /// Write the memory index out as sealed bytes, or read one back in. The
    /// bytes outlive the process, which is what makes this its own permission.
    seal_memory,
    /// Run author content: a lens, its parameters, its triggers, its script.
    activate_lens,
    /// Load a caller-supplied model, which is arbitrary compute over the frame.
    load_model,
    /// Turn the trackers on: faces, hands, bodies, segmentation.
    enable_tracking,
    /// Change how the person looks: smoothing, whitening, reshaping, makeup.
    retouch,
};

/// Reading a code or a fingerprint is deliberately not a verb. Every scan op is a
/// pure function over pixels or samples the caller already holds, so a permission
/// there would gate nothing, and a verb that gates nothing is the defect this list
/// was audited to remove.

/// Every verb's name, for a host showing a person what an agent asked for and an
/// agent told which permission it is missing. A bitmask is not an explanation.
pub fn verbName(verb: Verb) []const u8 {
    return switch (verb) {
        .annotate => "annotate",
        .egress => "egress",
        .record => "record",
        .remember => "remember",
        .search_memory => "search_memory",
        .open_clip => "open_clip",
        .capture_screen => "capture_screen",
        .submit_frame => "submit_frame",
        .submit_world => "submit_world",
        .submit_audio => "submit_audio",
        .audio_out => "audio_out",
        .seal_memory => "seal_memory",
        .activate_lens => "activate_lens",
        .load_model => "load_model",
        .enable_tracking => "enable_tracking",
        .retouch => "retouch",
    };
}

/// How many verbs this build knows, so a caller can walk them by index rather
/// than hard-coding a count that goes stale.
pub const verb_count: u32 = @typeInfo(Verb).@"enum".fields.len;

/// A scope, small enough to pass by value and to cross the ABI as two words.
pub const Scope = packed struct(u64) {
    /// Which snapshot sections may be read, in the same bit order as Select so
    /// the intersection is one instruction.
    sections: u32 = std.math.maxInt(u32),
    verbs: u32 = std.math.maxInt(u32),

    /// Everything, which is what a session has until a host narrows it.
    pub const all: Scope = .{};

    /// Nothing. A caller given this can watch the engine run and learn nothing
    /// from it, which is the useful floor for an untrusted agent.
    pub const none: Scope = .{ .sections = 0, .verbs = 0 };

    pub fn allows(s: Scope, tag: snapshot.Tag) bool {
        const bit = bitFor(tag) orelse return false;
        return s.sections & bit != 0;
    }

    pub fn allowsVerb(s: Scope, verb: Verb) bool {
        return s.verbs & (@as(u32, 1) << @intFromEnum(verb)) != 0;
    }

    /// The sections a caller asked for, narrowed to what it may have. A request
    /// for something out of scope is dropped rather than refused, so an agent
    /// asking for everything gets what it is entitled to instead of an error it
    /// cannot act on.
    pub fn narrow(s: Scope, select: snapshot.Select) snapshot.Select {
        const asked: u32 = @bitCast(select);
        return @bitCast(asked & s.sections);
    }

    /// Narrowed by another scope, never widened. A session hands its scope to
    /// whatever runs inside it, and anything that could grant itself a verb back
    /// would make the whole mechanism advisory; widening means a new session.
    pub fn narrowedTo(s: Scope, asked: Scope) Scope {
        return .{ .sections = s.sections & asked.sections, .verbs = s.verbs & asked.verbs };
    }

    pub fn withSection(s: Scope, tag: snapshot.Tag, allowed: bool) Scope {
        const bit = bitFor(tag) orelse return s;
        var out = s;
        out.sections = if (allowed) s.sections | bit else s.sections & ~bit;
        return out;
    }

    pub fn withVerb(s: Scope, verb: Verb, allowed: bool) Scope {
        const bit = @as(u32, 1) << @intFromEnum(verb);
        var out = s;
        out.verbs = if (allowed) s.verbs | bit else s.verbs & ~bit;
        return out;
    }
};

/// The bit a tag occupies, which is its position in Select. A tag this build
/// does not know has no bit, so it is never readable under any scope: a newer
/// engine's section must be declared before a scope can grant it.
fn bitFor(tag: snapshot.Tag) ?u32 {
    // Compared as integers, not by name: the tag set is non-exhaustive, and
    // asking an unnamed value for its name is not a question it can answer.
    const names = comptime std.meta.fieldNames(snapshot.Select);
    inline for (names, 0..) |name, i| {
        if (comptime std.mem.startsWith(u8, name, "_")) continue;
        if (!comptime @hasField(snapshot.Tag, name)) continue;
        if (@intFromEnum(tag) == @intFromEnum(@field(snapshot.Tag, name))) return @as(u32, 1) << @intCast(i);
    }
    return null;
}

const testing = std.testing;

test "a scope opens fully and narrows to nothing" {
    try testing.expect(Scope.all.allows(.frame));
    try testing.expect(Scope.all.allows(.text));
    try testing.expect(Scope.all.allowsVerb(.egress));

    try testing.expect(!Scope.none.allows(.frame));
    try testing.expect(!Scope.none.allowsVerb(.annotate));
    // Nothing readable means a request for everything comes back empty rather
    // than failing, so a caller gets what it is entitled to.
    const narrowed = Scope.none.narrow(snapshot.Select.all);
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(narrowed)));
}

test "one section can be withheld while the rest stay readable" {
    const no_frame = Scope.all.withSection(.frame, false);
    try testing.expect(!no_frame.allows(.frame));
    try testing.expect(no_frame.allows(.faces));

    // The pixels are withheld and the rest of the reading is not, which is the
    // shape a host wants for an agent it trusts to read but not to watch.
    const narrowed = no_frame.narrow(snapshot.Select.all);
    try testing.expect(!narrowed.frame);
    try testing.expect(narrowed.faces);
    try testing.expect(narrowed.text);
}

test "a verb can be withheld on its own, and every verb has its own bit" {
    var s = Scope.all;
    s = s.withVerb(.egress, false);
    try testing.expect(!s.allowsVerb(.egress));
    try testing.expect(s.allowsVerb(.annotate));

    // No two verbs share a bit, which is what stops withholding one from
    // withholding another by accident.
    inline for (comptime std.meta.fieldNames(Verb)) |name| {
        const verb = @field(Verb, name);
        const only = Scope.none.withVerb(verb, true);
        inline for (comptime std.meta.fieldNames(Verb)) |other_name| {
            const other = @field(Verb, other_name);
            const expected = verb == other;
            try testing.expectEqual(expected, only.allowsVerb(other));
        }
    }
}

test "every section a scope can name is one the record carries" {
    // A tag with no bit is readable under no scope, so a newer engine's section
    // cannot be granted by an older one that does not know it.
    try testing.expect(bitFor(@enumFromInt(9999)) == null);
    try testing.expect(!Scope.all.allows(@enumFromInt(9999)));
    // And every tag this build declares does have one.
    inline for (comptime std.meta.fieldNames(snapshot.Tag)) |name| {
        if (comptime std.mem.eql(u8, name, "_")) continue;
        try testing.expect(bitFor(@field(snapshot.Tag, name)) != null);
    }
}
