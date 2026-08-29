//! A self-contained ONNX inference engine: it parses the ONNX protobuf into a
//! graph and runs a bounded set of feed-forward vision operators on the CPU,
//! float32 only. It mirrors the tracking runtime's Engine surface so a bring-
//! your-own model core drives an ONNX net exactly as it drives a TFLite one.

const std = @import("std");

pub const Error = error{
    ModelRejected,
    UnsupportedOp,
    TensorMissing,
    TensorShapeMismatch,
    InvokeFailed,
    OutOfMemory,
};

// Protobuf wire reader. ONNX serializes as proto3; only four wire types and a
// handful of message shapes are needed, so a small reader replaces a vendored
// protobuf. Every unknown field is skipped so a newer model still loads.

const Wire = enum(u3) { varint = 0, i64 = 1, len = 2, i32 = 5, _ };

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn atEnd(r: *const Reader) bool {
        return r.pos >= r.buf.len;
    }

    fn readVarint(r: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (r.pos < r.buf.len) {
            const byte = r.buf[r.pos];
            r.pos += 1;
            result |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) return result;
            if (shift >= 63) return error.ModelRejected;
            shift += 7;
        }
        return error.ModelRejected;
    }

    const Tag = struct { field: u32, wire: Wire };

    fn readTag(r: *Reader) Error!Tag {
        const raw = try r.readVarint();
        return .{ .field = @intCast(raw >> 3), .wire = @enumFromInt(@as(u3, @truncate(raw))) };
    }

    fn readLen(r: *Reader) Error![]const u8 {
        const n = try r.readVarint();
        if (r.pos + n > r.buf.len) return error.ModelRejected;
        const slice = r.buf[r.pos .. r.pos + n];
        r.pos += @intCast(n);
        return slice;
    }

    fn readFixed32(r: *Reader) Error!u32 {
        if (r.pos + 4 > r.buf.len) return error.ModelRejected;
        const v = std.mem.readInt(u32, r.buf[r.pos..][0..4], .little);
        r.pos += 4;
        return v;
    }

    fn readFixed64(r: *Reader) Error!u64 {
        if (r.pos + 8 > r.buf.len) return error.ModelRejected;
        const v = std.mem.readInt(u64, r.buf[r.pos..][0..8], .little);
        r.pos += 8;
        return v;
    }

    /// Advances past a field of the given wire type whose tag was already read,
    /// so an unrecognized field never derails the parse.
    fn skip(r: *Reader, wire: Wire) Error!void {
        switch (wire) {
            .varint => _ = try r.readVarint(),
            .i64 => _ = try r.readFixed64(),
            .len => _ = try r.readLen(),
            .i32 => _ = try r.readFixed32(),
            _ => return error.ModelRejected,
        }
    }
};

// Graph model. Shapes carry as i64 the way ONNX stores them; tensor data is
// dense row-major float32.

const Tensor = struct {
    dims: []const i64,
    data: []f32,

    fn elemCount(t: *const Tensor) usize {
        var n: usize = 1;
        for (t.dims) |d| n *= @intCast(@max(d, 0));
        return n;
    }
};

const Attr = struct {
    name: []const u8,
    i: i64 = 0,
    f: f32 = 0,
    ints: []const i64 = &.{},
    floats: []const f32 = &.{},
    t: ?Tensor = null,
    s: []const u8 = &.{},
};

const Node = struct {
    op_type: []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
    attrs: []const Attr,

    fn attr(node: *const Node, name: []const u8) ?*const Attr {
        for (node.attrs) |*a| {
            if (std.mem.eql(u8, a.name, name)) return a;
        }
        return null;
    }

    fn attrInts(node: *const Node, name: []const u8) []const i64 {
        if (node.attr(name)) |a| return a.ints;
        return &.{};
    }

    fn attrInt(node: *const Node, name: []const u8, default: i64) i64 {
        if (node.attr(name)) |a| return a.i;
        return default;
    }

    fn attrFloat(node: *const Node, name: []const u8, default: f32) f32 {
        if (node.attr(name)) |a| return a.f;
        return default;
    }
};

const NamedTensor = struct { name: []const u8, tensor: Tensor };

const InputSlot = struct {
    name: []const u8,
    dims: []const i64,
    data: []f32,
};

// TensorProto data types that this engine reads (the float paths and the
// integer paths a shape/initializer uses). Anything else is rejected.

const DType = enum(i32) {
    float = 1,
    int32 = 6,
    int64 = 7,
    _,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    graph_arena: *std.heap.ArenaAllocator,
    run_arena: *std.heap.ArenaAllocator,

    nodes: []const Node,
    initializers: []const NamedTensor,
    inputs: []InputSlot,
    output_names: []const []const u8,
    /// The tensor table the last invoke produced, holding every output until
    /// the next invoke resets the run arena, the same lifetime the TFLite path
    /// gives its output slices.
    result_table: std.StringHashMapUnmanaged(Tensor) = .empty,

    /// Parses model_bytes into an executable graph. The bytes are copied into
    /// the graph arena, so the caller need not keep them.
    pub fn init(gpa: std.mem.Allocator, model_bytes: []const u8) Error!Engine {
        const graph_arena = gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        errdefer gpa.destroy(graph_arena);
        graph_arena.* = .init(gpa);
        errdefer graph_arena.deinit();

        const run_arena = gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        errdefer gpa.destroy(run_arena);
        run_arena.* = .init(gpa);
        errdefer run_arena.deinit();

        const arena = graph_arena.allocator();
        const parsed = try parseModel(arena, model_bytes);

        // A graph input backed by an initializer is a constant, not a fed
        // input; only the truly external inputs get a fed slot.
        var slots: std.ArrayList(InputSlot) = .empty;
        for (parsed.input_infos) |info| {
            var is_init = false;
            for (parsed.initializers) |ini| {
                if (std.mem.eql(u8, ini.name, info.name)) is_init = true;
            }
            if (is_init) continue;
            var count: usize = 1;
            for (info.dims) |d| count *= @intCast(@max(d, 1));
            const data = arena.alloc(f32, count) catch return error.OutOfMemory;
            @memset(data, 0);
            slots.append(arena, .{ .name = info.name, .dims = info.dims, .data = data }) catch return error.OutOfMemory;
        }
        if (slots.items.len == 0) return error.ModelRejected;
        if (parsed.output_names.len == 0) return error.ModelRejected;

        return .{
            .gpa = gpa,
            .graph_arena = graph_arena,
            .run_arena = run_arena,
            .nodes = parsed.nodes,
            .initializers = parsed.initializers,
            .inputs = slots.toOwnedSlice(arena) catch return error.OutOfMemory,
            .output_names = parsed.output_names,
        };
    }

    pub fn deinit(engine: *Engine) void {
        const gpa = engine.gpa;
        engine.run_arena.deinit();
        engine.graph_arena.deinit();
        gpa.destroy(engine.run_arena);
        gpa.destroy(engine.graph_arena);
        engine.* = undefined;
    }

    pub fn inputCount(engine: *const Engine) usize {
        return engine.inputs.len;
    }

    pub fn outputCount(engine: *const Engine) usize {
        return engine.output_names.len;
    }

    /// Writes one input tensor from raw float32 bytes. The length must match
    /// the declared input element count exactly, the same strictness the
    /// TFLite path applies, so a preprocessing mismatch fails loudly.
    pub fn writeInput(engine: *Engine, index: usize, bytes: []const u8) Error!void {
        if (index >= engine.inputs.len) return error.TensorMissing;
        const slot = &engine.inputs[index];
        if (bytes.len != slot.data.len * @sizeOf(f32)) return error.TensorShapeMismatch;
        @memcpy(std.mem.sliceAsBytes(slot.data), bytes);
    }

    pub fn invoke(engine: *Engine) Error!void {
        _ = engine.run_arena.reset(.retain_capacity);
        const ra = engine.run_arena.allocator();

        var table: std.StringHashMapUnmanaged(Tensor) = .empty;
        table.ensureTotalCapacity(ra, @intCast(engine.initializers.len + engine.inputs.len + engine.nodes.len + 4)) catch return error.OutOfMemory;
        for (engine.initializers) |ini| table.putAssumeCapacity(ini.name, ini.tensor);
        for (engine.inputs) |slot| table.putAssumeCapacity(slot.name, .{ .dims = slot.dims, .data = slot.data });

        for (engine.nodes) |*node| {
            try runNode(ra, node, &table);
        }

        // Every declared output must have been produced.
        for (engine.output_names) |name| {
            if (table.get(name) == null) return error.InvokeFailed;
        }
        engine.result_table = table;
    }

    pub fn outputFloats(engine: *const Engine, index: usize) Error![]const f32 {
        if (index >= engine.output_names.len) return error.TensorMissing;
        const t = engine.result_table.get(engine.output_names[index]) orelse return error.TensorMissing;
        return t.data;
    }

    pub fn inputDims(engine: *const Engine, index: usize, dims: []i32) Error![]i32 {
        if (index >= engine.inputs.len) return error.TensorMissing;
        const src = engine.inputs[index].dims;
        if (src.len > dims.len) return error.TensorShapeMismatch;
        for (dims[0..src.len], src) |*d, s| d.* = @intCast(s);
        return dims[0..src.len];
    }

    pub fn outputDims(engine: *const Engine, index: usize, dims: []i32) Error![]i32 {
        if (index >= engine.output_names.len) return error.TensorMissing;
        const t = engine.result_table.get(engine.output_names[index]) orelse return error.TensorMissing;
        if (t.dims.len > dims.len) return error.TensorShapeMismatch;
        for (dims[0..t.dims.len], t.dims) |*d, s| d.* = @intCast(s);
        return dims[0..t.dims.len];
    }
};

