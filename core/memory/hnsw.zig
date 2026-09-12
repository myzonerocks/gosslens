//! A navigable small-world graph over the embeddings, which is what answers a
//! nearest-neighbour query on a phone-sized corpus inside a frame. Insert,
//! delete and update are incremental: an index that must be rebuilt to accept a
//! keyframe is an index nothing can remember into.

const std = @import("std");
const vector_index = @import("vector_index.zig");

const Match = vector_index.Match;
const Metric = vector_index.Metric;

pub const Error = vector_index.Error;

pub const Options = struct {
    /// Neighbours kept per node on the upper layers, and twice that on layer
    /// zero, which is the shape the algorithm's own analysis argues for.
    connections: usize = 16,
    /// How wide the search runs while building. Higher costs build time and
    /// buys recall, and the proof measures rather than assumes the trade.
    build_width: usize = 200,
    /// The default width at query time; a caller raises it for a query that
    /// must not miss.
    search_width: usize = 64,
    /// Nothing beyond this is inserted, so the memory a caller was promised is
    /// the memory it gets.
    max_elements: usize = 100_000,
    metric: Metric = .cosine,
    /// Fixed, so an index built twice from the same inserts is the same index
    /// and the determinism gate has something to hold.
    seed: u64 = 0x9E3779B97F4A7C15,
};

const Node = struct {
    id: u64,
    /// Where this node's vector starts in the flat store.
    offset: usize,
    top_layer: u8,
    live: bool,
};

