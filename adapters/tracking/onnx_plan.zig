//! Load-time graph work: which operators a model needs, folding away what is
//! already known, and planning one buffer so inference allocates nothing.

const std = @import("std");
const onnx = @import("onnx.zig");

const Tensor = onnx.Tensor;
const Node = onnx.Node;
const Error = onnx.Error;
const Table = std.StringHashMapUnmanaged(Tensor);

/// Every operator the engine implements. The test below reads the dispatchers'
/// own source and fails if this list and the code disagree, so a new operator
/// cannot be added without appearing in the support report.
pub const supported_ops = [_][]const u8{
    "Abs",           "Acos",                    "Add",              "And",             "ArgMax",
    "ArgMin",        "Asin",                    "Atan",             "AveragePool",     "BatchNormalization",
    "Cast",          "CastLike",                "Ceil",             "Celu",            "Clip",
    "Compress",      "Concat",                  "Constant",         "ConstantOfShape", "Conv",
    "ConvInteger",   "ConvTranspose",
    "Cos",           "CumSum",                  "DepthToSpace",     "DequantizeLinear", "Div",
    "DynamicQuantizeLinear", "Einsum",          "Elu",              "Equal",           "Erf",
    "Exp",           "Expand",                  "Flatten",          "Floor",           "Gather",
    "GatherElements", "GatherND",               "Gelu",             "Gemm",            "GlobalAveragePool",
    "Greater",       "GreaterOrEqual",          "GridSample",       "HardSigmoid",     "HardSwish",
    "Identity",      "If",                      "InstanceNormalization", "LayerNormalization", "LeakyRelu",
    "Less",          "LessOrEqual",             "Log",              "LogSoftmax",      "Loop",
    "MatMul",        "MatMulInteger",           "Max",              "MaxPool",         "Mean",
    "Min",           "Mish",                    "Mod",              "Mul",             "Neg",
    "NonMaxSuppression", "NonZero",             "Not",              "OneHot",          "Or",
    "PRelu",         "Pad",                     "Pow",              "QLinearConv",     "QLinearMatMul",
    "QLinearAdd",    "QLinearGlobalAveragePool",
    "QuantizeLinear", "Range",                  "Reciprocal",       "ReduceL2",        "ReduceLogSum",
    "ReduceMax",     "ReduceMean",              "ReduceMin",        "ReduceProd",      "ReduceSum",
    "ReduceSumSquare", "Relu",                  "Reshape",          "Resize",          "RoiAlign",
    "Round",         "Scan",                    "Scatter",          "ScatterElements", "ScatterND",
    "Selu",          "Shape",                   "Sigmoid",          "Sign",            "Sin",
    "Slice",         "Softmax",              "SpaceToDepth",                 "Softplus",         "Softsign",        "Split",
    "Sqrt",          "Squeeze",                 "Sub",              "Sum",             "Tan",
    "Tanh",          "ThresholdedRelu",         "Tile",             "TopK",            "Transpose",
    "Trilu",         "Unsqueeze",               "Where",            "Xor",
};

pub fn isSupported(op: []const u8) bool {
    for (supported_ops) |name| {
        if (std.mem.eql(u8, name, op)) return true;
    }
    return false;
}