// Parsing.

const ValueInfo = struct { name: []const u8, dims: []const i64 };

const ParsedGraph = struct {
    nodes: []const Node,
    initializers: []const NamedTensor,
    input_infos: []const ValueInfo,
    output_names: []const []const u8,
};

fn parseModel(arena: std.mem.Allocator, bytes: []const u8) Error!ParsedGraph {
    // ModelProto: field 7 is the graph.
    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.field == 7 and tag.wire == .len) {
            return parseGraph(arena, try r.readLen());
        }
        try r.skip(tag.wire);
    }
    return error.ModelRejected;
}

fn parseGraph(arena: std.mem.Allocator, bytes: []const u8) Error!ParsedGraph {
    // GraphProto: 1 node, 5 initializer, 11 input, 12 output.
    var nodes: std.ArrayList(Node) = .empty;
    var inits: std.ArrayList(NamedTensor) = .empty;
    var input_infos: std.ArrayList(ValueInfo) = .empty;
    var outputs: std.ArrayList([]const u8) = .empty;

    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.wire != .len) {
            try r.skip(tag.wire);
            continue;
        }
        const sub = try r.readLen();
        switch (tag.field) {
            1 => nodes.append(arena, try parseNode(arena, sub)) catch return error.OutOfMemory,
            5 => inits.append(arena, try parseInitializer(arena, sub)) catch return error.OutOfMemory,
            11 => input_infos.append(arena, try parseValueInfo(arena, sub)) catch return error.OutOfMemory,
            12 => outputs.append(arena, try parseValueInfoName(sub)) catch return error.OutOfMemory,
            else => {},
        }
    }
    return .{
        .nodes = nodes.toOwnedSlice(arena) catch return error.OutOfMemory,
        .initializers = inits.toOwnedSlice(arena) catch return error.OutOfMemory,
        .input_infos = input_infos.toOwnedSlice(arena) catch return error.OutOfMemory,
        .output_names = outputs.toOwnedSlice(arena) catch return error.OutOfMemory,
    };
}

fn parseNode(arena: std.mem.Allocator, bytes: []const u8) Error!Node {
    // NodeProto: 1 input, 2 output, 4 op_type, 5 attribute.
    var inputs: std.ArrayList([]const u8) = .empty;
    var outputs: std.ArrayList([]const u8) = .empty;
    var attrs: std.ArrayList(Attr) = .empty;
    var op_type: []const u8 = &.{};

    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.wire != .len) {
            try r.skip(tag.wire);
            continue;
        }
        const sub = try r.readLen();
        switch (tag.field) {
            1 => inputs.append(arena, sub) catch return error.OutOfMemory,
            2 => outputs.append(arena, sub) catch return error.OutOfMemory,
            4 => op_type = sub,
            5 => attrs.append(arena, try parseAttr(arena, sub)) catch return error.OutOfMemory,
            else => {},
        }
    }
    return .{
        .op_type = op_type,
        .inputs = inputs.toOwnedSlice(arena) catch return error.OutOfMemory,
        .outputs = outputs.toOwnedSlice(arena) catch return error.OutOfMemory,
        .attrs = attrs.toOwnedSlice(arena) catch return error.OutOfMemory,
    };
}

fn parseAttr(arena: std.mem.Allocator, bytes: []const u8) Error!Attr {
    // AttributeProto: 1 name, 2 f, 3 i, 4 s, 5 t, 7 floats, 8 ints.
    var attr: Attr = .{ .name = &.{} };
    var floats: std.ArrayList(f32) = .empty;
    var ints: std.ArrayList(i64) = .empty;

    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        switch (tag.field) {
            1 => if (tag.wire == .len) {
                attr.name = try r.readLen();
            } else try r.skip(tag.wire),
            2 => if (tag.wire == .i32) {
                attr.f = @bitCast(try r.readFixed32());
            } else try r.skip(tag.wire),
            3 => if (tag.wire == .varint) {
                attr.i = @bitCast(try r.readVarint());
            } else try r.skip(tag.wire),
            4 => if (tag.wire == .len) {
                attr.s = try r.readLen();
            } else try r.skip(tag.wire),
            5 => if (tag.wire == .len) {
                attr.t = try parseInitializerTensor(arena, try r.readLen());
            } else try r.skip(tag.wire),
            7 => if (tag.wire == .len) {
                // packed repeated float
                var pr: Reader = .{ .buf = try r.readLen() };
                while (!pr.atEnd()) floats.append(arena, @bitCast(try pr.readFixed32())) catch return error.OutOfMemory;
            } else if (tag.wire == .i32) {
                floats.append(arena, @bitCast(try r.readFixed32())) catch return error.OutOfMemory;
            } else try r.skip(tag.wire),
            8 => if (tag.wire == .len) {
                var pr: Reader = .{ .buf = try r.readLen() };
                while (!pr.atEnd()) ints.append(arena, @bitCast(try pr.readVarint())) catch return error.OutOfMemory;
            } else if (tag.wire == .varint) {
                ints.append(arena, @bitCast(try r.readVarint())) catch return error.OutOfMemory;
            } else try r.skip(tag.wire),
            else => try r.skip(tag.wire),
        }
    }
    attr.floats = floats.toOwnedSlice(arena) catch return error.OutOfMemory;
    attr.ints = ints.toOwnedSlice(arena) catch return error.OutOfMemory;
    return attr;
}