pub const Index = struct {
    gpa: std.mem.Allocator,
    dim: usize,
    opts: Options,

    vectors: std.ArrayListUnmanaged(f32) = .empty,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    /// Neighbour lists, one slice per node per layer, flattened: layer zero
    /// holds 2*connections and the rest hold connections.
    links: std.ArrayListUnmanaged(u32) = .empty,
    link_counts: std.ArrayListUnmanaged(u16) = .empty,
    /// Where each node's layer-zero links begin; the upper layers follow.
    link_offsets: std.ArrayListUnmanaged(usize) = .empty,

    entry: ?u32 = null,
    top_layer: u8 = 0,
    live_count: usize = 0,
    prng: std.Random.DefaultPrng,

    /// Scratch the search reuses, so a query after the first allocates nothing.
    visited: std.ArrayListUnmanaged(u32) = .empty,
    visited_epoch: u32 = 0,
    candidates: std.ArrayListUnmanaged(Match) = .empty,
    results: std.ArrayListUnmanaged(Match) = .empty,

    pub fn init(gpa: std.mem.Allocator, dim: usize, opts: Options) Error!Index {
        if (dim == 0) return error.DimensionMismatch;
        return .{
            .gpa = gpa,
            .dim = dim,
            .opts = opts,
            .prng = std.Random.DefaultPrng.init(opts.seed),
        };
    }

    pub fn deinit(index: *Index) void {
        index.vectors.deinit(index.gpa);
        index.nodes.deinit(index.gpa);
        index.links.deinit(index.gpa);
        index.link_counts.deinit(index.gpa);
        index.link_offsets.deinit(index.gpa);
        index.visited.deinit(index.gpa);
        index.candidates.deinit(index.gpa);
        index.results.deinit(index.gpa);
        index.* = undefined;
    }

    pub fn count(index: *const Index) usize {
        return index.live_count;
    }

    /// The bytes this index holds, so a caller checks the budget it set rather
    /// than discovering it.
    pub fn byteSize(index: *const Index) usize {
        return index.vectors.items.len * @sizeOf(f32) +
            index.nodes.items.len * @sizeOf(Node) +
            index.links.items.len * @sizeOf(u32) +
            index.link_counts.items.len * @sizeOf(u16) +
            index.link_offsets.items.len * @sizeOf(usize);
    }

    fn linksPerLayer(index: *const Index, layer: u8) usize {
        return if (layer == 0) index.opts.connections * 2 else index.opts.connections;
    }

    fn layerBase(index: *const Index, node: u32, layer: u8) usize {
        const start = index.link_offsets.items[node];
        if (layer == 0) return start;
        return start + index.opts.connections * 2 + (@as(usize, layer) - 1) * index.opts.connections;
    }

    fn neighbours(index: *const Index, node: u32, layer: u8) []const u32 {
        const base = index.layerBase(node, layer);
        const n = index.link_counts.items[index.countSlot(node, layer)];
        return index.links.items[base..][0..n];
    }

    fn countSlot(index: *const Index, node: u32, layer: u8) usize {
        return @as(usize, node) * (@as(usize, index.opts.connections) + 1) + layer;
    }

    fn vectorOf(index: *const Index, node: u32) []const f32 {
        return index.vectors.items[index.nodes.items[node].offset..][0..index.dim];
    }

    /// The layer a new node reaches, drawn from the exponential distribution the
    /// algorithm assumes. The generator is seeded, so two indexes built from the
    /// same inserts have the same shape.
    fn drawLayer(index: *Index) u8 {
        const level_multiplier = 1.0 / @log(@as(f64, @floatFromInt(index.opts.connections)));
        const r = index.prng.random().float(f64);
        const drawn = -@log(@max(r, std.math.floatMin(f64))) * level_multiplier;
        const capped = @min(drawn, @as(f64, @floatFromInt(index.opts.connections)));
        return @intFromFloat(@floor(capped));
    }

    /// Adds a vector, or replaces the one already under this id. The caller's
    /// vector is copied and normalized, so it is free afterwards.
    pub fn insert(index: *Index, id: u64, vector: []const f32) Error!void {
        if (vector.len != index.dim) return error.DimensionMismatch;
        if (index.find(id)) |existing| {
            const offset = index.nodes.items[existing].offset;
            @memcpy(index.vectors.items[offset..][0..index.dim], vector);
            if (index.opts.metric == .cosine) vector_index.normalize(index.vectors.items[offset..][0..index.dim]);
            return;
        }
        if (index.live_count >= index.opts.max_elements) return error.Full;

        const node: u32 = @intCast(index.nodes.items.len);
        const offset = index.vectors.items.len;
        try index.vectors.appendSlice(index.gpa, vector);
        if (index.opts.metric == .cosine) vector_index.normalize(index.vectors.items[offset..][0..index.dim]);

        const layer = index.drawLayer();
        try index.nodes.append(index.gpa, .{ .id = id, .offset = offset, .top_layer = layer, .live = true });
        try index.link_offsets.append(index.gpa, index.links.items.len);
        const slots = index.opts.connections * 2 + @as(usize, index.opts.connections) * index.opts.connections;
        try index.links.appendNTimes(index.gpa, 0, slots);
        try index.link_counts.appendNTimes(index.gpa, 0, index.opts.connections + 1);
        try index.visited.append(index.gpa, 0);
        index.live_count += 1;

        if (index.entry == null) {
            index.entry = node;
            index.top_layer = layer;
            return;
        }

        // Descend the layers above this node's own greedily, then connect on
        // each layer it reaches.
        var current = index.entry.?;
        var l = index.top_layer;
        while (l > layer) : (l -= 1) {
            current = index.greedyDescend(current, index.vectorOf(node), l);
            if (l == 0) break;
        }

        var connect_layer: i32 = @intCast(@min(layer, index.top_layer));
        while (connect_layer >= 0) : (connect_layer -= 1) {
            const lay: u8 = @intCast(connect_layer);
            try index.searchLayer(index.vectorOf(node), current, lay, index.opts.build_width);
            const found = index.results.items;
            if (found.len != 0) current = @intCast(index.nodeOf(found[0].id).?);
            try index.connect(node, lay);
        }

        if (layer > index.top_layer) {
            index.top_layer = layer;
            index.entry = node;
        }
    }

    fn nodeOf(index: *const Index, id: u64) ?usize {
        for (index.nodes.items, 0..) |n, i| {
            if (n.id == id and n.live) return i;
        }
        return null;
    }

    fn find(index: *const Index, id: u64) ?u32 {
        for (index.nodes.items, 0..) |n, i| {
            if (n.id == id and n.live) return @intCast(i);
        }
        return null;
    }

    /// Tombstones a vector. The slot is kept so every neighbour list stays
    /// valid; a deleted node is stepped over on the way through rather than
    /// unpicked from every list that points at it.
    pub fn remove(index: *Index, id: u64) Error!void {
        const node = index.find(id) orelse return error.NotFound;
        index.nodes.items[node].live = false;
        index.live_count -= 1;
        if (index.entry) |e| {
            if (e == node) index.entry = index.firstLive();
        }
    }

    fn firstLive(index: *const Index) ?u32 {
        for (index.nodes.items, 0..) |n, i| {
            if (n.live) return @intCast(i);
        }
        return null;
    }

    fn greedyDescend(index: *Index, start: u32, query: []const f32, layer: u8) u32 {
        var current = start;
        var best = vector_index.similarity(index.vectorOf(current), query, index.opts.metric);
        var moved = true;
        while (moved) {
            moved = false;
            for (index.neighbours(current, layer)) |n| {
                const score = vector_index.similarity(index.vectorOf(n), query, index.opts.metric);
                if (score > best) {
                    best = score;
                    current = n;
                    moved = true;
                }
            }
        }
        return current;
    }

    /// The layer walk, widest-first, leaving its answer in index.results. A
    /// tombstoned node is walked through but never returned.
    fn searchLayer(index: *Index, query: []const f32, entry: u32, layer: u8, width: usize) Error!void {
        index.visited_epoch += 1;
        const epoch = index.visited_epoch;
        index.candidates.clearRetainingCapacity();
        index.results.clearRetainingCapacity();

        index.visited.items[entry] = epoch;
        const entry_score = vector_index.similarity(index.vectorOf(entry), query, index.opts.metric);
        try index.candidates.append(index.gpa, .{ .id = entry, .score = entry_score });
        if (index.nodes.items[entry].live) {
            try index.results.append(index.gpa, .{ .id = index.nodes.items[entry].id, .score = entry_score });
        }

        while (index.candidates.items.len != 0) {
            var best_at: usize = 0;
            for (index.candidates.items, 0..) |c, i| {
                if (c.score > index.candidates.items[best_at].score) best_at = i;
            }
            const current = index.candidates.swapRemove(best_at);
            const worst = if (index.results.items.len >= width) index.results.items[index.results.items.len - 1].score else -std.math.floatMax(f32);
            if (index.results.items.len >= width and current.score < worst) break;

            for (index.neighbours(@intCast(current.id), layer)) |n| {
                if (index.visited.items[n] == epoch) continue;
                index.visited.items[n] = epoch;
                const score = vector_index.similarity(index.vectorOf(n), query, index.opts.metric);
                try index.candidates.append(index.gpa, .{ .id = n, .score = score });
                if (!index.nodes.items[n].live) continue;
                try index.insertResult(.{ .id = index.nodes.items[n].id, .score = score }, width);
            }
        }
    }

    fn insertResult(index: *Index, candidate: Match, width: usize) Error!void {
        if (index.results.items.len < width) {
            try index.results.append(index.gpa, candidate);
        } else if (candidate.score > index.results.items[index.results.items.len - 1].score) {
            index.results.items[index.results.items.len - 1] = candidate;
        } else return;
        var at = index.results.items.len - 1;
        while (at > 0 and index.results.items[at - 1].score < index.results.items[at].score) : (at -= 1) {
            std.mem.swap(Match, &index.results.items[at - 1], &index.results.items[at]);
        }
    }

    /// Links the new node to what the layer search found, and links back, so
    /// the graph stays navigable from either end.
    fn connect(index: *Index, node: u32, layer: u8) Error!void {
        const limit = index.linksPerLayer(layer);
        var written: usize = 0;
        const base = index.layerBase(node, layer);
        for (index.results.items) |m| {
            if (written >= limit) break;
            const other = index.find(m.id) orelse continue;
            if (other == node) continue;
            index.links.items[base + written] = other;
            written += 1;
            try index.linkBack(other, node, layer);
        }
        index.link_counts.items[index.countSlot(node, layer)] = @intCast(written);
    }

    fn linkBack(index: *Index, node: u32, other: u32, layer: u8) Error!void {
        if (index.nodes.items[node].top_layer < layer) return;
        const slot = index.countSlot(node, layer);
        const n = index.link_counts.items[slot];
        const limit = index.linksPerLayer(layer);
        const base = index.layerBase(node, layer);
        for (index.links.items[base..][0..n]) |existing| {
            if (existing == other) return;
        }
        if (n < limit) {
            index.links.items[base + n] = other;
            index.link_counts.items[slot] = n + 1;
            return;
        }
        // The list is full, so the new neighbour takes the worst one's place if
        // it is nearer. Dropping it outright strands a node nothing points at.
        const me = index.vectorOf(node);
        var worst_at: usize = 0;
        var worst = vector_index.similarity(index.vectorOf(index.links.items[base]), me, index.opts.metric);
        for (index.links.items[base..][0..n], 0..) |existing, i| {
            const score = vector_index.similarity(index.vectorOf(existing), me, index.opts.metric);
            if (score < worst) {
                worst = score;
                worst_at = i;
            }
        }
        if (vector_index.similarity(index.vectorOf(other), me, index.opts.metric) > worst) {
            index.links.items[base + worst_at] = other;
        }
    }

    /// The nearest live vectors to a query. Answers how many landed, which is
    /// fewer than k on a corpus smaller than k rather than padded with nothing.
    pub fn search(index: *Index, query: []const f32, out: []Match, width: usize) Error!usize {
        if (query.len != index.dim) return error.DimensionMismatch;
        if (out.len == 0 or index.live_count == 0) return 0;
        var normalized_buf: [512]f32 = undefined;
        var q = query;
        if (index.opts.metric == .cosine and index.dim <= normalized_buf.len) {
            @memcpy(normalized_buf[0..index.dim], query);
            vector_index.normalize(normalized_buf[0..index.dim]);
            q = normalized_buf[0..index.dim];
        }

        var current = index.entry orelse return 0;
        var l = index.top_layer;
        while (l > 0) : (l -= 1) current = index.greedyDescend(current, q, l);

        const effective = @max(width, out.len);
        try index.searchLayer(q, current, 0, effective);
        const n = @min(out.len, index.results.items.len);
        @memcpy(out[0..n], index.results.items[0..n]);
        return n;
    }
};

