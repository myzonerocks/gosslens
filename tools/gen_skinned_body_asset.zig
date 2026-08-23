//! Generates lenses/reference/skinned-body/assets/body.glb: a two-part
//! skinned mesh (torso quad on a "Hips" joint, hand quad on a "LeftHand"
//! joint) so moving the wrist landmark deforms the hand. Run once with
//! `zig run tools/gen_skinned_body_asset.zig`; the output is committed.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();

    // Torso quad (joint 0, around the hips) then hand quad (joint 1).
    const positions = [8][3]f32{
        .{ -0.15, -0.5, 0.0 },
        .{ 0.15, -0.5, 0.0 },
        .{ 0.15, -0.2, 0.0 },
        .{ -0.15, -0.2, 0.0 },
        .{ 0.30, 0.10, 0.0 },
        .{ 0.50, 0.10, 0.0 },
        .{ 0.50, 0.30, 0.0 },
        .{ 0.30, 0.30, 0.0 },
    };
    const indices = [12]u16{ 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 };
    const joints = [8][4]u16{
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
    };
    const weights = [8][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
    };
    // Inverse binds map model space into each joint's local frame by
    // subtracting the joint's bind position (hips at y -0.5, hand at
    // 0.4, 0.2). Column-major, translation in the last column.
    const inverse_bind = [2][16]f32{
        .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0.5, 0, 1 },
        .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -0.4, -0.2, 0, 1 },
    };

    var bin: std.ArrayList(u8) = .empty;
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&positions)); // 0..96
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&indices)); // 96..120
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&joints)); // 120..184
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&weights)); // 184..312
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&inverse_bind)); // 312..440
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0);

    const json = try std.fmt.allocPrint(gpa,
        \\{{"asset":{{"version":"2.0"}},
        \\"buffers":[{{"byteLength":{d}}}],
        \\"bufferViews":[
        \\{{"buffer":0,"byteOffset":0,"byteLength":96}},
        \\{{"buffer":0,"byteOffset":96,"byteLength":24}},
        \\{{"buffer":0,"byteOffset":120,"byteLength":64}},
        \\{{"buffer":0,"byteOffset":184,"byteLength":128}},
        \\{{"buffer":0,"byteOffset":312,"byteLength":128}}],
        \\"accessors":[
        \\{{"bufferView":0,"componentType":5126,"count":8,"type":"VEC3","min":[-0.15,-0.5,0.0],"max":[0.5,0.3,0.0]}},
        \\{{"bufferView":1,"componentType":5123,"count":12,"type":"SCALAR"}},
        \\{{"bufferView":2,"componentType":5123,"count":8,"type":"VEC4"}},
        \\{{"bufferView":3,"componentType":5126,"count":8,"type":"VEC4"}},
        \\{{"bufferView":4,"componentType":5126,"count":2,"type":"MAT4"}}],
        \\"materials":[{{"pbrMetallicRoughness":{{"baseColorFactor":[0.1,0.7,0.9,1.0]}}}}],
        \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0,"JOINTS_0":2,"WEIGHTS_0":3}},"indices":1,"material":0}}]}}],
        \\"nodes":[{{"mesh":0,"skin":0,"name":"body"}},{{"name":"Hips"}},{{"name":"LeftHand"}}],
        \\"skins":[{{"joints":[1,2],"inverseBindMatrices":4}}],
        \\"scenes":[{{"nodes":[0,1,2]}}],"scene":0}}
    , .{bin.items.len});

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

    try std.Io.Dir.cwd().createDirPath(init.io, "lenses/reference/skinned-body/assets");
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "lenses/reference/skinned-body/assets/body.glb",
        .data = glb.items,
    });

    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    try stdout.interface.print("wrote lenses/reference/skinned-body/assets/body.glb ({d} bytes)\n", .{glb.items.len});
    try stdout.interface.flush();
    return 0;
}