fn parseInitializer(arena: std.mem.Allocator, bytes: []const u8) Error!NamedTensor {
    const t = try parseInitializerTensor(arena, bytes);
    // TensorProto: field 8 is the name.
    var r: Reader = .{ .buf = bytes };
    var name: []const u8 = &.{};
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.field == 8 and tag.wire == .len) {
            name = try r.readLen();
        } else try r.skip(tag.wire);
    }
    return .{ .name = name, .tensor = t };
}

/// Reads a TensorProto's shape and data into a dense float tensor. Float
/// initializers arrive either as packed float_data (field 4) or little-endian
/// raw_data (field 9); int64/int32 shapes arrive the same way and widen to
/// float so a Reshape target reads uniformly.
fn parseInitializerTensor(arena: std.mem.Allocator, bytes: []const u8) Error!Tensor {
    var dims: std.ArrayList(i64) = .empty;
    var dtype: DType = .float;
    var float_data: []const u8 = &.{};
    var raw_data: []const u8 = &.{};
    var int64_data: std.ArrayList(i64) = .empty;
    var int32_data: std.ArrayList(i64) = .empty;

    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        switch (tag.field) {
            1 => if (tag.wire == .len) {
                var pr: Reader = .{ .buf = try r.readLen() };
                while (!pr.atEnd()) dims.append(arena, @bitCast(try pr.readVarint())) catch return error.OutOfMemory;
            } else if (tag.wire == .varint) {
                dims.append(arena, @bitCast(try r.readVarint())) catch return error.OutOfMemory;
            } else try r.skip(tag.wire),
            2 => if (tag.wire == .varint) {
                dtype = @enumFromInt(@as(i32, @intCast(try r.readVarint())));
            } else try r.skip(tag.wire),
            4 => if (tag.wire == .len) {
                float_data = try r.readLen();
            } else try r.skip(tag.wire),
            6 => if (tag.wire == .len) {
                var pr: Reader = .{ .buf = try r.readLen() };
                while (!pr.atEnd()) int32_data.append(arena, @intCast(@as(i64, @bitCast(try pr.readVarint())))) catch return error.OutOfMemory;
            } else try r.skip(tag.wire),
            7 => if (tag.wire == .len) {
                var pr: Reader = .{ .buf = try r.readLen() };
                while (!pr.atEnd()) int64_data.append(arena, @bitCast(try pr.readVarint())) catch return error.OutOfMemory;
            } else try r.skip(tag.wire),
            9 => if (tag.wire == .len) {
                raw_data = try r.readLen();
            } else try r.skip(tag.wire),
            else => try r.skip(tag.wire),
        }
    }

    const shape = dims.toOwnedSlice(arena) catch return error.OutOfMemory;
    var count: usize = 1;
    for (shape) |d| count *= @intCast(@max(d, 0));
    if (shape.len == 0) count = 1;

    const data = arena.alloc(f32, count) catch return error.OutOfMemory;
    switch (dtype) {
        .float => {
            if (float_data.len >= count * 4) {
                for (0..count) |i| data[i] = @bitCast(std.mem.readInt(u32, float_data[i * 4 ..][0..4], .little));
            } else if (raw_data.len >= count * 4) {
                for (0..count) |i| data[i] = @bitCast(std.mem.readInt(u32, raw_data[i * 4 ..][0..4], .little));
            } else return error.ModelRejected;
        },
        .int64 => {
            if (int64_data.items.len >= count) {
                for (0..count) |i| data[i] = @floatFromInt(int64_data.items[i]);
            } else if (raw_data.len >= count * 8) {
                for (0..count) |i| data[i] = @floatFromInt(std.mem.readInt(i64, raw_data[i * 8 ..][0..8], .little));
            } else return error.ModelRejected;
        },
        .int32 => {
            if (int32_data.items.len >= count) {
                for (0..count) |i| data[i] = @floatFromInt(int32_data.items[i]);
            } else if (raw_data.len >= count * 4) {
                for (0..count) |i| data[i] = @floatFromInt(std.mem.readInt(i32, raw_data[i * 4 ..][0..4], .little));
            } else return error.ModelRejected;
        },
        else => return error.ModelRejected,
    }
    return .{ .dims = shape, .data = data };
}

fn parseValueInfo(arena: std.mem.Allocator, bytes: []const u8) Error!ValueInfo {
    // ValueInfoProto: 1 name, 2 type (TypeProto). Dims come from
    // type.tensor_type.shape; a missing or symbolic dim reads as 1.
    var name: []const u8 = &.{};
    var dims: []const i64 = &.{};
    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.field == 1 and tag.wire == .len) {
            name = try r.readLen();
        } else if (tag.field == 2 and tag.wire == .len) {
            dims = try parseTypeDims(arena, try r.readLen());
        } else try r.skip(tag.wire);
    }
    return .{ .name = name, .dims = dims };
}

fn parseValueInfoName(bytes: []const u8) Error![]const u8 {
    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.field == 1 and tag.wire == .len) return r.readLen();
        try r.skip(tag.wire);
    }
    return error.ModelRejected;
}

fn parseTypeDims(arena: std.mem.Allocator, bytes: []const u8) Error![]const i64 {
    // TypeProto: field 1 tensor_type (TypeProto.Tensor).
    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.field == 1 and tag.wire == .len) {
            return parseTensorTypeDims(arena, try r.readLen());
        }
        try r.skip(tag.wire);
    }
    return &.{};
}

fn parseTensorTypeDims(arena: std.mem.Allocator, bytes: []const u8) Error![]const i64 {
    // Tensor: field 2 shape (TensorShapeProto).
    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.field == 2 and tag.wire == .len) {
            return parseShape(arena, try r.readLen());
        }
        try r.skip(tag.wire);
    }
    return &.{};
}

fn parseShape(arena: std.mem.Allocator, bytes: []const u8) Error![]const i64 {
    // TensorShapeProto: field 1 dim (repeated Dimension).
    var dims: std.ArrayList(i64) = .empty;
    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.field == 1 and tag.wire == .len) {
            const dim_val = try parseDim(try r.readLen());
            dims.append(arena, dim_val) catch return error.OutOfMemory;
        } else try r.skip(tag.wire);
    }
    return dims.toOwnedSlice(arena) catch return error.OutOfMemory;
}

fn parseDim(bytes: []const u8) Error!i64 {
    // Dimension: field 1 dim_value (int64). A symbolic dim (dim_param) has no
    // value and reads as 1 so a fed input still has a concrete shape.
    var r: Reader = .{ .buf = bytes };
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.field == 1 and tag.wire == .varint) {
            return @bitCast(try r.readVarint());
        }
        try r.skip(tag.wire);
    }
    return 1;
}

// Execution.

fn get(table: *const std.StringHashMapUnmanaged(Tensor), name: []const u8) Error!Tensor {
    return table.get(name) orelse error.TensorMissing;
}