/// The file format. A version leads it, so an index written by an older engine
/// is refused rather than misread, and the layout is flat so a reader maps it
/// and walks it without parsing.
pub const file_magic = "GOSSHNSW";
pub const file_version: u32 = 1;

const Header = extern struct {
    magic: [8]u8,
    version: u32,
    dim: u32,
    connections: u32,
    max_elements: u32,
    metric: u32,
    node_count: u32,
    live_count: u32,
    top_layer: u32,
    entry: u32,
    has_entry: u32,
    seed: u64,
};

/// Writes the whole index, in one pass, to a caller-owned buffer. Answers the
/// byte count, and a short buffer reports the size it needed rather than a
/// truncated file that would load as something else.
pub fn save(index: *const Index, out: []u8) usize {
    const nodes = index.nodes.items.len;
    const needed = @sizeOf(Header) +
        index.vectors.items.len * @sizeOf(f32) +
        nodes * @sizeOf(Node) +
        index.links.items.len * @sizeOf(u32) +
        index.link_counts.items.len * @sizeOf(u16) +
        nodes * @sizeOf(u64);
    if (out.len < needed) return needed;

    var header: Header = .{
        .magic = file_magic.*,
        .version = file_version,
        .dim = @intCast(index.dim),
        .connections = @intCast(index.opts.connections),
        .max_elements = @intCast(index.opts.max_elements),
        .metric = @intFromEnum(index.opts.metric),
        .node_count = @intCast(nodes),
        .live_count = @intCast(index.live_count),
        .top_layer = index.top_layer,
        .entry = index.entry orelse 0,
        .has_entry = if (index.entry == null) 0 else 1,
        .seed = index.opts.seed,
    };
    var at: usize = 0;
    at += writeBytes(out[at..], std.mem.asBytes(&header));
    at += writeBytes(out[at..], std.mem.sliceAsBytes(index.vectors.items));
    at += writeBytes(out[at..], std.mem.sliceAsBytes(index.nodes.items));
    at += writeBytes(out[at..], std.mem.sliceAsBytes(index.links.items));
    at += writeBytes(out[at..], std.mem.sliceAsBytes(index.link_counts.items));
    at += writeBytes(out[at..], std.mem.sliceAsBytes(index.link_offsets.items));
    return at;
}