/// Every node in a graph, the bodies its control-flow nodes carry included. A
/// node names only its own inputs and op, so reading the top level alone misses
/// an operator a body needs and a value a body captures. Bounded rather than
/// recursive, because the nesting is untrusted input.
pub const Walk = struct {
    /// Deep enough for any real graph: an If pushes both branches, so this holds
    /// eight nested control-flow nodes, twice the depth the executor allows.
    const max_lists = 16;

    lists: [max_lists][]const Node = undefined,
    cursors: [max_lists]usize = @splat(0),
    depth: usize = 0,
    /// Set when a model nested past what this holds. A caller that must be exact
    /// reads it and refuses rather than reporting a partial answer as complete.
    overflowed: bool = false,

    pub fn init(nodes: []const Node) Walk {
        var w: Walk = .{};
        w.lists[0] = nodes;
        w.cursors[0] = 0;
        w.depth = 1;
        return w;
    }

    pub fn next(w: *Walk) ?*const Node {
        while (w.depth > 0) {
            const at = w.depth - 1;
            if (w.cursors[at] >= w.lists[at].len) {
                w.depth -= 1;
                continue;
            }
            const node = &w.lists[at][w.cursors[at]];
            w.cursors[at] += 1;
            for (node.attrs) |*attr| {
                const body = attr.g orelse continue;
                if (w.depth >= max_lists) {
                    w.overflowed = true;
                    break;
                }
                w.lists[w.depth] = body.nodes;
                w.cursors[w.depth] = 0;
                w.depth += 1;
            }
            return node;
        }
        return null;
    }
};

/// Every node a graph runs, the bodies included. The frame buffer's bookkeeping
/// is sized from this rather than from the top level, because a graph whose work
/// sits inside a loop has a handful of nodes and thousands of allocations.
pub fn nodeCount(nodes: []const Node) usize {
    var walk = Walk.init(nodes);
    var n: usize = 0;
    while (walk.next()) |_| n += 1;
    return n;
}

/// Writes the operators a model needs that this engine does not implement, one
/// per line, and answers how many bytes the full answer takes. A caller with a
/// short buffer learns the size rather than a truncated list it cannot trust.
pub fn missingOps(nodes: []const Node, out: []u8) usize {
    var written: usize = 0;
    var needed: usize = 0;
    // Ops already named. A graph needing more distinct operators than this build
    // lacks is a graph nobody runs, and past the bound a repeat only makes the
    // reported size larger than it had to be.
    var seen: [64][]const u8 = undefined;
    var seen_count: usize = 0;
    var walk = Walk.init(nodes);
    while (walk.next()) |node| {
        if (isSupported(node.op_type)) continue;
        var already = false;
        for (seen[0..seen_count]) |prior| {
            if (std.mem.eql(u8, prior, node.op_type)) already = true;
        }
        if (already) continue;
        if (seen_count < seen.len) {
            seen[seen_count] = node.op_type;
            seen_count += 1;
        }
        const line_len = node.op_type.len + 1;
        needed += line_len;
        if (written + line_len <= out.len) {
            @memcpy(out[written..][0..node.op_type.len], node.op_type);
            out[written + node.op_type.len] = '\n';
            written += line_len;
        }
    }
    return needed;
}

// ---- lifetimes ----

/// The node index after which a value is dead. A graph output never dies, so
/// its slot is never handed to anything else.
pub const Lifetimes = struct {
    last_use: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn build(a: std.mem.Allocator, nodes: []const Node, outputs: []const []const u8) Error!Lifetimes {
        var lt: Lifetimes = .{};
        lt.last_use.ensureTotalCapacity(a, @intCast(nodes.len * 4 + outputs.len + 4)) catch return error.OutOfMemory;
        for (0..nodes.len) |i| {
            // The node's bodies read through the same walk: a value a branch
            // captures is last read by the node carrying the branch, so its
            // buffer cannot be handed back before that node has run.
            var walk = Walk.init(nodes[i .. i + 1]);
            while (walk.next()) |node| {
                for (node.inputs) |name| {
                    if (name.len == 0) continue;
                    lt.last_use.put(a, name, @intCast(i)) catch return error.OutOfMemory;
                }
            }
        }
        for (outputs) |name| lt.last_use.put(a, name, std.math.maxInt(u32)) catch return error.OutOfMemory;
        return lt;
    }

    pub fn diesAfter(lt: *const Lifetimes, name: []const u8, node_index: usize) bool {
        const at = lt.last_use.get(name) orelse return true;
        return at == node_index;
    }
};