fn newTensor(ra: std.mem.Allocator, dims: []const i64) Error!Tensor {
    var count: usize = 1;
    for (dims) |d| count *= @intCast(@max(d, 0));
    if (dims.len == 0) count = 1;
    const data = ra.alloc(f32, count) catch return error.OutOfMemory;
    const owned_dims = ra.dupe(i64, dims) catch return error.OutOfMemory;
    return .{ .dims = owned_dims, .data = data };
}

fn runNode(ra: std.mem.Allocator, node: *const Node, table: *std.StringHashMapUnmanaged(Tensor)) Error!void {
    const op = node.op_type;
    const out = try dispatch(ra, node, table);
    if (node.outputs.len == 0) return error.InvokeFailed;
    _ = op;
    table.put(ra, node.outputs[0], out) catch return error.OutOfMemory;
}

fn dispatch(ra: std.mem.Allocator, node: *const Node, table: *std.StringHashMapUnmanaged(Tensor)) Error!Tensor {
    const op = node.op_type;
    if (eq(op, "Relu")) return unary(ra, try in(table, node, 0), reluScalar);
    if (eq(op, "Sigmoid")) return unary(ra, try in(table, node, 0), sigmoidScalar);
    if (eq(op, "Tanh")) return unary(ra, try in(table, node, 0), tanhScalar);
    if (eq(op, "Exp")) return unary(ra, try in(table, node, 0), expScalar);
    if (eq(op, "Sqrt")) return unary(ra, try in(table, node, 0), sqrtScalar);
    if (eq(op, "LeakyRelu")) return leakyRelu(ra, try in(table, node, 0), node.attrFloat("alpha", 0.01));
    if (eq(op, "Clip")) return clip(ra, node, table);
    if (eq(op, "Add")) return binary(ra, try in(table, node, 0), try in(table, node, 1), addScalar);
    if (eq(op, "Sub")) return binary(ra, try in(table, node, 0), try in(table, node, 1), subScalar);
    if (eq(op, "Mul")) return binary(ra, try in(table, node, 0), try in(table, node, 1), mulScalar);
    if (eq(op, "Div")) return binary(ra, try in(table, node, 0), try in(table, node, 1), divScalar);
    if (eq(op, "Gemm")) return gemm(ra, node, table);
    if (eq(op, "MatMul")) return matmul(ra, try in(table, node, 0), try in(table, node, 1));
    if (eq(op, "Conv")) return conv(ra, node, table);
    if (eq(op, "MaxPool")) return pool(ra, node, table, .max);
    if (eq(op, "AveragePool")) return pool(ra, node, table, .avg);
    if (eq(op, "GlobalAveragePool")) return globalAvgPool(ra, try in(table, node, 0));
    if (eq(op, "BatchNormalization")) return batchNorm(ra, node, table);
    if (eq(op, "Concat")) return concat(ra, node, table);
    if (eq(op, "Softmax")) return softmax(ra, try in(table, node, 0), node.attrInt("axis", -1));
    if (eq(op, "Reshape")) return reshape(ra, try in(table, node, 0), try in(table, node, 1));
    if (eq(op, "Flatten")) return flatten(ra, try in(table, node, 0), node.attrInt("axis", 1));
    if (eq(op, "Transpose")) return transpose(ra, node, try in(table, node, 0));
    if (eq(op, "Identity")) return copyTensor(ra, try in(table, node, 0));
    return error.UnsupportedOp;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn in(table: *const std.StringHashMapUnmanaged(Tensor), node: *const Node, idx: usize) Error!Tensor {
    if (idx >= node.inputs.len) return error.TensorMissing;
    return get(table, node.inputs[idx]);
}

fn copyTensor(ra: std.mem.Allocator, t: Tensor) Error!Tensor {
    const out = try newTensor(ra, t.dims);
    @memcpy(out.data, t.data);
    return out;
}

// ---- elementwise ----

fn reluScalar(x: f32) f32 {
    return @max(x, 0);
}
fn sigmoidScalar(x: f32) f32 {
    return 1.0 / (1.0 + @exp(-x));
}
fn tanhScalar(x: f32) f32 {
    return std.math.tanh(x);
}
fn expScalar(x: f32) f32 {
    return @exp(x);
}
fn sqrtScalar(x: f32) f32 {
    return @sqrt(x);
}
fn addScalar(a: f32, b: f32) f32 {
    return a + b;
}
fn subScalar(a: f32, b: f32) f32 {
    return a - b;
}
fn mulScalar(a: f32, b: f32) f32 {
    return a * b;
}
fn divScalar(a: f32, b: f32) f32 {
    return a / b;
}

fn unary(ra: std.mem.Allocator, x: Tensor, comptime f: fn (f32) f32) Error!Tensor {
    const out = try newTensor(ra, x.dims);
    for (out.data, x.data) |*o, v| o.* = f(v);
    return out;
}

fn leakyRelu(ra: std.mem.Allocator, x: Tensor, alpha: f32) Error!Tensor {
    const out = try newTensor(ra, x.dims);
    for (out.data, x.data) |*o, v| o.* = if (v >= 0) v else v * alpha;
    return out;
}

fn clip(ra: std.mem.Allocator, node: *const Node, table: *std.StringHashMapUnmanaged(Tensor)) Error!Tensor {
    const x = try in(table, node, 0);
    // min/max arrive as inputs (opset 11+) or as attributes (opset 6).
    var lo: f32 = node.attrFloat("min", -std.math.inf(f32));
    var hi: f32 = node.attrFloat("max", std.math.inf(f32));
    if (node.inputs.len > 1 and node.inputs[1].len != 0) {
        if (table.get(node.inputs[1])) |t| {
            if (t.data.len > 0) lo = t.data[0];
        }
    }
    if (node.inputs.len > 2 and node.inputs[2].len != 0) {
        if (table.get(node.inputs[2])) |t| {
            if (t.data.len > 0) hi = t.data[0];
        }
    }
    const out = try newTensor(ra, x.dims);
    for (out.data, x.data) |*o, v| o.* = std.math.clamp(v, lo, hi);
    return out;
}

// ---- broadcasting binary ----

/// NumPy-style broadcasting for elementwise binary ops: shapes align from the
/// right, and any axis of extent one stretches to the other operand.
fn binary(ra: std.mem.Allocator, a: Tensor, b: Tensor, comptime f: fn (f32, f32) f32) Error!Tensor {
    const rank = @max(a.dims.len, b.dims.len);
    var shape = ra.alloc(i64, rank) catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < rank) : (i += 1) {
        const ad = dimFromRight(a.dims, i);
        const bd = dimFromRight(b.dims, i);
        if (ad != bd and ad != 1 and bd != 1) return error.TensorShapeMismatch;
        shape[rank - 1 - i] = @max(ad, bd);
    }
    const out = try newTensor(ra, shape);

    const strides_a = ra.alloc(usize, rank) catch return error.OutOfMemory;
    const strides_b = ra.alloc(usize, rank) catch return error.OutOfMemory;
    fillBroadcastStrides(a.dims, rank, shape, strides_a);
    fillBroadcastStrides(b.dims, rank, shape, strides_b);

    const idx = ra.alloc(usize, rank) catch return error.OutOfMemory;
    @memset(idx, 0);
    for (out.data) |*o| {
        var oa: usize = 0;
        var ob: usize = 0;
        for (0..rank) |d| {
            oa += idx[d] * strides_a[d];
            ob += idx[d] * strides_b[d];
        }
        o.* = f(a.data[oa], b.data[ob]);
        incrementIndex(idx, shape);
    }
    return out;
}

