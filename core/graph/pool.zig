//! Bounded resource pools for the frame path. Bins are resolved from a
//! descriptor once, at graph edit time; per-frame acquire and release work
//! on the bin index alone, so the steady state does no hashing, no lookup,
//! and no allocation. Exhaustion is a counted, degradable event, never an
//! allocation fallback.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Identity of a poolable resource class. Two resources are interchangeable
/// exactly when their descriptors are equal.
pub const ResourceDesc = struct {
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    usage: u32 = 0,
    size_bytes: u64 = 0,

    pub fn eql(a: ResourceDesc, b: ResourceDesc) bool {
        return std.meta.eql(a, b);
    }
};

pub const BinIndex = u16;
pub const SlotIndex = u16;

pub const AcquireError = error{Exhausted};

/// The most distinct descriptors one pool will ever hold. Today's callers ask
/// for two sizes, so this is far above need; it exists because a caller that
/// derived a size from a per-frame value would otherwise mint a bin, a slot
/// array and a GPU resource every frame with nothing to stop it.
pub const max_bins: usize = 32;

pub const BinError = Allocator.Error || error{TooManyBins};

/// The pool tracks slot states; the actual platform resources (GPU textures,
/// staging buffers) are created by the caller when a slot is first used and
/// destroyed when the pool reports them at deinit. `payload` carries the
/// caller's handle for that resource.
pub const Pool = struct {
    gpa: Allocator,
    bins: std.ArrayList(Bin) = .empty,
    /// Descriptors turned away at the bin cap. Non-zero means a caller is
    /// deriving a pooled size from something that changes.
    bins_refused: u64 = 0,

    const Bin = struct {
        desc: ResourceDesc,
        capacity: u16,
        payloads: []u64,
        free_stack: []SlotIndex,
        free_count: u16,
        live_peak: u16,
        exhausted_count: u64,
    };

    pub fn init(gpa: Allocator) Pool {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Pool) void {
        for (p.bins.items) |bin| {
            p.gpa.free(bin.payloads);
            p.gpa.free(bin.free_stack);
        }
        p.bins.deinit(p.gpa);
    }

    /// Edit-time: returns the bin for a descriptor, creating it with the
    /// given capacity on first sight. Linear over bins, which are few and
    /// created only while the graph is being built.
    pub fn binFor(p: *Pool, desc: ResourceDesc, capacity: u16) BinError!BinIndex {
        for (p.bins.items, 0..) |bin, i| {
            if (bin.desc.eql(desc)) return @intCast(i);
        }
        if (p.bins.items.len >= max_bins) {
            p.bins_refused +|= 1;
            return error.TooManyBins;
        }
        const payloads = try p.gpa.alloc(u64, capacity);
        errdefer p.gpa.free(payloads);
        const free_stack = try p.gpa.alloc(SlotIndex, capacity);
        errdefer p.gpa.free(free_stack);
        @memset(payloads, 0);
        for (free_stack, 0..) |*s, i| s.* = @intCast(capacity - 1 - i);
        try p.bins.append(p.gpa, .{
            .desc = desc,
            .capacity = capacity,
            .payloads = payloads,
            .free_stack = free_stack,
            .free_count = capacity,
            .live_peak = 0,
            .exhausted_count = 0,
        });
        return @intCast(p.bins.items.len - 1);
    }

    /// Frame-time: constant time, no allocation. Exhaustion increments the
    /// bin's counter and surfaces as an error for the degradation policy.
    pub fn acquire(p: *Pool, bin_index: BinIndex) AcquireError!SlotIndex {
        const bin = &p.bins.items[bin_index];
        if (bin.free_count == 0) {
            bin.exhausted_count += 1;
            return error.Exhausted;
        }
        bin.free_count -= 1;
        const slot = bin.free_stack[bin.free_count];
        const live = bin.capacity - bin.free_count;
        if (live > bin.live_peak) bin.live_peak = live;
        return slot;
    }

    /// Frame-time: constant time, no allocation. In safe builds a slot
    /// already on the free stack trips the assert: a double release would
    /// hand the same resource to two live acquirers next.
    pub fn release(p: *Pool, bin_index: BinIndex, slot: SlotIndex) void {
        const bin = &p.bins.items[bin_index];
        std.debug.assert(bin.free_count < bin.capacity);
        std.debug.assert(slot < bin.capacity);
        if (std.debug.runtime_safety) {
            for (bin.free_stack[0..bin.free_count]) |already_free| std.debug.assert(already_free != slot);
        }
        bin.free_stack[bin.free_count] = slot;
        bin.free_count += 1;
    }

    pub fn setPayload(p: *Pool, bin_index: BinIndex, slot: SlotIndex, value: u64) void {
        p.bins.items[bin_index].payloads[slot] = value;
    }

    pub fn payload(p: *const Pool, bin_index: BinIndex, slot: SlotIndex) u64 {
        return p.bins.items[bin_index].payloads[slot];
    }

    pub const BinReport = struct {
        desc: ResourceDesc,
        capacity: u16,
        live: u16,
        live_peak: u16,
        exhausted_count: u64,
    };

    /// High-water and exhaustion accounting for the harness frame report.
    pub fn report(p: *const Pool, bin_index: BinIndex) BinReport {
        const bin = p.bins.items[bin_index];
        return .{
            .desc = bin.desc,
            .capacity = bin.capacity,
            .live = bin.capacity - bin.free_count,
            .live_peak = bin.live_peak,
            .exhausted_count = bin.exhausted_count,
        };
    }

    pub fn binCount(p: *const Pool) usize {
        return p.bins.items.len;
    }
};

