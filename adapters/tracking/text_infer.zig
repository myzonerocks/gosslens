//! The text pipeline on the engine's own model rail: a detector produces a
//! probability map, post-processing turns it into oriented regions, each region
//! is rectified to an upright crop, and a recogniser reads it. Both models are
//! caller-supplied, so a lens ships whichever pair it wants.

const std = @import("std");
const ml_infer = @import("ml_infer");
const text = @import("text");

const Region = text.Region;
const Quad = text.Quad;

pub const Error = error{ InvalidModel, OutOfMemory, NotReady };

pub const Options = struct {
    /// The square the detector runs at. Larger finds smaller text and costs
    /// proportionally more, so it is the caller's dial rather than a constant.
    detect_side: u32 = 320,
    /// The recogniser's fixed input height; its width follows the crop's aspect.
    recognize_height: u32 = 48,
    max_recognize_width: u32 = 320,
    max_regions: usize = 64,
    detect: text.detect.Options = .{},
};

/// A scale pass over the frame. Small distant text and large near text do not
/// both land at one scale, so the detector runs at more than one and the
/// regions merge.
pub const Scale = struct {
    side: u32,
    /// Regions smaller than this fraction of the frame are kept from this pass;
    /// a coarse pass keeps the large ones and a fine pass the small.
    max_relative_size: f32 = 1.0,
};