fn dimFromRight(dims: []const i64, from_right: usize) i64 {
    if (from_right >= dims.len) return 1;
    return @max(dims[dims.len - 1 - from_right], 1);
}

fn fillBroadcastStrides(dims: []const i64, rank: usize, shape: []const i64, out: []usize) void {
    // Row-major strides over the operand's own shape, zeroed on any axis it
    // broadcasts (extent one against a larger output axis).
    var acc: usize = 1;
    var i: usize = 0;
    while (i < rank) : (i += 1) {
        const axis = rank - 1 - i;
        const d = dimFromRight(dims, i);
        if (d == 1 and shape[axis] != 1) {
            out[axis] = 0;
        } else {
            out[axis] = acc;
        }
        acc *= @intCast(@max(d, 1));
    }
}

fn incrementIndex(idx: []usize, shape: []const i64) void {
    var d: usize = idx.len;
    while (d > 0) {
        d -= 1;
        idx[d] += 1;
        if (idx[d] < @as(usize, @intCast(shape[d]))) return;
        idx[d] = 0;
    }
}

// ---- matmul / gemm ----

fn matmul2d(ra: std.mem.Allocator, a: []const f32, b: []const f32, m: usize, k: usize, n: usize) Error![]f32 {
    const out = ra.alloc(f32, m * n) catch return error.OutOfMemory;
    @memset(out, 0);
    for (0..m) |row| {
        for (0..k) |p| {
            const av = a[row * k + p];
            const b_row = b[p * n ..][0..n];
            const o_row = out[row * n ..][0..n];
            for (0..n) |col| o_row[col] += av * b_row[col];
        }
    }
    return out;
}

fn matmul(ra: std.mem.Allocator, a: Tensor, b: Tensor) Error!Tensor {
    if (a.dims.len != 2 or b.dims.len != 2) return error.TensorShapeMismatch;
    const m: usize = @intCast(a.dims[0]);
    const k: usize = @intCast(a.dims[1]);
    if (@as(usize, @intCast(b.dims[0])) != k) return error.TensorShapeMismatch;
    const n: usize = @intCast(b.dims[1]);
    const data = try matmul2d(ra, a.data, b.data, m, k, n);
    const out: Tensor = .{ .dims = ra.dupe(i64, &.{ @intCast(m), @intCast(n) }) catch return error.OutOfMemory, .data = data };
    return out;
}

fn gemm(ra: std.mem.Allocator, node: *const Node, table: *std.StringHashMapUnmanaged(Tensor)) Error!Tensor {
    const a = try in(table, node, 0);
    const b = try in(table, node, 1);
    if (a.dims.len != 2 or b.dims.len != 2) return error.TensorShapeMismatch;
    const alpha = node.attrFloat("alpha", 1.0);
    const beta = node.attrFloat("beta", 1.0);
    const trans_a = node.attrInt("transA", 0) != 0;
    const trans_b = node.attrInt("transB", 0) != 0;

    const m: usize = @intCast(if (trans_a) a.dims[1] else a.dims[0]);
    const k: usize = @intCast(if (trans_a) a.dims[0] else a.dims[1]);
    const n: usize = @intCast(if (trans_b) b.dims[0] else b.dims[1]);
    const kb: usize = @intCast(if (trans_b) b.dims[1] else b.dims[0]);
    if (k != kb) return error.TensorShapeMismatch;

    const a_eff = if (trans_a) try transpose2d(ra, a.data, @intCast(a.dims[0]), @intCast(a.dims[1])) else a.data;
    const b_eff = if (trans_b) try transpose2d(ra, b.data, @intCast(b.dims[0]), @intCast(b.dims[1])) else b.data;
    const prod = try matmul2d(ra, a_eff, b_eff, m, k, n);

    const out = try newTensor(ra, &.{ @intCast(m), @intCast(n) });
    if (node.inputs.len > 2 and node.inputs[2].len != 0) {
        const cbias = try get(table, node.inputs[2]);
        for (0..m) |row| {
            for (0..n) |col| {
                const c_val = biasElem(cbias, row, col, m, n);
                out.data[row * n + col] = alpha * prod[row * n + col] + beta * c_val;
            }
        }
    } else {
        for (out.data, prod) |*o, p| o.* = alpha * p;
    }
    return out;
}

fn biasElem(c: Tensor, row: usize, col: usize, m: usize, n: usize) f32 {
    // C broadcasts from (n,), (1,n), (m,1) or (m,n).
    if (c.data.len == n) return c.data[col];
    if (c.data.len == m) return c.data[row];
    if (c.data.len == 1) return c.data[0];
    if (c.data.len == m * n) return c.data[row * n + col];
    return 0;
}

fn transpose2d(ra: std.mem.Allocator, data: []const f32, rows: usize, cols: usize) Error![]f32 {
    const out = ra.alloc(f32, rows * cols) catch return error.OutOfMemory;
    for (0..rows) |r| {
        for (0..cols) |c| out[c * rows + r] = data[r * cols + c];
    }
    return out;
}

// ---- convolution (NCHW) ----

fn conv(ra: std.mem.Allocator, node: *const Node, table: *std.StringHashMapUnmanaged(Tensor)) Error!Tensor {
    const x = try in(table, node, 0); // [N, C, H, W]
    const w = try in(table, node, 1); // [M, C/group, kH, kW]
    if (x.dims.len != 4 or w.dims.len != 4) return error.TensorShapeMismatch;

    const n: usize = @intCast(x.dims[0]);
    const c: usize = @intCast(x.dims[1]);
    const h: usize = @intCast(x.dims[2]);
    const wd: usize = @intCast(x.dims[3]);
    const m: usize = @intCast(w.dims[0]);
    const cpg: usize = @intCast(w.dims[1]);
    const kh: usize = @intCast(w.dims[2]);
    const kw: usize = @intCast(w.dims[3]);

    const group: usize = @intCast(node.attrInt("group", 1));
    if (group == 0 or c % group != 0 or m % group != 0 or cpg != c / group) return error.TensorShapeMismatch;

    const strides = node.attrInts("strides");
    const sh: usize = if (strides.len >= 2) @intCast(strides[0]) else 1;
    const sw: usize = if (strides.len >= 2) @intCast(strides[1]) else 1;
    const dil = node.attrInts("dilations");
    const dh: usize = if (dil.len >= 2) @intCast(dil[0]) else 1;
    const dw: usize = if (dil.len >= 2) @intCast(dil[1]) else 1;
    const pads = node.attrInts("pads");
    const pt: i64 = if (pads.len >= 4) pads[0] else 0;
    const pl: i64 = if (pads.len >= 4) pads[1] else 0;
    const pb: i64 = if (pads.len >= 4) pads[2] else 0;
    const pr: i64 = if (pads.len >= 4) pads[3] else 0;

    const oh: usize = @intCast(@divFloor(@as(i64, @intCast(h)) + pt + pb - (@as(i64, @intCast(dh)) * (@as(i64, @intCast(kh)) - 1) + 1), @as(i64, @intCast(sh))) + 1);
    const ow: usize = @intCast(@divFloor(@as(i64, @intCast(wd)) + pl + pr - (@as(i64, @intCast(dw)) * (@as(i64, @intCast(kw)) - 1) + 1), @as(i64, @intCast(sw))) + 1);

    var bias: ?Tensor = null;
    if (node.inputs.len > 2 and node.inputs[2].len != 0) bias = try get(table, node.inputs[2]);

    const out = try newTensor(ra, &.{ @intCast(n), @intCast(m), @intCast(oh), @intCast(ow) });
    const mpg = m / group; // output channels per group

    for (0..n) |ni| {
        for (0..group) |g| {
            for (0..mpg) |mi| {
                const oc = g * mpg + mi;
                const bias_v: f32 = if (bias) |bt| bt.data[oc] else 0;
                for (0..oh) |oy| {
                    for (0..ow) |ox| {
                        var acc: f32 = bias_v;
                        for (0..cpg) |ci| {
                            const ic = g * cpg + ci;
                            for (0..kh) |ky| {
                                const iy = @as(i64, @intCast(oy * sh + ky * dh)) - pt;
                                if (iy < 0 or iy >= @as(i64, @intCast(h))) continue;
                                for (0..kw) |kx| {
                                    const ix = @as(i64, @intCast(ox * sw + kx * dw)) - pl;
                                    if (ix < 0 or ix >= @as(i64, @intCast(wd))) continue;
                                    const xv = x.data[((ni * c + ic) * h + @as(usize, @intCast(iy))) * wd + @as(usize, @intCast(ix))];
                                    const wv = w.data[((oc * cpg + ci) * kh + ky) * kw + kx];
                                    acc += xv * wv;
                                }
                            }
                        }
                        out.data[((ni * m + oc) * oh + oy) * ow + ox] = acc;
                    }
                }
            }
        }
    }
    return out;
}

