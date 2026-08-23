//! Generates lenses/reference/morph-blend/assets/face.glb: a flat quad
//! with one morph target that pushes its corners out, so weighting the
//! target expands it and a render proof can see the deform. Run `zig run
//! tools/gen_morph_asset.zig` to regenerate; output committed.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();

    const positions = [4][3]f32{
        .{ -0.5, -0.5, 0.0 },
        .{ 0.5, -0.5, 0.0 },
        .{ 0.5, 0.5, 0.0 },
        .{ -0.5, 0.5, 0.0 },
    };
    const indices = [6]u16{ 0, 1, 2, 0, 2, 3 };
    // Morph target: each corner's delta points further out, so at full
    // weight the quad doubles in size.
    const deltas = [4][3]f32{
        .{ -0.5, -0.5, 0.0 },
        .{ 0.5, -0.5, 0.0 },
        .{ 0.5, 0.5, 0.0 },
        .{ -0.5, 0.5, 0.0 },
    };

    var bin: std.ArrayList(u8) = .empty;
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&positions)); // 0..48
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&indices)); // 48..60
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0);
    const deltas_offset = bin.items.len;
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&deltas)); // +48
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0);

    const json = try std.fmt.allocPrint(gpa,
        \\{{"asset":{{"version":"2.0"}},
        \\"buffers":[{{"byteLength":{d}}}],
        \\"bufferViews":[
        \\{{"buffer":0,"byteOffset":0,"byteLength":48}},
        \\{{"buffer":0,"byteOffset":48,"byteLength":12}},
        \\{{"buffer":0,"byteOffset":{d},"byteLength":48}}],
        \\"accessors":[
        \\{{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[-0.5,-0.5,0.0],"max":[0.5,0.5,0.0]}},
        \\{{"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}},
        \\{{"bufferView":2,"componentType":5126,"count":4,"type":"VEC3","min":[-0.5,-0.5,0.0],"max":[0.5,0.5,0.0]}}],
        \\"materials":[{{"pbrMetallicRoughness":{{"baseColorFactor":[1.0,0.35,0.1,1.0]}}}}],
        \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"indices":1,"material":0,"targets":[{{"POSITION":2}}]}}]}}],
        \\"nodes":[{{"mesh":0,"name":"face"}}],
        \\"scenes":[{{"nodes":[0]}}],"scene":0}}
    , .{ bin.items.len, deltas_offset });

    var json_padded: std.ArrayList(u8) = .empty;
    try json_padded.appendSlice(gpa, json);
    while (json_padded.items.len % 4 != 0) try json_padded.append(gpa, ' ');

    var glb: std.ArrayList(u8) = .empty;
    const total: u32 = @intCast(12 + 8 + json_padded.items.len + 8 + bin.items.len);
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u32, &scratch, 0x46546C67, .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, 2, .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, total, .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, @intCast(json_padded.items.len), .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, 0x4E4F534A, .little);
    try glb.appendSlice(gpa, &scratch);
    try glb.appendSlice(gpa, json_padded.items);
    std.mem.writeInt(u32, &scratch, @intCast(bin.items.len), .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, 0x004E4942, .little);
    try glb.appendSlice(gpa, &scratch);
    try glb.appendSlice(gpa, bin.items);

    try std.Io.Dir.cwd().createDirPath(init.io, "lenses/reference/morph-blend/assets");
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "lenses/reference/morph-blend/assets/face.glb",
        .data = glb.items,
    });

    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    try stdout.interface.print("wrote lenses/reference/morph-blend/assets/face.glb ({d} bytes)\n", .{glb.items.len});
    try stdout.interface.flush();
    return 0;
}