fn writeBytes(out: []u8, src: []const u8) usize {
    @memcpy(out[0..src.len], src);
    return src.len;
}

/// Reads an index back. A file from another version, another dimension or a
/// truncated write is refused as corrupt rather than loaded as something that
/// answers queries wrongly.
pub fn load(gpa: std.mem.Allocator, bytes: []const u8) Error!Index {
    if (bytes.len < @sizeOf(Header)) return error.Corrupt;
    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &header.magic, file_magic)) return error.Corrupt;
    if (header.version != file_version) return error.Corrupt;
    if (header.dim == 0 or header.connections == 0) return error.Corrupt;

    const metric: Metric = switch (header.metric) {
        0 => .cosine,
        1 => .euclidean,
        else => return error.Corrupt,
    };
    var index = try Index.init(gpa, header.dim, .{
        .connections = header.connections,
        .max_elements = header.max_elements,
        .metric = metric,
        .seed = header.seed,
    });
    errdefer index.deinit();

    const nodes: usize = header.node_count;
    const slots = index.opts.connections * 2 + @as(usize, index.opts.connections) * index.opts.connections;
    const vector_bytes = nodes * header.dim * @sizeOf(f32);
    const node_bytes = nodes * @sizeOf(Node);
    const link_bytes = nodes * slots * @sizeOf(u32);
    const count_bytes = nodes * (index.opts.connections + 1) * @sizeOf(u16);
    const offset_bytes = nodes * @sizeOf(usize);
    var at: usize = @sizeOf(Header);
    if (bytes.len < at + vector_bytes + node_bytes + link_bytes + count_bytes + offset_bytes) return error.Corrupt;

    try index.vectors.resize(gpa, nodes * header.dim);
    @memcpy(std.mem.sliceAsBytes(index.vectors.items), bytes[at..][0..vector_bytes]);
    at += vector_bytes;
    try index.nodes.resize(gpa, nodes);
    @memcpy(std.mem.sliceAsBytes(index.nodes.items), bytes[at..][0..node_bytes]);
    at += node_bytes;
    try index.links.resize(gpa, nodes * slots);
    @memcpy(std.mem.sliceAsBytes(index.links.items), bytes[at..][0..link_bytes]);
    at += link_bytes;
    try index.link_counts.resize(gpa, nodes * (index.opts.connections + 1));
    @memcpy(std.mem.sliceAsBytes(index.link_counts.items), bytes[at..][0..count_bytes]);
    at += count_bytes;
    try index.link_offsets.resize(gpa, nodes);
    @memcpy(std.mem.sliceAsBytes(index.link_offsets.items), bytes[at..][0..offset_bytes]);
    try index.visited.appendNTimes(gpa, 0, nodes);

    // Every link must name a node that exists, because a file is untrusted
    // input and a walk off the end of the node table is not a recoverable
    // error.
    for (index.links.items) |n| {
        if (n >= nodes) return error.Corrupt;
    }
    for (index.nodes.items) |n| {
        if (n.offset + header.dim > index.vectors.items.len) return error.Corrupt;
    }
    index.live_count = header.live_count;
    index.top_layer = @intCast(header.top_layer);
    index.entry = if (header.has_entry == 0) null else header.entry;
    if (index.entry) |e| {
        if (e >= nodes) return error.Corrupt;
    }
    return index;
}