// ---- pooling (NCHW) ----

const PoolKind = enum { max, avg };

fn pool(ra: std.mem.Allocator, node: *const Node, table: *std.StringHashMapUnmanaged(Tensor), kind: PoolKind) Error!Tensor {
    const x = try in(table, node, 0);
    if (x.dims.len != 4) return error.TensorShapeMismatch;
    const n: usize = @intCast(x.dims[0]);
    const c: usize = @intCast(x.dims[1]);
    const h: usize = @intCast(x.dims[2]);
    const wd: usize = @intCast(x.dims[3]);

    const ks = node.attrInts("kernel_shape");
    if (ks.len < 2) return error.TensorShapeMismatch;
    const kh: usize = @intCast(ks[0]);
    const kw: usize = @intCast(ks[1]);
    const strides = node.attrInts("strides");
    const sh: usize = if (strides.len >= 2) @intCast(strides[0]) else 1;
    const sw: usize = if (strides.len >= 2) @intCast(strides[1]) else 1;
    const pads = node.attrInts("pads");
    const pt: i64 = if (pads.len >= 4) pads[0] else 0;
    const pl: i64 = if (pads.len >= 4) pads[1] else 0;
    const pb: i64 = if (pads.len >= 4) pads[2] else 0;
    const prr: i64 = if (pads.len >= 4) pads[3] else 0;

    const oh: usize = @intCast(@divFloor(@as(i64, @intCast(h)) + pt + pb - @as(i64, @intCast(kh)), @as(i64, @intCast(sh))) + 1);
    const ow: usize = @intCast(@divFloor(@as(i64, @intCast(wd)) + pl + prr - @as(i64, @intCast(kw)), @as(i64, @intCast(sw))) + 1);

    const out = try newTensor(ra, &.{ @intCast(n), @intCast(c), @intCast(oh), @intCast(ow) });
    for (0..n) |ni| {
        for (0..c) |ci| {
            for (0..oh) |oy| {
                for (0..ow) |ox| {
                    var acc: f32 = if (kind == .max) -std.math.inf(f32) else 0;
                    var counted: usize = 0;
                    for (0..kh) |ky| {
                        const iy = @as(i64, @intCast(oy * sh + ky)) - pt;
                        if (iy < 0 or iy >= @as(i64, @intCast(h))) continue;
                        for (0..kw) |kx| {
                            const ix = @as(i64, @intCast(ox * sw + kx)) - pl;
                            if (ix < 0 or ix >= @as(i64, @intCast(wd))) continue;
                            const v = x.data[((ni * c + ci) * h + @as(usize, @intCast(iy))) * wd + @as(usize, @intCast(ix))];
                            if (kind == .max) acc = @max(acc, v) else acc += v;
                            counted += 1;
                        }
                    }
                    out.data[((ni * c + ci) * oh + oy) * ow + ox] = if (kind == .avg and counted > 0) acc / @as(f32, @floatFromInt(counted)) else acc;
                }
            }
        }
    }
    return out;
}

fn globalAvgPool(ra: std.mem.Allocator, x: Tensor) Error!Tensor {
    if (x.dims.len != 4) return error.TensorShapeMismatch;
    const n: usize = @intCast(x.dims[0]);
    const c: usize = @intCast(x.dims[1]);
    const h: usize = @intCast(x.dims[2]);
    const wd: usize = @intCast(x.dims[3]);
    const out = try newTensor(ra, &.{ @intCast(n), @intCast(c), 1, 1 });
    const plane = h * wd;
    for (0..n) |ni| {
        for (0..c) |ci| {
            var acc: f32 = 0;
            const base = (ni * c + ci) * plane;
            for (0..plane) |p| acc += x.data[base + p];
            out.data[ni * c + ci] = acc / @as(f32, @floatFromInt(plane));
        }
    }
    return out;
}

fn batchNorm(ra: std.mem.Allocator, node: *const Node, table: *std.StringHashMapUnmanaged(Tensor)) Error!Tensor {
    const x = try in(table, node, 0);
    const scale = try in(table, node, 1);
    const bias = try in(table, node, 2);
    const mean = try in(table, node, 3);
    const varr = try in(table, node, 4);
    if (x.dims.len < 2) return error.TensorShapeMismatch;
    const eps = node.attrFloat("epsilon", 1e-5);
    const channels: usize = @intCast(x.dims[1]);
    var plane: usize = 1;
    for (x.dims[2..]) |d| plane *= @intCast(@max(d, 1));
    const batch: usize = @intCast(x.dims[0]);

    const out = try newTensor(ra, x.dims);
    for (0..batch) |b| {
        for (0..channels) |ch| {
            const inv = 1.0 / @sqrt(varr.data[ch] + eps);
            const sc = scale.data[ch] * inv;
            const bi = bias.data[ch] - mean.data[ch] * sc;
            const base = (b * channels + ch) * plane;
            for (0..plane) |p| out.data[base + p] = x.data[base + p] * sc + bi;
        }
    }
    return out;
}

// ---- shape ops ----