pub const Pipeline = struct {
    gpa: std.mem.Allocator,
    detector: ml_infer.Engine,
    recognizer: ?ml_infer.Engine,
    dictionary: []const []const u8,
    opts: Options,

    detect_input: []f32,
    detect_map: []f32,
    crop: []u8,
    crop_input: []f32,
    scratch: text.detect.Scratch,
    regions: []Region,
    previous: []Region,
    previous_count: usize = 0,
    next_track: u32 = 1,

    /// Loads the detector, and the recogniser and dictionary where the caller
    /// supplied them. A detector alone is useful: it finds where the text is,
    /// which is what a redaction or a rectified crop needs.
    pub fn init(
        gpa: std.mem.Allocator,
        detector_bytes: []const u8,
        recognizer_bytes: ?[]const u8,
        dictionary_text: ?[]const u8,
        opts: Options,
    ) Error!Pipeline {
        var detector = ml_infer.Engine.init(gpa, detector_bytes, 2) catch return error.InvalidModel;
        errdefer detector.deinit();
        const side: i64 = @intCast(opts.detect_side);
        if (detector.inputNeedsShape(0)) {
            detector.resizeInput(0, &[_]i64{ 1, 3, side, side }) catch return error.InvalidModel;
        }

        var recognizer: ?ml_infer.Engine = null;
        errdefer if (recognizer) |*r| r.deinit();
        if (recognizer_bytes) |bytes| {
            var r = ml_infer.Engine.init(gpa, bytes, 2) catch return error.InvalidModel;
            if (r.inputNeedsShape(0)) {
                r.resizeInput(0, &[_]i64{ 1, 3, @intCast(opts.recognize_height), @intCast(opts.max_recognize_width) }) catch {
                    r.deinit();
                    return error.InvalidModel;
                };
            }
            recognizer = r;
        }

        var dictionary: []const []const u8 = &.{};
        errdefer gpa.free(dictionary);
        if (dictionary_text) |d| {
            dictionary = text.recognize.Dictionary.parse(gpa, d) catch return error.OutOfMemory;
        }

        const map_side: usize = opts.detect_side;
        const detect_input = gpa.alloc(f32, map_side * map_side * 3) catch return error.OutOfMemory;
        errdefer gpa.free(detect_input);
        const detect_map = gpa.alloc(f32, map_side * map_side) catch return error.OutOfMemory;
        errdefer gpa.free(detect_map);
        const crop_pixels = @as(usize, opts.recognize_height) * opts.max_recognize_width;
        const crop = gpa.alloc(u8, crop_pixels * 4) catch return error.OutOfMemory;
        errdefer gpa.free(crop);
        const crop_input = gpa.alloc(f32, crop_pixels * 3) catch return error.OutOfMemory;
        errdefer gpa.free(crop_input);
        const scratch = text.detect.Scratch.init(gpa, map_side, map_side) catch return error.OutOfMemory;
        errdefer scratch.deinit(gpa);
        const regions = gpa.alloc(Region, opts.max_regions) catch return error.OutOfMemory;
        errdefer gpa.free(regions);
        const previous = gpa.alloc(Region, opts.max_regions) catch return error.OutOfMemory;

        return .{
            .gpa = gpa,
            .detector = detector,
            .recognizer = recognizer,
            .dictionary = dictionary,
            .opts = opts,
            .detect_input = detect_input,
            .detect_map = detect_map,
            .crop = crop,
            .crop_input = crop_input,
            .scratch = scratch,
            .regions = regions,
            .previous = previous,
        };
    }

    pub fn deinit(p: *Pipeline) void {
        p.detector.deinit();
        if (p.recognizer) |*r| r.deinit();
        p.gpa.free(p.dictionary);
        p.gpa.free(p.detect_input);
        p.gpa.free(p.detect_map);
        p.gpa.free(p.crop);
        p.gpa.free(p.crop_input);
        p.scratch.deinit(p.gpa);
        p.gpa.free(p.regions);
        p.gpa.free(p.previous);
        p.* = undefined;
    }

    /// Finds the text regions in one RGBA frame and carries their track ids
    /// forward. Answers how many landed; the regions are readable until the
    /// next call.
    pub fn detectFrame(p: *Pipeline, rgba: []const u8, width: usize, height: usize, stride: usize) Error!usize {
        if (width == 0 or height == 0) return 0;
        const side: usize = p.opts.detect_side;
        sampleSquare(rgba, width, height, stride, p.detect_input, side);
        p.detector.writeInput(0, std.mem.sliceAsBytes(p.detect_input)) catch return error.InvalidModel;
        p.detector.invoke() catch return error.InvalidModel;
        const out = p.detector.outputFloats(0) catch return error.InvalidModel;

        // The map may come back at the detector's own stride rather than the
        // input square, so it is read at whatever size it declares.
        var dims_buf: [8]i32 = undefined;
        const dims = p.detector.outputDims(0, &dims_buf) catch return error.InvalidModel;
        const map_h: usize = if (dims.len >= 2) @intCast(@max(dims[dims.len - 2], 1)) else side;
        const map_w: usize = if (dims.len >= 1) @intCast(@max(dims[dims.len - 1], 1)) else side;
        if (out.len < map_w * map_h) return error.InvalidModel;

        const count = text.detect.regionsFrom(out[0 .. map_w * map_h], map_w, map_h, p.opts.detect, p.scratch, p.regions);
        text.carryTracks(p.previous[0..p.previous_count], p.regions[0..count], &p.next_track);
        @memcpy(p.previous[0..count], p.regions[0..count]);
        p.previous_count = count;
        return count;
    }

    /// Reads one detected region. The reading's text points into text_out, so
    /// the caller owns it and the pipeline holds no strings of its own.
    pub fn read(
        p: *Pipeline,
        index: usize,
        rgba: []const u8,
        width: usize,
        height: usize,
        stride: usize,
        text_out: []u8,
        chars_out: []text.recognize.Char,
    ) Error!text.recognize.Reading {
        const recognizer = &(p.recognizer orelse return error.NotReady);
        if (index >= p.regions.len) return error.NotReady;
        const q = p.regions[index].quad;

        // The crop keeps the region's aspect at the model's fixed height, so a
        // long sign is read across rather than squashed into a square.
        const extent = q.extent();
        const aspect = if (extent.h > 0) extent.w / extent.h else 1;
        const crop_h = p.opts.recognize_height;
        var crop_w: u32 = @intFromFloat(@max(8, @round(@as(f32, @floatFromInt(crop_h)) * aspect)));
        crop_w = @min(crop_w, p.opts.max_recognize_width);

        const plane: text.rectify.Plane = .{ .pixels = rgba, .width = width, .height = height, .channels = 4, .stride = stride };
        text.rectify.rectify(plane, q, p.crop, crop_w, crop_h);
        p.regions[index].content_hash = text.rectify.contentHash(p.crop[0 .. @as(usize, crop_w) * crop_h * 4]);

        if (recognizer.inputNeedsShape(0) or crop_w != p.opts.max_recognize_width) {
            recognizer.resizeInput(0, &[_]i64{ 1, 3, @intCast(crop_h), @intCast(crop_w) }) catch return error.InvalidModel;
        }
        toChannelFirst(p.crop, crop_w, crop_h, p.crop_input);
        recognizer.writeInput(0, std.mem.sliceAsBytes(p.crop_input[0 .. @as(usize, crop_w) * crop_h * 3])) catch return error.InvalidModel;
        recognizer.invoke() catch return error.InvalidModel;
        const scores = recognizer.outputFloats(0) catch return error.InvalidModel;

        var out_dims: [8]i32 = undefined;
        const dims = recognizer.outputDims(0, &out_dims) catch return error.InvalidModel;
        if (dims.len < 2) return error.InvalidModel;
        const classes: usize = @intCast(@max(dims[dims.len - 1], 1));
        const steps: usize = @intCast(@max(dims[dims.len - 2], 1));
        return text.recognize.decode(scores, steps, classes, .{ .entries = p.dictionary }, text_out, chars_out);
    }

    pub fn found(p: *const Pipeline) []const Region {
        return p.previous[0..p.previous_count];
    }
};