const t = std.testing;

test "same descriptor reuses the bin, different descriptor gets a new one" {
    var p = Pool.init(t.allocator);
    defer p.deinit();
    const full_hd: ResourceDesc = .{ .width = 1920, .height = 1080, .format = 1, .usage = 1 };
    const a = try p.binFor(full_hd, 4);
    const b = try p.binFor(full_hd, 4);
    const c = try p.binFor(.{ .width = 1280, .height = 720, .format = 1, .usage = 1 }, 4);
    try t.expectEqual(a, b);
    try t.expect(a != c);
    try t.expectEqual(@as(usize, 2), p.binCount());
}

test "acquire and release cycle with peak tracking" {
    var p = Pool.init(t.allocator);
    defer p.deinit();
    const bin = try p.binFor(.{ .size_bytes = 4096, .usage = 2 }, 3);

    const s0 = try p.acquire(bin);
    const s1 = try p.acquire(bin);
    try t.expect(s0 != s1);
    p.release(bin, s0);
    const s2 = try p.acquire(bin);
    _ = s2;

    const r = p.report(bin);
    try t.expectEqual(@as(u16, 2), r.live);
    try t.expectEqual(@as(u16, 2), r.live_peak);
    try t.expectEqual(@as(u64, 0), r.exhausted_count);
}

test "exhaustion is counted and recoverable, never an allocation" {
    var p = Pool.init(t.allocator);
    defer p.deinit();
    const bin = try p.binFor(.{ .size_bytes = 64 }, 2);
    _ = try p.acquire(bin);
    const s1 = try p.acquire(bin);
    try t.expectError(error.Exhausted, p.acquire(bin));
    try t.expectError(error.Exhausted, p.acquire(bin));
    try t.expectEqual(@as(u64, 2), p.report(bin).exhausted_count);
    p.release(bin, s1);
    _ = try p.acquire(bin);
}

test "payloads persist per slot across reuse" {
    var p = Pool.init(t.allocator);
    defer p.deinit();
    const bin = try p.binFor(.{ .size_bytes = 128 }, 2);
    const s = try p.acquire(bin);
    p.setPayload(bin, s, 0xfeed);
    p.release(bin, s);
    const again = try p.acquire(bin);
    try t.expectEqual(s, again);
    try t.expectEqual(@as(u64, 0xfeed), p.payload(bin, again));
}

test "the bin cap refuses a new descriptor and counts the refusal" {
    var p = Pool.init(std.testing.allocator);
    defer p.deinit();
    for (0..max_bins) |i| {
        _ = try p.binFor(.{ .width = @intCast(i + 1) }, 2);
    }
    try std.testing.expectEqual(max_bins, p.binCount());
    try std.testing.expectError(error.TooManyBins, p.binFor(.{ .width = 99999 }, 2));
    try std.testing.expectEqual(@as(u64, 1), p.bins_refused);
    // A descriptor the pool already holds still answers at the cap, so hitting
    // it costs the new size only, never the sizes already in use.
    const first = try p.binFor(.{ .width = 1 }, 2);
    try std.testing.expectEqual(@as(BinIndex, 0), first);
    try std.testing.expectEqual(max_bins, p.binCount());
}