fn concat(ra: std.mem.Allocator, node: *const Node, table: *std.StringHashMapUnmanaged(Tensor)) Error!Tensor {
    if (node.inputs.len == 0) return error.TensorMissing;
    const first = try get(table, node.inputs[0]);
    const rank = first.dims.len;
    var axis = node.attrInt("axis", 0);
    if (axis < 0) axis += @intCast(rank);
    const ax: usize = @intCast(axis);
    if (ax >= rank) return error.TensorShapeMismatch;

    var out_dim: i64 = 0;
    for (node.inputs) |name| {
        const t = try get(table, name);
        if (t.dims.len != rank) return error.TensorShapeMismatch;
        out_dim += t.dims[ax];
    }
    var shape = ra.dupe(i64, first.dims) catch return error.OutOfMemory;
    shape[ax] = out_dim;
    const out = try newTensor(ra, shape);

    // outer product of dims before the axis, inner of dims after.
    var outer: usize = 1;
    for (0..ax) |d| outer *= @intCast(@max(first.dims[d], 1));
    var inner: usize = 1;
    for (ax + 1..rank) |d| inner *= @intCast(@max(first.dims[d], 1));
    const out_axis: usize = @intCast(out_dim);

    var written_axis: usize = 0;
    for (node.inputs) |name| {
        const t = try get(table, name);
        const this_axis: usize = @intCast(t.dims[ax]);
        for (0..outer) |o| {
            for (0..this_axis) |a| {
                const src = (o * this_axis + a) * inner;
                const dst = (o * out_axis + written_axis + a) * inner;
                @memcpy(out.data[dst .. dst + inner], t.data[src .. src + inner]);
            }
        }
        written_axis += this_axis;
    }
    return out;
}

fn reshape(ra: std.mem.Allocator, x: Tensor, shape_t: Tensor) Error!Tensor {
    const total = x.data.len;
    var dims = ra.alloc(i64, shape_t.data.len) catch return error.OutOfMemory;
    var minus_one: ?usize = null;
    var known: usize = 1;
    for (shape_t.data, 0..) |v, i| {
        const d: i64 = @intFromFloat(v);
        if (d == -1) {
            minus_one = i;
            dims[i] = 1;
        } else if (d == 0) {
            dims[i] = x.dims[i];
            known *= @intCast(@max(dims[i], 1));
        } else {
            dims[i] = d;
            known *= @intCast(@max(d, 1));
        }
    }
    if (minus_one) |i| dims[i] = @intCast(total / @max(known, 1));
    const out: Tensor = .{ .dims = dims, .data = ra.alloc(f32, total) catch return error.OutOfMemory };
    @memcpy(out.data, x.data);
    return out;
}

fn flatten(ra: std.mem.Allocator, x: Tensor, axis_in: i64) Error!Tensor {
    var axis = axis_in;
    if (axis < 0) axis += @intCast(x.dims.len);
    const ax: usize = @intCast(axis);
    var rows: usize = 1;
    for (0..ax) |d| rows *= @intCast(@max(x.dims[d], 1));
    var cols: usize = 1;
    for (ax..x.dims.len) |d| cols *= @intCast(@max(x.dims[d], 1));
    const out: Tensor = .{ .dims = ra.dupe(i64, &.{ @intCast(rows), @intCast(cols) }) catch return error.OutOfMemory, .data = ra.alloc(f32, x.data.len) catch return error.OutOfMemory };
    @memcpy(out.data, x.data);
    return out;
}

fn transpose(ra: std.mem.Allocator, node: *const Node, x: Tensor) Error!Tensor {
    const rank = x.dims.len;
    const perm_attr = node.attrInts("perm");
    var perm = ra.alloc(usize, rank) catch return error.OutOfMemory;
    if (perm_attr.len == rank) {
        for (perm, perm_attr) |*p, v| p.* = @intCast(v);
    } else {
        for (0..rank) |i| perm[i] = rank - 1 - i; // default reverses the axes
    }
    var shape = ra.alloc(i64, rank) catch return error.OutOfMemory;
    for (0..rank) |i| shape[i] = x.dims[perm[i]];
    const out = try newTensor(ra, shape);

    // strides of the source in row-major order.
    var src_strides = ra.alloc(usize, rank) catch return error.OutOfMemory;
    var acc: usize = 1;
    var d: usize = rank;
    while (d > 0) {
        d -= 1;
        src_strides[d] = acc;
        acc *= @intCast(@max(x.dims[d], 1));
    }

    const idx = ra.alloc(usize, rank) catch return error.OutOfMemory;
    @memset(idx, 0);
    for (out.data) |*o| {
        var src: usize = 0;
        for (0..rank) |i| src += idx[i] * src_strides[perm[i]];
        o.* = x.data[src];
        incrementIndex(idx, shape);
    }
    return out;
}

fn softmax(ra: std.mem.Allocator, x: Tensor, axis_in: i64) Error!Tensor {
    var axis = axis_in;
    if (axis < 0) axis += @intCast(x.dims.len);
    const ax: usize = @intCast(axis);
    const out = try newTensor(ra, x.dims);

    var outer: usize = 1;
    for (0..ax) |d| outer *= @intCast(@max(x.dims[d], 1));
    const along: usize = @intCast(@max(x.dims[ax], 1));
    var inner: usize = 1;
    for (ax + 1..x.dims.len) |d| inner *= @intCast(@max(x.dims[d], 1));

    for (0..outer) |o| {
        for (0..inner) |i| {
            var maxv: f32 = -std.math.inf(f32);
            for (0..along) |a| {
                const v = x.data[(o * along + a) * inner + i];
                maxv = @max(maxv, v);
            }
            var sum: f32 = 0;
            for (0..along) |a| {
                const e = @exp(x.data[(o * along + a) * inner + i] - maxv);
                out.data[(o * along + a) * inner + i] = e;
                sum += e;
            }
            for (0..along) |a| out.data[(o * along + a) * inner + i] /= sum;
        }
    }
    return out;
}

// Tests. Each builds a tiny ONNX model by hand so the expected output is exact,
// with no external tooling or reference runtime in the loop.

const testing = std.testing;

const Pb = struct {
    buf: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn tag(p: *Pb, field: u32, wire: u3) void {
        p.varint((@as(u64, field) << 3) | wire);
    }
    fn varint(p: *Pb, v_in: u64) void {
        var v = v_in;
        while (true) {
            var byte: u8 = @truncate(v & 0x7f);
            v >>= 7;
            if (v != 0) byte |= 0x80;
            p.buf.append(p.a, byte) catch unreachable;
            if (v == 0) break;
        }
    }
    fn f32field(p: *Pb, field: u32, value: f32) void {
        p.tag(field, 5);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(value), .little);
        p.buf.appendSlice(p.a, &b) catch unreachable;
    }
    fn varintField(p: *Pb, field: u32, value: i64) void {
        p.tag(field, 0);
        p.varint(@bitCast(value));
    }
    fn bytesField(p: *Pb, field: u32, value: []const u8) void {
        p.tag(field, 2);
        p.varint(value.len);
        p.buf.appendSlice(p.a, value) catch unreachable;
    }
    fn slice(p: *Pb) []const u8 {
        return p.buf.items;
    }
};

fn tensorProto(a: std.mem.Allocator, name: []const u8, dims: []const i64, data: []const f32) []const u8 {
    var t: Pb = .{ .a = a };
    for (dims) |d| t.varintField(1, d); // dims
    t.varintField(2, 1); // data_type = FLOAT
    // raw_data (field 9)
    var raw: std.ArrayList(u8) = .empty;
    for (data) |v| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(v), .little);
        raw.appendSlice(a, &b) catch unreachable;
    }
    t.bytesField(9, raw.items);
    t.bytesField(8, name); // name
    return t.slice();
}