/// Samples an RGBA frame into a channel-first square in [0,1], the input layout
/// every exported detector in the wild declares.
fn sampleSquare(rgba: []const u8, width: usize, height: usize, stride: usize, out: []f32, side: usize) void {
    const plane = side * side;
    for (0..side) |y| {
        const sy = @min(height - 1, y * height / side);
        for (0..side) |x| {
            const sx = @min(width - 1, x * width / side);
            const src = sy * stride + sx * 4;
            const at = y * side + x;
            out[at] = @as(f32, @floatFromInt(rgba[src])) / 255.0;
            out[plane + at] = @as(f32, @floatFromInt(rgba[src + 1])) / 255.0;
            out[2 * plane + at] = @as(f32, @floatFromInt(rgba[src + 2])) / 255.0;
        }
    }
}

/// The crop, RGBA and interleaved, as channel-first floats in [-1,1]: the range
/// every text recogniser in the wild was exported with.
fn toChannelFirst(crop: []const u8, width: u32, height: u32, out: []f32) void {
    const plane = @as(usize, width) * height;
    for (0..plane) |i| {
        out[i] = @as(f32, @floatFromInt(crop[i * 4])) / 127.5 - 1.0;
        out[plane + i] = @as(f32, @floatFromInt(crop[i * 4 + 1])) / 127.5 - 1.0;
        out[2 * plane + i] = @as(f32, @floatFromInt(crop[i * 4 + 2])) / 127.5 - 1.0;
    }
}

const testing = std.testing;

test "the frame sampler writes a channel-first square in unit range" {
    // Two by two, one pure channel per pixel.
    const rgba = [_]u8{
        255, 0,   0,   255, 0, 255, 0,   255,
        0,   0,   255, 255, 0, 0,   0,   255,
    };
    var out: [2 * 2 * 3]f32 = undefined;
    sampleSquare(&rgba, 2, 2, 8, &out, 2);
    try testing.expectApproxEqAbs(@as(f32, 1), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), out[1], 1e-6);
    // Green of the second pixel lives in the second plane.
    try testing.expectApproxEqAbs(@as(f32, 1), out[4 + 1], 1e-6);
    // Blue of the third lives in the third.
    try testing.expectApproxEqAbs(@as(f32, 1), out[8 + 2], 1e-6);
}

test "the crop converter centres on zero the way a recogniser expects" {
    const crop = [_]u8{ 0, 128, 255, 255 };
    var out: [3]f32 = undefined;
    toChannelFirst(&crop, 1, 1, &out);
    try testing.expectApproxEqAbs(@as(f32, -1), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.00392), out[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), out[2], 1e-6);
}