/// Counts what the pool would charge and remembers the most ever live at once,
/// which is what the frame buffer has to hold. An arena cannot answer that: it
/// never frees, so its capacity is the sum of everything produced. Counting the
/// payload alone cannot either, because a plan that is short by a header grows.
pub const Counting = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    high_water: usize = 0,

    pub fn init(child: std.mem.Allocator) Counting {
        return .{ .child = child };
    }

    pub fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{
            .alloc = countAlloc,
            .resize = countResize,
            .remap = countRemap,
            .free = countFree,
        } };
    }

    fn countAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawAlloc(len, alignment, ra) orelse return null;
        c.live += Pool.charge(len, alignment);
        c.high_water = @max(c.high_water, c.live);
        return p;
    }

    fn countResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (!c.child.rawResize(memory, alignment, new_len, ra)) return false;
        c.live = c.live - Pool.charge(memory.len, alignment) + Pool.charge(new_len, alignment);
        c.high_water = @max(c.high_water, c.live);
        return true;
    }

    fn countRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        c.live = c.live - Pool.charge(memory.len, alignment) + Pool.charge(new_len, alignment);
        c.high_water = @max(c.high_water, c.live);
        return p;
    }

    fn countFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.child.rawFree(memory, alignment, ra);
        c.live -= Pool.charge(memory.len, alignment);
    }
};

// ---- one buffer, reused ----