fn valueInfo(a: std.mem.Allocator, name: []const u8, dims: []const i64) []const u8 {
    // ValueInfoProto{ name, type: TypeProto{ tensor_type: Tensor{ shape } } }
    var shape: Pb = .{ .a = a };
    for (dims) |d| {
        var dim: Pb = .{ .a = a };
        dim.varintField(1, d); // dim_value
        shape.bytesField(1, dim.slice()); // dim
    }
    var tt: Pb = .{ .a = a };
    tt.bytesField(2, shape.slice()); // shape
    var typ: Pb = .{ .a = a };
    typ.bytesField(1, tt.slice()); // tensor_type
    var vi: Pb = .{ .a = a };
    vi.bytesField(1, name); // name
    vi.bytesField(2, typ.slice()); // type
    return vi.slice();
}

const AttrSpec = struct { name: []const u8, ints: []const i64 = &.{}, f: ?f32 = null, i: ?i64 = null };

fn attrProto(a: std.mem.Allocator, spec: AttrSpec) []const u8 {
    var at: Pb = .{ .a = a };
    at.bytesField(1, spec.name);
    if (spec.f) |f| at.f32field(2, f);
    if (spec.i) |i| at.varintField(3, i);
    for (spec.ints) |v| at.varintField(8, v);
    return at.slice();
}

const NodeSpec = struct {
    op: []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
    attrs: []const AttrSpec = &.{},
};

fn nodeProto(a: std.mem.Allocator, spec: NodeSpec) []const u8 {
    var nd: Pb = .{ .a = a };
    for (spec.inputs) |i| nd.bytesField(1, i);
    for (spec.outputs) |o| nd.bytesField(2, o);
    nd.bytesField(4, spec.op);
    for (spec.attrs) |at| nd.bytesField(5, attrProto(a, at));
    return nd.slice();
}

const GraphSpec = struct {
    nodes: []const []const u8,
    inits: []const []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
};

fn modelProto(a: std.mem.Allocator, spec: GraphSpec) []const u8 {
    var g: Pb = .{ .a = a };
    for (spec.nodes) |nd| g.bytesField(1, nd);
    for (spec.inits) |ini| g.bytesField(5, ini);
    for (spec.inputs) |i| g.bytesField(11, i);
    for (spec.outputs) |o| g.bytesField(12, o);
    var model: Pb = .{ .a = a };
    model.varintField(1, 7); // ir_version, skipped by the parser
    model.bytesField(7, g.slice()); // graph
    return model.slice();
}

test "onnx parses and runs a gemm + relu classifier with an exact reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // y = relu(x * W + b), x:[1,3], W:[3,2], b:[2]
    const w = tensorProto(a, "W", &.{ 3, 2 }, &.{ 1, 0, 0, 1, 1, -1 });
    const b = tensorProto(a, "B", &.{2}, &.{ 0.5, -0.5 });
    const gemm_node = nodeProto(a, .{ .op = "Gemm", .inputs = &.{ "x", "W", "B" }, .outputs = &.{"h"} });
    const relu_node = nodeProto(a, .{ .op = "Relu", .inputs = &.{"h"}, .outputs = &.{"y"} });
    const model = modelProto(a, .{
        .nodes = &.{ gemm_node, relu_node },
        .inits = &.{ w, b },
        .inputs = &.{ valueInfo(a, "x", &.{ 1, 3 }), valueInfo(a, "W", &.{ 3, 2 }), valueInfo(a, "B", &.{2}) },
        .outputs = &.{valueInfo(a, "y", &.{ 1, 2 })},
    });

    var engine = try Engine.init(testing.allocator, model);
    defer engine.deinit();
    try testing.expectEqual(@as(usize, 1), engine.inputCount());
    try testing.expectEqual(@as(usize, 1), engine.outputCount());

    // x = [2, 3, 4] -> x*W = [2*1+3*0+4*1, 2*0+3*1+4*-1] = [6, -1]; +b = [6.5, -1.5]; relu = [6.5, 0]
    const x = [_]f32{ 2, 3, 4 };
    try engine.writeInput(0, std.mem.sliceAsBytes(&x));
    try engine.invoke();
    const y = try engine.outputFloats(0);
    try testing.expectEqual(@as(usize, 2), y.len);
    try testing.expectApproxEqAbs(@as(f32, 6.5), y[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), y[1], 1e-5);
}

test "onnx runs a 1-channel conv with known weights" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 3x3 input, 2x2 kernel of ones, valid conv -> 2x2 sums.
    const w = tensorProto(a, "W", &.{ 1, 1, 2, 2 }, &.{ 1, 1, 1, 1 });
    const conv_node = nodeProto(a, .{
        .op = "Conv",
        .inputs = &.{ "x", "W" },
        .outputs = &.{"y"},
        .attrs = &.{
            .{ .name = "kernel_shape", .ints = &.{ 2, 2 } },
            .{ .name = "strides", .ints = &.{ 1, 1 } },
            .{ .name = "pads", .ints = &.{ 0, 0, 0, 0 } },
        },
    });
    const model = modelProto(a, .{
        .nodes = &.{conv_node},
        .inits = &.{w},
        .inputs = &.{ valueInfo(a, "x", &.{ 1, 1, 3, 3 }), valueInfo(a, "W", &.{ 1, 1, 2, 2 }) },
        .outputs = &.{valueInfo(a, "y", &.{ 1, 1, 2, 2 })},
    });

    var engine = try Engine.init(testing.allocator, model);
    defer engine.deinit();

    // input 1..9 row-major; window sums: [1+2+4+5, 2+3+5+6, 4+5+7+8, 5+6+8+9] = [12,16,24,28]
    const x = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    try engine.writeInput(0, std.mem.sliceAsBytes(&x));
    try engine.invoke();
    const y = try engine.outputFloats(0);
    try testing.expectEqual(@as(usize, 4), y.len);
    try testing.expectApproxEqAbs(@as(f32, 12), y[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 16), y[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 24), y[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 28), y[3], 1e-5);
}

test "onnx broadcasts an add and reduces with softmax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bias = tensorProto(a, "B", &.{2}, &.{ 1, 2 });
    const add_node = nodeProto(a, .{ .op = "Add", .inputs = &.{ "x", "B" }, .outputs = &.{"s"} });
    const soft_node = nodeProto(a, .{ .op = "Softmax", .inputs = &.{"s"}, .outputs = &.{"y"}, .attrs = &.{.{ .name = "axis", .i = 1 }} });
    const model = modelProto(a, .{
        .nodes = &.{ add_node, soft_node },
        .inits = &.{bias},
        .inputs = &.{ valueInfo(a, "x", &.{ 1, 2 }), valueInfo(a, "B", &.{2}) },
        .outputs = &.{valueInfo(a, "y", &.{ 1, 2 })},
    });

    var engine = try Engine.init(testing.allocator, model);
    defer engine.deinit();
    // x = [0, 0] + [1, 2] = [1, 2]; softmax = [e^-1, 1]/sum -> equal after normalize.
    const x = [_]f32{ 0, 0 };
    try engine.writeInput(0, std.mem.sliceAsBytes(&x));
    try engine.invoke();
    const y = try engine.outputFloats(0);
    try testing.expectApproxEqAbs(y[0] + y[1], 1.0, 1e-5);
    const expected0 = @exp(@as(f32, 1)) / (@exp(@as(f32, 1)) + @exp(@as(f32, 2)));
    try testing.expectApproxEqAbs(y[0], expected0, 1e-5);
}
