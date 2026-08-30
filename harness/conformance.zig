//! Conformance harness: drives a real packaged reference lens through the
//! production ABI end to end - real engine, real session, real face
//! tracking and segmentation against a real corpus portrait, real
//! goss_session_activate_lens_from_directory, real goss_engine_render_frame -
//! and proves the result is bit-stable: the same fixed input rendered
//! twice produces byte-identical output. Each lens's hash also checks
//! against lenses/conformance-baseline.txt (--print regenerates it), so
//! a change that shifts a lens's real output shows up as a tracked diff
//! in review, not just same-run determinism. This is still one platform
//! (host/macOS); cross-platform value-stability is real remaining work.

const std = @import("std");
const abi = @import("abi");
const sampler = @import("sampler");
const image_adapter = @import("image");
const png = @import("png");
const world_replay = @import("world_replay");
const math = @import("math");
const lens_manifest = @import("manifest");
const lash_mesh = @import("lash_mesh");
const face_mesh_topology = @import("face_mesh_topology");
const material = @import("material");
const gltf = @import("gltf");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
});
const stb = @cImport(@cInclude("stb_image.h"));

extern fn glfwGetCocoaWindow(window: ?*c.GLFWwindow) ?*anyopaque;

// Live bytes each vendor holds on its own C/C++ heap, which the Zig leak
// gate cannot see. The vendor-heap proof reads these across a lifecycle so a
// leaked Jolt Hair, QuickJS runtime, or miniaudio sound is caught where the
// GPA is blind. Internal harness probes, not part of the public C ABI.
extern fn goss_jolt_live_bytes() usize;
extern fn goss_qjs_live_bytes() usize;
extern fn goss_ma_live_bytes() usize;

const width: u32 = 400;
const height: u32 = 300;
/// Each lens runs with the segmentation model a real host would pick
/// for it: the single-class segmenter's person confidence is crisper
/// for subject compositing, the multiclass model carries the class
/// channels (hair) the channel lenses need.
const reference_lenses = [_]struct { name: []const u8, segmentation_model: []const u8 }{
    .{ .name = "shader-tint", .segmentation_model = single_class_model_path },
    .{ .name = "beauty-baseline", .segmentation_model = single_class_model_path },
    .{ .name = "background-swap", .segmentation_model = single_class_model_path },
    .{ .name = "trigger-anim", .segmentation_model = single_class_model_path },
    .{ .name = "hair-recolor", .segmentation_model = multiclass_model_path },
    .{ .name = "face-paint", .segmentation_model = single_class_model_path },
    .{ .name = "face-mask", .segmentation_model = single_class_model_path },
};
const baseline_path = "lenses/conformance-baseline.txt";
const corpus_path = ".models/corpus/face_frontal_b.jpg";
const face_bundle_path = ".models/face_landmarker.task";
const body_corpus_path = ".models/corpus/body_standing.jpg";
const pose_bundle_path = ".models/pose_landmarker_full.task";
const hand_corpus_path = ".models/corpus/hand_raised.jpg";
const hand_bundle_path = ".models/hand_landmarker.task";
const multiclass_model_path = ".models/selfie_multiclass.tflite";
const single_class_model_path = ".models/selfie_segmenter.tflite";
const scene_model_path = ".models/deeplab_v3.tflite";
const beauty_resource_path = ".vendor/gpupixel/src";

var harness_io: std.Io = undefined;

const CorpusFrame = struct {
    frame: sampler.Frame,
    fn deinit(corpus: CorpusFrame) void {
        stb.stbi_image_free(@constCast(corpus.frame.pixels.rgba8.ptr));
    }
};

fn loadCorpusFrame(gpa: std.mem.Allocator, path: []const u8) !CorpusFrame {
    const encoded = try std.Io.Dir.cwd().readFileAlloc(harness_io, path, gpa, .limited(32 << 20));
    defer gpa.free(encoded);
    var img_width: c_int = 0;
    var img_height: c_int = 0;
    var channels: c_int = 0;
    const pixels = stb.stbi_load_from_memory(encoded.ptr, @intCast(encoded.len), &img_width, &img_height, &channels, 4) orelse
        return error.UndecodableCorpusFrame;
    const len = @as(usize, @intCast(img_width)) * @as(usize, @intCast(img_height)) * 4;
    return .{ .frame = .{
        .pixels = .{ .rgba8 = pixels[0..len] },
        .width = @intCast(img_width),
        .height = @intCast(img_height),
    } };
}

const Nv12Copy = struct {
    y: []u8,
    uv: []u8,
    width: u32,
    height: u32,

    fn deinit(copy: Nv12Copy, gpa: std.mem.Allocator) void {
        gpa.free(copy.y);
        gpa.free(copy.uv);
    }
};

/// Converts a decoded RGBA frame to NV12 exactly the way a camera would
/// deliver it: full range, the classic standard, chroma averaged 2x2 -
/// through the image adapter, the kit's one CPU conversion authority.
fn rgbaToNv12(gpa: std.mem.Allocator, frame: sampler.Frame) !Nv12Copy {
    const w = frame.width;
    const h = frame.height;
    const half_width = (w + 1) / 2;
    const half_height = (h + 1) / 2;
    const y_plane = try gpa.alloc(u8, @as(usize, w) * h);
    errdefer gpa.free(y_plane);
    const uv_plane = try gpa.alloc(u8, @as(usize, half_width) * half_height * 2);
    errdefer gpa.free(uv_plane);
    try image_adapter.rgbaToNv12(gpa, frame.pixels.rgba8, w, h, y_plane, uv_plane);
    return .{ .y = y_plane, .uv = uv_plane, .width = w, .height = h };
}

/// Activates bundle_path on a fresh session with real face tracking and
/// segmentation enabled, feeds a real corpus portrait (not a synthetic
/// frame) to both the analysis path and the render preview, and
/// requests a screenshot at out_path once real results have landed -
/// bgfx's own default callback (no custom one is wired here, since
/// RendererDesc has no callback field to carry one through the frozen
/// ABI) writes it as out_path ++ ".tga".
const RenderOpts = struct {
    segmentation_model: ?[]const u8 = null,
    corpus: []const u8 = corpus_path,
    face: bool = true,
    hands: bool = false,
    depth: ?[]const f32 = null,
    depth_w: u32 = 0,
    depth_h: u32 = 0,
    depth_near: f32 = 0,
    depth_far: f32 = 0,
};

fn renderOnce(gpa: std.mem.Allocator, engine: *abi.Engine, bundle_path: []const u8, out_path: [:0]const u8, segmentation_model: ?[]const u8) !void {
    return renderOnceWith(gpa, engine, bundle_path, out_path, .{ .segmentation_model = segmentation_model });
}

/// Renders one lens over a corpus frame through the real ABI. opts picks the
/// corpus and which trackers run; a tracker left off is the control for a
/// landmark-derived effect, whose mask channel then stays on the zero mask.
fn renderOnceWith(gpa: std.mem.Allocator, engine: *abi.Engine, bundle_path: []const u8, out_path: [:0]const u8, opts: RenderOpts) !void {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(face_bytes);
    if (opts.face and abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
        return error.EnableFaceTrackingFailed;
    }
    var hand_bytes: ?[]u8 = null;
    defer if (hand_bytes) |hb| gpa.free(hb);
    if (opts.hands) {
        hand_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, hand_bundle_path, gpa, .limited(16 << 20));
        if (abi.goss_session_enable_hand_tracking(session, hand_bytes.?.ptr, hand_bytes.?.len, 2) != .ok) {
            return error.EnableHandTrackingFailed;
        }
    }
    if (opts.segmentation_model) |model_path| {
        const segmentation_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, model_path, gpa, .limited(16 << 20));
        defer gpa.free(segmentation_bytes);
        if (abi.goss_session_enable_segmentation(session, segmentation_bytes.ptr, segmentation_bytes.len, 2) != .ok) {
            return error.EnableSegmentationFailed;
        }
    }
    // Enabled unconditionally, same as face tracking and segmentation
    // above: only beauty-baseline actually splices a beauty node, so
    // this is a real no-op for the other reference lenses (beautyActive
    // gates on the active lens, not just the session) rather than a
    // per-lens special case here. Enabling before activation matters -
    // activation applies the lens's own default effect values to
    // whatever chain is already live, and a chain enabled afterward
    // would silently miss them.
    if (abi.goss_session_enable_beauty(session, beauty_resource_path) != .ok) {
        return error.EnableBeautyFailed;
    }

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: activate {s}: {s}\n", .{ bundle_path, @tagName(activated) });
        return error.ActivationFailed;
    }

    const corpus = try loadCorpusFrame(gpa, opts.corpus);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    // Nothing to track when the control render enables no tracker; the frame
    // still submits below so the pass composites over a real image.
    if (opts.face or opts.hands or opts.segmentation_model != null) {
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.TrackFrameFailed;
        }
    }
    // Depth submitted before the mask settles below, so a segmenter's mask
    // fuses with it; a lens with no segmenter uses the depth as its own mask.
    if (opts.depth) |depth| {
        if (abi.goss_session_submit_depth(session, depth.ptr, opts.depth_w, opts.depth_h, opts.depth_near, opts.depth_far) != .ok) {
            return error.SubmitDepthFailed;
        }
    }

    // Face tracking runs off-thread; wait for a real result before
    // proceeding so the render below reflects real landmarks, not
    // whatever the worker's first frame or two happens to still be
    // computing.
    if (opts.face) {
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
    }
    if (opts.hands) {
        var hand_result: abi.HandResult = undefined;
        var hand_polls: usize = 0;
        while (abi.goss_session_hand_result(session, &hand_result) == .again or hand_result.hand_count == 0) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            hand_polls += 1;
            if (hand_polls > 100_000_000) return error.HandResultTimedOut;
        }
    }

    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }

    // Like the face wait above: heavier segmentation models publish
    // later than the face result, so render until the mask texture
    // exists - render_frame itself polls the worker, the same way a
    // real app's frame loop picks the mask up.
    if (opts.segmentation_model != null) {
        var mask_polls: usize = 0;
        while (session.segmentation_texture == null) {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            mask_polls += 1;
            if (mask_polls > 100_000) return error.SegmentationTimedOut;
        }
    }

    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot(out_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
}

/// Proves video recording end to end through the public surface: a
/// real lens composites the corpus frame while recording, the finished
/// file decodes back with the recorded shape, and a decoded frame is
/// exported as the by-eye artifact.
fn proveVideoRecording(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    if (!abi.recording_supported) {
        std.debug.print("conformance: FAIL recording backend missing on this host\n", .{});
        return false;
    }
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL recording lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const path = "zig-out/conformance-recording.mp4";
    if (abi.goss_engine_recording_start(engine, session, path.ptr, path.len, null) != .ok) {
        std.debug.print("conformance: FAIL recording start\n", .{});
        return false;
    }
    const total_frames = 40;
    // Per-frame synthetic PCM: near-silence for the first half, a loud
    // burst after - the level must rise and the beat must fire, and the
    // muxed audio track must line up with the video track.
    const audio_frames_per_video_frame = 1600;
    var pcm: [audio_frames_per_video_frame * 2]f32 = undefined;
    var beat_fired = false;
    for (0..total_frames) |i| {
        const desc: abi.FrameDesc = .{
            .width = planes.width,
            .height = planes.height,
            .pixel_format = 0,
            .color_standard = 0,
            .color_range = 1,
            .flags = 0,
            .timestamp_us = @intCast((i + 1) * 33_333),
        };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        const amplitude: f32 = if (i < 30) 0.03 else 0.8;
        for (0..audio_frames_per_video_frame) |at| {
            const value = amplitude * @sin(@as(f32, @floatFromInt(i * audio_frames_per_video_frame + at)) * 0.2);
            pcm[at * 2] = value;
            pcm[at * 2 + 1] = value;
        }
        if (abi.goss_session_submit_audio(session, &pcm, audio_frames_per_video_frame, 48_000, 2, @intCast((i + 1) * 33_333)) != .ok) {
            std.debug.print("conformance: FAIL audio submit\n", .{});
            return false;
        }
        if (session.audio.beat) beat_fired = true;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    if (!beat_fired or session.audio.level < 0.1) {
        std.debug.print("conformance: FAIL audio analysis (beat {any}, level {d:.3})\n", .{ beat_fired, session.audio.level });
        return false;
    }
    if (abi.goss_engine_recording_stop(engine) != .ok) {
        std.debug.print("conformance: FAIL recording stop\n", .{});
        return false;
    }

    const shape = abi.recordingProbe(path) catch {
        std.debug.print("conformance: FAIL the recorded file does not decode\n", .{});
        return false;
    };
    // Every encoder pool slot skips exactly its first frame while the
    // render-target wrap lands, and the engine counts those plus any
    // timestamp drops. The decoded count must match that accounting
    // (one extra sample of container-timing slack allowed - the video
    // track starts after time zero once audio sets the clock base),
    // and warmups must stay a minority of the recording.
    const accounted = total_frames - engine.recording_warmups - engine.recording_dropped;
    if (shape.frames < accounted or shape.frames > accounted + 1 or shape.frames < total_frames / 2 or shape.width != 400 or shape.height != 300) {
        std.debug.print("conformance: FAIL recorded shape {d} frames ({d} warmups, {d} dropped) {d}x{d} video {d}us\n", .{ shape.frames, engine.recording_warmups, engine.recording_dropped, shape.width, shape.height, shape.duration_us });
        return false;
    }

    const bgra = try gpa.alloc(u8, @as(usize, shape.width) * shape.height * 4);
    defer gpa.free(bgra);
    const exported = abi.recordingExportFrame(path, shape.frames / 2, bgra) catch {
        std.debug.print("conformance: FAIL recorded frame export\n", .{});
        return false;
    };
    for (0..@as(usize, exported.width) * exported.height) |at| {
        std.mem.swap(u8, &bgra[at * 4], &bgra[at * 4 + 2]);
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, bgra, exported.width, exported.height);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-recording-frame.png", .data = png_bytes.items });

    // Both tracks ride one clock, so they must END together even
    // though video starts late by the warmup frames: the probes report
    // track start + duration, and the ends stay within two frames.
    const audio_end_us = abi.recordingProbeAudio(path) catch {
        std.debug.print("conformance: FAIL the recording has no decodable audio track\n", .{});
        return false;
    };
    const drift = @abs(shape.duration_us - audio_end_us);
    if (drift > 66_666) {
        std.debug.print("conformance: FAIL a/v end drift {d}us (video end {d}, audio end {d})\n", .{ drift, shape.duration_us, audio_end_us });
        return false;
    }
    std.debug.print("conformance: PROOF recording is a decodable video with an aligned audio track ({d}/{d} frames, {d} pool warmups, {d}x{d}, video {d}us, a/v drift {d}us)\n", .{ shape.frames, total_frames, engine.recording_warmups, shape.width, shape.height, shape.duration_us, drift });
    return true;
}

/// Proves the platform photo formats end to end: JPEG and HEIC
/// captures decode back at the right shape within a small error of
/// the deterministic PNG capture's pixels. Lossy encoders are not
/// bit-stable across hosts, so nothing here pins a hash.
fn provePlatformPhotos(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    if (!abi.photo_supported) {
        std.debug.print("conformance: FAIL platform photo backend missing on this host\n", .{});
        return false;
    }
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL photo formats lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // The deterministic PNG capture is the pixel reference.
    var ref_needed: usize = 0;
    var photo_width: u32 = 0;
    var photo_height: u32 = 0;
    var probe_byte: [1]u8 = undefined;
    if (abi.goss_engine_capture_photo(engine, session, &probe_byte, 0, &ref_needed, &photo_width, &photo_height) != .invalid_argument or ref_needed == 0) {
        std.debug.print("conformance: FAIL reference png probe\n", .{});
        return false;
    }
    const ref_png = try gpa.alloc(u8, ref_needed);
    defer gpa.free(ref_png);
    var ref_len: usize = 0;
    if (abi.goss_engine_capture_photo(engine, session, ref_png.ptr, ref_png.len, &ref_len, &photo_width, &photo_height) != .ok) {
        std.debug.print("conformance: FAIL reference png capture\n", .{});
        return false;
    }
    const reference_image = image_adapter.decode(gpa, ref_png[0..ref_len]) catch {
        std.debug.print("conformance: FAIL reference png does not decode\n", .{});
        return false;
    };
    defer gpa.free(reference_image.rgba);
    const reference = reference_image.rgba;
    if (reference_image.width != photo_width or reference_image.height != photo_height) {
        std.debug.print("conformance: FAIL reference png shape\n", .{});
        return false;
    }

    for ([_]struct { format: u32, name: []const u8 }{
        .{ .format = 1, .name = "jpeg" },
        .{ .format = 2, .name = "heic" },
    }) |case| {
        var needed: usize = 0;
        if (abi.goss_engine_capture_photo_as(engine, session, case.format, 85, &probe_byte, 0, &needed, &photo_width, &photo_height) != .invalid_argument or needed == 0) {
            std.debug.print("conformance: FAIL {s} size probe\n", .{case.name});
            return false;
        }
        const encoded = try gpa.alloc(u8, needed);
        defer gpa.free(encoded);
        var encoded_len: usize = 0;
        if (abi.goss_engine_capture_photo_as(engine, session, case.format, 85, encoded.ptr, encoded.len, &encoded_len, &photo_width, &photo_height) != .ok) {
            std.debug.print("conformance: FAIL {s} capture\n", .{case.name});
            return false;
        }
        const decoded = try gpa.alloc(u8, @as(usize, photo_width) * photo_height * 4);
        defer gpa.free(decoded);
        var decoded_width: u32 = 0;
        var decoded_height: u32 = 0;
        abi.photoDecode(encoded[0..encoded_len], decoded, &decoded_width, &decoded_height) catch {
            std.debug.print("conformance: FAIL {s} does not decode\n", .{case.name});
            return false;
        };
        if (decoded_width != photo_width or decoded_height != photo_height) {
            std.debug.print("conformance: FAIL {s} decoded shape {d}x{d}\n", .{ case.name, decoded_width, decoded_height });
            return false;
        }
        var total_error: u64 = 0;
        for (0..@as(usize, photo_width) * photo_height) |at| {
            for (0..3) |ch| {
                const a: i32 = reference[at * 4 + ch];
                const b: i32 = decoded[at * 4 + ch];
                total_error += @abs(a - b);
            }
        }
        const mean_error = @as(f64, @floatFromInt(total_error)) / @as(f64, @floatFromInt(@as(usize, photo_width) * photo_height * 3));
        if (mean_error > 6.0) {
            std.debug.print("conformance: FAIL {s} mean channel error {d:.2} vs the png capture\n", .{ case.name, mean_error });
            return false;
        }
        const metadata = abi.photoProbeMetadata(encoded[0..encoded_len]) catch {
            std.debug.print("conformance: FAIL {s} metadata probe\n", .{case.name});
            return false;
        };
        if (metadata.orientation != 1 or !std.mem.eql(u8, metadata.software[0..metadata.software_len], "gosslens")) {
            std.debug.print("conformance: FAIL {s} metadata (orientation {d})\n", .{ case.name, metadata.orientation });
            return false;
        }
        std.debug.print("conformance: PROOF {s} photo capture decodes back within {d:.2} mean channel error, exif intact ({d} bytes)\n", .{ case.name, mean_error, encoded_len });
    }
    return true;
}

/// Proves the world seam end to end on the replay source: an orbiting
/// camera track drives world-anchored content through the public
/// surface, initializing frames draw nothing, tracking frames draw the
/// marker, and the whole sequence is bit-stable across two runs.
fn proveWorldAnchor(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/world-anchor", ".lens-packages/world-anchor".len) != .ok) {
            std.debug.print("conformance: FAIL world lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initializing_shot: []u8 = &.{};
        defer if (initializing_shot.len > 0) gpa.free(initializing_shot);
        var tracking_shot: []u8 = &.{};
        defer if (tracking_shot.len > 0) gpa.free(tracking_shot);

        const anchor = abi.WorldAnchor{ .id = 7, .pose = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };
        for (0..24) |i| {
            const replay = world_replay.stateAt(@intCast(i), 33_333, 4.0 / 3.0);
            const state = abi.WorldState{
                .tracking_state = replay.tracking_state,
                .world_from_camera = @bitCast(replay.world_from_camera.cols),
                .projection = @bitCast(replay.projection.cols),
                .timestamp_us = replay.timestamp_us,
            };
            if (abi.goss_session_submit_world(session, &state, null, 0, @ptrCast(&anchor), 1, null) != .ok) {
                std.debug.print("conformance: FAIL world submit\n", .{});
                return false;
            }
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = replay.timestamp_us,
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();

            if (i == 1 or i == 12) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const capacity = @as(usize, 400) * 300 * 4;
                const shot = try gpa.alloc(u8, capacity);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    std.debug.print("conformance: FAIL world capture at frame {d}\n", .{i});
                    gpa.free(shot);
                    return false;
                }
                if (i == 1) initializing_shot = shot else tracking_shot = shot;
            }
        }

        if (std.mem.eql(u8, initializing_shot, tracking_shot)) {
            std.debug.print("conformance: FAIL the tracked frame must differ from the initializing frame\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initializing_shot);
        hasher.update(tracking_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, tracking_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-world-anchor.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL world replay is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF world-anchored content tracks the replayed camera, degrades while initializing, bit-stable across runs\n", .{});
    return true;
}

/// Proves the multi-face render fan-out: a face-anchored model draws once
/// per submitted face. One real corpus face renders alone on the left, then
/// again with a copy shifted right; the left half stays put while the right
/// half gains the second model, so every submitted face got the model.
fn proveMultiFaceFanOut(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(face_bytes);
    if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
        std.debug.print("conformance: FAIL multi-face tracking enable\n", .{});
        return false;
    }
    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/face-mask", ".lens-packages/face-mask".len) != .ok) {
        std.debug.print("conformance: FAIL multi-face lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };

    // Harvest one real face off the corpus so its landmarks fit a real head.
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.TrackFrameFailed;
    }
    var base: abi.FaceResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_face_result(session, &base) == .again) {
        std.Thread.yield() catch {};
        if (g_watch) c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000_000) return error.FaceResultTimedOut;
    }

    // A horizontal shift in landmark pixels moves the anchored model the same
    // way on screen: one face sits left of centre, its copy sits right.
    const shift = @as(f32, @floatFromInt(planes.width)) * 0.2;
    const landmark_count = base.landmarks.len / 3;
    var left = base;
    var right = base;
    var lm: usize = 0;
    while (lm < landmark_count) : (lm += 1) {
        left.landmarks[lm * 3] -= shift;
        right.landmarks[lm * 3] += shift;
    }

    const cap = @as(usize, 400) * 300 * 4;
    const shot_one = try gpa.alloc(u8, cap);
    defer gpa.free(shot_one);
    const shot_two = try gpa.alloc(u8, cap);
    defer gpa.free(shot_two);

    const one = [_]abi.FaceResult{left};
    const two = [_]abi.FaceResult{ left, right };
    var w1: u32 = 0;
    var h1: u32 = 0;
    var w2: u32 = 0;
    var h2: u32 = 0;
    try renderSubmittedFaces(engine, session, &desc, planes, &one, shot_one, &w1, &h1);
    try renderSubmittedFaces(engine, session, &desc, planes, &two, shot_two, &w2, &h2);
    if (w1 != w2 or h1 != h2 or w1 == 0 or h1 == 0) {
        std.debug.print("conformance: FAIL multi-face capture size {d}x{d} vs {d}x{d}\n", .{ w1, h1, w2, h2 });
        return false;
    }

    // Count where the second face changed the frame. Its model lands right of
    // centre, so the right half must move far more than the left.
    var left_changed: usize = 0;
    var right_changed: usize = 0;
    var y: u32 = 0;
    while (y < h1) : (y += 1) {
        var x: u32 = 0;
        while (x < w1) : (x += 1) {
            const idx = (y * w1 + x) * 4;
            const differs = !std.mem.eql(u8, shot_one[idx .. idx + 4], shot_two[idx .. idx + 4]);
            if (differs) {
                if (x < w1 / 2) left_changed += 1 else right_changed += 1;
            }
        }
    }
    if (right_changed == 0 or right_changed <= left_changed * 3) {
        std.debug.print("conformance: FAIL multi-face fan-out (left changed {d}, right changed {d})\n", .{ left_changed, right_changed });
        return false;
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shot_two[0 .. w1 * h1 * 4], @intCast(w1), @intCast(h1));
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-multi-face.png", .data = png_bytes.items });

    std.debug.print("conformance: PROOF a face-anchored model fans out to every submitted face (left changed {d}, right changed {d})\n", .{ left_changed, right_changed });
    return true;
}

fn proveMultiBodyFanOut(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const pose_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, pose_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(pose_bytes);
    if (abi.goss_session_enable_pose_tracking(session, pose_bytes.ptr, pose_bytes.len, 2) != .ok) {
        std.debug.print("conformance: FAIL multi-body tracking enable\n", .{});
        return false;
    }
    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/body-mask", ".lens-packages/body-mask".len) != .ok) {
        std.debug.print("conformance: FAIL multi-body lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, body_corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };

    // Harvest one real body off the corpus so its landmarks fit a real figure.
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.TrackFrameFailed;
    }
    var base: abi.PoseResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_pose_result(session, &base) == .again or base.landmark_count_out == 0) {
        std.Thread.yield() catch {};
        if (g_watch) c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000_000) return error.PoseResultTimedOut;
    }

    // A horizontal shift in landmark pixels moves the anchored model the same
    // way on screen: one body sits left of centre, its copy sits right.
    const shift = @as(f32, @floatFromInt(planes.width)) * 0.2;
    const landmark_count = base.landmarks.len / 3;
    var left = base;
    var right = base;
    var lm: usize = 0;
    while (lm < landmark_count) : (lm += 1) {
        left.landmarks[lm * 3] -= shift;
        right.landmarks[lm * 3] += shift;
    }

    const cap = @as(usize, 400) * 300 * 4;
    const shot_one = try gpa.alloc(u8, cap);
    defer gpa.free(shot_one);
    const shot_two = try gpa.alloc(u8, cap);
    defer gpa.free(shot_two);

    const one = [_]abi.PoseResult{left};
    const two = [_]abi.PoseResult{ left, right };
    var w1: u32 = 0;
    var h1: u32 = 0;
    var w2: u32 = 0;
    var h2: u32 = 0;
    try renderSubmittedBodies(engine, session, &desc, planes, &one, shot_one, &w1, &h1);
    try renderSubmittedBodies(engine, session, &desc, planes, &two, shot_two, &w2, &h2);
    if (w1 != w2 or h1 != h2 or w1 == 0 or h1 == 0) {
        std.debug.print("conformance: FAIL multi-body capture size {d}x{d} vs {d}x{d}\n", .{ w1, h1, w2, h2 });
        return false;
    }

    // Count where the second body changed the frame. Its model lands right of
    // centre, so the right half must move far more than the left.
    var left_changed: usize = 0;
    var right_changed: usize = 0;
    var y: u32 = 0;
    while (y < h1) : (y += 1) {
        var x: u32 = 0;
        while (x < w1) : (x += 1) {
            const idx = (y * w1 + x) * 4;
            if (!std.mem.eql(u8, shot_one[idx .. idx + 4], shot_two[idx .. idx + 4])) {
                if (x < w1 / 2) left_changed += 1 else right_changed += 1;
            }
        }
    }
    if (right_changed == 0 or right_changed <= left_changed * 3) {
        std.debug.print("conformance: FAIL multi-body fan-out (left changed {d}, right changed {d})\n", .{ left_changed, right_changed });
        return false;
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shot_two[0 .. w1 * h1 * 4], @intCast(w1), @intCast(h1));
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-multi-body.png", .data = png_bytes.items });

    std.debug.print("conformance: PROOF a body-anchored model fans out to every submitted body (left changed {d}, right changed {d})\n", .{ left_changed, right_changed });
    return true;
}

fn proveSkeletonRig(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const pose_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, pose_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(pose_bytes);
    if (abi.goss_session_enable_pose_tracking(session, pose_bytes.ptr, pose_bytes.len, 2) != .ok) {
        std.debug.print("conformance: FAIL skeleton tracking enable\n", .{});
        return false;
    }
    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/skeleton-rig", ".lens-packages/skeleton-rig".len) != .ok) {
        std.debug.print("conformance: FAIL skeleton lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, body_corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };

    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.TrackFrameFailed;
    }
    var base: abi.PoseResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_pose_result(session, &base) == .again or base.landmark_count_out == 0) {
        std.Thread.yield() catch {};
        if (g_watch) c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000_000) return error.PoseResultTimedOut;
    }

    // One body left of centre, a copy shifted right, so the rig fans out and
    // the second figure's bones must land in the right half.
    const shift = @as(f32, @floatFromInt(planes.width)) * 0.2;
    const landmark_count = base.landmarks.len / 3;
    var left = base;
    var right = base;
    var lm: usize = 0;
    while (lm < landmark_count) : (lm += 1) {
        left.landmarks[lm * 3] -= shift;
        right.landmarks[lm * 3] += shift;
    }

    const cap = @as(usize, 400) * 300 * 4;
    const shot_one = try gpa.alloc(u8, cap);
    defer gpa.free(shot_one);
    const shot_two = try gpa.alloc(u8, cap);
    defer gpa.free(shot_two);

    const one = [_]abi.PoseResult{left};
    const two = [_]abi.PoseResult{ left, right };
    var w1: u32 = 0;
    var h1: u32 = 0;
    var w2: u32 = 0;
    var h2: u32 = 0;
    try renderSubmittedBodies(engine, session, &desc, planes, &one, shot_one, &w1, &h1);
    try renderSubmittedBodies(engine, session, &desc, planes, &two, shot_two, &w2, &h2);
    if (w1 != w2 or h1 != h2 or w1 == 0 or h1 == 0) {
        std.debug.print("conformance: FAIL skeleton capture size {d}x{d} vs {d}x{d}\n", .{ w1, h1, w2, h2 });
        return false;
    }

    // The second figure's rig lands in the right half, and its bones span the
    // whole figure, so the right change appears in both the top and the bottom.
    var left_changed: usize = 0;
    var right_top: usize = 0;
    var right_bottom: usize = 0;
    var y: u32 = 0;
    while (y < h1) : (y += 1) {
        var x: u32 = 0;
        while (x < w1) : (x += 1) {
            const idx = (y * w1 + x) * 4;
            if (!std.mem.eql(u8, shot_one[idx .. idx + 4], shot_two[idx .. idx + 4])) {
                if (x < w1 / 2) {
                    left_changed += 1;
                } else if (y < h1 / 2) {
                    right_top += 1;
                } else {
                    right_bottom += 1;
                }
            }
        }
    }
    const right_changed = right_top + right_bottom;
    if (right_changed <= left_changed * 3) {
        std.debug.print("conformance: FAIL skeleton fan-out (left {d}, right {d})\n", .{ left_changed, right_changed });
        return false;
    }
    if (right_top < 10 or right_bottom < 10) {
        std.debug.print("conformance: FAIL skeleton rig not full height (right top {d}, bottom {d})\n", .{ right_top, right_bottom });
        return false;
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shot_two[0 .. w1 * h1 * 4], @intCast(w1), @intCast(h1));
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-skeleton-rig.png", .data = png_bytes.items });

    std.debug.print("conformance: PROOF a skeleton-anchored model tiles a rig over the body (right top {d}, bottom {d})\n", .{ right_top, right_bottom });
    return true;
}

fn proveSkinnedBodyMesh(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const pose_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, pose_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(pose_bytes);
    if (abi.goss_session_enable_pose_tracking(session, pose_bytes.ptr, pose_bytes.len, 2) != .ok) {
        std.debug.print("conformance: FAIL skinned-body tracking enable\n", .{});
        return false;
    }
    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/skinned-body", ".lens-packages/skinned-body".len) != .ok) {
        std.debug.print("conformance: FAIL skinned-body lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, body_corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };

    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.TrackFrameFailed;
    }
    var base: abi.PoseResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_pose_result(session, &base) == .again or base.landmark_count_out == 0) {
        std.Thread.yield() catch {};
        if (g_watch) c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000_000) return error.PoseResultTimedOut;
    }

    // Move only the left wrist (landmark 15); the shoulders and hips that
    // set the body anchor stay put. A rigid mesh renders identically, so
    // any change proves the hand skinned to follow the wrist.
    var moved = base;
    const shift = @as(f32, @floatFromInt(planes.width)) * 0.15;
    moved.landmarks[15 * 3] += shift;
    moved.landmarks[15 * 3 + 1] -= shift;

    const cap = @as(usize, 400) * 300 * 4;
    const shot_rest = try gpa.alloc(u8, cap);
    defer gpa.free(shot_rest);
    const shot_bent = try gpa.alloc(u8, cap);
    defer gpa.free(shot_bent);
    const rest = [_]abi.PoseResult{base};
    const bent = [_]abi.PoseResult{moved};
    var wr: u32 = 0;
    var hr: u32 = 0;
    var wb: u32 = 0;
    var hb: u32 = 0;
    try renderSubmittedBodies(engine, session, &desc, planes, &rest, shot_rest, &wr, &hr);
    try renderSubmittedBodies(engine, session, &desc, planes, &bent, shot_bent, &wb, &hb);
    if (wr == 0 or wr != wb or hr != hb) {
        std.debug.print("conformance: FAIL skinned-body capture size {d}x{d} vs {d}x{d}\n", .{ wr, hr, wb, hb });
        return false;
    }

    var changed: usize = 0;
    for (0..wr * hr) |i| {
        if (!std.mem.eql(u8, shot_rest[i * 4 .. i * 4 + 4], shot_bent[i * 4 .. i * 4 + 4])) changed += 1;
    }
    if (changed == 0) {
        std.debug.print("conformance: FAIL moving the wrist did not deform the skinned mesh\n", .{});
        return false;
    }

    std.debug.print("conformance: PROOF a skinned body mesh bends to follow a moved wrist while its body anchor holds ({d} pixels changed)\n", .{changed});
    return true;
}

fn proveDepthOcclusion(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    // A blend.pass lens with no segmentation model: the submitted depth
    // alone drives its subject mask.
    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/background-swap", ".lens-packages/background-swap".len) != .ok) {
        std.debug.print("conformance: FAIL depth-occlusion lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, body_corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };

    // Range 0.1..5.0 puts the occlusion plane at 2.55 m. The left half of
    // the near map sits in front of it, the right half and the far map behind.
    const dw = 64;
    const dh = 48;
    var near_map: [dw * dh]f32 = undefined;
    var far_map: [dw * dh]f32 = undefined;
    for (0..dh) |y| {
        for (0..dw) |x| {
            near_map[y * dw + x] = if (x < dw / 2) 0.5 else 3.0;
            far_map[y * dw + x] = 3.0;
        }
    }

    const cap = @as(usize, 400) * 300 * 4;
    const shot_near = try gpa.alloc(u8, cap);
    defer gpa.free(shot_near);
    const shot_near2 = try gpa.alloc(u8, cap);
    defer gpa.free(shot_near2);
    const shot_far = try gpa.alloc(u8, cap);
    defer gpa.free(shot_far);
    var wn: u32 = 0;
    var hn: u32 = 0;
    var wn2: u32 = 0;
    var hn2: u32 = 0;
    var wf: u32 = 0;
    var hf: u32 = 0;
    try renderWithDepth(engine, session, &desc, planes, &near_map, dw, dh, 0.1, 5.0, shot_near, &wn, &hn);
    try renderWithDepth(engine, session, &desc, planes, &near_map, dw, dh, 0.1, 5.0, shot_near2, &wn2, &hn2);
    try renderWithDepth(engine, session, &desc, planes, &far_map, dw, dh, 0.1, 5.0, shot_far, &wf, &hf);
    if (wn == 0 or wn != wf or hn != hf or wn != wn2 or hn != hn2) {
        std.debug.print("conformance: FAIL depth-occlusion capture size mismatch\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, shot_near[0 .. wn * hn * 4], shot_near2[0 .. wn * hn * 4])) {
        std.debug.print("conformance: FAIL depth occlusion is not deterministic across runs\n", .{});
        return false;
    }
    var changed: usize = 0;
    for (0..wn * hn) |i| {
        if (!std.mem.eql(u8, shot_near[i * 4 .. i * 4 + 4], shot_far[i * 4 .. i * 4 + 4])) changed += 1;
    }
    if (changed == 0) {
        std.debug.print("conformance: FAIL the near depth patch did not change the composite\n", .{});
        return false;
    }

    std.debug.print("conformance: PROOF submitted depth drives occlusion: a near patch pokes the camera frame through the composite ({d} pixels changed), deterministically\n", .{changed});
    return true;
}

fn writeParallaxLens(dir: []const u8, amount: f32, focus: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.parallax","version":"1.0.0","display_name":"Parallax","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"p","type":"parallax.pass","inputs":{{"frame":"camera"}},"params":{{}},"parallax":{{"amount":{d:.4},"focus":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{ amount, focus });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Activates a parallax.pass lens, submits a fixed device tilt, and renders the
/// frame over a three-band synthetic depth map, returning the capture.
fn captureParallaxShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, depth: []const f32, dw: u32, dh: u32, tilt: [3]f32) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    _ = abi.goss_session_submit_orientation(session, tilt[0], tilt[1], tilt[2], 1000);
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    var w: u32 = 0;
    var h: u32 = 0;
    try renderWithDepth(engine, session, &desc, planes, depth, dw, dh, 0.0, 1.0, shot, &w, &h);
    return shot;
}

/// Proves the 3D-photo parallax warp: a red gradient over three depth bands (a
/// near, a focus-plane, and a far band) with a submitted device tilt. The near
/// band shifts by its distance from the focus plane while the focus band holds;
/// the shift reverses with the tilt; a zero amount is an identity; bit-stable.
fn proveParallax(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        f[idx + 0] = @intCast(col * 255 / (@as(usize, width) - 1)); // red rides the column
        f[idx + 1] = 90;
        f[idx + 2] = 160;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    // Three vertical depth bands: near (0), focus-plane (0.5), far (1).
    const dw: u32 = 60;
    const dh: u32 = 45;
    var depth: [dw * dh]f32 = undefined;
    for (0..dh) |y| for (0..dw) |x| {
        depth[y * dw + x] = if (x < dw / 3) 0.0 else if (x < 2 * dw / 3) 0.5 else 1.0;
    };

    const tilt = [3]f32{ 0.6, -0.8, 0 };
    const tilt_neg = [3]f32{ -0.6, -0.8, 0 };

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/parallax-0");
    try writeParallaxLens("zig-out/parallax-0", 0.0, 0.5);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/parallax-1");
    try writeParallaxLens("zig-out/parallax-1", 0.12, 0.5);

    const raw = try captureParallaxShot(gpa, engine, "zig-out/parallax-0", planes, &depth, dw, dh, tilt);
    defer gpa.free(raw);
    const warp = try captureParallaxShot(gpa, engine, "zig-out/parallax-1", planes, &depth, dw, dh, tilt);
    defer gpa.free(warp);
    const warp2 = try captureParallaxShot(gpa, engine, "zig-out/parallax-1", planes, &depth, dw, dh, tilt);
    defer gpa.free(warp2);
    const warp_neg = try captureParallaxShot(gpa, engine, "zig-out/parallax-1", planes, &depth, dw, dh, tilt_neg);
    defer gpa.free(warp_neg);

    if (!std.mem.eql(u8, warp, warp2)) {
        std.debug.print("conformance: FAIL parallax is not bit-stable across runs\n", .{});
        return false;
    }
    // A zero amount is an identity: the warp equals the raw frame.
    if (countDiff(raw, warp) == 0) {
        std.debug.print("conformance: FAIL parallax at amount 0.12 did not move the frame\n", .{});
        return false;
    }
    // The near band (left third) shifts; the focus band (middle third) holds.
    const near_raw = regionMean(raw, 20, 120);
    const near_warp = regionMean(warp, 20, 120);
    const focus_raw = regionMean(raw, 150, 250);
    const focus_warp = regionMean(warp, 150, 250);
    const near_shift = @abs(near_warp[0] - near_raw[0]);
    const focus_shift = @abs(focus_warp[0] - focus_raw[0]);
    if (!(near_shift > focus_shift + 8)) {
        std.debug.print("conformance: FAIL parallax did not shift the near band more than the focus band (near {d:.1}, focus {d:.1})\n", .{ near_shift, focus_shift });
        return false;
    }
    // The shift direction reverses with the tilt.
    if (std.mem.eql(u8, warp, warp_neg)) {
        std.debug.print("conformance: FAIL parallax did not reverse with the tilt direction\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a parallax.pass warps the frame by the submitted depth's distance from the focus plane: the near band shifts (red {d:.0} -> {d:.0}) while the focus band holds ({d:.0} -> {d:.0}), reversing with the tilt and identity at amount 0, bit-stable\n", .{ near_raw[0], near_warp[0], focus_raw[0], focus_warp[0] });
    return true;
}

/// Writes a lens whose ml.infer node binds its model output as both a driven
/// parameter (so a publish is observable) and the scene depth, feeding a
/// parallax.pass that carries no depth of its own. So the parallax warps only
/// once the model's estimated depth reaches the rail, with no depth submitted.
fn writeMonoDepthLens(dir: []const u8, amount: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.mono-depth","version":"1.0.0","display_name":"Mono Depth","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{{"name":"score","type":"float","default":-999.0,"min":-1000000.0,"max":1000000.0}}],
        \\ "nodes":[
        \\   {{"id":"est","type":"ml.infer","params":{{}},"ml":{{"model":"model.tflite","outputs":[{{"tensor":0,"index":32896,"param":"score"}}],"depth":{{"tensor":0}}}}}},
        \\   {{"id":"p","type":"parallax.pass","inputs":{{"frame":"camera"}},"params":{{}},"parallax":{{"amount":{d:.4},"focus":0.5}}}}
        \\ ],
        \\ "triggers":[]}}
    , .{amount});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Activates a mono-depth lens, feeds it until the model publishes, then renders
/// the parallax the estimated depth drives under a submitted tilt. No depth is
/// ever submitted; the depth the parallax reads comes only from the model.
/// Returns the capture and, through out_score, the parameter the model drove.
fn captureMonoDepthShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, tilt: [3]f32, out_score: *f32) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    _ = abi.goss_session_submit_orientation(session, tilt[0], tilt[1], tilt[2], 1000);
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    const signals = std.mem.zeroes(abi.LensSignals);
    // Feed the model (track) and watch the sentinel score flip to a real
    // inference, so the render below runs after the worker has published.
    var score: f32 = -999.0;
    var polls: usize = 0;
    while (score == -999.0) {
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.MlTrackFrameFailed;
        std.Thread.yield() catch {};
        _ = abi.goss_session_tick_lens(session, 16000, &signals);
        _ = abi.goss_session_parameter_value(session, "score", 5, &score);
        polls += 1;
        if (polls > 100_000_000) return error.MlInferTimedOut;
    }
    out_score.* = score;
    // The worker has published; render composites so pollMlDepth uploads the
    // estimated depth and the parallax draws over the fed camera frame.
    const shot = try gpa.alloc(u8, @as(usize, planes.width) * planes.height * 4);
    errdefer gpa.free(shot);
    var w: u32 = 0;
    var h: u32 = 0;
    for (0..5) |_| {
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.MlTrackFrameFailed;
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Proves depth-from-a-single-image: a bundled monocular depth net's output
/// becomes the session depth with no depth submitted, and that estimated depth
/// drives the parallax warp. The model runs on the frame (score responds to
/// pixels), the warp is non-trivial (identity at amount 0, reverses with tilt).
fn proveMonoDepth(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const model = try std.Io.Dir.cwd().readFileAlloc(harness_io, single_class_model_path, gpa, .limited(32 << 20));
    defer gpa.free(model);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/mono-depth-warp/assets");
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/mono-depth-still/assets");
    try writeMonoDepthLens("zig-out/mono-depth-warp", 0.15);
    try writeMonoDepthLens("zig-out/mono-depth-still", 0.0);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/mono-depth-warp/assets/model.tflite", .data = model });
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/mono-depth-still/assets/model.tflite", .data = model });

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);
    const gray_rgba = try gpa.alloc(u8, @as(usize, corpus.frame.width) * corpus.frame.height * 4);
    defer gpa.free(gray_rgba);
    @memset(gray_rgba, 128);
    const gray = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = gray_rgba }, .width = corpus.frame.width, .height = corpus.frame.height });
    defer gray.deinit(gpa);

    const tilt = [3]f32{ 0.6, -0.8, 0 };
    const tilt_neg = [3]f32{ -0.6, -0.8, 0 };
    var score_p: f32 = 0;
    var score_g: f32 = 0;
    var scratch: f32 = 0;

    const warp = try captureMonoDepthShot(gpa, engine, "zig-out/mono-depth-warp", person, tilt, &score_p);
    defer gpa.free(warp);
    const warp2 = try captureMonoDepthShot(gpa, engine, "zig-out/mono-depth-warp", person, tilt, &scratch);
    defer gpa.free(warp2);
    const warp_neg = try captureMonoDepthShot(gpa, engine, "zig-out/mono-depth-warp", person, tilt_neg, &scratch);
    defer gpa.free(warp_neg);
    const still = try captureMonoDepthShot(gpa, engine, "zig-out/mono-depth-still", person, tilt, &scratch);
    defer gpa.free(still);
    const gray_warp = try captureMonoDepthShot(gpa, engine, "zig-out/mono-depth-warp", gray, tilt, &score_g);
    defer gpa.free(gray_warp);

    // The model published a real inference from the frame: finite, and the
    // portrait and the flat frame drive its score apart, so it ran on pixels.
    if (!std.math.isFinite(score_p) or !std.math.isFinite(score_g)) {
        std.debug.print("conformance: FAIL mono-depth model published a non-finite score\n", .{});
        return false;
    }
    if (@abs(score_p - score_g) < 1e-4) {
        std.debug.print("conformance: FAIL mono-depth model did not respond to the frame ({d} vs {d})\n", .{ score_p, score_g });
        return false;
    }
    if (!std.mem.eql(u8, warp, warp2)) {
        std.debug.print("conformance: FAIL mono-depth parallax is not bit-stable across runs\n", .{});
        return false;
    }
    // The estimated depth drives the warp: amount 0 holds the frame, amount 0.15
    // moves it, and with no depth ever submitted only the model's output can be it.
    const moved = countDiff(still, warp);
    if (moved == 0) {
        std.debug.print("conformance: FAIL estimated depth did not drive the parallax warp\n", .{});
        return false;
    }
    if (std.mem.eql(u8, warp, warp_neg)) {
        std.debug.print("conformance: FAIL mono-depth parallax did not reverse with the tilt\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a monocular depth net's output becomes the session depth with no depth submitted and drives the parallax warp: the model runs on the frame (score {d:.3} vs flat {d:.3}), amount 0 holds while 0.15 moves it ({d} px), reversing with the tilt, bit-stable\n", .{ score_p, score_g, moved });
    return true;
}

/// Submits one frame with a set of faces, renders it settled, and captures.
fn renderSubmittedFaces(engine: *abi.Engine, session: *abi.Session, desc: *const abi.FrameDesc, planes: anytype, faces: []const abi.FaceResult, shot: []u8, out_w: *u32, out_h: *u32) !void {
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_faces(session, faces.ptr, @intCast(faces.len)) != .ok) return error.SubmitFacesFailed;
    for (0..5) |_| {
        if (abi.goss_session_submit_frame_copy(session, desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, out_w, out_h) != .ok) {
        return error.CaptureFailed;
    }
}

fn renderSubmittedBodies(engine: *abi.Engine, session: *abi.Session, desc: *const abi.FrameDesc, planes: anytype, bodies: []const abi.PoseResult, shot: []u8, out_w: *u32, out_h: *u32) !void {
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_bodies(session, bodies.ptr, @intCast(bodies.len)) != .ok) return error.SubmitBodiesFailed;
    for (0..5) |_| {
        if (abi.goss_session_submit_frame_copy(session, desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, out_w, out_h) != .ok) {
        return error.CaptureFailed;
    }
}

fn renderWithDepth(engine: *abi.Engine, session: *abi.Session, desc: *const abi.FrameDesc, planes: anytype, depth: []const f32, dw: u32, dh: u32, near: f32, far: f32, shot: []u8, out_w: *u32, out_h: *u32) !void {
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_depth(session, depth.ptr, dw, dh, near, far) != .ok) return error.SubmitDepthFailed;
    for (0..5) |_| {
        if (abi.goss_session_submit_frame_copy(session, desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, out_w, out_h) != .ok) {
        return error.CaptureFailed;
    }
}

/// Proves the named face regions land on the right anatomy of a real face:
/// the nose sits between forehead and chin, the four left regions all fall on
/// one side of the nose and the four right regions on the other, and the ears
/// are the widest points. This catches a swapped landmark or a left/right mix.
fn proveFaceRegions(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(face_bytes);
    if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
        std.debug.print("conformance: FAIL face-region tracking enable\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.TrackFrameFailed;
    }
    var result: abi.FaceResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_face_result(session, &result) == .again) {
        std.Thread.yield() catch {};
        if (g_watch) c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000_000) return error.FaceResultTimedOut;
    }

    var p: [13][3]f32 = undefined;
    var region: u32 = 0;
    while (region < 13) : (region += 1) {
        if (abi.goss_session_face_region(session, region, &p[region]) != .ok) {
            std.debug.print("conformance: FAIL face region {d} not read\n", .{region});
            return false;
        }
    }
    const forehead = p[0];
    const nose = p[2];
    const chin = p[3];
    const cx = nose[0];
    // The nose sits between forehead and chin along the vertical axis.
    if ((nose[1] - forehead[1]) * (chin[1] - nose[1]) <= 0) {
        std.debug.print("conformance: FAIL nose not between forehead and chin (y {d:.1} {d:.1} {d:.1})\n", .{ forehead[1], nose[1], chin[1] });
        return false;
    }
    // Every left region on one side of the nose, every right on the other.
    const left = [_]usize{ 4, 6, 8, 11 };
    const right = [_]usize{ 5, 7, 9, 12 };
    const left_positive = p[left[0]][0] > cx;
    for (left) |i| {
        if ((p[i][0] > cx) != left_positive) {
            std.debug.print("conformance: FAIL left region {d} on the wrong side of the nose\n", .{i});
            return false;
        }
    }
    for (right) |i| {
        if ((p[i][0] > cx) == left_positive) {
            std.debug.print("conformance: FAIL right region {d} on the wrong side of the nose\n", .{i});
            return false;
        }
    }
    // The ears are wider apart than the eyes.
    const ear_span = @abs(p[8][0] - p[9][0]);
    const eye_span = @abs(p[4][0] - p[5][0]);
    if (ear_span <= eye_span) {
        std.debug.print("conformance: FAIL ears not wider than eyes ({d:.1} <= {d:.1})\n", .{ ear_span, eye_span });
        return false;
    }
    std.debug.print("conformance: PROOF named face regions land on the right anatomy (ear span {d:.1}, eye span {d:.1})\n", .{ ear_span, eye_span });
    return true;
}

/// Proves the named body joints land on the right anatomy of a real standing
/// figure: head above shoulders above hips above knees above ankles down the
/// image, so a swapped landmark or a mis-indexed joint would fail.
fn proveBodyJoints(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const pose_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, pose_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(pose_bytes);
    if (abi.goss_session_enable_pose_tracking(session, pose_bytes.ptr, pose_bytes.len, 2) != .ok) {
        std.debug.print("conformance: FAIL body-joint tracking enable\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, body_corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.TrackFrameFailed;
    }
    var result: abi.PoseResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_pose_result(session, &result) == .again or result.landmark_count_out == 0) {
        std.Thread.yield() catch {};
        if (g_watch) c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000_000) return error.PoseResultTimedOut;
    }

    var p: [13][3]f32 = undefined;
    var jointi: u32 = 0;
    while (jointi < 13) : (jointi += 1) {
        if (abi.goss_session_body_joint(session, jointi, &p[jointi]) != .ok) {
            std.debug.print("conformance: FAIL body joint {d} not read\n", .{jointi});
            return false;
        }
    }
    // Down the image (y grows down): head, then the shoulder pair, the hip
    // pair, the knee pair, and the ankle pair, each below the last.
    const head_y = p[0][1];
    const shoulder_y = (p[1][1] + p[2][1]) * 0.5;
    const hip_y = (p[7][1] + p[8][1]) * 0.5;
    const knee_y = (p[9][1] + p[10][1]) * 0.5;
    const ankle_y = (p[11][1] + p[12][1]) * 0.5;
    if (!(head_y < shoulder_y and shoulder_y < hip_y and hip_y < knee_y and knee_y < ankle_y)) {
        std.debug.print("conformance: FAIL body joints out of order (head {d:.1} shoulder {d:.1} hip {d:.1} knee {d:.1} ankle {d:.1})\n", .{ head_y, shoulder_y, hip_y, knee_y, ankle_y });
        return false;
    }
    std.debug.print("conformance: PROOF named body joints land on the right anatomy (head {d:.1} to ankle {d:.1})\n", .{ head_y, ankle_y });
    return true;
}

/// Proves the named hand joints land on the right anatomy of a real raised
/// hand: the seven joints are distinct and every fingertip sits above the
/// wrist, so a swapped landmark or a mis-indexed joint would fail.
fn proveHandJoints(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const hand_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, hand_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(hand_bytes);
    if (abi.goss_session_enable_hand_tracking(session, hand_bytes.ptr, hand_bytes.len, 2) != .ok) {
        std.debug.print("conformance: FAIL hand-joint tracking enable\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, hand_corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.TrackFrameFailed;
    }
    var result: abi.HandResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_hand_result(session, &result) == .again or result.hand_count == 0) {
        std.Thread.yield() catch {};
        if (g_watch) c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000_000) return error.HandResultTimedOut;
    }

    var p: [7][3]f32 = undefined;
    var joint: u32 = 0;
    while (joint < 7) : (joint += 1) {
        if (abi.goss_session_hand_joint(session, 0, joint, &p[joint]) != .ok) {
            std.debug.print("conformance: FAIL hand joint {d} not read\n", .{joint});
            return false;
        }
    }
    const wrist = p[0];
    // The five fingertips must be distinct points, not one collapsed spot.
    for (1..6) |i| {
        for (i + 1..6) |k| {
            if (p[i][0] == p[k][0] and p[i][1] == p[k][1]) {
                std.debug.print("conformance: FAIL fingertips {d} and {d} share a point\n", .{ i, k });
                return false;
            }
        }
    }
    // A raised hand points its fingers up: every fingertip sits above the
    // wrist, a smaller y in image space.
    for (1..6) |i| {
        if (p[i][1] >= wrist[1]) {
            std.debug.print("conformance: FAIL fingertip {d} not above the wrist (y {d:.1} vs {d:.1})\n", .{ i, p[i][1], wrist[1] });
            return false;
        }
    }
    std.debug.print("conformance: PROOF named hand joints land on the right anatomy (wrist y {d:.1}, middle tip y {d:.1})\n", .{ wrist[1], p[3][1] });
    return true;
}

/// Proves lens physics end to end: a dropped marker settles onto the
/// slab across advancing frame timestamps, the settled frame differs
/// from the falling frame, and two runs land bit-identical.
fn provePhysicsDrop(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/physics-drop", ".lens-packages/physics-drop".len) != .ok) {
            std.debug.print("conformance: FAIL physics lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var falling_shot: []u8 = &.{};
        defer if (falling_shot.len > 0) gpa.free(falling_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();

            if (i == 4 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    std.debug.print("conformance: FAIL physics capture at frame {d}\n", .{i});
                    gpa.free(shot);
                    return false;
                }
                if (i == 4) falling_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, falling_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the settled frame must differ from the falling frame\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(falling_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-physics-drop.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL physics is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF lens physics settles deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves high-resolution capture: a still captured at a resolution
/// larger than the 400x300 preview swap chain comes back at that
/// resolution, not clamped to preview, and decodes; a still at the
/// submitted frame's own resolution comes back at the frame size.
fn proveHighResCapture(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL still capture lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // An explicit capture resolution well past the 400x300 preview.
    const cases = [_]struct { config: abi.CaptureConfig, want_w: u32, want_h: u32 }{
        .{ .config = .{ .width = 1200, .height = 900, .supersample = 0, .format = 0, .quality = 0 }, .want_w = 1200, .want_h = 900 },
        // Zero width and height captures at the submitted frame's size.
        .{ .config = .{ .width = 0, .height = 0, .supersample = 0, .format = 0, .quality = 0 }, .want_w = planes.width, .want_h = planes.height },
    };
    for (cases) |case| {
        var needed: usize = 0;
        var still_w: u32 = 0;
        var still_h: u32 = 0;
        var probe_byte: [1]u8 = undefined;
        if (abi.goss_engine_capture_still(engine, session, &case.config, &probe_byte, 0, &needed, &still_w, &still_h) != .invalid_argument or needed == 0) {
            std.debug.print("conformance: FAIL still size probe ({d}x{d})\n", .{ case.want_w, case.want_h });
            return false;
        }
        if (still_w != case.want_w or still_h != case.want_h) {
            std.debug.print("conformance: FAIL still captured at {d}x{d}, wanted {d}x{d} (preview is 400x300)\n", .{ still_w, still_h, case.want_w, case.want_h });
            return false;
        }
        const encoded = try gpa.alloc(u8, needed);
        defer gpa.free(encoded);
        var encoded_len: usize = 0;
        if (abi.goss_engine_capture_still(engine, session, &case.config, encoded.ptr, encoded.len, &encoded_len, &still_w, &still_h) != .ok) {
            std.debug.print("conformance: FAIL still capture ({d}x{d})\n", .{ case.want_w, case.want_h });
            return false;
        }
        const decoded = image_adapter.decode(gpa, encoded[0..encoded_len]) catch {
            std.debug.print("conformance: FAIL still does not decode\n", .{});
            return false;
        };
        defer gpa.free(decoded.rgba);
        if (decoded.width != case.want_w or decoded.height != case.want_h) {
            std.debug.print("conformance: FAIL still decoded at {d}x{d}\n", .{ decoded.width, decoded.height });
            return false;
        }
    }
    // Supersampling: the same output size, but the effect chain rendered
    // larger and box-downsampled, so the pixels differ from 1x (real
    // anti-aliasing) and two supersampled captures are byte-identical.
    const base_cfg = abi.CaptureConfig{ .width = 300, .height = 200, .supersample = 1, .format = 0, .quality = 0 };
    const ss_cfg = abi.CaptureConfig{ .width = 300, .height = 200, .supersample = 2, .format = 0, .quality = 0 };
    var ss_out_w: u32 = 0;
    var ss_out_h: u32 = 0;
    var base_len: usize = 0;
    var ss_len_a: usize = 0;
    var ss_len_b: usize = 0;
    const base_buf = try gpa.alloc(u8, 300 * 200 * 4 + 4096);
    defer gpa.free(base_buf);
    const ss_a = try gpa.alloc(u8, 300 * 200 * 4 + 4096);
    defer gpa.free(ss_a);
    const ss_b = try gpa.alloc(u8, 300 * 200 * 4 + 4096);
    defer gpa.free(ss_b);
    if (abi.goss_engine_capture_still(engine, session, &base_cfg, base_buf.ptr, base_buf.len, &base_len, &ss_out_w, &ss_out_h) != .ok) {
        std.debug.print("conformance: FAIL base capture for supersample compare\n", .{});
        return false;
    }
    if (abi.goss_engine_capture_still(engine, session, &ss_cfg, ss_a.ptr, ss_a.len, &ss_len_a, &ss_out_w, &ss_out_h) != .ok or ss_out_w != 300 or ss_out_h != 200) {
        std.debug.print("conformance: FAIL supersampled capture ({d}x{d})\n", .{ ss_out_w, ss_out_h });
        return false;
    }
    if (abi.goss_engine_capture_still(engine, session, &ss_cfg, ss_b.ptr, ss_b.len, &ss_len_b, &ss_out_w, &ss_out_h) != .ok) {
        std.debug.print("conformance: FAIL second supersampled capture\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, ss_a[0..ss_len_a], ss_b[0..ss_len_b])) {
        std.debug.print("conformance: FAIL supersampled capture is not deterministic\n", .{});
        return false;
    }
    if (std.mem.eql(u8, base_buf[0..base_len], ss_a[0..ss_len_a])) {
        std.debug.print("conformance: FAIL supersampling did not change the pixels\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF supersampled capture is the same size, anti-aliased (differs from 1x), and deterministic\n", .{});

    std.debug.print("conformance: PROOF stills capture at their own resolution ({d}x{d} source and 1200x900 explicit), decoupled from the 400x300 preview\n", .{ planes.width, planes.height });
    return true;
}

/// Proves tiled composition: a capture split across a lowered tile cap is
/// composited tile by tile and stitched, and the result is byte-identical
/// to the same capture as a single target. Tiling breaks the texture-size
/// ceiling on a full-sensor still without ever changing a pixel.
fn proveTiledCapture(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL tiled capture lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    const cfg = abi.CaptureConfig{ .width = 400, .height = 300, .supersample = 0, .format = 0, .quality = 0 };
    const buf_cap = 400 * 300 * 4 + 4096;

    // The reference: the whole 400x300 output composited in one target.
    const whole = try gpa.alloc(u8, buf_cap);
    defer gpa.free(whole);
    var whole_len: usize = 0;
    var ow: u32 = 0;
    var oh: u32 = 0;
    session.capture_tile_cap = 0;
    if (abi.goss_engine_capture_still(engine, session, &cfg, whole.ptr, whole.len, &whole_len, &ow, &oh) != .ok or ow != 400 or oh != 300) {
        std.debug.print("conformance: FAIL single-target capture for the tiling compare\n", .{});
        return false;
    }

    // Two lowered caps forcing different grids: 200 -> 2x2, 150 -> 3x2.
    // Each stitched result must match the single-target bytes exactly.
    const caps = [_]u32{ 200, 150 };
    for (caps) |tcap| {
        const tiled = try gpa.alloc(u8, buf_cap);
        defer gpa.free(tiled);
        var tiled_len: usize = 0;
        session.capture_tile_cap = tcap;
        const status = abi.goss_engine_capture_still(engine, session, &cfg, tiled.ptr, tiled.len, &tiled_len, &ow, &oh);
        session.capture_tile_cap = 0;
        if (status != .ok or ow != 400 or oh != 300) {
            std.debug.print("conformance: FAIL tiled capture at cap {d}\n", .{tcap});
            return false;
        }
        if (!std.mem.eql(u8, whole[0..whole_len], tiled[0..tiled_len])) {
            std.debug.print("conformance: FAIL tiled capture at cap {d} is not byte-identical to the single target\n", .{tcap});
            return false;
        }
    }

    std.debug.print("conformance: PROOF tiled composition stitches byte-identical to a single-target render (2x2 and 3x2 grids)\n", .{});
    return true;
}

/// Proves 3D content tiles past the texture cap through per-tile
/// off-center sub-frustums: mesh geometry (cloth) byte-identical to the
/// single target, particles deterministic and within a sub-pixel (their
/// billboards expand in clip space after the crop). The full-AR unlock.
fn prove3DTiledCapture(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const cases = [_]struct { lens: []const u8, exact: bool }{
        .{ .lens = ".lens-packages/cloth-flag", .exact = true },
        .{ .lens = ".lens-packages/ember-fountain", .exact = false },
    };
    const cfg = abi.CaptureConfig{ .width = 400, .height = 300, .supersample = 0, .format = 0, .quality = 0 };
    const buf_cap = 400 * 300 * 4 + 4096;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    for (cases) |case| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        if (abi.goss_session_activate_lens_from_directory(session, case.lens.ptr, case.lens.len) != .ok) {
            std.debug.print("conformance: FAIL 3D tiled lens activation ({s})\n", .{case.lens});
            return false;
        }
        for (0..30) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }

        var ow: u32 = 0;
        var oh: u32 = 0;
        const whole = try gpa.alloc(u8, buf_cap);
        defer gpa.free(whole);
        var whole_len: usize = 0;
        session.capture_tile_cap = 0;
        if (abi.goss_engine_capture_still(engine, session, &cfg, whole.ptr, whole.len, &whole_len, &ow, &oh) != .ok or ow != 400 or oh != 300) {
            std.debug.print("conformance: FAIL 3D single-target capture ({s})\n", .{case.lens});
            return false;
        }
        // A 200 cap forces a 2x2 grid; each tile draws the 3D content
        // through its own sub-frustum and the tiles stitch on the CPU.
        const tiled = try gpa.alloc(u8, buf_cap);
        defer gpa.free(tiled);
        var tiled_len: usize = 0;
        session.capture_tile_cap = 200;
        if (abi.goss_engine_capture_still(engine, session, &cfg, tiled.ptr, tiled.len, &tiled_len, &ow, &oh) != .ok or ow != 400 or oh != 300) {
            session.capture_tile_cap = 0;
            std.debug.print("conformance: FAIL 3D tiled capture ({s})\n", .{case.lens});
            return false;
        }
        const tiled2 = try gpa.alloc(u8, buf_cap);
        defer gpa.free(tiled2);
        var tiled2_len: usize = 0;
        _ = abi.goss_engine_capture_still(engine, session, &cfg, tiled2.ptr, tiled2.len, &tiled2_len, &ow, &oh);
        session.capture_tile_cap = 0;
        if (!std.mem.eql(u8, tiled[0..tiled_len], tiled2[0..tiled2_len])) {
            std.debug.print("conformance: FAIL 3D tiled capture is not deterministic ({s})\n", .{case.lens});
            return false;
        }

        if (case.exact) {
            if (!std.mem.eql(u8, whole[0..whole_len], tiled[0..tiled_len])) {
                std.debug.print("conformance: FAIL 3D mesh tiled is not byte-identical to the single target ({s})\n", .{case.lens});
                return false;
            }
        } else {
            const dec_whole = image_adapter.decode(gpa, whole[0..whole_len]) catch return false;
            defer gpa.free(dec_whole.rgba);
            const dec_tiled = image_adapter.decode(gpa, tiled[0..tiled_len]) catch return false;
            defer gpa.free(dec_tiled.rgba);
            var total_error: u64 = 0;
            var differing: u64 = 0;
            for (dec_whole.rgba, dec_tiled.rgba) |a, b| {
                const d = @abs(@as(i32, a) - @as(i32, b));
                total_error += @intCast(d);
                if (d != 0) differing += 1;
            }
            const mean_error = @as(f64, @floatFromInt(total_error)) / @as(f64, @floatFromInt(dec_whole.rgba.len));
            const differing_frac = @as(f64, @floatFromInt(differing)) / @as(f64, @floatFromInt(dec_whole.rgba.len));
            if (mean_error > 0.5 or differing_frac > 0.02) {
                std.debug.print("conformance: FAIL 3D particle tiled diverges (mean {d:.3}, {d:.2}% differ) ({s})\n", .{ mean_error, differing_frac * 100.0, case.lens });
                return false;
            }
        }
    }

    std.debug.print("conformance: PROOF 3D content tiles past the texture cap through per-tile sub-frustums: cloth mesh byte-identical to the single target, particles deterministic and within a sub-pixel of it - full-AR stills\n", .{});
    return true;
}

/// Proves the engine's own photo encoding and color management: the
/// built-in JPEG decodes back through the platform and is deterministic,
/// a wide-gamut PNG carries cHRM/gAMA and a wide-gamut JPEG carries an
/// ICC profile, while a plain sRGB capture carries neither.
fn proveColorManagedCapture(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL color-managed capture lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    const capture = struct {
        fn run(g: std.mem.Allocator, e: *abi.Engine, sess: *abi.Session, cfg: abi.CaptureConfig) ![]u8 {
            var needed: usize = 0;
            var cw: u32 = 0;
            var ch: u32 = 0;
            var probe: [1]u8 = undefined;
            _ = abi.goss_engine_capture_still(e, sess, &cfg, &probe, 0, &needed, &cw, &ch);
            if (needed == 0) return error.CaptureProbeFailed;
            const buf = try g.alloc(u8, needed);
            errdefer g.free(buf);
            var out_len: usize = 0;
            if (abi.goss_engine_capture_still(e, sess, &cfg, buf.ptr, buf.len, &out_len, &cw, &ch) != .ok) return error.CaptureFailed;
            return g.realloc(buf, out_len);
        }
    }.run;

    const base = abi.CaptureConfig{ .width = 200, .height = 150, .supersample = 0, .format = 0, .quality = 0 };

    // Wide-gamut PNG carries cHRM and gAMA; the sRGB one carries neither.
    var p3_png_cfg = base;
    p3_png_cfg.color_space = 1;
    const p3_png = try capture(gpa, engine, session, p3_png_cfg);
    defer gpa.free(p3_png);
    const srgb_png = try capture(gpa, engine, session, base);
    defer gpa.free(srgb_png);
    if (std.mem.indexOf(u8, p3_png, "cHRM") == null or std.mem.indexOf(u8, p3_png, "gAMA") == null) {
        std.debug.print("conformance: FAIL Display-P3 PNG is missing its cHRM/gAMA chunks\n", .{});
        return false;
    }
    if (std.mem.indexOf(u8, srgb_png, "cHRM") != null) {
        std.debug.print("conformance: FAIL sRGB PNG unexpectedly carries a gamut chunk\n", .{});
        return false;
    }

    // JPEG comes from the built-in encoder: it must decode back through
    // the platform decoder, and the wide-gamut one carries an ICC.
    var p3_jpeg_cfg = base;
    p3_jpeg_cfg.format = 1;
    p3_jpeg_cfg.color_space = 1;
    p3_jpeg_cfg.quality = 90;
    const p3_jpeg = try capture(gpa, engine, session, p3_jpeg_cfg);
    defer gpa.free(p3_jpeg);
    var srgb_jpeg_cfg = base;
    srgb_jpeg_cfg.format = 1;
    srgb_jpeg_cfg.quality = 90;
    const srgb_jpeg = try capture(gpa, engine, session, srgb_jpeg_cfg);
    defer gpa.free(srgb_jpeg);
    if (std.mem.indexOf(u8, p3_jpeg, "ICC_PROFILE") == null) {
        std.debug.print("conformance: FAIL Display-P3 JPEG is missing its ICC profile\n", .{});
        return false;
    }
    if (std.mem.indexOf(u8, srgb_jpeg, "ICC_PROFILE") != null) {
        std.debug.print("conformance: FAIL sRGB JPEG unexpectedly carries an ICC profile\n", .{});
        return false;
    }
    const decoded = try gpa.alloc(u8, 200 * 150 * 4);
    defer gpa.free(decoded);
    var dw: u32 = 0;
    var dh: u32 = 0;
    abi.photoDecode(srgb_jpeg, decoded, &dw, &dh) catch {
        std.debug.print("conformance: FAIL built-in JPEG does not decode\n", .{});
        return false;
    };
    if (dw != 200 or dh != 150) {
        std.debug.print("conformance: FAIL built-in JPEG decoded at {d}x{d}\n", .{ dw, dh });
        return false;
    }

    // The built-in encoder is deterministic.
    const again = try capture(gpa, engine, session, srgb_jpeg_cfg);
    defer gpa.free(again);
    if (!std.mem.eql(u8, srgb_jpeg, again)) {
        std.debug.print("conformance: FAIL built-in JPEG is not deterministic\n", .{});
        return false;
    }

    // A 16-bit PNG capture is a real 16-bit container: IHDR reports bit
    // depth 16 (the byte past the 8-byte signature and the width/height
    // fields), and it still decodes back at the right size.
    var png16_cfg = base;
    png16_cfg.bit_depth = 16;
    const png16 = try capture(gpa, engine, session, png16_cfg);
    defer gpa.free(png16);
    if (png16[24] != 16) {
        std.debug.print("conformance: FAIL 16-bit PNG IHDR reports bit depth {d}\n", .{png16[24]});
        return false;
    }
    const decoded16 = image_adapter.decode(gpa, png16) catch {
        std.debug.print("conformance: FAIL 16-bit PNG does not decode\n", .{});
        return false;
    };
    defer gpa.free(decoded16.rgba);
    if (decoded16.width != 200 or decoded16.height != 150) {
        std.debug.print("conformance: FAIL 16-bit PNG decoded at {d}x{d}\n", .{ decoded16.width, decoded16.height });
        return false;
    }

    std.debug.print("conformance: PROOF the built-in JPEG encoder decodes through the platform and is deterministic; wide-gamut PNG/JPEG carry cHRM/gAMA and ICC, sRGB carries neither; a 16-bit PNG is a real 16-bit container\n", .{});
    return true;
}

/// Writes a lens bundle whose ml.infer node runs a bundled author model, the
/// way an author ships one. It binds the segmenter mask center (256x256, so
/// 128*256+128 - foreground on a centered portrait, background on a blank frame)
/// to a parameter defaulting to a sentinel the first inference overwrites.
fn writeMlInferLens(dir: []const u8, model: []const u8) !void {
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.ml-infer","version":"1.0.0","display_name":"BYO Model","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"score","type":"float","default":-999.0,"min":-1000000.0,"max":1000000.0}],
        \\ "nodes":[{"id":"byo","type":"ml.infer","params":{},
        \\   "ml":{"model":"model.tflite","outputs":[{"tensor":0,"index":32896,"param":"score"}]}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/manifest.json", .{dir});
    defer std.heap.page_allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/assets/model.tflite", .{dir});
    defer std.heap.page_allocator.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Activates the byo-ml bundle on a fresh session, feeds it one frame, and
/// returns the parameter the model drove. Waits on the async worker's first
/// publish by watching the sentinel default flip to a real value, which is
/// magnitude-independent so it never races the inference result.
fn runMlInferOnce(engine: *abi.Engine, bundle_path: []const u8, param: []const u8, sentinel: f32, planes: Nv12Copy) !f32 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len) != .ok) {
        std.debug.print("conformance: FAIL byo-ml lens activation\n", .{});
        return error.MlActivationFailed;
    }
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    const signals = std.mem.zeroes(abi.LensSignals);
    var value: f32 = sentinel;
    var polls: usize = 0;
    while (value == sentinel) {
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.MlTrackFrameFailed;
        }
        std.Thread.yield() catch {};
        _ = abi.goss_session_tick_lens(session, 16000, &signals);
        _ = abi.goss_session_parameter_value(session, param.ptr, param.len, &value);
        polls += 1;
        if (polls > 100_000_000) return error.MlInferTimedOut;
    }
    return value;
}

/// Proves the bring-your-own model path through the real ABI: a bundled author
/// model runs on the camera frame off the render thread and drives a lens
/// parameter. The value is finite, stable across two runs, and responds to the
/// pixels (a portrait and a flat frame drive it apart), so it is real inference.
fn proveMlInfer(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const model = try std.Io.Dir.cwd().readFileAlloc(harness_io, single_class_model_path, gpa, .limited(32 << 20));
    defer gpa.free(model);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-infer-lens/assets");
    try writeMlInferLens("zig-out/ml-infer-lens", model);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    // A flat gray frame of the same size: a control with no subject, so its
    // inference must differ from the portrait if the model truly ran on pixels.
    const gray_rgba = try gpa.alloc(u8, @as(usize, corpus.frame.width) * corpus.frame.height * 4);
    defer gpa.free(gray_rgba);
    @memset(gray_rgba, 128);
    const gray = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = gray_rgba }, .width = corpus.frame.width, .height = corpus.frame.height });
    defer gray.deinit(gpa);

    const person_a = try runMlInferOnce(engine, "zig-out/ml-infer-lens", "score", -999.0, person);
    const person_b = try runMlInferOnce(engine, "zig-out/ml-infer-lens", "score", -999.0, person);
    const gray_score = try runMlInferOnce(engine, "zig-out/ml-infer-lens", "score", -999.0, gray);

    if (!std.math.isFinite(person_a) or !std.math.isFinite(gray_score)) {
        std.debug.print("conformance: FAIL the byo model published a non-finite value\n", .{});
        return false;
    }
    if (person_a != person_b) {
        std.debug.print("conformance: FAIL byo inference is not deterministic ({d} vs {d})\n", .{ person_a, person_b });
        return false;
    }
    if (@abs(person_a - gray_score) < 1e-4) {
        std.debug.print("conformance: FAIL byo inference did not respond to the frame ({d} vs {d})\n", .{ person_a, gray_score });
        return false;
    }
    std.debug.print("conformance: PROOF a bundled author model runs through the ml.infer node and drives a lens parameter from the camera frame, deterministically\n", .{});
    return true;
}

/// A minimal ONNX protobuf emitter, enough to hand-build the one net the ONNX
/// proof runs; the engine's own tests cover general parsing. Fields are written
/// with explicit wire tags the way the reader expects them.
const OnnxPb = struct {
    buf: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn varint(p: *OnnxPb, v_in: u64) void {
        var v = v_in;
        while (true) {
            var byte: u8 = @truncate(v & 0x7f);
            v >>= 7;
            if (v != 0) byte |= 0x80;
            p.buf.append(p.a, byte) catch unreachable;
            if (v == 0) break;
        }
    }
    fn tag(p: *OnnxPb, field: u32, wire: u3) void {
        p.varint((@as(u64, field) << 3) | wire);
    }
    fn f32field(p: *OnnxPb, field: u32, value: f32) void {
        p.tag(field, 5);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(value), .little);
        p.buf.appendSlice(p.a, &b) catch unreachable;
    }
    fn varintField(p: *OnnxPb, field: u32, value: i64) void {
        p.tag(field, 0);
        p.varint(@bitCast(value));
    }
    fn bytesField(p: *OnnxPb, field: u32, value: []const u8) void {
        p.tag(field, 2);
        p.varint(value.len);
        p.buf.appendSlice(p.a, value) catch unreachable;
    }
};

/// A synthetic audio model: Add(x, x) over a [1, N] window, doubling every
/// sample, so the output's first element is twice the newest window sample.
fn buildOnnxAudioProbe(a: std.mem.Allocator, n: i64) []const u8 {
    const add = onnxNode(a, "Add", &.{ "x", "x" }, &.{"out"}, &.{});
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, add);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, n }));
    g.bytesField(12, onnxValueInfo(a, "out", &.{ 1, n }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// Writes an audio.infer lens: a bounded window model driving the `level`
/// parameter from the microphone, plus the model asset.
fn writeAudioLens(dir: []const u8, model: []const u8) !void {
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.audio-infer","version":"1.0.0","display_name":"BYO Audio","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"level","type":"float","default":-999.0,"min":-1000000.0,"max":1000000.0}],
        \\ "nodes":[{"id":"aud","type":"audio.infer","params":{},
        \\   "audio":{"model":"model.onnx","outputs":[{"tensor":0,"index":0,"param":"level"}]}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/model.onnx", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Activates the audio lens, submits blocks of constant-amplitude audio while
/// ticking, and reports the `level` parameter once the worker has run over the
/// ring window (the default sentinel flips to a real value).
fn runAudioLevel(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, amp: f32) !f32 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const samples = try gpa.alloc(f32, 512);
    defer gpa.free(samples);
    @memset(samples, amp);
    const signals = std.mem.zeroes(abi.LensSignals);
    var value: f32 = -999.0;
    var polls: usize = 0;
    while (value == -999.0) {
        _ = abi.goss_session_submit_audio(session, samples.ptr, 512, 48000, 1, @intCast(1000 + polls * 1000));
        _ = abi.goss_session_tick_lens(session, 16000, &signals);
        _ = abi.goss_session_parameter_value(session, "level", "level".len, &value);
        polls += 1;
        if (polls > 100000) return error.AudioInferTimedOut;
    }
    return value;
}

/// Proves the audio.infer core: a bounded window model runs over the microphone
/// ring and drives a lens parameter. A doubling net reads about twice the
/// amplitude of a constant tone and near zero on silence, so it sees real audio.
fn proveAudioInfer(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxAudioProbe(arena.allocator(), 256);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/audio-infer/assets");
    try writeAudioLens("zig-out/audio-infer", model);

    const loud = try runAudioLevel(gpa, engine, "zig-out/audio-infer", 0.3);
    const quiet = try runAudioLevel(gpa, engine, "zig-out/audio-infer", 0.0);
    if (!(loud > 0.4 and loud < 0.8)) {
        std.debug.print("conformance: FAIL audio.infer did not read about twice a 0.3 tone (level {d})\n", .{loud});
        return false;
    }
    if (!(quiet > -0.05 and quiet < 0.05)) {
        std.debug.print("conformance: FAIL audio.infer did not read near zero on silence (level {d})\n", .{quiet});
        return false;
    }
    std.debug.print("conformance: PROOF an audio.infer node runs a bounded model over the microphone window and drives a parameter: a doubling net reads about twice a 0.3 tone ({d:.3}) and near zero on silence ({d:.3})\n", .{ loud, quiet });
    return true;
}

/// A synthetic caption net: MatMul(window[1,8], W[8,9]) yields [1,9] logits read
/// as three timesteps of three classes. W is built so a positive constant window
/// argmaxes each timestep to h, blank, i, which greedy-CTC-decodes to "hi".
fn buildOnnxCaptionProbe(a: std.mem.Allocator) []const u8 {
    const n = 8;
    const m = 9; // 3 timesteps * 3 classes
    // Per output column the target logit weight; classes are blank(0), h(1), i(2).
    const desired = [_]f32{ 0, 1, 0, 1, 0, 0, 0, 0, 1 };
    var w: OnnxPb = .{ .a = a };
    w.varintField(1, n);
    w.varintField(1, m);
    w.varintField(2, 1);
    var raw: std.ArrayList(u8) = .empty;
    for (0..n) |_| for (0..m) |j| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(desired[j] / @as(f32, n)), .little);
        raw.appendSlice(a, &b) catch unreachable;
    };
    w.bytesField(9, raw.items);
    w.bytesField(8, "W");
    const mm = onnxNode(a, "MatMul", &.{ "x", "W" }, &.{"out"}, &.{});
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, mm);
    g.bytesField(5, w.buf.items);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, n }));
    g.bytesField(11, onnxValueInfo(a, "W", &.{ n, m }));
    g.bytesField(12, onnxValueInfo(a, "out", &.{ 1, m }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// Writes a caption lens: an audio.infer node with a caption binding, plus the
/// model and a three-line labels file (blank, h, i).
fn writeCaptionLens(dir: []const u8, model: []const u8) !void {
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.caption","version":"1.0.0","display_name":"Caption","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"aud","type":"audio.infer","params":{},
        \\   "audio":{"model":"model.onnx","outputs":[],"caption":{"tensor":0,"labels":"labels"}}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/model.onnx", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
    const labels_path = try std.fmt.allocPrint(page, "{s}/assets/labels.txt", .{dir});
    defer page.free(labels_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = labels_path, .data = "_\nh\ni" });
}

/// Activates the caption lens, submits audio while ticking, and reads the decoded
/// caption by the node id once it lands. Caller owns the returned text.
fn runCaption(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, node_id: []const u8) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const samples = try gpa.alloc(f32, 512);
    defer gpa.free(samples);
    @memset(samples, 0.3);
    const signals = std.mem.zeroes(abi.LensSignals);
    var buf: [256]u8 = undefined;
    var polls: usize = 0;
    while (true) : (polls += 1) {
        _ = abi.goss_session_submit_audio(session, samples.ptr, 512, 48000, 1, @intCast(1000 + polls * 1000));
        _ = abi.goss_session_tick_lens(session, 16000, &signals);
        var out_len: usize = 0;
        const st = abi.goss_session_caption_text(session, node_id.ptr, node_id.len, &buf, buf.len, &out_len);
        if (st == .ok and out_len > 0) return gpa.dupe(u8, buf[0..out_len]);
        if (polls > 100000) return error.CaptionTimedOut;
    }
}

/// Proves on-device ASR captions: an audio.infer node CTC-decodes a logits tensor
/// into text read back by node id. The synthetic net's fixed logits decode to the
/// known word "hi", so the whole path - window, model, greedy CTC, labels, and the
/// caption ABI - is exercised end to end.
fn proveCaption(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxCaptionProbe(arena.allocator());
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/caption/assets");
    try writeCaptionLens("zig-out/caption", model);

    const text = try runCaption(gpa, engine, "zig-out/caption", "aud");
    defer gpa.free(text);
    if (!std.mem.eql(u8, text, "hi")) {
        std.debug.print("conformance: FAIL caption decoded '{s}', wanted 'hi'\n", .{text});
        return false;
    }
    std.debug.print("conformance: PROOF an audio.infer caption binding greedy-CTC-decodes a logits tensor into text read by node id: the synthetic net's fixed logits decode to 'hi'\n", .{});
    return true;
}

/// A synthetic speaker-embedding net: MatMul(window[1,4], W[4,2]) yields a
/// two-dimensional embedding whose first axis is the window's constant energy and
/// second its alternating energy, so a flat tone and an alternating tone map to
/// orthogonal embeddings the diarizer reads as two speakers.
fn buildOnnxDiarizeProbe(a: std.mem.Allocator) []const u8 {
    const n = 4;
    const d = 2;
    const wv = [_]f32{ 1, 1, 1, -1, 1, 1, 1, -1 }; // [4,2] row-major: sum axis, alternating axis
    var w: OnnxPb = .{ .a = a };
    w.varintField(1, n);
    w.varintField(1, d);
    w.varintField(2, 1);
    var raw: std.ArrayList(u8) = .empty;
    for (wv) |v| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(v), .little);
        raw.appendSlice(a, &b) catch unreachable;
    }
    w.bytesField(9, raw.items);
    w.bytesField(8, "W");
    const mm = onnxNode(a, "MatMul", &.{ "x", "W" }, &.{"out"}, &.{});
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, mm);
    g.bytesField(5, w.buf.items);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, n }));
    g.bytesField(11, onnxValueInfo(a, "W", &.{ n, d }));
    g.bytesField(12, onnxValueInfo(a, "out", &.{ 1, d }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// Writes a diarize lens: an audio.infer node whose embedding output drives a
/// `speaker` parameter, plus the model.
fn writeDiarizeLens(dir: []const u8, model: []const u8) !void {
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.diarize","version":"1.0.0","display_name":"Diarize","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"speaker","type":"float","default":-999.0,"min":-1000000.0,"max":1000000.0}],
        \\ "nodes":[{"id":"aud","type":"audio.infer","params":{},
        \\   "audio":{"model":"model.onnx","outputs":[],"diarize":{"embed_tensor":0,"max_speakers":8,"threshold":0.75,"param":"speaker"}}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/model.onnx", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Submits an audio pattern several times through the diarize lens and returns
/// the speaker parameter it settled on.
fn diarizeSpeaker(session: *abi.Session, engine: *abi.Engine, pattern: []const f32, ts: *i64) f32 {
    const signals = std.mem.zeroes(abi.LensSignals);
    for (0..6) |_| {
        _ = abi.goss_session_submit_audio(session, pattern.ptr, @intCast(pattern.len), 48000, 1, ts.*);
        ts.* += 1000;
        _ = abi.goss_session_tick_lens(session, 16000, &signals);
    }
    _ = engine;
    var value: f32 = -999;
    _ = abi.goss_session_parameter_value(session, "speaker", "speaker".len, &value);
    return value;
}

/// Proves speaker diarization: an audio.infer embedding output is clustered into
/// speaker ids. A flat tone and an alternating tone map to orthogonal embeddings,
/// so they read as two distinct speakers, and returning to the first tone reads
/// the first speaker again, showing stable clustering.
fn proveDiarize(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxDiarizeProbe(arena.allocator());
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/diarize/assets");
    try writeDiarizeLens("zig-out/diarize", model);

    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, "zig-out/diarize", "zig-out/diarize".len) != .ok) return error.ActivationFailed;

    const flat = [_]f32{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 };
    const alt = [_]f32{ 0.5, -0.5, 0.5, -0.5, 0.5, -0.5, 0.5, -0.5 };
    var ts: i64 = 1000;
    const s_flat = diarizeSpeaker(session, engine, &flat, &ts);
    const s_alt = diarizeSpeaker(session, engine, &alt, &ts);
    const s_flat2 = diarizeSpeaker(session, engine, &flat, &ts);
    if (s_flat == s_alt) {
        std.debug.print("conformance: FAIL diarize gave the two tones the same speaker ({d})\n", .{s_flat});
        return false;
    }
    if (s_flat != s_flat2) {
        std.debug.print("conformance: FAIL diarize did not return the first tone to its speaker ({d} vs {d})\n", .{ s_flat, s_flat2 });
        return false;
    }
    std.debug.print("conformance: PROOF an audio.infer diarize binding clusters embeddings into speakers: a flat tone and an alternating tone read as two distinct speakers ({d}, {d}) and the flat tone returns to its own ({d})\n", .{ s_flat, s_alt, s_flat2 });
    return true;
}

/// A synthetic translation decoder: MatMul(prev_onehot[1,4], W[4,4]) yields the
/// next-token logits, ignoring the memory input. W is a transition matrix where
/// bos leads to "a", "a" to "b", and "b" to eos, so the greedy loop emits "ab".
fn buildOnnxTranslateDecoder(a: std.mem.Allocator) []const u8 {
    const v = 4; // tokens: bos(0), a(1), b(2), eos(3)
    const wv = [_]f32{ 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0 };
    var w: OnnxPb = .{ .a = a };
    w.varintField(1, v);
    w.varintField(1, v);
    w.varintField(2, 1);
    var raw: std.ArrayList(u8) = .empty;
    for (wv) |vv| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(vv), .little);
        raw.appendSlice(a, &b) catch unreachable;
    }
    w.bytesField(9, raw.items);
    w.bytesField(8, "W");
    const mm = onnxNode(a, "MatMul", &.{ "prev", "W" }, &.{"out"}, &.{});
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, mm);
    g.bytesField(5, w.buf.items);
    g.bytesField(11, onnxValueInfo(a, "mem", &.{ 1, 4 })); // input 0, the encoder memory (unused here)
    g.bytesField(11, onnxValueInfo(a, "prev", &.{ 1, v })); // input 1, the previous token one-hot
    g.bytesField(11, onnxValueInfo(a, "W", &.{ v, v }));
    g.bytesField(12, onnxValueInfo(a, "out", &.{ 1, v }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// Writes a translate lens: an audio.infer node whose model is the encoder and
/// whose translate binding names the decoder step model, plus both models and a
/// four-line tokens file.
fn writeTranslateLens(dir: []const u8, encoder: []const u8, decoder: []const u8) !void {
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.translate","version":"1.0.0","display_name":"Translate","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"aud","type":"audio.infer","params":{},
        \\   "audio":{"model":"model.onnx","outputs":[],"translate":{"decoder":"decoder.onnx","tokens":"tokens","memory_tensor":0,"max_tokens":8,"bos":0,"eos":3}}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const enc_path = try std.fmt.allocPrint(page, "{s}/assets/model.onnx", .{dir});
    defer page.free(enc_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = enc_path, .data = encoder });
    const dec_path = try std.fmt.allocPrint(page, "{s}/assets/decoder.onnx", .{dir});
    defer page.free(dec_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = dec_path, .data = decoder });
    const tokens_path = try std.fmt.allocPrint(page, "{s}/assets/tokens.txt", .{dir});
    defer page.free(tokens_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = tokens_path, .data = "<bos>\na\nb\n<eos>" });
}

/// Proves live translation: an audio.infer encoder feeds a greedy autoregressive
/// decoder loop that emits tokens until eos, detokenized into text read like a
/// caption. The synthetic transition decoder walks bos to "a" to "b" to eos, so
/// the whole encode then decode loop yields "ab".
fn proveTranslate(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const encoder = buildOnnxAudioProbe(arena.allocator(), 4);
    const decoder = buildOnnxTranslateDecoder(arena.allocator());
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/translate/assets");
    try writeTranslateLens("zig-out/translate", encoder, decoder);

    const text = try runCaption(gpa, engine, "zig-out/translate", "aud");
    defer gpa.free(text);
    if (!std.mem.eql(u8, text, "ab")) {
        std.debug.print("conformance: FAIL translate decoded '{s}', wanted 'ab'\n", .{text});
        return false;
    }
    std.debug.print("conformance: PROOF an audio.infer translate binding runs a greedy autoregressive decoder over the encoder memory: the synthetic transition decoder walks bos to 'a' to 'b' to eos, yielding 'ab'\n", .{});
    return true;
}

/// A synthetic text-to-speech model: MatMul(chars[1,16], W[16,256]) yields a PCM
/// block, so a non-empty caption (its characters) synthesizes a non-zero voice.
fn buildOnnxDubProbe(a: std.mem.Allocator) []const u8 {
    const chars_n = 16;
    const samp = 256;
    var w: OnnxPb = .{ .a = a };
    w.varintField(1, chars_n);
    w.varintField(1, samp);
    w.varintField(2, 1);
    var raw: std.ArrayList(u8) = .empty;
    for (0..chars_n * samp) |_| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(@as(f32, 0.5)), .little);
        raw.appendSlice(a, &b) catch unreachable;
    }
    w.bytesField(9, raw.items);
    w.bytesField(8, "W");
    const mm = onnxNode(a, "MatMul", &.{ "chars", "W" }, &.{"pcm"}, &.{});
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, mm);
    g.bytesField(5, w.buf.items);
    g.bytesField(11, onnxValueInfo(a, "chars", &.{ 1, chars_n }));
    g.bytesField(11, onnxValueInfo(a, "W", &.{ chars_n, samp }));
    g.bytesField(12, onnxValueInfo(a, "pcm", &.{ 1, samp }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// Writes a dub lens: an audio.infer node that captions and also dubs, plus the
/// caption model, the tts model, and the labels file.
fn writeDubLens(dir: []const u8, caption_model: []const u8, tts_model: []const u8) !void {
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.dub","version":"1.0.0","display_name":"Dub","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"aud","type":"audio.infer","params":{},
        \\   "audio":{"model":"model.onnx","outputs":[],"caption":{"tensor":0,"labels":"labels"},"dub":{"model":"tts.onnx","rate":22050}}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const enc_path = try std.fmt.allocPrint(page, "{s}/assets/model.onnx", .{dir});
    defer page.free(enc_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = enc_path, .data = caption_model });
    const tts_path = try std.fmt.allocPrint(page, "{s}/assets/tts.onnx", .{dir});
    defer page.free(tts_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = tts_path, .data = tts_model });
    const labels_path = try std.fmt.allocPrint(page, "{s}/assets/labels.txt", .{dir});
    defer page.free(labels_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = labels_path, .data = "_\nh\ni" });
}

/// Activates the dub lens with dubbing on or off, submits audio while ticking so
/// the caption decodes and the dub fires, then pulls the mixed lens audio and
/// returns its total energy.
fn dubEnergy(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, enabled: u32) !u64 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    _ = abi.goss_session_set_dubbing(session, enabled);
    const samples = try gpa.alloc(f32, 512);
    defer gpa.free(samples);
    @memset(samples, 0.3);
    const signals = std.mem.zeroes(abi.LensSignals);
    for (0..20) |k| {
        _ = abi.goss_session_submit_audio(session, samples.ptr, 512, 48000, 1, @intCast(1000 + k * 1000));
        _ = abi.goss_session_tick_lens(session, 16000, &signals);
    }
    var out = [_]i16{0} ** 4096;
    _ = abi.goss_session_pull_audio(session, &out, 2048);
    var e: u64 = 0;
    for (out) |v| e += @abs(@as(i64, v));
    return e;
}

/// Proves on-device dubbing: with dubbing enabled a dub-bound audio.infer node
/// synthesizes its decoded caption to speech and plays it into the lens mixer, so
/// the pulled audio carries a voice; with dubbing off the same lens is silent.
fn proveDub(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const caption_model = buildOnnxCaptionProbe(arena.allocator());
    const tts_model = buildOnnxDubProbe(arena.allocator());
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/dub/assets");
    try writeDubLens("zig-out/dub", caption_model, tts_model);

    const on = try dubEnergy(gpa, engine, "zig-out/dub", 1);
    const off = try dubEnergy(gpa, engine, "zig-out/dub", 0);
    if (on == 0) {
        std.debug.print("conformance: FAIL dubbing enabled produced no voice in the pulled audio\n", .{});
        return false;
    }
    if (off != 0) {
        std.debug.print("conformance: FAIL dubbing disabled still played a voice (energy {d})\n", .{off});
        return false;
    }
    std.debug.print("conformance: PROOF a dub binding synthesizes the decoded caption to speech and plays it into the mixer: the pulled audio carries a voice with dubbing on ({d}) and is silent with it off ({d})\n", .{ on, off });
    return true;
}

/// Emits an ONNX net that sums the three input channels (a 1x1 conv with unit
/// weights) then averages the plane, so its one output is the frame's mean
/// brightness. NCHW input [1,3,8,8] exercises the core's channel transpose.
fn buildOnnxProbe(a: std.mem.Allocator) []const u8 {
    const side: i64 = 8;
    // W initializer [1,3,1,1] of ones.
    var w: OnnxPb = .{ .a = a };
    inline for (.{ 1, 3, 1, 1 }) |d| w.varintField(1, d);
    w.varintField(2, 1); // FLOAT
    var raw: std.ArrayList(u8) = .empty;
    for (0..3) |_| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(@as(f32, 1)), .little);
        raw.appendSlice(a, &b) catch unreachable;
    }
    w.bytesField(9, raw.items);
    w.bytesField(8, "W");

    const conv = onnxNode(a, "Conv", &.{ "x", "W" }, &.{"h"}, &.{
        .{ .name = "kernel_shape", .ints = &.{ 1, 1 } },
        .{ .name = "strides", .ints = &.{ 1, 1 } },
        .{ .name = "pads", .ints = &.{ 0, 0, 0, 0 } },
    });
    const pool = onnxNode(a, "GlobalAveragePool", &.{"h"}, &.{"y"}, &.{});

    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, conv);
    g.bytesField(1, pool);
    g.bytesField(5, w.buf.items);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, 3, side, side }));
    g.bytesField(11, onnxValueInfo(a, "W", &.{ 1, 3, 1, 1 }));
    g.bytesField(12, onnxValueInfo(a, "y", &.{ 1, 1, 1, 1 }));

    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7); // ir_version
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

const OnnxAttr = struct { name: []const u8, ints: []const i64 = &.{}, i: ?i64 = null };

fn onnxNode(a: std.mem.Allocator, op: []const u8, inputs: []const []const u8, outputs: []const []const u8, attrs: []const OnnxAttr) []const u8 {
    var nd: OnnxPb = .{ .a = a };
    for (inputs) |i| nd.bytesField(1, i);
    for (outputs) |o| nd.bytesField(2, o);
    nd.bytesField(4, op);
    for (attrs) |at| {
        var ap: OnnxPb = .{ .a = a };
        ap.bytesField(1, at.name);
        if (at.i) |iv| ap.varintField(3, iv);
        for (at.ints) |v| ap.varintField(8, v);
        nd.bytesField(5, ap.buf.items);
    }
    return nd.buf.items;
}

fn onnxValueInfo(a: std.mem.Allocator, name: []const u8, dims: []const i64) []const u8 {
    var shape: OnnxPb = .{ .a = a };
    for (dims) |d| {
        var dim: OnnxPb = .{ .a = a };
        dim.varintField(1, d);
        shape.bytesField(1, dim.buf.items);
    }
    var tt: OnnxPb = .{ .a = a };
    tt.bytesField(2, shape.buf.items);
    var typ: OnnxPb = .{ .a = a };
    typ.bytesField(1, tt.buf.items);
    var vi: OnnxPb = .{ .a = a };
    vi.bytesField(1, name);
    vi.bytesField(2, typ.buf.items);
    return vi.buf.items;
}

/// A one-element float initializer tensor, the constant a Mul scales its input by.
fn onnxScalarInit(a: std.mem.Allocator, name: []const u8, value: f32) []const u8 {
    var t: OnnxPb = .{ .a = a };
    t.varintField(1, 1); // dims = [1]
    t.varintField(2, 1); // data_type FLOAT
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @bitCast(value), .little);
    t.bytesField(9, &b); // raw_data
    t.bytesField(8, name); // name
    return t.buf.items;
}

/// A net that averages N square-RGB image inputs: it chains Add across f0..f(N-1)
/// then scales by 1/N, so the output is the per-pixel mean of the fed frames.
fn onnxMeanModel(a: std.mem.Allocator, n: usize, side: i64) []const u8 {
    var g: OnnxPb = .{ .a = a };
    var acc: []const u8 = "f0";
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const in_name = std.fmt.allocPrint(a, "f{d}", .{i}) catch unreachable;
        const out_name = std.fmt.allocPrint(a, "t{d}", .{i}) catch unreachable;
        g.bytesField(1, onnxNode(a, "Add", &.{ acc, in_name }, &.{out_name}, &.{}));
        acc = out_name;
    }
    g.bytesField(5, onnxScalarInit(a, "scale", 1.0 / @as(f32, @floatFromInt(n))));
    g.bytesField(1, onnxNode(a, "Mul", &.{ acc, "scale" }, &.{"y"}, &.{}));
    for (0..n) |k| {
        const name = std.fmt.allocPrint(a, "f{d}", .{k}) catch unreachable;
        g.bytesField(11, onnxValueInfo(a, name, &.{ 1, 3, side, side }));
    }
    g.bytesField(12, onnxValueInfo(a, "y", &.{ 1, 3, side, side }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// A net that interpolates two frames by a scalar phase t: y = f0 + t*(f1 - f0),
/// so t=0 is the first frame, t=1 the second, and the phase input rides input 2.
fn onnxLerpModel(a: std.mem.Allocator, side: i64) []const u8 {
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, onnxNode(a, "Sub", &.{ "f1", "f0" }, &.{"d"}, &.{}));
    g.bytesField(1, onnxNode(a, "Mul", &.{ "d", "t" }, &.{"td"}, &.{}));
    g.bytesField(1, onnxNode(a, "Add", &.{ "f0", "td" }, &.{"y"}, &.{}));
    g.bytesField(11, onnxValueInfo(a, "f0", &.{ 1, 3, side, side }));
    g.bytesField(11, onnxValueInfo(a, "f1", &.{ 1, 3, side, side }));
    g.bytesField(11, onnxValueInfo(a, "t", &.{1}));
    g.bytesField(12, onnxValueInfo(a, "y", &.{ 1, 3, side, side }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

fn writeOnnxLens(dir: []const u8, model: []const u8) !void {
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.ml-infer-onnx","version":"1.0.0","display_name":"BYO ONNX","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"score","type":"float","default":-999.0,"min":-1000000.0,"max":1000000.0}],
        \\ "nodes":[{"id":"byo","type":"ml.infer","params":{},
        \\   "ml":{"model":"model.onnx","outputs":[{"tensor":0,"index":0,"param":"score"}]}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/manifest.json", .{dir});
    defer std.heap.page_allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/assets/model.onnx", .{dir});
    defer std.heap.page_allocator.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Proves the ONNX backend of the same ml.infer node: a bundled ONNX net loads
/// on the engine's own runtime and drives a lens parameter from the frame,
/// finite, stable across runs, and responsive to the pixels. The model file
/// ends in .onnx, so the core routes it to the ONNX engine, not TFLite.
fn proveMlInferOnnx(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxProbe(arena.allocator());
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-infer-onnx/assets");
    try writeOnnxLens("zig-out/ml-infer-onnx", model);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const gray_rgba = try gpa.alloc(u8, @as(usize, corpus.frame.width) * corpus.frame.height * 4);
    defer gpa.free(gray_rgba);
    @memset(gray_rgba, 128);
    const gray = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = gray_rgba }, .width = corpus.frame.width, .height = corpus.frame.height });
    defer gray.deinit(gpa);

    const person_a = try runMlInferOnce(engine, "zig-out/ml-infer-onnx", "score", -999.0, person);
    const person_b = try runMlInferOnce(engine, "zig-out/ml-infer-onnx", "score", -999.0, person);
    const gray_score = try runMlInferOnce(engine, "zig-out/ml-infer-onnx", "score", -999.0, gray);

    if (!std.math.isFinite(person_a) or !std.math.isFinite(gray_score)) {
        std.debug.print("conformance: FAIL the onnx model published a non-finite value\n", .{});
        return false;
    }
    if (person_a != person_b) {
        std.debug.print("conformance: FAIL onnx inference is not deterministic ({d} vs {d})\n", .{ person_a, person_b });
        return false;
    }
    if (@abs(person_a - gray_score) < 1e-4) {
        std.debug.print("conformance: FAIL onnx inference did not respond to the frame ({d} vs {d})\n", .{ person_a, gray_score });
        return false;
    }
    std.debug.print("conformance: PROOF a bundled ONNX net runs through the ml.infer node and drives a lens parameter from the camera frame, deterministically\n", .{});
    return true;
}

/// Emits an ONNX segmenter: a 1x1 conv collapses the three input channels to a
/// single-channel mask the size of the input, the shape an author's own
/// segmenter would produce for the mask slot.
fn buildOnnxSegProbe(a: std.mem.Allocator) []const u8 {
    const side: i64 = 16;
    var w: OnnxPb = .{ .a = a };
    inline for (.{ 1, 3, 1, 1 }) |d| w.varintField(1, d);
    w.varintField(2, 1);
    var raw: std.ArrayList(u8) = .empty;
    for (0..3) |_| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(@as(f32, 1)), .little);
        raw.appendSlice(a, &b) catch unreachable;
    }
    w.bytesField(9, raw.items);
    w.bytesField(8, "W");
    const conv = onnxNode(a, "Conv", &.{ "x", "W" }, &.{"y"}, &.{
        .{ .name = "kernel_shape", .ints = &.{ 1, 1 } },
        .{ .name = "strides", .ints = &.{ 1, 1 } },
        .{ .name = "pads", .ints = &.{ 0, 0, 0, 0 } },
    });
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, conv);
    g.bytesField(5, w.buf.items);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, 3, side, side }));
    g.bytesField(11, onnxValueInfo(a, "W", &.{ 1, 3, 1, 1 }));
    g.bytesField(12, onnxValueInfo(a, "y", &.{ 1, 1, side, side }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

fn writeOnnxSegLens(dir: []const u8, model: []const u8) !void {
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.ml-seg","version":"1.0.0","display_name":"BYO Segmenter","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"seg","type":"ml.infer","params":{},
        \\   "ml":{"model":"model.onnx","outputs":[],"mask":{"tensor":0,"channel":"person"}}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/manifest.json", .{dir});
    defer std.heap.page_allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/assets/model.onnx", .{dir});
    defer std.heap.page_allocator.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Runs the segmenter bundle once and reports whether the author model's mask
/// reached the subject mask texture. The upload is on the render path, so this
/// feeds a frame and renders until the texture appears, the way the built-in
/// segmenter proof waits on its mask.
fn runMlSegOnce(engine: *abi.Engine, planes: Nv12Copy) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, "zig-out/ml-infer-seg", "zig-out/ml-infer-seg".len) != .ok) {
        std.debug.print("conformance: FAIL byo-ml segmenter activation\n", .{});
        return error.MlSegActivationFailed;
    }
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.MlSegTrackFailed;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.MlSegSubmitFailed;
    var polls: usize = 0;
    while (session.segmentation_texture == null) {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return false;
    }
    return true;
}

/// Proves the segmentation slot of the ml.infer node: an author's own model,
/// bound as a mask, drives the same subject mask texture the built-in segmenters
/// feed. The texture is empty until inference and then populates, on two runs.
fn proveMlInferSegMask(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxSegProbe(arena.allocator());
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-infer-seg/assets");
    try writeOnnxSegLens("zig-out/ml-infer-seg", model);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const uploaded_a = try runMlSegOnce(engine, person);
    const uploaded_b = try runMlSegOnce(engine, person);
    if (!uploaded_a or !uploaded_b) {
        std.debug.print("conformance: FAIL the author segmenter mask never reached the mask texture\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF an author model bound as a mask drives the subject mask channel through the ml.infer node\n", .{});
    return true;
}

/// Emits an ONNX classifier over three classes: channel means from a global
/// average pool, then a bias that makes the winner class the largest logit, so
/// the argmax is a known class regardless of the frame.
fn buildOnnxClsProbe(a: std.mem.Allocator, winner: usize) []const u8 {
    const side: i64 = 8;
    var b: OnnxPb = .{ .a = a };
    b.varintField(1, 3); // dims [3]
    b.varintField(2, 1); // FLOAT
    var raw: std.ArrayList(u8) = .empty;
    for (0..3) |i| {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @bitCast(@as(f32, if (i == winner) 100 else 0)), .little);
        raw.appendSlice(a, &buf) catch unreachable;
    }
    b.bytesField(9, raw.items);
    b.bytesField(8, "B");

    const pool = onnxNode(a, "GlobalAveragePool", &.{"x"}, &.{"p"}, &.{});
    const flat = onnxNode(a, "Flatten", &.{"p"}, &.{"f"}, &.{.{ .name = "axis", .i = 1 }});
    const add = onnxNode(a, "Add", &.{ "f", "B" }, &.{"y"}, &.{});

    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, pool);
    g.bytesField(1, flat);
    g.bytesField(1, add);
    g.bytesField(5, b.buf.items);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, 3, side, side }));
    g.bytesField(12, onnxValueInfo(a, "y", &.{ 1, 3 }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

fn writeOnnxClsLens(dir: []const u8, model: []const u8) !void {
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.ml-cls","version":"1.0.0","display_name":"BYO Classifier","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"label","type":"float","default":-1.0,"min":-1.0,"max":100.0}],
        \\ "nodes":[{"id":"cls","type":"ml.infer","params":{},
        \\   "ml":{"model":"model.onnx","outputs":[{"tensor":0,"reduce":"argmax","param":"label"}]}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/manifest.json", .{dir});
    defer std.heap.page_allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/assets/model.onnx", .{dir});
    defer std.heap.page_allocator.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Proves the classification slot: an argmax reduce reads a classifier's
/// predicted class into a parameter. Two models built to favour different
/// classes each drive the parameter to their own class, so the label tracks the
/// model's argmax rather than a fixed value.
fn proveMlInferCls(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    for ([_]usize{ 1, 2 }) |winner| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const model = buildOnnxClsProbe(arena.allocator(), winner);
        try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-cls/assets");
        try writeOnnxClsLens("zig-out/ml-cls", model);

        const label = try runMlInferOnce(engine, "zig-out/ml-cls", "label", -1.0, person);
        if (@as(usize, @intFromFloat(label)) != winner) {
            std.debug.print("conformance: FAIL argmax reduce read class {d}, wanted {d}\n", .{ label, winner });
            return false;
        }
    }
    std.debug.print("conformance: PROOF an argmax reduce reads a classifier's predicted class into a lens parameter\n", .{});
    return true;
}

fn writeOnnxPlaceLens(dir: []const u8, model: []const u8) !void {
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.ml-place","version":"1.0.0","display_name":"BYO Anchor","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"px","type":"float","default":-1.0,"min":-1.0,"max":3.0}],
        \\ "nodes":[{"id":"detect","type":"ml.infer","params":{},
        \\   "ml":{"model":"model.onnx","outputs":[{"tensor":0,"index":0,"param":"px"}]}},
        \\  {"id":"marker","type":"sprite.2d","inputs":{"frame":"camera"},"params":{},
        \\   "sprite":{"x":0.0,"y":0.0,"w":0.2,"h":0.2,"x_param":"px"}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/manifest.json", .{dir});
    defer std.heap.page_allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/assets/model.onnx", .{dir});
    defer std.heap.page_allocator.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

const PlaceResult = struct { px: f32, rect: [4]f32 };

/// Runs the anchor bundle once: feeds a frame, waits on the model's first
/// result, and reads back where the parameter-driven sprite lands.
fn runPlaceOnce(engine: *abi.Engine, planes: Nv12Copy) !PlaceResult {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, "zig-out/ml-place", "zig-out/ml-place".len) != .ok) {
        std.debug.print("conformance: FAIL byo-ml anchor activation\n", .{});
        return error.MlPlaceActivationFailed;
    }
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    const signals = std.mem.zeroes(abi.LensSignals);
    var px: f32 = -1.0;
    var polls: usize = 0;
    while (px == -1.0) {
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.MlPlaceTrackFailed;
        std.Thread.yield() catch {};
        _ = abi.goss_session_tick_lens(session, 16000, &signals);
        _ = abi.goss_session_parameter_value(session, "px", "px".len, &px);
        polls += 1;
        if (polls > 100_000_000) return error.MlPlaceTimedOut;
    }
    const rect = abi.firstSpriteEffectiveRect(session) orelse return error.MlPlaceNoSprite;
    return .{ .px = px, .rect = rect };
}

/// Proves the detection/pose anchor path: a model output drives a sprite's
/// placement parameter, so the sprite tracks what the model found. The sprite's
/// static x is zero; the bound parameter moves it to the model's value, and a
/// portrait and a flat frame move it to different places.
fn proveMlInferPlacement(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxProbe(arena.allocator());
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-place/assets");
    try writeOnnxPlaceLens("zig-out/ml-place", model);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);
    const gray_rgba = try gpa.alloc(u8, @as(usize, corpus.frame.width) * corpus.frame.height * 4);
    defer gpa.free(gray_rgba);
    @memset(gray_rgba, 128);
    const gray = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = gray_rgba }, .width = corpus.frame.width, .height = corpus.frame.height });
    defer gray.deinit(gpa);

    const on_person = try runPlaceOnce(engine, person);
    const on_gray = try runPlaceOnce(engine, gray);

    // The sprite's x tracks the bound parameter, which the model drove off the
    // static zero to its own output.
    if (@abs(on_person.rect[0] - on_person.px) > 1e-6) {
        std.debug.print("conformance: FAIL the sprite x {d} did not track its placement parameter {d}\n", .{ on_person.rect[0], on_person.px });
        return false;
    }
    if (!(on_person.rect[0] > 0.01)) {
        std.debug.print("conformance: FAIL the placement parameter did not move the sprite off its static x ({d})\n", .{on_person.rect[0]});
        return false;
    }
    if (@abs(on_person.rect[0] - on_gray.rect[0]) < 1e-4) {
        std.debug.print("conformance: FAIL the anchor did not track the frame ({d} vs {d})\n", .{ on_person.rect[0], on_gray.rect[0] });
        return false;
    }
    std.debug.print("conformance: PROOF a model output drives a sprite's placement parameter, the detection and pose anchor path\n", .{});
    return true;
}

/// Emits an ONNX restyle net: a 1x1 conv with identity channel weights, so its
/// output is a three-channel image the size of the input. A real style net
/// would transform the colours; the identity proves the image path.
fn buildOnnxStyleProbe(a: std.mem.Allocator) []const u8 {
    const side: i64 = 8;
    var w: OnnxPb = .{ .a = a };
    inline for (.{ 3, 3, 1, 1 }) |d| w.varintField(1, d);
    w.varintField(2, 1);
    var raw: std.ArrayList(u8) = .empty;
    for (0..3) |m| {
        for (0..3) |cc| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(@as(f32, if (m == cc) 1 else 0)), .little);
            raw.appendSlice(a, &b) catch unreachable;
        }
    }
    w.bytesField(9, raw.items);
    w.bytesField(8, "W");
    const conv = onnxNode(a, "Conv", &.{ "x", "W" }, &.{"y"}, &.{
        .{ .name = "kernel_shape", .ints = &.{ 1, 1 } },
        .{ .name = "strides", .ints = &.{ 1, 1 } },
        .{ .name = "pads", .ints = &.{ 0, 0, 0, 0 } },
    });
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, conv);
    g.bytesField(5, w.buf.items);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, 3, side, side }));
    g.bytesField(11, onnxValueInfo(a, "W", &.{ 3, 3, 1, 1 }));
    g.bytesField(12, onnxValueInfo(a, "y", &.{ 1, 3, side, side }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

fn writeOnnxStyleLens(dir: []const u8, model: []const u8) !void {
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.ml-style","version":"1.0.0","display_name":"BYO Restyle","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"restyle","type":"ml.infer","params":{},
        \\   "ml":{"model":"model.onnx","outputs":[],"style":{"tensor":0,"sprite":"canvas"}}},
        \\  {"id":"canvas","type":"sprite.2d","inputs":{"frame":"camera"},"params":{},
        \\   "sprite":{"x":0.0,"y":0.0,"w":1.0,"h":1.0}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/manifest.json", .{dir});
    defer std.heap.page_allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/assets/model.onnx", .{dir});
    defer std.heap.page_allocator.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Runs the restyle bundle once and reports whether the model's output image
/// reached the sprite that shows it. The upload is on the render path, so this
/// feeds a frame and renders until the sprite's style texture appears.
fn runStyleOnce(engine: *abi.Engine, planes: Nv12Copy) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, "zig-out/ml-style", "zig-out/ml-style".len) != .ok) {
        std.debug.print("conformance: FAIL byo-ml restyle activation\n", .{});
        return error.MlStyleActivationFailed;
    }
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.MlStyleTrackFailed;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.MlStyleSubmitFailed;
    var polls: usize = 0;
    while (abi.styleTextureCount(session) == 0) {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return false;
    }
    return true;
}

/// Proves the neural style-transfer component: a model that restyles the frame
/// draws its output image through a sprite. The sprite carries no image of its
/// own; the model's output becomes its texture, on two runs.
fn proveMlInferStyle(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxStyleProbe(arena.allocator());
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-style/assets");
    try writeOnnxStyleLens("zig-out/ml-style", model);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const drew_a = try runStyleOnce(engine, person);
    const drew_b = try runStyleOnce(engine, person);
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the restyle model's output never reached the sprite\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a model that restyles the frame draws its output through a sprite via the ml.infer style binding\n", .{});
    return true;
}

/// A super-resolution probe: an identity 1x1 conv, then a Concat along height
/// and a Concat along width, so a side-S input yields a 2S x 2S output, the
/// enlarge a real super-resolution net performs.
fn buildOnnxSuperResProbe(a: std.mem.Allocator, side: i64) []const u8 {
    var w: OnnxPb = .{ .a = a };
    inline for (.{ 3, 3, 1, 1 }) |d| w.varintField(1, d);
    w.varintField(2, 1);
    var raw: std.ArrayList(u8) = .empty;
    for (0..3) |m| for (0..3) |cc| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(@as(f32, if (m == cc) 1 else 0)), .little);
        raw.appendSlice(a, &b) catch unreachable;
    };
    w.bytesField(9, raw.items);
    w.bytesField(8, "W");
    const conv = onnxNode(a, "Conv", &.{ "x", "W" }, &.{"y"}, &.{
        .{ .name = "kernel_shape", .ints = &.{ 1, 1 } },
        .{ .name = "strides", .ints = &.{ 1, 1 } },
        .{ .name = "pads", .ints = &.{ 0, 0, 0, 0 } },
    });
    const cat_h = onnxNode(a, "Concat", &.{ "y", "y" }, &.{"y2"}, &.{.{ .name = "axis", .i = 2 }});
    const cat_w = onnxNode(a, "Concat", &.{ "y2", "y2" }, &.{"out"}, &.{.{ .name = "axis", .i = 3 }});
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, conv);
    g.bytesField(1, cat_h);
    g.bytesField(1, cat_w);
    g.bytesField(5, w.buf.items);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, 3, side, side }));
    g.bytesField(11, onnxValueInfo(a, "W", &.{ 3, 3, 1, 1 }));
    g.bytesField(12, onnxValueInfo(a, "out", &.{ 1, 3, 2 * side, 2 * side }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// Runs a style lens from `dir` until its output texture lands, then reports the
/// style texture's square side (0 if it never landed).
fn runStyleSideOnce(engine: *abi.Engine, dir: []const u8, planes: Nv12Copy) !u32 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.MlStyleActivationFailed;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
    _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
    var polls: usize = 0;
    while (abi.styleTextureCount(session) == 0) {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return 0;
    }
    return abi.styleTextureSide(session);
}

/// Proves super-resolution: a model whose output is a larger square than its
/// input draws through the style sprite at that enlarged side, so the upscaled
/// image reaches the pipeline. The synthetic net doubles an 8-side input to 16.
fn proveMlInferSuperRes(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxSuperResProbe(arena.allocator(), 8);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-superres/assets");
    try writeOnnxStyleLens("zig-out/ml-superres", model);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const side_a = try runStyleSideOnce(engine, "zig-out/ml-superres", person);
    const side_b = try runStyleSideOnce(engine, "zig-out/ml-superres", person);
    if (side_a != 16 or side_b != 16) {
        std.debug.print("conformance: FAIL super-resolution output side {d}/{d}, wanted 16 (2x the 8 input)\n", .{ side_a, side_b });
        return false;
    }
    std.debug.print("conformance: PROOF a super-resolution model whose output is a larger square than its input draws through the style sprite at the enlarged side (16 from an 8 input)\n", .{});
    return true;
}

/// A reference-conditioned probe: Add(frame, reference), two square-RGB inputs
/// to one output, so a net that consumes a second input plane is exercised. Add
/// is symmetric, so the proof holds whichever input the engine orders first.
fn buildOnnxAuxProbe(a: std.mem.Allocator, side: i64) []const u8 {
    const add = onnxNode(a, "Add", &.{ "x", "ref" }, &.{"out"}, &.{});
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, add);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, 3, side, side }));
    g.bytesField(11, onnxValueInfo(a, "ref", &.{ 1, 3, side, side }));
    g.bytesField(12, onnxValueInfo(a, "out", &.{ 1, 3, side, side }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// Writes a style lens whose ml.infer node conditions on a bundled reference
/// image (aux.reference), plus the model and the reference png.
fn writeOnnxAuxLens(dir: []const u8, model: []const u8, ref_png: []const u8) !void {
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.ml-aux","version":"1.0.0","display_name":"BYO Aux","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"restyle","type":"ml.infer","params":{},
        \\   "ml":{"model":"model.onnx","outputs":[],"aux":{"reference":"ref"},"style":{"tensor":0,"sprite":"canvas"}}},
        \\  {"id":"canvas","type":"sprite.2d","inputs":{"frame":"camera"},"params":{},
        \\   "sprite":{"x":0.0,"y":0.0,"w":1.0,"h":1.0}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/model.onnx", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
    const ref_path = try std.fmt.allocPrint(page, "{s}/assets/ref.png", .{dir});
    defer page.free(ref_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = ref_path, .data = ref_png });
}

/// Whether a style lens from `dir` produces its texture within a bounded number
/// of frames; false means its worker never loaded (the negative control).
fn styleReadyBounded(engine: *abi.Engine, dir: []const u8, planes: Nv12Copy) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return false;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    for (0..600) |_| {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (abi.styleTextureCount(session) > 0) return true;
    }
    return false;
}

/// Proves the reference-conditioned second input: a two-input net (frame plus a
/// bundled reference) feeds both inputs and draws through the style sprite; the
/// negative control proves the reference is required, the same two-input model
/// with no reference rejected at load and never drawing.
fn proveMlInferAux(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxAuxProbe(arena.allocator(), 8);

    const ref = try gpa.alloc(u8, @as(usize, 32) * 32 * 4);
    defer gpa.free(ref);
    var i: usize = 0;
    while (i < ref.len) : (i += 4) {
        ref[i + 0] = 40;
        ref[i + 1] = 80;
        ref[i + 2] = 120;
        ref[i + 3] = 255;
    }
    var ref_png: std.ArrayList(u8) = .empty;
    defer ref_png.deinit(gpa);
    try png.encodeRgba(gpa, &ref_png, ref, 32, 32);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-aux/assets");
    try writeOnnxAuxLens("zig-out/ml-aux", model, ref_png.items);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-aux-noref/assets");
    try writeOnnxStyleLens("zig-out/ml-aux-noref", model);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const with_ref = try runStyleSideOnce(engine, "zig-out/ml-aux", person);
    if (with_ref == 0) {
        std.debug.print("conformance: FAIL a two-input reference net never drew\n", .{});
        return false;
    }
    const no_ref = try styleReadyBounded(engine, "zig-out/ml-aux-noref", person);
    if (no_ref) {
        std.debug.print("conformance: FAIL a two-input model with no reference still loaded\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a two-input ml.infer net conditions on a bundled reference: with the reference it feeds both inputs and draws, and the same model with no reference is rejected at load\n", .{});
    return true;
}

/// Writes a style lens whose ml.infer node reads the previous output frame into
/// its second input (aux.temporal), plus the model. No reference png: input 1 is
/// the last frame, not a bundled image.
fn writeOnnxTemporalLens(dir: []const u8, model: []const u8) !void {
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.ml-temporal","version":"1.0.0","display_name":"BYO Temporal","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"restyle","type":"ml.infer","params":{},
        \\   "ml":{"model":"model.onnx","outputs":[],"aux":{"temporal":true},"style":{"tensor":0,"sprite":"canvas"}}},
        \\  {"id":"canvas","type":"sprite.2d","inputs":{"frame":"camera"},"params":{},
        \\   "sprite":{"x":0.0,"y":0.0,"w":1.0,"h":1.0}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/model.onnx", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Activates a style lens, feeds one constant frame until its output texture
/// lands, then holds the frame long enough for the recurrent second input to
/// settle, and captures the composited result. Caller owns the returned RGBA.
fn captureStyleSteady(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    var polls: usize = 0;
    while (abi.styleTextureCount(session) == 0) {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return error.StyleNeverLanded;
    }
    // The frame is constant, so a handful more computes settle the previous-frame
    // input onto that same frame before the capture reads the steady output.
    for (0..48) |_| {
        _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var w: u32 = 0;
    var h: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Proves the temporal second input: a recurrent Add(frame, previous) fed a
/// constant gray settles input 1 onto that gray and reads about twice the gray;
/// the control is the same graph on a black reference (a zero input 1) reading
/// the gray once, so the brighter temporal output proves the previous frame.
fn proveMlInferTemporal(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxAuxProbe(arena.allocator(), 8);

    // A uniform mid-gray frame, dim enough that twice its value stays unclamped.
    const gray = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(gray);
    var p: usize = 0;
    while (p + 4 <= gray.len) : (p += 4) {
        gray[p + 0] = 90;
        gray[p + 1] = 90;
        gray[p + 2] = 90;
        gray[p + 3] = 255;
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = gray }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    // The control: the same two-input graph conditioned on a black reference, so
    // its second input is a zero plane rather than the previous frame.
    const black = try gpa.alloc(u8, @as(usize, 32) * 32 * 4);
    defer gpa.free(black);
    @memset(black, 0);
    var i: usize = 3;
    while (i < black.len) : (i += 4) black[i] = 255;
    var black_png: std.ArrayList(u8) = .empty;
    defer black_png.deinit(gpa);
    try png.encodeRgba(gpa, &black_png, black, 32, 32);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-temporal/assets");
    try writeOnnxTemporalLens("zig-out/ml-temporal", model);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-temporal-ref/assets");
    try writeOnnxAuxLens("zig-out/ml-temporal-ref", model, black_png.items);

    const temporal_shot = try captureStyleSteady(gpa, engine, "zig-out/ml-temporal", planes);
    defer gpa.free(temporal_shot);
    const ref_shot = try captureStyleSteady(gpa, engine, "zig-out/ml-temporal-ref", planes);
    defer gpa.free(ref_shot);

    const temporal_sum = sumRgb(temporal_shot);
    const ref_sum = sumRgb(ref_shot);
    // The recurrent output carries the gray twice; the zero-reference control
    // carries it once. Require a clear margin above the once-gray control.
    if (temporal_sum <= ref_sum + ref_sum / 2) {
        std.debug.print("conformance: FAIL temporal sum {d} not clearly above the zero-reference {d}\n", .{ temporal_sum, ref_sum });
        return false;
    }
    std.debug.print("conformance: PROOF a temporal ml.infer net feeds the previous output frame into its second input: a recurrent sum of the frame and its previous reads about twice a constant gray, measurably brighter than the same graph on a zero reference\n", .{});
    return true;
}

/// Writes a dehaze.pass lens at a static strength (no asset).
fn writeDehazeLens(dir: []const u8, strength: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.dehaze","version":"1.0.0","display_name":"Dehaze","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"d","type":"dehaze.pass","inputs":{{"frame":"camera"}},"params":{{}},"dehaze":{{"strength":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{strength});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Activates a full-frame post lens from `dir`, submits the frame, and captures
/// the composited result; caller owns the returned RGBA.
fn captureDehazeShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    for (0..8) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var w: u32 = 0;
    var h: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Sums the rgb bytes of a capture, a stand-in for its overall brightness.
fn sumRgb(shot: []const u8) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i + 4 <= shot.len) : (i += 4) {
        total += @as(u64, shot[i]) + shot[i + 1] + shot[i + 2];
    }
    return total;
}

/// Proves the deterministic dehaze pass: a dehaze.pass lifts the atmospheric
/// veil off a hazy frame. At strength 0 the frame is untouched; at strength 1
/// the dark-channel transmission recovery pulls the bright veil down, so the
/// output differs from the identity and is measurably darker.
fn proveDehaze(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // A bright, low-contrast hazy frame: a veil the dehaze pass lifts.
    const hazy = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(hazy);
    var p: usize = 0;
    while (p + 4 <= hazy.len) : (p += 4) {
        hazy[p + 0] = 190;
        hazy[p + 1] = 200;
        hazy[p + 2] = 210;
        hazy[p + 3] = 255;
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = hazy }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/dehaze-0");
    try writeDehazeLens("zig-out/dehaze-0", 0.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/dehaze-1");
    try writeDehazeLens("zig-out/dehaze-1", 1.0);

    const shot0 = try captureDehazeShot(gpa, engine, "zig-out/dehaze-0", planes);
    defer gpa.free(shot0);
    const shot1 = try captureDehazeShot(gpa, engine, "zig-out/dehaze-1", planes);
    defer gpa.free(shot1);

    const changed = countDiff(shot0, shot1);
    const bright0 = sumRgb(shot0);
    const bright1 = sumRgb(shot1);
    if (changed == 0) {
        std.debug.print("conformance: FAIL dehaze at strength 1 left the frame identical to strength 0\n", .{});
        return false;
    }
    if (!(bright1 < bright0)) {
        std.debug.print("conformance: FAIL dehaze did not darken the veiled frame ({d} vs {d})\n", .{ bright1, bright0 });
        return false;
    }
    std.debug.print("conformance: PROOF a dehaze.pass lifts the atmospheric veil: strength 1 pulls the dark-channel transmission down, darkening a hazy frame where strength 0 leaves it untouched ({d} pixels changed)\n", .{changed});
    return true;
}

/// Writes a relight.pass lens at a static strength and light angle (no asset).
fn writeRelightLens(dir: []const u8, strength: f32, angle: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.relight","version":"1.0.0","display_name":"Relight","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"r","type":"relight.pass","inputs":{{"frame":"camera"}},"params":{{}},"relight":{{"strength":{d:.3},"angle":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{ strength, angle });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Sums the rgb bytes over the left third (side 0) or right third (side 1) of
/// the 400-wide capture, so a directional effect's two sides can be compared.
fn sumThird(shot: []const u8, side: usize) u64 {
    var total: u64 = 0;
    const w: usize = 400;
    const h: usize = 300;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const x0: usize = if (side == 0) 0 else (w * 2) / 3;
        const x1: usize = if (side == 0) w / 3 else w;
        var x: usize = x0;
        while (x < x1) : (x += 1) {
            const idx = (y * w + x) * 4;
            total += @as(u64, shot[idx]) + shot[idx + 1] + shot[idx + 2];
        }
    }
    return total;
}

/// Proves the parametric directional relight: a relight.pass at angle 0 lights
/// the frame from the right, so the right side brightens and the left shades,
/// where a uniform frame under strength 0 stays even side to side.
fn proveRelight(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const grayf = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(grayf);
    var q: usize = 0;
    while (q + 4 <= grayf.len) : (q += 4) {
        grayf[q + 0] = 128;
        grayf[q + 1] = 128;
        grayf[q + 2] = 128;
        grayf[q + 3] = 255;
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = grayf }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/relight-0");
    try writeRelightLens("zig-out/relight-0", 0.0, 0.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/relight-1");
    try writeRelightLens("zig-out/relight-1", 1.0, 0.0);

    const shot0 = try captureDehazeShot(gpa, engine, "zig-out/relight-0", planes);
    defer gpa.free(shot0);
    const shot1 = try captureDehazeShot(gpa, engine, "zig-out/relight-1", planes);
    defer gpa.free(shot1);

    const changed = countDiff(shot0, shot1);
    const left1 = sumThird(shot1, 0);
    const right1 = sumThird(shot1, 1);
    const left0 = sumThird(shot0, 0);
    const right0 = sumThird(shot0, 1);
    const id_gap = if (right0 > left0) right0 - left0 else left0 - right0;
    if (changed == 0) {
        std.debug.print("conformance: FAIL relight at strength 1 left the frame identical to strength 0\n", .{});
        return false;
    }
    if (!(right1 > left1) or (right1 - left1) <= id_gap) {
        std.debug.print("conformance: FAIL relight did not light from the right (left {d}, right {d}, identity gap {d})\n", .{ left1, right1, id_gap });
        return false;
    }
    std.debug.print("conformance: PROOF a relight.pass lights the frame directionally: at angle 0 the right side brightens over the left where the uniform strength-0 frame stays even ({d} pixels changed)\n", .{changed});
    return true;
}

/// Writes a glare.pass lens at a static strength and threshold (no asset).
fn writeGlareLens(dir: []const u8, strength: f32, threshold: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.glare","version":"1.0.0","display_name":"Glare","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"g","type":"glare.pass","inputs":{{"frame":"camera"}},"params":{{}},"glare":{{"strength":{d:.3},"threshold":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{ strength, threshold });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Proves the specular glare rolloff: a glare.pass pulls a bright highlight down
/// while a normal-luma region holds. The frame is blown out on the left and
/// mid-toned on the right; strength 1 recovers the left where the right barely
/// moves, and strength 0 is untouched.
fn proveGlare(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const v: u8 = if (col < width / 2) 240 else 100;
        f[idx + 0] = v;
        f[idx + 1] = v;
        f[idx + 2] = v;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/glare-0");
    try writeGlareLens("zig-out/glare-0", 0.0, 0.8);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/glare-1");
    try writeGlareLens("zig-out/glare-1", 1.0, 0.8);

    const shot0 = try captureDehazeShot(gpa, engine, "zig-out/glare-0", planes);
    defer gpa.free(shot0);
    const shot1 = try captureDehazeShot(gpa, engine, "zig-out/glare-1", planes);
    defer gpa.free(shot1);

    const changed = countDiff(shot0, shot1);
    const bright0 = sumThird(shot0, 0);
    const bright1 = sumThird(shot1, 0);
    const normal0 = sumThird(shot0, 1);
    const normal1 = sumThird(shot1, 1);
    const normal_gap = if (normal1 > normal0) normal1 - normal0 else normal0 - normal1;
    const bright_drop = if (bright0 > bright1) bright0 - bright1 else 0;
    if (changed == 0) {
        std.debug.print("conformance: FAIL glare at strength 1 left the frame identical to strength 0\n", .{});
        return false;
    }
    if (!(bright1 < bright0) or normal_gap > bright_drop / 4) {
        std.debug.print("conformance: FAIL glare did not recover the highlight while holding the normal region (bright drop {d}, normal gap {d})\n", .{ bright_drop, normal_gap });
        return false;
    }
    std.debug.print("conformance: PROOF a glare.pass recovers a blown highlight: strength 1 pulls the bright region down toward the threshold where the normal region barely moves and strength 0 is untouched ({d} pixels changed)\n", .{changed});
    return true;
}

/// Sums the rgb bytes of a rectangular block of the 400x300 capture.
fn sumBlock(shot: []const u8, x0: usize, y0: usize, x1: usize, y1: usize) u64 {
    var total: u64 = 0;
    const w: usize = 400;
    var y: usize = y0;
    while (y < y1) : (y += 1) {
        var x: usize = x0;
        while (x < x1) : (x += 1) {
            const idx = (y * w + x) * 4;
            total += @as(u64, shot[idx]) + shot[idx + 1] + shot[idx + 2];
        }
    }
    return total;
}

/// Writes a vignette.pass lens at a static strength and radius (no asset).
fn writeVignetteLens(dir: []const u8, strength: f32, radius: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.vignette","version":"1.0.0","display_name":"Vignette","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"v","type":"vignette.pass","inputs":{{"frame":"camera"}},"params":{{}},"vignette":{{"strength":{d:.3},"radius":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{ strength, radius });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Proves the radial vignette gain: a uniform gray frame stays uniform at
/// strength 0. A positive strength lifts the corners (correcting a lens
/// vignette) while the centre inside the radius holds; a negative strength sinks
/// them. The corner block moves the expected way and the centre barely does.
fn proveVignette(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    var p: usize = 0;
    while (p + 4 <= f.len) : (p += 4) {
        f[p + 0] = 128;
        f[p + 1] = 128;
        f[p + 2] = 128;
        f[p + 3] = 255;
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/vignette-0");
    try writeVignetteLens("zig-out/vignette-0", 0.0, 0.3);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/vignette-pos");
    try writeVignetteLens("zig-out/vignette-pos", 0.8, 0.3);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/vignette-neg");
    try writeVignetteLens("zig-out/vignette-neg", -0.8, 0.3);

    const shot0 = try captureDehazeShot(gpa, engine, "zig-out/vignette-0", planes);
    defer gpa.free(shot0);
    const shot_pos = try captureDehazeShot(gpa, engine, "zig-out/vignette-pos", planes);
    defer gpa.free(shot_pos);
    const shot_neg = try captureDehazeShot(gpa, engine, "zig-out/vignette-neg", planes);
    defer gpa.free(shot_neg);

    // Top-left corner (radially far, past the radius) versus a centre block.
    const corner0 = sumBlock(shot0, 0, 0, 80, 60);
    const corner_pos = sumBlock(shot_pos, 0, 0, 80, 60);
    const corner_neg = sumBlock(shot_neg, 0, 0, 80, 60);
    const center0 = sumBlock(shot0, 160, 120, 240, 180);
    const center_pos = sumBlock(shot_pos, 160, 120, 240, 180);

    const changed = countDiff(shot0, shot_pos);
    const corner_lift = if (corner_pos > corner0) corner_pos - corner0 else 0;
    const center_move = if (center_pos > center0) center_pos - center0 else center0 - center_pos;
    if (changed == 0) {
        std.debug.print("conformance: FAIL vignette at strength 0.8 left the frame identical to strength 0\n", .{});
        return false;
    }
    if (!(corner_pos > corner0) or !(corner_neg < corner0)) {
        std.debug.print("conformance: FAIL vignette corner did not lift on positive and sink on negative (0 {d}, pos {d}, neg {d})\n", .{ corner0, corner_pos, corner_neg });
        return false;
    }
    if (center_move * 4 > corner_lift) {
        std.debug.print("conformance: FAIL vignette moved the centre inside the radius (centre move {d}, corner lift {d})\n", .{ center_move, corner_lift });
        return false;
    }
    std.debug.print("conformance: PROOF a vignette.pass applies a radial luma-gain: a positive strength lifts the corners and a negative sinks them while the centre inside the radius holds ({d} pixels changed)\n", .{changed});
    return true;
}

/// Sums the absolute rgb step between horizontally adjacent pixels over a
/// vertical third of the 400x300 capture, a stand-in for its high-frequency
/// noise. side 0 is the left third, 2 the right.
fn roughnessThird(shot: []const u8, side: usize) u64 {
    var total: u64 = 0;
    const w: usize = 400;
    const h: usize = 300;
    const x0: usize = if (side == 0) 0 else (w * 2) / 3;
    const x1: usize = if (side == 0) w / 3 else w;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = x0;
        while (x + 1 < x1) : (x += 1) {
            const a = (y * w + x) * 4;
            const b = (y * w + x + 1) * 4;
            inline for (0..3) |ch| {
                const da: i32 = @as(i32, shot[a + ch]) - @as(i32, shot[b + ch]);
                total += @abs(da);
            }
        }
    }
    return total;
}

/// Writes a lowlight.pass lens at a static lift strength and denoise (no asset).
fn writeLowLightLens(dir: []const u8, strength: f32, denoise: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.lowlight","version":"1.0.0","display_name":"Low Light","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"l","type":"lowlight.pass","inputs":{{"frame":"camera"}},"params":{{}},"lowlight":{{"strength":{d:.3},"denoise":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{ strength, denoise });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Proves the low-light night lift: a dark noisy region and a bright region. At
/// strength 1 with denoise the shadows lift far more than the highlights hold,
/// and the shadow noise (adjacent-pixel step) drops; the 0/0 control is
/// untouched.
fn proveLowLight(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        // Left half: a dark 1px checkerboard (noisy shadow). Right half: a bright
        // near-flat region (the highlight to hold).
        const v: u8 = if (col < width / 2) (if ((row + col) % 2 == 0) @as(u8, 20) else 60) else 235;
        f[idx + 0] = v;
        f[idx + 1] = v;
        f[idx + 2] = v;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/lowlight-0");
    try writeLowLightLens("zig-out/lowlight-0", 0.0, 0.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/lowlight-1");
    try writeLowLightLens("zig-out/lowlight-1", 1.0, 0.8);

    const shot0 = try captureDehazeShot(gpa, engine, "zig-out/lowlight-0", planes);
    defer gpa.free(shot0);
    const shot1 = try captureDehazeShot(gpa, engine, "zig-out/lowlight-1", planes);
    defer gpa.free(shot1);

    const shadow0 = sumThird(shot0, 0);
    const shadow1 = sumThird(shot1, 0);
    const high0 = sumThird(shot0, 2);
    const high1 = sumThird(shot1, 2);
    const rough0 = roughnessThird(shot0, 0);
    const rough1 = roughnessThird(shot1, 0);

    const changed = countDiff(shot0, shot1);
    const shadow_lift = if (shadow1 > shadow0) shadow1 - shadow0 else 0;
    const high_move = if (high1 > high0) high1 - high0 else high0 - high1;
    if (changed == 0) {
        std.debug.print("conformance: FAIL lowlight at strength 1 left the frame identical to the 0/0 control\n", .{});
        return false;
    }
    if (!(shadow1 > shadow0) or shadow_lift < high_move * 3) {
        std.debug.print("conformance: FAIL lowlight did not lift the shadows far more than the highlights held (shadow lift {d}, highlight move {d})\n", .{ shadow_lift, high_move });
        return false;
    }
    // A substantial cut proves the denoise; the exact fraction tracks the
    // shadow-weight curve, and the lift re-expands what noise remains.
    if (!(rough1 * 3 < rough0 * 2)) {
        std.debug.print("conformance: FAIL lowlight denoise did not cut the shadow noise (rough {d} -> {d})\n", .{ rough0, rough1 });
        return false;
    }
    std.debug.print("conformance: PROOF a lowlight.pass lifts the shadows far more than it moves the highlights and cuts the shadow noise substantially ({d} pixels changed, roughness {d} -> {d})\n", .{ changed, rough0, rough1 });
    return true;
}

/// Writes an undistort.pass lens at a static correction strength (no asset).
fn writeUndistortLens(dir: []const u8, strength: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.undistort","version":"1.0.0","display_name":"Undistort","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"u","type":"undistort.pass","inputs":{{"frame":"camera"}},"params":{{}},"undistort":{{"strength":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{strength});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Activates an undistort lens, submits the given intrinsics (an empty
/// distortion clears them), holds the frame, and captures the composited result.
fn captureUndistortShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, fx: f32, cx: f32, cy: f32, distortion: []const f32) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    _ = abi.goss_session_submit_camera_intrinsics(session, fx, fx, cx, cy, if (distortion.len == 0) null else distortion.ptr, @intCast(distortion.len));
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    for (0..8) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var w: u32 = 0;
    var h: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Counts the bright (near-white) pixels of a capture, a stand-in for a white
/// region's area.
fn brightArea(shot: []const u8) u64 {
    var count: u64 = 0;
    var i: usize = 0;
    while (i + 4 <= shot.len) : (i += 4) {
        if (@as(u32, shot[i]) + shot[i + 1] + shot[i + 2] > 600) count += 1;
    }
    return count;
}

/// Proves the intrinsics-driven undistort: a centred white disk on black. A
/// positive k1 samples the input further out for a given output radius, so the
/// disk shrinks; a negative k1 magnifies it. The submitted coefficient drives
/// the effect, and with no intrinsics the node is inert.
fn proveUndistort(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const u = @as(f32, @floatFromInt(col)) / @as(f32, width) - 0.5;
        const v = @as(f32, @floatFromInt(row)) / @as(f32, height) - 0.5;
        const white = (u * u + v * v) < 0.3 * 0.3;
        const val: u8 = if (white) 255 else 0;
        f[idx + 0] = val;
        f[idx + 1] = val;
        f[idx + 2] = val;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/undistort");
    try writeUndistortLens("zig-out/undistort", 1.0);

    // The principal point at the frame centre, a square pixel aspect, and the
    // radial coefficient submitted three ways.
    const shrink = [_]f32{ 0.6, 0.0 };
    const grow = [_]f32{ -0.6, 0.0 };
    const none = [_]f32{};
    const shot_shrink = try captureUndistortShot(gpa, engine, "zig-out/undistort", planes, 400, 200, 150, &shrink);
    defer gpa.free(shot_shrink);
    const shot_grow = try captureUndistortShot(gpa, engine, "zig-out/undistort", planes, 400, 200, 150, &grow);
    defer gpa.free(shot_grow);
    const shot_none = try captureUndistortShot(gpa, engine, "zig-out/undistort", planes, 0, 0, 0, &none);
    defer gpa.free(shot_none);

    const area_shrink = brightArea(shot_shrink);
    const area_grow = brightArea(shot_grow);
    const area_none = brightArea(shot_none);
    if (!(area_shrink < area_none)) {
        std.debug.print("conformance: FAIL undistort with a positive k1 did not shrink the disk (shrink {d}, none {d})\n", .{ area_shrink, area_none });
        return false;
    }
    if (!(area_grow > area_none)) {
        std.debug.print("conformance: FAIL undistort with a negative k1 did not grow the disk (grow {d}, none {d})\n", .{ area_grow, area_none });
        return false;
    }
    std.debug.print("conformance: PROOF an undistort.pass applies the submitted radial map: a positive k1 shrinks a centred disk and a negative grows it, where no intrinsics leaves it inert (areas {d} < {d} < {d})\n", .{ area_shrink, area_none, area_grow });
    return true;
}

/// The spread between the brightest and dimmest channel mean of a capture, a
/// stand-in for a color cast: a neutral frame's channels sit close together, a
/// cast pushes one apart.
fn channelSpread(shot: []const u8) u64 {
    var sum = [3]u64{ 0, 0, 0 };
    var i: usize = 0;
    while (i + 4 <= shot.len) : (i += 4) {
        sum[0] += shot[i];
        sum[1] += shot[i + 1];
        sum[2] += shot[i + 2];
    }
    const hi = @max(sum[0], @max(sum[1], sum[2]));
    const lo = @min(sum[0], @min(sum[1], sum[2]));
    return hi - lo;
}

/// Writes an awb.pass lens at a static blend strength (no asset).
fn writeAwbLens(dir: []const u8, strength: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.awb","version":"1.0.0","display_name":"Auto Enhance","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"a","type":"awb.pass","inputs":{{"frame":"camera"}},"params":{{}},"awb":{{"strength":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{strength});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Proves the one-tap auto-enhance: a blue-cast frame estimated from the frame
/// thumb has its gray-world gains pull the channels back together. At strength 1
/// the channel spread collapses toward neutral; strength 0 is untouched.
fn proveAwb(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // A vertical luma ramp with a blue cast: a spread the gray-world balance
    // removes, and a luma range the auto-levels leaves near intact.
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const base: u8 = @intCast((row * 200) / height);
        f[idx + 0] = base;
        f[idx + 1] = base;
        f[idx + 2] = @intCast(@min(@as(usize, base) + 55, 255));
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/awb-0");
    try writeAwbLens("zig-out/awb-0", 0.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/awb-1");
    try writeAwbLens("zig-out/awb-1", 1.0);

    const shot0 = try captureDehazeShot(gpa, engine, "zig-out/awb-0", planes);
    defer gpa.free(shot0);
    const shot1 = try captureDehazeShot(gpa, engine, "zig-out/awb-1", planes);
    defer gpa.free(shot1);

    const spread0 = channelSpread(shot0);
    const spread1 = channelSpread(shot1);
    const changed = countDiff(shot0, shot1);
    if (changed == 0) {
        std.debug.print("conformance: FAIL awb at strength 1 left the frame identical to strength 0\n", .{});
        return false;
    }
    if (spread0 == 0 or spread1 * 2 >= spread0) {
        std.debug.print("conformance: FAIL awb did not pull the cast channels together (spread {d} -> {d})\n", .{ spread0, spread1 });
        return false;
    }
    std.debug.print("conformance: PROOF an awb.pass estimates a gray-world balance from the frame thumb and neutralizes a color cast: strength 1 pulls the channel spread to under half where strength 0 is untouched ({d} -> {d})\n", .{ spread0, spread1 });
    return true;
}

/// Writes a lens with `count` bare ml.infer nodes, all sharing one bundled model,
/// to exercise the per-session heavy-worker budget.
fn writeMlBudgetLens(dir: []const u8, model: []const u8, count: usize) !void {
    const page = std.heap.page_allocator;
    var nodes: std.ArrayList(u8) = .empty;
    defer nodes.deinit(page);
    for (0..count) |i| {
        if (i > 0) try nodes.append(page, ',');
        const one = try std.fmt.allocPrint(page, "{{\"id\":\"m{d}\",\"type\":\"ml.infer\",\"params\":{{}},\"ml\":{{\"model\":\"model.tflite\",\"outputs\":[]}}}}", .{i});
        defer page.free(one);
        try nodes.appendSlice(page, one);
    }
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.ml-budget","version":"1.0.0","display_name":"Budget","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{s}],
        \\ "triggers":[]}}
    , .{nodes.items});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/model.tflite", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Activates the budget lens on a fresh session under the given worker budget and
/// reports how many heavy workers it loaded.
fn workersUnderBudget(engine: *abi.Engine, dir: []const u8, budget: u32) !u32 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    abi.setMlWorkerBudget(session, budget);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    return abi.mlWorkerCount(session);
}

/// Proves the per-session inference budget: a lens with more heavy nets than the
/// budget loads only up to it, leaving the rest inert so a stacked enhance chain
/// cannot oversubscribe the device. A generous budget loads them all.
fn proveInferenceBudget(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const model = try std.Io.Dir.cwd().readFileAlloc(harness_io, single_class_model_path, gpa, .limited(32 << 20));
    defer gpa.free(model);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-budget/assets");
    try writeMlBudgetLens("zig-out/ml-budget", model, 4);

    const all = try workersUnderBudget(engine, "zig-out/ml-budget", 8);
    const capped = try workersUnderBudget(engine, "zig-out/ml-budget", 2);
    if (all != 4) {
        std.debug.print("conformance: FAIL a generous budget did not load all four nets (loaded {d})\n", .{all});
        return false;
    }
    if (capped != 2) {
        std.debug.print("conformance: FAIL the budget did not cap the workers at 2 (loaded {d})\n", .{capped});
        return false;
    }
    std.debug.print("conformance: PROOF a per-session inference budget caps the heavy workers: four ml.infer nets all load under a budget of eight but only two load under a budget of two, the rest left inert\n", .{});
    return true;
}

/// The total absolute byte difference between two captures, a magnitude-sensitive
/// stand-in for how much the frame moved (unlike a pixel count, which saturates
/// on a smooth gradient at any shift).
fn sumAbsDiff(a: []const u8, b: []const u8) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i + 4 <= a.len) : (i += 4) {
        inline for (0..3) |ch| {
            const d: i32 = @as(i32, a[i + ch]) - @as(i32, b[i + ch]);
            total += @abs(d);
        }
    }
    return total;
}

/// Writes a stabilize.pass lens (no asset).
fn writeStabilizeLens(dir: []const u8) !void {
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.stabilize","version":"1.0.0","display_name":"Stabilize","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"s","type":"stabilize.pass","inputs":{"frame":"camera"},"params":{},"stabilize":{"strength":1.0}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// A low-frequency textured pattern shifted horizontally by `shift` pixels: coarse
/// enough to survive the thumb downsample so the global-motion solve recovers the
/// shift, and the stabilizer can counter it.
fn buildJitteredFrame(gpa: std.mem.Allocator, shift: f32) ![]u8 {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const xf = @as(f32, @floatFromInt(col)) - shift;
        const yf: f32 = @floatFromInt(row);
        const val = std.math.clamp(128.0 + 85.0 * @sin(xf * 0.03) + 55.0 * @sin(yf * 0.035), 0.0, 255.0);
        const v: u8 = @intFromFloat(val);
        f[idx + 0] = v;
        f[idx + 1] = v;
        f[idx + 2] = v;
        f[idx + 3] = 255;
    };
    return f;
}

/// Runs a jittering sequence through the stabilize lens under a recording-policy
/// stabilization level and reports the total inter-frame motion of the composited
/// output over the settled tail. A lower sum means a steadier result.
fn captureStabilizeSequence(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, level: u32) !u64 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    var policy: abi.RecordingPolicy = .{};
    policy.stabilization = level;
    _ = abi.goss_session_set_recording_policy(session, &policy);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;

    const count = 16;
    var prev_shot: ?[]u8 = null;
    defer if (prev_shot) |p| gpa.free(p);
    var total: u64 = 0;
    for (0..count) |k| {
        // A horizontal jitter around a still camera: large enough to register on
        // the downsampled thumb, slow enough that the per-frame motion stays
        // inside the single-level solve's small-motion range.
        const shift = 22.0 * @sin(@as(f32, @floatFromInt(k)) * 0.6);
        const frame = try buildJitteredFrame(gpa, shift);
        defer gpa.free(frame);
        const src: sampler.Frame = .{ .pixels = .{ .rgba8 = frame }, .width = width, .height = height };
        const planes = try rgbaToNv12(gpa, src);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast(1000 + k * 33000) };
        _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        var w: u32 = 0;
        var h: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) {
            gpa.free(shot);
            return error.CaptureFailed;
        }
        // Sum inter-frame motion only over the settled tail, past the warm-up.
        if (k >= 6) {
            if (prev_shot) |p| total += sumAbsDiff(p, shot);
        }
        if (prev_shot) |p| gpa.free(p);
        prev_shot = shot;
    }
    return total;
}

/// Proves the electronic stabilizer wired to the recording policy: a jittering
/// camera run through a stabilize.pass holds far steadier than the same lens with
/// stabilization off. The engine estimates the global motion per frame, smooths
/// the camera path, and shifts each frame onto it.
fn proveStabilize(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/stabilize");
    try writeStabilizeLens("zig-out/stabilize");

    const raw = try captureStabilizeSequence(gpa, engine, "zig-out/stabilize", 0);
    const stabilized = try captureStabilizeSequence(gpa, engine, "zig-out/stabilize", 1);
    if (raw == 0) {
        std.debug.print("conformance: FAIL the jittering sequence produced no motion to stabilize\n", .{});
        return false;
    }
    if (stabilized * 2 >= raw) {
        std.debug.print("conformance: FAIL stabilization did not steady the jitter (raw {d}, stabilized {d})\n", .{ raw, stabilized });
        return false;
    }
    std.debug.print("conformance: PROOF a stabilize.pass steadies a jittering camera: with the recording policy's stabilization on the settled inter-frame motion falls to under half of the same lens with it off ({d} -> {d})\n", .{ raw, stabilized });
    return true;
}

/// Writes a zoom.pass lens at a static factor, centred (no asset).
fn writeZoomLens(dir: []const u8, factor: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.zoom","version":"1.0.0","display_name":"Zoom","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"z","type":"zoom.pass","inputs":{{"frame":"camera"}},"params":{{}},"zoom":{{"factor":{d:.3},"cx":0.5,"cy":0.5}}}}],
        \\ "triggers":[]}}
    , .{factor});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Proves the digital region zoom: a centred white disk magnified by the factor
/// fills more of the frame. At factor 1 the disk keeps its area; at factor 2 it
/// grows toward four times it (the area of a doubled radius).
fn proveZoom(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const u = @as(f32, @floatFromInt(col)) / @as(f32, width) - 0.5;
        const v = @as(f32, @floatFromInt(row)) / @as(f32, height) - 0.5;
        const white = (u * u + v * v) < 0.15 * 0.15;
        const val: u8 = if (white) 255 else 0;
        f[idx + 0] = val;
        f[idx + 1] = val;
        f[idx + 2] = val;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/zoom-1");
    try writeZoomLens("zig-out/zoom-1", 1.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/zoom-2");
    try writeZoomLens("zig-out/zoom-2", 2.0);

    const shot1 = try captureDehazeShot(gpa, engine, "zig-out/zoom-1", planes);
    defer gpa.free(shot1);
    const shot2 = try captureDehazeShot(gpa, engine, "zig-out/zoom-2", planes);
    defer gpa.free(shot2);

    const area1 = brightArea(shot1);
    const area2 = brightArea(shot2);
    if (area1 == 0) {
        std.debug.print("conformance: FAIL the zoom test frame had no disk to magnify\n", .{});
        return false;
    }
    if (area2 <= area1 * 2) {
        std.debug.print("conformance: FAIL zoom factor 2 did not magnify the disk (area {d} -> {d})\n", .{ area1, area2 });
        return false;
    }
    std.debug.print("conformance: PROOF a zoom.pass magnifies a centred region: a factor of 2 grows a centred disk toward four times its area ({d} -> {d})\n", .{ area1, area2 });
    return true;
}

/// Writes a dereflect.pass lens at a static strength (no asset).
fn writeDereflectLens(dir: []const u8, strength: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.dereflect","version":"1.0.0","display_name":"Dereflect","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"d","type":"dereflect.pass","inputs":{{"frame":"camera"}},"params":{{}},"dereflect":{{"strength":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{strength});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Proves the localized specular attenuation: a dark textured half and a bright
/// textured half. At strength 1 the high-frequency detail (the checkerboard) in
/// the bright half is pulled toward the local mean far more than in the dark
/// half, so a reflection over the bright regions softens while the dark holds.
fn proveDereflect(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const checker = (row + col) % 2 == 0;
        const v: u8 = if (col < width / 2)
            (if (checker) @as(u8, 20) else 60) // dark textured half
        else
            (if (checker) @as(u8, 200) else 240); // bright textured half
        f[idx + 0] = v;
        f[idx + 1] = v;
        f[idx + 2] = v;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/dereflect-0");
    try writeDereflectLens("zig-out/dereflect-0", 0.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/dereflect-1");
    try writeDereflectLens("zig-out/dereflect-1", 1.0);

    const shot0 = try captureDehazeShot(gpa, engine, "zig-out/dereflect-0", planes);
    defer gpa.free(shot0);
    const shot1 = try captureDehazeShot(gpa, engine, "zig-out/dereflect-1", planes);
    defer gpa.free(shot1);

    const dark0 = roughnessThird(shot0, 0);
    const dark1 = roughnessThird(shot1, 0);
    const bright0 = roughnessThird(shot0, 2);
    const bright1 = roughnessThird(shot1, 2);
    if (bright0 == 0) {
        std.debug.print("conformance: FAIL the dereflect test frame had no bright texture to attenuate\n", .{});
        return false;
    }
    // The bright half's high-frequency detail is cut substantially.
    if (!(bright1 * 2 < bright0)) {
        std.debug.print("conformance: FAIL dereflect did not soften the bright reflection texture ({d} -> {d})\n", .{ bright0, bright1 });
        return false;
    }
    // The dark half is largely held (a much smaller relative drop than the bright).
    const bright_drop = bright0 - bright1;
    const dark_drop = if (dark0 > dark1) dark0 - dark1 else 0;
    if (!(bright_drop > dark_drop * 3)) {
        std.debug.print("conformance: FAIL dereflect attenuated the dark half as much as the bright (dark drop {d}, bright drop {d})\n", .{ dark_drop, bright_drop });
        return false;
    }
    std.debug.print("conformance: PROOF a dereflect.pass attenuates high-frequency detail in the bright regions far more than the dark: the bright texture softens to under half while the dark holds (bright {d} -> {d}, dark {d} -> {d})\n", .{ bright0, bright1, dark0, dark1 });
    return true;
}

fn writeHarmonizeLens(dir: []const u8, strength: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.harmonize","version":"1.0.0","display_name":"Harmonize","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"h","type":"harmonize.pass","inputs":{{"frame":"camera"}},"params":{{}},"harmonize":{{"strength":{d:.3},"direction":0}}}}],
        \\ "triggers":[]}}
    , .{strength});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Captures a harmonize.pass shot with the person region on the left. The CPU
/// person mask feeds the region statistics and the same mask on channel 0 keys
/// the shader, both injected once the first frame has filled the thumb.
fn captureHarmonizeShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, mask: []const f32) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    abi.injectPersonMaskCpu(session, @ptrCast(mask.ptr));
    abi.injectMaskChannel(session, 0, @ptrCast(mask.ptr));
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    for (0..8) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        abi.injectPersonMaskCpu(session, @ptrCast(mask.ptr));
        abi.injectMaskChannel(session, 0, @ptrCast(mask.ptr));
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var w: u32 = 0;
    var h: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Mean rgb of the capture columns in [col_lo, col_hi), each channel 0..255.
fn regionMean(shot: []const u8, col_lo: usize, col_hi: usize) [3]f64 {
    var sum = [3]f64{ 0, 0, 0 };
    var n: f64 = 0;
    for (0..300) |row| {
        for (col_lo..col_hi) |col| {
            const idx = (row * 400 + col) * 4;
            inline for (0..3) |ch| sum[ch] += @floatFromInt(shot[idx + ch]);
            n += 1;
        }
    }
    return .{ sum[0] / n, sum[1] / n, sum[2] / n };
}

/// Proves the statistical color transfer: a warm subject on the left, a cool
/// background on the right, split by the person mask. At strength 1 the person
/// region takes on the background's color distribution, so its red falls and blue
/// rises toward the background while the background itself holds.
fn proveHarmonize(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const person = col < width / 2;
        f[idx + 0] = if (person) 210 else 60; // warm subject vs cool background
        f[idx + 1] = 70;
        f[idx + 2] = if (person) 60 else 210;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    const mask = try gpa.alloc(f32, abi.segmentation_mask_len);
    defer gpa.free(mask);
    const mask_side = std.math.sqrt(abi.segmentation_mask_len);
    for (0..mask_side) |row| for (0..mask_side) |col| {
        mask[row * mask_side + col] = if (col < mask_side / 2) 1.0 else 0.0;
    };

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/harmonize-0");
    try writeHarmonizeLens("zig-out/harmonize-0", 0.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/harmonize-1");
    try writeHarmonizeLens("zig-out/harmonize-1", 1.0);

    const shot0 = try captureHarmonizeShot(gpa, engine, "zig-out/harmonize-0", planes, mask);
    defer gpa.free(shot0);
    const shot1 = try captureHarmonizeShot(gpa, engine, "zig-out/harmonize-1", planes, mask);
    defer gpa.free(shot1);

    // A left strip well inside the person region, and a right strip inside the
    // background, both clear of the mask boundary.
    const fg0 = regionMean(shot0, 40, 150);
    const fg1 = regionMean(shot1, 40, 150);
    const bg0 = regionMean(shot0, 250, 360);
    const bg1 = regionMean(shot1, 250, 360);

    // The person region moves toward the cool background: red down, blue up.
    if (!(fg1[0] < fg0[0] - 20 and fg1[2] > fg0[2] + 20)) {
        std.debug.print("conformance: FAIL harmonize did not shift the person toward the background (fg red {d:.1}->{d:.1}, blue {d:.1}->{d:.1})\n", .{ fg0[0], fg1[0], fg0[2], fg1[2] });
        return false;
    }
    // The background region is held: the mask reads zero there, so it barely moves.
    const bg_shift = @abs(bg1[0] - bg0[0]) + @abs(bg1[2] - bg0[2]);
    const fg_shift = @abs(fg1[0] - fg0[0]) + @abs(fg1[2] - fg0[2]);
    if (!(bg_shift * 5 < fg_shift)) {
        std.debug.print("conformance: FAIL harmonize disturbed the background as much as the subject (bg shift {d:.1}, fg shift {d:.1})\n", .{ bg_shift, fg_shift });
        return false;
    }
    std.debug.print("conformance: PROOF a harmonize.pass matches the person's color distribution to the background: the subject's red falls and blue rises toward the background (fg {d:.0},{d:.0},{d:.0} -> {d:.0},{d:.0},{d:.0}) while the background holds\n", .{ fg0[0], fg0[1], fg0[2], fg1[0], fg1[1], fg1[2] });
    return true;
}

fn writeInpaintLens(dir: []const u8, radius: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.inpaint","version":"1.0.0","display_name":"Inpaint","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"i","type":"inpaint.pass","inputs":{{"frame":"camera"}},"params":{{}},"inpaint":{{"mask":"person","radius":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{radius});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Captures an inpaint.pass shot. When a removal mask is passed it is uploaded on
/// channel 0 so the pass fills that region; with none the readiness gate holds
/// the frame through, the capability degradation the proof leans on.
fn captureInpaintShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, mask: ?[]const f32) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    for (0..8) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        if (mask) |m| abi.injectMaskChannel(session, 0, @ptrCast(m.ptr));
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var w: u32 = 0;
    var h: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Mean rgb of the capture box [col_lo,col_hi) x [row_lo,row_hi), each channel 0..255.
fn boxMean(shot: []const u8, col_lo: usize, col_hi: usize, row_lo: usize, row_hi: usize) [3]f64 {
    var sum = [3]f64{ 0, 0, 0 };
    var n: f64 = 0;
    for (row_lo..row_hi) |row| {
        for (col_lo..col_hi) |col| {
            const idx = (row * 400 + col) * 4;
            inline for (0..3) |ch| sum[ch] += @floatFromInt(shot[idx + ch]);
            n += 1;
        }
    }
    return .{ sum[0] / n, sum[1] / n, sum[2] / n };
}

/// Proves content-aware fill: a red object square on a blue field named as the
/// removal mask. With no mask the readiness gate holds the frame through so the
/// square stays red; with the mask uploaded the pass fills the square from the
/// surrounding blue, so its red falls and blue rises while the field holds.
fn proveInpaint(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const u = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(width));
        const v = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(height));
        const object = u >= 0.45 and u < 0.55 and v >= 0.433 and v < 0.567;
        f[idx + 0] = if (object) 220 else 40; // red object on a blue field
        f[idx + 1] = 40;
        f[idx + 2] = if (object) 40 else 220;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    const mask = try gpa.alloc(f32, abi.segmentation_mask_len);
    defer gpa.free(mask);
    const mask_side = std.math.sqrt(abi.segmentation_mask_len);
    for (0..mask_side) |row| for (0..mask_side) |col| {
        const u = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(mask_side));
        const v = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(mask_side));
        mask[row * mask_side + col] = if (u >= 0.45 and u < 0.55 and v >= 0.433 and v < 0.567) 1.0 else 0.0;
    };

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/inpaint");
    try writeInpaintLens("zig-out/inpaint", 0.09);

    const shot0 = try captureInpaintShot(gpa, engine, "zig-out/inpaint", planes, null);
    defer gpa.free(shot0);
    const shot1 = try captureInpaintShot(gpa, engine, "zig-out/inpaint", planes, mask);
    defer gpa.free(shot1);

    // The very centre of the object square, and a blue patch off to the side.
    const obj0 = boxMean(shot0, 190, 210, 140, 160);
    const obj1 = boxMean(shot1, 190, 210, 140, 160);
    const field0 = boxMean(shot0, 30, 90, 140, 160);
    const field1 = boxMean(shot1, 30, 90, 140, 160);

    if (!(obj0[0] > 150 and obj0[2] < 100)) {
        std.debug.print("conformance: FAIL the inpaint object square did not read red before the fill ({d:.0},{d:.0},{d:.0})\n", .{ obj0[0], obj0[1], obj0[2] });
        return false;
    }
    // The removed region fills toward the surrounding blue: red down, blue up.
    if (!(obj1[0] < obj0[0] - 60 and obj1[2] > obj0[2] + 60)) {
        std.debug.print("conformance: FAIL inpaint did not fill the object from its surroundings (obj red {d:.0}->{d:.0}, blue {d:.0}->{d:.0})\n", .{ obj0[0], obj1[0], obj0[2], obj1[2] });
        return false;
    }
    // The surrounding field is untouched (the mask reads zero there).
    const field_shift = @abs(field1[0] - field0[0]) + @abs(field1[2] - field0[2]);
    if (!(field_shift < 12)) {
        std.debug.print("conformance: FAIL inpaint disturbed the surrounding field (shift {d:.1})\n", .{field_shift});
        return false;
    }
    std.debug.print("conformance: PROOF an inpaint.pass fills the masked object from its surrounding boundary: the removed square's red falls and blue rises toward the field ({d:.0},{d:.0},{d:.0} -> {d:.0},{d:.0},{d:.0}) while the field holds\n", .{ obj0[0], obj0[1], obj0[2], obj1[0], obj1[1], obj1[2] });
    return true;
}

fn writeWarpModeLens(dir: []const u8, mode: []const u8, strength: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.warp-mode","version":"1.0.0","display_name":"Warp","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"w","type":"warp.pass","inputs":{{"frame":"camera"}},"params":{{}},"warp":{{"mode":"{s}","strength":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{ mode, strength });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

fn writeRollingLens(dir: []const u8, strength: f32, readout: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.rolling","version":"1.0.0","display_name":"Rolling","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"r","type":"rolling.pass","inputs":{{"frame":"camera"}},"params":{{}},"rolling":{{"strength":{d:.3},"readout":{d:.4}}}}}],
        \\ "triggers":[]}}
    , .{ strength, readout });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Captures a rolling.pass shot. When motion is asked, two gravity samples a
/// known interval apart are submitted so the engine derives a horizontal angular
/// velocity; with none the orientation stream stays empty and the pass is inert.
fn captureRollingShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, motion: bool) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    if (motion) {
        _ = abi.goss_session_submit_orientation(session, 0, -1, 0, 0);
        _ = abi.goss_session_submit_orientation(session, 0.2, -0.98, 0, 50_000);
    }
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    for (0..8) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var w: u32 = 0;
    var h: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Mean column of the black-to-white transition across rows [row_lo, row_hi),
/// the edge position; 0 if a row held no edge.
fn edgeColumn(shot: []const u8, row_lo: usize, row_hi: usize) f64 {
    var sum: f64 = 0;
    var n: f64 = 0;
    for (row_lo..row_hi) |row| {
        var col: usize = 0;
        while (col < 400) : (col += 1) {
            if (shot[(row * 400 + col) * 4] > 128) {
                sum += @floatFromInt(col);
                n += 1;
                break;
            }
        }
    }
    return if (n > 0) sum / n else 0;
}

/// Proves rolling-shutter correction: a straight vertical edge with a camera
/// rotation submitted through the orientation stream. The engine derives the
/// horizontal motion from consecutive gravity samples and counter-shifts each
/// scanline by its readout offset, slanting the edge; still, it stays vertical.
fn proveRolling(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const v: u8 = if (col < width / 2) 0 else 255; // a straight vertical edge
        f[idx + 0] = v;
        f[idx + 1] = v;
        f[idx + 2] = v;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/rolling");
    try writeRollingLens("zig-out/rolling", 1.0, 0.05);

    const still = try captureRollingShot(gpa, engine, "zig-out/rolling", planes, false);
    defer gpa.free(still);
    const moved = try captureRollingShot(gpa, engine, "zig-out/rolling", planes, true);
    defer gpa.free(moved);

    const still_top = edgeColumn(still, 30, 70);
    const still_bot = edgeColumn(still, 230, 270);
    const moved_top = edgeColumn(moved, 30, 70);
    const moved_bot = edgeColumn(moved, 230, 270);

    if (still_top == 0 or moved_top == 0) {
        std.debug.print("conformance: FAIL the rolling test frame held no detectable edge\n", .{});
        return false;
    }
    // With no motion the edge is vertical: top and bottom columns agree.
    if (!(@abs(still_top - still_bot) < 8)) {
        std.debug.print("conformance: FAIL rolling shifted a still frame (top {d:.0}, bottom {d:.0})\n", .{ still_top, still_bot });
        return false;
    }
    // Under the submitted rotation the scanlines shift by their readout offset,
    // so the edge slants: top and bottom columns diverge well past the still.
    const moved_slant = @abs(moved_top - moved_bot);
    if (!(moved_slant > 40)) {
        std.debug.print("conformance: FAIL rolling did not slant the edge under motion (top {d:.0}, bottom {d:.0})\n", .{ moved_top, moved_bot });
        return false;
    }
    std.debug.print("conformance: PROOF a rolling.pass counter-shifts each scanline by its readout offset under a submitted camera rotation: a straight edge slants {d:.0}px top-to-bottom with motion ({d:.0} -> {d:.0}) and holds vertical without it\n", .{ moved_slant, moved_top, moved_bot });
    return true;
}

/// Captures a roll_lock warp shot. When a gravity vector is passed it is fed
/// through the orientation stream so the level correction has a tilt to counter;
/// with none the pass reads no roll and holds the frame through.
fn captureRollShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, gravity: ?[3]f32) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    if (gravity) |g| _ = abi.goss_session_submit_orientation(session, g[0], g[1], g[2], 1000);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    for (0..8) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var w: u32 = 0;
    var h: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Least-squares slope (rows per column) of the bright bar's centre row across
/// the capture columns, the bar's tilt; small is level.
fn barSlope(shot: []const u8) f64 {
    var n: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    var col: usize = 40;
    while (col < 360) : (col += 4) {
        var best_row: usize = 0;
        var best: u16 = 0;
        for (0..300) |row| {
            const lum = shot[(row * 400 + col) * 4];
            if (lum > best) {
                best = lum;
                best_row = row;
            }
        }
        if (best < 128) continue;
        const x: f64 = @floatFromInt(col);
        const y: f64 = @floatFromInt(best_row);
        n += 1;
        sx += x;
        sy += y;
        sxx += x * x;
        sxy += x * y;
    }
    const denom = n * sxx - sx * sx;
    return if (denom != 0) (n * sxy - sx * sy) / denom else 0;
}

/// Proves horizon-lock: a bright bar slanted 20 degrees, and a device gravity
/// tilted the same. The engine derives the roll from the orientation stream and
/// the roll_lock warp counter-rotates the frame, leveling the bar; with no
/// orientation the pass reads no roll and holds the frame byte-identical.
fn proveRollLock(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const slope0: f64 = 0.36397; // tan(20 degrees)
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    const cxp: f64 = @floatFromInt(width / 2);
    const cyp: f64 = @floatFromInt(height / 2);
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const bar_center = cyp + slope0 * (@as(f64, @floatFromInt(col)) - cxp);
        const on = @abs(@as(f64, @floatFromInt(row)) - bar_center) < 9.0;
        const v: u8 = if (on) 240 else 20;
        f[idx + 0] = v;
        f[idx + 1] = v;
        f[idx + 2] = v;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/rolllock");
    try writeWarpModeLens("zig-out/rolllock", "roll_lock", 1.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/rolllock-0");
    try writeWarpModeLens("zig-out/rolllock-0", "roll_lock", 0.0);

    // A 20-degree device roll: gravity tips out of straight-down by the same angle.
    const tilt = [3]f32{ 0.34202, -0.93969, 0 };
    const control = try captureRollShot(gpa, engine, "zig-out/rolllock-0", planes, tilt);
    defer gpa.free(control);
    const leveled = try captureRollShot(gpa, engine, "zig-out/rolllock", planes, tilt);
    defer gpa.free(leveled);
    const no_imu = try captureRollShot(gpa, engine, "zig-out/rolllock", planes, null);
    defer gpa.free(no_imu);

    // With no orientation the pass reads no roll and holds the frame through.
    if (!std.mem.eql(u8, no_imu, control)) {
        std.debug.print("conformance: FAIL roll_lock altered the frame with no orientation submitted\n", .{});
        return false;
    }
    const control_slope = @abs(barSlope(control));
    const leveled_slope = @abs(barSlope(leveled));
    if (!(control_slope > 0.2)) {
        std.debug.print("conformance: FAIL the roll_lock test bar was not measurably tilted ({d:.3})\n", .{control_slope});
        return false;
    }
    if (!(leveled_slope < control_slope * 0.4)) {
        std.debug.print("conformance: FAIL roll_lock did not level the tilted bar (control slope {d:.3}, leveled {d:.3})\n", .{ control_slope, leveled_slope });
        return false;
    }
    std.debug.print("conformance: PROOF a roll_lock warp counter-rotates the frame by the roll the orientation stream carries: a 20-degree tilted bar levels from slope {d:.3} to {d:.3} while it holds byte-identical with no orientation\n", .{ control_slope, leveled_slope });
    return true;
}

/// A synthetic face on a circle with the iris loops placed at two eyes and an
/// eyeLook gaze set, so a gaze_correct warp has irises to redirect. The gaze is
/// out-left, a clear horizontal look off the lens.
fn gazeFace() abi.FaceResult {
    var synthetic = std.mem.zeroes(abi.FaceResult);
    synthetic.presence = 1.0;
    const lm_count = synthetic.landmarks.len / 3;
    synthetic.landmark_count_out = @intCast(lm_count);
    const cxp: f32 = @as(f32, @floatFromInt(width)) / 2.0;
    const cyp: f32 = @as(f32, @floatFromInt(height)) / 2.0;
    for (0..lm_count) |lm| {
        const ang = @as(f32, @floatFromInt(lm)) / @as(f32, @floatFromInt(lm_count)) * std.math.tau;
        synthetic.landmarks[lm * 3 + 0] = cxp + 110.0 * @cos(ang);
        synthetic.landmarks[lm * 3 + 1] = cyp + 110.0 * @sin(ang);
        synthetic.landmarks[lm * 3 + 2] = 0;
    }
    // The iris loops sit at the two eyes so their centroids land where the
    // redirect should push.
    for ([_]u16{ 474, 475, 476, 477 }) |idx| {
        synthetic.landmarks[idx * 3 + 0] = cxp - 45.0;
        synthetic.landmarks[idx * 3 + 1] = cyp - 25.0;
    }
    for ([_]u16{ 469, 470, 471, 472 }) |idx| {
        synthetic.landmarks[idx * 3 + 0] = cxp + 45.0;
        synthetic.landmarks[idx * 3 + 1] = cyp - 25.0;
    }
    // blendshape_names[14] is eyeLookInRight and [15] eyeLookOutLeft, both a
    // look to the subject's left, pinned by a face module test.
    synthetic.blendshapes[15] = 1.0;
    synthetic.blendshapes[14] = 1.0;
    return synthetic;
}

/// Proves gaze correction: a synthetic face looking off the lens, its irises at
/// two eyes. The gaze_correct warp reads the gaze from the blendshapes and pushes
/// each pupil back toward the lens, so the eye region shifts versus a strength-0
/// control while the no-face frame and a far corner stay byte-identical.
fn proveGazeCorrect(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const cap_w: usize = 400;
    const frame_rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(frame_rgba);
    for (0..height) |row| for (0..width) |col| {
        const i = (row * @as(usize, width) + col) * 4;
        frame_rgba[i + 0] = @intCast(col * 255 / (@as(usize, width) - 1));
        frame_rgba[i + 1] = @intCast(row * 255 / (@as(usize, height) - 1));
        frame_rgba[i + 2] = 128;
        frame_rgba[i + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = frame_rgba }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    const face = gazeFace();
    const faces_one = [_]abi.FaceResult{face};
    const no_faces = [_]abi.FaceResult{};

    const gaze_json =
        \\{"glf":"1.0","id":"goss.reference.gaze","version":"1.0.0","display_name":"Gaze","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"gaze_correct","strength":0.15,"radius":0.12}}],"triggers":[]}
    ;
    const control_json =
        \\{"glf":"1.0","id":"goss.reference.gaze-control","version":"1.0.0","display_name":"Gaze Control","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"gaze_correct","strength":0.0,"radius":0.12}}],"triggers":[]}
    ;

    const redirected = try captureSubmittedFaceShot(gpa, engine, planes, gaze_json, &faces_one);
    defer gpa.free(redirected);
    const redirected2 = try captureSubmittedFaceShot(gpa, engine, planes, gaze_json, &faces_one);
    defer gpa.free(redirected2);
    const control = try captureSubmittedFaceShot(gpa, engine, planes, control_json, &faces_one);
    defer gpa.free(control);
    const no_face = try captureSubmittedFaceShot(gpa, engine, planes, gaze_json, &no_faces);
    defer gpa.free(no_face);
    const plain = try captureSubmittedFaceShot(gpa, engine, planes, null, &no_faces);
    defer gpa.free(plain);

    if (!std.mem.eql(u8, redirected, redirected2)) {
        std.debug.print("conformance: FAIL gaze_correct is not bit-stable across runs\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, no_face, plain)) {
        std.debug.print("conformance: FAIL gaze_correct altered the frame with no face - not keyed to the eyes\n", .{});
        return false;
    }
    var gcx: f32 = 0;
    var gcy: f32 = 0;
    const changed = changedRegion(redirected, control, cap_w, 300, &gcx, &gcy);
    if (!(changed > 200)) {
        std.debug.print("conformance: FAIL gaze_correct did not redirect the eye region ({d} px changed)\n", .{changed});
        return false;
    }
    if (!cornerBlockEqual(redirected, control, cap_w, 40)) {
        std.debug.print("conformance: FAIL gaze_correct changed a far corner outside the eyes\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a gaze_correct warp reads the gaze from the blendshapes and redirects the pupils at the iris centroids: the eye region shifts ({d} px) versus a strength-0 control while a far corner and the no-face frame stay byte-identical\n", .{changed});
    return true;
}

/// The mean red value over the capture's center block, a stand-in for the fused
/// gray the sprite draws there.
fn centerGray(shot: []const u8) u16 {
    var sum: u64 = 0;
    var n: u64 = 0;
    for (120..180) |row| {
        for (160..240) |col| {
            sum += shot[(row * 400 + col) * 4];
            n += 1;
        }
    }
    return @intCast(sum / n);
}

/// The centroid column and pixel count of the bright marker in a capture, the
/// pixels whose red passes the threshold; count 0 leaves the column at zero.
fn brightMarker(shot: []const u8, threshold: u8) struct { cx: f64, count: usize } {
    var sum_x: f64 = 0;
    var count: usize = 0;
    for (0..300) |row| {
        for (0..400) |col| {
            if (shot[(row * 400 + col) * 4] > threshold) {
                sum_x += @floatFromInt(col);
                count += 1;
            }
        }
    }
    return .{ .cx = if (count > 0) sum_x / @as(f64, @floatFromInt(count)) else 0, .count = count };
}

/// Proves auto-framing: a small face off to the left of the frame, marked by a
/// bright dot at its center. The auto_frame warp steers the face toward the
/// target anchor and grows it to the target size, so the marker moves toward the
/// frame center and enlarges; with no face it holds the frame through.
fn proveAutoFrame(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const f = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(f);
    const dot_x: f64 = 140;
    const dot_y: f64 = 110;
    for (0..height) |row| for (0..width) |col| {
        const idx = (row * @as(usize, width) + col) * 4;
        const dx = @as(f64, @floatFromInt(col)) - dot_x;
        const dy = @as(f64, @floatFromInt(row)) - dot_y;
        const on = dx * dx + dy * dy < 12.0 * 12.0;
        const v: u8 = if (on) 240 else 20;
        f[idx + 0] = v;
        f[idx + 1] = v;
        f[idx + 2] = v;
        f[idx + 3] = 255;
    };
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = f }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    // A small synthetic face centered on the marker, so its center and covering
    // size drive the reframe toward the anchor and target size.
    var synthetic = std.mem.zeroes(abi.FaceResult);
    synthetic.presence = 1.0;
    const lm_count = synthetic.landmarks.len / 3;
    synthetic.landmark_count_out = @intCast(lm_count);
    for (0..lm_count) |lm| {
        const ang = @as(f32, @floatFromInt(lm)) / @as(f32, @floatFromInt(lm_count)) * std.math.tau;
        synthetic.landmarks[lm * 3 + 0] = @as(f32, @floatCast(dot_x)) + 38.0 * @cos(ang);
        synthetic.landmarks[lm * 3 + 1] = @as(f32, @floatCast(dot_y)) + 38.0 * @sin(ang);
    }
    const faces_one = [_]abi.FaceResult{synthetic};
    const no_faces = [_]abi.FaceResult{};

    const frame_json =
        \\{"glf":"1.0","id":"goss.reference.autoframe","version":"1.0.0","display_name":"Auto Frame","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"auto_frame","strength":0.4,"center_x":0.5,"center_y":0.42}}],"triggers":[]}
    ;

    const framed = try captureSubmittedFaceShot(gpa, engine, planes, frame_json, &faces_one);
    defer gpa.free(framed);
    const framed2 = try captureSubmittedFaceShot(gpa, engine, planes, frame_json, &faces_one);
    defer gpa.free(framed2);
    const no_face = try captureSubmittedFaceShot(gpa, engine, planes, frame_json, &no_faces);
    defer gpa.free(no_face);
    const plain = try captureSubmittedFaceShot(gpa, engine, planes, null, &no_faces);
    defer gpa.free(plain);

    if (!std.mem.eql(u8, framed, framed2)) {
        std.debug.print("conformance: FAIL auto_frame is not bit-stable across runs\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, no_face, plain)) {
        std.debug.print("conformance: FAIL auto_frame altered the frame with no face - not keyed to the face\n", .{});
        return false;
    }
    const before = brightMarker(plain, 180);
    const after = brightMarker(framed, 180);
    if (before.count == 0 or after.count == 0) {
        std.debug.print("conformance: FAIL the auto_frame marker was not found\n", .{});
        return false;
    }
    // The marker moves toward the frame center (anchor x 0.5 -> column 200).
    if (!(@abs(after.cx - 200.0) < @abs(before.cx - 200.0) - 20.0)) {
        std.debug.print("conformance: FAIL auto_frame did not recenter the face (marker column {d:.0} -> {d:.0})\n", .{ before.cx, after.cx });
        return false;
    }
    // The small face is grown toward the target size, so the marker enlarges.
    if (!(after.count > before.count * 3 / 2)) {
        std.debug.print("conformance: FAIL auto_frame did not enlarge the small face (marker {d} px -> {d} px)\n", .{ before.count, after.count });
        return false;
    }
    std.debug.print("conformance: PROOF an auto_frame warp steers the tracked face to the target anchor and size: an off-center small face's marker recenters (column {d:.0} -> {d:.0}) and grows ({d} px -> {d} px), holding the frame through with no face\n", .{ before.cx, after.cx, before.count, after.count });
    return true;
}

fn writeTemporalLens(dir: []const u8, model: []const u8, frames: u32, mode: []const u8, phase: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.temporal","version":"1.0.0","display_name":"Temporal","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"fuse","type":"temporal.fuse","params":{{}},"temporal":{{"model":"m.onnx","frames":{d},"mode":"{s}","phase":{d:.3},"sprite":"canvas"}}}},
        \\  {{"id":"canvas","type":"sprite.2d","inputs":{{"frame":"camera"}},"params":{{}},"sprite":{{"x":0.0,"y":0.0,"w":1.0,"h":1.0}}}}],
        \\ "triggers":[]}}
    , .{ frames, mode, phase });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/m.onnx", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

fn writeTemporalHdrLens(dir: []const u8, model: []const u8, frames: u32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.temporal-hdr","version":"1.0.0","display_name":"Temporal HDR","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"fuse","type":"temporal.fuse","params":{{}},"temporal":{{"model":"m.onnx","frames":{d},"mode":"hdr","source":"bracket","sprite":"canvas"}}}},
        \\  {{"id":"canvas","type":"sprite.2d","inputs":{{"frame":"camera"}},"params":{{}},"sprite":{{"x":0.0,"y":0.0,"w":1.0,"h":1.0}}}}],
        \\ "triggers":[]}}
    , .{frames});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/m.onnx", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

fn solidNv12(gpa: std.mem.Allocator, gray: u8) !Nv12Copy {
    const rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(rgba);
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        rgba[i + 0] = gray;
        rgba[i + 1] = gray;
        rgba[i + 2] = gray;
        rgba[i + 3] = 255;
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = rgba }, .width = width, .height = height };
    return rgbaToNv12(gpa, frame);
}

/// Activates a temporal.fuse lens and feeds it a run of distinct solid-gray
/// frames, each a distinct timestamp so the ring keeps them all, then waits for
/// the fused image to publish and captures the sprite it draws. Null on timeout.
fn captureTemporalShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, grays: []const u8) !?[]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const half_w = (width + 1) / 2;
    for (grays, 0..) |gray, i| {
        const planes = try solidNv12(gpa, gray);
        defer planes.deinit(gpa);
        const desc: abi.FrameDesc = .{ .width = width, .height = height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 1000) };
        // track_frame feeds the fusion worker its ring; re-fed until the worker
        // rings this exact frame (deduped by timestamp), so the frames land in
        // order before the next distinct one replaces the mailbox.
        const want: u32 = @intCast(@min(i + 1, grays.len));
        var spins: usize = 0;
        while (abi.temporalRingFilled(session) < want) {
            _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, width, planes.uv.ptr, half_w * 2);
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
            _ = abi.goss_engine_render_frame(engine, session);
            std.Thread.yield() catch {};
            c.glfwPollEvents();
            spins += 1;
            if (spins > 20000) return null;
        }
    }
    // Wait for the fused image to publish and upload, then draw the sprite. The
    // last frame stays current so the sprite composites over it.
    const last = try solidNv12(gpa, grays[grays.len - 1]);
    defer last.deinit(gpa);
    const last_desc: abi.FrameDesc = .{ .width = width, .height = height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast(grays.len * 1000) };
    var polls: usize = 0;
    while (abi.styleTextureCount(session) == 0) {
        _ = abi.goss_session_submit_frame_copy(session, &last_desc, last.y.ptr, width, last.uv.ptr, half_w * 2);
        _ = abi.goss_engine_render_frame(engine, session);
        std.Thread.yield() catch {};
        c.glfwPollEvents();
        polls += 1;
        if (polls > 20000) return null;
    }
    var shot: []u8 = &.{};
    for (0..8) |i| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == 6) {
            shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            errdefer gpa.free(shot);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return shot;
}

/// Proves multi-frame fusion: a two-input averaging net fed a dark then a bright
/// frame draws their per-pixel mean through the sprite, distinct from either, and
/// a three-frame lens averages three. The ring keeps distinct frames, not copies
/// of the latest, or the mean would collapse to the last frame.
fn proveTemporalFuse(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 16;

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/temporal-2/assets");
    try writeTemporalLens("zig-out/temporal-2", onnxMeanModel(a, 2, side), 2, "denoise", 0.5);
    const shot2 = (try captureTemporalShot(gpa, engine, "zig-out/temporal-2", &.{ 51, 204 })) orelse {
        std.debug.print("conformance: FAIL temporal.fuse never published a fused image\n", .{});
        return false;
    };
    defer gpa.free(shot2);
    const mid = centerGray(shot2);
    // The mean of 0.2 and 0.8 is 0.5, distinct from either fed frame.
    if (!(mid > 110 and mid < 145)) {
        std.debug.print("conformance: FAIL temporal.fuse did not average its two frames (center {d})\n", .{mid});
        return false;
    }

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/temporal-3/assets");
    try writeTemporalLens("zig-out/temporal-3", onnxMeanModel(a, 3, side), 3, "denoise", 0.5);
    const shot3 = (try captureTemporalShot(gpa, engine, "zig-out/temporal-3", &.{ 30, 128, 226 })) orelse {
        std.debug.print("conformance: FAIL the three-frame temporal.fuse never published\n", .{});
        return false;
    };
    defer gpa.free(shot3);
    const mid3 = centerGray(shot3);
    if (!(mid3 > 110 and mid3 < 145)) {
        std.debug.print("conformance: FAIL the three-frame temporal.fuse did not average three frames (center {d})\n", .{mid3});
        return false;
    }
    std.debug.print("conformance: PROOF a temporal.fuse node fuses a ring of the last N frames through its sprite: a two-frame average of a dark and a bright frame reads {d} (their mean, distinct from either) and a three-frame average reads {d}\n", .{ mid, mid3 });
    return true;
}

/// Proves frame interpolation: a phase-input net blends two frames by the
/// authored phase, so a phase toward the first frame reads darker and toward the
/// second reads brighter, the midpoint between them.
fn proveTemporalInterpolate(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 16;

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/temporal-lerp-lo/assets");
    try writeTemporalLens("zig-out/temporal-lerp-lo", onnxLerpModel(a, side), 2, "interpolate", 0.25);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/temporal-lerp-hi/assets");
    try writeTemporalLens("zig-out/temporal-lerp-hi", onnxLerpModel(a, side), 2, "interpolate", 0.75);

    const lo = (try captureTemporalShot(gpa, engine, "zig-out/temporal-lerp-lo", &.{ 40, 220 })) orelse {
        std.debug.print("conformance: FAIL the interpolate lens never published (low phase)\n", .{});
        return false;
    };
    defer gpa.free(lo);
    const hi = (try captureTemporalShot(gpa, engine, "zig-out/temporal-lerp-hi", &.{ 40, 220 })) orelse {
        std.debug.print("conformance: FAIL the interpolate lens never published (high phase)\n", .{});
        return false;
    };
    defer gpa.free(hi);
    const lo_g = centerGray(lo);
    const hi_g = centerGray(hi);
    // Phase 0.25 sits nearer the dark first frame, phase 0.75 nearer the bright
    // second frame, so the high phase reads clearly brighter.
    if (!(hi_g > lo_g + 40)) {
        std.debug.print("conformance: FAIL temporal interpolate did not vary with phase (0.25 -> {d}, 0.75 -> {d})\n", .{ lo_g, hi_g });
        return false;
    }
    std.debug.print("conformance: PROOF a temporal.fuse interpolate net blends two frames by the authored phase: phase 0.25 reads {d} and phase 0.75 reads {d}, tracking from the first frame toward the second\n", .{ lo_g, hi_g });
    return true;
}

/// Activates a bracket-source temporal.fuse lens and submits a run of exposures
/// through the frame-bracket op, one at a time so the ring keeps them in order,
/// asserting the fusion does not publish until the full bracket has landed, then
/// captures the fused image. Null on timeout or an early publish.
fn captureTemporalBracketShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, grays: []const u8) !?[]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const half_w = (width + 1) / 2;
    for (grays, 0..) |gray, i| {
        const planes = try solidNv12(gpa, gray);
        defer planes.deinit(gpa);
        const desc: abi.FrameDesc = .{ .width = width, .height = height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        // One bracket submit per exposure; the op stamps its own sequence so the
        // ring keeps each. Wait for it to ring before the next exposure.
        if (abi.goss_session_submit_frame_bracket(session, &desc, planes.y.ptr, width, planes.uv.ptr, half_w * 2) != .ok) return error.BracketSubmitFailed;
        const want: u32 = @intCast(i + 1);
        var spins: usize = 0;
        while (abi.temporalRingFilled(session) < want) {
            _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, width, planes.uv.ptr, half_w * 2);
            _ = abi.goss_engine_render_frame(engine, session);
            std.Thread.yield() catch {};
            c.glfwPollEvents();
            spins += 1;
            if (spins > 20000) return null;
        }
        // The ring is not full until the last exposure, so nothing has published.
        if (i + 1 < grays.len and abi.styleTextureCount(session) != 0) {
            std.debug.print("conformance: FAIL temporal hdr published before the full bracket landed\n", .{});
            return null;
        }
    }
    const last = try solidNv12(gpa, grays[grays.len - 1]);
    defer last.deinit(gpa);
    const last_desc: abi.FrameDesc = .{ .width = width, .height = height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 2000 };
    var polls: usize = 0;
    while (abi.styleTextureCount(session) == 0) {
        _ = abi.goss_session_submit_frame_copy(session, &last_desc, last.y.ptr, width, last.uv.ptr, half_w * 2);
        _ = abi.goss_engine_render_frame(engine, session);
        std.Thread.yield() catch {};
        c.glfwPollEvents();
        polls += 1;
        if (polls > 20000) return null;
    }
    var shot: []u8 = &.{};
    for (0..8) |i| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == 6) {
            shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            errdefer gpa.free(shot);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return shot;
}

/// Proves HDR exposure fusion: a three-exposure bracket submitted through the
/// frame-bracket op fuses to its mean, distinct from any single exposure, and the
/// fusion holds off until the whole bracket has landed. The exposures are fed as
/// a bracket source, not the live camera.
fn proveTemporalHdr(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 16;
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/temporal-hdr/assets");
    try writeTemporalHdrLens("zig-out/temporal-hdr", onnxMeanModel(a, 3, side), 3);
    const shot = (try captureTemporalBracketShot(gpa, engine, "zig-out/temporal-hdr", &.{ 20, 100, 240 })) orelse {
        std.debug.print("conformance: FAIL temporal hdr never fused the bracket\n", .{});
        return false;
    };
    defer gpa.free(shot);
    const fused = centerGray(shot);
    // The mean of 20, 100 and 240 is 120, distinct from every single exposure.
    if (!(fused > 105 and fused < 135)) {
        std.debug.print("conformance: FAIL temporal hdr did not fuse the bracket to its mean (center {d})\n", .{fused});
        return false;
    }
    std.debug.print("conformance: PROOF a temporal.fuse hdr node merges an exposure bracket submitted through the frame-bracket op: three exposures fuse to their mean {d}, distinct from any single, and hold off until the whole bracket lands\n", .{fused});
    return true;
}

fn writeAudioEnhanceLens(dir: []const u8, strength: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.audio-enhance","version":"1.0.0","display_name":"Audio Enhance","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"clean","type":"audio.enhance","params":{{}},"enhance":{{"strength":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{strength});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Mixes a mic buffer through an audio.enhance lens (no lens sound, so the output
/// is the cleaned mic) and returns the i16 output track.
fn captureMixOutput(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, mic: []const f32, sample_rate: u32) ![]i16 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const out = try gpa.alloc(i16, mic.len);
    errdefer gpa.free(out);
    if (abi.goss_session_mix_output_audio(session, mic.ptr, out.ptr, @intCast(mic.len), sample_rate, 1) != .ok) return error.MixFailed;
    return out;
}

/// The total variation of an i16 track (the sum of absolute sample-to-sample
/// steps), a proxy for its high-frequency energy: a hiss-laden signal steps hard
/// every sample, a low-passed one steps gently.
fn stepEnergy(track: []const i16) u64 {
    var sum: u64 = 0;
    for (1..track.len) |i| {
        const d = @as(i32, track[i]) - @as(i32, track[i - 1]);
        sum += @abs(d);
    }
    return sum;
}

/// Proves microphone noise suppression: a 500 Hz tone buried under a per-sample
/// high-frequency hiss. An audio.enhance node low-passes the outgoing mic so the
/// hiss (its high-frequency energy) drops sharply, while a strength-0 control
/// passes the raw mic straight through.
fn proveAudioDenoise(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const sample_rate: u32 = 48000;
    const n: usize = 4800;
    const mic = try gpa.alloc(f32, n);
    defer gpa.free(mic);
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        const tone = 0.3 * @sin(2.0 * std.math.pi * 500.0 * t);
        const hiss: f32 = if (i % 2 == 0) 0.35 else -0.35;
        mic[i] = tone + hiss;
    }

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/audio-enh-0");
    try writeAudioEnhanceLens("zig-out/audio-enh-0", 0.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/audio-enh-1");
    try writeAudioEnhanceLens("zig-out/audio-enh-1", 1.0);

    const raw = try captureMixOutput(gpa, engine, "zig-out/audio-enh-0", mic, sample_rate);
    defer gpa.free(raw);
    const cleaned = try captureMixOutput(gpa, engine, "zig-out/audio-enh-1", mic, sample_rate);
    defer gpa.free(cleaned);

    const tv_raw = stepEnergy(raw);
    const tv_clean = stepEnergy(cleaned);
    if (!(tv_raw > 0)) {
        std.debug.print("conformance: FAIL the audio-enhance test mic had no high-frequency energy\n", .{});
        return false;
    }
    // The hiss carries most of the raw signal's step energy; the low-pass cuts it
    // to well under half.
    if (!(tv_clean * 2 < tv_raw)) {
        std.debug.print("conformance: FAIL audio.enhance did not suppress the mic hiss (step energy {d} -> {d})\n", .{ tv_raw, tv_clean });
        return false;
    }
    std.debug.print("conformance: PROOF an audio.enhance node cleans the outgoing microphone: a tone buried under per-sample hiss loses its high-frequency step energy ({d} -> {d}) while a strength-0 control passes the raw mic through\n", .{ tv_raw, tv_clean });
    return true;
}

fn writeVoiceLens(dir: []const u8, pitch: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.voice","version":"1.0.0","display_name":"Voice","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"vox","type":"voice.transform","params":{{}},"voice":{{"pitch":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{pitch});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Counts the hysteresis-gated zero crossings over the latter half of an i16
/// track (past the delay-line fill), a proxy for its fundamental frequency: a
/// crossing counts only when the signal swings fully from below -thresh to above
/// +thresh or back, so crossfade ripple does not inflate the count.
fn gatedCrossings(track: []const i16) u64 {
    const thresh: i32 = 3000;
    var count: u64 = 0;
    var high = false;
    var started = false;
    for (track[track.len / 2 ..]) |sample| {
        const v: i32 = sample;
        if (v > thresh) {
            if (started and !high) count += 1;
            high = true;
            started = true;
        } else if (v < -thresh) {
            if (started and high) count += 1;
            high = false;
            started = true;
        }
    }
    return count;
}

/// Proves real-time voice change: a 300 Hz tone through a voice.transform node at
/// pitch 1.5 comes out near 450 Hz, its fundamental shifted by the ratio while the
/// track keeps its length; a pitch-1 control leaves the tone's pitch unchanged.
fn proveVoiceTransform(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const sample_rate: u32 = 48000;
    const n: usize = 9600;
    const mic = try gpa.alloc(f32, n);
    defer gpa.free(mic);
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        mic[i] = 0.5 * @sin(2.0 * std.math.pi * 300.0 * t);
    }

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/voice-1");
    try writeVoiceLens("zig-out/voice-1", 1.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/voice-up");
    try writeVoiceLens("zig-out/voice-up", 1.5);

    const flat = try captureMixOutput(gpa, engine, "zig-out/voice-1", mic, sample_rate);
    defer gpa.free(flat);
    const shifted = try captureMixOutput(gpa, engine, "zig-out/voice-up", mic, sample_rate);
    defer gpa.free(shifted);

    if (shifted.len != mic.len) {
        std.debug.print("conformance: FAIL voice.transform changed the track length\n", .{});
        return false;
    }
    const zc_flat = gatedCrossings(flat);
    const zc_shift = gatedCrossings(shifted);
    if (!(zc_flat > 0)) {
        std.debug.print("conformance: FAIL the voice.transform control tone had no measurable pitch\n", .{});
        return false;
    }
    const ratio = @as(f64, @floatFromInt(zc_shift)) / @as(f64, @floatFromInt(zc_flat));
    // The fundamental should scale by the pitch ratio 1.5, within a tolerance for
    // the crossfade and the discrete crossing count.
    if (!(ratio > 1.3 and ratio < 1.7)) {
        std.debug.print("conformance: FAIL voice.transform did not shift the pitch by the ratio (crossings {d} -> {d}, ratio {d:.2})\n", .{ zc_flat, zc_shift, ratio });
        return false;
    }
    std.debug.print("conformance: PROOF a voice.transform node pitch-shifts the outgoing microphone by its ratio while keeping the track length: a 300 Hz tone's fundamental scales {d:.2}x (crossings {d} -> {d}) at pitch 1.5, and a pitch-1 control holds\n", .{ ratio, zc_flat, zc_shift });
    return true;
}

/// Proves the diarized caption segment read-back: a captioning audio.infer node's
/// decoded utterance lands in the segment ring, tagged with the times it spanned
/// and read back through the segment ABI, its metadata and text separate.
fn proveCaptionSegment(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const model = buildOnnxCaptionProbe(arena.allocator());
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/caption-seg/assets");
    try writeCaptionLens("zig-out/caption-seg", model);

    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, "zig-out/caption-seg", "zig-out/caption-seg".len) != .ok) return error.ActivationFailed;

    const samples = try gpa.alloc(f32, 512);
    defer gpa.free(samples);
    @memset(samples, 0.3);
    const signals = std.mem.zeroes(abi.LensSignals);
    var seg: abi.CaptionSegment = undefined;
    var polls: usize = 0;
    while (abi.goss_session_caption_segment(session, 0, &seg) != .ok) : (polls += 1) {
        _ = abi.goss_session_submit_audio(session, samples.ptr, 512, 48000, 1, @intCast(1000 + polls * 1000));
        _ = abi.goss_session_tick_lens(session, 16000, &signals);
        if (polls > 100000) {
            std.debug.print("conformance: FAIL the caption never landed in the segment ring\n", .{});
            return false;
        }
    }
    var buf: [256]u8 = undefined;
    var out_len: usize = 0;
    if (abi.goss_session_caption_segment_text(session, 0, &buf, buf.len, &out_len) != .ok) {
        std.debug.print("conformance: FAIL the caption segment text was not readable\n", .{});
        return false;
    }
    if (!(seg.text_len == 2 and out_len == 2 and std.mem.eql(u8, buf[0..out_len], "hi"))) {
        std.debug.print("conformance: FAIL the caption segment did not carry the decoded text ('{s}', len {d})\n", .{ buf[0..out_len], seg.text_len });
        return false;
    }
    if (!(seg.end_us > seg.start_us)) {
        std.debug.print("conformance: FAIL the caption segment did not span a time ({d} -> {d})\n", .{ seg.start_us, seg.end_us });
        return false;
    }
    std.debug.print("conformance: PROOF a diarized caption segment lands in the read-back ring: the decoded utterance 'hi' is held with the times it spanned ({d} -> {d}) and its speaker, its metadata and text read back separately\n", .{ seg.start_us, seg.end_us });
    return true;
}

/// Emits a 1x1 conv net: input [1,cin,side,side] plus any extra (unused) inputs,
/// a weight of cout x cin, output [1,cout,side,side]. The diffusion proof builds
/// its encoder, unet, and decoder from this.
fn onnxConvModel(a: std.mem.Allocator, in_name: []const u8, cin: i64, cout: i64, side: i64, weights: []const f32, extra_inputs: []const []const u8) []const u8 {
    var w: OnnxPb = .{ .a = a };
    w.varintField(1, cout);
    w.varintField(1, cin);
    w.varintField(1, 1);
    w.varintField(1, 1);
    w.varintField(2, 1);
    var raw: std.ArrayList(u8) = .empty;
    for (weights) |v| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @bitCast(v), .little);
        raw.appendSlice(a, &b) catch unreachable;
    }
    w.bytesField(9, raw.items);
    w.bytesField(8, "W");
    const conv = onnxNode(a, "Conv", &.{ in_name, "W" }, &.{"y"}, &.{
        .{ .name = "kernel_shape", .ints = &.{ 1, 1 } },
        .{ .name = "strides", .ints = &.{ 1, 1 } },
        .{ .name = "pads", .ints = &.{ 0, 0, 0, 0 } },
    });
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, conv);
    g.bytesField(5, w.buf.items);
    g.bytesField(11, onnxValueInfo(a, in_name, &.{ 1, cin, side, side }));
    for (extra_inputs) |ei| g.bytesField(11, ei);
    g.bytesField(11, onnxValueInfo(a, "W", &.{ cout, cin, 1, 1 }));
    g.bytesField(12, onnxValueInfo(a, "y", &.{ 1, cout, side, side }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// A synthetic ONNX model whose single 1x1 conv has zero weights and a bias equal
/// to `values`, so its output is exactly `values` for any frame. It hands a
/// splat.cloud a known gaussian set (xyz, scale, quaternion, opacity, rgb per
/// splat) so the render can be asserted precisely against fixed splats.
fn onnxConstModel(a: std.mem.Allocator, values: []const f32) []const u8 {
    const cout: i64 = @intCast(values.len);
    const cin: i64 = 3;
    var w: OnnxPb = .{ .a = a };
    w.varintField(1, cout);
    w.varintField(1, cin);
    w.varintField(1, 1);
    w.varintField(1, 1);
    w.varintField(2, 1);
    var wraw: std.ArrayList(u8) = .empty;
    var wi: usize = 0;
    while (wi < values.len * 3) : (wi += 1) wraw.appendSlice(a, &[4]u8{ 0, 0, 0, 0 }) catch unreachable;
    w.bytesField(9, wraw.items);
    w.bytesField(8, "W");
    var bp: OnnxPb = .{ .a = a };
    bp.varintField(1, cout);
    bp.varintField(2, 1);
    var braw: std.ArrayList(u8) = .empty;
    for (values) |v| {
        var b4: [4]u8 = undefined;
        std.mem.writeInt(u32, &b4, @bitCast(v), .little);
        braw.appendSlice(a, &b4) catch unreachable;
    }
    bp.bytesField(9, braw.items);
    bp.bytesField(8, "B");
    const conv = onnxNode(a, "Conv", &.{ "x", "W", "B" }, &.{"y"}, &.{
        .{ .name = "kernel_shape", .ints = &.{ 1, 1 } },
        .{ .name = "strides", .ints = &.{ 1, 1 } },
        .{ .name = "pads", .ints = &.{ 0, 0, 0, 0 } },
    });
    var g: OnnxPb = .{ .a = a };
    g.bytesField(1, conv);
    g.bytesField(5, w.buf.items);
    g.bytesField(5, bp.buf.items);
    g.bytesField(11, onnxValueInfo(a, "x", &.{ 1, cin, 1, 1 }));
    g.bytesField(11, onnxValueInfo(a, "W", &.{ cout, cin, 1, 1 }));
    g.bytesField(11, onnxValueInfo(a, "B", &.{cout}));
    g.bytesField(12, onnxValueInfo(a, "y", &.{ 1, cout, 1, 1 }));
    var model: OnnxPb = .{ .a = a };
    model.varintField(1, 7);
    model.bytesField(7, g.buf.items);
    return model.buf.items;
}

/// The knobs a diffusion reference lens varies. A null encoder starts from pure
/// noise (text to image); a text_embedding ships a cond asset; a sprite_mask
/// keys the output; coherence turns on the temporal filter; target_mesh draws
/// the generated texture through a mesh.face material instead of a sprite.
const DiffusionLensSpec = struct {
    dir: []const u8,
    enc: ?[]const u8 = null,
    unet: []const u8,
    dec: []const u8,
    text_embedding: ?[]const u8 = null,
    sprite_mask: ?[]const u8 = null,
    sprite_mask_over: bool = false,
    coherence: f32 = 0,
    target_mesh: bool = false,
    target_material: bool = false,
};

fn writeDiffusionLens(spec: DiffusionLensSpec) !void {
    const page = std.heap.page_allocator;
    const enc_field = if (spec.enc != null) "\"encoder\":\"enc.onnx\"," else "";
    const cond_field = if (spec.text_embedding != null) "\"text_embedding\":\"cond.bin\"," else "";
    const mode = if (spec.sprite_mask_over) ",\"mask_mode\":\"over\"" else "";
    const mask_field = if (spec.sprite_mask) |m| try std.fmt.allocPrint(page, ",\"mask\":\"{s}\"{s}", .{ m, mode }) else try page.dupe(u8, "");
    defer page.free(mask_field);
    const coherence_field = if (spec.coherence > 0) try std.fmt.allocPrint(page, ",\"coherence\":{d}", .{spec.coherence}) else try page.dupe(u8, "");
    defer page.free(coherence_field);
    // The target node the diffusion draws through: a full-frame sprite, a face
    // mesh that samples the generated texture as its material, or a shader.pass
    // whose material graph samples the reserved `generated` texture.
    const literal_target = spec.target_mesh or spec.target_material;
    const target_node = if (spec.target_mesh)
        "{\"id\":\"canvas\",\"type\":\"mesh.face\",\"inputs\":{\"frame\":\"camera\"},\"params\":{}}"
    else if (spec.target_material)
        "{\"id\":\"canvas\",\"type\":\"shader.pass\",\"inputs\":{\"frame\":\"camera\"},\"params\":{},\"material\":{\"output\":3,\"nodes\":[{\"kind\":\"uv\"},{\"kind\":\"texture\",\"name\":\"generated\"},{\"kind\":\"sample\",\"inputs\":[1,0]},{\"kind\":\"output\",\"inputs\":[2]}]}}"
    else
        try std.fmt.allocPrint(page, "{{\"id\":\"canvas\",\"type\":\"sprite.2d\",\"inputs\":{{\"frame\":\"camera\"}},\"params\":{{}}, \"sprite\":{{\"x\":0.0,\"y\":0.0,\"w\":1.0,\"h\":1.0{s}}}}}", .{mask_field});
    defer if (!literal_target) page.free(target_node);
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.ml-diffusion","version":"1.0.0","display_name":"BYO Diffusion","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"restyle","type":"diffusion","params":{{}},
        \\   "diffusion":{{{s}{s}"unet":"unet.onnx","decoder":"dec.onnx","sprite":"canvas","steps":2,"strength":0.5{s}}}}},
        \\  {s}],
        \\ "triggers":[]}}
    , .{ enc_field, cond_field, coherence_field, target_node });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{spec.dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    inline for (.{ .{ "enc.onnx", spec.enc }, .{ "unet.onnx", @as(?[]const u8, spec.unet) }, .{ "dec.onnx", @as(?[]const u8, spec.dec) }, .{ "cond.bin", spec.text_embedding } }) |pair| {
        if (pair[1]) |data| {
            const asset_path = try std.fmt.allocPrint(page, "{s}/assets/{s}", .{ spec.dir, pair[0] });
            defer page.free(asset_path);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = data });
        }
    }
}

const SegInject = struct { channel: usize, mask: []const f32 };

fn runDiffusionOnce(engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, seg: ?SegInject) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) {
        std.debug.print("conformance: FAIL diffusion lens activation\n", .{});
        return error.DiffusionActivationFailed;
    }
    if (seg) |inj| {
        // The set_segmentation_mask ABI is web-only; on host the mask is injected
        // straight into the channel the segmentation worker would fill.
        abi.injectMaskChannel(session, inj.channel, @ptrCast(inj.mask.ptr));
    }
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.DiffusionTrackFailed;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.DiffusionSubmitFailed;
    var polls: usize = 0;
    while (abi.styleTextureCount(session) == 0) {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return false;
    }
    return true;
}

/// Like runDiffusionOnce, but keeps feeding frames after the first restyle so a
/// coherence lens runs a second compute and exercises the flow-warp-blend
/// against its own history, then confirms it still holds a drawn texture.
fn runCoherenceOnce(engine: *abi.Engine, dir: []const u8, planes: Nv12Copy) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.DiffusionActivationFailed;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.DiffusionTrackFailed;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.DiffusionSubmitFailed;
    var polls: usize = 0;
    while (abi.styleTextureCount(session) == 0) {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return false;
    }
    var more: usize = 0;
    while (more < 4_000) : (more += 1) {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    return abi.styleTextureCount(session) > 0;
}

/// Proves the diffusion restyle loop: a lens ships a VAE encoder, unet, and
/// decoder, and the engine runs the img2img loop (encode, seed noise, a few
/// denoise steps, decode) off the frame thread, drawing through a sprite.
/// Synthetic same-size models stand in for real weights; the engine ships the loop.
fn proveMlInferDiffusion(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    // encoder 3->4: output channel m mirrors input channel m % 3.
    const enc_w = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 };
    // unet 4->4 identity: the noise estimate the schedule steps against.
    const unet_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    // decoder 4->3: keep the first three latent channels as rgb.
    const dec_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    const extra = [_][]const u8{ onnxValueInfo(a, "timestep", &.{1}), onnxValueInfo(a, "cond", &.{ 1, 4 }) };
    const enc = onnxConvModel(a, "x", 3, 4, side, &enc_w, &.{});
    const unet = onnxConvModel(a, "latent", 4, 4, side, &unet_w, &extra);
    const dec = onnxConvModel(a, "latent", 4, 3, side, &dec_w, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-diffusion/assets");
    try writeDiffusionLens(.{ .dir = "zig-out/ml-diffusion", .enc = enc, .unet = unet, .dec = dec });

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const drew_a = try runDiffusionOnce(engine, "zig-out/ml-diffusion", person, null);
    const drew_b = try runDiffusionOnce(engine, "zig-out/ml-diffusion", person, null);
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the diffusion restyle never reached the sprite\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a diffusion loop over a bundled encoder, unet, and decoder restyles the frame and draws it through a sprite\n", .{});
    return true;
}

/// Proves the text-to-image path: a diffusion lens ships only a unet and decoder
/// (no encoder) plus a text embedding, so the engine starts from seeded noise
/// rather than the camera frame and still draws a stable image through a sprite.
fn proveMlInferText2Img(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    const unet_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const dec_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    const extra = [_][]const u8{ onnxValueInfo(a, "timestep", &.{1}), onnxValueInfo(a, "cond", &.{ 1, 4 }) };
    const unet = onnxConvModel(a, "latent", 4, 4, side, &unet_w, &extra);
    const dec = onnxConvModel(a, "latent", 4, 3, side, &dec_w, &.{});
    // Four little-endian f32 conditioning values stand in for a text embedding.
    var cond_bytes: [16]u8 = undefined;
    inline for (.{ 0.25, 0.5, 0.75, 1.0 }, 0..) |v, i| std.mem.writeInt(u32, cond_bytes[i * 4 ..][0..4], @bitCast(@as(f32, v)), .little);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-text2img/assets");
    try writeDiffusionLens(.{ .dir = "zig-out/ml-text2img", .unet = unet, .dec = dec, .text_embedding = &cond_bytes });

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const drew_a = try runDiffusionOnce(engine, "zig-out/ml-text2img", person, null);
    const drew_b = try runDiffusionOnce(engine, "zig-out/ml-text2img", person, null);
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the text to image loop never reached the sprite\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a diffusion lens with no encoder generates from seeded noise and a text embedding, drawing the image through a sprite\n", .{});
    return true;
}

/// Proves the generative-background greenscreen: a text-to-image diffusion lens
/// feeds a sprite keyed to the person channel, so the generated image composites
/// as the background behind the subject the segmentation mask marks, keeping the
/// camera where the subject is and the generated image everywhere else.
fn proveMlInferGreenscreen(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    const unet_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const dec_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    const extra = [_][]const u8{ onnxValueInfo(a, "timestep", &.{1}), onnxValueInfo(a, "cond", &.{ 1, 4 }) };
    const unet = onnxConvModel(a, "latent", 4, 4, side, &unet_w, &extra);
    const dec = onnxConvModel(a, "latent", 4, 3, side, &dec_w, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-greenscreen/assets");
    try writeDiffusionLens(.{ .dir = "zig-out/ml-greenscreen", .unet = unet, .dec = dec, .sprite_mask = "person" });

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    // A half-and-half subject mask: the left half reads as the subject (kept from
    // the camera), the right half as background (filled by the generated image).
    const mask = try a.alloc(f32, abi.segmentation_mask_len);
    const mask_side = std.math.sqrt(abi.segmentation_mask_len);
    for (0..mask_side) |row| for (0..mask_side) |col| {
        mask[row * mask_side + col] = if (col < mask_side / 2) 1.0 else 0.0;
    };

    const drew_a = try runDiffusionOnce(engine, "zig-out/ml-greenscreen", person, .{ .channel = 0, .mask = mask });
    const drew_b = try runDiffusionOnce(engine, "zig-out/ml-greenscreen", person, .{ .channel = 0, .mask = mask });
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the generative greenscreen never reached the sprite\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a diffusion lens keyed to the person channel composites its generated image as the background behind the segmented subject\n", .{});
    return true;
}

/// Proves temporal coherence: an img2img diffusion lens with coherence on runs
/// the optical-flow warp and blend against its own previous frame across a run
/// of frames, and still draws the restyle through the sprite. The flow, warp,
/// and blend math is unit-tested in core/tracking/optical_flow.zig.
fn proveMlInferCoherence(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    const enc_w = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 };
    const unet_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const dec_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    const extra = [_][]const u8{ onnxValueInfo(a, "timestep", &.{1}), onnxValueInfo(a, "cond", &.{ 1, 4 }) };
    const enc = onnxConvModel(a, "x", 3, 4, side, &enc_w, &.{});
    const unet = onnxConvModel(a, "latent", 4, 4, side, &unet_w, &extra);
    const dec = onnxConvModel(a, "latent", 4, 3, side, &dec_w, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-coherence/assets");
    try writeDiffusionLens(.{ .dir = "zig-out/ml-coherence", .enc = enc, .unet = unet, .dec = dec, .coherence = 0.5 });

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    if (!try runCoherenceOnce(engine, "zig-out/ml-coherence", person)) {
        std.debug.print("conformance: FAIL the coherence restyle never held a drawn frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF an img2img diffusion lens with temporal coherence warps its previous frame by optical flow and blends it into the restyle, holding the sprite steady\n", .{});
    return true;
}

/// Proves the full-face restyle: an img2img diffusion lens feeds a sprite keyed
/// to the face_skin channel in `over` mode, so the generated restyle composites
/// only where the face matte is on and the camera holds everywhere else, the
/// masked-to-the-face path a real-time generative face filter rides.
fn proveMlInferFaceRestyle(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    const enc_w = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 };
    const unet_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const dec_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    const extra = [_][]const u8{ onnxValueInfo(a, "timestep", &.{1}), onnxValueInfo(a, "cond", &.{ 1, 4 }) };
    const enc = onnxConvModel(a, "x", 3, 4, side, &enc_w, &.{});
    const unet = onnxConvModel(a, "latent", 4, 4, side, &unet_w, &extra);
    const dec = onnxConvModel(a, "latent", 4, 3, side, &dec_w, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-facerestyle/assets");
    try writeDiffusionLens(.{ .dir = "zig-out/ml-facerestyle", .enc = enc, .unet = unet, .dec = dec, .sprite_mask = "face_skin", .sprite_mask_over = true });

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    // An oval face matte on the face_skin channel: the restyle lands inside it
    // and the camera holds outside, so the filter stays on the face.
    const mask = try a.alloc(f32, abi.segmentation_mask_len);
    const mask_side = std.math.sqrt(abi.segmentation_mask_len);
    const half: f32 = @floatFromInt(mask_side / 2);
    for (0..mask_side) |row| for (0..mask_side) |col| {
        const dx = (@as(f32, @floatFromInt(col)) - half) / half;
        const dy = (@as(f32, @floatFromInt(row)) - half) / half;
        mask[row * mask_side + col] = if (dx * dx + dy * dy < 0.36) 1.0 else 0.0;
    };

    const drew_a = try runDiffusionOnce(engine, "zig-out/ml-facerestyle", person, .{ .channel = 4, .mask = mask });
    const drew_b = try runDiffusionOnce(engine, "zig-out/ml-facerestyle", person, .{ .channel = 4, .mask = mask });
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the full-face restyle never reached the sprite\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF an img2img diffusion lens masked to the face_skin channel in over mode composites its restyle onto the face matte and holds the camera elsewhere\n", .{});
    return true;
}

/// Writes a masked-over sprite.2d lens whose solid sprite mixes onto the
/// face_skin channel by a static mask_strength, plus its one solid png asset.
fn writeMaskStrengthLens(dir: []const u8, png_bytes: []const u8, strength: f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.mask-strength","version":"1.0.0","display_name":"Mask Strength","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"tint","type":"sprite.2d","inputs":{{"frame":"camera"}},"params":{{}},
        \\   "sprite":{{"x":0.0,"y":0.0,"w":1.0,"h":1.0,"opacity":1.0,"mask":"face_skin","mask_mode":"over","mask_strength":{d:.3}}}}}],
        \\ "triggers":[]}}
    , .{strength});
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/tint.png", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = png_bytes });
}

/// Activates a mask-strength lens, injects the half face_skin matte, and
/// captures the composited frame; caller owns the returned RGBA.
fn captureMaskLens(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, mask: *const [abi.segmentation_mask_len]f32) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    // Land the sprite png, then hold the injected matte across the drawn frames.
    for (0..8) |_| {
        _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    for (0..5) |_| {
        abi.injectMaskChannel(session, 4, mask);
        _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var w: u32 = 0;
    var h: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Counts differing bytes over one clear region of the 400-wide capture: side 0
/// is the left fifth-to-two-fifths (well inside the masked half), side 1 the
/// right two columns (well outside). The middle band spans the mask's upsampled
/// soft edge and is skipped, so neither region straddles the transition.
fn halfDiff(a: []const u8, b: []const u8, side: usize) usize {
    var changed: usize = 0;
    const w: usize = 400;
    const h: usize = 300;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const x0: usize = if (side == 0) 0 else (w * 3) / 5;
        const x1: usize = if (side == 0) (w * 2) / 5 else w;
        var x: usize = x0;
        while (x < x1) : (x += 1) {
            const idx = (y * w + x) * 4;
            if (!std.mem.eql(u8, a[idx .. idx + 4], b[idx .. idx + 4])) changed += 1;
        }
    }
    return changed;
}

/// Proves the masked-composite strength knob: a masked-over sprite mixes onto
/// its region by mask_strength. At 0 the region holds the camera, at 1 it is
/// the full restyle, at 0.5 it differs from both; outside the mask nothing
/// changes with strength, so the knob scales only the masked region.
fn proveMaskStrength(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    // A solid blue full-frame sprite, distinct from any camera pixel.
    const blue = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    defer gpa.free(blue);
    var i: usize = 0;
    while (i < blue.len) : (i += 4) {
        blue[i + 0] = 0;
        blue[i + 1] = 0;
        blue[i + 2] = 255;
        blue[i + 3] = 255;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, blue, 400, 300);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/mask-strength-0/assets");
    try writeMaskStrengthLens("zig-out/mask-strength-0", png_bytes.items, 0.0);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/mask-strength-50/assets");
    try writeMaskStrengthLens("zig-out/mask-strength-50", png_bytes.items, 0.5);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/mask-strength-100/assets");
    try writeMaskStrengthLens("zig-out/mask-strength-100", png_bytes.items, 1.0);

    // Left half of the face_skin channel on, right half off.
    const mask = try gpa.alloc(f32, abi.segmentation_mask_len);
    defer gpa.free(mask);
    const mask_side = std.math.sqrt(abi.segmentation_mask_len);
    for (0..mask_side) |row| for (0..mask_side) |col| {
        mask[row * mask_side + col] = if (col < mask_side / 2) 1.0 else 0.0;
    };
    const mask_arr: *const [abi.segmentation_mask_len]f32 = @ptrCast(mask.ptr);

    const shot0 = try captureMaskLens(gpa, engine, "zig-out/mask-strength-0", planes, mask_arr);
    defer gpa.free(shot0);
    const shot50 = try captureMaskLens(gpa, engine, "zig-out/mask-strength-50", planes, mask_arr);
    defer gpa.free(shot50);
    const shot100 = try captureMaskLens(gpa, engine, "zig-out/mask-strength-100", planes, mask_arr);
    defer gpa.free(shot100);

    const masked_full = halfDiff(shot0, shot100, 0); // strength 1 vs 0, masked region
    const masked_half_lo = halfDiff(shot50, shot0, 0); // 0.5 vs 0
    const masked_half_hi = halfDiff(shot50, shot100, 0); // 0.5 vs 1
    const outside_lo = halfDiff(shot0, shot50, 1); // outside mask, 0 vs 0.5
    const outside_hi = halfDiff(shot0, shot100, 1); // outside mask, 0 vs 1

    if (masked_full == 0) {
        std.debug.print("conformance: FAIL mask_strength: the masked region did not change between strength 0 and 1\n", .{});
        return false;
    }
    if (masked_half_lo == 0 or masked_half_hi == 0) {
        std.debug.print("conformance: FAIL mask_strength: strength 0.5 matched an endpoint in the masked region\n", .{});
        return false;
    }
    if (outside_lo != 0 or outside_hi != 0) {
        std.debug.print("conformance: FAIL mask_strength: the region outside the mask changed with strength ({d}, {d})\n", .{ outside_lo, outside_hi });
        return false;
    }
    std.debug.print("conformance: PROOF a masked-over sprite mixes onto its region by mask_strength: the masked region moves from camera at 0 to the full restyle at 1 with 0.5 between ({d} pixels), while outside the mask nothing changes with strength\n", .{masked_full});
    return true;
}

/// Writes a grade.pass lens that inverts the frame, optionally scoped to the
/// face_skin channel (no asset).
fn writeGradeMaskLens(dir: []const u8, invert: f32, masked: bool) !void {
    const page = std.heap.page_allocator;
    const mask_field = if (masked) ",\"mask\":\"face_skin\"" else "";
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.grade-mask","version":"1.0.0","display_name":"Grade Mask","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"g","type":"grade.pass","inputs":{{"frame":"camera"}},"params":{{}},"grade":{{"invert":{d:.3}{s}}}}}],
        \\ "triggers":[]}}
    , .{ invert, mask_field });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Proves the masked grade: a grade.pass that names a channel grades only inside
/// it. An invert scoped to a half face_skin mask flips the masked region and
/// leaves the rest byte-identical, where the same invert with no mask flips the
/// whole frame including that outside region.
fn proveMaskedGrade(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/grade-plain");
    try writeGradeMaskLens("zig-out/grade-plain", 0.0, false);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/grade-masked");
    try writeGradeMaskLens("zig-out/grade-masked", 1.0, true);
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/grade-full");
    try writeGradeMaskLens("zig-out/grade-full", 1.0, false);

    // Left two fifths of the face_skin channel on (screen x < 160), well clear
    // of the outside sample region (x >= 240) so no soft edge reaches it.
    const mask = try gpa.alloc(f32, abi.segmentation_mask_len);
    defer gpa.free(mask);
    const mask_side = std.math.sqrt(abi.segmentation_mask_len);
    for (0..mask_side) |row| for (0..mask_side) |col| {
        mask[row * mask_side + col] = if (col < (mask_side * 2) / 5) 1.0 else 0.0;
    };
    const mask_arr: *const [abi.segmentation_mask_len]f32 = @ptrCast(mask.ptr);

    const plain = try captureMaskLens(gpa, engine, "zig-out/grade-plain", planes, mask_arr);
    defer gpa.free(plain);
    const masked = try captureMaskLens(gpa, engine, "zig-out/grade-masked", planes, mask_arr);
    defer gpa.free(masked);
    const full = try captureMaskLens(gpa, engine, "zig-out/grade-full", planes, mask_arr);
    defer gpa.free(full);

    const masked_inside = halfDiff(masked, plain, 0); // masked grade, inside the mask
    const masked_outside = halfDiff(masked, plain, 1); // masked grade, outside the mask
    const full_inside = halfDiff(full, plain, 0); // unmasked grade, inside region
    const full_outside = halfDiff(full, plain, 1); // unmasked grade, outside region
    // Inside the mask the grade lands in full, matching the unmasked grade; the
    // outside is strongly attenuated by the mask (a soft feathered edge, so a
    // small residual near the boundary is expected, not the full change).
    if (masked_inside < full_inside) {
        std.debug.print("conformance: FAIL masked grade did not fully grade inside the mask ({d} vs unmasked {d})\n", .{ masked_inside, full_inside });
        return false;
    }
    if (full_outside == 0) {
        std.debug.print("conformance: FAIL the unmasked grade left the outside region unchanged, so the mask proved nothing\n", .{});
        return false;
    }
    if (masked_outside * 10 >= full_outside) {
        std.debug.print("conformance: FAIL masked grade did not attenuate the outside region ({d} vs unmasked {d})\n", .{ masked_outside, full_outside });
        return false;
    }
    std.debug.print("conformance: PROOF a grade.pass naming a channel grades inside it and attenuates outside it: an invert scoped to a face_skin mask flips the masked region in full ({d} pixels, matching the unmasked grade) while the outside falls to under a tenth ({d} vs {d})\n", .{ masked_inside, masked_outside, full_outside });
    return true;
}

/// Proves text-to-material: a diffusion node targets a mesh.face node, so its
/// generated image binds as the face mesh's material texture rather than a
/// bundled png. The generated texture reaches the mesh's material slot; the mesh
/// then warps it over the tracked face like any authored face texture.
fn proveMlInferMaterial(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    const enc_w = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 };
    const unet_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const dec_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    const extra = [_][]const u8{ onnxValueInfo(a, "timestep", &.{1}), onnxValueInfo(a, "cond", &.{ 1, 4 }) };
    const enc = onnxConvModel(a, "x", 3, 4, side, &enc_w, &.{});
    const unet = onnxConvModel(a, "latent", 4, 4, side, &unet_w, &extra);
    const dec = onnxConvModel(a, "latent", 4, 3, side, &dec_w, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-material/assets");
    try writeDiffusionLens(.{ .dir = "zig-out/ml-material", .enc = enc, .unet = unet, .dec = dec, .target_mesh = true });

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const drew_a = try runDiffusionOnce(engine, "zig-out/ml-material", person, null);
    const drew_b = try runDiffusionOnce(engine, "zig-out/ml-material", person, null);
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the generated material never reached the face mesh\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a diffusion node targeting a mesh.face node binds its generated image as the face mesh's material texture\n", .{});
    return true;
}

/// Proves text-to-texture into the shader material graph: a diffusion node
/// targets a shader.pass whose material graph samples the reserved `generated`
/// texture, so the generated map is bound to that sampler and the material
/// draws it. The generated texture reaches the shader.pass target.
fn proveMlInferMaterialGraph(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    const enc_w = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 };
    const unet_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const dec_w = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    const extra = [_][]const u8{ onnxValueInfo(a, "timestep", &.{1}), onnxValueInfo(a, "cond", &.{ 1, 4 }) };
    const enc = onnxConvModel(a, "x", 3, 4, side, &enc_w, &.{});
    const unet = onnxConvModel(a, "latent", 4, 4, side, &unet_w, &extra);
    const dec = onnxConvModel(a, "latent", 4, 3, side, &dec_w, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-materialgraph/assets");
    try writeDiffusionLens(.{ .dir = "zig-out/ml-materialgraph", .enc = enc, .unet = unet, .dec = dec, .target_material = true });

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const drew_a = try runDiffusionOnce(engine, "zig-out/ml-materialgraph", person, null);
    const drew_b = try runDiffusionOnce(engine, "zig-out/ml-materialgraph", person, null);
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the generated texture never reached the material graph\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a diffusion node targeting a shader.pass binds its generated image to the material graph's generated sampler\n", .{});
    return true;
}

fn writeSplatLens(dir: []const u8, model: []const u8, mesh: bool, selfie: bool, colored: bool) !void {
    const page = std.heap.page_allocator;
    const draw = if (mesh) "mesh" else "points";
    const source = if (selfie) "selfie" else "camera";
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.ml-splat","version":"1.0.0","display_name":"BYO Splat","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"cloud","type":"splat.cloud","inputs":{{"frame":"camera"}},"params":{{}},
        \\   "splat":{{"model":"splat.onnx","source":"{s}","draw":"{s}","point":8.0,"r":0.9,"g":0.8,"b":0.3,"colored":{}}}}}],
        \\ "triggers":[]}}
    , .{ source, draw, colored });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/splat.onnx", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

fn runSplatOnce(engine: *abi.Engine, dir: []const u8, planes: Nv12Copy) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.SplatActivationFailed;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SplatTrackFailed;
    var polls: usize = 0;
    while (abi.splatCloudReadyCount(session) == 0) {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return false;
    }
    // Keep rendering a few frames so the cloud's billboard draw runs against the
    // published points, exercising the whole splat path.
    var more: usize = 0;
    while (more < 200) : (more += 1) {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    return true;
}

/// Proves text-to-3D: a splat.cloud node runs a bundled model that lifts the
/// camera frame into a 3D point set, and the engine draws it as camera-facing
/// billboards. A synthetic 3->3 conv stands in for the depth-lift net, turning
/// the sampled frame into one point per cell.
fn proveMlInferSplat(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    // 3->3 identity conv: each cell's rgb becomes an xyz point.
    const w = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const model = onnxConvModel(a, "x", 3, 3, side, &w, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-splat/assets");
    try writeSplatLens("zig-out/ml-splat", model, false, false, false);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const drew_a = try runSplatOnce(engine, "zig-out/ml-splat", person);
    const drew_b = try runSplatOnce(engine, "zig-out/ml-splat", person);
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the splat cloud never produced its points\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a splat.cloud node lifts the camera frame to a 3D point set with a bundled model and draws it as a billboard cloud\n", .{});
    return true;
}

/// Proves the text-to-3D mesh draw: a splat.cloud in mesh mode reads the model's
/// output as a square grid of points and draws it as a connected 3D surface, the
/// mesh sibling of the billboard cloud. The synthetic model emits a full grid.
fn proveMlInferSplatMesh(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    const w = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const model = onnxConvModel(a, "x", 3, 3, side, &w, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-splatmesh/assets");
    try writeSplatLens("zig-out/ml-splatmesh", model, true, false, false);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const drew_a = try runSplatOnce(engine, "zig-out/ml-splatmesh", person);
    const drew_b = try runSplatOnce(engine, "zig-out/ml-splatmesh", person);
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the splat mesh never produced its surface\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a splat.cloud in mesh mode reads the model's points as a grid and draws them as a connected 3D surface\n", .{});
    return true;
}

/// Proves per-splat color end to end: a colored splat.cloud runs a model that
/// emits rgb after xyz per point (six channels), so the loader reads it at
/// stride six and each splat carries its own color into the billboard cloud it
/// draws. The color the writer packs per point is asserted by a unit test.
fn proveMlInferSplatColored(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    // 6 outputs from 3 inputs: rows 0-2 carry rgb to xyz, rows 3-5 carry rgb to
    // the point color, so each splat's color is its own source pixel.
    const w6 = [_]f32{
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    };
    const colored_model = onnxConvModel(a, "x", 3, 6, side, &w6, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-splatcolor/assets");
    try writeSplatLens("zig-out/ml-splatcolor", colored_model, false, false, true);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const drew_a = try runSplatOnce(engine, "zig-out/ml-splatcolor", person);
    const drew_b = try runSplatOnce(engine, "zig-out/ml-splatcolor", person);
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the colored splat never produced its cloud\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a colored splat.cloud reads a six-channel model at stride six and draws each point carrying its own color\n", .{});
    return true;
}

/// Runs a selfie-source splat: the model is fed one still through the avatar op
/// rather than the per-frame camera, so the cloud is generated once and held.
fn runSelfieSplatOnce(engine: *abi.Engine, dir: []const u8, planes: Nv12Copy) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.SplatActivationFailed;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    // The selfie feeds only through the avatar op; the per-frame camera does not
    // drive it, so track_frame is never called here.
    if (abi.goss_session_submit_avatar_source(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.AvatarSubmitFailed;
    var polls: usize = 0;
    while (abi.splatCloudReadyCount(session) == 0) {
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return false;
    }
    var more: usize = 0;
    while (more < 200) : (more += 1) {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    return true;
}

/// The web selfie path: feeds one RGBA still through the avatar RGBA op rather
/// than the NV12 op, so the same cloud is generated from a canvas byte buffer.
fn runSelfieSplatRgbaOnce(engine: *abi.Engine, dir: []const u8, rgba: []const u8, w: u32, h: u32) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.SplatActivationFailed;
    if (abi.goss_session_submit_avatar_source_rgba(session, rgba.ptr, w, h) != .ok) return error.AvatarSubmitFailed;
    var polls: usize = 0;
    while (abi.splatCloudReadyCount(session) == 0) {
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return false;
    }
    var more: usize = 0;
    while (more < 200) : (more += 1) {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    return true;
}

fn writeSplatGaussianLens(dir: []const u8, model: []const u8, placement: []const u8, portal: [4]f32) !void {
    const page = std.heap.page_allocator;
    const manifest_json = try std.fmt.allocPrint(page,
        \\{{"glf":"1.0","id":"goss.reference.splat-gaussian","version":"1.0.0","display_name":"Gaussian Splat","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{{"id":"cloud","type":"splat.cloud","inputs":{{"frame":"camera"}},"params":{{}},
        \\   "splat":{{"model":"splat.onnx","source":"camera","draw":"gaussian","point":8.0,"placement":"{s}","portal":[{d:.3},{d:.3},{d:.3},{d:.3}]}}}}],
        \\ "triggers":[]}}
    , .{ placement, portal[0], portal[1], portal[2], portal[3] });
    defer page.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/splat.onnx", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = model });
}

/// Activates a gaussian splat lens, waits for the cloud to publish, and captures
/// the composite over a black frame so the splats read as their own coverage. A
/// non-null mask is injected as the subject channel for a background placement.
fn runSplatGaussianShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, mask: ?[]const f32, out_w: *u32, out_h: *u32) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.SplatActivationFailed;
    if (mask) |m| abi.injectMaskChannel(session, 0, @ptrCast(m.ptr));
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    var polls: usize = 0;
    while (abi.splatCloudReadyCount(session) == 0) {
        _ = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        std.Thread.yield() catch {};
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return error.SplatNeverReady;
    }
    for (0..8) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    // The capture lands at the renderer's own dimensions, not the fed frame's,
    // so a generous buffer holds it and the caller reads the real w*h back.
    const shot = try gpa.alloc(u8, @as(usize, 1024) * 1024 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, out_w, out_h) != .ok) return error.CaptureFailed;
    return shot;
}

const SplatExtents = struct { horiz: usize, vert: usize };

/// The on-screen width and height of a splat centred on the frame: the run of
/// lit pixels along the centre row and the centre column, so an oriented ellipse
/// reads as wider-than-tall or taller-than-wide.
fn splatExtents(shot: []const u8, w: u32, h: u32) SplatExtents {
    const cx: usize = w / 2;
    const cy: usize = h / 2;
    var minx: i64 = -1;
    var maxx: i64 = -1;
    for (0..w) |x| {
        const o = (cy * w + x) * 4;
        if (@as(u32, shot[o]) + shot[o + 1] + shot[o + 2] > 60) {
            if (minx < 0) minx = @intCast(x);
            maxx = @intCast(x);
        }
    }
    var miny: i64 = -1;
    var maxy: i64 = -1;
    for (0..h) |y| {
        const o = (y * w + cx) * 4;
        if (@as(u32, shot[o]) + shot[o + 1] + shot[o + 2] > 60) {
            if (miny < 0) miny = @intCast(y);
            maxy = @intCast(y);
        }
    }
    const he: usize = if (maxx >= 0) @intCast(maxx - minx + 1) else 0;
    const ve: usize = if (maxy >= 0) @intCast(maxy - miny + 1) else 0;
    return .{ .horiz = he, .vert = ve };
}

fn centerRgb(shot: []const u8, w: u32, h: u32) [3]u8 {
    const o = (@as(usize, h / 2) * w + w / 2) * 4;
    return .{ shot[o], shot[o + 1], shot[o + 2] };
}

/// Proves the anisotropic sorted gaussian splat render: fixed const-model splats
/// draw as oriented ellipses (a covariance elongated along x reads wider than
/// tall, along y taller than wide) and composite in depth order (a near opaque
/// splat draws over a far one, swapping when the depths swap), bit-stable.
fn proveSplatGaussian(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // One white splat, covariance elongated along x, then along y.
    const model_h = onnxConstModel(a, &.{ 0, 0, 0, 0.15, 0.045, 0.045, 0, 0, 0, 1, 1.0, 1, 1, 1 });
    const model_v = onnxConstModel(a, &.{ 0, 0, 0, 0.045, 0.15, 0.045, 0, 0, 0, 1, 1.0, 1, 1, 1 });
    // Two overlapping splats: a far blue and a near red, then the colors swapped
    // between the depths so the front-most one is the other color.
    const model_rb = onnxConstModel(a, &.{ 0, 0, -0.5, 0.12, 0.12, 0.12, 0, 0, 0, 1, 1.0, 0, 0, 1, 0, 0, 0.5, 0.12, 0.12, 0.12, 0, 0, 0, 1, 1.0, 1, 0, 0 });
    const model_br = onnxConstModel(a, &.{ 0, 0, -0.5, 0.12, 0.12, 0.12, 0, 0, 0, 1, 1.0, 1, 0, 0, 0, 0, 0.5, 0.12, 0.12, 0.12, 0, 0, 0, 1, 1.0, 0, 0, 1 });

    inline for (.{ "zig-out/splat-h", "zig-out/splat-v", "zig-out/splat-rb", "zig-out/splat-br" }) |d| {
        try std.Io.Dir.cwd().createDirPath(harness_io, d ++ "/assets");
    }
    try writeSplatGaussianLens("zig-out/splat-h", model_h, "overlay", .{ 0, 0, 0, 0 });
    try writeSplatGaussianLens("zig-out/splat-v", model_v, "overlay", .{ 0, 0, 0, 0 });
    try writeSplatGaussianLens("zig-out/splat-rb", model_rb, "overlay", .{ 0, 0, 0, 0 });
    try writeSplatGaussianLens("zig-out/splat-br", model_br, "overlay", .{ 0, 0, 0, 0 });

    const dim: u32 = 320;
    const black_rgba = try gpa.alloc(u8, @as(usize, dim) * dim * 4);
    defer gpa.free(black_rgba);
    @memset(black_rgba, 0);
    const black = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = black_rgba }, .width = dim, .height = dim });
    defer black.deinit(gpa);

    var w: u32 = 0;
    var h: u32 = 0;
    const shot_h = try runSplatGaussianShot(gpa, engine, "zig-out/splat-h", black, null, &w, &h);
    defer gpa.free(shot_h);
    const shot_h2 = try runSplatGaussianShot(gpa, engine, "zig-out/splat-h", black, null, &w, &h);
    defer gpa.free(shot_h2);
    const shot_v = try runSplatGaussianShot(gpa, engine, "zig-out/splat-v", black, null, &w, &h);
    defer gpa.free(shot_v);
    const shot_rb = try runSplatGaussianShot(gpa, engine, "zig-out/splat-rb", black, null, &w, &h);
    defer gpa.free(shot_rb);
    const shot_br = try runSplatGaussianShot(gpa, engine, "zig-out/splat-br", black, null, &w, &h);
    defer gpa.free(shot_br);

    const n = @as(usize, w) * h * 4;
    if (!std.mem.eql(u8, shot_h[0..n], shot_h2[0..n])) {
        std.debug.print("conformance: FAIL gaussian splat render is not bit-stable across runs\n", .{});
        return false;
    }
    const eh = splatExtents(shot_h, w, h);
    const ev = splatExtents(shot_v, w, h);
    if (eh.horiz == 0 or ev.vert == 0) {
        std.debug.print("conformance: FAIL gaussian splat drew nothing (h {d}x{d}, v {d}x{d})\n", .{ eh.horiz, eh.vert, ev.horiz, ev.vert });
        return false;
    }
    if (!(eh.horiz > eh.vert + 8)) {
        std.debug.print("conformance: FAIL the x-elongated splat did not read wider than tall ({d} vs {d})\n", .{ eh.horiz, eh.vert });
        return false;
    }
    if (!(ev.vert > ev.horiz + 8)) {
        std.debug.print("conformance: FAIL the y-elongated splat did not read taller than wide ({d} vs {d})\n", .{ ev.vert, ev.horiz });
        return false;
    }
    const crb = centerRgb(shot_rb, w, h);
    const cbr = centerRgb(shot_br, w, h);
    if (!(@as(i32, crb[0]) > @as(i32, crb[2]) + 20)) {
        std.debug.print("conformance: FAIL the near red splat did not draw over the far blue one (r {d}, b {d})\n", .{ crb[0], crb[2] });
        return false;
    }
    if (!(@as(i32, cbr[2]) > @as(i32, cbr[0]) + 20)) {
        std.debug.print("conformance: FAIL swapping the depths did not swap which splat is on top (r {d}, b {d})\n", .{ cbr[0], cbr[2] });
        return false;
    }
    std.debug.print("conformance: PROOF a gaussian splat.cloud draws anisotropic sorted splats: the x-elongated covariance reads {d}x{d} and the y-elongated {d}x{d}, and a near red splat composites over a far blue one (r {d} > b {d}), swapping with the depth, bit-stable\n", .{ eh.horiz, eh.vert, ev.horiz, ev.vert, crb[0], crb[2] });
    return true;
}

fn sum3(rgb: [3]u8) u32 {
    return @as(u32, rgb[0]) + rgb[1] + rgb[2];
}

/// A frame pixel's rgb at a normalized (u, v), for asserting a splat's presence
/// or absence in a region.
fn pixelAt(shot: []const u8, w: u32, h: u32, u: f32, v: f32) [3]u8 {
    const x: usize = @intFromFloat(std.math.clamp(u, 0, 0.999) * @as(f32, @floatFromInt(w)));
    const y: usize = @intFromFloat(std.math.clamp(v, 0, 0.999) * @as(f32, @floatFromInt(h)));
    const o = (y * w + x) * 4;
    return .{ shot[o], shot[o + 1], shot[o + 2] };
}

/// Proves the splat portal placement: a large gaussian cloud that fills the view
/// in overlay is confined to a rect in portal mode, so a point outside the rect
/// falls back to the frame while the rect centre still shows the cloud.
fn proveSplatPortal(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const model = onnxConstModel(a, &.{ 0, 0, 0, 0.6, 0.6, 0.6, 0, 0, 0, 1, 1.0, 1, 1, 1 });
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/splat-overlay/assets");
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/splat-portal/assets");
    const rect = [4]f32{ 0.35, 0.35, 0.3, 0.3 };
    try writeSplatGaussianLens("zig-out/splat-overlay", model, "overlay", .{ 0, 0, 0, 0 });
    try writeSplatGaussianLens("zig-out/splat-portal", model, "portal", rect);

    const dim: u32 = 320;
    const black_rgba = try gpa.alloc(u8, @as(usize, dim) * dim * 4);
    defer gpa.free(black_rgba);
    @memset(black_rgba, 0);
    const black = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = black_rgba }, .width = dim, .height = dim });
    defer black.deinit(gpa);

    var w: u32 = 0;
    var h: u32 = 0;
    const overlay = try runSplatGaussianShot(gpa, engine, "zig-out/splat-overlay", black, null, &w, &h);
    defer gpa.free(overlay);
    const portal = try runSplatGaussianShot(gpa, engine, "zig-out/splat-portal", black, null, &w, &h);
    defer gpa.free(portal);

    const outside_overlay = sum3(pixelAt(overlay, w, h, 0.08, 0.5));
    const outside_portal = sum3(pixelAt(portal, w, h, 0.08, 0.5));
    const inside_portal = sum3(pixelAt(portal, w, h, 0.5, 0.5));
    if (!(outside_overlay > 120)) {
        std.debug.print("conformance: FAIL the overlay cloud did not reach the point the portal must clip ({d})\n", .{outside_overlay});
        return false;
    }
    if (!(outside_portal < 40)) {
        std.debug.print("conformance: FAIL the portal did not clip the cloud outside its rect (lum {d})\n", .{outside_portal});
        return false;
    }
    if (!(inside_portal > 120)) {
        std.debug.print("conformance: FAIL the portal rect did not show the cloud (lum {d})\n", .{inside_portal});
        return false;
    }
    std.debug.print("conformance: PROOF a portal splat cloud is confined to its rect: a point outside reads {d} in overlay but {d} in portal, while the rect centre stays lit at {d}\n", .{ outside_overlay, outside_portal, inside_portal });
    return true;
}

/// Proves the splat background placement: a gaussian cloud drawn behind the
/// segmented subject, so the subject region shows the frame while the background
/// region shows the cloud, unlike overlay where the cloud covers the subject too.
fn proveSplatBackground(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const model = onnxConstModel(a, &.{ 0, 0, 0, 0.8, 0.8, 0.8, 0, 0, 0, 1, 1.0, 0, 1, 0 });
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/splat-bg-overlay/assets");
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/splat-bg/assets");
    try writeSplatGaussianLens("zig-out/splat-bg-overlay", model, "overlay", .{ 0, 0, 0, 0 });
    try writeSplatGaussianLens("zig-out/splat-bg", model, "background", .{ 0, 0, 0, 0 });

    const dim: u32 = 320;
    const black_rgba = try gpa.alloc(u8, @as(usize, dim) * dim * 4);
    defer gpa.free(black_rgba);
    @memset(black_rgba, 0);
    const black = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = black_rgba }, .width = dim, .height = dim });
    defer black.deinit(gpa);

    // A vertical band on the left is the subject (mask 1), the right is background
    // (mask 0); a vertical split so a mask y-flip cannot confound the assertion.
    const mask = try gpa.alloc(f32, 256 * 256);
    defer gpa.free(mask);
    for (0..256) |y| for (0..256) |x| {
        mask[y * 256 + x] = if (x < 102) 1.0 else 0.0;
    };

    var w: u32 = 0;
    var h: u32 = 0;
    const overlay = try runSplatGaussianShot(gpa, engine, "zig-out/splat-bg-overlay", black, mask, &w, &h);
    defer gpa.free(overlay);
    const bg = try runSplatGaussianShot(gpa, engine, "zig-out/splat-bg", black, mask, &w, &h);
    defer gpa.free(bg);

    const subject_overlay = pixelAt(overlay, w, h, 0.28, 0.5)[1];
    const subject_bg = sum3(pixelAt(bg, w, h, 0.28, 0.5));
    const back_bg = pixelAt(bg, w, h, 0.72, 0.5)[1];
    if (!(subject_overlay > 100)) {
        std.debug.print("conformance: FAIL the overlay cloud did not cover the subject region ({d})\n", .{subject_overlay});
        return false;
    }
    if (!(subject_bg < 60)) {
        std.debug.print("conformance: FAIL the background placement did not keep the subject in front (lum {d})\n", .{subject_bg});
        return false;
    }
    if (!(back_bg > 100)) {
        std.debug.print("conformance: FAIL the background region did not show the splat cloud (g {d})\n", .{back_bg});
        return false;
    }
    std.debug.print("conformance: PROOF a background splat cloud sits behind the subject: the subject region reads green {d} in overlay but {d} behind the subject in background, while the background region shows the cloud (g {d})\n", .{ subject_overlay, subject_bg, back_bg });
    return true;
}

/// A world_from_camera pose rotated `theta` about the Y axis (column-major), so a
/// guided-capture scan sees a distinct yaw each step.
fn makeYaw(theta: f32) [16]f32 {
    const cs = @cos(theta);
    const sn = @sin(theta);
    var m = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    m[0] = cs;
    m[2] = -sn;
    m[8] = sn;
    m[10] = cs;
    return m;
}

/// Proves guided capture and the deterministic reconstruction: capturing a ring of
/// eight yaw viewpoints covers the scan, each view's depth back-projects through
/// the submitted pose and projection into a spread of world-space gaussians landing
/// where the geometry puts them, and the same poses and depth rebuild the same set.
fn proveCaptureReconstruct(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const dw: u32 = 16;
    const dh: u32 = 16;
    var depth: [dw * dh]f32 = undefined;
    @memset(&depth, 0.5);
    const identity_proj = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

    var guidance: abi.CaptureGuidance = undefined;
    const scan = struct {
        fn run(sess: *abi.Session, d: []const f32, w: u32, h: u32, proj: [16]f32, out: *abi.CaptureGuidance) !void {
            for (0..8) |i| {
                const theta = @as(f32, @floatFromInt(i)) * (std.math.tau / 8.0);
                var ws: abi.WorldState = .{ .tracking_state = 1, .world_from_camera = makeYaw(theta), .projection = proj, .timestamp_us = @intCast(i * 1000) };
                if (abi.goss_session_submit_world(sess, &ws, null, 0, null, 0, null) != .ok) return error.SubmitWorldFailed;
                if (abi.goss_session_submit_depth(sess, d.ptr, w, h, 1.0, 3.0) != .ok) return error.SubmitDepthFailed;
                if (abi.goss_session_capture_view(sess, out) != .ok) return error.CaptureViewFailed;
            }
        }
    };
    try scan.run(session, &depth, dw, dh, identity_proj, &guidance);

    if (guidance.complete != 1 or guidance.covered != 8) {
        std.debug.print("conformance: FAIL guided capture did not complete coverage ({d}/{d})\n", .{ guidance.covered, guidance.total });
        return false;
    }
    const expect: usize = 8 * 16 * 16;
    if (abi.reconstructedSplatCount(session) != expect) {
        std.debug.print("conformance: FAIL reconstruction produced {d} gaussians, expected {d}\n", .{ abi.reconstructedSplatCount(session), expect });
        return false;
    }
    // View 0 is the identity pose; its centre grid sample back-projects a metric
    // depth of 2 (near 1 + 0.5 * span 2) to world z -2.
    const centre = abi.reconstructedSplat(session, 8 * 16 + 8);
    if (!(@abs(centre[2] + 2.0) < 0.01)) {
        std.debug.print("conformance: FAIL the back-projected depth landed at z {d:.3}, not -2\n", .{centre[2]});
        return false;
    }
    // The grid spreads across the frame: the left and right samples of view 0 land
    // well apart in world x, so it is a real unprojection, not one point.
    const left = abi.reconstructedSplat(session, 8 * 16 + 0);
    const right = abi.reconstructedSplat(session, 8 * 16 + 15);
    if (!(@abs(left[0] - right[0]) > 1.0)) {
        std.debug.print("conformance: FAIL the reconstruction did not spread across the frame (dx {d:.3})\n", .{@abs(left[0] - right[0])});
        return false;
    }

    // Deterministic: reset and rescan the same poses and depth rebuild the same set.
    if (abi.goss_session_reset_capture(session) != .ok) return error.ResetFailed;
    if (abi.reconstructedSplatCount(session) != 0) {
        std.debug.print("conformance: FAIL reset did not clear the reconstruction\n", .{});
        return false;
    }
    try scan.run(session, &depth, dw, dh, identity_proj, &guidance);
    const centre2 = abi.reconstructedSplat(session, 8 * 16 + 8);
    if (abi.reconstructedSplatCount(session) != expect or !std.mem.eql(u8, std.mem.asBytes(&centre), std.mem.asBytes(&centre2))) {
        std.debug.print("conformance: FAIL the reconstruction is not deterministic across a rescan\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a guided capture covers eight yaw viewpoints and reconstructs {d} gaussians by back-projecting each view's depth through its pose (centre at z {d:.2}, frame spread {d:.2}), deterministically\n", .{ expect, centre[2], @abs(left[0] - right[0]) });
    return true;
}

fn writeReconLens(dir: []const u8) !void {
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.splat-recon","version":"1.0.0","display_name":"Reconstruction","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"cloud","type":"splat.cloud","inputs":{"frame":"camera"},"params":{},
        \\   "splat":{"source":"reconstruction","draw":"gaussian","point":8.0}}],
        \\ "triggers":[]}
    ;
    const manifest_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/manifest.json", .{dir});
    defer std.heap.page_allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
}

/// Activates the reconstruction lens; when capture is set, runs a short guided
/// scan (world pose, depth, capture_view) to fill the reconstruction, then renders
/// the composite over a black frame so the reconstructed cloud reads as its cover.
fn runReconShot(gpa: std.mem.Allocator, engine: *abi.Engine, dir: []const u8, planes: Nv12Copy, capture: bool, out_w: *u32, out_h: *u32) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ReconActivationFailed;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    if (capture) {
        const dw: u32 = 16;
        const dh: u32 = 16;
        var depth: [dw * dh]f32 = undefined;
        @memset(&depth, 0.5);
        const proj = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        for (0..3) |i| {
            var ws: abi.WorldState = .{ .tracking_state = 1, .world_from_camera = makeYaw(0), .projection = proj, .timestamp_us = @intCast(i * 1000) };
            _ = abi.goss_session_submit_world(session, &ws, null, 0, null, 0, null);
            _ = abi.goss_session_submit_depth(session, &depth, dw, dh, 1.0, 3.0);
            _ = abi.goss_session_capture_view(session, null);
        }
    }
    for (0..8) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const shot = try gpa.alloc(u8, @as(usize, 1024) * 1024 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, out_w, out_h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Proves the reconstruction render wire: a splat.cloud with source:reconstruction
/// draws the session's guided-capture gaussians live. With no scan it holds the
/// frame; once a scan fills the reconstruction, the cloud draws over it, bit-stable.
fn proveReconstructionRender(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/splat-recon");
    try writeReconLens("zig-out/splat-recon");

    const dim: u32 = 320;
    const black_rgba = try gpa.alloc(u8, @as(usize, dim) * dim * 4);
    defer gpa.free(black_rgba);
    @memset(black_rgba, 0);
    const black = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = black_rgba }, .width = dim, .height = dim });
    defer black.deinit(gpa);

    var w: u32 = 0;
    var h: u32 = 0;
    const empty = try runReconShot(gpa, engine, "zig-out/splat-recon", black, false, &w, &h);
    defer gpa.free(empty);
    const recon = try runReconShot(gpa, engine, "zig-out/splat-recon", black, true, &w, &h);
    defer gpa.free(recon);
    const recon2 = try runReconShot(gpa, engine, "zig-out/splat-recon", black, true, &w, &h);
    defer gpa.free(recon2);

    const n = @as(usize, w) * h * 4;
    // With no scan the reconstruction is empty, so the cloud holds the black frame.
    var empty_lit: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 4) {
        if (@as(u32, empty[i]) + empty[i + 1] + empty[i + 2] > 60) empty_lit += 1;
    }
    if (empty_lit != 0) {
        std.debug.print("conformance: FAIL the reconstruction drew before any scan ({d} lit)\n", .{empty_lit});
        return false;
    }
    // After a scan the reconstructed cloud draws, so the black frame gains splats.
    const drew = countDiff(empty[0..n], recon[0..n]);
    if (drew < 100) {
        std.debug.print("conformance: FAIL the scanned reconstruction did not draw ({d} px)\n", .{drew});
        return false;
    }
    if (!std.mem.eql(u8, recon[0..n], recon2[0..n])) {
        std.debug.print("conformance: FAIL the reconstruction render is not bit-stable across runs\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a splat.cloud with source:reconstruction draws the guided-capture gaussians live: no scan holds the frame, a scan draws the cloud over it ({d} px), bit-stable\n", .{drew});
    return true;
}

/// Proves the photoreal selfie avatar: a splat.cloud with source:selfie runs its
/// model once over a still submitted through goss_session_submit_avatar_source
/// Proves the photoreal selfie avatar: a splat.cloud with source:selfie runs its
/// model once over a still submitted through goss_session_submit_avatar_source
/// (not the live camera) and draws the generated cloud, so an avatar is built
/// from one photo and held.
fn proveMlInferSelfieAvatar(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const side: i64 = 8;
    const w = [_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const model = onnxConvModel(a, "x", 3, 3, side, &w, &.{});

    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/ml-selfie/assets");
    try writeSplatLens("zig-out/ml-selfie", model, false, true, false);

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);

    const drew_a = try runSelfieSplatOnce(engine, "zig-out/ml-selfie", person);
    const drew_b = try runSelfieSplatOnce(engine, "zig-out/ml-selfie", person);
    if (!drew_a or !drew_b) {
        std.debug.print("conformance: FAIL the selfie avatar never generated its cloud\n", .{});
        return false;
    }
    // The web selfie path: the same still submitted as an RGBA buffer through the
    // RGBA sibling op generates the cloud the same way.
    const rgba = corpus.frame.pixels.rgba8;
    const drew_rgba = try runSelfieSplatRgbaOnce(engine, "zig-out/ml-selfie", rgba, corpus.frame.width, corpus.frame.height);
    if (!drew_rgba) {
        std.debug.print("conformance: FAIL the selfie avatar never generated its cloud from an RGBA still\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a selfie-source splat.cloud generates its avatar from one submitted still through the avatar op (NV12 and RGBA) and draws it, off the per-frame camera\n", .{});
    return true;
}

/// Proves the prompt-to-lens compiler: the goss_compile_prompt ABI op turns a
/// text prompt into a GLF manifest on device, the two-call length probe matches
/// the filled buffer, and the emitted manifest activates as a real lens that
/// renders, so a lens is authored from words with no assets and no round trip.
fn proveCompilePrompt(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const text = "cinematic glow foggy sketch";
    // Length probe: a null buffer reports how many bytes the manifest needs.
    var needed: usize = 0;
    if (abi.goss_compile_prompt(engine, text.ptr, text.len, null, 0, &needed) != .ok or needed == 0) {
        std.debug.print("conformance: FAIL the prompt compiler reported no length\n", .{});
        return false;
    }
    const buf = try gpa.alloc(u8, needed);
    defer gpa.free(buf);
    var written: usize = 0;
    if (abi.goss_compile_prompt(engine, text.ptr, text.len, buf.ptr, buf.len, &written) != .ok or written != needed) {
        std.debug.print("conformance: FAIL the prompt compiler did not fill the buffer\n", .{});
        return false;
    }
    // The compiled manifest must activate as a lens and render its post-effect
    // chain over a frame, off the same corpus the other proofs use.
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const person = try rgbaToNv12(gpa, corpus.frame);
    defer person.deinit(gpa);
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens(session, buf.ptr, written) != .ok) {
        std.debug.print("conformance: FAIL the compiled prompt lens did not activate\n", .{});
        return false;
    }
    const desc: abi.FrameDesc = .{ .width = person.width, .height = person.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (person.width + 1) / 2;
    _ = abi.goss_session_submit_frame_copy(session, &desc, person.y.ptr, person.width, person.uv.ptr, half_w * 2);
    _ = abi.goss_engine_render_frame(engine, session);
    c.glfwPollEvents();
    std.debug.print("conformance: PROOF the prompt compiler emits a GLF manifest on device that activates as a lens and renders\n", .{});
    return true;
}

/// Proves a script node: the sandboxed script reads a signal and writes a
/// lens parameter each tick, deterministically, and the host reads it back
/// through the ABI. The scripting section's end-to-end proof.
fn proveScript(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/script-param", ".lens-packages/script-param".len) != .ok) {
        std.debug.print("conformance: FAIL script lens activation\n", .{});
        return false;
    }

    const name = "intensity";
    var present = std.mem.zeroes(abi.LensSignals);
    present.has_face = true;
    const absent = std.mem.zeroes(abi.LensSignals);

    var v_present: f32 = -1;
    var v_absent: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &present);
    if (abi.goss_session_parameter_value(session, name.ptr, name.len, &v_present) != .ok) {
        std.debug.print("conformance: FAIL reading the script-driven parameter\n", .{});
        return false;
    }
    _ = abi.goss_session_tick_lens(session, 16000, &absent);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_absent);

    if (@abs(v_present - 0.8) > 1e-6 or @abs(v_absent - 0.2) > 1e-6) {
        std.debug.print("conformance: FAIL script drove intensity to {d}/{d}, wanted 0.8/0.2\n", .{ v_present, v_absent });
        return false;
    }

    // Deterministic: the same signal produces the same value, bit for bit.
    var v_again: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &present);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_again);
    if (v_again != v_present) {
        std.debug.print("conformance: FAIL script is not deterministic ({d} vs {d})\n", .{ v_again, v_present });
        return false;
    }

    std.debug.print("conformance: PROOF a script node drives a lens parameter from a signal deterministically (0.8 present, 0.2 absent)\n", .{});
    return true;
}

/// Proves a script node can ship its source as a bundled asset instead of
/// inlining it: the manifest names "file":"drive.js", activation loads and
/// compiles assets/drive.js, and it drives the parameter the same way the
/// inline form does - bit-stable across ticks.
fn proveScriptFile(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const dir = "zig-out/script-file";
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.script-file","version":"1.0.0","display_name":"Script File","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"intensity","type":"float","default":0.0,"min":0.0,"max":1.0}],
        \\ "nodes":[{"id":"drive","type":"script","params":{},"file":"drive.js"}],
        \\ "triggers":[]}
    ;
    const script_src = "function update(lens) { lens.params.intensity = lens.signals.face_present > 0.5 ? 0.8 : 0.2; }";
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/script-file/assets");
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/drive.js", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = script_src });

    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) {
        std.debug.print("conformance: FAIL script-file lens activation\n", .{});
        return false;
    }

    const name = "intensity";
    var present = std.mem.zeroes(abi.LensSignals);
    present.has_face = true;
    const absent = std.mem.zeroes(abi.LensSignals);

    var v_present: f32 = -1;
    var v_absent: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &present);
    if (abi.goss_session_parameter_value(session, name.ptr, name.len, &v_present) != .ok) {
        std.debug.print("conformance: FAIL reading the file-script parameter\n", .{});
        return false;
    }
    _ = abi.goss_session_tick_lens(session, 16000, &absent);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_absent);

    if (@abs(v_present - 0.8) > 1e-6 or @abs(v_absent - 0.2) > 1e-6) {
        std.debug.print("conformance: FAIL bundled script drove intensity to {d}/{d}, wanted 0.8/0.2\n", .{ v_present, v_absent });
        return false;
    }

    var v_again: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &present);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_again);
    if (v_again != v_present) {
        std.debug.print("conformance: FAIL bundled script is not deterministic ({d} vs {d})\n", .{ v_again, v_present });
        return false;
    }

    std.debug.print("conformance: PROOF a script node loads its source from a bundled assets/*.js and drives a parameter deterministically (0.8 present, 0.2 absent)\n", .{});
    return true;
}

/// Proves the math-transform and vector logic.graph nodes: a graph chaining
/// hypot(3,4)=5, mod(5,3)=2 and smoothstep(0,4,2)=0.5 drives a parameter to
/// exactly 0.5, bit-stable across ticks, with no code and no host dependence.
fn proveLogicGraphMath(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const dir = "zig-out/logic-math";
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.logic-math","version":"1.0.0","display_name":"Logic Math","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"intensity","type":"float","default":0.0,"min":0.0,"max":1.0}],
        \\ "nodes":[{"id":"lg","type":"logic.graph","params":{},"graph":{
        \\   "nodes":[{"id":"m","op":"hypot","a":3.0,"b":4.0},
        \\            {"id":"r","op":"mod","a":"m","b":3.0},
        \\            {"id":"q","op":"smoothstep","a":0.0,"b":4.0,"c":"r"}],
        \\   "output":"q","output_param":"intensity"}}],
        \\ "triggers":[]}
    ;
    try std.Io.Dir.cwd().createDirPath(harness_io, dir);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });

    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) {
        std.debug.print("conformance: FAIL logic-math lens activation\n", .{});
        return false;
    }

    const name = "intensity";
    const signals = std.mem.zeroes(abi.LensSignals);
    var v: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &signals);
    if (abi.goss_session_parameter_value(session, name.ptr, name.len, &v) != .ok) {
        std.debug.print("conformance: FAIL reading the logic-graph parameter\n", .{});
        return false;
    }
    if (@abs(v - 0.5) > 1e-6) {
        std.debug.print("conformance: FAIL logic graph drove intensity to {d}, wanted 0.5\n", .{v});
        return false;
    }
    var v_again: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &signals);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_again);
    if (v_again != v) {
        std.debug.print("conformance: FAIL logic graph is not deterministic ({d} vs {d})\n", .{ v_again, v });
        return false;
    }

    std.debug.print("conformance: PROOF a logic.graph chains hypot, mod and smoothstep to drive a parameter to exactly 0.5, deterministically\n", .{});
    return true;
}

/// Proves a script carries persistent state across ticks with no engine
/// feature beyond its context outliving the frame: a ring buffer of the last
/// four signal samples and an entity-component table both evolve tick to tick
/// and drive parameters, identically across two fresh runs of the sequence.
fn proveScriptState(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const dir = "zig-out/script-state";
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.script-state","version":"1.0.0","display_name":"Script State","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"window","type":"float","default":0.0,"min":0.0,"max":1.0},
        \\               {"name":"alive","type":"float","default":0.0,"min":0.0,"max":1.0},
        \\               {"name":"drift","type":"float","default":0.0,"min":0.0,"max":1.0}],
        \\ "nodes":[{"id":"drive","type":"script","params":{},"file":"state.js"}],
        \\ "triggers":[]}
    ;
    const script_src =
        \\var buf = [];
        \\var ents = null;
        \\function update(lens) {
        \\  if (ents === null) { ents = []; for (var i = 0; i < 3; i++) ents.push({ ttl: 3, vy: 0.1 * (i + 1) }); }
        \\  buf.push(lens.signals.face_present);
        \\  if (buf.length > 4) buf.shift();
        \\  var sum = 0; for (var i = 0; i < buf.length; i++) sum += buf[i];
        \\  lens.params.window = sum / 4;
        \\  var alive = 0, drift = 0;
        \\  for (var i = 0; i < ents.length; i++) { var e = ents[i]; if (e.ttl > 0) { e.ttl -= 1; alive += 1; drift += e.vy; } }
        \\  lens.params.alive = alive / 8;
        \\  lens.params.drift = drift;
        \\}
    ;
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/script-state/assets");
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/state.js", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = script_src });

    var present = std.mem.zeroes(abi.LensSignals);
    present.has_face = true;

    // Two fresh runs of four face-present ticks. The window rolls up
    // 0.25 -> 0.5 -> 0.75 -> 1.0 (ring buffer), and the entities' ttl runs out
    // by the fourth tick (alive 0.375 -> 0, drift 0.6 -> 0); both must match.
    var runs: [2][3]f32 = undefined;
    var first: [3]f32 = undefined;
    for (0..2) |run| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) {
            std.debug.print("conformance: FAIL script-state lens activation\n", .{});
            return false;
        }
        for (0..4) |tick| {
            _ = abi.goss_session_tick_lens(session, 16000, &present);
            if (tick == 0) {
                _ = abi.goss_session_parameter_value(session, "window", "window".len, &first[0]);
                _ = abi.goss_session_parameter_value(session, "alive", "alive".len, &first[1]);
                _ = abi.goss_session_parameter_value(session, "drift", "drift".len, &first[2]);
            }
        }
        _ = abi.goss_session_parameter_value(session, "window", "window".len, &runs[run][0]);
        _ = abi.goss_session_parameter_value(session, "alive", "alive".len, &runs[run][1]);
        _ = abi.goss_session_parameter_value(session, "drift", "drift".len, &runs[run][2]);
    }

    if (@abs(first[0] - 0.25) > 1e-6 or @abs(first[1] - 0.375) > 1e-6 or @abs(first[2] - 0.6) > 1e-4) {
        std.debug.print("conformance: FAIL first tick state window {d} alive {d} drift {d}\n", .{ first[0], first[1], first[2] });
        return false;
    }
    if (@abs(runs[0][0] - 1.0) > 1e-6 or @abs(runs[0][1]) > 1e-6 or @abs(runs[0][2]) > 1e-6) {
        std.debug.print("conformance: FAIL fourth tick state window {d} alive {d} drift {d}\n", .{ runs[0][0], runs[0][1], runs[0][2] });
        return false;
    }
    if (runs[0][0] != runs[1][0] or runs[0][1] != runs[1][1] or runs[0][2] != runs[1][2]) {
        std.debug.print("conformance: FAIL script state is not deterministic across runs\n", .{});
        return false;
    }

    std.debug.print("conformance: PROOF a script carries a ring buffer and an entity-component table across ticks, driving parameters deterministically\n", .{});
    return true;
}

/// Proves a character-locomotion controller from shipped primitives: a script
/// ramps a speed and smoothsteps it into a normalized crossfade between two
/// clip weights (the values a model.gltf's clip_weights blend walk and run by),
/// all-walk to all-run, normalized every tick, identical across two runs.
fn proveLocomotion(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const dir = "zig-out/locomotion";
    const page = std.heap.page_allocator;
    const manifest_json =
        \\{"glf":"1.0","id":"goss.reference.locomotion","version":"1.0.0","display_name":"Locomotion","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[{"name":"walk_w","type":"float","default":1.0,"min":0.0,"max":1.0},
        \\               {"name":"run_w","type":"float","default":0.0,"min":0.0,"max":1.0}],
        \\ "nodes":[{"id":"drive","type":"script","params":{},"file":"locomotion.js"}],
        \\ "triggers":[]}
    ;
    const script_src =
        \\var speed = 0.0;
        \\function update(lens) {
        \\  speed = speed + 0.05;
        \\  var x = (speed - 0.3) / 0.4;
        \\  if (x < 0) x = 0; if (x > 1) x = 1;
        \\  var t = x * x * (3 - 2 * x);
        \\  lens.params.run_w = t;
        \\  lens.params.walk_w = 1 - t;
        \\}
    ;
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/locomotion/assets");
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/locomotion.js", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = script_src });

    const signals = std.mem.zeroes(abi.LensSignals);
    // Two runs of fourteen ticks. Sampled at tick 1 (all walk), tick 10
    // (an even blend), and tick 14 (all run); the pair of weights sums to 1
    // at every sample and both runs land on the same values.
    var samples: [2][3][2]f32 = undefined;
    for (0..2) |run| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) {
            std.debug.print("conformance: FAIL locomotion lens activation\n", .{});
            return false;
        }
        for (1..15) |tick| {
            _ = abi.goss_session_tick_lens(session, 16000, &signals);
            const slot: ?usize = switch (tick) {
                1 => 0,
                10 => 1,
                14 => 2,
                else => null,
            };
            if (slot) |si| {
                _ = abi.goss_session_parameter_value(session, "walk_w", "walk_w".len, &samples[run][si][0]);
                _ = abi.goss_session_parameter_value(session, "run_w", "run_w".len, &samples[run][si][1]);
            }
        }
    }

    const s = samples[0];
    for (s) |pair| {
        if (@abs(pair[0] + pair[1] - 1.0) > 1e-5) {
            std.debug.print("conformance: FAIL locomotion weights not normalized ({d} + {d})\n", .{ pair[0], pair[1] });
            return false;
        }
    }
    if (@abs(s[0][0] - 1.0) > 1e-6 or @abs(s[1][0] - 0.5) > 1e-5 or @abs(s[2][0]) > 1e-6) {
        std.debug.print("conformance: FAIL locomotion crossfade walk {d}/{d}/{d}, wanted 1/0.5/0\n", .{ s[0][0], s[1][0], s[2][0] });
        return false;
    }
    for (0..3) |i| {
        if (samples[0][i][0] != samples[1][i][0] or samples[0][i][1] != samples[1][i][1]) {
            std.debug.print("conformance: FAIL locomotion is not deterministic across runs\n", .{});
            return false;
        }
    }

    std.debug.print("conformance: PROOF a locomotion controller smoothsteps an evolving speed into a normalized walk-to-run clip-weight crossfade, deterministically\n", .{});
    return true;
}

/// Activates a two-grade chain (a stop up then a stop down) on a fresh session,
/// hdr or plain, feeds the constant frame, and returns the center pixel's green.
/// The hdr lens allocates half-float composite targets and keeps its grade
/// passes unclamped; the plain lens is byte-for-byte the same lens without hdr.
fn captureGradeUpDown(gpa: std.mem.Allocator, engine: *abi.Engine, hdr: bool, planes: Nv12Copy) !u8 {
    const dir = if (hdr) "zig-out/hdr-grade" else "zig-out/plain-grade";
    const page = std.heap.page_allocator;
    const manifest_json = if (hdr)
        \\{"glf":"1.0","id":"goss.reference.hdr-grade","version":"1.0.0","display_name":"HDR Grade","engine_compat":">=0.5","capabilities":[],"hdr":true,
        \\ "parameters":[],
        \\ "nodes":[{"id":"up","type":"grade.pass","inputs":{"frame":"camera"},"params":{},"grade":{"exposure":1.0}},
        \\          {"id":"down","type":"grade.pass","inputs":{"frame":"up"},"params":{},"grade":{"exposure":-1.0}}],
        \\ "triggers":[]}
    else
        \\{"glf":"1.0","id":"goss.reference.plain-grade","version":"1.0.0","display_name":"Plain Grade","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"up","type":"grade.pass","inputs":{"frame":"camera"},"params":{},"grade":{"exposure":1.0}},
        \\          {"id":"down","type":"grade.pass","inputs":{"frame":"up"},"params":{},"grade":{"exposure":-1.0}}],
        \\ "triggers":[]}
    ;
    try std.Io.Dir.cwd().createDirPath(harness_io, dir);
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });

    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const shot = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(shot);
    var w: u32 = 0;
    var h: u32 = 0;
    try renderCapture(engine, session, &desc, planes, half_w, shot, &w, &h);
    const cx = w / 2;
    const cy = h / 2;
    const idx = (cy * w + cx) * 4;
    return shot[idx + 1];
}

/// Proves the HDR compositing chain: an "hdr":true lens grades a bright gray up
/// a stop (past 1.0) then back down; the half-float intermediate keeps the
/// bright value so the result recovers, while the identical non-HDR lens clips
/// at 1.0 in its 8-bit intermediate and comes back darker. Deterministic.
fn proveHdrComposite(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const gray = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(gray);
    var p: usize = 0;
    while (p + 4 <= gray.len) : (p += 4) {
        gray[p + 0] = 179;
        gray[p + 1] = 179;
        gray[p + 2] = 179;
        gray[p + 3] = 255;
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = gray }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    const hdr_green = try captureGradeUpDown(gpa, engine, true, planes);
    const plain_green = try captureGradeUpDown(gpa, engine, false, planes);
    const hdr_again = try captureGradeUpDown(gpa, engine, true, planes);

    if (hdr_green != hdr_again) {
        std.debug.print("conformance: FAIL HDR composite is not deterministic ({d} vs {d})\n", .{ hdr_green, hdr_again });
        return false;
    }
    if (@as(i32, hdr_green) - @as(i32, plain_green) < 12) {
        std.debug.print("conformance: FAIL HDR chain did not preserve the highlight (hdr {d} vs plain {d})\n", .{ hdr_green, plain_green });
        return false;
    }

    std.debug.print("conformance: PROOF an hdr lens grades a highlight past 1.0 and back through a half-float intermediate, recovering it ({d}) where the 8-bit chain clips it ({d})\n", .{ hdr_green, plain_green });
    return true;
}

/// Activates a model.gltf sphere over a black frame in one of three variants -
/// flat (no light), or lit from the front or the back - and captures the
/// composited RGBA. The same sphere covers the same pixels in every variant, so
/// only the shading differs. Caller owns the returned buffer.
fn captureLitModel(gpa: std.mem.Allocator, engine: *abi.Engine, variant: []const u8, planes: Nv12Copy, ball_glb: []const u8) ![]u8 {
    const dir = "zig-out/light-model";
    const page = std.heap.page_allocator;
    const manifest_json = if (std.mem.eql(u8, variant, "front"))
        \\{"glf":"1.0","id":"goss.reference.light-model","version":"1.0.0","display_name":"Light Model","engine_compat":">=0.5","capabilities":[],
        \\ "light":{"direction":[0.0,0.0,-1.0],"color":[1.0,1.0,1.0],"intensity":1.0,"ambient":0.1},
        \\ "parameters":[],
        \\ "nodes":[{"id":"ball","type":"model.gltf","inputs":{"frame":"camera"},"params":{}}],
        \\ "triggers":[]}
    else if (std.mem.eql(u8, variant, "back"))
        \\{"glf":"1.0","id":"goss.reference.light-model","version":"1.0.0","display_name":"Light Model","engine_compat":">=0.5","capabilities":[],
        \\ "light":{"direction":[0.0,0.0,1.0],"color":[1.0,1.0,1.0],"intensity":1.0,"ambient":0.1},
        \\ "parameters":[],
        \\ "nodes":[{"id":"ball","type":"model.gltf","inputs":{"frame":"camera"},"params":{}}],
        \\ "triggers":[]}
    else
        \\{"glf":"1.0","id":"goss.reference.light-model","version":"1.0.0","display_name":"Light Model","engine_compat":">=0.5","capabilities":[],
        \\ "parameters":[],
        \\ "nodes":[{"id":"ball","type":"model.gltf","inputs":{"frame":"camera"},"params":{}}],
        \\ "triggers":[]}
    ;
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/light-model/assets");
    const manifest_path = try std.fmt.allocPrint(page, "{s}/manifest.json", .{dir});
    defer page.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(page, "{s}/assets/ball.glb", .{dir});
    defer page.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = ball_glb });

    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return error.ActivationFailed;
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };

    // The glb decodes off-thread; render until the mesh lands, then settle.
    var polls: usize = 0;
    while (session.model_meshes.count() == 0) {
        _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 200_000) return error.ModelNeverLanded;
    }
    const shot = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(shot);
    var w: u32 = 0;
    var h: u32 = 0;
    try renderCapture(engine, session, &desc, planes, half_w, shot, &w, &h);
    return shot;
}

/// Proves opt-in directional lighting on a model.gltf: a sphere lit from the
/// front shades differently than the same sphere lit from the back (the light
/// direction genuinely drives the shading, not just a flat dim), and both
/// differ from the unlit sphere. Deterministic across runs.
fn proveDirectionalLight(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const ball_glb = std.Io.Dir.cwd().readFileAlloc(harness_io, "lenses/reference/box-block/assets/ball.glb", gpa, .limited(4 << 20)) catch {
        std.debug.print("conformance: FAIL could not read the reference sphere glb\n", .{});
        return false;
    };
    defer gpa.free(ball_glb);

    // A black frame, so the sphere is the only thing drawn and the background
    // contributes nothing to the comparison.
    const black = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(black);
    @memset(black, 0);
    for (0..black.len / 4) |i| black[i * 4 + 3] = 255;
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = black }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    const front = try captureLitModel(gpa, engine, "front", planes, ball_glb);
    defer gpa.free(front);
    const back = try captureLitModel(gpa, engine, "back", planes, ball_glb);
    defer gpa.free(back);
    const flat = try captureLitModel(gpa, engine, "flat", planes, ball_glb);
    defer gpa.free(flat);
    const front_again = try captureLitModel(gpa, engine, "front", planes, ball_glb);
    defer gpa.free(front_again);

    if (!std.mem.eql(u8, front, front_again)) {
        std.debug.print("conformance: FAIL directional light is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, front, flat) or std.mem.eql(u8, back, flat)) {
        std.debug.print("conformance: FAIL a lit sphere renders identical to the unlit sphere\n", .{});
        return false;
    }

    // Over the pixels the flat sphere covers, count how many shade differently
    // between the front and back light: a real directional light lights the two
    // hemispheres oppositely, so many covered pixels must diverge.
    var diverged: u64 = 0;
    var covered: u64 = 0;
    var front_sum: u64 = 0;
    var back_sum: u64 = 0;
    var p: usize = 0;
    while (p + 4 <= flat.len) : (p += 4) {
        if (flat[p + 1] > 16) {
            covered += 1;
            front_sum += front[p + 1];
            back_sum += back[p + 1];
            const d = @as(i32, front[p + 1]) - @as(i32, back[p + 1]);
            if (@abs(d) > 16) diverged += 1;
        }
    }
    if (covered < 200) {
        std.debug.print("conformance: FAIL the model covered too few pixels ({d}) to judge lighting\n", .{covered});
        return false;
    }
    if (diverged * 4 < covered) {
        std.debug.print("conformance: FAIL front and back light barely differ ({d}/{d} px diverged)\n", .{ diverged, covered });
        return false;
    }

    std.debug.print("conformance: PROOF a directional light shades a model.gltf by its direction: {d} of {d} covered pixels diverge front-vs-back (front avg {d}, back avg {d}), deterministically\n", .{ diverged, covered, front_sum / covered, back_sum / covered });
    return true;
}

/// Proves lens audio: a play_sound trigger starts a voice that the mixer
/// pulls out as PCM, silent before the trigger, non-silent after, and
/// bit-identical across two runs of the same sequence.
fn proveAudio(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const block: u32 = 512;

    var captured: [2][block]i16 = undefined;
    for (0..2) |run| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/sound-beat", ".lens-packages/sound-beat".len) != .ok) {
            std.debug.print("conformance: FAIL sound lens activation\n", .{});
            return false;
        }

        // Before any trigger the mixer has no voice, so the pull is silent.
        var pre: [block]i16 = undefined;
        _ = abi.goss_session_pull_audio(session, &pre, block);
        var pre_energy: u64 = 0;
        for (pre) |s| pre_energy += @abs(@as(i32, s));
        if (pre_energy != 0) {
            std.debug.print("conformance: FAIL audio before the trigger is not silent\n", .{});
            return false;
        }

        // Face present fires the play_sound trigger; the next pull carries it.
        var present = std.mem.zeroes(abi.LensSignals);
        present.has_face = true;
        _ = abi.goss_session_tick_lens(session, 16000, &present);
        _ = abi.goss_session_pull_audio(session, &captured[run], block);
    }
    _ = gpa;

    var energy: u64 = 0;
    for (captured[0]) |s| energy += @abs(@as(i32, s));
    if (energy == 0) {
        std.debug.print("conformance: FAIL the sound did not play after the trigger\n", .{});
        return false;
    }
    if (!std.mem.eql(i16, &captured[0], &captured[1])) {
        std.debug.print("conformance: FAIL lens audio is not deterministic across runs\n", .{});
        return false;
    }

    std.debug.print("conformance: PROOF a play_sound trigger mixes a voice the SDK pulls, silent before and bit-stable after\n", .{});
    return true;
}

/// Proves the camera-controls contract through the public ABI: out-of-range
/// intent is normalized to its valid envelope and read back exactly, with no
/// hardware and no host dependence.
fn proveCameraControls(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    var in: abi.CameraControls = .{
        .flash_mode = 99,
        .zoom_factor = 99,
        .max_zoom_factor = 4,
        .exposure_bias_ev = 40,
        .focus_point_x = 5.0,
        .mirror_save_policy = 1,
    };
    if (abi.goss_session_set_camera_controls(session, &in) != .ok) {
        std.debug.print("conformance: FAIL set_camera_controls\n", .{});
        return false;
    }
    var out: abi.CameraControls = undefined;
    if (abi.goss_session_camera_controls(session, &out) != .ok) {
        std.debug.print("conformance: FAIL camera_controls read-back\n", .{});
        return false;
    }
    if (out.flash_mode != 0 or out.zoom_factor != 4.0 or out.exposure_bias_ev != 8.0 or
        out.focus_point_x != 1.0 or out.mirror_save_policy != 0)
    {
        std.debug.print("conformance: FAIL camera controls not normalized (zoom {d}, bias {d}, focus_x {d})\n", .{ out.zoom_factor, out.exposure_bias_ev, out.focus_point_x });
        return false;
    }
    std.debug.print("conformance: PROOF camera controls normalize out-of-range intent to their valid envelope and read back exactly\n", .{});
    return true;
}

/// Proves the host-fired event trigger through the public ABI: a lens with an
/// event('celebrate') trigger leaves its parameter at default until the exact
/// event is fired, ignores a non-matching event, fires the action on the next
/// tick, and does so bit-identically across runs.
fn proveEventTrigger(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const manifest =
        \\{"glf":"1.0","id":"goss.reference.event-burst","version":"1.0.0","display_name":"Event Burst","engine_compat":">=0.5","capabilities":[],"parameters":[{"name":"intensity","type":"float","default":0.0,"min":0.0,"max":1.0}],"nodes":[{"id":"grade","type":"grade.pass","inputs":{"frame":"camera"},"params":{}}],"triggers":[{"when":"event('celebrate')","action":{"kind":"param_set","target":"intensity","to":1.0}}]}
    ;
    const pname = "intensity";
    var results: [2]f32 = undefined;
    for (0..2) |run| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        if (abi.goss_session_activate_lens(session, manifest.ptr, manifest.len) != .ok) {
            std.debug.print("conformance: FAIL event lens activation\n", .{});
            return false;
        }
        var sig = std.mem.zeroes(abi.LensSignals);
        var value: f32 = -1;

        // No event: the trigger never fires, the parameter stays at default.
        _ = abi.goss_session_tick_lens(session, 16000, &sig);
        _ = abi.goss_session_parameter_value(session, pname, pname.len, &value);
        if (value != 0.0) {
            std.debug.print("conformance: FAIL event trigger fired with no event ({d})\n", .{value});
            return false;
        }
        // A non-matching event is ignored.
        _ = abi.goss_session_fire_event(session, "other", "other".len);
        _ = abi.goss_session_tick_lens(session, 16000, &sig);
        _ = abi.goss_session_parameter_value(session, pname, pname.len, &value);
        if (value != 0.0) {
            std.debug.print("conformance: FAIL a non-matching event fired the trigger ({d})\n", .{value});
            return false;
        }
        // The matching event fires the action on the next tick.
        _ = abi.goss_session_fire_event(session, "celebrate", "celebrate".len);
        _ = abi.goss_session_tick_lens(session, 16000, &sig);
        _ = abi.goss_session_parameter_value(session, pname, pname.len, &value);
        results[run] = value;
    }
    if (results[0] != 1.0) {
        std.debug.print("conformance: FAIL the matching event did not fire the action ({d})\n", .{results[0]});
        return false;
    }
    if (results[0] != results[1]) {
        std.debug.print("conformance: FAIL event trigger is not deterministic across runs\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a host-fired event fires a lens trigger for exactly one tick, ignores non-matching names, and is bit-stable\n", .{});
    return true;
}

/// Renders the session over a fixed frame and captures the composite, so a proof
/// can see a draw node's visibility change take effect.
fn renderTriggerShot(gpa: std.mem.Allocator, engine: *abi.Engine, session: *abi.Session, planes: Nv12Copy, out_w: *u32, out_h: *u32) ![]u8 {
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const half_w = (planes.width + 1) / 2;
    for (0..5) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const shot = try gpa.alloc(u8, @as(usize, 1024) * 1024 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, out_w, out_h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Proves the show/hide/swap_subgraph trigger actions, which parsed and validated
/// but were no-ops. A hide action skips a draw node's pass (the frame passes
/// through), show restores it, and swap_subgraph switches between two mutually
/// exclusive grade variants; each rendered result is asserted and bit-stable.
fn proveShowHideSwap(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const dim: u32 = 320;
    const red = try gpa.alloc(u8, @as(usize, dim) * dim * 4);
    defer gpa.free(red);
    var i: usize = 0;
    while (i < red.len) : (i += 4) {
        red[i] = 220;
        red[i + 1] = 20;
        red[i + 2] = 20;
        red[i + 3] = 255;
    }
    const planes = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = red }, .width = dim, .height = dim });
    defer planes.deinit(gpa);

    const sh_manifest =
        \\{"glf":"1.0","id":"goss.reference.showhide","version":"1.0.0","display_name":"ShowHide","engine_compat":">=0.5","capabilities":[],"parameters":[],
        \\ "nodes":[{"id":"g","type":"grade.pass","inputs":{"frame":"camera"},"params":{},"grade":{"invert":1.0}}],
        \\ "triggers":[{"when":"event('hide')","action":{"kind":"hide","target":"g"}},{"when":"event('show')","action":{"kind":"show","target":"g"}}]}
    ;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens(session, sh_manifest.ptr, sh_manifest.len) != .ok) return error.ShowHideActivation;
    var sig = std.mem.zeroes(abi.LensSignals);
    var w: u32 = 0;
    var h: u32 = 0;

    const shown = try renderTriggerShot(gpa, engine, session, planes, &w, &h);
    defer gpa.free(shown);
    _ = abi.goss_session_fire_event(session, "hide", "hide".len);
    _ = abi.goss_session_tick_lens(session, 16000, &sig);
    const hidden = try renderTriggerShot(gpa, engine, session, planes, &w, &h);
    defer gpa.free(hidden);
    _ = abi.goss_session_fire_event(session, "show", "show".len);
    _ = abi.goss_session_tick_lens(session, 16000, &sig);
    const shown2 = try renderTriggerShot(gpa, engine, session, planes, &w, &h);
    defer gpa.free(shown2);

    const n = @as(usize, w) * h * 4;
    // The graded (inverted) frame differs from the raw frame the hidden node lets
    // through, and showing it again restores the exact graded frame, bit-stable.
    if (countDiff(shown[0..n], hidden[0..n]) == 0) {
        std.debug.print("conformance: FAIL hide did not skip the grade pass (frame unchanged)\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, shown[0..n], shown2[0..n])) {
        std.debug.print("conformance: FAIL show did not restore the grade pass identically\n", .{});
        return false;
    }

    const sw_manifest =
        \\{"glf":"1.0","id":"goss.reference.swapsg","version":"1.0.0","display_name":"Swap","engine_compat":">=0.5","capabilities":[],"parameters":[],
        \\ "nodes":[{"id":"a","type":"grade.pass","inputs":{"frame":"camera"},"params":{},"grade":{"invert":1.0}},{"id":"b","type":"grade.pass","inputs":{"frame":"camera"},"params":{},"grade":{"grayscale":1.0}}],
        \\ "triggers":[{"when":"event('swapa')","action":{"kind":"swap_subgraph","target":"a"}},{"when":"event('swapb')","action":{"kind":"swap_subgraph","target":"b"}}]}
    ;
    const sess2 = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(sess2);
    defer settle(engine);
    if (abi.goss_session_activate_lens(sess2, sw_manifest.ptr, sw_manifest.len) != .ok) return error.SwapActivation;
    _ = abi.goss_session_fire_event(sess2, "swapb", "swapb".len);
    _ = abi.goss_session_tick_lens(sess2, 16000, &sig);
    const only_b = try renderTriggerShot(gpa, engine, sess2, planes, &w, &h);
    defer gpa.free(only_b);
    _ = abi.goss_session_fire_event(sess2, "swapa", "swapa".len);
    _ = abi.goss_session_tick_lens(sess2, 16000, &sig);
    const only_a = try renderTriggerShot(gpa, engine, sess2, planes, &w, &h);
    defer gpa.free(only_a);

    // Swapping to a (invert) then to b (grayscale) shows mutually exclusive
    // variants, so the two rendered frames differ.
    if (countDiff(only_a[0..n], only_b[0..n]) == 0) {
        std.debug.print("conformance: FAIL swap_subgraph did not switch between the variants\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF show/hide/swap_subgraph drive draw-node visibility: hide skips a pass (frame diff {d}), show restores it bit-identically, and swap_subgraph switches exclusive variants (diff {d})\n", .{ countDiff(shown[0..n], hidden[0..n]), countDiff(only_a[0..n], only_b[0..n]) });
    return true;
}

/// Proves a trigger volume through the public ABI: a lens with a device.in_volume
/// trigger and a manifest volume leaves its parameter at default while the
/// submitted world pose sits outside the region and fires the action once the
/// device is inside it - the pose never crosses the ABI, only the membership.
fn proveVolumeTrigger(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const manifest =
        \\{"glf":"1.0","id":"goss.reference.volume-trigger","version":"1.0.0","display_name":"Volume Trigger","engine_compat":">=0.5","capabilities":[],"parameters":[{"name":"intensity","type":"float","default":0.0,"min":0.0,"max":1.0}],"nodes":[{"id":"grade","type":"grade.pass","inputs":{"frame":"camera"},"params":{}}],"triggers":[{"when":"device.in_volume","action":{"kind":"param_set","target":"intensity","to":1.0}}],"volume":{"center":[0.0,0.0,0.0],"radius":0.6}}
    ;
    const pname = "intensity";

    // A world pose whose translation is well outside the radius-0.6 sphere.
    var outside_pose = identity_pose;
    outside_pose[12] = 2.0;

    const cases = [_]struct { pose: [16]f32, want: f32 }{
        .{ .pose = outside_pose, .want = 0.0 },
        .{ .pose = identity_pose, .want = 1.0 }, // translation at the origin, inside
    };
    for (cases) |case| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        if (abi.goss_session_activate_lens(session, manifest.ptr, manifest.len) != .ok) {
            std.debug.print("conformance: FAIL volume-trigger lens activation\n", .{});
            return false;
        }
        var state: abi.WorldState = .{ .tracking_state = 2, .world_from_camera = case.pose, .projection = identity_pose, .timestamp_us = 1000 };
        if (abi.goss_session_submit_world(session, &state, null, 0, null, 0, null) != .ok) return error.SubmitFailed;
        var sig = std.mem.zeroes(abi.LensSignals);
        _ = abi.goss_session_tick_lens(session, 16000, &sig);
        var value: f32 = -1;
        _ = abi.goss_session_parameter_value(session, pname, pname.len, &value);
        if (value != case.want) {
            std.debug.print("conformance: FAIL volume trigger: wanted {d}, got {d}\n", .{ case.want, value });
            return false;
        }
    }
    std.debug.print("conformance: PROOF a trigger volume fires device.in_volume only while the world pose is inside the region\n", .{});
    return true;
}

/// Proves multi-source composition through the public ABI: a side-by-side
/// layout puts the camera (a red frame) in the left half and a named source (a
/// green frame) in the right half of the captured output, deterministically.
fn proveLayoutComposite(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const sw: u32 = 64;
    const sh: u32 = 64;
    const cam = try gpa.alloc(u8, sw * sh * 4);
    defer gpa.free(cam);
    const src = try gpa.alloc(u8, sw * sh * 4);
    defer gpa.free(src);
    for (0..sw * sh) |p| {
        cam[p * 4 + 0] = 255; cam[p * 4 + 1] = 0; cam[p * 4 + 2] = 0; cam[p * 4 + 3] = 255; // red
        src[p * 4 + 0] = 0; src[p * 4 + 1] = 255; src[p * 4 + 2] = 0; src[p * 4 + 3] = 255; // green
    }
    const base_desc: abi.FrameDesc = .{ .width = sw, .height = sh, .pixel_format = 4, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 33_333 };

    var shots: [2][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);
    for (0..2) |_| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        if (abi.goss_session_define_source(session, "b", 1) != .ok or
            abi.goss_session_submit_source_frame_rgba_copy(session, "b", 1, &base_desc, src.ptr, sw * 4) != .ok or
            abi.goss_session_set_layout(session, 1) != .ok)
        {
            std.debug.print("conformance: FAIL composition setup\n", .{});
            return false;
        }
        for (0..3) |i| {
            var d = base_desc;
            d.timestamp_us = @intCast((i + 1) * 33_333);
            if (abi.goss_session_submit_frame_rgba_copy(session, &d, cam.ptr, sw * 4) != .ok) return error.SubmitFailed;
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var cw: u32 = 0;
        var ch: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &cw, &ch) != .ok) {
            gpa.free(shot);
            std.debug.print("conformance: FAIL composition capture\n", .{});
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    const w: usize = 400;
    const h: usize = 300;
    const s0 = shots[0];
    const left = (h / 2 * w + w / 4) * 4; // camera half
    const right = (h / 2 * w + w * 3 / 4) * 4; // source half
    if (!(s0[left + 0] > 200 and s0[left + 1] < 60)) {
        std.debug.print("conformance: FAIL left half is not the camera (red)\n", .{});
        return false;
    }
    if (!(s0[right + 1] > 200 and s0[right + 0] < 60)) {
        std.debug.print("conformance: FAIL right half is not the source (green)\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL composition is not deterministic across runs\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a side-by-side layout composites the camera left and a named source right, deterministically\n", .{});
    return true;
}

/// Proves per-source composite opacity: a green source at half opacity in an
/// overlay layout over a red camera blends to a red-green mix, not an opaque
/// green overwrite, so the compositor really alpha-blends the source.
fn proveCompositeOpacity(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const sw: u32 = 64;
    const sh: u32 = 64;
    const cam = try gpa.alloc(u8, sw * sh * 4);
    defer gpa.free(cam);
    const src = try gpa.alloc(u8, sw * sh * 4);
    defer gpa.free(src);
    for (0..sw * sh) |p| {
        cam[p * 4 + 0] = 255;
        cam[p * 4 + 1] = 0;
        cam[p * 4 + 2] = 0;
        cam[p * 4 + 3] = 255; // red
        src[p * 4 + 0] = 0;
        src[p * 4 + 1] = 255;
        src[p * 4 + 2] = 0;
        src[p * 4 + 3] = 255; // green
    }
    const base_desc: abi.FrameDesc = .{ .width = sw, .height = sh, .pixel_format = 4, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 33_333 };

    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_define_source(session, "g", 1) != .ok or
        abi.goss_session_submit_source_frame_rgba_copy(session, "g", 1, &base_desc, src.ptr, sw * 4) != .ok or
        abi.goss_session_set_source_composite(session, "g", 1, 0.5, 0, 0, 0, 0, 0) != .ok or
        abi.goss_session_set_layout(session, 5) != .ok)
    {
        std.debug.print("conformance: FAIL composite opacity setup\n", .{});
        return false;
    }
    for (0..3) |i| {
        var d = base_desc;
        d.timestamp_us = @intCast((i + 1) * 33_333);
        if (abi.goss_session_submit_frame_rgba_copy(session, &d, cam.ptr, sw * 4) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var cw: u32 = 0;
    var ch: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    defer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &cw, &ch) != .ok) {
        std.debug.print("conformance: FAIL composite opacity capture\n", .{});
        return false;
    }
    const w: usize = 400;
    const h: usize = 300;
    const centre = (h / 2 * w + w / 2) * 4;
    const rr = shot[centre + 0];
    const gg = shot[centre + 1];
    // Half-opacity green over red: both channels land mid-range, neither saturated.
    if (!(rr > 90 and rr < 180 and gg > 90 and gg < 180)) {
        std.debug.print("conformance: FAIL opacity did not blend the source over the camera (r={d} g={d})\n", .{ rr, gg });
        return false;
    }
    std.debug.print("conformance: PROOF a source at half opacity composites over the camera as a blend, not an opaque overwrite\n", .{});
    return true;
}

/// Proves geofilters through the public ABI: a lens with a geo.in_region trigger
/// fires its action when a submitted location is inside the geofence, not when
/// it is outside, deterministically, with the location computed on-device and
/// never crossing back over the ABI.
fn proveGeofilter(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const manifest =
        \\{"glf":"1.0","id":"goss.reference.geofilter","version":"1.0.0","display_name":"Geofilter","engine_compat":">=0.5","capabilities":[],"parameters":[{"name":"intensity","type":"float","default":0.0,"min":0.0,"max":1.0}],"nodes":[{"id":"grade","type":"grade.pass","inputs":{"frame":"camera"},"params":{}}],"triggers":[{"when":"geo.in_region","action":{"kind":"param_set","target":"intensity","to":1.0}}]}
    ;
    const c_lat: f64 = 37.7749;
    const c_lon: f64 = -122.4194;

    const S = struct {
        fn start(e: *abi.Engine, m: []const u8) !*abi.Session {
            const session = try abi.createSession(e, .{ .frame_budget_us = 0, .reserved = 0 });
            if (abi.goss_session_activate_lens(session, m.ptr, m.len) != .ok) {
                abi.destroySession(session);
                return error.Activate;
            }
            return session;
        }

        fn read(session: *abi.Session, lat: f64, lon: f64, acc: f32) f32 {
            _ = abi.goss_session_submit_location(session, lat, lon, acc, 1000);
            var sig = std.mem.zeroes(abi.LensSignals);
            _ = abi.goss_session_tick_lens(session, 16000, &sig);
            var v: f32 = -1;
            _ = abi.goss_session_parameter_value(session, "intensity", "intensity".len, &v);
            return v;
        }

        fn run(e: *abi.Engine, m: []const u8, clat: f64, clon: f64, lat: f64) !f32 {
            const session = try start(e, m);
            defer abi.destroySession(session);
            if (abi.goss_session_set_geofence(session, clat, clon, 100) != .ok) return error.Geofence;
            return read(session, lat, clon, 5.0);
        }
    };

    const inside_a = S.run(engine, manifest, c_lat, c_lon, c_lat + 0.0001) catch return false; // ~11 m north, inside 100 m
    const inside_b = S.run(engine, manifest, c_lat, c_lon, c_lat + 0.0001) catch return false;
    const outside = S.run(engine, manifest, c_lat, c_lon, c_lat + 0.01) catch return false; // ~1.1 km north, outside

    if (inside_a != 1.0) {
        std.debug.print("conformance: FAIL geo.in_region did not fire inside the geofence ({d})\n", .{inside_a});
        return false;
    }
    if (outside != 0.0) {
        std.debug.print("conformance: FAIL geo.in_region fired outside the geofence ({d})\n", .{outside});
        return false;
    }
    if (inside_a != inside_b) {
        std.debug.print("conformance: FAIL geofilter is not deterministic across runs\n", .{});
        return false;
    }

    // A bbox region: inside the box fires, outside does not.
    {
        const session = S.start(engine, manifest) catch return false;
        defer abi.destroySession(session);
        if (abi.goss_session_set_geofence_bbox(session, c_lat - 0.001, c_lon - 0.001, c_lat + 0.001, c_lon + 0.001) != .ok) return false;
        if (S.read(session, c_lat, c_lon, 5.0) != 1.0) {
            std.debug.print("conformance: FAIL bbox in_region did not fire inside\n", .{});
            return false;
        }
    }
    {
        const session = S.start(engine, manifest) catch return false;
        defer abi.destroySession(session);
        if (abi.goss_session_set_geofence_bbox(session, c_lat - 0.001, c_lon - 0.001, c_lat + 0.001, c_lon + 0.001) != .ok) return false;
        if (S.read(session, c_lat + 0.01, c_lon, 5.0) != 0.0) {
            std.debug.print("conformance: FAIL bbox in_region fired outside\n", .{});
            return false;
        }
    }

    // A polygon region: a small diamond around the center.
    const diamond = [_]f64{ c_lat + 0.001, c_lon, c_lat, c_lon + 0.001, c_lat - 0.001, c_lon, c_lat, c_lon - 0.001 };
    {
        const session = S.start(engine, manifest) catch return false;
        defer abi.destroySession(session);
        if (abi.goss_session_set_geofence_polygon(session, &diamond, 4) != .ok) return false;
        if (S.read(session, c_lat, c_lon, 5.0) != 1.0) {
            std.debug.print("conformance: FAIL polygon in_region did not fire inside\n", .{});
            return false;
        }
    }
    {
        const session = S.start(engine, manifest) catch return false;
        defer abi.destroySession(session);
        if (abi.goss_session_set_geofence_polygon(session, &diamond, 4) != .ok) return false;
        if (S.read(session, c_lat + 0.01, c_lon, 5.0) != 0.0) {
            std.debug.print("conformance: FAIL polygon in_region fired outside\n", .{});
            return false;
        }
    }

    // An accuracy gate: an accurate fix inside fires, a vague one does not.
    {
        const session = S.start(engine, manifest) catch return false;
        defer abi.destroySession(session);
        if (abi.goss_session_set_geofence(session, c_lat, c_lon, 100) != .ok) return false;
        if (abi.goss_session_set_geo_accuracy(session, 20.0) != .ok) return false;
        if (S.read(session, c_lat + 0.0001, c_lon, 5.0) != 1.0) {
            std.debug.print("conformance: FAIL accurate fix inside the region did not fire\n", .{});
            return false;
        }
    }
    {
        const session = S.start(engine, manifest) catch return false;
        defer abi.destroySession(session);
        if (abi.goss_session_set_geofence(session, c_lat, c_lon, 100) != .ok) return false;
        if (abi.goss_session_set_geo_accuracy(session, 20.0) != .ok) return false;
        if (S.read(session, c_lat + 0.0001, c_lon, 80.0) != 0.0) {
            std.debug.print("conformance: FAIL a fix vaguer than the accuracy gate fired\n", .{});
            return false;
        }
    }

    std.debug.print("conformance: PROOF geo.in_region fires inside a circle, box, or polygon region and not outside, an accuracy gate refuses a vague fix, deterministically, with the location never leaving the engine\n", .{});
    return true;
}

/// Proves the brush board: a two-segment stroke yields the expected ribbon size
/// (two segments, six vertices each, six floats each), a null-out query reports
/// that same float count, and undo then clear empty the ribbon.
fn proveBrushStroke(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    if (abi.goss_session_brush_set_style(session, 1.0, 0.2, 0.4, 1.0, 0.02) != .ok) return false;
    _ = abi.goss_session_brush_begin(session);
    _ = abi.goss_session_brush_point(session, 0.0, 0.0);
    _ = abi.goss_session_brush_point(session, 1.0, 0.0);
    _ = abi.goss_session_brush_point(session, 1.0, 1.0);
    _ = abi.goss_session_brush_end(session);

    const want: usize = 2 * 6 * 6; // two segments, six vertices, six floats
    var reported: usize = 0;
    if (abi.goss_session_brush_vertices(session, null, 0, &reported) != .ok) return false;
    if (reported != want) {
        std.debug.print("conformance: FAIL brush float-count query reported {d}, expected {d}\n", .{ reported, want });
        return false;
    }

    var buf: [want]f32 = undefined;
    var written: usize = 0;
    if (abi.goss_session_brush_vertices(session, &buf, buf.len, &written) != .ok) return false;
    if (written != want) {
        std.debug.print("conformance: FAIL brush ribbon wrote {d} floats, expected {d}\n", .{ written, want });
        return false;
    }
    if (buf[2] != 1.0 or buf[3] != 0.2) {
        std.debug.print("conformance: FAIL brush color did not ride the vertices\n", .{});
        return false;
    }

    _ = abi.goss_session_brush_undo(session);
    var after_undo: usize = 1;
    _ = abi.goss_session_brush_vertices(session, null, 0, &after_undo);

    _ = abi.goss_session_brush_redo(session);
    var after_redo: usize = 0;
    _ = abi.goss_session_brush_vertices(session, null, 0, &after_redo);

    _ = abi.goss_session_brush_clear(session);
    var after_clear: usize = 1;
    _ = abi.goss_session_brush_vertices(session, null, 0, &after_clear);

    if (after_undo != 0 or after_redo != want or after_clear != 0) {
        std.debug.print("conformance: FAIL brush undo/redo/clear did not track the ribbon ({d}/{d}/{d})\n", .{ after_undo, after_redo, after_clear });
        return false;
    }

    // Highlighter mode biases the opened stroke: half the pen alpha rides its vertices.
    _ = abi.goss_session_brush_set_style(session, 1.0, 1.0, 1.0, 1.0, 0.01);
    _ = abi.goss_session_brush_set_mode(session, 1); // highlighter
    _ = abi.goss_session_brush_begin(session);
    _ = abi.goss_session_brush_point(session, 0.0, 0.5);
    _ = abi.goss_session_brush_point(session, 1.0, 0.5);
    _ = abi.goss_session_brush_end(session);
    var hi: [6]f32 = undefined;
    var hic: usize = 0;
    _ = abi.goss_session_brush_vertices(session, &hi, hi.len, &hic);
    if (hic != 6 or hi[5] > 0.5) {
        std.debug.print("conformance: FAIL highlighter mode did not lower the ribbon alpha ({d})\n", .{hi[5]});
        return false;
    }

    // Erase across that stroke drops it; a miss leaves it.
    var missed: usize = 1;
    _ = abi.goss_session_brush_erase_at(session, 0.5, 0.9, 0.05, &missed);
    var erased: usize = 0;
    _ = abi.goss_session_brush_erase_at(session, 0.5, 0.5, 0.05, &erased);
    var left: usize = 1;
    _ = abi.goss_session_brush_vertices(session, null, 0, &left);
    if (missed != 0 or erased != 1 or left != 0) {
        std.debug.print("conformance: FAIL brush erase did not hit the crossed stroke only ({d}/{d}/{d})\n", .{ missed, erased, left });
        return false;
    }

    std.debug.print("conformance: PROOF a brush stroke builds a bounded triangle ribbon the renderer can pull, with modes, erase, undo, redo, and clear tracking it, allocation-free\n", .{});
    return true;
}

/// Proves the engine-side outgoing mix: at the native 48 kHz, the lens over a
/// silent mic is bit-identical to pull_audio, a non-zero mic sums in with
/// saturation, and the resampled 44.1 kHz path is non-silent and deterministic
/// across runs.
fn proveOutputMix(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const block: u32 = 512;

    // Helper: a fresh session with the sound lens active and its trigger fired,
    // ready for the first audio block to carry the voice from sample zero.
    const S = struct {
        const dir = ".lens-packages/sound-beat";
        fn armed(e: *abi.Engine) !*abi.Session {
            const session = try abi.createSession(e, .{ .frame_budget_us = 0, .reserved = 0 });
            if (abi.goss_session_activate_lens_from_directory(session, dir, dir.len) != .ok) return error.Activate;
            var present = std.mem.zeroes(abi.LensSignals);
            present.has_face = true;
            _ = abi.goss_session_tick_lens(session, 16000, &present);
            return session;
        }
    };

    // The reference lens PCM, pulled straight from the mixer.
    var lens_ref: [block]i16 = undefined;
    {
        const session = try S.armed(engine);
        defer abi.destroySession(session);
        _ = abi.goss_session_pull_audio(session, &lens_ref, block);
    }
    var ref_energy: u64 = 0;
    for (lens_ref) |s| ref_energy += @abs(@as(i32, s));
    if (ref_energy == 0) {
        std.debug.print("conformance: FAIL the reference lens sound is silent\n", .{});
        return false;
    }

    // Native-rate mix over a silent mic equals the pulled lens PCM exactly.
    var mix_silence: [block]i16 = undefined;
    {
        const session = try S.armed(engine);
        defer abi.destroySession(session);
        if (abi.goss_session_mix_output_audio(session, null, &mix_silence, block, 48_000, 1) != .ok) {
            std.debug.print("conformance: FAIL mix_output_audio returned non-ok\n", .{});
            return false;
        }
    }
    if (!std.mem.eql(i16, &mix_silence, &lens_ref)) {
        std.debug.print("conformance: FAIL native-rate mix over silence differs from the pulled lens PCM\n", .{});
        return false;
    }

    // A steady mic sums in with saturation: out == clamp(mic_s16 + lens).
    const mic_val: f32 = 0.25;
    const mic_s16: i32 = @intFromFloat(@round(@as(f64, mic_val) * 32767.0)); // 8192
    var mic_block: [block]f32 = undefined;
    @memset(&mic_block, mic_val);
    var mix_mic: [2][block]i16 = undefined;
    for (0..2) |run| {
        const session = try S.armed(engine);
        defer abi.destroySession(session);
        if (abi.goss_session_mix_output_audio(session, &mic_block, &mix_mic[run], block, 48_000, 1) != .ok) {
            std.debug.print("conformance: FAIL mix_output_audio with a mic returned non-ok\n", .{});
            return false;
        }
    }
    for (mix_mic[0], 0..) |got, i| {
        const want: i16 = @intCast(std.math.clamp(mic_s16 + @as(i32, lens_ref[i]), @as(i32, -32768), @as(i32, 32767)));
        if (got != want) {
            std.debug.print("conformance: FAIL outgoing mix sample {d} = {d}, want {d}\n", .{ i, got, want });
            return false;
        }
    }
    if (!std.mem.eql(i16, &mix_mic[0], &mix_mic[1])) {
        std.debug.print("conformance: FAIL outgoing mix is not deterministic across runs\n", .{});
        return false;
    }

    // The resampled path (44.1 kHz outgoing) is non-silent and bit-stable.
    var mix_resampled: [2][block]i16 = undefined;
    for (0..2) |run| {
        const session = try S.armed(engine);
        defer abi.destroySession(session);
        if (abi.goss_session_mix_output_audio(session, null, &mix_resampled[run], block, 44_100, 1) != .ok) {
            std.debug.print("conformance: FAIL resampled mix returned non-ok\n", .{});
            return false;
        }
    }
    var res_energy: u64 = 0;
    for (mix_resampled[0]) |s| res_energy += @abs(@as(i32, s));
    if (res_energy == 0) {
        std.debug.print("conformance: FAIL resampled outgoing mix is silent\n", .{});
        return false;
    }
    if (!std.mem.eql(i16, &mix_resampled[0], &mix_resampled[1])) {
        std.debug.print("conformance: FAIL resampled outgoing mix is not deterministic across runs\n", .{});
        return false;
    }

    std.debug.print("conformance: PROOF the engine mixes lens sound into the outgoing track - native-rate mix equals the pulled PCM, a mic sums with saturation, resampled and bit-stable\n", .{});
    return true;
}

/// Proves physics chains: a dynamic pendant chained to a static anchor
/// swings out under gravity to hang at the chain length, the settled
/// frame differs from the initial frame, and two runs are identical.
fn provePhysicsChain(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/physics-chain", ".lens-packages/physics-chain".len) != .ok) {
            std.debug.print("conformance: FAIL chain lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the chained pendant did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-physics-chain.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL physics chain is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a chained pendant swings and hangs deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Renders a physics reference lens for 86 frames and returns its settled
/// 400x300 capture, so two joint types can be compared pixel for pixel.
fn settledPhysicsCapture(gpa: std.mem.Allocator, engine: *abi.Engine, bundle: []const u8) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, bundle.ptr, bundle.len) != .ok) return error.ActivationFailed;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    var settled: []u8 = &.{};
    errdefer if (settled.len > 0) gpa.free(settled);
    for (0..90) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == 85) {
            settled = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, settled.ptr, settled.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return settled;
}

/// Settles a physics scene whose bodies are anchored to the tracked world:
/// each frame submits a world state (a moving camera pose and one anchor) then
/// the corpus frame, so the sim runs in world space and draws through the
/// platform camera. Captures at frame 85.
fn settledWorldPhysicsCapture(gpa: std.mem.Allocator, engine: *abi.Engine, bundle: []const u8) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, bundle.ptr, bundle.len) != .ok) return error.ActivationFailed;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const anchor = abi.WorldAnchor{ .id = 7, .pose = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };
    var settled: []u8 = &.{};
    errdefer if (settled.len > 0) gpa.free(settled);
    for (0..90) |i| {
        const replay = world_replay.stateAt(@intCast(i), 33_333, 4.0 / 3.0);
        const state = abi.WorldState{
            .tracking_state = replay.tracking_state,
            .world_from_camera = @bitCast(replay.world_from_camera.cols),
            .projection = @bitCast(replay.projection.cols),
            .timestamp_us = replay.timestamp_us,
        };
        if (abi.goss_session_submit_world(session, &state, null, 0, @ptrCast(&anchor), 1, null) != .ok) return error.SubmitFailed;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = replay.timestamp_us };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == 85) {
            settled = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, settled.ptr, settled.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return settled;
}

/// Proves the point (ball) joint: a pendant pinned to its anchor by a point
/// joint settles to its pivot, deterministically, at a place the same pendant
/// hung on a distance chain does not - so the joint type genuinely changes the
/// physics, each bit-stable across runs.
fn provePhysicsPivot(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var pivot_settled: []u8 = &.{};
    defer if (pivot_settled.len > 0) gpa.free(pivot_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-pivot");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            pivot_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL physics pivot is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const chain_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-chain");
    defer gpa.free(chain_settled);
    if (std.mem.eql(u8, pivot_settled, chain_settled)) {
        std.debug.print("conformance: FAIL the point joint settled the same as the distance chain\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a point joint pins a pendant to its pivot, settling where a distance chain does not, bit-stable across runs\n", .{});
    return true;
}

/// Proves the fixed joint: a pendant welded to its anchor rides it rigidly,
/// settling at a place neither the distance chain nor the freely-swinging point
/// joint reaches, deterministically and bit-stable across runs.
fn provePhysicsFixed(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var fixed_settled: []u8 = &.{};
    defer if (fixed_settled.len > 0) gpa.free(fixed_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-fixed");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            fixed_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL physics fixed is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const chain_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-chain");
    defer gpa.free(chain_settled);
    const pivot_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-pivot");
    defer gpa.free(pivot_settled);
    if (std.mem.eql(u8, fixed_settled, chain_settled)) {
        std.debug.print("conformance: FAIL the fixed joint settled the same as the distance chain\n", .{});
        return false;
    }
    if (std.mem.eql(u8, fixed_settled, pivot_settled)) {
        std.debug.print("conformance: FAIL the fixed joint settled the same as the point joint\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a fixed joint welds a pendant to its anchor, settling where neither the distance chain nor the point joint does, bit-stable across runs\n", .{});
    return true;
}

/// Proves the hinge joint: a pendant hinged about a z axis at its anchor swings
/// in one plane and settles where the point and fixed joints do not, its rigid
/// single-axis arm reaching a different frame than any of the others, each
/// bit-stable across runs.
fn provePhysicsHinge(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var hinge_settled: []u8 = &.{};
    defer if (hinge_settled.len > 0) gpa.free(hinge_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-hinge");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            hinge_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL physics hinge is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const point_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-pivot");
    defer gpa.free(point_settled);
    const fixed_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-fixed");
    defer gpa.free(fixed_settled);
    if (std.mem.eql(u8, hinge_settled, point_settled)) {
        std.debug.print("conformance: FAIL the hinge joint settled the same as the point joint\n", .{});
        return false;
    }
    if (std.mem.eql(u8, hinge_settled, fixed_settled)) {
        std.debug.print("conformance: FAIL the hinge joint settled the same as the fixed joint\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a hinge joint swings a pendant in one plane, settling where the point and fixed joints do not, bit-stable across runs\n", .{});
    return true;
}

/// Proves the spring joint: a pendant tethered by a soft spring stretches
/// under gravity and settles lower than the same pendant on a rigid distance
/// chain or hinge, and nowhere near the point or fixed joints, each
/// bit-stable across runs.
fn provePhysicsSpring(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var spring_settled: []u8 = &.{};
    defer if (spring_settled.len > 0) gpa.free(spring_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-spring");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            spring_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL physics spring is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const chain_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-chain");
    defer gpa.free(chain_settled);
    const hinge_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-hinge");
    defer gpa.free(hinge_settled);
    if (std.mem.eql(u8, spring_settled, chain_settled)) {
        std.debug.print("conformance: FAIL the spring joint settled the same as the rigid distance chain\n", .{});
        return false;
    }
    if (std.mem.eql(u8, spring_settled, hinge_settled)) {
        std.debug.print("conformance: FAIL the spring joint settled the same as the hinge joint\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a spring joint stretches a pendant below where the rigid distance chain and hinge settle it, bit-stable across runs\n", .{});
    return true;
}

/// Proves a 2D world of planar colliders: a planar sphere (circle) and a planar
/// hull (polygon) drop onto a tilted incline. Confined to the plane they hold
/// their ground where the free version of the same scene slides off in the
/// third axis (the 2D spring and confinement are pinned by the module tests).
fn provePhysics2dWorld(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var planar_settled: []u8 = &.{};
    defer if (planar_settled.len > 0) gpa.free(planar_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/two-d-world");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            planar_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the 2D world is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const free_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/two-d-world-free");
    defer gpa.free(free_settled);
    if (std.mem.eql(u8, planar_settled, free_settled)) {
        std.debug.print("conformance: FAIL the 2D world settled the same as the unconstrained 3D version\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a 2D world of a circle collider and a polygon collider holds its plane on a tilted incline where the free 3D scene slides off it, bit-stable across runs\n", .{});
    return true;
}

/// Proves physics against a world-anchored mesh: a concave mesh and a ball,
/// both anchored to the tracked world, settle in world space and draw through
/// the platform camera - the ball comes to rest in the mesh valley where the
/// same ball with no mesh keeps falling, bit-stable across runs.
fn provePhysicsWorldMesh(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var caught: []u8 = &.{};
    defer if (caught.len > 0) gpa.free(caught);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledWorldPhysicsCapture(gpa, engine, ".lens-packages/world-mesh-collider");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            caught = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the world-anchored mesh scene is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const empty = try settledWorldPhysicsCapture(gpa, engine, ".lens-packages/world-mesh-empty");
    defer gpa.free(empty);
    if (std.mem.eql(u8, caught, empty)) {
        std.debug.print("conformance: FAIL the world-anchored mesh did not change where the ball settles\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a ball rests on a world-anchored mesh where the same ball with no mesh keeps falling, bit-stable across runs\n", .{});
    return true;
}

/// Settles a physics scene after its glb geometry has decoded: a first frame
/// plus pumpUntilLoaded builds any glb-derived collider before the sim runs (no
/// frame advances it during the wait), so the fall is deterministic whatever
/// the decode timing. Captures at frame 85.
fn settledGlbPhysicsCapture(gpa: std.mem.Allocator, engine: *abi.Engine, bundle: []const u8) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, bundle.ptr, bundle.len) != .ok) return error.ActivationFailed;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const warm: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1 };
    if (abi.goss_session_submit_frame_copy(session, &warm, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
    pumpUntilLoaded(engine, session);
    var settled: []u8 = &.{};
    errdefer if (settled.len > 0) gpa.free(settled);
    for (0..90) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == 85) {
            settled = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, settled.ptr, settled.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return settled;
}

/// Proves a mesh collider auto-built from a node's own glb: a ball dropped onto
/// a slab whose collider is the slab glb's own decoded geometry comes to rest on
/// it, where the same slab with no physics lets the ball fall straight past.
/// Bit-stable across runs.
fn provePhysicsGlbCollider(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var caught: []u8 = &.{};
    defer if (caught.len > 0) gpa.free(caught);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledGlbPhysicsCapture(gpa, engine, ".lens-packages/glb-collider");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            caught = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the glb-collider scene is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const loose = try settledGlbPhysicsCapture(gpa, engine, ".lens-packages/glb-collider-loose");
    defer gpa.free(loose);
    if (std.mem.eql(u8, caught, loose)) {
        std.debug.print("conformance: FAIL the glb-derived collider did not catch the ball\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a ball rests on a collider built from a slab's own glb geometry where the same slab with no physics lets it fall past, bit-stable across runs\n", .{});
    return true;
}

/// Settles a physics scene, optionally driving a grab: once the ball has come
/// to rest, grab it, drag it up and to the side over several frames, and let
/// go, so it is flung. Captures at frame 85.
fn settledGrabCapture(gpa: std.mem.Allocator, engine: *abi.Engine, bundle: []const u8, do_grab: bool) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, bundle.ptr, bundle.len) != .ok) return error.ActivationFailed;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    var settled: []u8 = &.{};
    errdefer if (settled.len > 0) gpa.free(settled);
    for (0..90) |i| {
        if (do_grab) {
            if (i == 12) _ = abi.goss_session_grab(session, 0.0, -0.13, 0.0);
            if (i > 12 and i < 36) {
                const t = @as(f32, @floatFromInt(i - 12)) / 24.0;
                _ = abi.goss_session_grab(session, 0.35 * t, -0.13 + 0.72 * t, 0.0);
            }
            if (i == 36) _ = abi.goss_session_release(session);
        }
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == 85) {
            settled = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, settled.ptr, settled.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return settled;
}

/// Proves grab and throw: a pointer grabs the resting ball, drags it up and
/// aside, and releases it so it flies off - the settled frame lands far from
/// the same scene left untouched, where the ball just rests. Bit-stable.
fn proveGrabThrow(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var thrown: []u8 = &.{};
    defer if (thrown.len > 0) gpa.free(thrown);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledGrabCapture(gpa, engine, ".lens-packages/grab-scene", true);
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            thrown = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the grab-throw is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const rested = try settledGrabCapture(gpa, engine, ".lens-packages/grab-scene", false);
    defer gpa.free(rested);
    if (std.mem.eql(u8, thrown, rested)) {
        std.debug.print("conformance: FAIL the grab did not move the ball\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a pointer grabs the resting ball, drags it and throws it clear of where it rests untouched, bit-stable across runs\n", .{});
    return true;
}

/// Proves the 2D SPH fluid renders and flows: the block of fluid particles it
/// starts as pools into a different shape by the settle frame, so the sim is
/// on screen and running, and the settled frame is bit-stable across runs. The
/// pooling itself is pinned by the sph module test.
fn proveSphFluid(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var settled: []u8 = &.{};
    defer if (settled.len > 0) gpa.free(settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = (try captureFountainAtFrame(gpa, engine, ".lens-packages/sph-pool", 85)) orelse return false;
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the sph fluid is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const early = (try captureFountainAtFrame(gpa, engine, ".lens-packages/sph-pool", 2)) orelse return false;
    defer gpa.free(early);
    if (std.mem.eql(u8, settled, early)) {
        std.debug.print("conformance: FAIL the sph fluid did not flow\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a 2D SPH fluid renders and flows from its start block into a pool, bit-stable across runs\n", .{});
    return true;
}

/// Settles a physics scene with face tracking on, so a head-following collider
/// has a head to track. It first warms the tracker with frozen physics (a fixed
/// timestamp advances no step) until a face result lands, so the head is being
/// tracked before the ball falls; then it settles and captures at frame 85.
fn settledHeadPhysicsCapture(gpa: std.mem.Allocator, engine: *abi.Engine, bundle: []const u8) !?[]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    const face_bytes = std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20)) catch return null;
    defer gpa.free(face_bytes);
    if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) return null;
    if (abi.goss_session_activate_lens_from_directory(session, bundle.ptr, bundle.len) != .ok) return error.ActivationFailed;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    var warm: u32 = 0;
    while (warm < 180) : (warm += 1) {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1 };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        var fr: abi.FaceResult = undefined;
        if (abi.goss_session_face_result(session, &fr) == .ok) break;
    }
    var settled: []u8 = &.{};
    errdefer if (settled.len > 0) gpa.free(settled);
    for (0..90) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == 85) {
            settled = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, settled.ptr, settled.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return settled;
}

/// Proves a head collider driven off the tracked head pose: a ball dropped onto
/// the tracked head comes to rest on the head-following collider where the same
/// ball with no collider falls straight past. Bit-stable across runs.
fn proveHeadCollider(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var caught: []u8 = &.{};
    defer if (caught.len > 0) gpa.free(caught);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = (try settledHeadPhysicsCapture(gpa, engine, ".lens-packages/head-collider")) orelse return true;
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            caught = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the head collider scene is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const nocollider = (try settledHeadPhysicsCapture(gpa, engine, ".lens-packages/head-nocollider")) orelse return true;
    defer gpa.free(nocollider);
    if (std.mem.eql(u8, caught, nocollider)) {
        std.debug.print("conformance: FAIL the head collider did not stop the ball\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a ball rests on a collider driven to the tracked head where the same ball with no collider falls past, bit-stable across runs\n", .{});
    return true;
}

/// Settles a scene over a live collider added at runtime under the ball; when
/// `erase` is set the collider is erased partway, so the resting ball falls.
/// Captures at frame 85.
fn settledLiveColliderCapture(gpa: std.mem.Allocator, engine: *abi.Engine, erase: bool) ![]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/live-collider", ".lens-packages/live-collider".len) != .ok) return error.ActivationFailed;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    _ = abi.goss_session_add_collider(session, 0.0, -0.15, 0.0);
    var settled: []u8 = &.{};
    errdefer if (settled.len > 0) gpa.free(settled);
    for (0..90) |i| {
        if (erase and i == 45) _ = abi.goss_session_erase_collider(session, 0.0, -0.15, 0.0, 0.3);
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == 85) {
            settled = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, settled.ptr, settled.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return settled;
}

/// Proves erasable live colliders: a ball rests on a collider added under it at
/// runtime, and when that collider is erased partway the ball drops - the same
/// scene lands the ball in two different places. Bit-stable across runs.
fn proveLiveCollider(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var resting: []u8 = &.{};
    defer if (resting.len > 0) gpa.free(resting);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledLiveColliderCapture(gpa, engine, false);
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            resting = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the live collider scene is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const erased = try settledLiveColliderCapture(gpa, engine, true);
    defer gpa.free(erased);
    if (std.mem.eql(u8, resting, erased)) {
        std.debug.print("conformance: FAIL erasing the live collider did not drop the ball\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a ball rests on a live collider added under it and drops when that collider is erased, bit-stable across runs\n", .{});
    return true;
}

/// Proves GPU mesh instancing: a 3D-mesh particle cloud drawn in one instanced
/// call renders the same image as the same cloud drawn one mesh per particle,
/// so the instanced path is correct. It is stable and on screen (an early frame
/// differs from a later one), and matches the per-draw cloud.
fn proveMeshInstancing(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const inst0 = (try captureFountainAtFrame(gpa, engine, ".lens-packages/mesh-instanced", 40)) orelse return false;
    defer gpa.free(inst0);
    const inst1 = (try captureFountainAtFrame(gpa, engine, ".lens-packages/mesh-instanced", 40)) orelse return false;
    defer gpa.free(inst1);
    if (!std.mem.eql(u8, inst0, inst1)) {
        std.debug.print("conformance: FAIL the instanced mesh cloud is not bit-stable across runs\n", .{});
        return false;
    }
    const early = (try captureFountainAtFrame(gpa, engine, ".lens-packages/mesh-instanced", 4)) orelse return false;
    defer gpa.free(early);
    if (std.mem.eql(u8, inst0, early)) {
        std.debug.print("conformance: FAIL the instanced mesh cloud drew nothing dynamic\n", .{});
        return false;
    }
    const plain = (try captureFountainAtFrame(gpa, engine, ".lens-packages/mesh-plain", 40)) orelse return false;
    defer gpa.free(plain);
    if (frameDiffFraction(inst0, plain, 16) > 0.005) {
        std.debug.print("conformance: FAIL the instanced mesh cloud does not match the per-draw cloud\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a mesh particle cloud drawn in one instanced call matches the per-draw cloud, stable and on screen\n", .{});
    return true;
}

/// Proves rich text styling: the same string with a gradient, a drop shadow
/// and a stroke outline renders a different frame from the plain-fill text, so
/// the styling draws, and it is bit-stable across runs. The rasterizer's own
/// coverage is pinned by the font module test.
fn proveRichText(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const rich0 = (try captureFountainAtFrame(gpa, engine, ".lens-packages/text-rich", 10)) orelse return false;
    defer gpa.free(rich0);
    const rich1 = (try captureFountainAtFrame(gpa, engine, ".lens-packages/text-rich", 10)) orelse return false;
    defer gpa.free(rich1);
    if (!std.mem.eql(u8, rich0, rich1)) {
        std.debug.print("conformance: FAIL rich text is not bit-stable across runs\n", .{});
        return false;
    }
    const plain = (try captureFountainAtFrame(gpa, engine, ".lens-packages/text-plain", 10)) orelse return false;
    defer gpa.free(plain);
    if (std.mem.eql(u8, rich0, plain)) {
        std.debug.print("conformance: FAIL rich text styling did not change the frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF gradient, shadow and stroke restyle a text label away from the plain fill, bit-stable across runs\n", .{});
    return true;
}

/// Proves extruded 3D text: the same string with a depth draws as a rotated 3D
/// block mesh through the model path, a different frame from the flat sprite
/// text, and bit-stable across runs. The block mesh itself is pinned by the
/// font module test.
fn proveExtrudedText(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const solid0 = (try captureFountainAtFrame(gpa, engine, ".lens-packages/text-3d", 10)) orelse return false;
    defer gpa.free(solid0);
    const solid1 = (try captureFountainAtFrame(gpa, engine, ".lens-packages/text-3d", 10)) orelse return false;
    defer gpa.free(solid1);
    if (!std.mem.eql(u8, solid0, solid1)) {
        std.debug.print("conformance: FAIL extruded 3D text is not bit-stable across runs\n", .{});
        return false;
    }
    const flat = (try captureFountainAtFrame(gpa, engine, ".lens-packages/text-flat", 10)) orelse return false;
    defer gpa.free(flat);
    if (std.mem.eql(u8, solid0, flat)) {
        std.debug.print("conformance: FAIL extruded text drew the same as the flat text\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a text label extrudes into a rotated 3D block mesh, a different frame from the flat sprite text, bit-stable across runs\n", .{});
    return true;
}

/// Paints one fixture frame: a bright band on a dark field, its column
/// sweeping left to right across the clip, so a decoded frame reveals how
/// far playback has advanced.
fn paintSweepFrame(rgba: []u8, w: u32, h: u32, i: u32, n: u32) void {
    const span = w - 40;
    const band: u32 = if (n > 1) (i * span) / (n - 1) else 0;
    for (0..h) |y| {
        for (0..w) |x| {
            const at = (y * w + x) * 4;
            const on = x >= band and x < band + 40;
            rgba[at + 0] = if (on) 250 else 24;
            rgba[at + 1] = if (on) 40 else 24;
            rgba[at + 2] = if (on) 40 else @intCast((i * 5) % 200);
            rgba[at + 3] = 255;
        }
    }
}

/// Encodes a short deterministic clip through the recording rail so the
/// video-texture proof has a real MP4 to decode back. The sweeping band
/// makes each frame distinct, so playback advancing is observable.
fn encodeVideoFixture(gpa: std.mem.Allocator, engine: *abi.Engine, path: []const u8) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) return false;
    if (abi.goss_engine_recording_start(engine, session, path.ptr, path.len, null) != .ok) return false;

    const w: u32 = 400;
    const h: u32 = 300;
    const rgba = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(rgba);
    const total: u32 = 56;
    for (0..total) |i| {
        paintSweepFrame(rgba, w, h, @intCast(i), total);
        const planes = try rgbaToNv12(gpa, .{ .pixels = .{ .rgba8 = rgba }, .width = w, .height = h });
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return false;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    if (abi.goss_engine_recording_stop(engine) != .ok) return false;
    const shape = abi.recordingProbe(path) catch return false;
    // The late capture reads ~27 frames in; the clip must be at least that
    // long so playback lands mid-clip rather than looping back to the start.
    return shape.frames >= 32 and shape.width == w and shape.height == h;
}

fn writeVideoLens(dir: []const u8, clip: []const u8, fps: f32) !void {
    const manifest_json = try std.fmt.allocPrint(std.heap.page_allocator,
        \\{{"glf":"1.0","id":"goss.reference.video-texture","version":"1.0.0","display_name":"Video Texture","engine_compat":">=0.5","capabilities":[],"parameters":[],
        \\ "nodes":[{{"id":"clip","type":"video.texture","inputs":{{"frame":"camera"}},"params":{{}},
        \\ "video":{{"source":"clip","x":0.2,"y":0.2,"w":0.6,"h":0.6,"fps":{d:.1},"loop":true}}}}],"triggers":[]}}
    , .{fps});
    defer std.heap.page_allocator.free(manifest_json);
    const manifest_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/manifest.json", .{dir});
    defer std.heap.page_allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = manifest_path, .data = manifest_json });
    const asset_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/assets/clip.mp4", .{dir});
    defer std.heap.page_allocator.free(asset_path);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = asset_path, .data = clip });
}

/// Proves the video texture through a real MP4 round trip: a clip encoded
/// through the recording rail decodes back onto a sprite. A late frame
/// differs from an early one (playback advances off the frame clock), the
/// late frame is bit-stable, and an fps-0 lens holds the first frame.
fn proveVideoTexture(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/video-lens/assets");
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out/video-static/assets");
    if (!try encodeVideoFixture(gpa, engine, "zig-out/conformance-video.mp4")) {
        std.debug.print("conformance: FAIL the video fixture did not encode\n", .{});
        return false;
    }
    const clip = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-video.mp4", gpa, .limited(64 << 20));
    defer gpa.free(clip);
    try writeVideoLens("zig-out/video-lens", clip, 10.0);
    try writeVideoLens("zig-out/video-static", clip, 0.0);

    const early = (try captureFountainAtFrame(gpa, engine, "zig-out/video-lens", 5)) orelse return false;
    defer gpa.free(early);
    const late = (try captureFountainAtFrame(gpa, engine, "zig-out/video-lens", 80)) orelse return false;
    defer gpa.free(late);
    const late2 = (try captureFountainAtFrame(gpa, engine, "zig-out/video-lens", 80)) orelse return false;
    defer gpa.free(late2);
    const held = (try captureFountainAtFrame(gpa, engine, "zig-out/video-static", 80)) orelse return false;
    defer gpa.free(held);

    if (!std.mem.eql(u8, late, late2)) {
        std.debug.print("conformance: FAIL the decoded video frame is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, early, late)) {
        std.debug.print("conformance: FAIL the video did not advance between an early and a late frame\n", .{});
        return false;
    }
    if (std.mem.eql(u8, late, held)) {
        std.debug.print("conformance: FAIL a paused (fps 0) clip drew the same frame as a playing one\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a recorded MP4 decodes onto a sprite and advances off the lens clock, bit-stable, with a paused clip holding its first frame\n", .{});
    return true;
}

/// Proves the cylinder collider shape: the same marker dropped as a cylinder
/// lands flat on its base and rests a half height up, where the sphere marker
/// of the identical drop lens settles far lower - so the shape, not the model,
/// drives the contact - each bit-stable across runs.
fn provePhysicsShapeCylinder(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var cyl_settled: []u8 = &.{};
    defer if (cyl_settled.len > 0) gpa.free(cyl_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/shape-cylinder");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            cyl_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL cylinder shape is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const sphere_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-drop");
    defer gpa.free(sphere_settled);
    if (std.mem.eql(u8, cyl_settled, sphere_settled)) {
        std.debug.print("conformance: FAIL the cylinder marker settled the same as the sphere marker\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a cylinder marker rests a half height up where the identical sphere-marker drop settles lower, bit-stable across runs\n", .{});
    return true;
}

/// Proves the capsule collider and oriented bodies: a capsule laid on its side
/// bridges a gap between two pillars, resting high, where a sphere of its
/// radius drops straight through the same gap to the floor - so both the
/// elongated shape and the body rotation take effect - each bit-stable.
fn provePhysicsShapeCapsule(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var cap_settled: []u8 = &.{};
    defer if (cap_settled.len > 0) gpa.free(cap_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/shape-capsule");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            cap_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL capsule shape is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const sphere_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/gap-sphere");
    defer gpa.free(sphere_settled);
    if (std.mem.eql(u8, cap_settled, sphere_settled)) {
        std.debug.print("conformance: FAIL the bridging capsule settled the same as the sphere falling through the gap\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a side-laid capsule bridges a gap a sphere of its radius falls straight through, bit-stable across runs\n", .{});
    return true;
}

/// Proves declarative jiggle: a jiggle chain builds hidden spring-linked proxy
/// bodies that hang its ornament well below the anchor, where the same ornament
/// rigidly welded rides at it - so the multi-link chain assembled and simulates,
/// bit-stable. The secondary-motion lag itself is covered by the physics unit test.
fn provePhysicsJiggle(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var jiggle_settled: []u8 = &.{};
    defer if (jiggle_settled.len > 0) gpa.free(jiggle_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/jiggle-ornament");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            jiggle_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the jiggle chain is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const rigid_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/rigid-ornament");
    defer gpa.free(rigid_settled);
    if (std.mem.eql(u8, jiggle_settled, rigid_settled)) {
        std.debug.print("conformance: FAIL the jiggle ornament settled the same as the rigidly welded one\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a jiggle chain hangs its ornament below the anchor where a rigid weld rides at it, bit-stable across runs\n", .{});
    return true;
}

/// Proves per-body material: the same block set on the same slope holds near
/// where it sits when it is grippy but runs to the base when it is slippery, so
/// friction alone changes where it settles, each bit-stable across runs.
fn provePhysicsFriction(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var grip_settled: []u8 = &.{};
    defer if (grip_settled.len > 0) gpa.free(grip_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/friction-grip");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            grip_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the grippy block is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const slide_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/friction-slide");
    defer gpa.free(slide_settled);
    if (std.mem.eql(u8, grip_settled, slide_settled)) {
        std.debug.print("conformance: FAIL the grippy block settled the same as the slippery one\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a grippy block holds on a slope where a slippery one of the same shape runs to the base, bit-stable across runs\n", .{});
    return true;
}

/// Proves the convex-hull collider: the same ball dropped on a wedge-shaped
/// hull rolls down its sloped face and off the low edge, where on a flat-topped
/// box it stays where it lands, so the hull points shape the contact, each
/// bit-stable across runs.
fn provePhysicsHull(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var wedge_settled: []u8 = &.{};
    defer if (wedge_settled.len > 0) gpa.free(wedge_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/hull-wedge");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            wedge_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the hull wedge is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const box_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/box-block");
    defer gpa.free(box_settled);
    if (std.mem.eql(u8, wedge_settled, box_settled)) {
        std.debug.print("conformance: FAIL the ball on the hull wedge settled the same as on the flat box\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a ball rolls down a wedge-shaped convex hull where on a flat box it stays put, bit-stable across runs\n", .{});
    return true;
}

/// Proves restitution: a bouncy ball is still rebounding above the floor at the
/// settle frame where a dead ball of the same drop has come to rest, so the
/// material's restitution changes the motion, each bit-stable across runs.
fn provePhysicsRestitution(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var bouncy_settled: []u8 = &.{};
    defer if (bouncy_settled.len > 0) gpa.free(bouncy_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/bounce-high");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            bouncy_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the bouncy ball is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const dead_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/bounce-dead");
    defer gpa.free(dead_settled);
    if (std.mem.eql(u8, bouncy_settled, dead_settled)) {
        std.debug.print("conformance: FAIL the bouncy ball settled the same as the dead one\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a bouncy ball still rides above the floor where a dead ball of the same drop has come to rest, bit-stable across runs\n", .{});
    return true;
}

/// Proves the concave mesh collider: a ball settles at the bottom of a V-groove
/// triangle mesh where on the convex hull of the very same points it rests up on
/// the filled-in top, so the mesh keeps a concavity a hull cannot, each
/// bit-stable across runs.
fn provePhysicsMesh(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var mesh_settled: []u8 = &.{};
    defer if (mesh_settled.len > 0) gpa.free(mesh_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/mesh-valley");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            mesh_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the mesh valley is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const hull_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/hull-valley");
    defer gpa.free(hull_settled);
    if (std.mem.eql(u8, mesh_settled, hull_settled)) {
        std.debug.print("conformance: FAIL the ball in the mesh valley settled the same as on the hull of the same points\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a ball settles in a concave mesh valley where the convex hull of the same points holds it up on top, bit-stable across runs\n", .{});
    return true;
}

/// Proves the pressurised soft-body balloon: the same shell with internal
/// pressure inflates to a fuller shape than the limp one at zero pressure, so
/// the pressure drives the deformation, each bit-stable across runs.
fn provePhysicsBalloon(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var inflated_settled: []u8 = &.{};
    defer if (inflated_settled.len > 0) gpa.free(inflated_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/balloon-inflated");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            inflated_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the inflated balloon is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const limp_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/balloon-limp");
    defer gpa.free(limp_settled);
    if (std.mem.eql(u8, inflated_settled, limp_settled)) {
        std.debug.print("conformance: FAIL the inflated balloon settled the same as the limp one\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a pressurised soft-body balloon inflates to a fuller shape than the same shell left limp, bit-stable across runs\n", .{});
    return true;
}

/// Proves a free soft body colliding with rigid geometry: an unpinned shell
/// dropped on a floor holds a full shape when firm but collapses flat when
/// limp, so pressure resists the deformation the impact and gravity apply,
/// each bit-stable across runs.
fn provePhysicsSoftBody(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var firm_settled: []u8 = &.{};
    defer if (firm_settled.len > 0) gpa.free(firm_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/soft-firm");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            firm_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the firm soft body is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const squish_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/soft-squish");
    defer gpa.free(squish_settled);
    if (std.mem.eql(u8, firm_settled, squish_settled)) {
        std.debug.print("conformance: FAIL the firm soft body settled the same as the limp one\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a firm soft body holds its shape on a floor where a limp one collapses flat, bit-stable across runs\n", .{});
    return true;
}

/// Proves 2D physics: a planar body on a z-sloped incline is confined to the
/// z plane and rests in view where the same body free in 3D slides off in z, so
/// the planar constraint drives a 2D world, each bit-stable across runs.
fn provePhysicsPlanar(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var planar_settled: []u8 = &.{};
    defer if (planar_settled.len > 0) gpa.free(planar_settled);
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const shot = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-planar");
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            planar_settled = shot;
        } else {
            defer gpa.free(shot);
            if (!std.mem.eql(u8, &first_hash, &hash)) {
                std.debug.print("conformance: FAIL the planar body is not bit-stable across runs\n", .{});
                return false;
            }
        }
    }
    const free_settled = try settledPhysicsCapture(gpa, engine, ".lens-packages/physics-free3d");
    defer gpa.free(free_settled);
    if (std.mem.eql(u8, planar_settled, free_settled)) {
        std.debug.print("conformance: FAIL the planar body settled the same as the free 3D one\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a planar body holds in the z plane where the same body free in 3D slides off in z, bit-stable across runs\n", .{});
    return true;
}

/// Proves lens cloth: a simulated flag drapes under gravity across
/// advancing frames, the settled frame differs from the initial, and
/// two runs land bit-identical.
fn proveClothFlag(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/cloth-flag", ".lens-packages/cloth-flag".len) != .ok) {
            std.debug.print("conformance: FAIL cloth lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the cloth did not drape\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-cloth-flag.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL cloth is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a simulated cloth flag drapes deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves lens particles: the fountain emits and falls deterministically over
/// frames, the settled frame differing from the initial and bit-stable across
/// two runs.
fn proveParticles(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/sparkles", ".lens-packages/sparkles".len) != .ok) {
            std.debug.print("conformance: FAIL particle lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the particles did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-sparkles.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL particles are not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a particle fountain emits and falls deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves the fading-particle path: the ember-fountain lens sets fade, so each
/// point is alpha-blended by its remaining life through the particle program
/// rather than drawn opaque. The fountain still develops (settled differs from
/// initial) and the whole thing is bit-stable across runs.
fn proveEmber(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/ember-fountain", ".lens-packages/ember-fountain".len) != .ok) {
            std.debug.print("conformance: FAIL ember lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the ember fountain did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-ember-fountain.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL the ember fountain is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a fading particle fountain alpha-blends each point by its life deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves a textured particle sprite: the star-fountain lens loads its own
/// assets/star.png at activation and textures each fading sprite with it, so
/// the fountain develops (settled differs from initial) and is bit-stable
/// across runs - the sprite-texture path, beyond the built-in round default.
fn proveStarSprite(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/star-fountain", ".lens-packages/star-fountain".len) != .ok) {
            std.debug.print("conformance: FAIL star-fountain lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the star fountain did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL the star fountain is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a textured particle sprite loads its own image and renders deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves the emission-pattern, force and colour surface renders: rain snow
/// (drag, turbulence, pale, slow) and a spinning size-shrinking burst of
/// confetti each develop, stay bit-stable across runs, and render a picture
/// distinct from each other.
fn proveParticlePatterns(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const lenses = [_][]const u8{ ".lens-packages/snow-fall", ".lens-packages/confetti-burst" };
    var settled: [2][]u8 = .{ &.{}, &.{} };
    defer for (settled) |s| if (s.len > 0) gpa.free(s);

    for (lenses, 0..) |pkg, lens_idx| {
        var first_hash: [64]u8 = undefined;
        var runs: u32 = 0;
        while (runs < 2) : (runs += 1) {
            const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(engine);
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL particle-pattern lens activation\n", .{});
                return false;
            }
            const corpus = try loadCorpusFrame(gpa, corpus_path);
            defer corpus.deinit();
            const planes = try rgbaToNv12(gpa, corpus.frame);
            defer planes.deinit(gpa);
            const half_w = (planes.width + 1) / 2;

            var initial_shot: []u8 = &.{};
            defer if (initial_shot.len > 0) gpa.free(initial_shot);
            var this_settled: []u8 = &.{};
            defer if (this_settled.len > 0) gpa.free(this_settled);

            for (0..90) |i| {
                const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
                if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
                _ = abi.goss_engine_render_frame(engine, session);
                c.glfwPollEvents();
                if (i == 2 or i == 85) {
                    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                    errdefer gpa.free(shot);
                    var w: u32 = 0;
                    var h: u32 = 0;
                    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) {
                        gpa.free(shot);
                        return false;
                    }
                    if (i == 2) initial_shot = shot else this_settled = shot;
                }
            }
            if (std.mem.eql(u8, initial_shot, this_settled)) {
                std.debug.print("conformance: FAIL a particle pattern did not move\n", .{});
                return false;
            }
            var digest: [32]u8 = undefined;
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(this_settled);
            hasher.final(&digest);
            const hash = std.fmt.bytesToHex(digest, .lower);
            if (runs == 0) {
                first_hash = hash;
            } else {
                if (!std.mem.eql(u8, &first_hash, &hash)) {
                    std.debug.print("conformance: FAIL a particle pattern is not bit-stable across runs\n", .{});
                    return false;
                }
                settled[lens_idx] = this_settled;
                this_settled = &.{};
            }
        }
    }
    if (std.mem.eql(u8, settled[0], settled[1])) {
        std.debug.print("conformance: FAIL snow and confetti rendered the same picture\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, settled[0], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-snow-fall.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF emission patterns, forces and colour render distinctly (rain snow vs spinning burst confetti), each bit-stable across runs\n", .{});
    return true;
}

/// Proves particle trails: the comet-trail lens draws each particle's recent
/// positions as a fading tail behind it, so its settled frame differs from the
/// comet-plain lens - identical particles with the trail off - which draws only
/// the heads. Both stay bit-stable across runs.
fn proveParticleTrail(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const lenses = [_][]const u8{ ".lens-packages/comet-trail", ".lens-packages/comet-plain" };
    var settled: [2][]u8 = .{ &.{}, &.{} };
    defer for (settled) |s| if (s.len > 0) gpa.free(s);

    for (lenses, 0..) |pkg, lens_idx| {
        var first_hash: [64]u8 = undefined;
        var runs: u32 = 0;
        while (runs < 2) : (runs += 1) {
            const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(engine);
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL comet lens activation\n", .{});
                return false;
            }
            const corpus = try loadCorpusFrame(gpa, corpus_path);
            defer corpus.deinit();
            const planes = try rgbaToNv12(gpa, corpus.frame);
            defer planes.deinit(gpa);
            const half_w = (planes.width + 1) / 2;

            var this_settled: []u8 = &.{};
            defer if (this_settled.len > 0) gpa.free(this_settled);

            for (0..90) |i| {
                const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
                if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
                _ = abi.goss_engine_render_frame(engine, session);
                c.glfwPollEvents();
                if (i == 85) {
                    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                    errdefer gpa.free(shot);
                    var w: u32 = 0;
                    var h: u32 = 0;
                    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) {
                        gpa.free(shot);
                        return false;
                    }
                    this_settled = shot;
                }
            }
            var digest: [32]u8 = undefined;
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(this_settled);
            hasher.final(&digest);
            const hash = std.fmt.bytesToHex(digest, .lower);
            if (runs == 0) {
                first_hash = hash;
            } else {
                if (!std.mem.eql(u8, &first_hash, &hash)) {
                    std.debug.print("conformance: FAIL a comet lens is not bit-stable across runs\n", .{});
                    return false;
                }
                settled[lens_idx] = this_settled;
                this_settled = &.{};
            }
        }
    }
    if (std.mem.eql(u8, settled[0], settled[1])) {
        std.debug.print("conformance: FAIL the trail drew nothing the plain comet did not\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF particle trails draw a fading tail: the trailed comet differs from the same comet with no trail, each bit-stable\n", .{});
    return true;
}

/// Proves the prebuilt VFX asset library: a node whose particles name only the
/// `fire` preset renders exactly the same frame as the hand-tuned flame lens, so
/// the preset expands to the curated config, each bit-stable across runs.
fn provePresetLibrary(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const lenses = [_][]const u8{ ".lens-packages/preset-fire", ".lens-packages/flame-curl" };
    var settled: [2][]u8 = .{ &.{}, &.{} };
    defer for (settled) |s| if (s.len > 0) gpa.free(s);
    for (lenses, 0..) |pkg, lens_idx| {
        var first_hash: [64]u8 = undefined;
        var runs: u32 = 0;
        while (runs < 2) : (runs += 1) {
            const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(engine);
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL preset lens activation\n", .{});
                return false;
            }
            const corpus = try loadCorpusFrame(gpa, corpus_path);
            defer corpus.deinit();
            const planes = try rgbaToNv12(gpa, corpus.frame);
            defer planes.deinit(gpa);
            const half_w = (planes.width + 1) / 2;
            var this_settled: []u8 = &.{};
            defer if (this_settled.len > 0) gpa.free(this_settled);
            for (0..90) |i| {
                const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
                if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
                _ = abi.goss_engine_render_frame(engine, session);
                c.glfwPollEvents();
                if (i == 85) {
                    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                    errdefer gpa.free(shot);
                    var w: u32 = 0;
                    var h: u32 = 0;
                    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) {
                        gpa.free(shot);
                        return false;
                    }
                    this_settled = shot;
                }
            }
            var digest: [32]u8 = undefined;
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(this_settled);
            hasher.final(&digest);
            const hash = std.fmt.bytesToHex(digest, .lower);
            if (runs == 0) {
                first_hash = hash;
            } else {
                if (!std.mem.eql(u8, &first_hash, &hash)) {
                    std.debug.print("conformance: FAIL a preset lens is not bit-stable across runs\n", .{});
                    return false;
                }
                settled[lens_idx] = this_settled;
                this_settled = &.{};
            }
        }
    }
    if (!std.mem.eql(u8, settled[0], settled[1])) {
        std.debug.print("conformance: FAIL the fire preset did not expand to the hand-tuned flame config\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF the fire VFX preset renders identically to the hand-tuned flame lens, bit-stable across runs\n", .{});
    return true;
}

/// The fraction of pixels where any channel differs by more than `delta`.
fn frameDiffFraction(a: []const u8, b: []const u8, delta: u8) f32 {
    if (a.len != b.len or a.len == 0) return 1.0;
    var differing: usize = 0;
    var i: usize = 0;
    while (i + 4 <= a.len) : (i += 4) {
        const dr = if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i];
        const dg = if (a[i + 1] > b[i + 1]) a[i + 1] - b[i + 1] else b[i + 1] - a[i + 1];
        const db = if (a[i + 2] > b[i + 2]) a[i + 2] - b[i + 2] else b[i + 2] - a[i + 2];
        if (dr > delta or dg > delta or db > delta) differing += 1;
    }
    return @as(f32, @floatFromInt(differing)) / @as(f32, @floatFromInt(a.len / 4));
}

fn captureFountain(gpa: std.mem.Allocator, engine: *abi.Engine, pkg: []const u8) !?[]u8 {
    return captureFountainAtFrame(gpa, engine, pkg, 85);
}

fn captureFountainAtFrame(gpa: std.mem.Allocator, engine: *abi.Engine, pkg: []const u8, capture_frame: usize) !?[]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) return null;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    var settled: []u8 = &.{};
    errdefer if (settled.len > 0) gpa.free(settled);
    for (0..90) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == capture_frame) {
            settled = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, settled.ptr, settled.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return settled;
}

/// Proves the GPU-compute particle path: a fountain simmed on the GPU renders a
/// stable frame that closely tracks the same fountain simmed on the CPU (they
/// share the emit and integration math, off only by GPU float rounding), so the
/// compute path stays in sync with the deterministic baseline.
fn proveGpuParticles(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // First confirm the GPU compute path is actually taken here; a backend
    // without compute falls back to the CPU sim, which is already proven.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const pkg = ".lens-packages/gpu-fountain";
        if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) return false;
        if (abi.activeGpuParticleSims(session) == 0) {
            std.debug.print("conformance: gpu-particles skipped - no compute backend here, the CPU sim runs and is already proven\n", .{});
            return true;
        }
    }
    const gpu0 = (try captureFountain(gpa, engine, ".lens-packages/gpu-fountain")) orelse return false;
    defer gpa.free(gpu0);
    const gpu1 = (try captureFountain(gpa, engine, ".lens-packages/gpu-fountain")) orelse return false;
    defer gpa.free(gpu1);
    if (!std.mem.eql(u8, gpu0, gpu1)) {
        std.debug.print("conformance: FAIL the GPU fountain is not stable across runs\n", .{});
        return false;
    }
    const cpu = (try captureFountain(gpa, engine, ".lens-packages/cpu-fountain")) orelse return false;
    defer gpa.free(cpu);
    // The GPU and CPU share the emit and integration math, so their frames
    // track within GPU float rounding (here they land pixel-identical).
    if (frameDiffFraction(gpu0, cpu, 16) > 0.15) {
        std.debug.print("conformance: FAIL the GPU fountain does not track the CPU fountain\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a GPU-compute fountain renders on the compute path, stable across runs and tracking the CPU fountain\n", .{});
    return true;
}

/// Proves the GPU compute path runs the force set beyond gravity: the exact-op
/// forces (drag, wind, an attractor, a vortex) drive the fountain far from plain
/// gravity yet pixel-identical to the CPU, and turbulence and curl churn the
/// compute render further. Bit-stable across runs.
fn proveGpuForces(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const pkg = ".lens-packages/gpu-swirl";
        if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) return false;
        if (abi.activeGpuParticleSims(session) == 0) {
            std.debug.print("conformance: gpu-forces skipped - no compute backend here, the CPU sim runs and is already proven\n", .{});
            return true;
        }
    }
    const gpu0 = (try captureFountainAtFrame(gpa, engine, ".lens-packages/gpu-swirl", 55)) orelse return false;
    defer gpa.free(gpu0);
    const gpu1 = (try captureFountainAtFrame(gpa, engine, ".lens-packages/gpu-swirl", 55)) orelse return false;
    defer gpa.free(gpu1);
    if (!std.mem.eql(u8, gpu0, gpu1)) {
        std.debug.print("conformance: FAIL the GPU swirl is not stable across runs\n", .{});
        return false;
    }
    const plain = (try captureFountainAtFrame(gpa, engine, ".lens-packages/gpu-fountain", 55)) orelse return false;
    defer gpa.free(plain);
    const cpu = (try captureFountainAtFrame(gpa, engine, ".lens-packages/cpu-swirl", 55)) orelse return false;
    defer gpa.free(cpu);
    const churn = (try captureFountainAtFrame(gpa, engine, ".lens-packages/gpu-churn", 55)) orelse return false;
    defer gpa.free(churn);
    // The exact-op force set (drag, wind, an attractor and a vortex) drives the
    // fountain into a form far from plain gravity.
    if (frameDiffFraction(gpu0, plain, 16) < 0.15) {
        std.debug.print("conformance: FAIL the GPU force set did not visibly change the fountain from plain gravity\n", .{});
        return false;
    }
    // Those forces are exact float ops, so the GPU compute path lands pixel-for-
    // pixel on the CPU sim running the identical config.
    if (frameDiffFraction(gpu0, cpu, 16) > 0.005) {
        std.debug.print("conformance: FAIL the GPU swirl does not track the CPU swirl\n", .{});
        return false;
    }
    // Turbulence and curl (transcendental forces) also drive the compute path:
    // adding them to the same swirl visibly churns the render.
    if (frameDiffFraction(churn, gpu0, 16) < 0.03) {
        std.debug.print("conformance: FAIL turbulence and curl did not act on the GPU compute path\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF the GPU compute path runs the force set beyond gravity - drag, wind, an attractor and a vortex driving the fountain far from plain gravity and pixel-identical to the CPU, with turbulence and curl churning it further\n", .{});
    return true;
}

/// Proves the sub-emitter: a firework whose shells burst into child sparks
/// renders a different frame from the same emitter with no sub-emitter, so the
/// children the parents spawn on death are drawn, each bit-stable across runs.
fn proveSubEmitter(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const lenses = [_][]const u8{ ".lens-packages/firework-burst", ".lens-packages/firework-plain" };
    var settled: [2][]u8 = .{ &.{}, &.{} };
    defer for (settled) |s| if (s.len > 0) gpa.free(s);
    for (lenses, 0..) |pkg, lens_idx| {
        var first_hash: [64]u8 = undefined;
        var runs: u32 = 0;
        while (runs < 2) : (runs += 1) {
            const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(engine);
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL firework lens activation\n", .{});
                return false;
            }
            const corpus = try loadCorpusFrame(gpa, corpus_path);
            defer corpus.deinit();
            const planes = try rgbaToNv12(gpa, corpus.frame);
            defer planes.deinit(gpa);
            const half_w = (planes.width + 1) / 2;
            var this_settled: []u8 = &.{};
            defer if (this_settled.len > 0) gpa.free(this_settled);
            for (0..90) |i| {
                const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
                if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
                _ = abi.goss_engine_render_frame(engine, session);
                c.glfwPollEvents();
                if (i == 85) {
                    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                    errdefer gpa.free(shot);
                    var w: u32 = 0;
                    var h: u32 = 0;
                    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) {
                        gpa.free(shot);
                        return false;
                    }
                    this_settled = shot;
                }
            }
            var digest: [32]u8 = undefined;
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(this_settled);
            hasher.final(&digest);
            const hash = std.fmt.bytesToHex(digest, .lower);
            if (runs == 0) {
                first_hash = hash;
            } else {
                if (!std.mem.eql(u8, &first_hash, &hash)) {
                    std.debug.print("conformance: FAIL a firework lens is not bit-stable across runs\n", .{});
                    return false;
                }
                settled[lens_idx] = this_settled;
                this_settled = &.{};
            }
        }
    }
    if (std.mem.eql(u8, settled[0], settled[1])) {
        std.debug.print("conformance: FAIL the sub-emitter drew nothing the plain firework did not\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a sub-emitter bursts child sparks: the firework differs from the same emitter with no sub-emitter, each bit-stable\n", .{});
    return true;
}

/// Proves particle sphere colliders: the collide-sphere lens drops rain onto a
/// sphere the particles bounce off, so its settled frame differs from the
/// collide-none lens - the same rain with no collider - which falls straight
/// through. Both stay bit-stable across runs.
fn proveParticleCollider(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const lenses = [_][]const u8{ ".lens-packages/collide-sphere", ".lens-packages/collide-none" };
    var settled: [2][]u8 = .{ &.{}, &.{} };
    defer for (settled) |s| if (s.len > 0) gpa.free(s);

    for (lenses, 0..) |pkg, lens_idx| {
        var first_hash: [64]u8 = undefined;
        var runs: u32 = 0;
        while (runs < 2) : (runs += 1) {
            const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(engine);
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL collide lens activation\n", .{});
                return false;
            }
            const corpus = try loadCorpusFrame(gpa, corpus_path);
            defer corpus.deinit();
            const planes = try rgbaToNv12(gpa, corpus.frame);
            defer planes.deinit(gpa);
            const half_w = (planes.width + 1) / 2;

            var this_settled: []u8 = &.{};
            defer if (this_settled.len > 0) gpa.free(this_settled);

            for (0..90) |i| {
                const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
                if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
                _ = abi.goss_engine_render_frame(engine, session);
                c.glfwPollEvents();
                if (i == 85) {
                    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                    errdefer gpa.free(shot);
                    var w: u32 = 0;
                    var h: u32 = 0;
                    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) {
                        gpa.free(shot);
                        return false;
                    }
                    this_settled = shot;
                }
            }
            var digest: [32]u8 = undefined;
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(this_settled);
            hasher.final(&digest);
            const hash = std.fmt.bytesToHex(digest, .lower);
            if (runs == 0) {
                first_hash = hash;
            } else {
                if (!std.mem.eql(u8, &first_hash, &hash)) {
                    std.debug.print("conformance: FAIL a collide lens is not bit-stable across runs\n", .{});
                    return false;
                }
                settled[lens_idx] = this_settled;
                this_settled = &.{};
            }
        }
    }
    if (std.mem.eql(u8, settled[0], settled[1])) {
        std.debug.print("conformance: FAIL the sphere collider deflected nothing\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF particle sphere colliders deflect the sim: rain onto a collider differs from the same rain with none, each bit-stable\n", .{});
    return true;
}

/// Proves 3D-mesh particles: the mesh-orbs lens draws each particle as a small
/// 3D octahedron, so its settled frame differs from the mesh-orbs-flat lens -
/// the same fountain drawn as flat billboards. Both stay bit-stable across
/// runs.
fn proveMeshParticles(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const lenses = [_][]const u8{ ".lens-packages/mesh-orbs", ".lens-packages/mesh-orbs-flat" };
    var settled: [2][]u8 = .{ &.{}, &.{} };
    defer for (settled) |s| if (s.len > 0) gpa.free(s);

    for (lenses, 0..) |pkg, lens_idx| {
        var first_hash: [64]u8 = undefined;
        var runs: u32 = 0;
        while (runs < 2) : (runs += 1) {
            const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(engine);
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL mesh-orbs lens activation\n", .{});
                return false;
            }
            const corpus = try loadCorpusFrame(gpa, corpus_path);
            defer corpus.deinit();
            const planes = try rgbaToNv12(gpa, corpus.frame);
            defer planes.deinit(gpa);
            const half_w = (planes.width + 1) / 2;

            var this_settled: []u8 = &.{};
            defer if (this_settled.len > 0) gpa.free(this_settled);

            for (0..90) |i| {
                const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
                if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
                _ = abi.goss_engine_render_frame(engine, session);
                c.glfwPollEvents();
                if (i == 85) {
                    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                    errdefer gpa.free(shot);
                    var w: u32 = 0;
                    var h: u32 = 0;
                    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) {
                        gpa.free(shot);
                        return false;
                    }
                    this_settled = shot;
                }
            }
            var digest: [32]u8 = undefined;
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(this_settled);
            hasher.final(&digest);
            const hash = std.fmt.bytesToHex(digest, .lower);
            if (runs == 0) {
                first_hash = hash;
            } else {
                if (!std.mem.eql(u8, &first_hash, &hash)) {
                    std.debug.print("conformance: FAIL a mesh-orbs lens is not bit-stable across runs\n", .{});
                    return false;
                }
                settled[lens_idx] = this_settled;
                this_settled = &.{};
            }
        }
    }
    if (std.mem.eql(u8, settled[0], settled[1])) {
        std.debug.print("conformance: FAIL mesh particles rendered the same as flat billboards\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF 3D-mesh particles draw as solid shapes: mesh orbs render differently from the same fountain as flat billboards, each bit-stable\n", .{});
    return true;
}

/// Proves particle ribbons: the ribbon-comet lens draws each particle's trail
/// history as one solid connected strip, so its settled frame differs from the
/// ribbon-comet-bb lens - the same trail drawn as separate fading billboards.
/// Both stay bit-stable across runs.
fn proveRibbon(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const lenses = [_][]const u8{ ".lens-packages/ribbon-comet", ".lens-packages/ribbon-comet-bb" };
    var settled: [2][]u8 = .{ &.{}, &.{} };
    defer for (settled) |s| if (s.len > 0) gpa.free(s);

    for (lenses, 0..) |pkg, lens_idx| {
        var first_hash: [64]u8 = undefined;
        var runs: u32 = 0;
        while (runs < 2) : (runs += 1) {
            const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(engine);
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL ribbon-comet lens activation\n", .{});
                return false;
            }
            const corpus = try loadCorpusFrame(gpa, corpus_path);
            defer corpus.deinit();
            const planes = try rgbaToNv12(gpa, corpus.frame);
            defer planes.deinit(gpa);
            const half_w = (planes.width + 1) / 2;

            var this_settled: []u8 = &.{};
            defer if (this_settled.len > 0) gpa.free(this_settled);

            for (0..90) |i| {
                const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
                if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
                _ = abi.goss_engine_render_frame(engine, session);
                c.glfwPollEvents();
                if (i == 85) {
                    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                    errdefer gpa.free(shot);
                    var w: u32 = 0;
                    var h: u32 = 0;
                    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) {
                        gpa.free(shot);
                        return false;
                    }
                    this_settled = shot;
                }
            }
            var digest: [32]u8 = undefined;
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(this_settled);
            hasher.final(&digest);
            const hash = std.fmt.bytesToHex(digest, .lower);
            if (runs == 0) {
                first_hash = hash;
            } else {
                if (!std.mem.eql(u8, &first_hash, &hash)) {
                    std.debug.print("conformance: FAIL a ribbon-comet lens is not bit-stable across runs\n", .{});
                    return false;
                }
                settled[lens_idx] = this_settled;
                this_settled = &.{};
            }
        }
    }
    if (std.mem.eql(u8, settled[0], settled[1])) {
        std.debug.print("conformance: FAIL the ribbon rendered the same as separate billboards\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF particle ribbons draw a solid strip: the ribbon comet renders differently from the same trail as separate billboards, each bit-stable\n", .{});
    return true;
}

/// Proves the AR spawn off tracked landmarks: the face-sparkle lens uses the face
/// emission pattern, so particles spawn from the tracked face landmarks. With
/// face tracking on the portrait corpus it develops (settled differs from
/// initial) and is bit-stable across runs.
fn proveFaceSparkle(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) return error.EnableFaceTrackingFailed;
        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/face-sparkle", ".lens-packages/face-sparkle".len) != .ok) {
            std.debug.print("conformance: FAIL face-sparkle lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                var w: u32 = 0;
                var h: u32 = 0;
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL face-sparkle did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-face-sparkle.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL face-sparkle is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF particles spawn from tracked face landmarks (the AR face pattern) and render deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves a post-effect lens activates from raw json, no bundle directory:
/// goss_session_activate_lens on a blur.pass manifest builds the composite
/// chain (the asset-free path the web uses), so the capture differs from the
/// plain frame and is bit-stable - post-effects reach the browser too.
fn proveJsonPostEffect(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const blur_manifest =
        \\{"glf":"1.0","id":"goss.test.json-blur","version":"1.0.0","display_name":"JSON Blur","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"b","type":"blur.pass","inputs":{"frame":"camera"},"params":{}}],"triggers":[]}
    ;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (0..3) |run| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (run > 0) {
            if (abi.goss_session_activate_lens(session, blur_manifest.ptr, blur_manifest.len) != .ok) {
                std.debug.print("conformance: FAIL json blur activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL json post-effect is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL a json-activated blur.pass did not change the frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a post-effect lens activates from raw json and renders deterministically, no bundle directory needed\n", .{});
    return true;
}

/// Proves a particle fountain runs from raw json: goss_session_activate_lens
/// on a particles manifest builds the CPU fountain and its sprite mesh with
/// no bundle directory (the path the web uses), so the fountain develops
/// (settled differs from initial) and is bit-stable across runs.
fn proveJsonParticles(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const particle_manifest =
        \\{"glf":"1.0","id":"goss.test.json-particles","version":"1.0.0","display_name":"JSON Particles","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"p","type":"model.gltf","inputs":{"frame":"camera"},"params":{},"particles":{"count":150,"gravity":3.0,"speed":0.5,"lifetime":1.5,"fade":true,"size":10}}],"triggers":[]}
    ;
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens(session, particle_manifest.ptr, particle_manifest.len) != .ok) {
            std.debug.print("conformance: FAIL json particle activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the json particle fountain did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL the json particle fountain is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a particle fountain runs from raw json and renders deterministically, no bundle directory needed\n", .{});
    return true;
}

/// Proves the whole node graph composes in one lens: studio-full runs a
/// beauty.face smooth, then grade.pass, bloom.pass and a fading ember fountain
/// over the same frame; its settled capture differs from the plain frame and
/// is bit-stable - beauty, post-effects and particles coexisting in one pass.
fn proveFullStack(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/studio-full", ".lens-packages/studio-full" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL studio-full lens activation\n", .{});
                return false;
            }
        }
        var shot: []u8 = &.{};
        errdefer if (shot.len > 0) gpa.free(shot);
        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    return error.CaptureFailed;
                }
            }
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL the full stack is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL the full stack did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-studio-full.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF beauty, grade, bloom and a fading particle fountain compose in one lens deterministically, differing from the plain frame\n", .{});
    return true;
}

/// Proves a blur.pass post-effect: the built-in separable blur softens the
/// frame, so a blurred capture differs from the un-blurred one and is
/// bit-stable across runs (no asset, always ready).
fn proveBlur(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/soft-blur", ".lens-packages/soft-blur" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL blur lens activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL blur is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL blur.pass did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-soft-blur.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF a blur.pass softens the frame deterministically, differing from the un-blurred capture\n", .{});
    return true;
}

/// Proves a grade.pass post-effect: the parametric color grade shifts the
/// frame (warm, brighter, more contrast), so a graded capture differs from
/// the un-graded one and is bit-stable across runs (no asset, ready at
/// activation).
fn proveGrade(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/warm-grade", ".lens-packages/warm-grade" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL grade lens activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL grade is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL grade.pass did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-warm-grade.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF a grade.pass shifts the frame's color deterministically, differing from the un-graded capture\n", .{});
    return true;
}

/// Proves the grade.pass color adjustments: a grayscale grade collapses
/// every pixel's chroma so its channels read equal, and an invert grade
/// flips the frame so each channel reads its complement against the
/// identity grade. Both are deterministic and bit-stable across runs.
fn proveColorAdjust(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_][]const u8{
        ".lens-packages/plain-grade",
        ".lens-packages/plain-grade",
        ".lens-packages/mono-grade",
        ".lens-packages/negative-grade",
    };
    var shots: [4][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
            std.debug.print("conformance: FAIL color adjust lens activation\n", .{});
            return false;
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }

    if (!std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL grade color adjust is not bit-stable across runs\n", .{});
        return false;
    }

    // Grayscale collapses chroma: every pixel's channels read one gray.
    var mono_spread: u8 = 0;
    var i: usize = 0;
    while (i < shots[2].len) : (i += 4) {
        const r = shots[2][i];
        const g = shots[2][i + 1];
        const b = shots[2][i + 2];
        const rg = if (r > g) r - g else g - r;
        const gb = if (g > b) g - b else b - g;
        if (rg > mono_spread) mono_spread = rg;
        if (gb > mono_spread) mono_spread = gb;
    }
    if (mono_spread > 1) {
        std.debug.print("conformance: FAIL grayscale grade left chroma (max channel spread {d})\n", .{mono_spread});
        return false;
    }
    if (std.mem.eql(u8, shots[2], shots[0])) {
        std.debug.print("conformance: FAIL grayscale grade did not change the frame\n", .{});
        return false;
    }

    // Invert reads each channel as its complement against the identity grade,
    // so an inverted byte plus the identity byte sums to 255.
    var max_flip_err: u32 = 0;
    i = 0;
    while (i < shots[3].len) : (i += 4) {
        for ([_]usize{ 0, 1, 2 }) |ch| {
            const sum = @as(u32, shots[3][i + ch]) + @as(u32, shots[0][i + ch]);
            const err = if (sum > 255) sum - 255 else 255 - sum;
            if (err > max_flip_err) max_flip_err = err;
        }
    }
    if (max_flip_err > 2) {
        std.debug.print("conformance: FAIL invert grade is not the frame's complement (max error {d})\n", .{max_flip_err});
        return false;
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[2], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-mono-grade.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF grade.pass color adjustments collapse chroma to gray and invert to the frame's complement deterministically\n", .{});
    return true;
}

/// Captures one lens (or the plain frame when pkg is null) over the corpus:
/// three settle frames then a readback, the shared body proveStylize's
/// per-mode checks run on. The caller owns the returned RGBA8 buffer.
fn captureStylizeShot(gpa: std.mem.Allocator, engine: *abi.Engine, planes: Nv12Copy, pkg: ?[]const u8) ![]u8 {
    const half_w = (planes.width + 1) / 2;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (pkg) |p| {
        if (abi.goss_session_activate_lens_from_directory(session, p.ptr, p.len) != .ok) {
            std.debug.print("conformance: FAIL stylize lens activation {s}\n", .{p});
            return error.ActivationFailed;
        }
    }
    for (0..3) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var shot_width: u32 = 0;
    var shot_height: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
        return error.CaptureFailed;
    }
    return shot;
}

fn lumaByte(r: u8, g: u8, b: u8) u8 {
    return @intCast((@as(u32, r) * 54 + @as(u32, g) * 183 + @as(u32, b) * 19) >> 8);
}

/// The largest gap between a pixel's channels anywhere in the frame - zero
/// for a monochrome image (equal channels), large for a colour one.
fn maxChannelSpread(buf: []const u8) u8 {
    var spread: u8 = 0;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 4) {
        const r = buf[i];
        const g = buf[i + 1];
        const b = buf[i + 2];
        const rg = if (r > g) r - g else g - r;
        const gb = if (g > b) g - b else b - g;
        if (rg > spread) spread = rg;
        if (gb > spread) spread = gb;
    }
    return spread;
}

/// How many distinct byte values one channel takes across the frame - a
/// quantized image collapses to a handful, a photo spans most of the range.
fn distinctChannelValues(buf: []const u8, channel: usize) usize {
    var seen = [_]bool{false} ** 256;
    var i: usize = channel;
    while (i < buf.len) : (i += 4) seen[buf[i]] = true;
    var n: usize = 0;
    for (seen) |s| {
        if (s) n += 1;
    }
    return n;
}

/// The mean of every RGB byte in the frame - near 128 for a mid-grey relief.
fn meanRgbByte(buf: []const u8) u32 {
    var sum: u64 = 0;
    var count: u64 = 0;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 4) {
        sum += @as(u64, buf[i]) + buf[i + 1] + buf[i + 2];
        count += 3;
    }
    if (count == 0) return 0;
    return @intCast(sum / count);
}

/// The fraction of pixels whose luma sits at one extreme - near 1.0 for an
/// ink-on-paper image, low for a continuous-tone one.
fn nearBinaryFraction(buf: []const u8) f32 {
    var near: usize = 0;
    var total: usize = 0;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 4) {
        const l = lumaByte(buf[i], buf[i + 1], buf[i + 2]);
        if (l < 24 or l > 232) near += 1;
        total += 1;
    }
    if (total == 0) return 0;
    return @as(f32, @floatFromInt(near)) / @as(f32, @floatFromInt(total));
}

/// Proves the stylize.pass modes, each with a signature only that filter
/// makes, captured twice for bit-stability: sketch reduces to a monochrome
/// pencil, toon quantizes each channel to a few levels, emboss recenters on
/// mid-grey, and crosshatch binarizes to ink and paper.
fn proveStylize(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    const control = try captureStylizeShot(gpa, engine, planes, null);
    defer gpa.free(control);
    const control_reds = distinctChannelValues(control, 0);

    {
        const a = try captureStylizeShot(gpa, engine, planes, ".lens-packages/sketch");
        defer gpa.free(a);
        const b = try captureStylizeShot(gpa, engine, planes, ".lens-packages/sketch");
        defer gpa.free(b);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("conformance: FAIL sketch is not bit-stable across runs\n", .{});
            return false;
        }
        if (std.mem.eql(u8, a, control)) {
            std.debug.print("conformance: FAIL sketch did not change the frame\n", .{});
            return false;
        }
        const spread = maxChannelSpread(a);
        if (spread > 2) {
            std.debug.print("conformance: FAIL sketch is not monochrome (channel spread {d})\n", .{spread});
            return false;
        }
    }

    {
        const a = try captureStylizeShot(gpa, engine, planes, ".lens-packages/toon");
        defer gpa.free(a);
        const b = try captureStylizeShot(gpa, engine, planes, ".lens-packages/toon");
        defer gpa.free(b);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("conformance: FAIL toon is not bit-stable across runs\n", .{});
            return false;
        }
        if (std.mem.eql(u8, a, control)) {
            std.debug.print("conformance: FAIL toon did not change the frame\n", .{});
            return false;
        }
        const reds = distinctChannelValues(a, 0);
        if (reds > 40 or reds * 2 >= control_reds) {
            std.debug.print("conformance: FAIL toon did not quantize (distinct reds {d} vs frame {d})\n", .{ reds, control_reds });
            return false;
        }
    }

    {
        const a = try captureStylizeShot(gpa, engine, planes, ".lens-packages/emboss");
        defer gpa.free(a);
        const b = try captureStylizeShot(gpa, engine, planes, ".lens-packages/emboss");
        defer gpa.free(b);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("conformance: FAIL emboss is not bit-stable across runs\n", .{});
            return false;
        }
        if (std.mem.eql(u8, a, control)) {
            std.debug.print("conformance: FAIL emboss did not change the frame\n", .{});
            return false;
        }
        const mean = meanRgbByte(a);
        if (mean < 108 or mean > 148) {
            std.debug.print("conformance: FAIL emboss is not centered on mid-grey (mean {d})\n", .{mean});
            return false;
        }
    }

    var hatch_shot: ?[]u8 = null;
    defer if (hatch_shot) |h| gpa.free(h);
    {
        const a = try captureStylizeShot(gpa, engine, planes, ".lens-packages/crosshatch");
        hatch_shot = a;
        const b = try captureStylizeShot(gpa, engine, planes, ".lens-packages/crosshatch");
        defer gpa.free(b);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("conformance: FAIL crosshatch is not bit-stable across runs\n", .{});
            return false;
        }
        if (std.mem.eql(u8, a, control)) {
            std.debug.print("conformance: FAIL crosshatch did not change the frame\n", .{});
            return false;
        }
        const spread = maxChannelSpread(a);
        const binary = nearBinaryFraction(a);
        if (spread > 2 or binary < 0.80) {
            std.debug.print("conformance: FAIL crosshatch is not ink-on-paper (spread {d}, binary {d:.2})\n", .{ spread, binary });
            return false;
        }
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, hatch_shot.?, 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-crosshatch.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF stylize.pass filters are deterministic - sketch monochrome, toon quantized, emboss mid-grey, crosshatch ink-on-paper\n", .{});
    return true;
}

/// The fraction of pixels lit as an edge - luma above the midpoint. An edge
/// map is mostly black, so this counts how much of the frame the detector
/// marked, and the same measure lets canny be compared against raw sobel.
fn litFraction(buf: []const u8) f32 {
    var lit: usize = 0;
    var total: usize = 0;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 4) {
        if (lumaByte(buf[i], buf[i + 1], buf[i + 2]) > 128) lit += 1;
        total += 1;
    }
    if (total == 0) return 0;
    return @as(f32, @floatFromInt(lit)) / @as(f32, @floatFromInt(total));
}

/// Proves edge.pass on real content: sobel and canny each turn the frame into a
/// near-monochrome edge map, deterministic across two captures, that lights up on
/// a real portrait but goes almost black on a flat frame. Canny's suppression and
/// hysteresis then leave strictly fewer lit pixels than raw sobel.
fn proveEdge(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    // A flat mid-grey frame the same size: no gradients anywhere, so a faithful
    // detector must return almost pure black. NV12 ignores alpha, so a uniform
    // rgb fill is enough to make the control.
    const flat_rgba = try gpa.alloc(u8, @as(usize, corpus.frame.width) * corpus.frame.height * 4);
    defer gpa.free(flat_rgba);
    @memset(flat_rgba, 128);
    const flat_frame: sampler.Frame = .{ .pixels = .{ .rgba8 = flat_rgba }, .width = corpus.frame.width, .height = corpus.frame.height };
    const flat_planes = try rgbaToNv12(gpa, flat_frame);
    defer flat_planes.deinit(gpa);

    const control = try captureStylizeShot(gpa, engine, planes, null);
    defer gpa.free(control);

    var sobel_lit: f32 = 0;
    {
        const a = try captureStylizeShot(gpa, engine, planes, ".lens-packages/sobel");
        defer gpa.free(a);
        const b = try captureStylizeShot(gpa, engine, planes, ".lens-packages/sobel");
        defer gpa.free(b);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("conformance: FAIL sobel is not bit-stable across runs\n", .{});
            return false;
        }
        if (std.mem.eql(u8, a, control)) {
            std.debug.print("conformance: FAIL sobel did not change the frame\n", .{});
            return false;
        }
        const spread = maxChannelSpread(a);
        if (spread > 2) {
            std.debug.print("conformance: FAIL sobel is not monochrome (channel spread {d})\n", .{spread});
            return false;
        }
        sobel_lit = litFraction(a);
        if (sobel_lit < 0.03) {
            std.debug.print("conformance: FAIL sobel found almost no edges on the corpus (lit {d:.3})\n", .{sobel_lit});
            return false;
        }
        const flat = try captureStylizeShot(gpa, engine, flat_planes, ".lens-packages/sobel");
        defer gpa.free(flat);
        const flat_lit = litFraction(flat);
        if (flat_lit > 0.02) {
            std.debug.print("conformance: FAIL sobel lit a flat frame (lit {d:.3})\n", .{flat_lit});
            return false;
        }
    }

    var canny_shot: ?[]u8 = null;
    defer if (canny_shot) |cs| gpa.free(cs);
    var canny_lit: f32 = 0;
    {
        const a = try captureStylizeShot(gpa, engine, planes, ".lens-packages/canny");
        canny_shot = a;
        const b = try captureStylizeShot(gpa, engine, planes, ".lens-packages/canny");
        defer gpa.free(b);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("conformance: FAIL canny is not bit-stable across runs\n", .{});
            return false;
        }
        if (std.mem.eql(u8, a, control)) {
            std.debug.print("conformance: FAIL canny did not change the frame\n", .{});
            return false;
        }
        const spread = maxChannelSpread(a);
        const binary = nearBinaryFraction(a);
        if (spread > 2 or binary < 0.90) {
            std.debug.print("conformance: FAIL canny is not a near-binary edge map (spread {d}, binary {d:.2})\n", .{ spread, binary });
            return false;
        }
        canny_lit = litFraction(a);
        if (canny_lit < 0.004) {
            std.debug.print("conformance: FAIL canny found almost no edges on the corpus (lit {d:.3})\n", .{canny_lit});
            return false;
        }
        const flat = try captureStylizeShot(gpa, engine, flat_planes, ".lens-packages/canny");
        defer gpa.free(flat);
        const flat_lit = litFraction(flat);
        if (flat_lit > 0.02) {
            std.debug.print("conformance: FAIL canny lit a flat frame (lit {d:.3})\n", .{flat_lit});
            return false;
        }
    }

    if (canny_lit >= sobel_lit) {
        std.debug.print("conformance: FAIL canny is not thinner than sobel (canny {d:.3} vs sobel {d:.3})\n", .{ canny_lit, sobel_lit });
        return false;
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, canny_shot.?, 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-canny.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF edge.pass sobel and canny are deterministic near-binary edge maps, black on a flat frame, canny thinner than sobel ({d:.3} vs {d:.3})\n", .{ canny_lit, sobel_lit });
    return true;
}

/// Renders one warp.pass manifest inline over the corpus and captures it -
/// the from-json mirror of captureStylizeShot, so a proof can hold every
/// warp parameter fixed but the strength and compare the two. A null manifest
/// captures the plain passthrough frame.
fn captureWarpShotJson(gpa: std.mem.Allocator, engine: *abi.Engine, planes: Nv12Copy, manifest_json: ?[]const u8) ![]u8 {
    const half_w = (planes.width + 1) / 2;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (manifest_json) |m| {
        if (abi.goss_session_activate_lens(session, m.ptr, m.len) != .ok) {
            std.debug.print("conformance: FAIL warp lens activation\n", .{});
            return error.ActivationFailed;
        }
    }
    for (0..3) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var shot_width: u32 = 0;
    var shot_height: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
        return error.CaptureFailed;
    }
    return shot;
}

/// True when the top-left corner block of two captures is byte-identical -
/// the region a radial warp centered on the frame must leave untouched, well
/// outside its radius. This is the proof a warp is localized, not global.
fn cornerBlockEqual(a: []const u8, b: []const u8, cap_width: usize, block: usize) bool {
    var y: usize = 0;
    while (y < block) : (y += 1) {
        const row = y * cap_width * 4;
        if (!std.mem.eql(u8, a[row .. row + block * 4], b[row .. row + block * 4])) return false;
    }
    return true;
}

/// True when the center block of two captures differs anywhere - where the
/// warp actually displaces or refracts the image.
fn centerBlockDiffers(a: []const u8, b: []const u8, cap_width: usize, cap_height: usize, block: usize) bool {
    const x0 = cap_width / 2 - block / 2;
    const y0 = cap_height / 2 - block / 2;
    var y: usize = y0;
    while (y < y0 + block) : (y += 1) {
        const start = (y * cap_width + x0) * 4;
        if (!std.mem.eql(u8, a[start .. start + block * 4], b[start .. start + block * 4])) return true;
    }
    return false;
}

/// True when every pixel in the top-left corner block is black - what
/// sphere_refraction leaves everywhere outside its sphere.
fn cornerBlockDark(buf: []const u8, cap_width: usize, block: usize) bool {
    var y: usize = 0;
    while (y < block) : (y += 1) {
        var x: usize = 0;
        while (x < block) : (x += 1) {
            const i = (y * cap_width + x) * 4;
            if (lumaByte(buf[i], buf[i + 1], buf[i + 2]) > 8) return false;
        }
    }
    return true;
}

/// Proves warp.pass on real content: each mode is a radial distortion centered
/// on the frame, bit-stable across two runs, changing its center block versus
/// the same mode at strength zero, yet leaving a far corner outside the radius
/// byte-identical to that identity control. sphere_refraction is black there.
fn proveWarp(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    const cap_w: usize = 400;
    const cap_h: usize = 300;
    // A 40x40 top-left block. Its farthest pixel sits at u ~0.099, so its
    // distance from the centered warp exceeds 0.4 - well past every reference
    // radius (0.28) whatever the aspect, since the x term alone clears it.
    const corner: usize = 40;
    // The center block a radial warp always touches on real content.
    const center: usize = 40;

    const modes = [_]struct { name: []const u8, mode: []const u8, refraction: bool }{
        .{ .name = "glass-sphere", .mode = "glass_sphere", .refraction = false },
        .{ .name = "sphere-refraction", .mode = "sphere_refraction", .refraction = true },
        .{ .name = "bulge", .mode = "bulge", .refraction = false },
        .{ .name = "pinch", .mode = "pinch", .refraction = false },
        .{ .name = "swirl", .mode = "swirl", .refraction = false },
    };

    var showcase: ?[]u8 = null;
    defer if (showcase) |s| gpa.free(s);

    for (modes) |m| {
        const pkg = try std.fmt.allocPrint(gpa, ".lens-packages/{s}", .{m.name});
        defer gpa.free(pkg);

        const warped_a = try captureStylizeShot(gpa, engine, planes, pkg);
        defer gpa.free(warped_a);
        const warped_b = try captureStylizeShot(gpa, engine, planes, pkg);
        defer gpa.free(warped_b);
        if (!std.mem.eql(u8, warped_a, warped_b)) {
            std.debug.print("conformance: FAIL warp {s} is not bit-stable across runs\n", .{m.name});
            return false;
        }

        // The same mode at strength zero: identity through the very same pass,
        // so it shares the warp's resample everywhere and isolates the effect.
        const control_json = try std.fmt.allocPrint(gpa,
            \\{{"glf":"1.0","id":"goss.reference.warp-control","version":"1.0.0","display_name":"Warp Control","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{{"id":"w","type":"warp.pass","inputs":{{"frame":"camera"}},"params":{{}},"warp":{{"mode":"{s}","center_x":0.5,"center_y":0.5,"radius":0.28,"strength":0.0,"refractive_index":0.71}}}}],"triggers":[]}}
        , .{m.mode});
        defer gpa.free(control_json);
        const control = try captureWarpShotJson(gpa, engine, planes, control_json);
        defer gpa.free(control);

        if (!centerBlockDiffers(warped_a, control, cap_w, cap_h, center)) {
            std.debug.print("conformance: FAIL warp {s} did not change the center region\n", .{m.name});
            return false;
        }
        if (!cornerBlockEqual(warped_a, control, cap_w, corner)) {
            std.debug.print("conformance: FAIL warp {s} changed a far corner outside its radius (not localized)\n", .{m.name});
            return false;
        }
        if (m.refraction and !cornerBlockDark(warped_a, cap_w, corner)) {
            std.debug.print("conformance: FAIL sphere_refraction did not blacken the surround outside the sphere\n", .{});
            return false;
        }

        if (std.mem.eql(u8, m.name, "glass-sphere")) {
            showcase = try gpa.dupe(u8, warped_a);
        }
    }

    if (showcase) |s| {
        var png_bytes: std.ArrayList(u8) = .empty;
        defer png_bytes.deinit(gpa);
        try png.encodeRgba(gpa, &png_bytes, s, 400, 300);
        try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-warp.png", .data = png_bytes.items });
    }
    std.debug.print("conformance: PROOF warp.pass modes are deterministic, localized radial distortions - the center warps while a far corner stays byte-identical to the identity control, sphere_refraction black outside the sphere\n", .{});
    return true;
}

/// True when any pixel in the block-sized region at (x0, y0) differs between
/// two captures - used to test a specific point neighborhood or mirror side.
fn blockDiffersAt(a: []const u8, b: []const u8, cap_width: usize, x0: usize, y0: usize, block: usize) bool {
    var y: usize = y0;
    while (y < y0 + block) : (y += 1) {
        const start = (y * cap_width + x0) * 4;
        if (!std.mem.eql(u8, a[start .. start + block * 4], b[start .. start + block * 4])) return true;
    }
    return false;
}

/// Proves the two freeform warp traits. Liquify sums local push points: two of
/// them warp both neighborhoods while a far corner stays byte-identical to the
/// strength-zero identity control, so the push is local. Symmetry mirrors an
/// off-center warp onto the opposite side, which stays untouched without it.
fn proveLiquifySymmetry(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    const cap_w: usize = 400;
    const corner: usize = 40;
    const block: usize = 30;
    // Point one sits at u 0.3 (px 120), point two at u 0.7 (px 280), both on
    // the vertical middle (py 150); the mirror axis is the frame center u 0.5.
    const left_x: usize = 120 - block / 2;
    const right_x: usize = 280 - block / 2;
    const mid_y: usize = 150 - block / 2;

    const liquify_json =
        \\{"glf":"1.0","id":"goss.reference.liquify-proof","version":"1.0.0","display_name":"Liquify Proof","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"liquify","strength":1.0,"points":[{"x":0.3,"y":0.5,"dx":0.08,"dy":0.0,"radius":0.13},{"x":0.7,"y":0.5,"dx":-0.08,"dy":0.0,"radius":0.13}]}}],"triggers":[]}
    ;
    // The same two points at strength zero: an identity resample through the
    // very same pass, isolating the push everywhere it acts.
    const liquify_control_json =
        \\{"glf":"1.0","id":"goss.reference.liquify-control","version":"1.0.0","display_name":"Liquify Control","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"liquify","strength":0.0,"points":[{"x":0.3,"y":0.5,"dx":0.08,"dy":0.0,"radius":0.13},{"x":0.7,"y":0.5,"dx":-0.08,"dy":0.0,"radius":0.13}]}}],"triggers":[]}
    ;

    const liq_a = try captureWarpShotJson(gpa, engine, planes, liquify_json);
    defer gpa.free(liq_a);
    const liq_b = try captureWarpShotJson(gpa, engine, planes, liquify_json);
    defer gpa.free(liq_b);
    if (!std.mem.eql(u8, liq_a, liq_b)) {
        std.debug.print("conformance: FAIL liquify is not bit-stable across runs\n", .{});
        return false;
    }
    const liq_ctrl = try captureWarpShotJson(gpa, engine, planes, liquify_control_json);
    defer gpa.free(liq_ctrl);

    if (!blockDiffersAt(liq_a, liq_ctrl, cap_w, left_x, mid_y, block)) {
        std.debug.print("conformance: FAIL liquify did not warp the first point neighborhood\n", .{});
        return false;
    }
    if (!blockDiffersAt(liq_a, liq_ctrl, cap_w, right_x, mid_y, block)) {
        std.debug.print("conformance: FAIL liquify did not warp the second point neighborhood\n", .{});
        return false;
    }
    if (!cornerBlockEqual(liq_a, liq_ctrl, cap_w, corner)) {
        std.debug.print("conformance: FAIL liquify changed a far corner outside every point radius (not local)\n", .{});
        return false;
    }

    // An off-center bulge at u 0.3, once one-sided and once mirrored about u 0.5,
    // against the same bulge at strength zero (the identity control).
    const asym_json =
        \\{"glf":"1.0","id":"goss.reference.warp-asym","version":"1.0.0","display_name":"Warp Asym","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"bulge","center_x":0.3,"center_y":0.5,"radius":0.2,"strength":2.0}}],"triggers":[]}
    ;
    const sym_json =
        \\{"glf":"1.0","id":"goss.reference.warp-sym","version":"1.0.0","display_name":"Warp Sym","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"bulge","center_x":0.3,"center_y":0.5,"radius":0.2,"strength":2.0,"symmetry":true,"symmetry_x":0.5}}],"triggers":[]}
    ;
    const sym_control_json =
        \\{"glf":"1.0","id":"goss.reference.warp-sym-control","version":"1.0.0","display_name":"Warp Sym Control","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"bulge","center_x":0.3,"center_y":0.5,"radius":0.2,"strength":0.0}}],"triggers":[]}
    ;

    const asym = try captureWarpShotJson(gpa, engine, planes, asym_json);
    defer gpa.free(asym);
    const sym_a = try captureWarpShotJson(gpa, engine, planes, sym_json);
    defer gpa.free(sym_a);
    const sym_b = try captureWarpShotJson(gpa, engine, planes, sym_json);
    defer gpa.free(sym_b);
    if (!std.mem.eql(u8, sym_a, sym_b)) {
        std.debug.print("conformance: FAIL symmetric warp is not bit-stable across runs\n", .{});
        return false;
    }
    const sym_ctrl = try captureWarpShotJson(gpa, engine, planes, sym_control_json);
    defer gpa.free(sym_ctrl);

    if (!blockDiffersAt(asym, sym_ctrl, cap_w, left_x, mid_y, block)) {
        std.debug.print("conformance: FAIL the off-center warp did not touch its own side\n", .{});
        return false;
    }
    if (blockDiffersAt(asym, sym_ctrl, cap_w, right_x, mid_y, block)) {
        std.debug.print("conformance: FAIL the one-sided warp leaked onto the opposite side\n", .{});
        return false;
    }
    if (!blockDiffersAt(sym_a, sym_ctrl, cap_w, right_x, mid_y, block)) {
        std.debug.print("conformance: FAIL symmetry did not mirror the warp onto the opposite side\n", .{});
        return false;
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, sym_a, 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-liquify.png", .data = png_bytes.items });

    std.debug.print("conformance: PROOF liquify sums local push points - both neighborhoods warp while a far corner stays byte-identical to the identity control - and symmetry mirrors an off-center warp onto the opposite side that is untouched without it\n", .{});
    return true;
}

/// Renders one warp lens over a synthetic frame, optionally injecting a
/// synthetic class mask each frame so the warp is confined to that region. A
/// null mask leaves the warp acting on the whole frame.
fn captureBodyWarpShot(gpa: std.mem.Allocator, engine: *abi.Engine, planes: Nv12Copy, manifest_json: []const u8, mask: ?*const [abi.segmentation_mask_len]f32, channel: usize) ![]u8 {
    const half_w = (planes.width + 1) / 2;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens(session, manifest_json.ptr, manifest_json.len) != .ok) {
        std.debug.print("conformance: FAIL body warp lens activation\n", .{});
        return error.ActivationFailed;
    }
    for (0..3) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        if (mask) |m| abi.injectMaskChannel(session, channel, m);
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var shot_width: u32 = 0;
    var shot_height: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
        return error.CaptureFailed;
    }
    return shot;
}

/// Proves a mask-gated warp reshapes only the masked body and spares the
/// background: a full-frame bulge moves the masked center but leaves a corner
/// outside the mask byte-identical to the original frame, while an unmasked or
/// fully-present-class warp matches the no-mask warp. Bit-stable across runs.
fn proveBodyReshape(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const cap_w: usize = 400;
    const cap_h: usize = 300;
    const corner: usize = 40;
    const center: usize = 40;

    // A synthetic frame with variation on both axes, so any displacement moves
    // the sampled color: red rides the column, green rides the row.
    const frame_rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(frame_rgba);
    for (0..height) |row| {
        for (0..width) |col| {
            const i = (row * @as(usize, width) + col) * 4;
            frame_rgba[i + 0] = @intCast(col * 255 / (@as(usize, width) - 1));
            frame_rgba[i + 1] = @intCast(row * 255 / (@as(usize, height) - 1));
            frame_rgba[i + 2] = 128;
            frame_rgba[i + 3] = 255;
        }
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = frame_rgba }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    // A mask over only the central region: 1 where the grid maps into
    // [0.35, 0.65] on both axes, 0 elsewhere, so all four corners are outside.
    const side = abi.segmentation_mask_side;
    var central: [abi.segmentation_mask_len]f32 = undefined;
    var full: [abi.segmentation_mask_len]f32 = undefined;
    for (0..side) |gy| {
        for (0..side) |gx| {
            const u = (@as(f32, @floatFromInt(gx)) + 0.5) / @as(f32, @floatFromInt(side));
            const v = (@as(f32, @floatFromInt(gy)) + 0.5) / @as(f32, @floatFromInt(side));
            const inside = u >= 0.35 and u <= 0.65 and v >= 0.35 and v <= 0.65;
            central[gy * side + gx] = if (inside) 1.0 else 0.0;
            full[gy * side + gx] = 1.0;
        }
    }
    const body_channel: usize = lens_manifest.maskChannelIndex("body_skin").?;

    // A full-frame bulge (radius past every corner) so an unmasked warp would
    // move the corner too; the mask is the only thing that can spare it.
    const masked_json =
        \\{"glf":"1.0","id":"goss.reference.body-reshape-proof","version":"1.0.0","display_name":"Body Reshape Proof","engine_compat":">=0.5","capabilities":["segmentation"],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"bulge","center_x":0.5,"center_y":0.5,"radius":0.95,"strength":3.0,"aspect_auto":false,"mask":"body_skin"}}],"triggers":[]}
    ;
    const unmasked_json =
        \\{"glf":"1.0","id":"goss.reference.body-reshape-plain","version":"1.0.0","display_name":"Body Reshape Plain","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"bulge","center_x":0.5,"center_y":0.5,"radius":0.95,"strength":3.0,"aspect_auto":false}}],"triggers":[]}
    ;
    const control_json =
        \\{"glf":"1.0","id":"goss.reference.body-reshape-control","version":"1.0.0","display_name":"Body Reshape Control","engine_compat":">=0.5","capabilities":["segmentation"],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"bulge","center_x":0.5,"center_y":0.5,"radius":0.95,"strength":0.0,"aspect_auto":false,"mask":"body_skin"}}],"triggers":[]}
    ;

    const original = try captureWarpShotJson(gpa, engine, planes, null);
    defer gpa.free(original);

    const masked_a = try captureBodyWarpShot(gpa, engine, planes, masked_json, &central, body_channel);
    defer gpa.free(masked_a);
    const masked_b = try captureBodyWarpShot(gpa, engine, planes, masked_json, &central, body_channel);
    defer gpa.free(masked_b);
    if (!std.mem.eql(u8, masked_a, masked_b)) {
        std.debug.print("conformance: FAIL mask-gated warp is not bit-stable across runs\n", .{});
        return false;
    }

    const control = try captureBodyWarpShot(gpa, engine, planes, control_json, &central, body_channel);
    defer gpa.free(control);

    const unmasked_a = try captureBodyWarpShot(gpa, engine, planes, unmasked_json, null, body_channel);
    defer gpa.free(unmasked_a);
    const unmasked_b = try captureBodyWarpShot(gpa, engine, planes, unmasked_json, null, body_channel);
    defer gpa.free(unmasked_b);
    if (!std.mem.eql(u8, unmasked_a, unmasked_b)) {
        std.debug.print("conformance: FAIL unmasked warp is not bit-stable across runs\n", .{});
        return false;
    }

    const full_masked = try captureBodyWarpShot(gpa, engine, planes, masked_json, &full, body_channel);
    defer gpa.free(full_masked);

    // The masked warp reshapes the center inside the mask, versus the identity control.
    if (!centerBlockDiffers(masked_a, control, cap_w, cap_h, center)) {
        std.debug.print("conformance: FAIL mask-gated warp did not reshape the masked region\n", .{});
        return false;
    }
    // The corner is outside the mask, so it stays byte-identical to the original
    // frame - the background is truly untouched, not merely matching the control.
    if (!cornerBlockEqual(masked_a, original, cap_w, corner)) {
        std.debug.print("conformance: FAIL mask-gated warp changed the background outside the mask\n", .{});
        return false;
    }
    // The same warp with no mask does move that corner, so the mask, not the
    // radius, is what spared the background.
    if (cornerBlockEqual(unmasked_a, original, cap_w, corner)) {
        std.debug.print("conformance: FAIL the unmasked warp left the corner unchanged, so the proof cannot isolate the mask gate\n", .{});
        return false;
    }
    // A warp with no mask is byte-identical to the same warp keyed to a fully
    // present class: the gate is transparent where the mask is set, so masked
    // pixels warp exactly like the current unmasked warp.
    if (!std.mem.eql(u8, unmasked_a, full_masked)) {
        std.debug.print("conformance: FAIL a fully-masked warp is not byte-identical to the unmasked warp\n", .{});
        return false;
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, masked_a, 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-body-reshape.png", .data = png_bytes.items });

    std.debug.print("conformance: PROOF a mask-gated warp reshapes only the masked body - the center warps while a corner outside the mask stays byte-identical to the original frame - and a warp with no mask is byte-identical to the fully-masked warp, bit-stable across runs\n", .{});
    return true;
}

/// Builds a one-node reshape.bank lens whose reshape block is `body`, over a
/// real corpus face. The empty body "{}" is the identity control every param
/// capture shares its resample path with.
fn reshapeManifest(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\{{"glf":"1.0","id":"goss.reference.reshape-proof","version":"1.0.0","display_name":"Reshape Proof","engine_compat":">=0.5","capabilities":["face"],"parameters":[],"nodes":[{{"id":"sculpt","type":"reshape.bank","inputs":{{"frame":"camera"}},"params":{{}},"reshape":{s}}}],"triggers":[]}}
    , .{body});
}

/// Renders one reshape.bank lens over the corpus face through the real ABI
/// with native face tracking, warming until a face lands then capturing a
/// settled frame. Null when the face model is unavailable, so a machine
/// without it skips the proof rather than failing it.
fn captureReshapeShot(gpa: std.mem.Allocator, engine: *abi.Engine, manifest_json: []const u8) !?[]u8 {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    const face_bytes = std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20)) catch return null;
    defer gpa.free(face_bytes);
    if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) return null;
    if (abi.goss_session_activate_lens(session, manifest_json.ptr, manifest_json.len) != .ok) return error.ActivationFailed;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
    var result: abi.FaceResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_face_result(session, &result) == .again) {
        std.Thread.yield() catch {};
        if (g_watch) c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000_000) return error.FaceResultTimedOut;
    }
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
    var shot: []u8 = &.{};
    for (0..8) |i| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (i == 6) {
            shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
            errdefer gpa.free(shot);
            var w: u32 = 0;
            var h: u32 = 0;
            if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
        }
    }
    return shot;
}

/// Counts the pixels that differ between a sculpted capture and its identity
/// control and accumulates their centroid, so the proof knows both that a
/// region moved and where the movement landed.
fn changedRegion(a: []const u8, b: []const u8, cap_width: usize, cap_height: usize, out_cx: *f32, out_cy: *f32) usize {
    var count: usize = 0;
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var y: usize = 0;
    while (y < cap_height) : (y += 1) {
        var x: usize = 0;
        while (x < cap_width) : (x += 1) {
            const i = (y * cap_width + x) * 4;
            if (!std.mem.eql(u8, a[i .. i + 4], b[i .. i + 4])) {
                count += 1;
                sum_x += @floatFromInt(x);
                sum_y += @floatFromInt(y);
            }
        }
    }
    if (count > 0) {
        out_cx.* = @floatCast(sum_x / @as(f64, @floatFromInt(count)));
        out_cy.* = @floatCast(sum_y / @as(f64, @floatFromInt(count)));
    }
    return count;
}

/// True when the block of half-width `half` centered on (cx, cy) is byte
/// identical between two captures - the proof one region's sculpt leaves a
/// different region untouched.
fn blockEqualAt(a: []const u8, b: []const u8, cap_width: usize, cap_height: usize, cx: f32, cy: f32, half: usize) bool {
    const ix: usize = @intFromFloat(@max(0.0, cx));
    const iy: usize = @intFromFloat(@max(0.0, cy));
    const x0 = if (ix > half) ix - half else 0;
    const y0 = if (iy > half) iy - half else 0;
    const x1 = @min(cap_width, ix + half);
    const y1 = @min(cap_height, iy + half);
    var y = y0;
    while (y < y1) : (y += 1) {
        const start = (y * cap_width + x0) * 4;
        const end = (y * cap_width + x1) * 4;
        if (!std.mem.eql(u8, a[start..end], b[start..end])) return false;
    }
    return true;
}

/// Proves the reshape.bank sculpt on a real corpus face: nose width, chin
/// length, left eye size and jaw slim each move their own region versus the
/// identity control, leave the far corner and the other tested region byte
/// identical, and the whole face-tracked path is bit-stable across two runs.
fn proveReshapeBank(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const cap_w: usize = 400;
    const cap_h: usize = 300;
    const control_json = try reshapeManifest(gpa, "{}");
    defer gpa.free(control_json);
    const control = (try captureReshapeShot(gpa, engine, control_json)) orelse return true;
    defer gpa.free(control);
    const control2 = (try captureReshapeShot(gpa, engine, control_json)) orelse return true;
    defer gpa.free(control2);
    if (!std.mem.eql(u8, control, control2)) {
        std.debug.print("conformance: FAIL reshape.bank identity control is not bit-stable across runs\n", .{});
        return false;
    }

    const cases = [_]struct { name: []const u8, body: []const u8 }{
        .{ .name = "nose_width", .body = "{\"nose_width\":0.9}" },
        .{ .name = "chin_length", .body = "{\"chin_length\":0.9}" },
        .{ .name = "eye_size_l", .body = "{\"eye_size_l\":0.9}" },
        .{ .name = "jaw_slim", .body = "{\"jaw_slim\":0.9}" },
    };

    var shots: [cases.len][]u8 = undefined;
    var cx: [cases.len]f32 = undefined;
    var cy: [cases.len]f32 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (cases, 0..) |cse, idx| {
        const json = try reshapeManifest(gpa, cse.body);
        defer gpa.free(json);
        const shot = (try captureReshapeShot(gpa, engine, json)) orelse return true;
        shots[idx] = shot;
        taken += 1;
        const count = changedRegion(shot, control, cap_w, cap_h, &cx[idx], &cy[idx]);
        if (count < 100) {
            std.debug.print("conformance: FAIL reshape.bank {s} did not move its region ({d} px changed)\n", .{ cse.name, count });
            return false;
        }
        if (!cornerBlockEqual(shot, control, cap_w, 40)) {
            std.debug.print("conformance: FAIL reshape.bank {s} changed the far background corner (not localized)\n", .{cse.name});
            return false;
        }
    }

    // Localization between regions: one region's sculpt leaves the other
    // tested region's block byte-identical to the control, in both directions.
    const pairs = [_][2]usize{ .{ 0, 1 }, .{ 2, 3 } };
    for (pairs) |pr| {
        const a = pr[0];
        const b = pr[1];
        const dx = cx[a] - cx[b];
        const dy = cy[a] - cy[b];
        if (dx * dx + dy * dy < 225.0) {
            std.debug.print("conformance: FAIL reshape.bank {s} and {s} centroids not separated\n", .{ cases[a].name, cases[b].name });
            return false;
        }
        if (!blockEqualAt(shots[a], control, cap_w, cap_h, cx[b], cy[b], 8)) {
            std.debug.print("conformance: FAIL reshape.bank {s} disturbed the {s} region\n", .{ cases[a].name, cases[b].name });
            return false;
        }
        if (!blockEqualAt(shots[b], control, cap_w, cap_h, cx[a], cy[a], 8)) {
            std.debug.print("conformance: FAIL reshape.bank {s} disturbed the {s} region\n", .{ cases[b].name, cases[a].name });
            return false;
        }
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[3], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-reshape-bank.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF reshape.bank sculpts each face region locally - nose, chin, eye and jaw each move their own region while the far corner and the other region stay byte-identical to the identity control, bit-stable across runs\n", .{});
    return true;
}

/// True when the top-left corner block is a single flat color - every pixel
/// byte-identical to the first - the mark a cutout replaced the background with
/// one chosen color rather than any image content.
fn cornerBlockUniform(buf: []const u8, cap_width: usize, block: usize) bool {
    const first = buf[0..4];
    var y: usize = 0;
    while (y < block) : (y += 1) {
        var x: usize = 0;
        while (x < block) : (x += 1) {
            const i = (y * cap_width + x) * 4;
            if (!std.mem.eql(u8, buf[i .. i + 4], first)) return false;
        }
    }
    return true;
}

/// Renders one inline-JSON lens over a frame with a set of host-submitted faces
/// and captures the composited frame. The faces drive the face_scale center
/// with no native tracker, so the proof is deterministic and needs no model.
fn captureSubmittedFaceShot(gpa: std.mem.Allocator, engine: *abi.Engine, planes: Nv12Copy, json: ?[]const u8, faces: []const abi.FaceResult) ![]u8 {
    const half_w = (planes.width + 1) / 2;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (json) |j| {
        if (abi.goss_session_activate_lens(session, j.ptr, j.len) != .ok) return error.ActivationFailed;
    }
    if (abi.goss_session_submit_faces(session, faces.ptr, @intCast(faces.len)) != .ok) return error.SubmitFacesFailed;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    for (0..5) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var shot_width: u32 = 0;
    var shot_height: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) return error.CaptureFailed;
    return shot;
}

/// Proves the three landmark-anchored face transforms. face_scale scales the
/// face about its center: a probe right of center samples nearer center under a
/// stretch and farther under an inset, ordering stretch below the control below
/// inset. Cutout keys the face matte over a flat color. All bit-stable.
fn proveFaceTransform(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const cap_w: usize = 400;
    const cap_h: usize = 300;
    const corner: usize = 40;
    const center: usize = 40;

    // A gradient frame: red rides the column, so a horizontal resample toward or
    // away from the face center shifts the sampled red measurably.
    const frame_rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(frame_rgba);
    for (0..height) |row| {
        for (0..width) |col| {
            const i = (row * @as(usize, width) + col) * 4;
            frame_rgba[i + 0] = @intCast(col * 255 / (@as(usize, width) - 1));
            frame_rgba[i + 1] = @intCast(row * 255 / (@as(usize, height) - 1));
            frame_rgba[i + 2] = 128;
            frame_rgba[i + 3] = 255;
        }
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = frame_rgba }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    // A synthetic face: 478 landmarks on a circle centered on the frame, so the
    // face_scale center lands on the frame center with a radius covering it.
    var synthetic = std.mem.zeroes(abi.FaceResult);
    synthetic.presence = 1.0;
    const lm_count = synthetic.landmarks.len / 3;
    synthetic.landmark_count_out = @intCast(lm_count);
    const cxp: f32 = @as(f32, @floatFromInt(width)) / 2.0;
    const cyp: f32 = @as(f32, @floatFromInt(height)) / 2.0;
    const face_r: f32 = 110.0;
    for (0..lm_count) |lm| {
        const ang = @as(f32, @floatFromInt(lm)) / @as(f32, @floatFromInt(lm_count)) * std.math.tau;
        synthetic.landmarks[lm * 3 + 0] = cxp + face_r * @cos(ang);
        synthetic.landmarks[lm * 3 + 1] = cyp + face_r * @sin(ang);
        synthetic.landmarks[lm * 3 + 2] = 0;
    }
    const faces_one = [_]abi.FaceResult{synthetic};
    const no_faces = [_]abi.FaceResult{};

    const inset_json =
        \\{"glf":"1.0","id":"goss.reference.face-inset-proof","version":"1.0.0","display_name":"Face Inset Proof","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"face_scale","strength":-0.6}}],"triggers":[]}
    ;
    const stretch_json =
        \\{"glf":"1.0","id":"goss.reference.face-stretch-proof","version":"1.0.0","display_name":"Face Stretch Proof","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"face_scale","strength":0.7}}],"triggers":[]}
    ;
    const control_json =
        \\{"glf":"1.0","id":"goss.reference.face-scale-control","version":"1.0.0","display_name":"Face Scale Control","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"w","type":"warp.pass","inputs":{"frame":"camera"},"params":{},"warp":{"mode":"face_scale","strength":0.0}}],"triggers":[]}
    ;

    const inset_a = try captureSubmittedFaceShot(gpa, engine, planes, inset_json, &faces_one);
    defer gpa.free(inset_a);
    const inset_b = try captureSubmittedFaceShot(gpa, engine, planes, inset_json, &faces_one);
    defer gpa.free(inset_b);
    if (!std.mem.eql(u8, inset_a, inset_b)) {
        std.debug.print("conformance: FAIL face inset is not bit-stable across runs\n", .{});
        return false;
    }
    const stretch = try captureSubmittedFaceShot(gpa, engine, planes, stretch_json, &faces_one);
    defer gpa.free(stretch);
    const control = try captureSubmittedFaceShot(gpa, engine, planes, control_json, &faces_one);
    defer gpa.free(control);
    const inset_noface = try captureSubmittedFaceShot(gpa, engine, planes, inset_json, &no_faces);
    defer gpa.free(inset_noface);
    const plain = try captureSubmittedFaceShot(gpa, engine, planes, null, &no_faces);
    defer gpa.free(plain);

    // With no face the face_scale holds the frame through, byte-identical to the
    // plain frame - the effect is keyed to the tracked face.
    if (!std.mem.eql(u8, inset_noface, plain)) {
        std.debug.print("conformance: FAIL face_scale altered the frame with no face - not keyed to the face\n", .{});
        return false;
    }
    // Both scales reshape the face region versus the identity control.
    if (!centerBlockDiffers(inset_a, control, cap_w, cap_h, center) or !centerBlockDiffers(stretch, control, cap_w, cap_h, center)) {
        std.debug.print("conformance: FAIL a face_scale did not reshape the face region\n", .{});
        return false;
    }
    // A far corner outside the face radius stays byte-identical to the control,
    // so the scale is local to the face, not a global resample.
    if (!cornerBlockEqual(inset_a, control, cap_w, corner) or !cornerBlockEqual(stretch, control, cap_w, corner)) {
        std.debug.print("conformance: FAIL a face_scale changed a far corner outside the face\n", .{});
        return false;
    }
    // Direction: a probe right of the face center samples nearer the center
    // under a stretch (smaller red) and farther under an inset (larger red), so
    // the identity control sits between them - stretch enlarges, inset shrinks.
    const pidx = (@as(usize, 150) * cap_w + 255) * 4;
    const stretch_red = stretch[pidx];
    const control_red = control[pidx];
    const inset_red = inset_a[pidx];
    if (!(stretch_red + 2 < control_red and control_red + 2 < inset_red)) {
        std.debug.print("conformance: FAIL face_scale direction wrong (stretch {d}, control {d}, inset {d})\n", .{ stretch_red, control_red, inset_red });
        return false;
    }

    // Cutout over a real tracked face: keying the face matte over a flat color.
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const corpus_planes = try rgbaToNv12(gpa, corpus.frame);
    defer corpus_planes.deinit(gpa);

    const cutout_json =
        \\{"glf":"1.0","id":"goss.reference.face-cutout-proof","version":"1.0.0","display_name":"Face Cutout Proof","engine_compat":">=0.5","capabilities":["face"],"parameters":[],"nodes":[{"id":"cut","type":"cutout.pass","inputs":{"frame":"camera"},"params":{},"cutout":{"mask":"head","color":[0.05,0.5,0.55],"softness":0.03}}],"triggers":[]}
    ;

    const plain_face = try captureOccluderShot(gpa, engine, corpus_planes, null, true);
    defer gpa.free(plain_face);
    const cut_a = try captureOccluderShot(gpa, engine, corpus_planes, cutout_json, true);
    defer gpa.free(cut_a);
    const cut_b = try captureOccluderShot(gpa, engine, corpus_planes, cutout_json, true);
    defer gpa.free(cut_b);
    const cut_noface = try captureOccluderShot(gpa, engine, corpus_planes, cutout_json, false);
    defer gpa.free(cut_noface);
    const plain_noface = try captureOccluderShot(gpa, engine, corpus_planes, null, false);
    defer gpa.free(plain_noface);

    if (!std.mem.eql(u8, cut_a, cut_b)) {
        std.debug.print("conformance: FAIL face cutout is not bit-stable across runs\n", .{});
        return false;
    }
    // With no face the cutout holds the frame through, byte-identical to plain.
    if (wholeFrameMeanDiff(cut_noface, plain_noface) >= 2) {
        std.debug.print("conformance: FAIL cutout altered the frame with no face - not keyed to the face\n", .{});
        return false;
    }
    // The far corner outside the face is replaced by one flat background color.
    if (cornerBlockEqual(cut_a, plain_face, cap_w, corner)) {
        std.debug.print("conformance: FAIL cutout did not replace the background outside the face\n", .{});
        return false;
    }
    if (!cornerBlockUniform(cut_a, cap_w, corner)) {
        std.debug.print("conformance: FAIL cutout background is not a single flat color\n", .{});
        return false;
    }
    // cut_noface is the passthrough camera frame. Against it, cut_a keeps the
    // frame where the face matte is on and swaps a flat color in where it is
    // off. Both regions are substantial, so neither the face nor the flat
    // background flooded the whole frame.
    var kept: usize = 0;
    var replaced: usize = 0;
    var pi: usize = 0;
    while (pi + 3 < cut_a.len) : (pi += 4) {
        const d = pixelChannelDiff(cut_a, cut_noface, pi);
        if (d <= 8) kept += 1 else if (d > 24) replaced += 1;
    }
    if (kept < 500) {
        std.debug.print("conformance: FAIL cutout kept too little of the face over the background ({d} pixels)\n", .{kept});
        return false;
    }
    if (replaced < 5000) {
        std.debug.print("conformance: FAIL cutout replaced too little of the background ({d} pixels)\n", .{replaced});
        return false;
    }

    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, cut_a, 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-face-cutout.png", .data = png_bytes.items });

    std.debug.print("conformance: PROOF the face transforms are landmark anchored: face_scale enlarges the face under a stretch and shrinks it under an inset about the face center (probe stretch {d} < control {d} < inset {d}) while a far corner stays byte-identical and no face is a passthrough; cutout keys the face matte over a flat color, {d} background pixels replaced and {d} face pixels kept, all bit-stable\n", .{ stretch_red, control_red, inset_red, replaced, kept });
    return true;
}

/// Proves a bloom.pass post-effect: the bright pass, separable blur and
/// additive composite bleed a glow from the highlights, so a bloomed
/// capture differs from the plain one and is bit-stable across runs (no
/// asset, ready at activation).
fn proveBloom(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/glow-bloom", ".lens-packages/glow-bloom" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL bloom lens activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL bloom is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL bloom.pass did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-glow-bloom.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF a bloom.pass glows the frame's highlights deterministically, differing from the plain capture\n", .{});
    return true;
}

/// Proves the post-effect nodes compose: a lens chaining blur.pass into
/// grade.pass into bloom.pass runs all three in one composite chain, its
/// capture bit-stable and differing from the plain frame - the multi-stage
/// path (ping-pong, bloom scratch) the single-node proofs never exercise.
fn proveStackedPostEffects(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/studio-stack", ".lens-packages/studio-stack" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL stacked post-effect lens activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL the stacked post-effect chain is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL the stacked post-effect chain did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-studio-stack.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF blur, grade and bloom compose in one chain deterministically, differing from the plain capture\n", .{});
    return true;
}

/// Proves the post-effect chain tiles correctly under HD capture: the
/// studio-stack lens (blur, grade, bloom) captured tile-by-tile stitches
/// byte-identical to the single-target render, so the tile-aware post-effect
/// path - bloom's own scratch pair included - holds across grid sizes.
fn proveTiledPostEffect(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/studio-stack", ".lens-packages/studio-stack".len) != .ok) {
        std.debug.print("conformance: FAIL tiled post-effect lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    const cfg = abi.CaptureConfig{ .width = 400, .height = 300, .supersample = 0, .format = 0, .quality = 0 };
    const buf_cap = 400 * 300 * 4 + 4096;
    const whole = try gpa.alloc(u8, buf_cap);
    defer gpa.free(whole);
    var whole_len: usize = 0;
    var ow: u32 = 0;
    var oh: u32 = 0;
    session.capture_tile_cap = 0;
    if (abi.goss_engine_capture_still(engine, session, &cfg, whole.ptr, whole.len, &whole_len, &ow, &oh) != .ok or ow != 400 or oh != 300) {
        std.debug.print("conformance: FAIL single-target capture for the post-effect tiling compare\n", .{});
        return false;
    }
    const caps = [_]u32{ 200, 150 };
    for (caps) |tcap| {
        const tiled = try gpa.alloc(u8, buf_cap);
        defer gpa.free(tiled);
        var tiled_len: usize = 0;
        session.capture_tile_cap = tcap;
        const status = abi.goss_engine_capture_still(engine, session, &cfg, tiled.ptr, tiled.len, &tiled_len, &ow, &oh);
        session.capture_tile_cap = 0;
        if (status != .ok or ow != 400 or oh != 300) {
            std.debug.print("conformance: FAIL tiled post-effect capture at cap {d}\n", .{tcap});
            return false;
        }
        if (!std.mem.eql(u8, whole[0..whole_len], tiled[0..tiled_len])) {
            std.debug.print("conformance: FAIL tiled post-effect capture at cap {d} is not byte-identical to the single target\n", .{tcap});
            return false;
        }
    }
    std.debug.print("conformance: PROOF the blur/grade/bloom chain tiles byte-identical to a single-target render (2x2 and 3x2 grids)\n", .{});
    return true;
}

/// Proves a script reads a facial blendshape: the script-expression lens maps
/// lens.signals.jawOpen straight to a parameter, so a wide-open jaw drives it
/// near 1 and a nearly-closed jaw near 0, deterministically - the expression
/// surface a trigger already reaches through jawOpen.blendshape.
fn proveExpressionScript(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/script-expression", ".lens-packages/script-expression".len) != .ok) {
        std.debug.print("conformance: FAIL script-expression lens activation\n", .{});
        return false;
    }

    const name = "open_amount";
    // blendshape_names[25] is jawOpen, pinned by a face module test.
    const jaw_open = 25;
    var open = std.mem.zeroes(abi.LensSignals);
    open.has_face = true;
    open.blendshapes[jaw_open] = 0.9;
    var closed = std.mem.zeroes(abi.LensSignals);
    closed.has_face = true;
    closed.blendshapes[jaw_open] = 0.1;

    var v_open: f32 = -1;
    var v_closed: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &open);
    if (abi.goss_session_parameter_value(session, name.ptr, name.len, &v_open) != .ok) {
        std.debug.print("conformance: FAIL reading the expression-driven parameter\n", .{});
        return false;
    }
    _ = abi.goss_session_tick_lens(session, 16000, &closed);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_closed);
    if (@abs(v_open - 0.9) > 1e-6 or @abs(v_closed - 0.1) > 1e-6) {
        std.debug.print("conformance: FAIL script read jawOpen as {d}/{d}, wanted 0.9/0.1\n", .{ v_open, v_closed });
        return false;
    }

    var v_again: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &open);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_again);
    if (v_again != v_open) {
        std.debug.print("conformance: FAIL expression script is not deterministic ({d} vs {d})\n", .{ v_again, v_open });
        return false;
    }

    std.debug.print("conformance: PROOF a script reads a facial blendshape (jawOpen) and drives a parameter from it deterministically (0.9 open, 0.1 closed)\n", .{});
    return true;
}

/// Counts the diagnostics a manifest source parses to, freeing everything.
/// The arena owns the diagnostic strings; the manifest owns its own arena.
fn manifestDiagCount(gpa: std.mem.Allocator, source: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diags: lens_manifest.Diagnostics = .{ .arena = arena.allocator() };
    var parsed = try lens_manifest.parse(gpa, &diags, source);
    if (parsed) |*m| m.deinit();
    return diags.list.items.len;
}

/// The hostile-input tripwire: the exact adversarial values from the audit are
/// fed to the untrusted parsers, each asserted to FAIL CLOSED (a diagnostic or
/// a typed error) rather than crash. A safe twin isolates the hostile value so
/// unrelated schema diagnostics cannot mask a regression.
fn proveHostileManifest(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const Pair = struct { name: []const u8, safe: []const u8, hostile: []const u8 };
    const pairs = [_]Pair{
        .{
            .name = "1e10 int default",
            .safe =
            \\{"glf":"1.0","id":"h","version":"1.0","display_name":"H","parameters":[{"name":"p","type":"int","default":5,"min":0,"max":100}]}
            ,
            .hostile =
            \\{"glf":"1.0","id":"h","version":"1.0","display_name":"H","parameters":[{"name":"p","type":"int","default":1e10,"min":0,"max":100}]}
            ,
        },
        .{
            .name = "1e300 vec component",
            .safe =
            \\{"glf":"1.0","id":"h","version":"1.0","display_name":"H","nodes":[{"type":"model.gltf","id":"n","src":"m.glb","particles":{"color":[1,0,0]}}]}
            ,
            .hostile =
            \\{"glf":"1.0","id":"h","version":"1.0","display_name":"H","nodes":[{"type":"model.gltf","id":"n","src":"m.glb","particles":{"color":[1e300,0,0]}}]}
            ,
        },
        .{
            .name = "1e10 duration",
            .safe =
            \\{"glf":"1.0","id":"h","version":"1.0","display_name":"H","triggers":[{"when":"start","action":{"kind":"param_ramp","target":"p","to":1,"duration_ms":100}}]}
            ,
            .hostile =
            \\{"glf":"1.0","id":"h","version":"1.0","display_name":"H","triggers":[{"when":"start","action":{"kind":"param_ramp","target":"p","to":1,"duration_ms":1e10}}]}
            ,
        },
    };
    for (pairs) |pair| {
        const safe_count = try manifestDiagCount(gpa, pair.safe);
        const hostile_count = try manifestDiagCount(gpa, pair.hostile);
        if (hostile_count <= safe_count) {
            std.debug.print("conformance: FAIL hostile '{s}' raised no extra diagnostic (safe {d}, hostile {d})\n", .{ pair.name, safe_count, hostile_count });
            return false;
        }
    }

    // A material graph node chain past the cap must be refused with a typed
    // error, not recursed into a native stack overflow.
    {
        const chain = material.max_nodes + 2;
        const nodes = try gpa.alloc(material.Node, chain);
        defer gpa.free(nodes);
        for (nodes) |*n| n.* = .{ .kind = .uv };
        nodes[chain - 1] = .{ .kind = .output, .inputs = &.{0} };
        const types = try gpa.alloc(material.ValueType, chain);
        defer gpa.free(types);
        material.validate(gpa, .{ .nodes = nodes, .root = chain - 1 }, types) catch |err| {
            if (err != error.TooManyNodes) {
                std.debug.print("conformance: FAIL deep material chain gave {t}, expected TooManyNodes\n", .{err});
                return false;
            }
        };
    }

    // A glTF mesh with zero primitives must refuse, not null-deref.
    {
        const json = "{\"asset\":{\"version\":\"2.0\"},\"meshes\":[{}]}";
        if (gltf.decodeModel(gpa, json)) |model| {
            gltf.freeDecodedModel(gpa, model);
            std.debug.print("conformance: FAIL zero-primitive glb was decoded, expected an error\n", .{});
            return false;
        } else |_| {}
    }

    // A malformed model bundle must fail closed at the ABI, not read OOB or
    // crash: garbage task bytes cannot stand up a tracker.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        const garbage = [_]u8{0xab} ** 64;
        if (abi.goss_session_enable_face_tracking(session, &garbage, garbage.len, 1) == .ok) {
            std.debug.print("conformance: FAIL a garbage face bundle was accepted\n", .{});
            return false;
        }
    }

    std.debug.print("conformance: PROOF hostile inputs fail closed with a diagnostic\n", .{});
    return true;
}

/// Submits `frames` corpus frames through the loader and render path on
/// the renderer-backed engine, the same submit/decode/nv12 sequence a
/// live session runs.
fn submitCorpusFrames(gpa: std.mem.Allocator, engine: *abi.Engine, session: *abi.Session, frames: u32) !void {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    for (0..frames) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
}

/// The full-rendering leak gate on the renderer-backed engine: a real
/// lens is activated (its status checked, never ignored), frames submit
/// and render through the loaders, a photo captures, a recording runs.
/// A warm-up settles the caches; the repeat proves no heap grew.
fn proveNoLeaks(gpa: std.mem.Allocator, engine: *abi.Engine, counter: *CountingAllocator) !bool {
    const round = struct {
        fn once(g: std.mem.Allocator, e: *abi.Engine) !void {
            const bundle = ".lens-packages/soft-blur";
            const session = try abi.createSession(e, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(e);
            if (abi.goss_session_activate_lens_from_directory(session, bundle.ptr, bundle.len) != .ok) return error.ActivationFailed;
            try submitCorpusFrames(g, e, session, 8);

            var needed: usize = 0;
            var pw: u32 = 0;
            var ph: u32 = 0;
            var probe: [1]u8 = undefined;
            if (abi.goss_engine_capture_photo(e, session, &probe, 0, &needed, &pw, &ph) != .invalid_argument or needed == 0) return error.CaptureProbeFailed;
            const photo_png = try g.alloc(u8, needed);
            defer g.free(photo_png);
            var got: usize = 0;
            if (abi.goss_engine_capture_photo(e, session, photo_png.ptr, photo_png.len, &got, &pw, &ph) != .ok) return error.CaptureFailed;

            if (abi.recording_supported) {
                const path = "zig-out/conformance-noleaks.mp4";
                if (abi.goss_engine_recording_start(e, session, path.ptr, path.len, null) != .ok) return error.RecordStartFailed;
                try submitCorpusFrames(g, e, session, 24);
                if (abi.goss_engine_recording_stop(e) != .ok) return error.RecordStopFailed;
            }
        }
    };

    try round.once(gpa, engine);
    settle(engine);
    const base = counter.inUse();
    const jolt_base = goss_jolt_live_bytes();
    const qjs_base = goss_qjs_live_bytes();
    const ma_base = goss_ma_live_bytes();

    try round.once(gpa, engine);
    settle(engine);
    const after = counter.inUse();
    if (after > base) {
        std.debug.print("conformance: FAIL the full rendering lifecycle grew the heap {d} -> {d} bytes\n", .{ base, after });
        return false;
    }

    const jolt_after = goss_jolt_live_bytes();
    const qjs_after = goss_qjs_live_bytes();
    const ma_after = goss_ma_live_bytes();
    if (jolt_after > jolt_base or qjs_after > qjs_base or ma_after > ma_base) {
        std.debug.print("conformance: FAIL a vendor heap grew across the full rendering lifecycle (jolt {d}->{d}, qjs {d}->{d}, miniaudio {d}->{d})\n", .{ jolt_base, jolt_after, qjs_base, qjs_after, ma_base, ma_after });
        return false;
    }

    std.debug.print("conformance: PROOF a full rendering lifecycle (activate, submit, render, capture, record, loaders) leaks no Zig or vendor-heap memory\n", .{});
    return true;
}

/// Proves each major subsystem survives a second full lifecycle with no heap
/// growth: session, hair physics, and recording are each created, used, and
/// destroyed, then the whole round runs again while the counting allocator
/// watches the footprint. A leak that only shows on re-creation fails here.
fn proveSecondLifecycle(gpa: std.mem.Allocator, engine: *abi.Engine, counter: *CountingAllocator) !bool {
    const round = struct {
        fn submitFrames(g: std.mem.Allocator, e: *abi.Engine, session: *abi.Session, frames: u32) !void {
            const corpus = try loadCorpusFrame(g, corpus_path);
            defer corpus.deinit();
            const planes = try rgbaToNv12(g, corpus.frame);
            defer planes.deinit(g);
            const half_w = (planes.width + 1) / 2;
            for (0..frames) |i| {
                const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
                if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
                _ = abi.goss_engine_render_frame(e, session);
                c.glfwPollEvents();
            }
        }
        fn lensLifecycle(g: std.mem.Allocator, e: *abi.Engine, bundle: []const u8) !void {
            const session = try abi.createSession(e, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(e);
            if (abi.goss_session_activate_lens_from_directory(session, bundle.ptr, bundle.len) != .ok) return error.ActivationFailed;
            try submitFrames(g, e, session, 8);
        }
        fn recordingLifecycle(g: std.mem.Allocator, e: *abi.Engine) !void {
            const session = try abi.createSession(e, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(e);
            if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) return error.ActivationFailed;
            const path = "zig-out/conformance-second-lifecycle.mp4";
            if (abi.goss_engine_recording_start(e, session, path.ptr, path.len, null) != .ok) return error.RecordStartFailed;
            try submitFrames(g, e, session, 40);
            if (abi.goss_engine_recording_stop(e) != .ok) return error.RecordStopFailed;
        }
        fn scriptLifecycle(e: *abi.Engine) !void {
            const session = try abi.createSession(e, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(e);
            if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/script-param", ".lens-packages/script-param".len) != .ok) return error.ActivationFailed;
            var present = std.mem.zeroes(abi.LensSignals);
            present.has_face = true;
            for (0..8) |_| _ = abi.goss_session_tick_lens(session, 16000, &present);
        }
        fn soundLifecycle(e: *abi.Engine) !void {
            const session = try abi.createSession(e, .{ .frame_budget_us = 0, .reserved = 0 });
            defer abi.destroySession(session);
            defer settle(e);
            if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/sound-beat", ".lens-packages/sound-beat".len) != .ok) return error.ActivationFailed;
            var present = std.mem.zeroes(abi.LensSignals);
            present.has_face = true;
            _ = abi.goss_session_tick_lens(session, 16000, &present);
            var block: [512]i16 = undefined;
            _ = abi.goss_session_pull_audio(session, &block, 512);
        }
        fn all(g: std.mem.Allocator, e: *abi.Engine) !void {
            try lensLifecycle(g, e, ".lens-packages/soft-blur");
            try lensLifecycle(g, e, ".lens-packages/hair-sim");
            try scriptLifecycle(e);
            try soundLifecycle(e);
            if (abi.recording_supported) try recordingLifecycle(g, e);
        }
    };

    // Warm-up round: the first creation allocates the one-time caches every
    // subsystem keeps for the engine's life, so the footprint it settles to
    // is the honest baseline the repeat must not exceed.
    try round.all(gpa, engine);
    settle(engine);
    const base = counter.inUse();
    const jolt_base = goss_jolt_live_bytes();
    const qjs_base = goss_qjs_live_bytes();
    const ma_base = goss_ma_live_bytes();

    // Second round: the same work again, no lasting growth allowed.
    try round.all(gpa, engine);
    settle(engine);
    const after = counter.inUse();

    if (after > base) {
        std.debug.print("conformance: FAIL a subsystem grew the heap {d} -> {d} bytes across a second lifecycle\n", .{ base, after });
        return false;
    }

    // The vendor heaps the Zig GPA cannot see: Jolt, QuickJS, and miniaudio
    // each report live bytes, and a hair, runtime, or sound leaked past its
    // owner shows as growth here where the GPA is blind.
    const jolt_after = goss_jolt_live_bytes();
    const qjs_after = goss_qjs_live_bytes();
    const ma_after = goss_ma_live_bytes();
    if (jolt_after > jolt_base or qjs_after > qjs_base or ma_after > ma_base) {
        std.debug.print("conformance: FAIL a vendor heap grew across a second lifecycle (jolt {d}->{d}, qjs {d}->{d}, miniaudio {d}->{d})\n", .{ jolt_base, jolt_after, qjs_base, qjs_after, ma_base, ma_after });
        return false;
    }

    std.debug.print("conformance: PROOF session, hair, script, sound, and recording survive a second create/use/destroy with no Zig or vendor-heap growth\n", .{});
    return true;
}

/// Wraps an allocator to track bytes in use, so the per-frame gate watches the
/// heap footprint settle rather than the wall clock. The loader and tracking
/// threads allocate concurrently with the render thread, so the counters are
/// atomic; a non-atomic step could lose an update and corrupt the leak proof.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    in_use_atomic: std.atomic.Value(usize) = .init(0),
    peak_atomic: std.atomic.Value(usize) = .init(0),
    // Every heap-acquiring vtable call, counted so the per-frame proof can
    // fail on churn (alloc+free that nets to zero bytes) the byte gate misses.
    calls_atomic: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn inUse(self: *const CountingAllocator) usize {
        return self.in_use_atomic.load(.monotonic);
    }
    fn peakBytes(self: *const CountingAllocator) usize {
        return self.peak_atomic.load(.monotonic);
    }
    fn calls(self: *const CountingAllocator) usize {
        return self.calls_atomic.load(.monotonic);
    }
    fn resetPeakToInUse(self: *CountingAllocator) void {
        self.peak_atomic.store(self.in_use_atomic.load(.monotonic), .monotonic);
    }
    // Raises the recorded peak to `current` with a CAS loop so a concurrent
    // grow cannot clobber a higher peak another thread just set.
    fn bump(self: *CountingAllocator, current: usize) void {
        var seen = self.peak_atomic.load(.monotonic);
        while (current > seen) {
            seen = self.peak_atomic.cmpxchgWeak(seen, current, .monotonic, .monotonic) orelse break;
        }
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        _ = self.calls_atomic.fetchAdd(1, .monotonic);
        self.bump(self.in_use_atomic.fetchAdd(len, .monotonic) + len);
        return p;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(buf, alignment, new_len, ra)) return false;
        _ = self.calls_atomic.fetchAdd(1, .monotonic);
        self.bump(self.applyDelta(buf.len, new_len));
        return true;
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(buf, alignment, new_len, ra) orelse return null;
        _ = self.calls_atomic.fetchAdd(1, .monotonic);
        self.bump(self.applyDelta(buf.len, new_len));
        return p;
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, alignment, ra);
        _ = self.in_use_atomic.fetchSub(buf.len, .monotonic);
    }
    // Applies a resize's signed byte delta atomically, returning the new total.
    fn applyDelta(self: *CountingAllocator, old_len: usize, new_len: usize) usize {
        if (new_len >= old_len) return self.in_use_atomic.fetchAdd(new_len - old_len, .monotonic) + (new_len - old_len);
        return self.in_use_atomic.fetchSub(old_len - new_len, .monotonic) - (old_len - new_len);
    }
};

/// Enforces bounded per-frame work: the heaviest reference stack (blur,
/// grade, bloom and particles at once) renders many frames while the heap
/// footprint is sampled each frame. Past warm-up the in-use bytes must
/// hold flat - steady growth is the accumulation that overheats a phone.
fn provePerFrameBudget(gpa: std.mem.Allocator, engine: *abi.Engine, counter: *CountingAllocator) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/studio-full", ".lens-packages/studio-full".len) != .ok) {
        std.debug.print("conformance: FAIL per-frame budget lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const total_frames: usize = 120;
    const warmup: usize = 40;
    var steady_min: usize = std.math.maxInt(usize);
    var steady_max: usize = 0;
    for (0..total_frames) |frame| {
        const desc: abi.FrameDesc = .{
            .width = planes.width,
            .height = planes.height,
            .pixel_format = 0,
            .color_standard = 0,
            .color_range = 1,
            .flags = 0,
            .timestamp_us = @as(i64, @intCast(frame + 1)) * 33_333,
        };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (frame >= warmup) {
            const now = counter.inUse();
            if (now < steady_min) steady_min = now;
            if (now > steady_max) steady_max = now;
        }
    }

    // Steady-state footprint must be flat: no bytes accumulate frame to
    // frame once the pools and caches have filled.
    if (steady_max != steady_min) {
        std.debug.print("conformance: FAIL per-frame footprint grew {d} bytes over steady state (min {d}, max {d}) - per-frame accumulation\n", .{ steady_max - steady_min, steady_min, steady_max });
        return false;
    }
    std.debug.print("conformance: PROOF the full stack holds a flat {d}-byte per-frame footprint over {d} frames (no accumulation)\n", .{ steady_min, total_frames - warmup });
    return true;
}

const AllocCallScenario = struct { name: []const u8, dir: []const u8, depth: bool };

/// Every per-frame path Branch 5 moved onto persistent staging, each named so
/// a regression points at the exact conversion that leaked back an allocation.
const alloc_call_scenarios = [_]AllocCallScenario{
    .{ .name = "full stack staging", .dir = ".lens-packages/studio-full", .depth = false },
    .{ .name = "ribbon staging", .dir = ".lens-packages/ribbon-comet", .depth = false },
    .{ .name = "trail billboards", .dir = ".lens-packages/comet-trail", .depth = false },
    .{ .name = "fade billboards", .dir = ".lens-packages/smoke-plume", .depth = false },
    .{ .name = "plain points", .dir = ".lens-packages/sparkles", .depth = false },
    .{ .name = "mesh cloud", .dir = ".lens-packages/mesh-orbs", .depth = false },
    .{ .name = "sph fluid", .dir = ".lens-packages/sph-pool", .depth = false },
    .{ .name = "cloth solver", .dir = ".lens-packages/cloth-flag", .depth = false },
    .{ .name = "hair solver", .dir = ".lens-packages/hair-sim", .depth = false },
    .{ .name = "morph mesh", .dir = ".lens-packages/morph-blend", .depth = false },
    .{ .name = "depth submit", .dir = ".lens-packages/dof-blur", .depth = true },
};

/// The steady-window allocation-CALL gate: renders each converted per-frame
/// path through a warm-up and then a steady window, failing if the engine
/// makes ANY allocation call in that window. That is churn (an alloc paired
/// with a free) the flat-byte gate above cannot see, since it nets to zero.
fn provePerFrameAllocCalls(gpa: std.mem.Allocator, engine: *abi.Engine, counter: *CountingAllocator) !bool {
    for (alloc_call_scenarios) |sc| {
        if (!try proveScenarioAllocFree(gpa, engine, counter, sc)) return false;
    }
    return true;
}

fn proveScenarioAllocFree(gpa: std.mem.Allocator, engine: *abi.Engine, counter: *CountingAllocator, sc: AllocCallScenario) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, sc.dir.ptr, sc.dir.len) != .ok) {
        std.debug.print("conformance: FAIL alloc-call scenario {s} lens activation\n", .{sc.name});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    // A stable-size depth plane the occlusion and dof paths normalize each
    // frame, so submit_depth's scratch and dynamic texture are exercised.
    const depth_w: u32 = 64;
    const depth_h: u32 = 64;
    var depth_plane: []f32 = &.{};
    defer if (depth_plane.len > 0) gpa.free(depth_plane);
    if (sc.depth) {
        depth_plane = try gpa.alloc(f32, depth_w * depth_h);
        for (depth_plane, 0..) |*d, i| d.* = 0.5 + 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    }

    // Warm-up lets every persistent buffer grow to its largest frame; the
    // steady window past it must touch the allocator zero times.
    const total_frames: usize = 90;
    const warmup: usize = 45;
    var start_calls: usize = 0;
    for (0..total_frames) |frame| {
        const desc: abi.FrameDesc = .{
            .width = planes.width,
            .height = planes.height,
            .pixel_format = 0,
            .color_standard = 0,
            .color_range = 1,
            .flags = 0,
            .timestamp_us = @as(i64, @intCast(frame + 1)) * 33_333,
        };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        if (sc.depth) {
            if (abi.goss_session_submit_depth(session, depth_plane.ptr, depth_w, depth_h, 0.2, 3.0) != .ok) return error.SubmitFailed;
        }
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        if (frame == warmup) start_calls = counter.calls();
    }
    const steady = counter.calls() - start_calls;
    if (steady != 0) {
        std.debug.print("conformance: FAIL {s} made {d} allocation calls over {d} steady frames - per-frame churn\n", .{ sc.name, steady, total_frames - warmup });
        return false;
    }
    std.debug.print("conformance: PROOF {s} holds zero allocation calls over {d} steady frames\n", .{ sc.name, total_frames - warmup });
    return true;
}

/// Proves a tiled PNG capture streams instead of buffering the whole
/// frame: forced to many tiles, the streaming path's peak heap stays a
/// full render buffer below the full-buffer path's - the memory unlock
/// that lets a very large capture fit in a phone's RAM.
fn provePeakBoundedCapture(gpa: std.mem.Allocator, engine: *abi.Engine, counter: *CountingAllocator) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL peak-bounded capture lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // An 800x600 output at a 100px tile cap forces an 8x6 grid. Both the
    // streaming and full-buffer paths hold the same compressed output, so
    // the difference in peak heap is the full render buffer the streaming
    // path never allocates.
    const render_size: usize = 800 * 600 * 4;
    const cfg = abi.CaptureConfig{ .width = 800, .height = 600, .supersample = 0, .format = 0, .quality = 0 };
    const buf = try gpa.alloc(u8, render_size + 65536); // via gpa, uncounted
    defer gpa.free(buf);
    var out_len: usize = 0;
    var ow: u32 = 0;
    var oh: u32 = 0;

    const measure = struct {
        fn run(e: *abi.Engine, sess: *abi.Session, ct: *CountingAllocator, config: *const abi.CaptureConfig, out: []u8, no_stream: bool) usize {
            sess.capture_tile_cap = 100;
            sess.capture_no_stream = no_stream;
            ct.resetPeakToInUse();
            const base = ct.inUse();
            var ol: usize = 0;
            var cw: u32 = 0;
            var ch: u32 = 0;
            _ = abi.goss_engine_capture_still(e, sess, config, out.ptr, out.len, &ol, &cw, &ch);
            sess.capture_tile_cap = 0;
            sess.capture_no_stream = false;
            return ct.peakBytes() - base;
        }
    }.run;

    const peak_stream = measure(engine, session, counter, &cfg, buf, false);
    const peak_full = measure(engine, session, counter, &cfg, buf, true);
    // Sanity: the capture itself still succeeds and is the right size.
    session.capture_tile_cap = 100;
    const status = abi.goss_engine_capture_still(engine, session, &cfg, buf.ptr, buf.len, &out_len, &ow, &oh);
    session.capture_tile_cap = 0;
    if (status != .ok or ow != 800 or oh != 600) {
        std.debug.print("conformance: FAIL peak-bounded capture ({d}x{d})\n", .{ ow, oh });
        return false;
    }
    // The full-buffer path must peak at least a render buffer higher, and
    // the streaming path must not carry a full render buffer.
    if (peak_full < peak_stream + render_size - (render_size / 8)) {
        std.debug.print("conformance: FAIL streaming did not save a render buffer (stream {d}, full {d}, render {d})\n", .{ peak_stream, peak_full, render_size });
        return false;
    }
    std.debug.print("conformance: PROOF a tiled PNG capture streams: peak heap {d} bytes vs {d} for the full-buffer path, saving ~{d} bytes (the render buffer) across an 8x6 grid\n", .{ peak_stream, peak_full, peak_full - peak_stream });
    return true;
}

/// Proves lens strand hair: the strands hang and settle deterministically
/// across frames (the head pose drives them live on device; here a fixed
/// pose gives a bit-stable host proof), settled differing from initial.
fn proveHairSim(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/hair-sim", ".lens-packages/hair-sim".len) != .ok) {
            std.debug.print("conformance: FAIL hair lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the hair did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-hair-sim.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL hair is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF strand hair driven by the head pose settles deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves the zero-mask degradation: hair-recolor against a model with
/// no hair class renders exactly the frame it renders with no
/// segmentation at all, and both differ from the real multiclass
/// render - the masked effect draws nothing, never everywhere.
fn proveMaskDegradation(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    try renderOnce(gpa, engine, ".lens-packages/hair-recolor", "zig-out/conformance-hair-degraded", single_class_model_path);
    settle(engine);
    try renderOnce(gpa, engine, ".lens-packages/hair-recolor", "zig-out/conformance-hair-unsegmented", null);
    settle(engine);

    const degraded = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-hair-degraded.tga", gpa, .limited(8 << 20));
    defer gpa.free(degraded);
    const unsegmented = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-hair-unsegmented.tga", gpa, .limited(8 << 20));
    defer gpa.free(unsegmented);
    if (!std.mem.eql(u8, degraded, unsegmented)) {
        std.debug.print("conformance: FAIL a hair mask without a hair class must render exactly like no segmentation\n", .{});
        return false;
    }
    const real = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-hair-recolor-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(real);
    if (std.mem.eql(u8, degraded, real)) {
        std.debug.print("conformance: FAIL the multiclass hair render must differ from the degraded render\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a named mask channel without live data degrades to zero, never all-foreground\n", .{});
    return true;
}

fn proveMaterialGraph(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // material-tint authors its shader as a node graph; packaging lowered
    // and compiled it. Render it twice: it must load, run, and draw real
    // tinted content deterministically.
    try renderOnce(gpa, engine, ".lens-packages/material-tint", "zig-out/conformance-material-a", null);
    settle(engine);
    try renderOnce(gpa, engine, ".lens-packages/material-tint", "zig-out/conformance-material-b", null);
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-material-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-material-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL a material-graph shader is not deterministic\n", .{});
        return false;
    }
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (a[18..]) |byte| {
        lo = @min(lo, byte);
        hi = @max(hi, byte);
    }
    if (hi - lo < 10) {
        std.debug.print("conformance: FAIL the material shader drew a flat frame, it never sampled the input\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a lens-authored material graph compiles, loads, and renders real content deterministically\n", .{});
    return true;
}

/// The mean r, g, b over a 40x40 centre block of a 400x300 RGBA capture -
/// a low-noise read of a solid frame's one colour.
fn centreMean(shot: []const u8) [3]f32 {
    var sum = [3]u64{ 0, 0, 0 };
    var count: u64 = 0;
    var row: usize = 130;
    while (row < 170) : (row += 1) {
        var col: usize = 180;
        while (col < 220) : (col += 1) {
            const i = (row * @as(usize, width) + col) * 4;
            sum[0] += shot[i + 0];
            sum[1] += shot[i + 1];
            sum[2] += shot[i + 2];
            count += 1;
        }
    }
    const n: f32 = @floatFromInt(count);
    return .{
        @as(f32, @floatFromInt(sum[0])) / n,
        @as(f32, @floatFromInt(sum[1])) / n,
        @as(f32, @floatFromInt(sum[2])) / n,
    };
}

/// Proves the material colormatrix op computes an exact 3x3 colour transform,
/// the primitive behind a generic colour matrix, an rgb gain, or a luminance
/// compress in a shader.pass lens. A solid frame through material-color-matrix
/// must equal its sepia matrix times the plain input to a byte, and be stable.
fn proveMaterialOps(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const solid = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(solid);
    // Three distinct channels, so every output channel mixing all three
    // inputs tests the off-diagonal matrix terms, not just the row sums a
    // grey would.
    var p: usize = 0;
    while (p < solid.len) : (p += 4) {
        solid[p + 0] = 200;
        solid[p + 1] = 120;
        solid[p + 2] = 60;
        solid[p + 3] = 255;
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = solid }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    const plain = try captureStylizeShot(gpa, engine, planes, null);
    defer gpa.free(plain);
    const sepia_a = try captureStylizeShot(gpa, engine, planes, ".lens-packages/material-color-matrix");
    defer gpa.free(sepia_a);
    const sepia_b = try captureStylizeShot(gpa, engine, planes, ".lens-packages/material-color-matrix");
    defer gpa.free(sepia_b);

    if (!std.mem.eql(u8, sepia_a, sepia_b)) {
        std.debug.print("conformance: FAIL colormatrix material is not bit-stable across runs\n", .{});
        return false;
    }

    const in = centreMean(plain);
    const got = centreMean(sepia_a);
    // The sepia rows the lens authors, applied to the plain input the shader
    // samples. Byte in, byte out, clamped exactly as saturate does on device.
    const mat = [3][3]f32{
        .{ 0.393, 0.769, 0.189 },
        .{ 0.349, 0.686, 0.168 },
        .{ 0.272, 0.534, 0.131 },
    };
    var want: [3]f32 = undefined;
    var max_shift: f32 = 0;
    for (0..3) |row| {
        const acc = mat[row][0] * in[0] + mat[row][1] * in[1] + mat[row][2] * in[2];
        want[row] = std.math.clamp(acc, 0.0, 255.0);
        const shift = @abs(want[row] - in[row]);
        if (shift > max_shift) max_shift = shift;
    }
    // The chosen input must actually move under the matrix, so the match
    // below is a real constraint, never trivially met by an identity.
    if (max_shift < 20.0) {
        std.debug.print("conformance: FAIL colormatrix proof input does not exercise the transform\n", .{});
        return false;
    }
    var max_err: f32 = 0;
    for (0..3) |ch| {
        const err = @abs(got[ch] - want[ch]);
        if (err > max_err) max_err = err;
    }
    if (max_err > 3.0) {
        std.debug.print(
            "conformance: FAIL colormatrix is not the exact sepia transform: in ({d:.1},{d:.1},{d:.1}) got ({d:.1},{d:.1},{d:.1}) want ({d:.1},{d:.1},{d:.1}) err {d:.2}\n",
            .{ in[0], in[1], in[2], got[0], got[1], got[2], want[0], want[1], want[2], max_err },
        );
        return false;
    }
    std.debug.print("conformance: PROOF a material colormatrix op applies an exact 3x3 colour transform (sepia) deterministically (err {d:.2})\n", .{max_err});
    return true;
}

fn proveSceneSegmentation(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // The deeplab scene segmenter infers 21 classes at 257 x 257 - both
    // past the portrait segmenters' shape. It must load, resample onto
    // the canonical mask grid, and drive the subject mask deterministically.
    try renderOnce(gpa, engine, ".lens-packages/background-swap", "zig-out/conformance-scene-a", scene_model_path);
    settle(engine);
    try renderOnce(gpa, engine, ".lens-packages/background-swap", "zig-out/conformance-scene-b", scene_model_path);
    settle(engine);
    try renderOnce(gpa, engine, ".lens-packages/background-swap", "zig-out/conformance-scene-unseg", null);
    settle(engine);

    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-scene-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-scene-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the deeplab scene segmenter is not deterministic across runs\n", .{});
        return false;
    }
    const unseg = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-scene-unseg.tga", gpa, .limited(8 << 20));
    defer gpa.free(unseg);
    if (std.mem.eql(u8, a, unseg)) {
        std.debug.print("conformance: FAIL the deeplab scene mask changed nothing - the model never drove the composite\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a 21-class 257x257 scene segmenter resamples onto the canonical mask grid and drives the subject mask deterministically\n", .{});
    return true;
}

fn proveClassOutline(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // An outline.pass with a "person" mask traces the subject boundary off the
    // segmentation mask instead of depth; with no segmenter the class is the
    // zero mask, so the outline degrades to nothing.
    try renderOnce(gpa, engine, ".lens-packages/outline-person", "zig-out/conformance-outline-a", single_class_model_path);
    settle(engine);
    try renderOnce(gpa, engine, ".lens-packages/outline-person", "zig-out/conformance-outline-b", single_class_model_path);
    settle(engine);
    try renderOnce(gpa, engine, ".lens-packages/outline-person", "zig-out/conformance-outline-unseg", null);
    settle(engine);

    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-outline-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-outline-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the person-mask outline is not deterministic across runs\n", .{});
        return false;
    }
    const unseg = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-outline-unseg.tga", gpa, .limited(8 << 20));
    defer gpa.free(unseg);
    if (std.mem.eql(u8, a, unseg)) {
        std.debug.print("conformance: FAIL the person-mask outline drew nothing - the mask edge never traced\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF an outline.pass traces a segmentation class edge, a rim absent when the class is, bit-stable across runs\n", .{});
    return true;
}

fn proveHeadMatte(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // An outline.pass masked to "head" rims the face region off the face
    // landmark hull with no segmentation model; with no face tracked the
    // channel is the zero mask, so the rim degrades to nothing.
    try renderOnceWith(gpa, engine, ".lens-packages/outline-head", "zig-out/conformance-head-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-head", "zig-out/conformance-head-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-head", "zig-out/conformance-head-noface", .{ .face = false });
    settle(engine);

    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-head-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-head-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the head matte outline is not deterministic across runs\n", .{});
        return false;
    }
    const noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-head-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(noface);
    if (std.mem.eql(u8, a, noface)) {
        std.debug.print("conformance: FAIL the head matte drew nothing - the landmark hull never rasterized\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF an outline.pass rims the face-landmark head matte, gone with no face, bit-stable across runs\n", .{});
    return true;
}

/// The largest absolute per-channel difference between the two captures at
/// pixel index i (four bytes per pixel, rgb weighed).
fn pixelChannelDiff(a: []const u8, b: []const u8, i: usize) u8 {
    var d: u8 = 0;
    var ch: usize = 0;
    while (ch < 3) : (ch += 1) {
        const cd = if (a[i + ch] > b[i + ch]) a[i + ch] - b[i + ch] else b[i + ch] - a[i + ch];
        if (cd > d) d = cd;
    }
    return d;
}

/// The mean absolute per-channel difference between two captures over every
/// pixel - low when they hold the same image, high when they diverge.
fn wholeFrameMeanDiff(a: []const u8, b: []const u8) u32 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i + 3 < a.len) : (i += 4) {
        var ch: usize = 0;
        while (ch < 3) : (ch += 1) {
            sum += if (a[i + ch] > b[i + ch]) a[i + ch] - b[i + ch] else b[i + ch] - a[i + ch];
        }
    }
    return @intCast(sum / (a.len / 4 * 3));
}

/// Renders one inline-JSON lens (or the plain frame when json is null) over the
/// corpus, optionally with the face tracker live so the head matte fills, and
/// reads the composited frame back off the GPU.
fn captureOccluderShot(gpa: std.mem.Allocator, engine: *abi.Engine, planes: Nv12Copy, json: ?[]const u8, face: bool) ![]u8 {
    const half_w = (planes.width + 1) / 2;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    var face_bytes: ?[]u8 = null;
    defer if (face_bytes) |fb| gpa.free(fb);
    if (face) {
        face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        if (abi.goss_session_enable_face_tracking(session, face_bytes.?.ptr, face_bytes.?.len, 2) != .ok) return error.EnableFaceTrackingFailed;
    }
    if (json) |j| {
        if (abi.goss_session_activate_lens(session, j.ptr, j.len) != .ok) {
            std.debug.print("conformance: FAIL head-occluder lens activation\n", .{});
            return error.ActivationFailed;
        }
    }
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    if (face) {
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
    }
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var shot_width: u32 = 0;
    var shot_height: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) return error.CaptureFailed;
    return shot;
}

/// Proves the head occluder hides 3D content behind the head. A grade whitens
/// the whole frame as a stand-in content layer; an occluder.pass after it
/// reveals the head matte's camera frame, so the head region shows the head,
/// not the object, while outside it the object still shows - keyed to the face.
fn proveHeadOccluder(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    const cap_w: usize = 400;
    const corner: usize = 30;

    // The object behind the head: a grade that whitens the whole frame, a
    // synthetic content layer standing in for 3D content drawn behind the head.
    const content_json =
        \\{"glf":"1.0","id":"goss.reference.head-occluder-content","version":"1.0.0","display_name":"Occluder Content","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"obj","type":"grade.pass","inputs":{"frame":"camera"},"params":{},"grade":{"brightness":2.0}}],"triggers":[]}
    ;
    // The same content with a head occluder after it: the head matte reveals
    // the camera frame, so the whitened object is hidden behind the head.
    const occluder_json =
        \\{"glf":"1.0","id":"goss.reference.head-occluder-proof","version":"1.0.0","display_name":"Occluder Proof","engine_compat":">=0.5","capabilities":["face"],"parameters":[],"nodes":[{"id":"obj","type":"grade.pass","inputs":{"frame":"camera"},"params":{},"grade":{"brightness":2.0}},{"id":"head","type":"occluder.pass","inputs":{"frame":"obj"},"params":{},"occluder":{"mask":"head","expand":0.0,"softness":0.03}}],"triggers":[]}
    ;

    const plain = try captureOccluderShot(gpa, engine, planes, null, true);
    defer gpa.free(plain);
    const content = try captureOccluderShot(gpa, engine, planes, content_json, true);
    defer gpa.free(content);
    const occ_a = try captureOccluderShot(gpa, engine, planes, occluder_json, true);
    defer gpa.free(occ_a);
    const occ_b = try captureOccluderShot(gpa, engine, planes, occluder_json, true);
    defer gpa.free(occ_b);
    const occ_noface = try captureOccluderShot(gpa, engine, planes, occluder_json, false);
    defer gpa.free(occ_noface);

    if (!std.mem.eql(u8, occ_a, occ_b)) {
        std.debug.print("conformance: FAIL the head occluder is not deterministic across runs\n", .{});
        return false;
    }
    // The reveal region is where the occluder changed the frame versus the
    // no-face control (whose head matte is the zero mask): the head matte. Over
    // it, sum the distance from the camera frame and from the whitened object.
    var reveal_count: usize = 0;
    var to_camera: u64 = 0;
    var to_object: u64 = 0;
    var i: usize = 0;
    while (i + 3 < occ_a.len) : (i += 4) {
        if (pixelChannelDiff(occ_a, occ_noface, i) <= 8) continue;
        reveal_count += 1;
        var ch: usize = 0;
        while (ch < 3) : (ch += 1) {
            to_camera += if (occ_a[i + ch] > plain[i + ch]) occ_a[i + ch] - plain[i + ch] else plain[i + ch] - occ_a[i + ch];
            to_object += if (occ_a[i + ch] > content[i + ch]) occ_a[i + ch] - content[i + ch] else content[i + ch] - occ_a[i + ch];
        }
    }
    // The head was present and occluded a real block of the object.
    if (reveal_count < 500) {
        std.debug.print("conformance: FAIL the occluder revealed too small a region ({d} pixels)\n", .{reveal_count});
        return false;
    }
    // No colour of its own: over the revealed head the frame sits far closer to
    // the camera than to the whitened object, so it shows the head not the object.
    if (!(to_camera * 3 < to_object)) {
        std.debug.print("conformance: FAIL the head region does not reveal the camera (camera dist {d}, object dist {d})\n", .{ to_camera, to_object });
        return false;
    }
    // Outside the head the object is untouched: the top-left corner is
    // byte-identical to the no-face control, so the reveal is local to the matte.
    if (!cornerBlockEqual(occ_a, occ_noface, cap_w, corner)) {
        std.debug.print("conformance: FAIL the occluder changed a corner outside the head matte\n", .{});
        return false;
    }
    // Keyed to the face: with no face the head matte is empty, so the object
    // shows through the whole frame, the control staying close to the object.
    if (!(wholeFrameMeanDiff(occ_noface, content) < 4)) {
        std.debug.print("conformance: FAIL with no face the occluder still altered the object ({d})\n", .{wholeFrameMeanDiff(occ_noface, content)});
        return false;
    }
    std.debug.print("conformance: PROOF the head occluder hides content behind the head: over {d} revealed head pixels the frame shows the camera not the object (camera dist {d}, object dist {d}), a corner outside the matte is byte-identical, gone with no face, bit-stable\n", .{ reveal_count, to_camera, to_object });
    return true;
}

fn proveHandMatte(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // An outline.pass masked to "hand" rims each tracked hand off its
    // landmark hull with no segmentation model; with no hand tracked the
    // channel is the zero mask, so the rim degrades to nothing.
    try renderOnceWith(gpa, engine, ".lens-packages/outline-hand", "zig-out/conformance-hand-a", .{ .corpus = hand_corpus_path, .face = false, .hands = true });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-hand", "zig-out/conformance-hand-b", .{ .corpus = hand_corpus_path, .face = false, .hands = true });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-hand", "zig-out/conformance-hand-nohand", .{ .corpus = hand_corpus_path, .face = false, .hands = false });
    settle(engine);

    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-hand-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-hand-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the hand matte outline is not deterministic across runs\n", .{});
        return false;
    }
    const nohand = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-hand-nohand.tga", gpa, .limited(8 << 20));
    defer gpa.free(nohand);
    if (std.mem.eql(u8, a, nohand)) {
        std.debug.print("conformance: FAIL the hand matte drew nothing - the landmark hull never rasterized\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF an outline.pass rims the hand-landmark matte, gone with no hand, bit-stable across runs\n", .{});
    return true;
}

fn proveLipsMatte(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // First prove the outer-lip loop is anatomically the lips: on a real
    // tracked face its centroid sits below the nose, above the chin, and
    // between the two mouth corners, so a wrong loop would fail here.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL lips face tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const lm = &result.landmarks;
        var cx: f32 = 0;
        var cy: f32 = 0;
        for (abi.outer_lip_loop) |idx| {
            cx += lm[@as(usize, idx) * 3];
            cy += lm[@as(usize, idx) * 3 + 1];
        }
        cx /= @floatFromInt(abi.outer_lip_loop.len);
        cy /= @floatFromInt(abi.outer_lip_loop.len);
        const nose_y = lm[1 * 3 + 1];
        const chin_y = lm[152 * 3 + 1];
        if (!(nose_y < cy and cy < chin_y)) {
            std.debug.print("conformance: FAIL lip centroid not between nose and chin (y {d:.1} {d:.1} {d:.1})\n", .{ nose_y, cy, chin_y });
            return false;
        }
        const lo_x = @min(lm[61 * 3], lm[291 * 3]);
        const hi_x = @max(lm[61 * 3], lm[291 * 3]);
        if (!(lo_x < cx and cx < hi_x)) {
            std.debug.print("conformance: FAIL lip centroid not between the mouth corners (x {d:.1} {d:.1} {d:.1})\n", .{ lo_x, cx, hi_x });
            return false;
        }
    }

    // Then prove the render: the outline rims the lips, gone with no face,
    // bit-stable across runs.
    try renderOnceWith(gpa, engine, ".lens-packages/outline-lips", "zig-out/conformance-lips-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-lips", "zig-out/conformance-lips-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-lips", "zig-out/conformance-lips-noface", .{ .face = false });
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-lips-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-lips-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the lips matte outline is not deterministic across runs\n", .{});
        return false;
    }
    const noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-lips-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(noface);
    if (std.mem.eql(u8, a, noface)) {
        std.debug.print("conformance: FAIL the lips matte drew nothing - the lip loop never rasterized\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF the lips matte fills the outer-lip loop below the nose between the corners, rims the mouth, gone with no face, bit-stable\n", .{});
    return true;
}

/// The centroid (x, y in frame pixels) of a ring of mesh landmarks, read from
/// a face result's flat landmark array.
fn ringCentroid(lm: []const f32, loop: []const u16) [2]f32 {
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (loop) |idx| {
        cx += lm[@as(usize, idx) * 3];
        cy += lm[@as(usize, idx) * 3 + 1];
    }
    const n: f32 = @floatFromInt(loop.len);
    return .{ cx / n, cy / n };
}

/// The centroid (x, y) of a lash-line band ring, so a proof can place the band
/// against the eye it rides.
fn bandCentroid(ring: []const [2]f32) [2]f32 {
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (ring) |p| {
        cx += p[0];
        cy += p[1];
    }
    const n: f32 = @floatFromInt(ring.len);
    return .{ cx / n, cy / n };
}

fn proveEyesMatte(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // First prove the eye loops are anatomically the eyes: on a real tracked
    // face each eye centroid sits above the lips and the two flank the nose,
    // so a swapped or wrong loop would fail here.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL eyes face tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const lm = &result.landmarks;
        const left = ringCentroid(lm, &abi.left_eye_loop);
        const right = ringCentroid(lm, &abi.right_eye_loop);
        const lips = ringCentroid(lm, &abi.outer_lip_loop);
        if (!(left[1] < lips[1] and right[1] < lips[1])) {
            std.debug.print("conformance: FAIL an eye centroid not above the lips (y L {d:.1} R {d:.1} lips {d:.1})\n", .{ left[1], right[1], lips[1] });
            return false;
        }
        const nose_x = lm[1 * 3];
        if ((left[0] > nose_x) == (right[0] > nose_x)) {
            std.debug.print("conformance: FAIL the eyes not on opposite sides of the nose (x L {d:.1} R {d:.1} nose {d:.1})\n", .{ left[0], right[0], nose_x });
            return false;
        }
    }

    // Then prove the render: the outline rims both eyes, gone with no face,
    // bit-stable across runs.
    try renderOnceWith(gpa, engine, ".lens-packages/outline-eyes", "zig-out/conformance-eyes-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-eyes", "zig-out/conformance-eyes-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-eyes", "zig-out/conformance-eyes-noface", .{ .face = false });
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-eyes-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-eyes-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the eyes matte outline is not deterministic across runs\n", .{});
        return false;
    }
    const noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-eyes-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(noface);
    if (std.mem.eql(u8, a, noface)) {
        std.debug.print("conformance: FAIL the eyes matte drew nothing - the eye loops never rasterized\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF the eyes matte fills both eye loops above the lips and flanking the nose, rims the eyes, gone with no face, bit-stable\n", .{});
    return true;
}

fn proveBrowsMatte(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // First prove the brow loops are anatomically the brows: on a real
    // tracked face each brow centroid sits above its own eye and the two
    // flank the nose, so a swapped or wrong loop would fail here.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL brows face tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const lm = &result.landmarks;
        const left_brow = ringCentroid(lm, &abi.left_brow_loop);
        const right_brow = ringCentroid(lm, &abi.right_brow_loop);
        const left_eye = ringCentroid(lm, &abi.left_eye_loop);
        const right_eye = ringCentroid(lm, &abi.right_eye_loop);
        if (!(left_brow[1] < left_eye[1] and right_brow[1] < right_eye[1])) {
            std.debug.print("conformance: FAIL a brow centroid not above its eye (y browL {d:.1} eyeL {d:.1} browR {d:.1} eyeR {d:.1})\n", .{ left_brow[1], left_eye[1], right_brow[1], right_eye[1] });
            return false;
        }
        const nose_x = lm[1 * 3];
        if ((left_brow[0] > nose_x) == (right_brow[0] > nose_x)) {
            std.debug.print("conformance: FAIL the brows not on opposite sides of the nose (x L {d:.1} R {d:.1} nose {d:.1})\n", .{ left_brow[0], right_brow[0], nose_x });
            return false;
        }
    }

    // Then prove the render: the outline rims both brows, gone with no face,
    // bit-stable across runs.
    try renderOnceWith(gpa, engine, ".lens-packages/outline-brows", "zig-out/conformance-brows-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-brows", "zig-out/conformance-brows-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/outline-brows", "zig-out/conformance-brows-noface", .{ .face = false });
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-brows-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-brows-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the brows matte outline is not deterministic across runs\n", .{});
        return false;
    }
    const noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-brows-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(noface);
    if (std.mem.eql(u8, a, noface)) {
        std.debug.print("conformance: FAIL the brows matte drew nothing - the brow loops never rasterized\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF the brows matte fills both brow loops above the eyes and flanking the nose, rims the brows, gone with no face, bit-stable\n", .{});
    return true;
}

fn proveTint(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // A tint.pass masked to "lips" blends its color into the lip region off
    // the lips matte; with no face the mask is empty, so the tint fades to
    // nothing and the frame passes through.
    try renderOnceWith(gpa, engine, ".lens-packages/lip-tint", "zig-out/conformance-tint-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lip-tint", "zig-out/conformance-tint-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lip-tint", "zig-out/conformance-tint-noface", .{ .face = false });
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-tint-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-tint-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the lip tint is not deterministic across runs\n", .{});
        return false;
    }
    const noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-tint-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(noface);
    if (std.mem.eql(u8, a, noface)) {
        std.debug.print("conformance: FAIL the lip tint drew nothing - the mask never keyed the color\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a tint.pass blends its color into the lips matte, gone with no face, bit-stable across runs\n", .{});
    return true;
}

fn proveMakeup(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // Eyeshadow and brow tint reuse tint.pass over the eyes and brows mattes.
    // Each colors its own region, so both differ from the plain frame and
    // from each other; with no face the control is the untouched frame.
    try renderOnceWith(gpa, engine, ".lens-packages/eyeshadow", "zig-out/conformance-eyeshadow", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/eyeshadow", "zig-out/conformance-makeup-control", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/brow-tint", "zig-out/conformance-brow-tint", .{});
    settle(engine);
    const eyeshadow = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-eyeshadow.tga", gpa, .limited(8 << 20));
    defer gpa.free(eyeshadow);
    const control = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-makeup-control.tga", gpa, .limited(8 << 20));
    defer gpa.free(control);
    const brow_tint = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-brow-tint.tga", gpa, .limited(8 << 20));
    defer gpa.free(brow_tint);
    if (std.mem.eql(u8, eyeshadow, control)) {
        std.debug.print("conformance: FAIL eyeshadow drew nothing over the eyes\n", .{});
        return false;
    }
    if (std.mem.eql(u8, brow_tint, control)) {
        std.debug.print("conformance: FAIL brow tint drew nothing over the brows\n", .{});
        return false;
    }
    if (std.mem.eql(u8, eyeshadow, brow_tint)) {
        std.debug.print("conformance: FAIL eyeshadow and brow tint colored the same region\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF eyeshadow and brow tint each color their own matte, both differ from the plain frame and from each other\n", .{});
    return true;
}

/// Counts the bytes that differ between two equal-length renders, a stand-in
/// for how large a region an effect touched.
fn countDiff(a: []const u8, b: []const u8) usize {
    var n: usize = 0;
    const len = @min(a.len, b.len);
    for (a[0..len], b[0..len]) |x, y| {
        if (x != y) n += 1;
    }
    return n;
}

fn proveIris(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // First prove the iris loops are anatomically the irises: on a real
    // tracked face each iris centroid sits above the lips and the two flank
    // the nose, present only because the model refines iris landmarks.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL iris face tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const lm = &result.landmarks;
        const left = ringCentroid(lm, &abi.left_iris_loop);
        const right = ringCentroid(lm, &abi.right_iris_loop);
        const lips = ringCentroid(lm, &abi.outer_lip_loop);
        if (!(left[1] < lips[1] and right[1] < lips[1])) {
            std.debug.print("conformance: FAIL an iris centroid not above the lips (y L {d:.1} R {d:.1} lips {d:.1})\n", .{ left[1], right[1], lips[1] });
            return false;
        }
        const nose_x = lm[1 * 3];
        if ((left[0] > nose_x) == (right[0] > nose_x)) {
            std.debug.print("conformance: FAIL the irises not on opposite sides of the nose (x L {d:.1} R {d:.1} nose {d:.1})\n", .{ left[0], right[0], nose_x });
            return false;
        }
    }

    // Then prove the render: the iris tint colors a non-empty region strictly
    // smaller than eyeshadow over the whole eye, and is gone with no face.
    try renderOnceWith(gpa, engine, ".lens-packages/iris-tint", "zig-out/conformance-iris-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/iris-tint", "zig-out/conformance-iris-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/iris-tint", "zig-out/conformance-iris-control", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/eyeshadow", "zig-out/conformance-iris-eyes", .{});
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-iris-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-iris-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    const control = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-iris-control.tga", gpa, .limited(8 << 20));
    defer gpa.free(control);
    const eyes = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-iris-eyes.tga", gpa, .limited(8 << 20));
    defer gpa.free(eyes);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the iris tint is not deterministic across runs\n", .{});
        return false;
    }
    const iris_diff = countDiff(a, control);
    const eyes_diff = countDiff(eyes, control);
    if (iris_diff == 0) {
        std.debug.print("conformance: FAIL the iris tint drew nothing - no refined iris landmarks\n", .{});
        return false;
    }
    if (iris_diff >= eyes_diff) {
        std.debug.print("conformance: FAIL the iris tint is not smaller than the eye (iris {d} eye {d})\n", .{ iris_diff, eyes_diff });
        return false;
    }
    std.debug.print("conformance: PROOF the iris tint colors just the iris, a region smaller than the eye, gone with no face, bit-stable\n", .{});
    return true;
}

fn proveFoundation(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // Foundation tints the face_skin class, a model-derived channel, so this
    // proves tint.pass keys the multiclass segmenter's classes as well as the
    // landmark mattes; with no segmenter the class is empty and it fades out.
    try renderOnceWith(gpa, engine, ".lens-packages/foundation", "zig-out/conformance-foundation-a", .{ .segmentation_model = multiclass_model_path, .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/foundation", "zig-out/conformance-foundation-b", .{ .segmentation_model = multiclass_model_path, .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/foundation", "zig-out/conformance-foundation-unseg", .{ .face = false });
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-foundation-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-foundation-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the foundation tint is not deterministic across runs\n", .{});
        return false;
    }
    const unseg = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-foundation-unseg.tga", gpa, .limited(8 << 20));
    defer gpa.free(unseg);
    if (std.mem.eql(u8, a, unseg)) {
        std.debug.print("conformance: FAIL the foundation tint drew nothing - the model class never keyed the color\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a tint.pass keys a model class, foundation over face_skin, gone with no segmenter, bit-stable\n", .{});
    return true;
}

/// One composited frame captured through the deterministic readback path
/// (goss_engine_capture_frame), kept as tightly packed RGBA so a proof can
/// sample any pixel the lens produced without touching the flaky backbuffer
/// screenshot path.
const Shot = struct {
    w: usize,
    h: usize,
    data: []u8,
    fn r(s: Shot, x: usize, y: usize) i32 {
        return @as(i32, s.data[(y * s.w + x) * 4]);
    }
    fn g(s: Shot, x: usize, y: usize) i32 {
        return @as(i32, s.data[(y * s.w + x) * 4 + 1]);
    }
    fn b(s: Shot, x: usize, y: usize) i32 {
        return @as(i32, s.data[(y * s.w + x) * 4 + 2]);
    }
};

/// Activates a lens over the corpus frame and reads the composited output back
/// as RGBA. face gates whether the face tracker runs, so the same lens with no
/// face is the control an image-projection effect degrades to.
fn captureLens(gpa: std.mem.Allocator, engine: *abi.Engine, bundle_path: []const u8, face: bool) !Shot {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer settle(engine);
    defer abi.destroySession(session);

    const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(face_bytes);
    if (face and abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
        return error.EnableFaceTrackingFailed;
    }
    if (abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len) != .ok) {
        return error.ActivationFailed;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    if (face) {
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
    }
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    // Real frames first, so the paint texture load and the landmark mattes
    // land before the capture path reads the composite back.
    for (0..12) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    var w: u32 = 0;
    var h: u32 = 0;
    var probe: u8 = 0;
    _ = abi.goss_engine_capture_frame(engine, session, @ptrCast(&probe), 0, &w, &h);
    if (w == 0 or h == 0) return error.CaptureSize;
    const size = @as(usize, w) * @as(usize, h) * 4;
    const data = try gpa.alloc(u8, size);
    errdefer gpa.free(data);
    if (abi.goss_engine_capture_frame(engine, session, data.ptr, size, &w, &h) != .ok) return error.CaptureFailed;
    return .{ .w = w, .h = h, .data = data };
}

fn absDiff(a: i32, b: i32) i32 {
    return if (a > b) a - b else b - a;
}

/// True when four small corner patches, well outside the face mesh, are
/// byte-identical between two renders - so an effect confined to the face
/// left the surround untouched.
fn cornersUnchanged(a: Shot, b: Shot) bool {
    const patch: usize = 12;
    const corners = [_][2]usize{ .{ 0, 0 }, .{ a.w - patch, 0 }, .{ 0, a.h - patch }, .{ a.w - patch, a.h - patch } };
    for (corners) |corner| {
        var yy: usize = 0;
        while (yy < patch) : (yy += 1) {
            var xx: usize = 0;
            while (xx < patch) : (xx += 1) {
                const x = corner[0] + xx;
                const y = corner[1] + yy;
                if (a.r(x, y) != b.r(x, y) or a.g(x, y) != b.g(x, y) or a.b(x, y) != b.b(x, y)) return false;
            }
        }
    }
    return true;
}

fn proveFaceMaterial(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // Where the tracked face sits, so the projected image can be checked
    // against real anatomy: the nose is the facial midline the two-tone
    // image seam should land on.
    var nose_x: f32 = 0;
    var frame_w: f32 = 1;
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL paint.face tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        frame_w = @floatFromInt(planes.width);
        nose_x = result.landmarks[1 * 3] / frame_w;
    }

    const mat = try captureLens(gpa, engine, ".lens-packages/face-projection", true);
    defer gpa.free(mat.data);
    const mat_b = try captureLens(gpa, engine, ".lens-packages/face-projection", true);
    defer gpa.free(mat_b.data);
    const plain = try captureLens(gpa, engine, ".lens-packages/face-projection", false);
    defer gpa.free(plain.data);
    const tat = try captureLens(gpa, engine, ".lens-packages/face-tattoo", true);
    defer gpa.free(tat.data);
    if (mat.w != plain.w or mat.h != plain.h or mat.w != tat.w or mat.h != tat.h or mat.w != mat_b.w) {
        std.debug.print("conformance: FAIL paint.face renders differ in size\n", .{});
        return false;
    }

    // Bit-stable across two runs, and present only with a tracked face.
    if (!std.mem.eql(u8, mat.data, mat_b.data)) {
        std.debug.print("conformance: FAIL the face projection is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, mat.data, plain.data)) {
        std.debug.print("conformance: FAIL the face projection is gone with a tracked face - it never drew\n", .{});
        return false;
    }

    const w = mat.w;
    const h = mat.h;
    var changed: usize = 0;
    var tattoo_changed: usize = 0;
    var blue_count: usize = 0;
    var yellow_count: usize = 0;
    var blue_sum_x: f64 = 0;
    var yellow_sum_x: f64 = 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const pr = plain.r(x, y);
            const pg = plain.g(x, y);
            const pb = plain.b(x, y);
            const mr = mat.r(x, y);
            const mg = mat.g(x, y);
            const mb = mat.b(x, y);
            if (absDiff(mr, pr) + absDiff(mg, pg) + absDiff(mb, pb) > 60) {
                changed += 1;
                if (mb > mr + 60) {
                    blue_count += 1;
                    blue_sum_x += @floatFromInt(x);
                } else if (mr > mb + 60) {
                    yellow_count += 1;
                    yellow_sum_x += @floatFromInt(x);
                }
            }
            if (absDiff(tat.r(x, y), pr) + absDiff(tat.g(x, y), pg) + absDiff(tat.b(x, y), pb) > 60) tattoo_changed += 1;
        }
    }

    const total: f64 = @floatFromInt(w * h);
    if (blue_count == 0 or yellow_count == 0) {
        std.debug.print("conformance: FAIL the projected image's own colors did not appear (blue {d} yellow {d})\n", .{ blue_count, yellow_count });
        return false;
    }
    const wf: f64 = @floatFromInt(w);
    const blue_cx = blue_sum_x / @as(f64, @floatFromInt(blue_count));
    const yellow_cx = yellow_sum_x / @as(f64, @floatFromInt(yellow_count));
    // The projection must clearly repaint the face region, not a stray pixel.
    if (@as(f64, @floatFromInt(changed)) < 0.02 * total) {
        std.debug.print("conformance: FAIL the projection barely touched the frame ({d} px)\n", .{changed});
        return false;
    }
    if (@abs(blue_cx - yellow_cx) < 0.04 * wf) {
        std.debug.print("conformance: FAIL the two-tone halves are not separated on the face ({d:.1} vs {d:.1})\n", .{ blue_cx, yellow_cx });
        return false;
    }
    const seam = (blue_cx + yellow_cx) * 0.5;
    const expected = @as(f64, nose_x) * wf;
    if (@abs(seam - expected) > 0.15 * wf) {
        std.debug.print("conformance: FAIL the image seam did not land on the face midline (seam {d:.1} nose {d:.1})\n", .{ seam, expected });
        return false;
    }
    if (@abs(blue_cx - expected) > 0.35 * wf or @abs(yellow_cx - expected) > 0.35 * wf) {
        std.debug.print("conformance: FAIL the projection smeared off the face\n", .{});
        return false;
    }
    if (!cornersUnchanged(mat, plain)) {
        std.debug.print("conformance: FAIL the projection changed a frame corner outside the face\n", .{});
        return false;
    }

    // The region-masked tattoo drew, kept the corners, and covered a strictly
    // smaller area than the whole-face projection: the contour mask confined it.
    if (tattoo_changed == 0) {
        std.debug.print("conformance: FAIL the region-masked tattoo drew nothing\n", .{});
        return false;
    }
    if (!cornersUnchanged(tat, plain)) {
        std.debug.print("conformance: FAIL the tattoo changed a frame corner outside the face\n", .{});
        return false;
    }
    if (tattoo_changed >= changed) {
        std.debug.print("conformance: FAIL the contour mask did not confine the tattoo below the full projection ({d} vs {d})\n", .{ tattoo_changed, changed });
        return false;
    }

    std.debug.print("conformance: PROOF paint.face projects a lens image through the face UVs (two-tone seam at x {d:.0} lands on the nose at x {d:.0}, {d} px changed), masks it to the face (corners clean), the contour tattoo confines to {d} px, gone with no face, bit-stable\n", .{ seam, expected, changed, tattoo_changed });
    return true;
}

fn proveFaceSwap(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // The tracked face gives the live landmarks the donor warps to; the nose is
    // the facial midline the two-tone donor seam should land on.
    var nose_x: f32 = 0;
    var frame_w: f32 = 1;
    var frame_h: f32 = 1;
    var landmarks: [468 * 3]f32 = undefined;
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL face.swap tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        frame_w = @floatFromInt(planes.width);
        frame_h = @floatFromInt(planes.height);
        nose_x = result.landmarks[1 * 3] / frame_w;
        for (0..468 * 3) |i| landmarks[i] = result.landmarks[i];
    }

    // The seam feather is a graded transition, not a hard cut: zero on the
    // silhouette, one deep inside, with a real band between.
    var min_f: f32 = 1.0;
    var max_f: f32 = 0.0;
    var graded: usize = 0;
    for (face_mesh_topology.vertex_feather) |f| {
        if (f < min_f) min_f = f;
        if (f > max_f) max_f = f;
        if (f > 0.05 and f < 0.95) graded += 1;
    }
    if (!(min_f < 0.001 and max_f > 0.999 and graded > 8)) {
        std.debug.print("conformance: FAIL the swap seam is not a graded feather (min {d:.3} max {d:.3} band {d})\n", .{ min_f, max_f, graded });
        return false;
    }

    // Moving a live landmark carries the swapped region: each vertex rides its
    // tracked landmark, so shifting the nose shifts only the vertices on it.
    var base_pos: [face_mesh_topology.vertex_count * 2]f32 = undefined;
    face_mesh_topology.projectPositions(&landmarks, frame_w, frame_h, &base_pos);
    var moved = landmarks;
    moved[1 * 3] += 0.1 * frame_w;
    var moved_pos: [face_mesh_topology.vertex_count * 2]f32 = undefined;
    face_mesh_topology.projectPositions(&moved, frame_w, frame_h, &moved_pos);
    var carried = false;
    for (face_mesh_topology.vertex_landmarks, 0..) |lm, at| {
        if (lm == 1) {
            if (@abs(moved_pos[at * 2] - base_pos[at * 2]) > 0.05) carried = true;
        } else if (moved_pos[at * 2] != base_pos[at * 2] or moved_pos[at * 2 + 1] != base_pos[at * 2 + 1]) {
            std.debug.print("conformance: FAIL a vertex off the moved landmark shifted with it\n", .{});
            return false;
        }
    }
    if (!carried) {
        std.debug.print("conformance: FAIL moving a live landmark did not carry the swapped mesh\n", .{});
        return false;
    }

    const swap = try captureLens(gpa, engine, ".lens-packages/face-swap", true);
    defer gpa.free(swap.data);
    const swap_b = try captureLens(gpa, engine, ".lens-packages/face-swap", true);
    defer gpa.free(swap_b.data);
    const plain = try captureLens(gpa, engine, ".lens-packages/face-swap", false);
    defer gpa.free(plain.data);
    if (swap.w != plain.w or swap.h != plain.h or swap.w != swap_b.w) {
        std.debug.print("conformance: FAIL face.swap renders differ in size\n", .{});
        return false;
    }

    // Bit-stable across two runs, and present only with a tracked face.
    if (!std.mem.eql(u8, swap.data, swap_b.data)) {
        std.debug.print("conformance: FAIL the face swap is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, swap.data, plain.data)) {
        std.debug.print("conformance: FAIL the face swap is gone with a tracked face - it never drew\n", .{});
        return false;
    }

    const w = swap.w;
    const h = swap.h;
    var changed: usize = 0;
    var blue_count: usize = 0;
    var yellow_count: usize = 0;
    var blue_sum_x: f64 = 0;
    var yellow_sum_x: f64 = 0;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const pr = plain.r(x, y);
            const pg = plain.g(x, y);
            const pb = plain.b(x, y);
            const sr = swap.r(x, y);
            const sg = swap.g(x, y);
            const sb = swap.b(x, y);
            if (absDiff(sr, pr) + absDiff(sg, pg) + absDiff(sb, pb) > 60) {
                changed += 1;
                if (sb > sr + 60) {
                    blue_count += 1;
                    blue_sum_x += @floatFromInt(x);
                } else if (sr > sb + 60) {
                    yellow_count += 1;
                    yellow_sum_x += @floatFromInt(x);
                }
            }
        }
    }

    const total: f64 = @floatFromInt(w * h);
    if (blue_count == 0 or yellow_count == 0) {
        std.debug.print("conformance: FAIL the donor's own colors did not appear (blue {d} yellow {d})\n", .{ blue_count, yellow_count });
        return false;
    }
    const wf: f64 = @floatFromInt(w);
    const blue_cx = blue_sum_x / @as(f64, @floatFromInt(blue_count));
    const yellow_cx = yellow_sum_x / @as(f64, @floatFromInt(yellow_count));
    // The swap must clearly repaint the face region, not a stray pixel.
    if (@as(f64, @floatFromInt(changed)) < 0.02 * total) {
        std.debug.print("conformance: FAIL the swap barely touched the frame ({d} px)\n", .{changed});
        return false;
    }
    const seam = (blue_cx + yellow_cx) * 0.5;
    const expected = @as(f64, nose_x) * wf;
    if (@abs(seam - expected) > 0.15 * wf) {
        std.debug.print("conformance: FAIL the donor seam did not land on the face midline (seam {d:.1} nose {d:.1})\n", .{ seam, expected });
        return false;
    }
    // The face mesh and its feather confine the swap: the frame corners, well
    // outside the mesh, stay byte-identical to the no-swap control.
    if (!cornersUnchanged(swap, plain)) {
        std.debug.print("conformance: FAIL the swap changed a frame corner outside the face\n", .{});
        return false;
    }

    std.debug.print("conformance: PROOF face.swap warps a donor face through the mesh onto the tracked landmarks (two-tone seam at x {d:.0} on the nose at x {d:.0}, {d} px changed), a graded feather (feather {d:.2}..{d:.2}, {d}-vertex band) confines it to the face (corners clean), gone with no face, bit-stable\n", .{ seam, expected, changed, min_f, max_f, graded });
    return true;
}

fn proveGlam(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // The glam look chains three tint.pass nodes (lips, eyes, brows), each
    // reading the previous one's output, so it stacks all three regions and
    // touches more of the frame than any single tint - proving passes compose.
    try renderOnceWith(gpa, engine, ".lens-packages/glam-look", "zig-out/conformance-glam-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/glam-look", "zig-out/conformance-glam-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/glam-look", "zig-out/conformance-glam-control", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lip-tint", "zig-out/conformance-glam-lip", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/eyeshadow", "zig-out/conformance-glam-eye", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/brow-tint", "zig-out/conformance-glam-brow", .{});
    settle(engine);
    const glam_a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-glam-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(glam_a);
    const glam_b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-glam-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(glam_b);
    const control = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-glam-control.tga", gpa, .limited(8 << 20));
    defer gpa.free(control);
    const lip = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-glam-lip.tga", gpa, .limited(8 << 20));
    defer gpa.free(lip);
    const eye = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-glam-eye.tga", gpa, .limited(8 << 20));
    defer gpa.free(eye);
    const brow = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-glam-brow.tga", gpa, .limited(8 << 20));
    defer gpa.free(brow);
    if (!std.mem.eql(u8, glam_a, glam_b)) {
        std.debug.print("conformance: FAIL the glam look is not deterministic across runs\n", .{});
        return false;
    }
    const glam_d = countDiff(glam_a, control);
    const lip_d = countDiff(lip, control);
    const eye_d = countDiff(eye, control);
    const brow_d = countDiff(brow, control);
    if (glam_d == 0) {
        std.debug.print("conformance: FAIL the glam look drew nothing\n", .{});
        return false;
    }
    if (!(glam_d > lip_d and glam_d > eye_d and glam_d > brow_d)) {
        std.debug.print("conformance: FAIL the glam look does not stack past a single region (glam {d} lip {d} eye {d} brow {d})\n", .{ glam_d, lip_d, eye_d, brow_d });
        return false;
    }
    std.debug.print("conformance: PROOF three tint.pass nodes chain into one look, touching more than any single tint, bit-stable\n", .{});
    return true;
}

/// The sum of every pixel byte after the 18-byte TGA header, a monotonic proxy
/// for total frame brightness: a multiply darken can only lower it, a screen
/// lighten can only raise it, across every color channel at once.
fn pixelByteSum(tga: []const u8) u64 {
    if (tga.len <= 18) return 0;
    var sum: u64 = 0;
    for (tga[18..]) |byte| sum += byte;
    return sum;
}

fn proveContourHighlight(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // First prove the region clusters are anatomically placed: on a real
    // tracked face the two cheek-hollow contours flank the nose, the nose-
    // bridge highlight sits central and above the nose tip, and the chin
    // highlight sits below the lips, so a mislabeled cluster would fail here.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL contour face tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const lm = &result.landmarks;
        const cheek_r = ringCentroid(lm, abi.contour_regions[0]);
        const cheek_l = ringCentroid(lm, abi.contour_regions[1]);
        const bridge = ringCentroid(lm, abi.highlight_regions[4]);
        const chin = ringCentroid(lm, abi.highlight_regions[6]);
        const lips = ringCentroid(lm, &abi.outer_lip_loop);
        const nose_x = lm[1 * 3];
        const nose_y = lm[1 * 3 + 1];
        if ((cheek_r[0] > nose_x) == (cheek_l[0] > nose_x)) {
            std.debug.print("conformance: FAIL the contour cheeks not on opposite sides of the nose (x R {d:.1} L {d:.1} nose {d:.1})\n", .{ cheek_r[0], cheek_l[0], nose_x });
            return false;
        }
        const lo_x = @min(cheek_r[0], cheek_l[0]);
        const hi_x = @max(cheek_r[0], cheek_l[0]);
        if (!(lo_x < bridge[0] and bridge[0] < hi_x and bridge[1] < nose_y)) {
            std.debug.print("conformance: FAIL the nose-bridge highlight not central and above the tip (x {d:.1} in {d:.1}..{d:.1}, y {d:.1} tip {d:.1})\n", .{ bridge[0], lo_x, hi_x, bridge[1], nose_y });
            return false;
        }
        if (!(chin[1] > lips[1])) {
            std.debug.print("conformance: FAIL the chin highlight not below the lips (y chin {d:.1} lips {d:.1})\n", .{ chin[1], lips[1] });
            return false;
        }
    }

    // Then prove the render: contour multiplies its shadow into its matte so
    // the frame darkens, highlight screens its light into its matte so the
    // frame brightens, both key off the face and vanish without one, and the
    // combined look is bit-stable across two runs.
    try renderOnceWith(gpa, engine, ".lens-packages/contour-highlight", "zig-out/conformance-ch-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/contour-highlight", "zig-out/conformance-ch-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/contour-highlight", "zig-out/conformance-ch-control", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/face-contour", "zig-out/conformance-ch-contour", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/face-highlight", "zig-out/conformance-ch-highlight", .{});
    settle(engine);
    const ch_a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-ch-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(ch_a);
    const ch_b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-ch-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(ch_b);
    const control = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-ch-control.tga", gpa, .limited(8 << 20));
    defer gpa.free(control);
    const contour = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-ch-contour.tga", gpa, .limited(8 << 20));
    defer gpa.free(contour);
    const highlight = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-ch-highlight.tga", gpa, .limited(8 << 20));
    defer gpa.free(highlight);
    if (!std.mem.eql(u8, ch_a, ch_b)) {
        std.debug.print("conformance: FAIL the contour-highlight look is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, ch_a, control)) {
        std.debug.print("conformance: FAIL the contour-highlight look drew nothing - the mattes never keyed\n", .{});
        return false;
    }
    if (std.mem.eql(u8, contour, control) or std.mem.eql(u8, highlight, control)) {
        std.debug.print("conformance: FAIL a contour or highlight matte never rasterized\n", .{});
        return false;
    }
    const base_sum = pixelByteSum(control);
    if (!(pixelByteSum(contour) < base_sum)) {
        std.debug.print("conformance: FAIL the contour did not darken the frame (contour {d} base {d})\n", .{ pixelByteSum(contour), base_sum });
        return false;
    }
    if (!(pixelByteSum(highlight) > base_sum)) {
        std.debug.print("conformance: FAIL the highlight did not brighten the frame (highlight {d} base {d})\n", .{ pixelByteSum(highlight), base_sum });
        return false;
    }
    std.debug.print("conformance: PROOF contour darkens its cheekbone-hollow matte and highlight brightens its raised-plane matte, both keyed off the face, gone without one, bit-stable\n", .{});
    return true;
}

fn proveEyeMakeup(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // First prove the lash-line band is anatomically placed: on a real tracked
    // face each eye's band centroid sits above that eye's own centre and the
    // two bands flank the nose, so a wrong upper-lid arc would fail here.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL eye-makeup face tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const lm = &result.landmarks;
        var points: [abi.face_landmark_count][2]f32 = undefined;
        for (0..abi.face_landmark_count) |i| points[i] = .{ lm[i * 3], lm[i * 3 + 1] };
        var band: [18][2]f32 = undefined;
        const left_band = bandCentroid(abi.lashLineBand(&points, &abi.left_eye_loop, &band));
        const right_band = bandCentroid(abi.lashLineBand(&points, &abi.right_eye_loop, &band));
        const left_eye = ringCentroid(lm, &abi.left_eye_loop);
        const right_eye = ringCentroid(lm, &abi.right_eye_loop);
        if (!(left_band[1] < left_eye[1] and right_band[1] < right_eye[1])) {
            std.debug.print("conformance: FAIL a lash band not above its eye centre (y bandL {d:.1} eyeL {d:.1} bandR {d:.1} eyeR {d:.1})\n", .{ left_band[1], left_eye[1], right_band[1], right_eye[1] });
            return false;
        }
        const nose_x = lm[1 * 3];
        if ((left_band[0] > nose_x) == (right_band[0] > nose_x)) {
            std.debug.print("conformance: FAIL the lash bands not on opposite sides of the nose (x L {d:.1} R {d:.1} nose {d:.1})\n", .{ left_band[0], right_band[0], nose_x });
            return false;
        }
    }

    // Then prove the render: eyeliner, mascara, and false lashes each darken the
    // lash-line band off the same channel, heavier as the tint weight climbs,
    // all keyed off the face and gone without one, bit-stable across two runs.
    try renderOnceWith(gpa, engine, ".lens-packages/eyeliner", "zig-out/conformance-eyeliner-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/eyeliner", "zig-out/conformance-eyeliner-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/eyeliner", "zig-out/conformance-eyeliner-noface", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/mascara", "zig-out/conformance-mascara", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/false-lashes", "zig-out/conformance-false-lashes", .{});
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-eyeliner-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-eyeliner-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    const noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-eyeliner-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(noface);
    const mascara = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-mascara.tga", gpa, .limited(8 << 20));
    defer gpa.free(mascara);
    const lashes = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-false-lashes.tga", gpa, .limited(8 << 20));
    defer gpa.free(lashes);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the eyeliner is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, a, noface)) {
        std.debug.print("conformance: FAIL the eyeliner drew nothing - the lash-line band never keyed\n", .{});
        return false;
    }
    const base = pixelByteSum(noface);
    if (!(pixelByteSum(a) < base and pixelByteSum(mascara) < base and pixelByteSum(lashes) < base)) {
        std.debug.print("conformance: FAIL a lash-line tint did not darken the band (liner {d} mascara {d} lashes {d} base {d})\n", .{ pixelByteSum(a), pixelByteSum(mascara), pixelByteSum(lashes), base });
        return false;
    }
    if (!(pixelByteSum(lashes) < pixelByteSum(a))) {
        std.debug.print("conformance: FAIL the false lashes did not read heavier than the eyeliner (lashes {d} liner {d})\n", .{ pixelByteSum(lashes), pixelByteSum(a) });
        return false;
    }
    if (std.mem.eql(u8, a, mascara) or std.mem.eql(u8, mascara, lashes) or std.mem.eql(u8, a, lashes)) {
        std.debug.print("conformance: FAIL two lash-line looks produced the same pixels\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF eyeliner, mascara, and false lashes darken the upper lash-line band above each eye and flanking the nose, heavier by tint weight, gone with no face, bit-stable\n", .{});
    return true;
}

/// Width, height, and bytes per pixel read from a TGA's 18-byte header.
const TgaDims = struct { w: usize, h: usize, bpp: usize };
fn tgaDims(tga: []const u8) TgaDims {
    const w = @as(usize, tga[12]) | (@as(usize, tga[13]) << 8);
    const h = @as(usize, tga[14]) | (@as(usize, tga[15]) << 8);
    return .{ .w = w, .h = h, .bpp = @as(usize, tga[16]) / 8 };
}

/// The centroid (x, y) of one eye's lash tip row in the built strip, so a
/// proof can place the strip's tips against the eye it rises from.
fn lashTipCentroid(pos: *const [lash_mesh.vertex_count * 2]f32, eye: usize) [2]f32 {
    const off = (eye * lash_mesh.points_per_eye * 2 + lash_mesh.points_per_eye) * 2;
    var cx: f32 = 0;
    var cy: f32 = 0;
    for (0..lash_mesh.points_per_eye) |i| {
        cx += pos[off + i * 2];
        cy += pos[off + i * 2 + 1];
    }
    const n: f32 = @floatFromInt(lash_mesh.points_per_eye);
    return .{ cx / n, cy / n };
}

fn proveLashMesh(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // First prove the strip geometry the renderer draws: on a real tracked
    // face each eye's tip row rises above that eye's centre and the two rows
    // flank the nose, and shifting the face carries the whole strip with it.
    var nose_x_n: f32 = 0.5;
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL lash-mesh face tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const lm = &result.landmarks;
        // Build the strip in frame pixels (frame size one) so the tips compare
        // against the eye centres and nose the tracker reports in pixels.
        var pos: [lash_mesh.vertex_count * 2]f32 = undefined;
        lash_mesh.buildPositions(lm, 1.0, 1.0, 0.7, 0.3, &pos);
        const left_tip = lashTipCentroid(&pos, 0);
        const right_tip = lashTipCentroid(&pos, 1);
        const left_eye = ringCentroid(lm, &abi.left_eye_loop);
        const right_eye = ringCentroid(lm, &abi.right_eye_loop);
        if (!(left_tip[1] < left_eye[1] and right_tip[1] < right_eye[1])) {
            std.debug.print("conformance: FAIL a lash tip row not above its eye centre (y tipL {d:.1} eyeL {d:.1} tipR {d:.1} eyeR {d:.1})\n", .{ left_tip[1], left_eye[1], right_tip[1], right_eye[1] });
            return false;
        }
        const nose_x = lm[1 * 3];
        if ((left_tip[0] > nose_x) == (right_tip[0] > nose_x)) {
            std.debug.print("conformance: FAIL the lash tip rows not on opposite sides of the nose (x L {d:.1} R {d:.1} nose {d:.1})\n", .{ left_tip[0], right_tip[0], nose_x });
            return false;
        }
        // Shift every landmark right and rebuild: the whole strip follows, so
        // the tips move by the same shift the face did.
        const shift: f32 = 40.0;
        var shifted_lm: [abi.face_landmark_count * 3]f32 = undefined;
        for (0..abi.face_landmark_count) |i| {
            shifted_lm[i * 3] = lm[i * 3] + shift;
            shifted_lm[i * 3 + 1] = lm[i * 3 + 1];
            shifted_lm[i * 3 + 2] = lm[i * 3 + 2];
        }
        var shifted_pos: [lash_mesh.vertex_count * 2]f32 = undefined;
        lash_mesh.buildPositions(&shifted_lm, 1.0, 1.0, 0.7, 0.3, &shifted_pos);
        const moved_tip = lashTipCentroid(&shifted_pos, 0);
        if (@abs((moved_tip[0] - left_tip[0]) - shift) > 1.0) {
            std.debug.print("conformance: FAIL the lash strip did not track the shifted face (dx {d:.1} shift {d:.1})\n", .{ moved_tip[0] - left_tip[0], shift });
            return false;
        }
        nose_x_n = nose_x / @as(f32, @floatFromInt(planes.width));
    }

    // Then prove the render: the strip draws over a tracked face, its lit
    // pixels flank the nose, it is gone with no face, and bit-stable twice.
    // Segmentation is enabled at the session level (the lens never reads it)
    // so the harness settles the mask before it captures the screenshot.
    try renderOnceWith(gpa, engine, ".lens-packages/lashes-3d", "zig-out/conformance-lashes-a", .{ .segmentation_model = single_class_model_path });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lashes-3d", "zig-out/conformance-lashes-b", .{ .segmentation_model = single_class_model_path });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lashes-3d", "zig-out/conformance-lashes-noface", .{ .segmentation_model = single_class_model_path, .face = false });
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-lashes-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-lashes-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    const noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-lashes-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(noface);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL the lash mesh is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, a, noface)) {
        std.debug.print("conformance: FAIL the lash mesh drew nothing, or drew without a face\n", .{});
        return false;
    }
    // The lit pixels flank the nose: the strip draws on both sides, one lash
    // set per eye, so the change against the no-face frame lands left and right.
    if (a.len != noface.len or a.len <= 18) {
        std.debug.print("conformance: FAIL the lash renders are not comparable frames\n", .{});
        return false;
    }
    const dims = tgaDims(a);
    const split = @as(usize, @intFromFloat(nose_x_n * @as(f32, @floatFromInt(dims.w))));
    const px_a = a[18..];
    const px_c = noface[18..];
    var left_changed: usize = 0;
    var right_changed: usize = 0;
    var i: usize = 0;
    while (i < dims.w * dims.h and (i + 1) * dims.bpp <= px_a.len) : (i += 1) {
        const off = i * dims.bpp;
        var changed = false;
        var k: usize = 0;
        while (k < dims.bpp) : (k += 1) {
            if (px_a[off + k] != px_c[off + k]) changed = true;
        }
        if (!changed) continue;
        if (i % dims.w < split) left_changed += 1 else right_changed += 1;
    }
    if (!(left_changed > 0 and right_changed > 0)) {
        std.debug.print("conformance: FAIL the lash pixels did not flank the nose (left {d} right {d} split {d})\n", .{ left_changed, right_changed, split });
        return false;
    }
    std.debug.print("conformance: PROOF the lash mesh rises off each tracked upper lid above the eye and flanking the nose, tracks the shifted face, is gone with no face, bit-stable\n", .{});
    return true;
}

/// The summed per-pixel colorfulness (brightest channel minus darkest) after
/// the 18-byte TGA header, a proxy for contrast and chroma: a boost that pushes
/// a pixel's channels apart around its mid raises it, while a flat uniform lift
/// leaves it unchanged.
fn chromaSpread(tga: []const u8) u64 {
    if (tga.len <= 18) return 0;
    const px = tga[18..];
    var sum: u64 = 0;
    var i: usize = 0;
    while (i + 4 <= px.len) : (i += 4) {
        const hi = @max(px[i], @max(px[i + 1], px[i + 2]));
        const lo = @min(px[i], @min(px[i + 1], px[i + 2]));
        sum += hi - lo;
    }
    return sum;
}

fn proveMakeupFinish(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // Each finish rides the same masked tint (lip-gloss and metallic-lip share
    // lip-tint's color, eyeshadow-shimmer shares eyeshadow's), differing only
    // in the finish uniform, so any difference is the finish alone.
    try renderOnceWith(gpa, engine, ".lens-packages/lip-gloss", "zig-out/conformance-finish-gloss-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lip-gloss", "zig-out/conformance-finish-gloss-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lip-tint", "zig-out/conformance-finish-matte-lips", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/metallic-lip", "zig-out/conformance-finish-metallic", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/eyeshadow-shimmer", "zig-out/conformance-finish-shimmer", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/eyeshadow", "zig-out/conformance-finish-matte-eyes", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lip-tint", "zig-out/conformance-finish-lips-noface", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/eyeshadow", "zig-out/conformance-finish-eyes-noface", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lip-gloss", "zig-out/conformance-finish-gloss-noface", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/metallic-lip", "zig-out/conformance-finish-metallic-noface", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/eyeshadow-shimmer", "zig-out/conformance-finish-shimmer-noface", .{ .face = false });
    settle(engine);

    const gloss_a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-gloss-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(gloss_a);
    const gloss_b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-gloss-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(gloss_b);
    const matte_lips = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-matte-lips.tga", gpa, .limited(8 << 20));
    defer gpa.free(matte_lips);
    const metallic = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-metallic.tga", gpa, .limited(8 << 20));
    defer gpa.free(metallic);
    const shimmer = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-shimmer.tga", gpa, .limited(8 << 20));
    defer gpa.free(shimmer);
    const matte_eyes = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-matte-eyes.tga", gpa, .limited(8 << 20));
    defer gpa.free(matte_eyes);
    const lips_noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-lips-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(lips_noface);
    const eyes_noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-eyes-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(eyes_noface);
    const gloss_noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-gloss-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(gloss_noface);
    const metallic_noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-metallic-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(metallic_noface);
    const shimmer_noface = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-finish-shimmer-noface.tga", gpa, .limited(8 << 20));
    defer gpa.free(shimmer_noface);

    if (!std.mem.eql(u8, gloss_a, gloss_b)) {
        std.debug.print("conformance: FAIL a finish is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, gloss_a, matte_lips) or std.mem.eql(u8, metallic, matte_lips) or std.mem.eql(u8, shimmer, matte_eyes)) {
        std.debug.print("conformance: FAIL a finish left the flat matte layer unchanged\n", .{});
        return false;
    }
    // Gloss lifts the region's highlights, so its masked layer is brighter than
    // the flat matte; matte itself stays byte-for-byte the plain tint.
    if (!(pixelByteSum(gloss_a) > pixelByteSum(matte_lips))) {
        std.debug.print("conformance: FAIL gloss did not lift the region's highlights (gloss {d} matte {d})\n", .{ pixelByteSum(gloss_a), pixelByteSum(matte_lips) });
        return false;
    }
    // Shimmer's per-cell glint adds high-frequency variance the flat matte over
    // the same region lacks.
    if (!(totalVariation(shimmer) > totalVariation(matte_eyes))) {
        std.debug.print("conformance: FAIL shimmer added no high-frequency sparkle (shimmer {d} matte {d})\n", .{ totalVariation(shimmer), totalVariation(matte_eyes) });
        return false;
    }
    // Metallic's contrast and chroma boost pushes the region's channels apart,
    // raising its colorfulness over the flat matte.
    if (!(chromaSpread(metallic) > chromaSpread(matte_lips))) {
        std.debug.print("conformance: FAIL metallic did not raise contrast (metallic {d} matte {d})\n", .{ chromaSpread(metallic), chromaSpread(matte_lips) });
        return false;
    }
    // With no face the mask is empty, so every finish reduces to the plain frame
    // its matte would - the finish is keyed to the mask and gone without it.
    if (!std.mem.eql(u8, gloss_noface, lips_noface) or !std.mem.eql(u8, metallic_noface, lips_noface)) {
        std.debug.print("conformance: FAIL a lip finish drew without a face mask\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, shimmer_noface, eyes_noface)) {
        std.debug.print("conformance: FAIL the eye shimmer drew without a face mask\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF gloss lifts highlights, shimmer sparkles high-frequency variance, metallic raises contrast, each over the same masked tint, keyed to the mask and bit-stable\n", .{});
    return true;
}

fn proveDepthMatting(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // With a segmenter AND depth submitted, the subject mask is the two
    // fused: depth prunes segmentation foreground behind the plane. A near
    // depth keeps the subject, a far depth prunes it, so a subject-
    // compositing lens differs between them.
    const dw = 64;
    const dh = 48;
    var near_map: [dw * dh]f32 = undefined;
    var far_map: [dw * dh]f32 = undefined;
    for (&near_map) |*d| d.* = 0.5;
    for (&far_map) |*d| d.* = 3.0;
    const near_opts: RenderOpts = .{ .segmentation_model = single_class_model_path, .face = false, .depth = &near_map, .depth_w = dw, .depth_h = dh, .depth_near = 0.1, .depth_far = 5.0 };
    try renderOnceWith(gpa, engine, ".lens-packages/background-swap", "zig-out/conformance-fuse-near-a", near_opts);
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/background-swap", "zig-out/conformance-fuse-near-b", near_opts);
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/background-swap", "zig-out/conformance-fuse-far", .{ .segmentation_model = single_class_model_path, .face = false, .depth = &far_map, .depth_w = dw, .depth_h = dh, .depth_near = 0.1, .depth_far = 5.0 });
    settle(engine);
    const near_a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-fuse-near-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(near_a);
    const near_b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-fuse-near-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(near_b);
    const far = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-fuse-far.tga", gpa, .limited(8 << 20));
    defer gpa.free(far);
    if (!std.mem.eql(u8, near_a, near_b)) {
        std.debug.print("conformance: FAIL depth-fused matting is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, near_a, far)) {
        std.debug.print("conformance: FAIL depth did not refine the segmentation mask - near and far match\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF depth fuses with the segmenter: a far depth prunes subject the mask kept, differing from a near depth, bit-stable\n", .{});
    return true;
}

/// Sum of absolute differences between each byte and the same channel of the
/// next pixel across, a stand-in for how much fine detail a render holds; a
/// blur lowers it.
fn totalVariation(buf: []const u8) u64 {
    var tv: u64 = 0;
    var i: usize = 0;
    while (i + 4 < buf.len) : (i += 1) {
        tv += if (buf[i] > buf[i + 4]) buf[i] - buf[i + 4] else buf[i + 4] - buf[i];
    }
    return tv;
}

/// The sum of every byte in a captured RGBA frame, a monotonic proxy for total
/// brightness across every channel, read from the GPU readback (not a stale
/// on-disk screenshot).
fn frameByteSum(buf: []const u8) u64 {
    var sum: u64 = 0;
    for (buf) |byte| sum += byte;
    return sum;
}

/// Renders a retouch lens over the corpus and reads the composited frame back
/// off the GPU, optionally with the face tracker or the skin segmenter live so
/// its landmark or class matte fills. A capability left off is the control for
/// a region-keyed effect, whose mask then stays on the zero mask.
fn captureRetouchShot(gpa: std.mem.Allocator, engine: *abi.Engine, planes: Nv12Copy, pkg: []const u8, face: bool, seg_model: ?[]const u8) ![]u8 {
    const half_w = (planes.width + 1) / 2;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    var face_bytes: ?[]u8 = null;
    defer if (face_bytes) |fb| gpa.free(fb);
    if (face) {
        face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        if (abi.goss_session_enable_face_tracking(session, face_bytes.?.ptr, face_bytes.?.len, 2) != .ok) return error.EnableFaceTrackingFailed;
    }
    if (seg_model) |mp| {
        const seg = try std.Io.Dir.cwd().readFileAlloc(harness_io, mp, gpa, .limited(16 << 20));
        defer gpa.free(seg);
        if (abi.goss_session_enable_segmentation(session, seg.ptr, seg.len, 2) != .ok) return error.EnableSegmentationFailed;
    }
    if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
        std.debug.print("conformance: FAIL retouch lens activation {s}\n", .{pkg});
        return error.ActivationFailed;
    }
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    if (face or seg_model != null) {
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
    }
    if (face) {
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
    }
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
    if (seg_model != null) {
        var mask_polls: usize = 0;
        while (session.segmentation_texture == null) {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            mask_polls += 1;
            if (mask_polls > 100_000) return error.SegmentationTimedOut;
        }
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var shot_width: u32 = 0;
    var shot_height: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) return error.CaptureFailed;
    return shot;
}

/// The six retouch effects: each lands on the right anatomy and does the
/// right thing. First the region mattes are placed against tracked landmarks,
/// then each look renders keyed to the face (or the skin segmenter) and vanishes
/// without it, softening, brightening, or mattING its region, bit-stable.
fn proveRetouchBreadth(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    // Anatomy: the new region clusters sit where their names say on a real face.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL retouch face tracking enable\n", .{});
            return false;
        }
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const lm = &result.landmarks;
        const re = ringCentroid(lm, &abi.right_eye_loop);
        const le = ringCentroid(lm, &abi.left_eye_loop);
        const eye_y = (re[1] + le[1]) * 0.5;
        const mouth = ringCentroid(lm, &abi.outer_lip_loop);
        const nose_y = lm[1 * 3 + 1];
        const chin_y = lm[152 * 3 + 1];

        for (abi.under_eye_regions) |region| {
            const c0 = ringCentroid(lm, region);
            if (!(c0[1] > eye_y and c0[1] < mouth[1])) {
                std.debug.print("conformance: FAIL an under-eye cluster not below the eye and above the mouth (y {d:.1} eye {d:.1} mouth {d:.1})\n", .{ c0[1], eye_y, mouth[1] });
                return false;
            }
        }
        const nl0 = ringCentroid(lm, abi.nasolabial_regions[0]);
        const nl1 = ringCentroid(lm, abi.nasolabial_regions[1]);
        if (!(nl0[1] > nose_y and nl1[1] > nose_y and nl0[1] < chin_y and nl1[1] < chin_y)) {
            std.debug.print("conformance: FAIL a nasolabial cluster not between the nose tip and the chin\n", .{});
            return false;
        }
        if ((nl0[0] > mouth[0]) == (nl1[0] > mouth[0])) {
            std.debug.print("conformance: FAIL the nasolabial folds not flanking the mouth (x {d:.1} {d:.1} mouth {d:.1})\n", .{ nl0[0], nl1[0], mouth[0] });
            return false;
        }
        const forehead = ringCentroid(lm, abi.t_zone_regions[0]);
        const bridge = ringCentroid(lm, abi.t_zone_regions[1]);
        if (!(forehead[1] < eye_y)) {
            std.debug.print("conformance: FAIL the t-zone forehead not above the eyes (y {d:.1} eye {d:.1})\n", .{ forehead[1], eye_y });
            return false;
        }
        const lo_x = @min(re[0], le[0]);
        const hi_x = @max(re[0], le[0]);
        if (!(lo_x < bridge[0] and bridge[0] < hi_x)) {
            std.debug.print("conformance: FAIL the t-zone nose bridge not centered between the eyes (x {d:.1} in {d:.1}..{d:.1})\n", .{ bridge[0], lo_x, hi_x });
            return false;
        }
    }

    // eye-bag soften: a smooth over the under-eye band lowers total variation,
    // gone with no face, bit-stable.
    if (!try softenReducesVariation(gpa, engine, planes, "eye-bag soften", ".lens-packages/eye-bag-soften", true, null)) return false;
    // smile-line soften: a smooth over the nasolabial fold, same three checks.
    if (!try softenReducesVariation(gpa, engine, planes, "smile-line soften", ".lens-packages/smile-line-soften", true, null)) return false;
    // blemish smooth: the edge-aware retouch over the segmented face skin lowers
    // total variation, gone with no segmenter, bit-stable.
    if (!try softenReducesVariation(gpa, engine, planes, "blemish smooth", ".lens-packages/blemish-smooth", false, multiclass_model_path)) return false;

    // eye-brighten: a screen tint over the sclera lifts the eye white, so the
    // frame brightens, gone with no face, bit-stable.
    {
        const a = try captureRetouchShot(gpa, engine, planes, ".lens-packages/eye-brighten", true, null);
        defer gpa.free(a);
        const b = try captureRetouchShot(gpa, engine, planes, ".lens-packages/eye-brighten", true, null);
        defer gpa.free(b);
        const control = try captureRetouchShot(gpa, engine, planes, ".lens-packages/eye-brighten", false, null);
        defer gpa.free(control);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("conformance: FAIL eye brighten is not deterministic across runs\n", .{});
            return false;
        }
        if (std.mem.eql(u8, a, control)) {
            std.debug.print("conformance: FAIL eye brighten drew nothing over the sclera\n", .{});
            return false;
        }
        if (!(frameByteSum(a) > frameByteSum(control))) {
            std.debug.print("conformance: FAIL eye brighten did not lighten the sclera ({d} vs {d})\n", .{ frameByteSum(a), frameByteSum(control) });
            return false;
        }
    }

    // shine matte: the retouch pulls the T-zone highlights back toward the local
    // mean, so the frame loses brightness, gone with no face, bit-stable.
    {
        const a = try captureRetouchShot(gpa, engine, planes, ".lens-packages/shine-matte", true, null);
        defer gpa.free(a);
        const b = try captureRetouchShot(gpa, engine, planes, ".lens-packages/shine-matte", true, null);
        defer gpa.free(b);
        const control = try captureRetouchShot(gpa, engine, planes, ".lens-packages/shine-matte", false, null);
        defer gpa.free(control);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("conformance: FAIL shine matte is not deterministic across runs\n", .{});
            return false;
        }
        if (std.mem.eql(u8, a, control)) {
            std.debug.print("conformance: FAIL shine matte drew nothing over the t-zone\n", .{});
            return false;
        }
        if (!(frameByteSum(a) < frameByteSum(control))) {
            std.debug.print("conformance: FAIL shine matte did not lower the t-zone brightness ({d} vs {d})\n", .{ frameByteSum(a), frameByteSum(control) });
            return false;
        }
    }

    // face symmetry: a light reshape mirror-blend nudges both sides of the face,
    // gone with no face, bit-stable.
    {
        const a = try captureRetouchShot(gpa, engine, planes, ".lens-packages/face-symmetry", true, null);
        defer gpa.free(a);
        const b = try captureRetouchShot(gpa, engine, planes, ".lens-packages/face-symmetry", true, null);
        defer gpa.free(b);
        const control = try captureRetouchShot(gpa, engine, planes, ".lens-packages/face-symmetry", false, null);
        defer gpa.free(control);
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print("conformance: FAIL face symmetry is not deterministic across runs\n", .{});
            return false;
        }
        if (std.mem.eql(u8, a, control)) {
            std.debug.print("conformance: FAIL face symmetry drew nothing over the face\n", .{});
            return false;
        }
        // A symmetric nudge touches both sides: a block left of center and one
        // right of center both differ from the no-face control.
        if (!(blockDiffersAt(a, control, width, 110, 150, 28) and blockDiffersAt(a, control, width, 262, 150, 28))) {
            std.debug.print("conformance: FAIL face symmetry did not nudge both sides of the face\n", .{});
            return false;
        }
    }

    std.debug.print("conformance: PROOF the six retouch effects land on their anatomy - eye-bag, smile-line and blemish soften their regions (lower variation), eye-brighten lifts the sclera, shine-matte pulls the t-zone highlights down, face-symmetry nudges both sides - each keyed to the face or skin, gone without it, bit-stable\n", .{});
    return true;
}

/// A soften look reduces its region's total variation versus the no-region
/// control, is bit-stable across two captures, and draws something. Shared by
/// the eye-bag, smile-line and blemish checks; face drives the landmark mattes,
/// seg_model the skin class.
fn softenReducesVariation(gpa: std.mem.Allocator, engine: *abi.Engine, planes: Nv12Copy, label: []const u8, pkg: []const u8, face: bool, seg_model: ?[]const u8) !bool {
    const a = try captureRetouchShot(gpa, engine, planes, pkg, face, seg_model);
    defer gpa.free(a);
    const b = try captureRetouchShot(gpa, engine, planes, pkg, face, seg_model);
    defer gpa.free(b);
    const control = try captureRetouchShot(gpa, engine, planes, pkg, false, null);
    defer gpa.free(control);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL {s} is not deterministic across runs\n", .{label});
        return false;
    }
    if (std.mem.eql(u8, a, control)) {
        std.debug.print("conformance: FAIL {s} drew nothing over its region\n", .{label});
        return false;
    }
    if (!(totalVariation(a) < totalVariation(control))) {
        std.debug.print("conformance: FAIL {s} did not reduce detail (tv {d} vs {d})\n", .{ label, totalVariation(a), totalVariation(control) });
        return false;
    }
    return true;
}

fn proveSmooth(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // A smooth.pass masked to the head region blends the face toward a local
    // average, so it draws only there, is gone with no face, and lowers the
    // frame's total variation (it genuinely smooths, not just recolors).
    try renderOnceWith(gpa, engine, ".lens-packages/face-smooth", "zig-out/conformance-smooth-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/face-smooth", "zig-out/conformance-smooth-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/face-smooth", "zig-out/conformance-smooth-control", .{ .face = false });
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-smooth-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-smooth-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    const control = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-smooth-control.tga", gpa, .limited(8 << 20));
    defer gpa.free(control);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL face smooth is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, a, control)) {
        std.debug.print("conformance: FAIL face smooth drew nothing over the head\n", .{});
        return false;
    }
    const tv_a = totalVariation(a);
    const tv_control = totalVariation(control);
    if (tv_a >= tv_control) {
        std.debug.print("conformance: FAIL face smooth did not reduce detail (tv {d} vs {d})\n", .{ tv_a, tv_control });
        return false;
    }
    std.debug.print("conformance: PROOF a smooth.pass blurs the masked region, lowering total variation, gone with no face, bit-stable\n", .{});
    return true;
}

/// The refined matte alpha (0..1) the matte.refine pass wrote, read from a
/// captured RGBA frame's red channel (the pass writes the matte as grayscale).
fn matteBandMean(shot: []const u8, col_lo: usize, col_hi: usize) f32 {
    var sum: f64 = 0;
    var count: f64 = 0;
    var row: usize = 110;
    while (row < 190) : (row += 1) {
        var col = col_lo;
        while (col < col_hi) : (col += 1) {
            sum += @floatFromInt(shot[(row * @as(usize, width) + col) * 4]);
            count += 1;
        }
    }
    if (count == 0) return 0;
    return @floatCast(sum / count / 255.0);
}

/// The sub-pixel column where the refined matte first crosses `mid`, scanning
/// left to right over a mid-height row average - the location of the matte's
/// refined edge, which the proof compares against the frame's luma edge.
fn matteCrossing(shot: []const u8, mid: f32, from: usize, to: usize) f32 {
    var prev_col: usize = from;
    var prev_val = matteBandMean(shot, from, from + 1);
    var col = from + 1;
    while (col < to) : (col += 1) {
        const val = matteBandMean(shot, col, col + 1);
        if (prev_val < mid and val >= mid) {
            const t = (mid - prev_val) / (val - prev_val);
            return @as(f32, @floatFromInt(prev_col)) + t * @as(f32, @floatFromInt(col - prev_col));
        }
        prev_col = col;
        prev_val = val;
    }
    return @floatFromInt(to);
}

/// Renders matte-refine over a synthetic frame plus an injected depth matte,
/// capturing the refined matte as an RGBA frame. The frame carries the luma
/// edge guide; the depth is the deliberately-misaligned soft matte.
fn captureRefinedMatte(gpa: std.mem.Allocator, engine: *abi.Engine, planes: Nv12Copy, depth: []const f32) ![]u8 {
    const half_w = (planes.width + 1) / 2;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    const pkg = ".lens-packages/matte-refine";
    if (abi.goss_session_activate_lens_from_directory(session, pkg, pkg.len) != .ok) {
        std.debug.print("conformance: FAIL matte-refine lens activation\n", .{});
        return error.ActivationFailed;
    }
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 33_333 };
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    if (abi.goss_session_submit_depth(session, depth.ptr, planes.width, planes.height, 0.0, 1.0) != .ok) {
        return error.SubmitDepthFailed;
    }
    for (0..4) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var shot_width: u32 = 0;
    var shot_height: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
        return error.CaptureFailed;
    }
    return shot;
}

fn proveMatteRefine(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // A synthetic frame with one hard vertical luma edge at column `edge`: dark
    // to the left, bright to the right. This is the guide the refinement keys
    // its matte to.
    const edge: usize = 200;
    const frame_rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(frame_rgba);
    // A deliberately-misaligned soft matte: flat 0.1 on the dark side and past
    // the true edge, ramping to 0.9 only over [edge+ramp_start, +span], so its
    // 50% crossing sits well right of the true luma edge with almost no step
    // there. A good refinement pulls that crossing back and builds a step.
    const ramp_start: f32 = 6.0;
    const span: f32 = 20.0;
    const input_cross: f32 = @as(f32, @floatFromInt(edge)) + ramp_start + span / 2.0;
    const depth = try gpa.alloc(f32, @as(usize, width) * height);
    defer gpa.free(depth);
    for (0..height) |row| {
        for (0..width) |col| {
            const bright = col >= edge;
            const luma: u8 = if (bright) 245 else 10;
            const i = (row * @as(usize, width) + col) * 4;
            frame_rgba[i + 0] = luma;
            frame_rgba[i + 1] = luma;
            frame_rgba[i + 2] = luma;
            frame_rgba[i + 3] = 255;
            const x: f32 = @floatFromInt(col);
            const ramp = (x - (@as(f32, @floatFromInt(edge)) + ramp_start)) / span;
            depth[row * @as(usize, width) + col] = std.math.clamp(0.1 + 0.8 * ramp, 0.1, 0.9);
        }
    }

    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = frame_rgba }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    const a = try captureRefinedMatte(gpa, engine, planes, depth);
    defer gpa.free(a);
    const b = try captureRefinedMatte(gpa, engine, planes, depth);
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL matte refinement is not deterministic across runs\n", .{});
        return false;
    }

    // Far from the edge the matte's own plateaus must survive: low on the dark
    // side, high on the bright side (polarity preserved, no inversion).
    const far_left = matteBandMean(a, edge - 45, edge - 25);
    const far_right = matteBandMean(a, edge + 25, edge + 45);
    // The matte alpha measured on both sides of the true (luma) edge. The input
    // matte is ~0.1 on both narrow bands here (its ramp only reaches high well
    // to the right), so the input has almost no step at the true edge.
    const near_left = matteBandMean(a, edge - 12, edge - 2);
    const near_right = matteBandMean(a, edge + 2, edge + 12);
    const input_near_left: f32 = 0.1;
    // The input matte averaged over the same near-right band [edge+2, edge+12],
    // centered near edge+7: with the ramp starting at edge+ramp_start it is
    // still close to the 0.1 plateau, so the input barely steps at the edge.
    const input_near_right: f32 = std.math.clamp(0.1 + 0.8 * @max(0.0, (7.0 - ramp_start)) / span, 0.1, 0.9);
    const refined_step = near_right - near_left;
    const input_step = input_near_right - input_near_left;

    // Where the refined matte's edge landed, versus where the input matte's
    // edge was. The mid level is halfway between the two refined plateaus.
    const mid = (far_left + far_right) * 0.5;
    const refined_cross = matteCrossing(a, mid, edge - 45, edge + 45);

    std.debug.print(
        "conformance: matte-refine far_left {d:.3} far_right {d:.3} near_left {d:.3} near_right {d:.3} refined_step {d:.3} input_step {d:.3} refined_cross {d:.1} input_cross {d:.1}\n",
        .{ far_left, far_right, near_left, near_right, refined_step, input_step, refined_cross, input_cross },
    );

    if (far_left > 0.35) {
        std.debug.print("conformance: FAIL refined matte not low on the dark side (far_left {d:.3})\n", .{far_left});
        return false;
    }
    if (far_right < 0.65) {
        std.debug.print("conformance: FAIL refined matte not high on the bright side (far_right {d:.3})\n", .{far_right});
        return false;
    }
    // The refinement builds a real step exactly at the true luma edge, far
    // stronger than the input matte's near-flat crossing there.
    if (!(refined_step > input_step + 0.12) or refined_step < 0.20) {
        std.debug.print("conformance: FAIL refinement did not sharpen the matte at the luma edge (refined_step {d:.3} input_step {d:.3})\n", .{ refined_step, input_step });
        return false;
    }
    // The refined edge moved toward the luma edge: strictly left of the input
    // crossing, and strictly closer to the true edge than the input was.
    if (!(refined_cross < input_cross - 2.0)) {
        std.debug.print("conformance: FAIL refined edge did not move toward the luma edge (refined_cross {d:.1} input_cross {d:.1})\n", .{ refined_cross, input_cross });
        return false;
    }
    const refined_err = @abs(refined_cross - @as(f32, @floatFromInt(edge)));
    const input_err = @abs(input_cross - @as(f32, @floatFromInt(edge)));
    if (!(refined_err < input_err)) {
        std.debug.print("conformance: FAIL refined edge not closer to the luma edge than the input (refined_err {d:.1} input_err {d:.1})\n", .{ refined_err, input_err });
        return false;
    }
    std.debug.print("conformance: PROOF matte.refine snaps a misaligned soft matte to the frame's luma edge (crossing {d:.1}->{d:.1} toward {d}), sharpens the boundary, bit-stable across runs\n", .{ input_cross, refined_cross, edge });
    return true;
}

/// A misaligned coarse hair class as a mask-grid ramp: 0.1 flat on the dark
/// side and up to ramp_start, rising to 0.9 over span columns, so its crossing
/// sits right of the frame's luma edge until a matte.hair source pulls it back.
fn buildCoarseHairRamp(mask: *[abi.segmentation_mask_len]f32, ramp_start_col: f32, span_col: f32) void {
    const side = abi.segmentation_mask_side;
    for (0..side) |gy| {
        for (0..side) |gx| {
            const u = (@as(f32, @floatFromInt(gx)) + 0.5) / @as(f32, @floatFromInt(side));
            const col = u * @as(f32, @floatFromInt(width));
            const ramp = (col - ramp_start_col) / span_col;
            mask[gy * side + gx] = std.math.clamp(0.1 + 0.8 * ramp, 0.1, 0.9);
        }
    }
}

/// A matte.hair source publishing the hair_matte channel, then a strength-0
/// matte.refine reading that channel back out as grayscale, so a capture reads
/// the published alpha verbatim in its red channel.
const hair_matte_proof_json =
    \\{"glf":"1.0","id":"goss.reference.hair-matte-proof","version":"1.0.0","display_name":"Hair Matte Proof","engine_compat":">=0.5","capabilities":["segmentation"],"parameters":[],"nodes":[{"id":"hair_source","type":"matte.hair","inputs":{"frame":"camera"},"hair_matte":{"radius":3.5,"sensitivity":12.0,"strength":1.0}},{"id":"show","type":"matte.refine","inputs":{"frame":"hair_source"},"params":{},"matte":{"strength":0.0,"mask":"hair_matte"}}],"triggers":[]}
;

/// Renders the hair-matte source over a synthetic frame with a vertical luma
/// edge at edge_col, injecting a coarse hair ramp aligned to it when present,
/// and captures the published hair_matte as an RGBA frame (matte in red).
fn captureHairMatteScene(gpa: std.mem.Allocator, engine: *abi.Engine, edge_col: usize, present: bool) ![]u8 {
    const frame_rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(frame_rgba);
    for (0..height) |row| {
        for (0..width) |col| {
            const luma: u8 = if (col >= edge_col) 245 else 10;
            const i = (row * @as(usize, width) + col) * 4;
            frame_rgba[i + 0] = luma;
            frame_rgba[i + 1] = luma;
            frame_rgba[i + 2] = luma;
            frame_rgba[i + 3] = 255;
        }
    }
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = frame_rgba }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    var coarse: [abi.segmentation_mask_len]f32 = undefined;
    buildCoarseHairRamp(&coarse, @as(f32, @floatFromInt(edge_col)) + 6.0, 20.0);

    const half_w = (planes.width + 1) / 2;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens(session, hair_matte_proof_json.ptr, hair_matte_proof_json.len) != .ok) {
        std.debug.print("conformance: FAIL hair-matte lens activation\n", .{});
        return error.ActivationFailed;
    }
    for (0..4) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        if (present) abi.injectMaskChannel(session, lens_manifest.hair_channel, &coarse);
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var shot_width: u32 = 0;
    var shot_height: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
        return error.CaptureFailed;
    }
    return shot;
}

fn proveHairMatte(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // The channel vocabulary the source rides: the coarse hair class it consumes
    // and the strand channel it publishes, appended at the frozen tail.
    if (lens_manifest.hair_channel != 2 or lens_manifest.maskChannelIndex("hair_matte") != 21) {
        std.debug.print("conformance: FAIL hair matte channel vocabulary moved (hair {d}, hair_matte {?d})\n", .{ lens_manifest.hair_channel, lens_manifest.maskChannelIndex("hair_matte") });
        return false;
    }

    const edge: usize = 200;
    // The coarse ramp starts at edge+6 and spans 20 columns, so its 50% crossing
    // sits at edge+16, well right of the true luma edge the refinement snaps to.
    const input_cross: f32 = @as(f32, @floatFromInt(edge)) + 6.0 + 10.0;

    const a = try captureHairMatteScene(gpa, engine, edge, true);
    defer gpa.free(a);
    const b = try captureHairMatteScene(gpa, engine, edge, true);
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL hair matte is not deterministic across runs\n", .{});
        return false;
    }

    // The published alpha across the boundary: low on the dark (non-hair) side,
    // high on the bright side, with a real step and a graded transition band.
    const far_left = matteBandMean(a, edge - 45, edge - 25);
    const far_right = matteBandMean(a, edge + 25, edge + 45);
    const near_left = matteBandMean(a, edge - 12, edge - 2);
    const near_right = matteBandMean(a, edge + 2, edge + 12);
    const transition = matteBandMean(a, edge + 2, edge + 16);
    const refined_step = near_right - near_left;
    const mid = (far_left + far_right) * 0.5;
    const refined_cross = matteCrossing(a, mid, edge - 45, edge + 45);

    std.debug.print(
        "conformance: hair-matte far_left {d:.3} far_right {d:.3} transition {d:.3} refined_step {d:.3} refined_cross {d:.1} input_cross {d:.1}\n",
        .{ far_left, far_right, transition, refined_step, refined_cross, input_cross },
    );

    // Spatially confined: near zero off the hair region, filled inside it.
    if (!(far_left < 0.35)) {
        std.debug.print("conformance: FAIL hair matte not confined - alpha off the hair region (far_left {d:.3})\n", .{far_left});
        return false;
    }
    if (!(far_right > 0.65)) {
        std.debug.print("conformance: FAIL hair matte did not fill the hair region (far_right {d:.3})\n", .{far_right});
        return false;
    }
    // A soft 0..1 alpha, not a hard 0/1 bit: the plateaus stay off the extremes
    // and the boundary carries a graded band strictly between the two, so the
    // matte feathers rather than cutting a binary edge.
    if (!(far_left > 0.02 and far_right < 0.98 and transition > far_left + 0.08 and transition < far_right - 0.08)) {
        std.debug.print("conformance: FAIL hair matte is not a soft 0..1 alpha (far_left {d:.3} transition {d:.3} far_right {d:.3})\n", .{ far_left, transition, far_right });
        return false;
    }
    if (!(refined_step > 0.2)) {
        std.debug.print("conformance: FAIL the refined matte did not step at the luma edge (refined_step {d:.3})\n", .{refined_step});
        return false;
    }
    // Snapped toward the luma edge - the strand boundary - from the coarse crossing.
    if (!(refined_cross < input_cross - 2.0)) {
        std.debug.print("conformance: FAIL the refined edge did not snap toward the luma edge (refined_cross {d:.1} input_cross {d:.1})\n", .{ refined_cross, input_cross });
        return false;
    }

    // Tracks the hair region as it moves: a scene shifted right by `shift` puts
    // the luma edge and the coarse hair at edge+shift, and the refined edge
    // follows there rather than staying put.
    const shift: usize = 40;
    const edge2 = edge + shift;
    const shifted = try captureHairMatteScene(gpa, engine, edge2, true);
    defer gpa.free(shifted);
    const mid2 = (matteBandMean(shifted, edge2 - 45, edge2 - 25) + matteBandMean(shifted, edge2 + 25, edge2 + 45)) * 0.5;
    const refined_cross2 = matteCrossing(shifted, mid2, edge2 - 45, edge2 + 45);
    if (!(refined_cross2 > refined_cross + @as(f32, @floatFromInt(shift)) - 15.0)) {
        std.debug.print("conformance: FAIL hair matte did not track the shifted hair region (cross {d:.1} -> {d:.1}, shift {d})\n", .{ refined_cross, refined_cross2, shift });
        return false;
    }

    // Absent with no person: the same frame with no coarse hair injected leaves
    // the channel the zero mask, so the visualized matte reads black everywhere.
    const absent = try captureHairMatteScene(gpa, engine, edge, false);
    defer gpa.free(absent);
    const absent_left = matteBandMean(absent, edge - 45, edge - 25);
    const absent_right = matteBandMean(absent, edge + 25, edge + 45);
    if (!(absent_left < 0.1 and absent_right < 0.1)) {
        std.debug.print("conformance: FAIL hair matte not absent with no hair class (left {d:.3} right {d:.3})\n", .{ absent_left, absent_right });
        return false;
    }

    std.debug.print("conformance: PROOF matte.hair publishes a soft strand-level hair_matte channel, confined to the hair region, snapped to the luma edge (crossing {d:.1}->{d:.1}), tracking the region when it shifts to {d:.1}, gone with no hair class, bit-stable across runs\n", .{ input_cross, refined_cross, refined_cross2 });
    return true;
}

/// A tint.pass keying one scene mask channel, so an injected scene map confines
/// the recolor to that region. Only the channel name varies between the three.
fn sceneLensJson(comptime mask: []const u8) []const u8 {
    return "{\"glf\":\"1.0\",\"id\":\"goss.reference.scene-" ++ mask ++
        "\",\"version\":\"1.0.0\",\"display_name\":\"Scene " ++ mask ++
        "\",\"engine_compat\":\">=0.9\",\"capabilities\":[\"segmentation\"],\"parameters\":[]," ++
        "\"nodes\":[{\"id\":\"tint\",\"type\":\"tint.pass\",\"inputs\":{\"frame\":\"camera\"},\"params\":{}," ++
        "\"tint\":{\"color\":[0.95,0.5,0.2],\"opacity\":0.7,\"mask\":\"" ++ mask ++ "\"}}],\"triggers\":[]}";
}

/// A synthetic scene class: 1 to the right of edge_col, 0 to the left, a clean
/// step so a tint keyed to it lands on exactly that region.
fn buildSceneStep(mask: *[abi.segmentation_mask_len]f32, edge_col: f32) void {
    const side = abi.segmentation_mask_side;
    for (0..side) |gy| {
        for (0..side) |gx| {
            const u = (@as(f32, @floatFromInt(gx)) + 0.5) / @as(f32, @floatFromInt(side));
            const col = u * @as(f32, @floatFromInt(width));
            mask[gy * side + gx] = if (col >= edge_col) 1.0 else 0.0;
        }
    }
}

/// Renders a scene tint over a flat gray frame, injecting the synthetic scene
/// class into its channel when present so the recolor is confined to that
/// region. Absent leaves the channel the zero mask, the model-absent state.
fn captureSceneScene(gpa: std.mem.Allocator, engine: *abi.Engine, lens_json: []const u8, channel: usize, edge_col: f32, present: bool) ![]u8 {
    const frame_rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(frame_rgba);
    for (frame_rgba, 0..) |*px, i| px.* = if (i % 4 == 3) 255 else 128;
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = frame_rgba }, .width = width, .height = height };
    const planes = try rgbaToNv12(gpa, frame);
    defer planes.deinit(gpa);

    var scene: [abi.segmentation_mask_len]f32 = undefined;
    buildSceneStep(&scene, edge_col);

    const half_w = (planes.width + 1) / 2;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    if (abi.goss_session_activate_lens(session, lens_json.ptr, lens_json.len) != .ok) {
        std.debug.print("conformance: FAIL scene lens activation\n", .{});
        return error.ActivationFailed;
    }
    for (0..4) |i| {
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = @intCast((i + 1) * 33_333) };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        if (present) abi.injectMaskChannel(session, channel, &scene);
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var shot_width: u32 = 0;
    var shot_height: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
        return error.CaptureFailed;
    }
    return shot;
}

/// One scene channel plumbs when an injected map tints its region and an absent
/// map leaves the region the base frame. Returns false with a diagnostic on the
/// first channel that does not.
fn sceneChannelTinted(gpa: std.mem.Allocator, engine: *abi.Engine, lens_json: []const u8, channel: usize, name: []const u8) !bool {
    const edge: usize = 200;
    const present = try captureSceneScene(gpa, engine, lens_json, channel, @floatFromInt(edge), true);
    defer gpa.free(present);
    const absent = try captureSceneScene(gpa, engine, lens_json, channel, @floatFromInt(edge), false);
    defer gpa.free(absent);
    const p_left = matteBandMean(present, edge - 45, edge - 25);
    const p_right = matteBandMean(present, edge + 25, edge + 45);
    const a_left = matteBandMean(absent, edge - 45, edge - 25);
    const a_right = matteBandMean(absent, edge + 25, edge + 45);
    if (!(p_right > p_left + 0.12)) {
        std.debug.print("conformance: FAIL scene {s} did not tint its region (left {d:.3} right {d:.3})\n", .{ name, p_left, p_right });
        return false;
    }
    if (!(a_right < a_left + 0.05)) {
        std.debug.print("conformance: FAIL scene {s} tinted with no scene class (left {d:.3} right {d:.3})\n", .{ name, a_left, a_right });
        return false;
    }
    return true;
}

/// Proves the scene classes plumb end to end with no scene model: a synthetic
/// sky, ground, or building map keyed on a tint.pass confines the recolor to
/// that region, tracks it when it moves, is bit-stable, and with no map the
/// channel is empty so the frame matches the model-absent control.
fn proveSceneClasses(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    if (lens_manifest.maskChannelIndex("sky") != 22 or lens_manifest.maskChannelIndex("ground") != 23 or lens_manifest.maskChannelIndex("building") != 24) {
        std.debug.print("conformance: FAIL scene channel vocabulary moved (sky {?d}, ground {?d}, building {?d})\n", .{ lens_manifest.maskChannelIndex("sky"), lens_manifest.maskChannelIndex("ground"), lens_manifest.maskChannelIndex("building") });
        return false;
    }

    const sky_json = comptime sceneLensJson("sky");
    const edge: usize = 200;

    const a = try captureSceneScene(gpa, engine, sky_json, lens_manifest.sky_channel, @floatFromInt(edge), true);
    defer gpa.free(a);
    const b = try captureSceneScene(gpa, engine, sky_json, lens_manifest.sky_channel, @floatFromInt(edge), true);
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL scene sky is not deterministic across runs\n", .{});
        return false;
    }

    const far_left = matteBandMean(a, edge - 45, edge - 25);
    const far_right = matteBandMean(a, edge + 25, edge + 45);
    const mid = (far_left + far_right) * 0.5;
    const cross = matteCrossing(a, mid, edge - 45, edge + 45);
    std.debug.print("conformance: scene-sky base {d:.3} tinted {d:.3} edge {d:.1}\n", .{ far_left, far_right, cross });

    // Confined: the base region left of the edge stays the gray frame, the sky
    // region right of it is recolored.
    if (!(far_left < 0.6)) {
        std.debug.print("conformance: FAIL scene sky bled onto the base region (far_left {d:.3})\n", .{far_left});
        return false;
    }
    if (!(far_right > far_left + 0.15)) {
        std.debug.print("conformance: FAIL scene sky did not fill its region (far_left {d:.3} far_right {d:.3})\n", .{ far_left, far_right });
        return false;
    }

    // Tracks: a map whose edge shifts right moves the recolor boundary with it.
    const shift: usize = 40;
    const edge2 = edge + shift;
    const shifted = try captureSceneScene(gpa, engine, sky_json, lens_manifest.sky_channel, @floatFromInt(edge2), true);
    defer gpa.free(shifted);
    const cross2 = matteCrossing(shifted, mid, edge2 - 45, edge2 + 45);
    if (!(cross2 > cross + @as(f32, @floatFromInt(shift)) - 15.0)) {
        std.debug.print("conformance: FAIL scene sky did not track the shifted region (edge {d:.1} -> {d:.1}, shift {d})\n", .{ cross, cross2, shift });
        return false;
    }

    // Absent: with no scene map injected the channel is the zero mask, so the
    // tint draws nothing and both bands read the base frame. Two absent renders
    // are byte-identical, the reproducible model-absent control.
    const absent = try captureSceneScene(gpa, engine, sky_json, lens_manifest.sky_channel, @floatFromInt(edge), false);
    defer gpa.free(absent);
    const control = try captureSceneScene(gpa, engine, sky_json, lens_manifest.sky_channel, @floatFromInt(edge), false);
    defer gpa.free(control);
    if (!std.mem.eql(u8, absent, control)) {
        std.debug.print("conformance: FAIL the model-absent scene render is not byte-identical across runs\n", .{});
        return false;
    }
    const absent_left = matteBandMean(absent, edge - 45, edge - 25);
    const absent_right = matteBandMean(absent, edge + 25, edge + 45);
    if (!(absent_right < absent_left + 0.05)) {
        std.debug.print("conformance: FAIL scene sky tinted with no scene model (left {d:.3} right {d:.3})\n", .{ absent_left, absent_right });
        return false;
    }

    // The ground and building channels plumb through the identical path.
    if (!try sceneChannelTinted(gpa, engine, comptime sceneLensJson("ground"), lens_manifest.ground_channel, "ground")) return false;
    if (!try sceneChannelTinted(gpa, engine, comptime sceneLensJson("building"), lens_manifest.building_channel, "building")) return false;

    std.debug.print("conformance: PROOF a tint.pass keys the scene classes sky, ground, and building, each confined to its injected region (sky edge {d:.1}->{d:.1} when shifted), empty and byte-identical to the model-absent control with no scene model, bit-stable across runs\n", .{ cross, cross2 });
    return true;
}

fn proveTeeth(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // The teeth matte fills the inner-lip loop, the mouth aperture inside the
    // outer lip. First prove the loop is the inner mouth: its centroid sits
    // below the nose, above the chin, and between the mouth corners.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
        defer gpa.free(face_bytes);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL teeth face tracking enable\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;
        const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const lm = &result.landmarks;
        const inner = ringCentroid(lm, &abi.inner_lip_loop);
        const nose_y = lm[1 * 3 + 1];
        const chin_y = lm[152 * 3 + 1];
        if (!(nose_y < inner[1] and inner[1] < chin_y)) {
            std.debug.print("conformance: FAIL inner-lip centroid not between nose and chin (y {d:.1} {d:.1} {d:.1})\n", .{ nose_y, inner[1], chin_y });
            return false;
        }
        const lo_x = @min(lm[61 * 3], lm[291 * 3]);
        const hi_x = @max(lm[61 * 3], lm[291 * 3]);
        if (!(lo_x < inner[0] and inner[0] < hi_x)) {
            std.debug.print("conformance: FAIL inner-lip centroid not between the mouth corners (x {d:.1} {d:.1} {d:.1})\n", .{ lo_x, inner[0], hi_x });
            return false;
        }
    }

    // Then prove the render: a whitening tint over the inner lip colors a
    // smaller region than a lip tint over the outer lip, gone with no face.
    try renderOnceWith(gpa, engine, ".lens-packages/teeth-whiten", "zig-out/conformance-teeth-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/teeth-whiten", "zig-out/conformance-teeth-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/teeth-whiten", "zig-out/conformance-teeth-control", .{ .face = false });
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/lip-tint", "zig-out/conformance-teeth-lip", .{});
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-teeth-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-teeth-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    const control = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-teeth-control.tga", gpa, .limited(8 << 20));
    defer gpa.free(control);
    const lip = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-teeth-lip.tga", gpa, .limited(8 << 20));
    defer gpa.free(lip);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL teeth whiten is not deterministic across runs\n", .{});
        return false;
    }
    const teeth_d = countDiff(a, control);
    const lip_d = countDiff(lip, control);
    if (teeth_d == 0) {
        std.debug.print("conformance: FAIL teeth whiten drew nothing over the inner lip\n", .{});
        return false;
    }
    if (teeth_d >= lip_d) {
        std.debug.print("conformance: FAIL the inner-lip region is not smaller than the outer lip (teeth {d} lip {d})\n", .{ teeth_d, lip_d });
        return false;
    }
    std.debug.print("conformance: PROOF teeth whiten fills the inner-lip mouth, a smaller region than the outer lip, gone with no face, bit-stable\n", .{});
    return true;
}

fn proveSharpen(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // A smooth.pass with a negative amount sharpens instead of blurs: it
    // pushes the masked region away from its local average, raising total
    // variation, the opposite of the smooth pass. Gone with no face.
    try renderOnceWith(gpa, engine, ".lens-packages/detail-sharpen", "zig-out/conformance-sharpen-a", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/detail-sharpen", "zig-out/conformance-sharpen-b", .{});
    settle(engine);
    try renderOnceWith(gpa, engine, ".lens-packages/detail-sharpen", "zig-out/conformance-sharpen-control", .{ .face = false });
    settle(engine);
    const a = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-sharpen-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-sharpen-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(b);
    const control = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-sharpen-control.tga", gpa, .limited(8 << 20));
    defer gpa.free(control);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("conformance: FAIL detail sharpen is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, a, control)) {
        std.debug.print("conformance: FAIL detail sharpen drew nothing over the head\n", .{});
        return false;
    }
    const tv_a = totalVariation(a);
    const tv_control = totalVariation(control);
    if (tv_a <= tv_control) {
        std.debug.print("conformance: FAIL detail sharpen did not raise detail (tv {d} vs {d})\n", .{ tv_a, tv_control });
        return false;
    }
    std.debug.print("conformance: PROOF a negative smooth amount sharpens the masked region, raising total variation, gone with no face, bit-stable\n", .{});
    return true;
}

fn proveUserMediaSeg(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // goss_session_submit_segmentation_image feeds a still RGBA image to the
    // segmenter; a subject-compositing lens then shows the segmented subject,
    // differing from a session handed no image, and it is deterministic.
    const seg_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, single_class_model_path, gpa, .limited(16 << 20));
    defer gpa.free(seg_bytes);
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const rgba = corpus.frame.pixels.rgba8;
    const cw = corpus.frame.width;
    const ch = corpus.frame.height;
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const cap = @as(usize, 1024) * 1024 * 4;
    const shot_img = try gpa.alloc(u8, cap);
    defer gpa.free(shot_img);
    const shot_img2 = try gpa.alloc(u8, cap);
    defer gpa.free(shot_img2);
    const shot_none = try gpa.alloc(u8, cap);
    defer gpa.free(shot_none);
    var wi: u32 = 0;
    var hi: u32 = 0;
    var wi2: u32 = 0;
    var hi2: u32 = 0;
    var wn: u32 = 0;
    var hn: u32 = 0;

    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        if (abi.goss_session_enable_segmentation(session, seg_bytes.ptr, seg_bytes.len, 2) != .ok) {
            std.debug.print("conformance: FAIL user-media segmentation enable\n", .{});
            return false;
        }
        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/background-swap", ".lens-packages/background-swap".len) != .ok) {
            std.debug.print("conformance: FAIL user-media lens activation\n", .{});
            return false;
        }
        if (abi.goss_session_submit_segmentation_image(session, rgba.ptr, cw, ch) != .ok) {
            std.debug.print("conformance: FAIL submit_segmentation_image rejected the still\n", .{});
            return false;
        }
        var polls: usize = 0;
        while (session.segmentation_texture == null) {
            _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            polls += 1;
            if (polls > 1_000_000) {
                std.debug.print("conformance: FAIL the submitted image never produced a mask\n", .{});
                return false;
            }
        }
        for (0..5) |_| {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        if (abi.goss_engine_capture_frame(engine, session, shot_img.ptr, shot_img.len, &wi, &hi) != .ok) return error.CaptureFailed;
        for (0..3) |_| {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        if (abi.goss_engine_capture_frame(engine, session, shot_img2.ptr, shot_img2.len, &wi2, &hi2) != .ok) return error.CaptureFailed;
    }
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        if (abi.goss_session_enable_segmentation(session, seg_bytes.ptr, seg_bytes.len, 2) != .ok) return error.EnableSegmentationFailed;
        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/background-swap", ".lens-packages/background-swap".len) != .ok) return error.ActivationFailed;
        for (0..10) |_| {
            _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        if (abi.goss_engine_capture_frame(engine, session, shot_none.ptr, shot_none.len, &wn, &hn) != .ok) return error.CaptureFailed;
    }
    if (wi == 0 or wi != wn or hi != hn or wi != wi2 or hi != hi2) {
        std.debug.print("conformance: FAIL user-media capture size mismatch\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, shot_img[0 .. wi * hi * 4], shot_img2[0 .. wi * hi * 4])) {
        std.debug.print("conformance: FAIL user-media segmentation is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shot_img[0 .. wi * hi * 4], shot_none[0 .. wn * hn * 4])) {
        std.debug.print("conformance: FAIL the submitted image did not segment - composite unchanged from no image\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF submit_segmentation_image segments a still RGBA, changing the composite from a session given no image, deterministically\n", .{});
    return true;
}

fn fillSolid(buf: []u8, r: u8, g: u8, b: u8) void {
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 4) {
        buf[i] = r;
        buf[i + 1] = g;
        buf[i + 2] = b;
        buf[i + 3] = 255;
    }
}

fn renderCapture(engine: *abi.Engine, session: *abi.Session, desc: *const abi.FrameDesc, planes: anytype, half_w: u32, buf: []u8, ow: *u32, oh: *u32) !void {
    for (0..5) |_| {
        _ = abi.goss_session_submit_frame_copy(session, desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    if (abi.goss_engine_capture_frame(engine, session, buf.ptr, buf.len, ow, oh) != .ok) return error.CaptureFailed;
}

fn proveMakeupTransfer(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // A reference-sourced tint.pass paints the lips in the makeup reference's
    // sampled color, so two references of different colors drive different
    // results and the transfer is deterministic.
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);
    const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(face_bytes);
    if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
        std.debug.print("conformance: FAIL makeup-transfer face tracking enable\n", .{});
        return false;
    }
    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/makeup-transfer", ".lens-packages/makeup-transfer".len) != .ok) {
        std.debug.print("conformance: FAIL makeup-transfer lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
    var result: abi.FaceResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_face_result(session, &result) == .again) {
        std.Thread.yield() catch {};
        if (g_watch) c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000_000) return error.FaceResultTimedOut;
    }
    const rw = corpus.frame.width;
    const rh = corpus.frame.height;
    const count: u32 = @intCast(result.landmarks.len / 3);
    const ref = try gpa.alloc(u8, @as(usize, rw) * rh * 4);
    defer gpa.free(ref);
    const cap = @as(usize, 1024) * 1024 * 4;
    const red_a = try gpa.alloc(u8, cap);
    defer gpa.free(red_a);
    const red_b = try gpa.alloc(u8, cap);
    defer gpa.free(red_b);
    const blue = try gpa.alloc(u8, cap);
    defer gpa.free(blue);
    var wra: u32 = 0;
    var hra: u32 = 0;
    var wrb: u32 = 0;
    var hrb: u32 = 0;
    var wb: u32 = 0;
    var hb: u32 = 0;

    fillSolid(ref, 230, 30, 60);
    if (abi.goss_session_set_makeup_reference(session, ref.ptr, rw, rh, &result.landmarks, count) != .ok) {
        std.debug.print("conformance: FAIL set_makeup_reference rejected the red reference\n", .{});
        return false;
    }
    try renderCapture(engine, session, &desc, planes, half_w, red_a, &wra, &hra);
    try renderCapture(engine, session, &desc, planes, half_w, red_b, &wrb, &hrb);
    fillSolid(ref, 40, 60, 220);
    if (abi.goss_session_set_makeup_reference(session, ref.ptr, rw, rh, &result.landmarks, count) != .ok) return error.SetMakeupReferenceFailed;
    try renderCapture(engine, session, &desc, planes, half_w, blue, &wb, &hb);

    if (wra == 0 or wra != wb or hra != hb or wra != wrb or hra != hrb) {
        std.debug.print("conformance: FAIL makeup-transfer capture size mismatch\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, red_a[0 .. wra * hra * 4], red_b[0 .. wrb * hrb * 4])) {
        std.debug.print("conformance: FAIL makeup transfer is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, red_a[0 .. wra * hra * 4], blue[0 .. wb * hb * 4])) {
        std.debug.print("conformance: FAIL the reference color did not drive the tint - red and blue match\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a reference-sourced tint paints the lips in the makeup reference's color, red and blue references differing, deterministically\n", .{});
    return true;
}

/// Paints the reference gray, then the skin-patch landmarks a strong green, so
/// a correct skin-tone sample reads green while a lips or brow sample would
/// read the gray base - the reference's skin region is a distinct known color.
fn paintSkinPatch(ref: []u8, rw: u32, rh: u32, lm: [*]const f32) void {
    fillSolid(ref, 128, 128, 128);
    const max_x: i64 = @intCast(rw - 1);
    const max_y: i64 = @intCast(rh - 1);
    for (abi.skin_patch) |idx| {
        const cx: i64 = @intFromFloat(std.math.clamp(lm[@as(usize, idx) * 3], 0, @as(f32, @floatFromInt(max_x))));
        const cy: i64 = @intFromFloat(std.math.clamp(lm[@as(usize, idx) * 3 + 1], 0, @as(f32, @floatFromInt(max_y))));
        var dy: i64 = -2;
        while (dy <= 2) : (dy += 1) {
            var dx: i64 = -2;
            while (dx <= 2) : (dx += 1) {
                const px: usize = @intCast(std.math.clamp(cx + dx, 0, max_x));
                const py: usize = @intCast(std.math.clamp(cy + dy, 0, max_y));
                const o = (py * rw + px) * 4;
                ref[o] = 20;
                ref[o + 1] = 220;
                ref[o + 2] = 40;
                ref[o + 3] = 255;
            }
        }
    }
}

/// The mean green bias over an RGBA buffer: how far green leads the red/blue
/// average, so a green skin tint reads high and the warm static foundation
/// reads near zero, a scalar for which color drove the face_skin region.
fn greenness(buf: []const u8) f32 {
    var sum_r: u64 = 0;
    var sum_g: u64 = 0;
    var sum_b: u64 = 0;
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 4) {
        sum_r += buf[i];
        sum_g += buf[i + 1];
        sum_b += buf[i + 2];
    }
    const n: f32 = @floatFromInt(buf.len / 4);
    const mr: f32 = @as(f32, @floatFromInt(sum_r)) / n;
    const mg: f32 = @as(f32, @floatFromInt(sum_g)) / n;
    const mb: f32 = @as(f32, @floatFromInt(sum_b)) / n;
    return mg - (mr + mb) / 2.0;
}

fn proveFoundationShadeMatch(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    // A reference-driven foundation reads the reference photo's skin tone from
    // the skin patch and tints the live face_skin class in it, so a green skin
    // reference pushes the segmented face toward green, differs from the static
    // foundation color, and vanishes without the face_skin mask.
    const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(face_bytes);
    const seg_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, multiclass_model_path, gpa, .limited(16 << 20));
    defer gpa.free(seg_bytes);
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    const rw = corpus.frame.width;
    const rh = corpus.frame.height;

    const cap = @as(usize, 1024) * 1024 * 4;
    const matched_a = try gpa.alloc(u8, cap);
    defer gpa.free(matched_a);
    const matched_b = try gpa.alloc(u8, cap);
    defer gpa.free(matched_b);
    const static = try gpa.alloc(u8, cap);
    defer gpa.free(static);
    const noseg = try gpa.alloc(u8, cap);
    defer gpa.free(noseg);
    const ref = try gpa.alloc(u8, @as(usize, rw) * rh * 4);
    defer gpa.free(ref);
    var wma: u32 = 0;
    var hma: u32 = 0;
    var wmb: u32 = 0;
    var hmb: u32 = 0;
    var ws: u32 = 0;
    var hs: u32 = 0;
    var wn: u32 = 0;
    var hn: u32 = 0;

    // Session one carries face tracking and segmentation, so the face_skin
    // class exists and the reference skin tone drives the tint over it.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) return error.EnableFaceTrackingFailed;
        if (abi.goss_session_enable_segmentation(session, seg_bytes.ptr, seg_bytes.len, 2) != .ok) return error.EnableSegmentationFailed;
        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/foundation-match", ".lens-packages/foundation-match".len) != .ok) {
            std.debug.print("conformance: FAIL foundation-match lens activation\n", .{});
            return false;
        }
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        var mask_polls: usize = 0;
        while (session.segmentation_texture == null) {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            mask_polls += 1;
            if (mask_polls > 100_000) return error.SegmentationTimedOut;
        }
        paintSkinPatch(ref, rw, rh, &result.landmarks);
        const count: u32 = @intCast(result.landmarks.len / 3);
        if (abi.goss_session_set_makeup_reference(session, ref.ptr, rw, rh, &result.landmarks, count) != .ok) {
            std.debug.print("conformance: FAIL set_makeup_reference rejected the skin reference\n", .{});
            return false;
        }
        try renderCapture(engine, session, &desc, planes, half_w, matched_a, &wma, &hma);
        try renderCapture(engine, session, &desc, planes, half_w, matched_b, &wmb, &hmb);
        // Clearing the reference drops the skin tone, so the same lens now
        // paints its own static foundation color and the shade match is gone.
        if (abi.goss_session_set_makeup_reference(session, null, 0, 0, null, 0) != .ok) return error.ClearReferenceFailed;
        try renderCapture(engine, session, &desc, planes, half_w, static, &ws, &hs);
    }

    // Session two tracks the face but runs no segmenter, so face_skin serves
    // the zero mask: the reference-driven foundation has nothing to key and
    // must fade to the untouched frame.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);
        if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) return error.EnableFaceTrackingFailed;
        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/foundation-match", ".lens-packages/foundation-match".len) != .ok) return error.ActivationFailed;
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.TrackFrameFailed;
        var result: abi.FaceResult = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            if (g_watch) c.glfwPollEvents();
            polls += 1;
            if (polls > 100_000_000) return error.FaceResultTimedOut;
        }
        const count: u32 = @intCast(result.landmarks.len / 3);
        if (abi.goss_session_set_makeup_reference(session, ref.ptr, rw, rh, &result.landmarks, count) != .ok) return error.SetMakeupReferenceFailed;
        try renderCapture(engine, session, &desc, planes, half_w, noseg, &wn, &hn);
    }

    if (wma == 0 or wma != wmb or hma != hmb or wma != ws or hma != hs or wma != wn or hma != hn) {
        std.debug.print("conformance: FAIL foundation-match capture size mismatch\n", .{});
        return false;
    }
    const bytes = @as(usize, wma) * hma * 4;
    const matched_slice = matched_a[0..bytes];
    if (!std.mem.eql(u8, matched_slice, matched_b[0..bytes])) {
        std.debug.print("conformance: FAIL the foundation shade match is not deterministic across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, matched_slice, static[0..bytes])) {
        std.debug.print("conformance: FAIL the reference skin tone did not drive the tint - matched equals the static foundation\n", .{});
        return false;
    }
    if (std.mem.eql(u8, matched_slice, noseg[0..bytes])) {
        std.debug.print("conformance: FAIL the foundation drew with no face_skin mask - not keyed to the face\n", .{});
        return false;
    }
    const matched_green = greenness(matched_slice);
    const static_green = greenness(static[0..bytes]);
    if (matched_green <= static_green + 0.5) {
        std.debug.print("conformance: FAIL the face did not shift toward the green skin reference (matched {d:.2} static {d:.2})\n", .{ matched_green, static_green });
        return false;
    }
    std.debug.print("conformance: PROOF a reference-driven foundation matches the reference skin tone over face_skin, greener than the static color, gone with no mask, bit-stable\n", .{});
    return true;
}

/// Proves goss_engine_capture_photo end to end: the size probe
/// reports the exact needed size, a capture into an exactly-sized
/// buffer yields well-formed PNG bytes, and two captures of the same
/// composited frame are byte-identical.
fn provePhotoCapture(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const activated = abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len);
    if (activated != .ok) {
        std.debug.print("conformance: FAIL photo lens activation: {t}\n", .{activated});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    var needed: usize = 0;
    var photo_width: u32 = 0;
    var photo_height: u32 = 0;
    const probe = abi.goss_engine_capture_photo(engine, session, @ptrCast(&needed), 0, &needed, &photo_width, &photo_height);
    if (probe != .invalid_argument or needed == 0) {
        std.debug.print("conformance: FAIL photo size probe: {t}, needed {d}\n", .{ probe, needed });
        return false;
    }

    const first = try gpa.alloc(u8, needed);
    defer gpa.free(first);
    var first_len: usize = 0;
    if (abi.goss_engine_capture_photo(engine, session, first.ptr, first.len, &first_len, &photo_width, &photo_height) != .ok or first_len != needed) {
        std.debug.print("conformance: FAIL photo capture into an exactly-sized buffer\n", .{});
        return false;
    }
    const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (!std.mem.eql(u8, first[0..8], &png_signature) or !std.mem.eql(u8, first[12..16], "IHDR")) {
        std.debug.print("conformance: FAIL photo bytes are not a PNG\n", .{});
        return false;
    }
    if (std.mem.readInt(u32, first[16..20], .big) != photo_width or std.mem.readInt(u32, first[20..24], .big) != photo_height) {
        std.debug.print("conformance: FAIL photo IHDR does not match the reported size\n", .{});
        return false;
    }

    const second = try gpa.alloc(u8, needed);
    defer gpa.free(second);
    var second_len: usize = 0;
    if (abi.goss_engine_capture_photo(engine, session, second.ptr, second.len, &second_len, &photo_width, &photo_height) != .ok) {
        std.debug.print("conformance: FAIL second photo capture\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, first[0..first_len], second[0..second_len])) {
        std.debug.print("conformance: FAIL photo capture produced different bytes across two runs\n", .{});
        return false;
    }
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-photo.png", .data = first[0..first_len] });
    std.debug.print("conformance: PROOF photo capture is a deterministic PNG of the composited frame ({d}x{d}, {d} bytes, sha256 {s})\n", .{ photo_width, photo_height, first_len, sha256Hex(first[0..first_len]) });
    return true;
}

/// Pumps a few frames with no active session, purely so bgfx has enough
/// frame boundaries to actually retire whatever the session just
/// destroyed - destroySession's own bgfx_destroy_* calls only queue
/// destruction until the GPU is done with a resource, they do not force
/// it, so creating (or shutting down) immediately after leaves handles
/// bgfx itself still considers in flight.
fn settle(engine: *abi.Engine) void {
    for (0..10) |_| {
        _ = abi.goss_engine_render_frame(engine, null);
        c.glfwPollEvents();
    }
}

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Activates lens_name's packaged bundle twice, rendering the same real
/// corpus portrait through each, and asserts the two screenshots are
/// byte-identical - proving the lens is bit-stable, not just that it
/// happened to render something. Returns the hex hash of that output on
/// success, null (with a printed reason) on failure.
fn checkDeterminism(gpa: std.mem.Allocator, engine: *abi.Engine, lens_name: []const u8, segmentation_model: []const u8) !?[64]u8 {
    var bundle_buf: [256]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buf, ".lens-packages/{s}", .{lens_name});
    var out_a_buf: [256:0]u8 = undefined;
    const out_a = try std.fmt.bufPrintZ(&out_a_buf, "zig-out/conformance-{s}-a", .{lens_name});
    var out_b_buf: [256:0]u8 = undefined;
    const out_b = try std.fmt.bufPrintZ(&out_b_buf, "zig-out/conformance-{s}-b", .{lens_name});

    try renderOnce(gpa, engine, bundle_path, out_a, segmentation_model);
    settle(engine);
    try renderOnce(gpa, engine, bundle_path, out_b, segmentation_model);
    settle(engine);

    var path_a_buf: [256]u8 = undefined;
    const path_a = try std.fmt.bufPrint(&path_a_buf, "{s}.tga", .{out_a});
    var path_b_buf: [256]u8 = undefined;
    const path_b = try std.fmt.bufPrint(&path_b_buf, "{s}.tga", .{out_b});

    const shot_a = try std.Io.Dir.cwd().readFileAlloc(harness_io, path_a, gpa, .limited(8 << 20));
    defer gpa.free(shot_a);
    const shot_b = try std.Io.Dir.cwd().readFileAlloc(harness_io, path_b, gpa, .limited(8 << 20));
    defer gpa.free(shot_b);

    if (!std.mem.eql(u8, shot_a, shot_b)) {
        std.debug.print("conformance: FAIL {s} produced different output across two runs of the same fixed input\n", .{lens_name});
        return null;
    }
    const hash = sha256Hex(shot_a);
    std.debug.print("conformance: PROOF {s} is bit-stable across two runs of the same fixed input through the real ABI ({d} bytes, sha256 {s})\n", .{ lens_name, shot_a.len, hash });
    return hash;
}

/// Proves play_animation actually fires and changes the rendered
/// output, not just that it compiles - the bit-stability loop above
/// only ever exercises the reference lenses' default, never-triggered
/// state, since it never calls goss_session_tick_lens at all. Activates
/// the real packaged trigger-anim bundle, screenshots its rest pose,
/// ticks it in dt_us steps past its own manifest's 2-second timer
/// threshold, screenshots again, and asserts the two differ.
fn proveTriggerAnimFires(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/trigger-anim";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: trigger-anim proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }

    // Let the model.gltf node's async .glb load land before either
    // screenshot - both must show a real drawn mesh, only the pose
    // should differ.
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const before_path: [:0]const u8 = "zig-out/conformance-trigger-anim-before";
    engine.renderer.?.requestScreenshot(before_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    var signals = std.mem.zeroes(abi.LensSignals);
    var elapsed_us: u64 = 0;
    const dt_us: u32 = 16_666;
    while (elapsed_us < 2_100_000) : (elapsed_us += dt_us) {
        if (abi.goss_session_tick_lens(session, dt_us, &signals) != .ok) {
            std.debug.print("conformance: trigger-anim proof: tick refused\n", .{});
            return false;
        }
    }

    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const after_path: [:0]const u8 = "zig-out/conformance-trigger-anim-after";
    engine.renderer.?.requestScreenshot(after_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const before = try std.Io.Dir.cwd().readFileAlloc(harness_io, before_path ++ ".tga", gpa, .limited(8 << 20));
    defer gpa.free(before);
    const after = try std.Io.Dir.cwd().readFileAlloc(harness_io, after_path ++ ".tga", gpa, .limited(8 << 20));
    defer gpa.free(after);

    if (std.mem.eql(u8, before, after)) {
        std.debug.print("conformance: FAIL trigger-anim: play_animation firing after {d}us produced no visible change\n", .{elapsed_us});
        return false;
    }
    std.debug.print("conformance: PROOF trigger-anim's play_animation trigger fires after {d}us and visibly changes the rendered mesh pose\n", .{elapsed_us});
    return true;
}

/// Proves the mixer blends clips by their bound weights. The anim-mixer
/// bundle holds a spin clip and a slide clip whose weights start on the
/// spin clip (quad centered) and ramp onto the slide clip (quad offset in
/// +x), so screenshots before and after the ramp must differ.
fn proveMixerBlend(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/anim-mixer";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: anim-mixer proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }

    // Let the async .glb land, then screenshot the rest pose: full weight
    // on the spin clip, the quad centered.
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const before_path: [:0]const u8 = "zig-out/conformance-anim-mixer-before";
    engine.renderer.?.requestScreenshot(before_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // Tick past the triggers' 0.3s threshold and the 100ms ramp so the
    // weight moves fully onto the slide clip.
    var signals = std.mem.zeroes(abi.LensSignals);
    var elapsed_us: u64 = 0;
    const dt_us: u32 = 16_666;
    while (elapsed_us < 600_000) : (elapsed_us += dt_us) {
        if (abi.goss_session_tick_lens(session, dt_us, &signals) != .ok) {
            std.debug.print("conformance: anim-mixer proof: tick refused\n", .{});
            return false;
        }
    }

    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const after_path: [:0]const u8 = "zig-out/conformance-anim-mixer-after";
    engine.renderer.?.requestScreenshot(after_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const before = try std.Io.Dir.cwd().readFileAlloc(harness_io, before_path ++ ".tga", gpa, .limited(8 << 20));
    defer gpa.free(before);
    const after = try std.Io.Dir.cwd().readFileAlloc(harness_io, after_path ++ ".tga", gpa, .limited(8 << 20));
    defer gpa.free(after);

    if (std.mem.eql(u8, before, after)) {
        std.debug.print("conformance: FAIL anim-mixer: shifting the clip weights left the pose unchanged\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF anim-mixer blends its clips by weight: ramping onto the slide clip visibly moves the pose\n", .{});
    return true;
}

/// Proves a lens deforms a mesh by its bound morph weights. The morph-blend
/// bundle's quad carries one morph target that expands it; its weight starts
/// at zero and a param_ramp drives it to one, so screenshots before and
/// after the ramp must differ.
fn proveMorphBlend(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/morph-blend";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: morph-blend proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }

    // Let the async .glb land, then screenshot the rest mesh: weight zero,
    // the quad at its base size.
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const before_path: [:0]const u8 = "zig-out/conformance-morph-blend-before";
    engine.renderer.?.requestScreenshot(before_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // Tick past the trigger's 0.3s threshold and the 100ms ramp so the
    // morph weight reaches one and the quad expands.
    var signals = std.mem.zeroes(abi.LensSignals);
    var elapsed_us: u64 = 0;
    const dt_us: u32 = 16_666;
    while (elapsed_us < 600_000) : (elapsed_us += dt_us) {
        if (abi.goss_session_tick_lens(session, dt_us, &signals) != .ok) {
            std.debug.print("conformance: morph-blend proof: tick refused\n", .{});
            return false;
        }
    }

    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const after_path: [:0]const u8 = "zig-out/conformance-morph-blend-after";
    engine.renderer.?.requestScreenshot(after_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const before = try std.Io.Dir.cwd().readFileAlloc(harness_io, before_path ++ ".tga", gpa, .limited(8 << 20));
    defer gpa.free(before);
    const after = try std.Io.Dir.cwd().readFileAlloc(harness_io, after_path ++ ".tga", gpa, .limited(8 << 20));
    defer gpa.free(after);

    if (std.mem.eql(u8, before, after)) {
        std.debug.print("conformance: FAIL morph-blend: driving the morph weight left the mesh unchanged\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF morph-blend deforms its mesh by weight: ramping the morph weight visibly expands the quad\n", .{});
    return true;
}

/// Captures the face-reenact avatar deformed by one injected source face. The
/// caller owns the returned RGBA; the source performance is held across the
/// rendered frames since no tracker overwrites the submitted faces.
fn captureReenactShot(gpa: std.mem.Allocator, engine: *abi.Engine, session: *abi.Session, planes: Nv12Copy, faces: []const abi.FaceResult) ![]u8 {
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    if (abi.goss_session_submit_faces(session, faces.ptr, @intCast(faces.len)) != .ok) return error.SubmitFacesFailed;
    for (0..5) |_| {
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    var w: u32 = 0;
    var h: u32 = 0;
    const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
    errdefer gpa.free(shot);
    if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &w, &h) != .ok) return error.CaptureFailed;
    return shot;
}

/// Proves one-shot head reenactment: a source face injected through
/// goss_session_submit_faces (not the local live face) carries jawOpen, and the
/// face-reenact lens binds its jawOpen morph target to it, so a wide-open source
/// jaw deforms the avatar mesh where a closed one holds it at rest, same still.
fn proveHeadReenact(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/face-reenact";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len) != .ok) {
        std.debug.print("conformance: FAIL face-reenact lens activation\n", .{});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    // Land the async .glb before either capture so both read a drawn mesh and
    // only the driven pose differs.
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
    pumpUntilLoaded(engine, session);

    // blendshape_names[25] is jawOpen, pinned by a face module test.
    const jaw_open = 25;
    var closed = std.mem.zeroes(abi.FaceResult);
    closed.presence = 1.0;
    closed.landmark_count_out = @intCast(closed.landmarks.len / 3);
    closed.blendshapes[jaw_open] = 0.05;
    var open = closed;
    open.blendshapes[jaw_open] = 0.9;

    const shot_closed = try captureReenactShot(gpa, engine, session, planes, &[_]abi.FaceResult{closed});
    defer gpa.free(shot_closed);
    const shot_open = try captureReenactShot(gpa, engine, session, planes, &[_]abi.FaceResult{open});
    defer gpa.free(shot_open);

    var changed: usize = 0;
    var i: usize = 0;
    while (i + 4 <= shot_closed.len) : (i += 4) {
        if (!std.mem.eql(u8, shot_closed[i .. i + 4], shot_open[i .. i + 4])) changed += 1;
    }
    if (changed == 0) {
        std.debug.print("conformance: FAIL head-reenact: the injected source jaw left the avatar mesh unchanged\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a retarget avatar is reenacted by an injected source performance: an open source jaw deforms the mesh where a closed one holds it at rest ({d} pixels changed)\n", .{changed});
    return true;
}

/// Loads a directory lens and lands its async .glb before a face-driven capture.
fn activateAndLoad(gpa: std.mem.Allocator, engine: *abi.Engine, session: *abi.Session, dir: []const u8, planes: Nv12Copy) !bool {
    _ = gpa;
    if (abi.goss_session_activate_lens_from_directory(session, dir.ptr, dir.len) != .ok) return false;
    const half_w = (planes.width + 1) / 2;
    const desc: abi.FrameDesc = .{ .width = planes.width, .height = planes.height, .pixel_format = 0, .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 1000 };
    _ = abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2);
    pumpUntilLoaded(engine, session);
    return true;
}

/// Proves the stylized avatar system: the avatar-toon lens toon-shades a
/// retarget avatar, and it stays live. The toon avatar under an open injected
/// jaw differs from the same under a closed one (liveness) and from the
/// un-stylized avatar (style applied), so any tracked avatar renders in a style.
fn proveStylizedAvatar(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);

    // blendshape_names[25] is jawOpen, pinned by a face module test.
    const jaw_open = 25;
    var closed = std.mem.zeroes(abi.FaceResult);
    closed.presence = 1.0;
    closed.landmark_count_out = @intCast(closed.landmarks.len / 3);
    closed.blendshapes[jaw_open] = 0.05;
    var open = closed;
    open.blendshapes[jaw_open] = 0.9;

    const toon = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(toon);
    defer settle(engine);
    if (!try activateAndLoad(gpa, engine, toon, ".lens-packages/avatar-toon", planes)) {
        std.debug.print("conformance: FAIL avatar-toon lens activation\n", .{});
        return false;
    }
    const toon_open = try captureReenactShot(gpa, engine, toon, planes, &[_]abi.FaceResult{open});
    defer gpa.free(toon_open);
    const toon_closed = try captureReenactShot(gpa, engine, toon, planes, &[_]abi.FaceResult{closed});
    defer gpa.free(toon_closed);

    const plain = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(plain);
    if (!try activateAndLoad(gpa, engine, plain, ".lens-packages/face-reenact", planes)) {
        std.debug.print("conformance: FAIL face-reenact control activation\n", .{});
        return false;
    }
    const plain_open = try captureReenactShot(gpa, engine, plain, planes, &[_]abi.FaceResult{open});
    defer gpa.free(plain_open);

    const live = countDiff(toon_open, toon_closed);
    const styled = countDiff(toon_open, plain_open);
    if (live == 0) {
        std.debug.print("conformance: FAIL stylized-avatar: the toon avatar did not track the injected jaw\n", .{});
        return false;
    }
    if (styled == 0) {
        std.debug.print("conformance: FAIL stylized-avatar: the toon style left the avatar unchanged\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a tracked avatar renders in an art style and stays live: a toon avatar tracks an injected jaw ({d} bytes) and differs from the un-stylized avatar ({d} bytes)\n", .{ live, styled });
    return true;
}

/// Proves a sprite.2d node draws its image over the frame. The static
/// Renders frames until every async image and model load has landed, so a
/// screenshot reads a deterministic frame no matter how the loader threads were
/// scheduled. Caps the wait so a genuinely stuck load still fails loudly.
fn pumpUntilLoaded(engine: *abi.Engine, session: anytype) void {
    var frames: u32 = 0;
    while (abi.loadsPending(session) > 0 and frames < 600) : (frames += 1) {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    // A few more frames so the freshly-uploaded textures are drawn.
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
}

/// sprite-overlay bundle draws a badge in a centre rect; its output must
/// differ from the same frame with no lens, so the sprite really composited.
fn proveSpriteDraw(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;

    // Baseline: the frame through a session with no lens.
    {
        const plain = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(plain);
        if (abi.goss_session_submit_frame_copy(plain, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        for (0..8) |_| {
            _ = abi.goss_engine_render_frame(engine, plain);
            c.glfwPollEvents();
        }
        engine.renderer.?.requestScreenshot("zig-out/conformance-sprite-plain");
        for (0..5) |_| {
            _ = abi.goss_engine_render_frame(engine, plain);
            c.glfwPollEvents();
        }
        settle(engine);
    }

    // The sprite lens, given time for its image to decode, then screenshot.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        const bundle_path = ".lens-packages/sprite-overlay";
        const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
        if (activated != .ok) {
            std.debug.print("conformance: sprite-overlay proof: activate: {s}\n", .{@tagName(activated)});
            return false;
        }
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        pumpUntilLoaded(engine, session);
        engine.renderer.?.requestScreenshot("zig-out/conformance-sprite-drawn");
        for (0..5) |_| {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        settle(engine);
    }

    const plain = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-sprite-plain.tga", gpa, .limited(8 << 20));
    defer gpa.free(plain);
    const drawn = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-sprite-drawn.tga", gpa, .limited(8 << 20));
    defer gpa.free(drawn);

    if (std.mem.eql(u8, plain, drawn)) {
        std.debug.print("conformance: FAIL sprite-overlay: the sprite produced no visible change over the plain frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF sprite-overlay draws its image over the frame: the composited output differs from the plain frame\n", .{});
    return true;
}

/// Proves a text.2d node rasterizes and draws its string. The text-overlay
/// bundle draws a label over the frame; its output must differ from the
/// same frame with no lens, so the built-in font really composited.
fn proveTextDraw(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;

    // Baseline: the frame through a session with no lens.
    {
        const plain = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(plain);
        if (abi.goss_session_submit_frame_copy(plain, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        for (0..8) |_| {
            _ = abi.goss_engine_render_frame(engine, plain);
            c.glfwPollEvents();
        }
        engine.renderer.?.requestScreenshot("zig-out/conformance-text-plain");
        for (0..5) |_| {
            _ = abi.goss_engine_render_frame(engine, plain);
            c.glfwPollEvents();
        }
        settle(engine);
    }

    // The text lens: its string rasterizes at activation, so it draws right away.
    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        const bundle_path = ".lens-packages/text-overlay";
        const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
        if (activated != .ok) {
            std.debug.print("conformance: text-overlay proof: activate: {s}\n", .{@tagName(activated)});
            return false;
        }
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        for (0..8) |_| {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        engine.renderer.?.requestScreenshot("zig-out/conformance-text-drawn");
        for (0..5) |_| {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        settle(engine);
    }

    const plain = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-text-plain.tga", gpa, .limited(8 << 20));
    defer gpa.free(plain);
    const drawn = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-text-drawn.tga", gpa, .limited(8 << 20));
    defer gpa.free(drawn);

    if (std.mem.eql(u8, plain, drawn)) {
        std.debug.print("conformance: FAIL text-overlay: the text produced no visible change over the plain frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF text-overlay rasterizes and draws its string: the composited output differs from the plain frame\n", .{});
    return true;
}

/// Proves a material graph can clip the frame to a region: the material-clip
/// bundle keeps the frame inside a centre rect and blacks out the rest
/// through a step/mix graph, so its output must differ from the plain frame.
fn proveMaterialClip(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;

    {
        const plain = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(plain);
        if (abi.goss_session_submit_frame_copy(plain, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        for (0..8) |_| {
            _ = abi.goss_engine_render_frame(engine, plain);
            c.glfwPollEvents();
        }
        engine.renderer.?.requestScreenshot("zig-out/conformance-clip-plain");
        for (0..5) |_| {
            _ = abi.goss_engine_render_frame(engine, plain);
            c.glfwPollEvents();
        }
        settle(engine);
    }

    {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        const bundle_path = ".lens-packages/material-clip";
        const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
        if (activated != .ok) {
            std.debug.print("conformance: material-clip proof: activate: {s}\n", .{@tagName(activated)});
            return false;
        }
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
        for (0..8) |_| {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        engine.renderer.?.requestScreenshot("zig-out/conformance-clip-drawn");
        for (0..5) |_| {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        settle(engine);
    }

    const plain = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-clip-plain.tga", gpa, .limited(8 << 20));
    defer gpa.free(plain);
    const drawn = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-clip-drawn.tga", gpa, .limited(8 << 20));
    defer gpa.free(drawn);

    if (std.mem.eql(u8, plain, drawn)) {
        std.debug.print("conformance: FAIL material-clip: clipping the frame to a region produced no visible change\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF material-clip clips the frame to a region: the composited output differs from the plain frame\n", .{});
    return true;
}

/// Proves a sprite's opacity follows a bound parameter. The sprite-fade
/// bundle draws a badge at full opacity, then a param_ramp fades its
/// opacity_param to zero, so the frame before the ramp (badge visible) and
/// after (badge gone) must differ.
fn proveSpriteFade(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/sprite-fade";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: sprite-fade proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;

    pumpUntilLoaded(engine, session);
    engine.renderer.?.requestScreenshot("zig-out/conformance-sprite-fade-before");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    var signals = std.mem.zeroes(abi.LensSignals);
    var elapsed_us: u64 = 0;
    const dt_us: u32 = 16_666;
    while (elapsed_us < 600_000) : (elapsed_us += dt_us) {
        if (abi.goss_session_tick_lens(session, dt_us, &signals) != .ok) {
            std.debug.print("conformance: sprite-fade proof: tick refused\n", .{});
            return false;
        }
    }

    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-sprite-fade-after");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const before = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-sprite-fade-before.tga", gpa, .limited(8 << 20));
    defer gpa.free(before);
    const after = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-sprite-fade-after.tga", gpa, .limited(8 << 20));
    defer gpa.free(after);

    if (std.mem.eql(u8, before, after)) {
        std.debug.print("conformance: FAIL sprite-fade: fading the opacity parameter left the frame unchanged\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF sprite-fade follows its opacity parameter: ramping it to zero fades the badge out\n", .{});
    return true;
}

/// Proves an animated sprite cycles its frames off the lens clock. The
/// sprite-anim bundle draws a two-frame badge at 8 fps; the frame at
/// elapsed zero and the frame after ticking a quarter second (past one
/// frame period) draw different images, so the two must differ.
fn proveSpriteAnim(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/sprite-anim";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: sprite-anim proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;

    // Let both frames decode (no tick, so the clock stays at zero), then
    // screenshot frame 0.
    pumpUntilLoaded(engine, session);
    engine.renderer.?.requestScreenshot("zig-out/conformance-sprite-anim-frame0");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // Advance the lens clock into the second frame's window (one frame
    // period at 8 fps is 125ms; ~180ms lands on frame 1, not a wrap back
    // to frame 0 as a full 250ms two-period tick would).
    var signals = std.mem.zeroes(abi.LensSignals);
    var elapsed_us: u64 = 0;
    const dt_us: u32 = 16_666;
    while (elapsed_us < 180_000) : (elapsed_us += dt_us) {
        if (abi.goss_session_tick_lens(session, dt_us, &signals) != .ok) {
            std.debug.print("conformance: sprite-anim proof: tick refused\n", .{});
            return false;
        }
    }

    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-sprite-anim-frame1");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const frame0 = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-sprite-anim-frame0.tga", gpa, .limited(8 << 20));
    defer gpa.free(frame0);
    const frame1 = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-sprite-anim-frame1.tga", gpa, .limited(8 << 20));
    defer gpa.free(frame1);

    if (std.mem.eql(u8, frame0, frame1)) {
        std.debug.print("conformance: FAIL sprite-anim: advancing the clock did not change the sprite frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF sprite-anim cycles its frames off the lens clock: advancing the clock draws a different frame\n", .{});
    return true;
}

/// Proves a sprite.2d node plays an animated GIF as a video texture. The
/// gif-sprite bundle ships clip.gif, a bar sweeping across six frames; the
/// hand-written decoder turns it into textures the sprite cycles off the lens
/// clock, so advancing the clock draws a different frame.
fn proveGifSprite(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/gif-sprite";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: gif-sprite proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;

    // The GIF decodes to textures at activation; wait for the load to land.
    pumpUntilLoaded(engine, session);
    engine.renderer.?.requestScreenshot("zig-out/conformance-gif-frame0");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // The clip runs at 12.5 fps (80ms a frame); 120ms lands on frame 1, its
    // bar swept to a new column, not a wrap back to frame 0.
    var signals = std.mem.zeroes(abi.LensSignals);
    var elapsed_us: u64 = 0;
    const dt_us: u32 = 16_666;
    while (elapsed_us < 120_000) : (elapsed_us += dt_us) {
        if (abi.goss_session_tick_lens(session, dt_us, &signals) != .ok) return error.TickRefused;
    }

    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-gif-frame1");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const frame0 = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-gif-frame0.tga", gpa, .limited(8 << 20));
    defer gpa.free(frame0);
    const frame1 = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-gif-frame1.tga", gpa, .limited(8 << 20));
    defer gpa.free(frame1);

    if (std.mem.eql(u8, frame0, frame1)) {
        std.debug.print("conformance: FAIL gif-sprite: advancing the clock did not change the GIF frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF gif-sprite plays its clip off the lens clock: advancing the clock draws a different decoded GIF frame\n", .{});
    return true;
}

/// Proves the dof.pass blurs by the submitted depth. The dof-blur bundle
/// holds the frame through until depth arrives (its capability is absent),
/// then, given a near-to-far depth gradient, softens everything off the
/// focus plane, so the frame with depth differs from the frame without.
fn proveDofPass(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/dof-blur";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: dof-blur proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;

    // No depth yet: the dof.pass holds the frame through.
    for (0..8) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-dof-nodepth");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // A near-to-far depth gradient across the frame: only the middle sits at
    // the focus plane, so the sides blur.
    const dw: u32 = 32;
    const dh: u32 = 32;
    var depth: [dw * dh]f32 = undefined;
    for (0..dh) |y| {
        for (0..dw) |x| {
            const t01 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(dw - 1));
            depth[y * dw + x] = 0.1 + t01 * 4.9;
        }
    }
    if (abi.goss_session_submit_depth(session, &depth, dw, dh, 0.1, 5.0) != .ok) return error.SubmitFailed;

    for (0..8) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-dof-depth");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const nodepth = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-dof-nodepth.tga", gpa, .limited(8 << 20));
    defer gpa.free(nodepth);
    const withdepth = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-dof-depth.tga", gpa, .limited(8 << 20));
    defer gpa.free(withdepth);

    if (std.mem.eql(u8, nodepth, withdepth)) {
        std.debug.print("conformance: FAIL dof-blur: submitting depth did not change the frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF dof-blur softens by depth: the frame with a depth gradient differs from the frame without depth\n", .{});
    return true;
}

/// Proves the fog.pass fades the frame toward its fog color by the submitted
/// depth. The fog-depth bundle holds the frame through until depth arrives,
/// then, given a near-to-far gradient, sinks the far side into haze, so the
/// frame with depth differs from the frame without.
fn proveFogPass(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/fog-depth";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: fog-depth proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;

    for (0..8) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-fog-nodepth");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    const dw: u32 = 32;
    const dh: u32 = 32;
    var depth: [dw * dh]f32 = undefined;
    for (0..dh) |y| {
        for (0..dw) |x| {
            const t01 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(dw - 1));
            depth[y * dw + x] = 0.1 + t01 * 4.9;
        }
    }
    if (abi.goss_session_submit_depth(session, &depth, dw, dh, 0.1, 5.0) != .ok) return error.SubmitFailed;

    for (0..8) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-fog-depth");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const nodepth = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-fog-nodepth.tga", gpa, .limited(8 << 20));
    defer gpa.free(nodepth);
    const withdepth = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-fog-depth.tga", gpa, .limited(8 << 20));
    defer gpa.free(withdepth);

    if (std.mem.eql(u8, nodepth, withdepth)) {
        std.debug.print("conformance: FAIL fog-depth: submitting depth did not change the frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF fog-depth fades by depth: the frame with a depth gradient differs from the frame without depth\n", .{});
    return true;
}

/// Proves the outline.pass draws where depth jumps, not merely where it
/// varies. The outline-edge bundle, given a flat depth, leaves the frame be
/// (no edge), but given a depth with a sharp step draws a line along it, so
/// the stepped frame differs from the flat one.
fn proveOutlinePass(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/outline-edge";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: outline-edge proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;

    // A realistic-resolution depth so the outline's small uv tap spans a
    // texel; heap-allocated to keep it off the stack.
    const dw: u32 = 256;
    const dh: u32 = 256;
    const flat = try gpa.alloc(f32, dw * dh);
    defer gpa.free(flat);
    const stepd = try gpa.alloc(f32, dw * dh);
    defer gpa.free(stepd);

    // Flat depth: no edges, so the outline pass leaves the frame alone.
    for (flat) |*d| d.* = 2.0;
    if (abi.goss_session_submit_depth(session, flat.ptr, dw, dh, 0.1, 5.0) != .ok) return error.SubmitFailed;
    for (0..8) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-outline-flat");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // A depth with a sharp step down the middle: an outline draws along it.
    for (0..dh) |y| {
        for (0..dw) |x| {
            stepd[y * dw + x] = if (x < dw / 2) 0.5 else 4.0;
        }
    }
    if (abi.goss_session_submit_depth(session, stepd.ptr, dw, dh, 0.1, 5.0) != .ok) return error.SubmitFailed;
    for (0..8) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-outline-step");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const flat_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-outline-flat.tga", gpa, .limited(8 << 20));
    defer gpa.free(flat_tga);
    const step_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-outline-step.tga", gpa, .limited(8 << 20));
    defer gpa.free(step_tga);

    if (std.mem.eql(u8, flat_tga, step_tga)) {
        std.debug.print("conformance: FAIL outline-edge: a depth step drew no outline over flat depth\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF outline-edge draws on depth steps: a stepped depth outlines where flat depth does not\n", .{});
    return true;
}

/// Proves the trail.pass echoes the previous frame. Right after the scene
/// cuts from A to B the frame still carries A's echo, so it differs from the
/// same B once the echo has settled to B alone - both captures are frame B,
/// so the trail is the only difference between them.
fn proveTrailPass(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/trail-echo";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: trail-echo proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes_a = try rgbaToNv12(gpa, corpus.frame);
    defer planes_a.deinit(gpa);

    // Frame B: a solid fill at the same size as A, so a trailed B and a
    // settled B differ only by A's echo, never by a size change resetting
    // the trail's previous-frame buffer.
    const w = corpus.frame.width;
    const h = corpus.frame.height;
    const rgba_b = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(rgba_b);
    var i: usize = 0;
    while (i < rgba_b.len) : (i += 4) {
        rgba_b[i] = 220;
        rgba_b[i + 1] = 30;
        rgba_b[i + 2] = 200;
        rgba_b[i + 3] = 255;
    }
    const frame_b: sampler.Frame = .{ .pixels = .{ .rgba8 = rgba_b }, .width = w, .height = h };
    const planes_b = try rgbaToNv12(gpa, frame_b);
    defer planes_b.deinit(gpa);

    const desc: abi.FrameDesc = .{
        .width = w,
        .height = h,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (w + 1) / 2;

    // Settle on frame A so the trail's previous-frame buffer holds A.
    if (abi.goss_session_submit_frame_copy(session, &desc, planes_a.y.ptr, w, planes_a.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
    for (0..8) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // Cut to frame B: the very next frame still echoes A.
    if (abi.goss_session_submit_frame_copy(session, &desc, planes_b.y.ptr, w, planes_b.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
    engine.renderer.?.requestScreenshot("zig-out/conformance-trail-echo");
    for (0..6) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // B is now the previous frame too, so the echo has settled to B alone.
    engine.renderer.?.requestScreenshot("zig-out/conformance-trail-settled");
    for (0..6) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const echo_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-trail-echo.tga", gpa, .limited(8 << 20));
    defer gpa.free(echo_tga);
    const settled_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-trail-settled.tga", gpa, .limited(8 << 20));
    defer gpa.free(settled_tga);

    if (std.mem.eql(u8, echo_tga, settled_tga)) {
        std.debug.print("conformance: FAIL trail-echo: the frame after a scene cut carried no echo of the frame before it\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF trail-echo blends the previous frame: the frame right after a cut differs from the same frame once the echo has settled\n", .{});
    return true;
}

/// Proves the ssr.pass reflects by the submitted depth. The ssr-floor bundle
/// mirrors the scene into the floor below the horizon, scaled by how near the
/// depth reads: a far, dry floor leaves the frame alone, a near one wets it
/// with a reflection, so the near-depth frame differs from the far one.
fn proveSsrPass(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/ssr-floor";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: ssr-floor proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;

    const dw: u32 = 64;
    const dh: u32 = 64;
    const depth = try gpa.alloc(f32, dw * dh);
    defer gpa.free(depth);

    // A far, dry floor: depth at the far plane reads no reflection.
    for (depth) |*d| d.* = 5.0;
    if (abi.goss_session_submit_depth(session, depth.ptr, dw, dh, 0.1, 5.0) != .ok) return error.SubmitFailed;
    for (0..8) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-ssr-dry");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // A near floor: the same region now wets with a mirrored reflection.
    for (depth) |*d| d.* = 0.1;
    if (abi.goss_session_submit_depth(session, depth.ptr, dw, dh, 0.1, 5.0) != .ok) return error.SubmitFailed;
    for (0..8) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-ssr-wet");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const dry_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-ssr-dry.tga", gpa, .limited(8 << 20));
    defer gpa.free(dry_tga);
    const wet_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-ssr-wet.tga", gpa, .limited(8 << 20));
    defer gpa.free(wet_tga);

    if (std.mem.eql(u8, dry_tga, wet_tga)) {
        std.debug.print("conformance: FAIL ssr-floor: a near depth wet no reflection over the far, dry floor\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF ssr-floor reflects by depth: a near floor wets with a mirrored reflection where a far one stays dry\n", .{});
    return true;
}

/// Proves the env.pass sky pans with the submitted camera pose. The env-sky
/// bundle draws a sky gradient behind the segmented foreground; tilting the
/// camera up shifts the gradient, so the pitched-pose frame differs from the
/// level one while the foreground subject stays put.
fn proveEnvPass(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/env-sky";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const seg_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, single_class_model_path, gpa, .limited(16 << 20));
    defer gpa.free(seg_bytes);
    if (abi.goss_session_enable_segmentation(session, seg_bytes.ptr, seg_bytes.len, 2) != .ok) return error.EnableSegmentationFailed;

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: env-sky proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    // The analysis path feeds the segmentation worker; the render path feeds
    // the preview the sky composites over.
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;

    // Render until the segmentation worker publishes its mask, so the sky has
    // a real background region to fill behind the subject.
    var mask_polls: usize = 0;
    while (session.segmentation_texture == null) {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        mask_polls += 1;
        if (mask_polls > 100_000) return error.MaskTimedOut;
    }

    // A level pose: the camera looks straight ahead, the sky centered.
    var level: abi.WorldState = .{ .tracking_state = 2, .world_from_camera = identity_pose, .projection = identity_pose, .timestamp_us = 1000 };
    if (abi.goss_session_submit_world(session, &level, null, 0, null, 0, null) != .ok) return error.SubmitFailed;
    for (0..6) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-env-level");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // Tilt up 0.6 rad about x: the camera's forward rises, shifting the sky.
    const a: f32 = 0.6;
    const ca = std.math.cos(a);
    const sa = std.math.sin(a);
    const pitched_pose = [16]f32{ 1, 0, 0, 0, 0, ca, sa, 0, 0, -sa, ca, 0, 0, 0, 0, 1 };
    var pitched: abi.WorldState = .{ .tracking_state = 2, .world_from_camera = pitched_pose, .projection = identity_pose, .timestamp_us = 2000 };
    if (abi.goss_session_submit_world(session, &pitched, null, 0, null, 0, null) != .ok) return error.SubmitFailed;
    for (0..6) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-env-pitched");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const level_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-env-level.tga", gpa, .limited(8 << 20));
    defer gpa.free(level_tga);
    const pitched_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-env-pitched.tga", gpa, .limited(8 << 20));
    defer gpa.free(pitched_tga);

    if (std.mem.eql(u8, level_tga, pitched_tga)) {
        std.debug.print("conformance: FAIL env-sky: tilting the camera pose did not pan the sky\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF env-sky pans with the pose: tilting the camera up shifts the sky behind the segmented foreground\n", .{});
    return true;
}

/// Proves env.pass's image variant samples an equirect by the pose. The
/// env-map bundle ships a sky.png with a sun at one longitude; yawing the
/// camera pans it, so the yawed frame differs from the level one while the
/// segmented foreground stays put.
fn proveEnvmapPass(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/env-map";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const seg_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, single_class_model_path, gpa, .limited(16 << 20));
    defer gpa.free(seg_bytes);
    if (abi.goss_session_enable_segmentation(session, seg_bytes.ptr, seg_bytes.len, 2) != .ok) return error.EnableSegmentationFailed;

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: env-map proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const desc: abi.FrameDesc = .{
        .width = planes.width,
        .height = planes.height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;

    // Render until both the segmentation mask and the equirect image have
    // landed, so the pass takes its image path over a real background.
    var polls: usize = 0;
    while (session.segmentation_texture == null or session.env_textures.count() == 0) {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
        polls += 1;
        if (polls > 100_000) return error.EnvMapTimedOut;
    }

    var level: abi.WorldState = .{ .tracking_state = 2, .world_from_camera = identity_pose, .projection = identity_pose, .timestamp_us = 1000 };
    if (abi.goss_session_submit_world(session, &level, null, 0, null, 0, null) != .ok) return error.SubmitFailed;
    for (0..6) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-envmap-level");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // Yaw 1.0 rad about y: the camera turns, panning the equirect sideways.
    const b: f32 = 1.0;
    const cb = std.math.cos(b);
    const sb = std.math.sin(b);
    const yawed_pose = [16]f32{ cb, 0, -sb, 0, 0, 1, 0, 0, sb, 0, cb, 0, 0, 0, 0, 1 };
    var yawed: abi.WorldState = .{ .tracking_state = 2, .world_from_camera = yawed_pose, .projection = identity_pose, .timestamp_us = 2000 };
    if (abi.goss_session_submit_world(session, &yawed, null, 0, null, 0, null) != .ok) return error.SubmitFailed;
    for (0..6) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot("zig-out/conformance-envmap-yawed");
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const level_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-envmap-level.tga", gpa, .limited(8 << 20));
    defer gpa.free(level_tga);
    const yawed_tga = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-envmap-yawed.tga", gpa, .limited(8 << 20));
    defer gpa.free(yawed_tga);

    if (std.mem.eql(u8, level_tga, yawed_tga)) {
        std.debug.print("conformance: FAIL env-map: yawing the camera did not pan the equirect\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF env-map samples the equirect by pose: yawing the camera pans the environment behind the foreground\n", .{});
    return true;
}

const identity_pose = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

var g_watch_window: ?*c.GLFWwindow = null;
var g_watch = false;

// In watch mode, hold each proof's final frame on screen and title the
// window with its name, so the run reads as a live sequence of real
// renders instead of one frozen frame. A no-op in the default run.
fn watchHold(name: [*:0]const u8) void {
    if (!g_watch) return;
    const window = g_watch_window orelse return;
    c.glfwSetWindowTitle(window, name);
    var held: usize = 0;
    while (held < 30) : (held += 1) {
        c.glfwWaitEventsTimeout(0.016);
    }
}

pub fn main(init_args: std.process.Init) !u8 {
    const gpa = init_args.gpa;
    harness_io = init_args.io;

    // Screenshot comparisons land under zig-out/, which a clean
    // checkout does not have until the first install step runs.
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out");

    var arg_it = std.process.Args.Iterator.init(init_args.minimal.args);
    _ = arg_it.next();
    const first_arg = arg_it.next();
    const print_mode = if (first_arg) |arg| std.mem.eql(u8, arg, "--print") else false;
    g_watch = if (first_arg) |arg| std.mem.eql(u8, arg, "--watch") else false;

    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInit;
    defer c.glfwTerminate();
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(@intCast(width), @intCast(height), "conformance", null, null) orelse return error.WindowCreate;
    defer c.glfwDestroyWindow(window);
    g_watch_window = window;

    // The engine runs under a counting allocator so the per-frame budget
    // gate can watch its heap footprint settle across a render loop.
    var frame_counter = CountingAllocator{ .backing = gpa };
    const engine = try abi.createEngine(frame_counter.allocator(), .{ .texture_pool_capacity = 4, .staging_pool_capacity = 4 });
    defer abi.destroyEngine(engine);

    const renderer_desc: abi.RendererDesc = .{
        .native_window_handle = glfwGetCocoaWindow(window),
        .width = width,
        .height = height,
    };
    if (abi.goss_engine_init_renderer(engine, &renderer_desc) != .ok) return error.RendererInit;

    var current: std.Io.Writer.Allocating = .init(gpa);
    defer current.deinit();
    for (reference_lenses) |lens| {
        const hash = try checkDeterminism(gpa, engine, lens.name, lens.segmentation_model) orelse return 1;
        try current.writer.print("{s} {s}\n", .{ lens.name, hash });
    }

    if (print_mode) {
        var out_buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init_args.io, &out_buf);
        try stdout.interface.writeAll(current.writer.buffered());
        try stdout.interface.flush();
        return 0;
    }

    const baseline = std.Io.Dir.cwd().readFileAlloc(init_args.io, baseline_path, gpa, .limited(1 << 16)) catch |err| {
        std.debug.print("conformance: cannot read {s}: {t}\n", .{ baseline_path, err });
        return 1;
    };
    defer gpa.free(baseline);
    if (!std.mem.eql(u8, baseline, current.writer.buffered())) {
        std.debug.print(
            "conformance: output differs from {s}\n---- current ----\n{s}---- baseline ----\n{s}An intended change must update the baseline (zig build conformance -- --print > {s}).\n",
            .{ baseline_path, current.writer.buffered(), baseline, baseline_path },
        );
        return 1;
    }
    std.debug.print("conformance: PROOF all reference lenses match the pinned baseline\n", .{});

    // A focused run exercises one proof (or a small group) without the full
    // suite, so a single proof can be iterated at its own cost. It reads its
    // selector from zig-out/conf-only.txt; absent that file the suite runs.
    if (std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conf-only.txt", gpa, .limited(64)) catch null) |raw| {
        defer gpa.free(raw);
        const only = std.mem.trim(u8, raw, " \n\r\t");
        if (std.mem.eql(u8, only, "gpu-forces")) {
            if (!try proveGpuParticles(gpa, engine)) return 1;
            if (!try proveGpuForces(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "2d-world")) {
            if (!try provePhysics2dWorld(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "world-mesh")) {
            if (!try provePhysicsWorldMesh(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "glb-collider")) {
            if (!try provePhysicsGlbCollider(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "grab-throw")) {
            if (!try proveGrabThrow(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "sph-fluid")) {
            if (!try proveSphFluid(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "dof")) {
            if (!try proveDofPass(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "head-collider")) {
            if (!try proveHeadCollider(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "live-collider")) {
            if (!try proveLiveCollider(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "mesh-instancing")) {
            if (!try proveMeshInstancing(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "rich-text")) {
            if (!try proveRichText(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "extruded-text")) {
            if (!try proveExtrudedText(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "video-texture")) {
            if (!try proveVideoTexture(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "class-outline")) {
            if (!try proveClassOutline(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "head-matte")) {
            if (!try proveHeadMatte(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "head-occluder")) {
            if (!try proveHeadOccluder(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "hand-matte")) {
            if (!try proveHandMatte(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "lips-matte")) {
            if (!try proveLipsMatte(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "eyes-matte")) {
            if (!try proveEyesMatte(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "brows-matte")) {
            if (!try proveBrowsMatte(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "tint")) {
            if (!try proveTint(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "makeup")) {
            if (!try proveMakeup(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "iris")) {
            if (!try proveIris(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "foundation")) {
            if (!try proveFoundation(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "paint-face")) {
            if (!try proveFaceMaterial(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "face-swap")) {
            if (!try proveFaceSwap(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "glam")) {
            if (!try proveGlam(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "contour-highlight")) {
            if (!try proveContourHighlight(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "eye-makeup")) {
            if (!try proveEyeMakeup(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "lash-mesh")) {
            if (!try proveLashMesh(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "makeup-finish")) {
            if (!try proveMakeupFinish(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "depth-matting")) {
            if (!try proveDepthMatting(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "smooth")) {
            if (!try proveSmooth(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "retouch-breadth")) {
            if (!try proveRetouchBreadth(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "matte-refine")) {
            if (!try proveMatteRefine(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "hair-matte")) {
            if (!try proveHairMatte(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "scene-classes")) {
            if (!try proveSceneClasses(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "teeth")) {
            if (!try proveTeeth(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "sharpen")) {
            if (!try proveSharpen(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "user-media-seg")) {
            if (!try proveUserMediaSeg(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "makeup-transfer")) {
            if (!try proveMakeupTransfer(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "foundation-shade-match")) {
            if (!try proveFoundationShadeMatch(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "color-adjust")) {
            if (!try proveColorAdjust(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "stylize")) {
            if (!try proveStylize(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "edge")) {
            if (!try proveEdge(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "warp")) {
            if (!try proveWarp(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "liquify-symmetry")) {
            if (!try proveLiquifySymmetry(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "body-reshape")) {
            if (!try proveBodyReshape(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "reshape")) {
            if (!try proveReshapeBank(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "face-transform")) {
            if (!try proveFaceTransform(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "material-ops")) {
            if (!try proveMaterialOps(gpa, engine)) return 1;
        } else if (std.mem.eql(u8, only, "second-lifecycle")) {
            if (!try proveSecondLifecycle(gpa, engine, &frame_counter)) return 1;
        } else if (std.mem.eql(u8, only, "per-frame-alloc")) {
            if (!try provePerFrameAllocCalls(gpa, engine, &frame_counter)) return 1;
        } else if (std.mem.eql(u8, only, "hostile-manifest")) {
            if (!try proveHostileManifest(gpa, engine)) return 1;
        } else {
            std.debug.print("conformance: unknown conf-only selector {s}\n", .{only});
            return 1;
        }
        std.debug.print("conformance: focused run {s} complete\n", .{only});
        return 0;
    }

    if (!try proveTriggerAnimFires(gpa, engine)) return 1;
    watchHold("trigger anim fires");
    if (!try proveMixerBlend(gpa, engine)) return 1;
    watchHold("anim mixer blend");
    if (!try proveMorphBlend(gpa, engine)) return 1;
    watchHold("morph blend");
    if (!try proveHeadReenact(gpa, engine)) return 1;
    watchHold("head reenact");
    if (!try proveStylizedAvatar(gpa, engine)) return 1;
    watchHold("stylized avatar");
    if (!try proveSpriteDraw(gpa, engine)) return 1;
    watchHold("sprite overlay");
    if (!try proveTextDraw(gpa, engine)) return 1;
    watchHold("text overlay");
    if (!try proveMaterialClip(gpa, engine)) return 1;
    watchHold("material clip");
    if (!try proveSpriteFade(gpa, engine)) return 1;
    watchHold("sprite fade");
    if (!try proveSpriteAnim(gpa, engine)) return 1;
    watchHold("sprite anim");
    if (!try proveDofPass(gpa, engine)) return 1;
    watchHold("dof pass");
    if (!try proveFogPass(gpa, engine)) return 1;
    watchHold("fog pass");
    if (!try proveOutlinePass(gpa, engine)) return 1;
    watchHold("outline pass");
    if (!try proveTrailPass(gpa, engine)) return 1;
    watchHold("trail pass");
    if (!try proveSsrPass(gpa, engine)) return 1;
    watchHold("ssr pass");
    if (!try proveEnvPass(gpa, engine)) return 1;
    watchHold("env pass");
    if (!try proveEnvmapPass(gpa, engine)) return 1;
    watchHold("env map");
    if (!try proveGifSprite(gpa, engine)) return 1;
    watchHold("gif sprite");
    if (!try provePhotoCapture(gpa, engine)) return 1;
    watchHold("photo capture");
    if (!try proveMaskDegradation(gpa, engine)) return 1;
    watchHold("mask degradation");
    if (!try proveMaterialGraph(gpa, engine)) return 1;
    watchHold("material graph");
    if (!try proveMaterialOps(gpa, engine)) return 1;
    watchHold("material ops");
    if (!try proveSceneSegmentation(gpa, engine)) return 1;
    watchHold("scene segmentation");
    if (!try proveClassOutline(gpa, engine)) return 1;
    watchHold("class outline");
    if (!try proveHeadMatte(gpa, engine)) return 1;
    watchHold("head matte");
    if (!try proveHeadOccluder(gpa, engine)) return 1;
    watchHold("head occluder");
    if (!try proveHandMatte(gpa, engine)) return 1;
    watchHold("hand matte");
    if (!try proveLipsMatte(gpa, engine)) return 1;
    watchHold("lips matte");
    if (!try proveEyesMatte(gpa, engine)) return 1;
    watchHold("eyes matte");
    if (!try proveBrowsMatte(gpa, engine)) return 1;
    watchHold("brows matte");
    if (!try proveTint(gpa, engine)) return 1;
    watchHold("tint pass");
    if (!try proveMakeup(gpa, engine)) return 1;
    watchHold("makeup lenses");
    if (!try proveIris(gpa, engine)) return 1;
    watchHold("iris tint");
    if (!try proveFoundation(gpa, engine)) return 1;
    watchHold("foundation");
    if (!try proveFaceMaterial(gpa, engine)) return 1;
    watchHold("paint.face");
    if (!try proveFaceSwap(gpa, engine)) return 1;
    watchHold("face.swap");
    if (!try proveGlam(gpa, engine)) return 1;
    watchHold("glam look");
    if (!try proveContourHighlight(gpa, engine)) return 1;
    watchHold("contour highlight");
    if (!try proveEyeMakeup(gpa, engine)) return 1;
    watchHold("eye makeup");
    if (!try proveLashMesh(gpa, engine)) return 1;
    watchHold("lash mesh");
    if (!try proveMakeupFinish(gpa, engine)) return 1;
    watchHold("makeup finish");
    if (!try proveDepthMatting(gpa, engine)) return 1;
    watchHold("depth matting");
    if (!try proveSmooth(gpa, engine)) return 1;
    watchHold("face smooth");
    if (!try proveRetouchBreadth(gpa, engine)) return 1;
    watchHold("retouch breadth");
    if (!try proveMatteRefine(gpa, engine)) return 1;
    watchHold("matte refine");
    if (!try proveHairMatte(gpa, engine)) return 1;
    watchHold("hair matte");
    if (!try proveSceneClasses(gpa, engine)) return 1;
    watchHold("scene classes");
    if (!try proveTeeth(gpa, engine)) return 1;
    watchHold("teeth whiten");
    if (!try proveSharpen(gpa, engine)) return 1;
    watchHold("detail sharpen");
    if (!try proveUserMediaSeg(gpa, engine)) return 1;
    watchHold("user-media segmentation");
    if (!try proveMakeupTransfer(gpa, engine)) return 1;
    watchHold("makeup transfer");
    if (!try proveFoundationShadeMatch(gpa, engine)) return 1;
    watchHold("foundation shade match");
    if (!try proveVideoRecording(gpa, engine)) return 1;
    watchHold("video recording");
    if (!try provePlatformPhotos(gpa, engine)) return 1;
    watchHold("platform photos");
    if (!try proveWorldAnchor(gpa, engine)) return 1;
    watchHold("world anchor");
    if (!try proveMultiFaceFanOut(gpa, engine)) return 1;
    watchHold("multi face fan out");
    if (!try proveMultiBodyFanOut(gpa, engine)) return 1;
    watchHold("multi body fan out");
    if (!try proveSkeletonRig(gpa, engine)) return 1;
    watchHold("skeleton rig");
    if (!try proveSkinnedBodyMesh(gpa, engine)) return 1;
    watchHold("skinned body mesh");
    if (!try proveDepthOcclusion(gpa, engine)) return 1;
    watchHold("depth occlusion");
    if (!try proveParallax(gpa, engine)) return 1;
    watchHold("parallax pass");
    if (!try proveMonoDepth(gpa, engine)) return 1;
    watchHold("mono depth");
    if (!try proveFaceRegions(gpa, engine)) return 1;
    watchHold("face regions");
    if (!try proveBodyJoints(gpa, engine)) return 1;
    watchHold("body joints");
    if (!try proveHandJoints(gpa, engine)) return 1;
    watchHold("hand joints");
    if (!try provePhysicsDrop(gpa, engine)) return 1;
    watchHold("physics drop");
    if (!try provePhysicsChain(gpa, engine)) return 1;
    watchHold("physics chain");
    if (!try provePhysicsPivot(gpa, engine)) return 1;
    watchHold("physics pivot");
    if (!try provePhysicsFixed(gpa, engine)) return 1;
    watchHold("physics fixed");
    if (!try provePhysicsHinge(gpa, engine)) return 1;
    watchHold("physics hinge");
    if (!try provePhysicsSpring(gpa, engine)) return 1;
    watchHold("physics spring");
    if (!try provePhysicsShapeCylinder(gpa, engine)) return 1;
    watchHold("physics shape cylinder");
    if (!try provePhysicsShapeCapsule(gpa, engine)) return 1;
    watchHold("physics shape capsule");
    if (!try provePhysicsJiggle(gpa, engine)) return 1;
    watchHold("physics jiggle");
    if (!try provePhysicsFriction(gpa, engine)) return 1;
    watchHold("physics friction");
    if (!try provePhysicsHull(gpa, engine)) return 1;
    watchHold("physics hull");
    if (!try provePhysicsRestitution(gpa, engine)) return 1;
    watchHold("physics restitution");
    if (!try provePhysicsMesh(gpa, engine)) return 1;
    watchHold("physics mesh");
    if (!try provePhysicsBalloon(gpa, engine)) return 1;
    watchHold("physics balloon");
    if (!try provePhysicsSoftBody(gpa, engine)) return 1;
    watchHold("physics soft body");
    if (!try provePhysicsPlanar(gpa, engine)) return 1;
    watchHold("physics planar");
    if (!try provePhysics2dWorld(gpa, engine)) return 1;
    watchHold("physics 2d world");
    if (!try provePhysicsWorldMesh(gpa, engine)) return 1;
    watchHold("physics world mesh");
    if (!try provePhysicsGlbCollider(gpa, engine)) return 1;
    watchHold("physics glb collider");
    if (!try proveGrabThrow(gpa, engine)) return 1;
    watchHold("grab throw");
    if (!try proveSphFluid(gpa, engine)) return 1;
    watchHold("sph fluid");
    if (!try proveHeadCollider(gpa, engine)) return 1;
    watchHold("head collider");
    if (!try proveLiveCollider(gpa, engine)) return 1;
    watchHold("live collider");
    if (!try proveMeshInstancing(gpa, engine)) return 1;
    watchHold("mesh instancing");
    if (!try proveRichText(gpa, engine)) return 1;
    watchHold("rich text");
    if (!try proveExtrudedText(gpa, engine)) return 1;
    watchHold("extruded text");
    if (!try proveVideoTexture(gpa, engine)) return 1;
    watchHold("video texture");
    if (!try proveClothFlag(gpa, engine)) return 1;
    watchHold("cloth flag");
    if (!try proveParticles(gpa, engine)) return 1;
    watchHold("particles");
    if (!try proveHairSim(gpa, engine)) return 1;
    watchHold("hair sim");
    if (!try proveHighResCapture(gpa, engine)) return 1;
    watchHold("high res capture");
    if (!try proveTiledCapture(gpa, engine)) return 1;
    watchHold("tiled capture");
    if (!try prove3DTiledCapture(gpa, engine)) return 1;
    watchHold("d tiled capture");
    if (!try proveColorManagedCapture(gpa, engine)) return 1;
    watchHold("color managed capture");
    if (!try proveMlInfer(gpa, engine)) return 1;
    watchHold("ml infer");
    if (!try proveAudioInfer(gpa, engine)) return 1;
    watchHold("audio infer");
    if (!try proveCaption(gpa, engine)) return 1;
    watchHold("audio caption");
    if (!try proveDiarize(gpa, engine)) return 1;
    watchHold("audio diarize");
    if (!try proveTranslate(gpa, engine)) return 1;
    watchHold("audio translate");
    if (!try proveDub(gpa, engine)) return 1;
    watchHold("audio dub");
    if (!try proveMlInferOnnx(gpa, engine)) return 1;
    watchHold("ml infer onnx");
    if (!try proveMlInferSegMask(gpa, engine)) return 1;
    watchHold("ml infer seg mask");
    if (!try proveMlInferCls(gpa, engine)) return 1;
    watchHold("ml infer cls");
    if (!try proveMlInferPlacement(gpa, engine)) return 1;
    watchHold("ml infer placement");
    if (!try proveMlInferStyle(gpa, engine)) return 1;
    watchHold("ml infer style");
    if (!try proveMlInferSuperRes(gpa, engine)) return 1;
    watchHold("ml infer super-res");
    if (!try proveMlInferAux(gpa, engine)) return 1;
    watchHold("ml infer aux reference");
    if (!try proveMlInferTemporal(gpa, engine)) return 1;
    watchHold("ml infer temporal");
    if (!try proveMlInferDiffusion(gpa, engine)) return 1;
    watchHold("ml infer diffusion");
    if (!try proveMlInferText2Img(gpa, engine)) return 1;
    watchHold("ml infer text2img");
    if (!try proveMlInferGreenscreen(gpa, engine)) return 1;
    watchHold("ml infer greenscreen");
    if (!try proveMlInferCoherence(gpa, engine)) return 1;
    watchHold("ml infer coherence");
    if (!try proveMlInferFaceRestyle(gpa, engine)) return 1;
    watchHold("ml infer face restyle");
    if (!try proveMaskStrength(gpa, engine)) return 1;
    watchHold("mask strength");
    if (!try proveMaskedGrade(gpa, engine)) return 1;
    watchHold("masked grade");
    if (!try proveDehaze(gpa, engine)) return 1;
    watchHold("dehaze pass");
    if (!try proveRelight(gpa, engine)) return 1;
    watchHold("relight pass");
    if (!try proveGlare(gpa, engine)) return 1;
    watchHold("glare pass");
    if (!try proveVignette(gpa, engine)) return 1;
    watchHold("vignette pass");
    if (!try proveLowLight(gpa, engine)) return 1;
    watchHold("lowlight pass");
    if (!try proveUndistort(gpa, engine)) return 1;
    watchHold("undistort pass");
    if (!try proveAwb(gpa, engine)) return 1;
    watchHold("awb pass");
    if (!try proveInferenceBudget(gpa, engine)) return 1;
    watchHold("inference budget");
    if (!try proveStabilize(gpa, engine)) return 1;
    watchHold("stabilize pass");
    if (!try proveZoom(gpa, engine)) return 1;
    watchHold("zoom pass");
    if (!try proveDereflect(gpa, engine)) return 1;
    watchHold("dereflect pass");
    if (!try proveHarmonize(gpa, engine)) return 1;
    watchHold("harmonize pass");
    if (!try proveInpaint(gpa, engine)) return 1;
    watchHold("inpaint pass");
    if (!try proveRolling(gpa, engine)) return 1;
    watchHold("rolling pass");
    if (!try proveRollLock(gpa, engine)) return 1;
    watchHold("roll_lock warp");
    if (!try proveGazeCorrect(gpa, engine)) return 1;
    watchHold("gaze_correct warp");
    if (!try proveAutoFrame(gpa, engine)) return 1;
    watchHold("auto_frame warp");
    if (!try proveTemporalFuse(gpa, engine)) return 1;
    watchHold("temporal.fuse");
    if (!try proveTemporalInterpolate(gpa, engine)) return 1;
    watchHold("temporal interpolate");
    if (!try proveTemporalHdr(gpa, engine)) return 1;
    watchHold("temporal hdr");
    if (!try proveAudioDenoise(gpa, engine)) return 1;
    watchHold("audio enhance");
    if (!try proveVoiceTransform(gpa, engine)) return 1;
    watchHold("voice transform");
    if (!try proveCaptionSegment(gpa, engine)) return 1;
    watchHold("caption segment");
    if (!try proveMlInferMaterial(gpa, engine)) return 1;
    watchHold("ml infer material");
    if (!try proveMlInferMaterialGraph(gpa, engine)) return 1;
    watchHold("ml infer material graph");
    if (!try proveMlInferSplat(gpa, engine)) return 1;
    watchHold("ml infer splat");
    if (!try proveMlInferSplatMesh(gpa, engine)) return 1;
    watchHold("ml infer splat mesh");
    if (!try proveMlInferSplatColored(gpa, engine)) return 1;
    watchHold("ml infer splat colored");
    if (!try proveSplatGaussian(gpa, engine)) return 1;
    watchHold("splat gaussian");
    if (!try proveSplatPortal(gpa, engine)) return 1;
    watchHold("splat portal");
    if (!try proveSplatBackground(gpa, engine)) return 1;
    watchHold("splat background");
    if (!try proveCaptureReconstruct(gpa, engine)) return 1;
    watchHold("capture reconstruct");
    if (!try proveReconstructionRender(gpa, engine)) return 1;
    watchHold("reconstruction render");
    if (!try proveMlInferSelfieAvatar(gpa, engine)) return 1;
    watchHold("ml infer selfie avatar");
    if (!try proveCompilePrompt(gpa, engine)) return 1;
    watchHold("compile prompt");
    if (!try proveScript(gpa, engine)) return 1;
    watchHold("script");
    if (!try proveScriptFile(gpa, engine)) return 1;
    watchHold("script-file");
    if (!try proveLogicGraphMath(gpa, engine)) return 1;
    watchHold("logic-math");
    if (!try proveScriptState(gpa, engine)) return 1;
    watchHold("script-state");
    if (!try proveLocomotion(gpa, engine)) return 1;
    watchHold("locomotion");
    if (!try proveHdrComposite(gpa, engine)) return 1;
    watchHold("hdr-composite");
    if (!try proveDirectionalLight(gpa, engine)) return 1;
    watchHold("directional-light");
    if (!try proveAudio(gpa, engine)) return 1;
    watchHold("audio");
    if (!try proveOutputMix(gpa, engine)) return 1;
    watchHold("output mix");
    if (!try proveCameraControls(gpa, engine)) return 1;
    watchHold("camera controls");
    if (!try proveEventTrigger(gpa, engine)) return 1;
    watchHold("event trigger");
    if (!try proveShowHideSwap(gpa, engine)) return 1;
    watchHold("show hide swap");
    if (!try proveVolumeTrigger(gpa, engine)) return 1;
    watchHold("volume trigger");
    if (!try proveLayoutComposite(gpa, engine)) return 1;
    watchHold("layout composite");
    if (!try proveCompositeOpacity(gpa, engine)) return 1;
    watchHold("composite opacity");
    if (!try proveGeofilter(gpa, engine)) return 1;
    watchHold("geofilter");
    if (!try proveBrushStroke(gpa, engine)) return 1;
    watchHold("brush stroke");
    if (!try proveBlur(gpa, engine)) return 1;
    watchHold("blur");
    if (!try proveGrade(gpa, engine)) return 1;
    watchHold("grade");
    if (!try proveColorAdjust(gpa, engine)) return 1;
    watchHold("color adjust");
    if (!try proveBloom(gpa, engine)) return 1;
    watchHold("bloom");
    if (!try proveStackedPostEffects(gpa, engine)) return 1;
    watchHold("stacked post effects");
    if (!try proveStylize(gpa, engine)) return 1;
    watchHold("stylize");
    if (!try proveEdge(gpa, engine)) return 1;
    watchHold("edge");
    if (!try proveWarp(gpa, engine)) return 1;
    watchHold("warp");
    if (!try proveLiquifySymmetry(gpa, engine)) return 1;
    watchHold("liquify symmetry");
    if (!try proveBodyReshape(gpa, engine)) return 1;
    watchHold("body reshape");
    if (!try proveReshapeBank(gpa, engine)) return 1;
    watchHold("reshape bank");
    if (!try proveFaceTransform(gpa, engine)) return 1;
    watchHold("face transform");
    if (!try proveExpressionScript(gpa, engine)) return 1;
    watchHold("expression script");
    if (!try proveEmber(gpa, engine)) return 1;
    watchHold("ember");
    if (!try proveStarSprite(gpa, engine)) return 1;
    watchHold("star sprite");
    if (!try proveParticlePatterns(gpa, engine)) return 1;
    watchHold("particle patterns");
    if (!try proveParticleTrail(gpa, engine)) return 1;
    watchHold("particle trail");
    if (!try provePresetLibrary(gpa, engine)) return 1;
    watchHold("preset library");
    if (!try proveSubEmitter(gpa, engine)) return 1;
    watchHold("sub emitter");
    if (!try proveGpuParticles(gpa, engine)) return 1;
    watchHold("gpu particles");
    if (!try proveGpuForces(gpa, engine)) return 1;
    watchHold("gpu forces");
    if (!try proveParticleCollider(gpa, engine)) return 1;
    watchHold("particle collider");
    if (!try proveMeshParticles(gpa, engine)) return 1;
    watchHold("mesh particles");
    if (!try proveRibbon(gpa, engine)) return 1;
    watchHold("particle ribbon");
    if (!try proveFaceSparkle(gpa, engine)) return 1;
    watchHold("face sparkle");
    if (!try proveJsonPostEffect(gpa, engine)) return 1;
    watchHold("json post effect");
    if (!try proveJsonParticles(gpa, engine)) return 1;
    watchHold("json particles");
    if (!try proveFullStack(gpa, engine)) return 1;
    watchHold("full stack");
    if (!try proveTiledPostEffect(gpa, engine)) return 1;
    watchHold("tiled post effect");
    if (!try proveHostileManifest(gpa, engine)) return 1;
    watchHold("hostile manifest");
    if (!try proveNoLeaks(gpa, engine, &frame_counter)) return 1;
    watchHold("no leaks");
    if (!try provePerFrameBudget(gpa, engine, &frame_counter)) return 1;
    watchHold("per frame budget");
    if (!try provePerFrameAllocCalls(gpa, engine, &frame_counter)) return 1;
    watchHold("per frame alloc calls");
    if (!try provePeakBoundedCapture(gpa, engine, &frame_counter)) return 1;
    watchHold("peak bounded capture");
    if (!try proveSecondLifecycle(gpa, engine, &frame_counter)) return 1;
    watchHold("second lifecycle");
    return 0;
}