/// A fixed-buffer allocator whose every operation is constant time: blocks
/// linked in address order, free ones threaded onto a list per power-of-two size
/// class, and each allocation carrying its block index in the eight bytes before
/// the payload. Nothing after load reaches the general allocator.
pub const Pool = struct {
    buffer: []u8,
    blocks: []Block,
    used: usize = 0,
    recycled: u32 = nil_block,
    free_heads: [class_count]u32 = @splat(nil_block),
    high_water: usize = 0,
    exhausted: u32 = 0,

    pub const Block = struct {
        offset: usize,
        len: usize,
        free: bool,
        /// Address order: what makes merging with the space beside it local.
        prev: u32 = nil_block,
        next: u32 = nil_block,
        /// Membership of one size class's free list.
        free_prev: u32 = nil_block,
        free_next: u32 = nil_block,
    };

    const nil_block = std.math.maxInt(u32);
    const class_count = @bitSizeOf(usize);
    /// Holds the block index, so a pointer finds its block in one read.
    const header = 8;
    /// A smaller remainder stays inside the allocation: a block costs more to
    /// track than such a sliver can serve.
    const min_split = 32;

    pub fn init(buffer: []u8, blocks: []Block) Pool {
        var p: Pool = .{ .buffer = buffer, .blocks = blocks };
        p.reset();
        return p;
    }

    pub fn reset(p: *Pool) void {
        p.used = 0;
        p.recycled = nil_block;
        p.free_heads = @splat(nil_block);
        if (p.blocks.len == 0 or p.buffer.len == 0) return;
        p.blocks[0] = .{ .offset = 0, .len = p.buffer.len, .free = true };
        p.used = 1;
        p.pushFree(0);
    }

    pub fn allocator(p: *Pool) std.mem.Allocator {
        return .{ .ptr = p, .vtable = &.{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        } };
    }

    /// What one allocation costs the pool: the payload, its header, the padding
    /// alignment can demand, and a tail too small to split off. A measure that
    /// counts only payloads underestimates, and a plan short by that much grows
    /// mid-frame, which throws the frame away and runs it again.
    pub fn charge(len: usize, alignment: std.mem.Alignment) usize {
        const want = @max(alignment.toByteUnits(), header);
        return len + header + want - 1 + min_split;
    }

    fn classOf(len: usize) usize {
        if (len < 2) return 0;
        return class_count - 1 - @clz(len);
    }

    /// Rounds up to a class boundary, so any block on that class's list or a
    /// larger one certainly fits and the search takes the first head it finds.
    fn roundToClass(len: usize) usize {
        const c = classOf(len);
        if (c + 1 >= class_count) return len;
        const base = @as(usize, 1) << @intCast(c);
        if (len == base) return len;
        return base << 1;
    }

    fn pushFree(p: *Pool, index: u32) void {
        const c = classOf(p.blocks[index].len);
        const head = p.free_heads[c];
        p.blocks[index].free_prev = nil_block;
        p.blocks[index].free_next = head;
        if (head != nil_block) p.blocks[head].free_prev = index;
        p.free_heads[c] = index;
    }

    fn pullFree(p: *Pool, index: u32) void {
        const b = p.blocks[index];
        if (b.free_prev != nil_block) {
            p.blocks[b.free_prev].free_next = b.free_next;
        } else {
            p.free_heads[classOf(b.len)] = b.free_next;
        }
        if (b.free_next != nil_block) p.blocks[b.free_next].free_prev = b.free_prev;
        p.blocks[index].free_prev = nil_block;
        p.blocks[index].free_next = nil_block;
    }

    fn takeSlot(p: *Pool) ?u32 {
        if (p.recycled != nil_block) {
            const slot = p.recycled;
            p.recycled = p.blocks[slot].free_next;
            return slot;
        }
        if (p.used == p.blocks.len) return null;
        const slot: u32 = @intCast(p.used);
        p.used += 1;
        return slot;
    }

    fn dropSlot(p: *Pool, index: u32) void {
        p.blocks[index].free_next = p.recycled;
        p.recycled = index;
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const p: *Pool = @ptrCast(@alignCast(ctx));
        const want = @max(alignment.toByteUnits(), header);
        if (len > p.buffer.len) {
            p.exhausted += 1;
            return null;
        }
        // The most the header and the alignment can ever cost ahead of the payload.
        const need = roundToClass(len + header + want - 1);
        var c = classOf(need);
        while (c < class_count) : (c += 1) {
            const index = p.free_heads[c];
            if (index == nil_block) continue;
            return p.carve(index, len, want) orelse break;
        }
        p.exhausted += 1;
        return null;
    }

    /// Hands out the front of a free block and returns the rest to its class.
    fn carve(p: *Pool, index: u32, len: usize, want: usize) ?[*]u8 {
        const base = @intFromPtr(p.buffer.ptr) + p.blocks[index].offset;
        const payload = std.mem.alignForward(usize, base + header, want);
        const span = payload - base + len;
        if (p.blocks[index].len < span) return null;

        p.pullFree(index);
        const tail = p.blocks[index].len - span;
        if (tail >= min_split) {
            const rest = p.takeSlot() orelse {
                p.pushFree(index);
                return null;
            };
            p.blocks[rest] = .{
                .offset = p.blocks[index].offset + span,
                .len = tail,
                .free = true,
                .prev = index,
                .next = p.blocks[index].next,
            };
            if (p.blocks[index].next != nil_block) p.blocks[p.blocks[index].next].prev = rest;
            p.blocks[index].next = rest;
            p.blocks[index].len = span;
            p.pushFree(rest);
        }
        p.blocks[index].free = false;
        std.mem.writeInt(u64, @ptrFromInt(payload - header), index, .little);
        p.high_water = @max(p.high_water, p.blocks[index].offset + p.blocks[index].len);
        return @ptrFromInt(payload);
    }

    /// Whether a pointer came out of this pool, which is what lets a caller mix
    /// the pool with somewhere to spill and still free each byte to its owner.
    pub fn ownsPointer(p: *const Pool, ptr: [*]u8) bool {
        const at = @intFromPtr(ptr);
        const base = @intFromPtr(p.buffer.ptr);
        return at >= base and at < base + p.buffer.len;
    }

    /// The block holding a pointer, read out of the pointer's own header.
    fn indexOf(p: *Pool, ptr: [*]u8) ?u32 {
        const at = @intFromPtr(ptr);
        if (at < @intFromPtr(p.buffer.ptr) + header) return null;
        if (at > @intFromPtr(p.buffer.ptr) + p.buffer.len) return null;
        const index = std.mem.readInt(u64, @ptrFromInt(at - header), .little);
        if (index >= p.used) return null;
        const block = p.blocks[@intCast(index)];
        if (block.free) return null;
        if (at < @intFromPtr(p.buffer.ptr) + block.offset) return null;
        if (at > @intFromPtr(p.buffer.ptr) + block.offset + block.len) return null;
        return @intCast(index);
    }

    /// What a block can still hold past the header and padding already spent.
    fn capacity(p: *Pool, index: u32, ptr: [*]u8) usize {
        const spent = @intFromPtr(ptr) - (@intFromPtr(p.buffer.ptr) + p.blocks[index].offset);
        return p.blocks[index].len - spent;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const p: *Pool = @ptrCast(@alignCast(ctx));
        const i = p.indexOf(memory.ptr) orelse return false;
        return new_len <= p.capacity(i, memory.ptr);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        if (resizeFn(ctx, memory, alignment, new_len, ra)) return memory.ptr;
        return null;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const p: *Pool = @ptrCast(@alignCast(ctx));
        var i = p.indexOf(memory.ptr) orelse return;
        p.blocks[i].free = true;

        const next = p.blocks[i].next;
        if (next != nil_block and p.blocks[next].free) {
            p.pullFree(next);
            p.blocks[i].len += p.blocks[next].len;
            p.blocks[i].next = p.blocks[next].next;
            if (p.blocks[next].next != nil_block) p.blocks[p.blocks[next].next].prev = i;
            p.dropSlot(next);
        }
        const prev = p.blocks[i].prev;
        if (prev != nil_block and p.blocks[prev].free) {
            p.pullFree(prev);
            p.blocks[prev].len += p.blocks[i].len;
            p.blocks[prev].next = p.blocks[i].next;
            if (p.blocks[i].next != nil_block) p.blocks[p.blocks[i].next].prev = prev;
            p.dropSlot(i);
            i = prev;
        }
        p.pushFree(i);
    }
};