const testing = std.testing;

test "the graph finds the nearest of a thousand vectors as the oracle does" {
    const dim = 8;
    const total = 1000;
    var index = try Index.init(testing.allocator, dim, .{ .connections = 8, .build_width = 64 });
    defer index.deinit();

    var prng = std.Random.DefaultPrng.init(0x5EED);
    const random = prng.random();
    const flat = try testing.allocator.alloc(f32, total * dim);
    defer testing.allocator.free(flat);
    const ids = try testing.allocator.alloc(u64, total);
    defer testing.allocator.free(ids);
    const live = try testing.allocator.alloc(bool, total);
    defer testing.allocator.free(live);

    for (0..total) |i| {
        const v = flat[i * dim ..][0..dim];
        for (v) |*x| x.* = random.float(f32) * 2 - 1;
        vector_index.normalize(v);
        ids[i] = @intCast(i + 1);
        live[i] = true;
        try index.insert(ids[i], v);
    }
    try testing.expectEqual(@as(usize, total), index.count());

    // Recall against the exact oracle on the same queries, reported rather than
    // assumed: an approximate index nobody measured is a guess.
    var hits: usize = 0;
    const queries = 50;
    for (0..queries) |qi| {
        var query: [dim]f32 = undefined;
        for (&query) |*x| x.* = random.float(f32) * 2 - 1;
        vector_index.normalize(&query);

        var exact: [1]vector_index.Match = undefined;
        _ = vector_index.exactSearch(flat, ids, live, dim, &query, .cosine, &exact);
        var approx: [1]vector_index.Match = undefined;
        const n = try index.search(&query, &approx, 64);
        try testing.expectEqual(@as(usize, 1), n);
        if (approx[0].id == exact[0].id) hits += 1;
        _ = qi;
    }
    // The bar is a number, not a feeling: below this the index is not worth
    // having over the exact walk.
    try testing.expect(hits * 100 / queries >= 90);
}