/// The pool, with somewhere to spill when a frame asks for more than the plan
/// reserved. Without it an exhausted pool means throwing the frame away and
/// running the whole graph again on a bigger buffer, which for a detector is a
/// second of work lost to a few kilobytes of shortfall.
pub const Fallback = struct {
    pool: *Pool,
    spill: std.mem.Allocator,
    spilled: usize = 0,
    peak_spilled: usize = 0,

    pub fn allocator(f: *Fallback) std.mem.Allocator {
        return .{ .ptr = f, .vtable = &.{
            .alloc = fallbackAlloc,
            .resize = fallbackResize,
            .remap = fallbackRemap,
            .free = fallbackFree,
        } };
    }

    fn fallbackAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const f: *Fallback = @ptrCast(@alignCast(ctx));
        if (f.pool.allocator().rawAlloc(len, alignment, ra)) |p| return p;
        const p = f.spill.rawAlloc(len, alignment, ra) orelse return null;
        f.spilled += Pool.charge(len, alignment);
        f.peak_spilled = @max(f.peak_spilled, f.spilled);
        return p;
    }

    fn fallbackResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const f: *Fallback = @ptrCast(@alignCast(ctx));
        if (f.pool.ownsPointer(memory.ptr)) return f.pool.allocator().rawResize(memory, alignment, new_len, ra);
        return f.spill.rawResize(memory, alignment, new_len, ra);
    }

    fn fallbackRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const f: *Fallback = @ptrCast(@alignCast(ctx));
        if (f.pool.ownsPointer(memory.ptr)) return f.pool.allocator().rawRemap(memory, alignment, new_len, ra);
        return f.spill.rawRemap(memory, alignment, new_len, ra);
    }

    fn fallbackFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const f: *Fallback = @ptrCast(@alignCast(ctx));
        if (f.pool.ownsPointer(memory.ptr)) {
            f.pool.allocator().rawFree(memory, alignment, ra);
            return;
        }
        f.spill.rawFree(memory, alignment, ra);
        f.spilled -= Pool.charge(memory.len, alignment);
    }
};

test "a frame that outgrows the plan spills instead of starting over" {
    var bytes: [512]u8 = undefined;
    var blocks: [16]Pool.Block = undefined;
    var p = Pool.init(&bytes, &blocks);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var f: Fallback = .{ .pool = &p, .spill = arena.allocator() };
    const a = f.allocator();
    const inside = try a.alloc(u8, 64);
    const outside = try a.alloc(u8, 4096);
    try std.testing.expect(p.ownsPointer(inside.ptr));
    try std.testing.expect(!p.ownsPointer(outside.ptr));
    try std.testing.expect(f.peak_spilled >= 4096);

    // Each byte goes back to whoever handed it out, which is what makes mixing
    // the two safe rather than a leak on one side and a bad free on the other.
    a.free(outside);
    a.free(inside);
    try std.testing.expectEqual(@as(usize, 0), f.spilled);
}

test "the pool hands a freed block back to the next caller of the same size" {
    var bytes: [4096]u8 = undefined;
    var blocks: [64]Pool.Block = undefined;
    var p = Pool.init(&bytes, &blocks);
    const a = p.allocator();

    const first = try a.alloc(u64, 16);
    a.free(first);
    const second = try a.alloc(u64, 16);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(second.ptr));
    a.free(second);
    // Reuse means the furthest byte ever reserved stays where one allocation put it.
    try std.testing.expect(p.high_water <= 16 * @sizeOf(u64) + 64);
}

test "freeing every block in any order leaves one block covering the buffer" {
    var bytes: [8192]u8 = undefined;
    var blocks: [256]Pool.Block = undefined;
    var p = Pool.init(&bytes, &blocks);
    const a = p.allocator();

    var held: [24][]u32 = undefined;
    for (&held, 0..) |*slot, i| slot.* = try a.alloc(u32, 8 + i);
    // Odd indices first, so every merge direction is exercised.
    for (held, 0..) |slot, i| if (i % 2 == 1) a.free(slot);
    for (held, 0..) |slot, i| if (i % 2 == 0) a.free(slot);

    var live: usize = 0;
    var whole: usize = 0;
    for (p.blocks[0..p.used]) |b| {
        if (!b.free) live += 1;
        if (b.free and b.len == bytes.len) whole += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), live);
    try std.testing.expectEqual(@as(usize, 1), whole);
}

test "a pool that cannot fit a request says so instead of overrunning the buffer" {
    var bytes: [1024]u8 = undefined;
    var blocks: [16]Pool.Block = undefined;
    var p = Pool.init(&bytes, &blocks);
    const a = p.allocator();

    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 2048));
    try std.testing.expectEqual(@as(u32, 1), p.exhausted);
    const fits = try a.alloc(u8, 64);
    a.free(fits);
}

test "a block is found from its pointer no matter how many blocks there are" {
    var bytes: [1 << 16]u8 = undefined;
    var blocks: [2048]Pool.Block = undefined;
    var p = Pool.init(&bytes, &blocks);
    const a = p.allocator();

    var held: [400][]u8 = undefined;
    for (&held) |*slot| slot.* = try a.alloc(u8, 24);
    // The last one allocated is the deepest in the address list, and freeing it
    // must cost what freeing the first one costs.
    for (held) |slot| a.free(slot);
    try std.testing.expectEqual(@as(u32, 0), p.exhausted);
}

test "alignment past eight bytes is honoured and still freeable" {
    var bytes: [4096]u8 = undefined;
    var blocks: [64]Pool.Block = undefined;
    var p = Pool.init(&bytes, &blocks);
    const a = p.allocator();

    const wide = try a.alignedAlloc(u8, .@"64", 100);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(wide.ptr) % 64);
    a.free(wide);
    const again = try a.alignedAlloc(u8, .@"64", 100);
    try std.testing.expectEqual(@intFromPtr(wide.ptr), @intFromPtr(again.ptr));
    a.free(again);
}

// ---- load-time rewriting ----

pub const Optimization = struct {
    folded: u32 = 0,
    eliminated: u32 = 0,
    fused: u32 = 0,
};