test "insert replaces, delete hides, and the entry survives losing its node" {
    const dim = 4;
    var index = try Index.init(testing.allocator, dim, .{ .connections = 4, .build_width = 16 });
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1, 0, 0, 0 });
    try index.insert(2, &[_]f32{ 0, 1, 0, 0 });
    try index.insert(3, &[_]f32{ 0, 0, 1, 0 });
    try testing.expectEqual(@as(usize, 3), index.count());

    var out: [3]Match = undefined;
    var n = try index.search(&[_]f32{ 1, 0, 0, 0 }, &out, 16);
    try testing.expectEqual(@as(u64, 1), out[0].id);

    // Inserting the same id again replaces rather than duplicating.
    try index.insert(1, &[_]f32{ 0, 0, 0, 1 });
    try testing.expectEqual(@as(usize, 3), index.count());
    n = try index.search(&[_]f32{ 0, 0, 0, 1 }, &out, 16);
    try testing.expectEqual(@as(u64, 1), out[0].id);

    // Deleting the entry node leaves the index navigable.
    try index.remove(1);
    try testing.expectEqual(@as(usize, 2), index.count());
    n = try index.search(&[_]f32{ 0, 1, 0, 0 }, &out, 16);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 2), out[0].id);
    for (out[0..n]) |m| try testing.expect(m.id != 1);

    try testing.expectError(error.NotFound, index.remove(99));
}

test "the index refuses past its bound and reports what it holds" {
    var index = try Index.init(testing.allocator, 2, .{ .connections = 4, .max_elements = 3 });
    defer index.deinit();
    try index.insert(1, &[_]f32{ 1, 0 });
    try index.insert(2, &[_]f32{ 0, 1 });
    try index.insert(3, &[_]f32{ 1, 1 });
    try testing.expectError(error.Full, index.insert(4, &[_]f32{ 1, 0 }));
    try testing.expect(index.byteSize() > 0);
    try testing.expectError(error.DimensionMismatch, index.insert(5, &[_]f32{1}));
}

test "an index survives a round trip through its file and refuses a broken one" {
    const dim = 6;
    var index = try Index.init(testing.allocator, dim, .{ .connections = 6, .build_width = 32 });
    defer index.deinit();

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();
    for (0..120) |i| {
        var v: [dim]f32 = undefined;
        for (&v) |*x| x.* = random.float(f32) * 2 - 1;
        try index.insert(@intCast(i + 1), &v);
    }
    try index.remove(7);

    const needed = save(&index, &.{});
    const buffer = try testing.allocator.alloc(u8, needed);
    defer testing.allocator.free(buffer);
    try testing.expectEqual(needed, save(&index, buffer));

    var restored = try load(testing.allocator, buffer);
    defer restored.deinit();
    try testing.expectEqual(index.count(), restored.count());

    // The same query answers the same way, which is the only thing persistence
    // is for.
    var query: [dim]f32 = undefined;
    for (&query) |*x| x.* = random.float(f32) * 2 - 1;
    var before: [5]Match = undefined;
    var after: [5]Match = undefined;
    const n = try index.search(&query, &before, 32);
    try testing.expectEqual(n, try restored.search(&query, &after, 32));
    for (0..n) |i| try testing.expectEqual(before[i].id, after[i].id);
    // And the deleted vector is still gone after the trip.
    for (after[0..n]) |m| try testing.expect(m.id != 7);

    // A file is untrusted input.
    var broken = try testing.allocator.dupe(u8, buffer);
    defer testing.allocator.free(broken);
    broken[0] = 'X';
    try testing.expectError(error.Corrupt, load(testing.allocator, broken));
    try testing.expectError(error.Corrupt, load(testing.allocator, buffer[0..8]));
}