fn producedBy(nodes: []const Node, name: []const u8) ?usize {
    for (nodes, 0..) |n, i| {
        for (n.outputs) |o| {
            if (std.mem.eql(u8, o, name)) return i;
        }
    }
    return null;
}

/// Drops every node no declared output depends on. A training graph carries
/// losses and debug taps a camera frame should never pay for.
pub fn eliminateDead(a: std.mem.Allocator, nodes: []const Node, outputs: []const []const u8, stats: *Optimization) Error![]const Node {
    const live = a.alloc(bool, nodes.len) catch return error.OutOfMemory;
    @memset(live, false);
    var wanted: std.ArrayList([]const u8) = .empty;
    for (outputs) |o| wanted.append(a, o) catch return error.OutOfMemory;

    var head: usize = 0;
    while (head < wanted.items.len) : (head += 1) {
        const name = wanted.items[head];
        const at = producedBy(nodes, name) orelse continue;
        if (live[at]) continue;
        live[at] = true;
        // Bodies included: a tensor a branch captures is named nowhere at the
        // top level, and without this its producer reads as dead and is deleted,
        // so the body asks at run time for a name nothing holds.
        var walk = Walk.init(nodes[at .. at + 1]);
        while (walk.next()) |node| {
            for (node.inputs) |i| {
                if (i.len != 0) wanted.append(a, i) catch return error.OutOfMemory;
            }
        }
    }

    var kept: std.ArrayList(Node) = .empty;
    for (nodes, 0..) |n, i| {
        if (live[i]) {
            kept.append(a, n) catch return error.OutOfMemory;
        } else {
            stats.eliminated += 1;
        }
    }
    return kept.toOwnedSlice(a) catch return error.OutOfMemory;
}

/// Conv followed by batch normalization is one convolution once the four
/// batchnorm constants are folded into the weights and the bias, which is the
/// single biggest saving on any exported vision model.
pub fn fuseConvBatchNorm(
    a: std.mem.Allocator,
    nodes: []const Node,
    initializers: *std.StringHashMapUnmanaged(Tensor),
    stats: *Optimization,
) Error![]const Node {
    var kept: std.ArrayList(Node) = .empty;
    var skip = a.alloc(bool, nodes.len) catch return error.OutOfMemory;
    @memset(skip, false);

    for (nodes, 0..) |node, i| {
        if (skip[i]) continue;
        if (!std.mem.eql(u8, node.op_type, "Conv") or node.outputs.len != 1) {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        }
        const bn_at = nextConsumer(nodes, i, node.outputs[0]) orelse {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        };
        const bn = nodes[bn_at];
        if (!std.mem.eql(u8, bn.op_type, "BatchNormalization") or bn.inputs.len < 5 or
            countConsumers(nodes, node.outputs[0]) != 1)
        {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        }
        const w = initializers.get(node.inputs[1]) orelse {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        };
        const scale = initializers.get(bn.inputs[1]);
        const shift = initializers.get(bn.inputs[2]);
        const mean = initializers.get(bn.inputs[3]);
        const variance = initializers.get(bn.inputs[4]);
        if (scale == null or shift == null or mean == null or variance == null) {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        }
        const epsilon = bn.attrFloat("epsilon", 1e-5);
        const channels: usize = @intCast(@max(w.dims[0], 1));
        const per_channel = if (channels == 0) 0 else w.data.len / channels;

        const new_w = a.alloc(f32, w.data.len) catch return error.OutOfMemory;
        const new_b = a.alloc(f32, channels) catch return error.OutOfMemory;
        const old_bias: ?Tensor = if (node.inputs.len > 2 and node.inputs[2].len != 0) initializers.get(node.inputs[2]) else null;
        for (0..channels) |c| {
            const factor = scale.?.data[c % scale.?.data.len] / @sqrt(variance.?.data[c % variance.?.data.len] + epsilon);
            for (0..per_channel) |k| new_w[c * per_channel + k] = w.data[c * per_channel + k] * factor;
            const b0: f32 = if (old_bias) |ob| (if (c < ob.data.len) ob.data[c] else 0) else 0;
            new_b[c] = (b0 - mean.?.data[c % mean.?.data.len]) * factor + shift.?.data[c % shift.?.data.len];
        }

        const w_name = std.fmt.allocPrint(a, "{s}.fused_w", .{node.outputs[0]}) catch return error.OutOfMemory;
        const b_name = std.fmt.allocPrint(a, "{s}.fused_b", .{node.outputs[0]}) catch return error.OutOfMemory;
        initializers.put(a, w_name, .{ .dims = w.dims, .data = new_w }) catch return error.OutOfMemory;
        initializers.put(a, b_name, .{ .dims = a.dupe(i64, &[_]i64{@intCast(channels)}) catch return error.OutOfMemory, .data = new_b }) catch return error.OutOfMemory;

        const inputs = a.alloc([]const u8, 3) catch return error.OutOfMemory;
        inputs[0] = node.inputs[0];
        inputs[1] = w_name;
        inputs[2] = b_name;
        kept.append(a, .{
            .op_type = node.op_type,
            .inputs = inputs,
            .outputs = bn.outputs[0..1],
            .attrs = node.attrs,
        }) catch return error.OutOfMemory;
        skip[bn_at] = true;
        stats.fused += 1;
    }
    return kept.toOwnedSlice(a) catch return error.OutOfMemory;
}

fn nextConsumer(nodes: []const Node, after: usize, name: []const u8) ?usize {
    for (nodes[after + 1 ..], after + 1..) |n, i| {
        for (n.inputs) |in_name| {
            if (std.mem.eql(u8, in_name, name)) return i;
        }
    }
    return null;
}

fn countConsumers(nodes: []const Node, name: []const u8) usize {
    var count: usize = 0;
    for (nodes) |n| {
        for (n.inputs) |in_name| {
            if (std.mem.eql(u8, in_name, name)) count += 1;
        }
    }
    return count;
}

/// Runs every node whose inputs are all already known and turns its result into
/// an initializer. Shape arithmetic is the usual beneficiary: a graph that
/// computes its own reshape target does it once at load rather than per frame.
pub fn foldConstants(
    a: std.mem.Allocator,
    nodes: []const Node,
    initializers: *std.StringHashMapUnmanaged(Tensor),
    fed_inputs: []const []const u8,
    stats: *Optimization,
) Error![]const Node {
    var kept: std.ArrayList(Node) = .empty;
    for (nodes, 0..) |node, at| {
        var foldable = node.inputs.len != 0 and node.outputs.len == 1;
        for (node.inputs) |name| {
            if (name.len == 0) continue;
            if (initializers.get(name) == null) foldable = false;
            for (fed_inputs) |fed| {
                if (std.mem.eql(u8, fed, name)) foldable = false;
            }
        }
        // Control flow and the data-dependent shapes stay put: folding them
        // would bake in an answer that depends on the frame.
        if (foldable and (std.mem.eql(u8, node.op_type, "If") or std.mem.eql(u8, node.op_type, "Loop") or
            std.mem.eql(u8, node.op_type, "Scan") or std.mem.eql(u8, node.op_type, "NonZero"))) foldable = false;
        if (!foldable) {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        }

        var scratch: Table = .empty;
        for (node.inputs) |name| {
            if (name.len == 0) continue;
            scratch.put(a, name, initializers.get(name).?) catch return error.OutOfMemory;
        }
        onnx.runNodes(a, nodes[at .. at + 1], &scratch, 0, node.outputs) catch {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        };
        const produced = scratch.get(node.outputs[0]) orelse {
            kept.append(a, node) catch return error.OutOfMemory;
            continue;
        };
        initializers.put(a, node.outputs[0], produced) catch return error.OutOfMemory;
        stats.folded += 1;
    }
    return kept.toOwnedSlice(a) catch return error.OutOfMemory;
}
