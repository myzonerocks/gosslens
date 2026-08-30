//! The Android binding: JNI exports over the goss_ ABI, written in Zig and
//! compiled into the same shared library as the core, so one build system
//! produces the whole .so. The layer holds no logic beyond marshalling;
//! JNIEnv is touched only for the two capabilities Java cannot hand over as
//! plain values: resolving a Surface to its native window and reading a
//! direct buffer address.

const std = @import("std");
const abi = @import("abi");

const JniEnv = opaque {};
const jobject = ?*anyopaque;

extern fn ANativeWindow_fromSurface(env: *JniEnv, surface: jobject) ?*anyopaque;
extern fn AHardwareBuffer_fromHardwareBuffer(env: *JniEnv, hardware_buffer: jobject) ?*anyopaque;
extern fn ANativeWindow_release(window: ?*anyopaque) void;

// JNIEnv points at a pointer to the JNI function table. Only one entry is
// used: GetDirectBufferAddress, index 230 in the JNI specification.
fn getDirectBufferAddress(env: *JniEnv, buffer: jobject) ?[*]u8 {
    const table: *align(1) const [*]const ?*const anyopaque = @ptrCast(env);
    const entry = table.*[230] orelse return null;
    const call: *const fn (*JniEnv, jobject) callconv(.c) ?[*]u8 = @ptrCast(@alignCast(entry));
    return call(env, buffer);
}

export fn Java_com_gosslens_Gosslens_nativeAbiVersion(env: *JniEnv, cls: jobject) i32 {
    _ = env;
    _ = cls;
    return @bitCast(abi.goss_abi_version());
}

export fn Java_com_gosslens_Gosslens_nativeEngineCreate(env: *JniEnv, cls: jobject, texture_pool_capacity: i32, staging_pool_capacity: i32) i64 {
    _ = env;
    _ = cls;
    // Negative capacities mean no config was given; the core's own
    // defaults apply, the same as passing null from C.
    var config: abi.EngineConfig = undefined;
    var config_ptr: ?*const abi.EngineConfig = null;
    if (texture_pool_capacity >= 0 and staging_pool_capacity >= 0) {
        config = .{ .texture_pool_capacity = @intCast(texture_pool_capacity), .staging_pool_capacity = @intCast(staging_pool_capacity) };
        config_ptr = &config;
    }
    var engine: ?*abi.Engine = null;
    if (abi.goss_engine_create(config_ptr, @ptrCast(&engine)) != .ok) return 0;
    return @bitCast(@as(u64, @intFromPtr(engine.?)));
}

export fn Java_com_gosslens_Gosslens_nativeEngineDestroy(env: *JniEnv, cls: jobject, engine: i64) void {
    _ = env;
    _ = cls;
    const e = engineFromHandle(engine) orelse return;
    // The window reference outlives the renderer teardown inside destroy,
    // then this engine's own reference is dropped - never another's.
    const window = e.attached_window;
    e.attached_window = null;
    abi.goss_engine_destroy(e);
    if (window) |w| ANativeWindow_release(w);
}

fn engineFromHandle(handle: i64) ?*abi.Engine {
    if (handle == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(handle)));
}

fn sessionFromHandle(handle: i64) ?*abi.Session {
    if (handle == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(handle)));
}

export fn Java_com_gosslens_Gosslens_nativeInitRenderer(env: *JniEnv, cls: jobject, engine: i64, surface: jobject, width: i32, height: i32) i32 {
    _ = cls;
    const e = engineFromHandle(engine) orelse return @intFromEnum(abi.Status.invalid_argument);
    // Mirror the core's re-init refusal before touching window references:
    // a live renderer keeps using the window already attached, so that
    // reference must not be released or replaced on a refused call.
    if (e.renderer != null) return @intFromEnum(abi.Status.invalid_argument);
    const window = ANativeWindow_fromSurface(env, surface) orelse return @intFromEnum(abi.Status.invalid_argument);
    // fromSurface takes a reference each call; the one held for a prior
    // surface goes back before the new one lands in its slot.
    if (e.attached_window) |previous| ANativeWindow_release(previous);
    e.attached_window = window;
    var desc: abi.RendererDesc = .{
        .native_window_handle = window,
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
    };
    const status = abi.goss_engine_init_renderer(e, &desc);
    if (status != .ok) {
        // A failed init leaves no renderer holding the window; the
        // reference goes back rather than waiting for engine destroy.
        e.attached_window = null;
        ANativeWindow_release(window);
    }
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeResize(env: *JniEnv, cls: jobject, engine: i64, width: i32, height: i32) void {
    _ = env;
    _ = cls;
    abi.goss_engine_resize(engineFromHandle(engine), @intCast(@max(width, 0)), @intCast(@max(height, 0)));
}

export fn Java_com_gosslens_Gosslens_nativeRequestScreenshot(env: *JniEnv, cls: jobject, engine: i64, path_buffer: jobject, path_len: i32) i32 {
    _ = cls;
    const path = getDirectBufferAddress(env, path_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_engine_request_screenshot(engineFromHandle(engine), path, @intCast(@max(path_len, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeRenderFrame(env: *JniEnv, cls: jobject, engine: i64, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_engine_render_frame(engineFromHandle(engine), sessionFromHandle(session)));
}

/// Compiles a prompt into a GLF manifest: pass a null out buffer (or zero
/// capacity) to write the length into len_buffer and probe, then again with a
/// buffer that fits. len_buffer is eight bytes holding the size_t out length.
export fn Java_com_gosslens_Gosslens_nativeCompilePrompt(env: *JniEnv, cls: jobject, engine: i64, prompt_buffer: jobject, prompt_len: i32, out_buffer: jobject, out_capacity: i64, len_buffer: jobject) i32 {
    _ = cls;
    const prompt = getDirectBufferAddress(env, prompt_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const len_bytes = getDirectBufferAddress(env, len_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out_len: *align(1) u64 = @ptrCast(len_bytes);
    const out: ?[*]u8 = getDirectBufferAddress(env, out_buffer);
    var written: usize = 0;
    const status = abi.goss_compile_prompt(engineFromHandle(engine), @ptrCast(prompt), @intCast(@max(prompt_len, 0)), out, @intCast(@max(out_capacity, 0)), &written);
    out_len.* = written;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeSetDubbing(env: *JniEnv, cls: jobject, session: i64, enabled: i32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_set_dubbing(sessionFromHandle(session), @intCast(@max(enabled, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeCaptionText(env: *JniEnv, cls: jobject, session: i64, node_id_buffer: jobject, node_id_len: i32, out_buffer: jobject, out_capacity: i64, len_buffer: jobject) i32 {
    _ = cls;
    const node_id = getDirectBufferAddress(env, node_id_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const len_bytes = getDirectBufferAddress(env, len_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out_len: *align(1) u64 = @ptrCast(len_bytes);
    const out: ?[*]u8 = getDirectBufferAddress(env, out_buffer);
    var written: usize = 0;
    const status = abi.goss_session_caption_text(sessionFromHandle(session), @ptrCast(node_id), @intCast(@max(node_id_len, 0)), out, @intCast(@max(out_capacity, 0)), &written);
    out_len.* = written;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeCaptionSegment(env: *JniEnv, cls: jobject, session: i64, index: i32, out_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var seg: abi.CaptionSegment = undefined;
    const status = abi.goss_session_caption_segment(sessionFromHandle(session), @intCast(@max(index, 0)), &seg);
    if (status == .ok) @memcpy(bytes[0..@sizeOf(abi.CaptionSegment)], std.mem.asBytes(&seg));
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeCaptionSegmentText(env: *JniEnv, cls: jobject, session: i64, index: i32, out_buffer: jobject, out_capacity: i64, len_buffer: jobject) i32 {
    _ = cls;
    const len_bytes = getDirectBufferAddress(env, len_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out_len: *align(1) u64 = @ptrCast(len_bytes);
    const out: ?[*]u8 = getDirectBufferAddress(env, out_buffer);
    var written: usize = 0;
    const status = abi.goss_session_caption_segment_text(sessionFromHandle(session), @intCast(@max(index, 0)), out, @intCast(@max(out_capacity, 0)), &written);
    out_len.* = written;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeSessionCreate(env: *JniEnv, cls: jobject, engine: i64, frame_budget_us: i32) i64 {
    _ = env;
    _ = cls;
    // Negative means no config was given; the core's default budget
    // applies, the same as passing null from C.
    var config: abi.SessionConfig = undefined;
    var config_ptr: ?*const abi.SessionConfig = null;
    if (frame_budget_us >= 0) {
        config = .{ .frame_budget_us = @intCast(frame_budget_us), .reserved = 0 };
        config_ptr = &config;
    }
    var session: ?*abi.Session = null;
    if (abi.goss_session_create(engineFromHandle(engine), config_ptr, @ptrCast(&session)) != .ok) return 0;
    return @bitCast(@as(u64, @intFromPtr(session.?)));
}

export fn Java_com_gosslens_Gosslens_nativeDegradeLevel(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return abi.goss_session_degrade_level(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeYuvToRgb(env: *JniEnv, cls: jobject, standard: i32, range: i32, out_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const matrix: *[16]f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_color_yuv_to_rgb(@intCast(@max(standard, 0)), @intCast(@max(range, 0)), matrix));
}

export fn Java_com_gosslens_Gosslens_nativeSolveTwoBoneIk(env: *JniEnv, cls: jobject, in_buffer: jobject, upper_len: f32, lower_len: f32, out_buffer: jobject) i32 {
    _ = cls;
    const in_bytes = getDirectBufferAddress(env, in_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out_bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const in_f: *[9]f32 = @ptrCast(@alignCast(in_bytes));
    const out_f: *[6]f32 = @ptrCast(@alignCast(out_bytes));
    return @intFromEnum(abi.goss_solve_two_bone_ik(in_f[0..3], upper_len, lower_len, in_f[3..6], in_f[6..9], out_f[0..3], out_f[3..6]));
}

export fn Java_com_gosslens_Gosslens_nativeActivateLensFromDirectory(env: *JniEnv, cls: jobject, session: i64, path_buffer: jobject, path_len: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, path_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_activate_lens_from_directory(sessionFromHandle(session), bytes, @intCast(@max(path_len, 0))));
}

/// Zero-copy submission: up to three platform texture handles arrive as plain
/// i64 values, packed into goss_frame_planes; the platform objects behind them
/// must outlive the next rendered frame.
export fn Java_com_gosslens_Gosslens_nativeSubmitFrame(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    plane0: i64,
    plane1: i64,
    plane2: i64,
    plane_count: i32,
    width: i32,
    height: i32,
    pixel_format: i32,
    flags: i32,
    color_standard: i32,
    color_range: i32,
    timestamp_us: i64,
) i32 {
    _ = env;
    _ = cls;
    var desc: abi.FrameDesc = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .pixel_format = @intCast(@max(pixel_format, 0)),
        .color_standard = @intCast(@max(color_standard, 0)),
        .color_range = @intCast(@max(color_range, 0)),
        .flags = @bitCast(flags),
        .timestamp_us = timestamp_us,
    };
    var planes: abi.FramePlanes = .{
        .plane_count = @intCast(@max(plane_count, 0)),
        .reserved = 0,
        .planes = .{ @bitCast(plane0), @bitCast(plane1), @bitCast(plane2) },
    };
    return @intFromEnum(abi.goss_session_submit_frame(sessionFromHandle(session), &desc, &planes));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitFrameRgbaCopy(env: *JniEnv, cls: jobject, session: i64, rgba_buffer: jobject, stride: i32, width: i32, height: i32, pixel_format: i32, flags: i32, timestamp_us: i64) i32 {
    _ = cls;
    const rgba = getDirectBufferAddress(env, rgba_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var desc: abi.FrameDesc = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .pixel_format = @intCast(@max(pixel_format, 0)),
        .color_standard = 0,
        .color_range = 1,
        .flags = @bitCast(flags),
        .timestamp_us = timestamp_us,
    };
    return @intFromEnum(abi.goss_session_submit_frame_rgba_copy(sessionFromHandle(session), &desc, rgba, @intCast(@max(stride, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeEnableSegmentation(env: *JniEnv, cls: jobject, session: i64, model_buffer: jobject, model_len: i32, threads: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, model_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_enable_segmentation(sessionFromHandle(session), bytes, @intCast(@max(model_len, 0)), threads));
}

/// digest_buffer is a direct byte buffer of the 32-byte SHA-256 digest.
export fn Java_com_gosslens_Gosslens_nativeAllowModelDigest(env: *JniEnv, cls: jobject, session: i64, digest_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, digest_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const digest: *const [32]u8 = @ptrCast(bytes);
    return @intFromEnum(abi.goss_session_allow_model_digest(sessionFromHandle(session), digest));
}

export fn Java_com_gosslens_Gosslens_nativeClearModelAllowlist(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_clear_model_allowlist(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeDisableSegmentation(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_disable_segmentation(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeSetFaceLandmarks(env: *JniEnv, cls: jobject, session: i64, points_buffer: jobject, point_count: i32) i32 {
    _ = cls;
    if (point_count == 0) return @intFromEnum(abi.goss_session_set_face_landmarks(sessionFromHandle(session), null, 0));
    const bytes = getDirectBufferAddress(env, points_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const points: [*]const f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_set_face_landmarks(sessionFromHandle(session), points, @intCast(@max(point_count, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSetBeautyLut(env: *JniEnv, cls: jobject, session: i64, slot: i32, rgba_buffer: jobject, width: i32, height: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, rgba_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const rgba: [*]const u8 = @ptrCast(bytes);
    return @intFromEnum(abi.goss_session_set_beauty_lut(sessionFromHandle(session), slot, rgba, @intCast(@max(width, 0)), @intCast(@max(height, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSetBeautyMakeupTexture(env: *JniEnv, cls: jobject, session: i64, effect: i32, rgba_buffer: jobject, width: i32, height: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, rgba_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const rgba: [*]const u8 = @ptrCast(bytes);
    return @intFromEnum(abi.goss_session_set_beauty_makeup_texture(sessionFromHandle(session), effect, rgba, @intCast(@max(width, 0)), @intCast(@max(height, 0))));
}

/// data_buffer receives width*height*4 RGBA8 (row 0 first); info_buffer
/// receives {width: u32, height: u32}, the renderer's real size. Debug/test.
export fn Java_com_gosslens_Gosslens_nativeCaptureFrame(env: *JniEnv, cls: jobject, engine: i64, session: i64, data_buffer: jobject, data_capacity: i64, info_buffer: jobject) i32 {
    _ = cls;
    const info_bytes = getDirectBufferAddress(env, info_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const info: *extern struct { width: u32, height: u32 } = @ptrCast(@alignCast(info_bytes));
    const data = getDirectBufferAddress(env, data_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var width: u32 = 0;
    var height: u32 = 0;
    const status = abi.goss_engine_capture_frame(engineFromHandle(engine), sessionFromHandle(session), @ptrCast(data), @intCast(@max(data_capacity, 0)), &width, &height);
    info.width = width;
    info.height = height;
    return @intFromEnum(status);
}

/// info_buffer receives {encoded_len: u64, width: u32, height: u32}; a
/// too-small data buffer still fills it for the caller to retry with the
/// exact size, the same probe contract nativeCapturePhoto follows.
export fn Java_com_gosslens_Gosslens_nativeCapturePhotoAs(env: *JniEnv, cls: jobject, engine: i64, session: i64, format: i32, quality: i32, data_buffer: jobject, data_capacity: i64, info_buffer: jobject) i32 {
    _ = cls;
    const info_bytes = getDirectBufferAddress(env, info_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const info: *extern struct { encoded_len: u64, width: u32, height: u32 } = @ptrCast(@alignCast(info_bytes));
    const data = getDirectBufferAddress(env, data_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var encoded_len: usize = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    const status = abi.goss_engine_capture_photo_as(engineFromHandle(engine), sessionFromHandle(session), @intCast(@max(format, 0)), @intCast(@max(quality, 0)), @ptrCast(data), @intCast(@max(data_capacity, 0)), &encoded_len, &width, &height);
    info.encoded_len = encoded_len;
    info.width = width;
    info.height = height;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeRenderToLiveTexture(env: *JniEnv, cls: jobject, engine: i64, session: i64, native_handle: i64, width: i32, height: i32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_engine_render_to_live_texture(engineFromHandle(engine), sessionFromHandle(session), @bitCast(native_handle), @intCast(@max(width, 0)), @intCast(@max(height, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeReleaseLiveTexture(env: *JniEnv, cls: jobject, engine: i64, native_handle: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_engine_release_live_texture(engineFromHandle(engine), @bitCast(native_handle)));
}

export fn Java_com_gosslens_Gosslens_nativePhysicsHairRemove(env: *JniEnv, cls: jobject, session: i64, hair_id: i32) i32 {
    _ = env;
    _ = cls;
    if (hair_id < 0) return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_physics_hair_remove(sessionFromHandle(session), @intCast(hair_id)));
}

export fn Java_com_gosslens_Gosslens_nativeSessionDestroy(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_destroy(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitFrameCopy(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    y_buffer: jobject,
    y_stride: i32,
    uv_buffer: jobject,
    uv_stride: i32,
    width: i32,
    height: i32,
    flags: i32,
    color_standard: i32,
    color_range: i32,
    timestamp_us: i64,
) i32 {
    _ = cls;
    const y = getDirectBufferAddress(env, y_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const uv = getDirectBufferAddress(env, uv_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var desc: abi.FrameDesc = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .pixel_format = 0,
        .color_standard = @intCast(@max(color_standard, 0)),
        .color_range = @intCast(@max(color_range, 0)),
        .flags = @bitCast(flags),
        .timestamp_us = timestamp_us,
    };
    return @intFromEnum(abi.goss_session_submit_frame_copy(sessionFromHandle(session), &desc, y, @intCast(@max(y_stride, 0)), uv, @intCast(@max(uv_stride, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitFrameBracket(env: *JniEnv, cls: jobject, session: i64, y_buffer: jobject, y_stride: i32, uv_buffer: jobject, uv_stride: i32, width: i32, height: i32, color_standard: i32, color_range: i32, timestamp_us: i64) i32 {
    _ = cls;
    const y = getDirectBufferAddress(env, y_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const uv = getDirectBufferAddress(env, uv_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var desc: abi.FrameDesc = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .pixel_format = 0,
        .color_standard = @intCast(@max(color_standard, 0)),
        .color_range = @intCast(@max(color_range, 0)),
        .flags = 0,
        .timestamp_us = timestamp_us,
    };
    return @intFromEnum(abi.goss_session_submit_frame_bracket(sessionFromHandle(session), &desc, y, @intCast(@max(y_stride, 0)), uv, @intCast(@max(uv_stride, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitFrameBracketRgba(env: *JniEnv, cls: jobject, session: i64, rgba_buffer: jobject, width: i32, height: i32) i32 {
    _ = cls;
    const rgba = getDirectBufferAddress(env, rgba_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_submit_frame_bracket_rgba(sessionFromHandle(session), rgba, @intCast(@max(width, 0)), @intCast(@max(height, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitHardwareBuffer(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    hardware_buffer: jobject,
    width: i32,
    height: i32,
    flags: i32,
    color_standard: i32,
    color_range: i32,
    timestamp_us: i64,
) i32 {
    _ = cls;
    const buffer = AHardwareBuffer_fromHardwareBuffer(env, hardware_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var desc: abi.FrameDesc = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .pixel_format = 0,
        .color_standard = @intCast(@max(color_standard, 0)),
        .color_range = @intCast(@max(color_range, 0)),
        .flags = @bitCast(flags),
        .timestamp_us = timestamp_us,
    };
    return @intFromEnum(abi.goss_session_submit_hardware_buffer(sessionFromHandle(session), &desc, buffer));
}

export fn Java_com_gosslens_Gosslens_nativeEnableFaceTracking(env: *JniEnv, cls: jobject, session: i64, task_buffer: jobject, task_len: i32, threads: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, task_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_enable_face_tracking(sessionFromHandle(session), bytes, @intCast(@max(task_len, 0)), threads));
}

export fn Java_com_gosslens_Gosslens_nativeDisableFaceTracking(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_disable_face_tracking(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeTrackFrame(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    y_buffer: jobject,
    y_stride: i32,
    uv_buffer: jobject,
    uv_stride: i32,
    width: i32,
    height: i32,
    color_standard: i32,
    color_range: i32,
    timestamp_us: i64,
) i32 {
    _ = cls;
    const y = getDirectBufferAddress(env, y_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const uv = getDirectBufferAddress(env, uv_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var desc: abi.FrameDesc = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .pixel_format = 0,
        .color_standard = @intCast(@max(color_standard, 0)),
        .color_range = @intCast(@max(color_range, 0)),
        .flags = 0,
        .timestamp_us = timestamp_us,
    };
    return @intFromEnum(abi.goss_session_track_frame(sessionFromHandle(session), &desc, y, @intCast(@max(y_stride, 0)), uv, @intCast(@max(uv_stride, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitAvatarSource(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    y_buffer: jobject,
    y_stride: i32,
    uv_buffer: jobject,
    uv_stride: i32,
    width: i32,
    height: i32,
    color_standard: i32,
    color_range: i32,
    timestamp_us: i64,
) i32 {
    _ = cls;
    const y = getDirectBufferAddress(env, y_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const uv = getDirectBufferAddress(env, uv_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var desc: abi.FrameDesc = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .pixel_format = 0,
        .color_standard = @intCast(@max(color_standard, 0)),
        .color_range = @intCast(@max(color_range, 0)),
        .flags = 0,
        .timestamp_us = timestamp_us,
    };
    return @intFromEnum(abi.goss_session_submit_avatar_source(sessionFromHandle(session), &desc, y, @intCast(@max(y_stride, 0)), uv, @intCast(@max(uv_stride, 0))));
}

/// The result buffer is a direct buffer of at least the frozen result
/// size; the SDK reads the fields straight out of it.
export fn Java_com_gosslens_Gosslens_nativeFaceResult(env: *JniEnv, cls: jobject, session: i64, result_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, result_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const result: *abi.FaceResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_face_result(sessionFromHandle(session), result));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitFaces(env: *JniEnv, cls: jobject, session: i64, faces_buffer: jobject, count: i32) i32 {
    _ = cls;
    if (count == 0) return @intFromEnum(abi.goss_session_submit_faces(sessionFromHandle(session), null, 0));
    const bytes = getDirectBufferAddress(env, faces_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const faces: [*]const abi.FaceResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_submit_faces(sessionFromHandle(session), faces, @intCast(@max(count, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeFaceCount(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    var count: u32 = 0;
    if (abi.goss_session_face_count(sessionFromHandle(session), &count) != .ok) return -1;
    return @intCast(count);
}

export fn Java_com_gosslens_Gosslens_nativeFaceResultAt(env: *JniEnv, cls: jobject, session: i64, index: i32, result_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, result_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const result: *abi.FaceResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_face_result_at(sessionFromHandle(session), @intCast(@max(index, 0)), result));
}

export fn Java_com_gosslens_Gosslens_nativeFaceTrackId(env: *JniEnv, cls: jobject, session: i64, index: i32) i32 {
    _ = env;
    _ = cls;
    var id: u32 = 0;
    if (abi.goss_session_face_track_id(sessionFromHandle(session), @intCast(@max(index, 0)), &id) != .ok) return -1;
    return @intCast(id);
}

export fn Java_com_gosslens_Gosslens_nativeSubmitBodies(env: *JniEnv, cls: jobject, session: i64, bodies_buffer: jobject, count: i32) i32 {
    _ = cls;
    if (count == 0) return @intFromEnum(abi.goss_session_submit_bodies(sessionFromHandle(session), null, 0));
    const bytes = getDirectBufferAddress(env, bodies_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const bodies: [*]const abi.PoseResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_submit_bodies(sessionFromHandle(session), bodies, @intCast(@max(count, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitDepth(env: *JniEnv, cls: jobject, session: i64, depth_buffer: jobject, width: i32, height: i32, near: f32, far: f32) i32 {
    _ = cls;
    if (width == 0 or height == 0) return @intFromEnum(abi.goss_session_submit_depth(sessionFromHandle(session), null, 0, 0, 0, 0));
    const bytes = getDirectBufferAddress(env, depth_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const depth: [*]const f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_submit_depth(sessionFromHandle(session), depth, @intCast(@max(width, 0)), @intCast(@max(height, 0)), near, far));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitCameraIntrinsics(env: *JniEnv, cls: jobject, session: i64, fx: f32, fy: f32, cx: f32, cy: f32, distortion_buffer: jobject, distortion_len: i32) i32 {
    _ = cls;
    if (distortion_len == 0) return @intFromEnum(abi.goss_session_submit_camera_intrinsics(sessionFromHandle(session), 0, 0, 0, 0, null, 0));
    const bytes = getDirectBufferAddress(env, distortion_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const distortion: [*]const f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_submit_camera_intrinsics(sessionFromHandle(session), fx, fy, cx, cy, distortion, @intCast(@max(distortion_len, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitOrientation(env: *JniEnv, cls: jobject, session: i64, gravity_x: f32, gravity_y: f32, gravity_z: f32, timestamp_us: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_submit_orientation(sessionFromHandle(session), gravity_x, gravity_y, gravity_z, timestamp_us));
}

export fn Java_com_gosslens_Gosslens_nativeCaptureView(env: *JniEnv, cls: jobject, session: i64, guidance_buffer: jobject) i32 {
    _ = cls;
    const guidance = getDirectBufferAddress(env, guidance_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_capture_view(sessionFromHandle(session), @ptrCast(@alignCast(guidance))));
}

export fn Java_com_gosslens_Gosslens_nativeResetCapture(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_reset_capture(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitSegmentationImage(env: *JniEnv, cls: jobject, session: i64, rgba_buffer: jobject, width: i32, height: i32) i32 {
    _ = cls;
    if (width == 0 or height == 0) return @intFromEnum(abi.Status.invalid_argument);
    const bytes = getDirectBufferAddress(env, rgba_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const rgba: [*]const u8 = @ptrCast(bytes);
    return @intFromEnum(abi.goss_session_submit_segmentation_image(sessionFromHandle(session), rgba, @intCast(@max(width, 0)), @intCast(@max(height, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitAvatarSourceRgba(env: *JniEnv, cls: jobject, session: i64, rgba_buffer: jobject, width: i32, height: i32) i32 {
    _ = cls;
    if (width == 0 or height == 0) return @intFromEnum(abi.Status.invalid_argument);
    const bytes = getDirectBufferAddress(env, rgba_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const rgba: [*]const u8 = @ptrCast(bytes);
    return @intFromEnum(abi.goss_session_submit_avatar_source_rgba(sessionFromHandle(session), rgba, @intCast(@max(width, 0)), @intCast(@max(height, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSetMakeupReference(env: *JniEnv, cls: jobject, session: i64, rgba_buffer: jobject, width: i32, height: i32, landmarks_buffer: jobject, count: i32) i32 {
    _ = cls;
    if (count == 0) return @intFromEnum(abi.goss_session_set_makeup_reference(sessionFromHandle(session), null, 0, 0, null, 0));
    const rbytes = getDirectBufferAddress(env, rgba_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const lbytes = getDirectBufferAddress(env, landmarks_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const rgba: [*]const u8 = @ptrCast(rbytes);
    const landmarks: [*]const f32 = @ptrCast(@alignCast(lbytes));
    return @intFromEnum(abi.goss_session_set_makeup_reference(sessionFromHandle(session), rgba, @intCast(@max(width, 0)), @intCast(@max(height, 0)), landmarks, @intCast(@max(count, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeBodyCount(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    var count: u32 = 0;
    if (abi.goss_session_body_count(sessionFromHandle(session), &count) != .ok) return -1;
    return @intCast(count);
}

export fn Java_com_gosslens_Gosslens_nativeBodyResultAt(env: *JniEnv, cls: jobject, session: i64, index: i32, result_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, result_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const result: *abi.PoseResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_body_result_at(sessionFromHandle(session), @intCast(@max(index, 0)), result));
}

export fn Java_com_gosslens_Gosslens_nativeEnableHandTracking(env: *JniEnv, cls: jobject, session: i64, task_buffer: jobject, task_len: i32, threads: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, task_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_enable_hand_tracking(sessionFromHandle(session), bytes, @intCast(@max(task_len, 0)), threads));
}

export fn Java_com_gosslens_Gosslens_nativeDisableHandTracking(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_disable_hand_tracking(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeHandResult(env: *JniEnv, cls: jobject, session: i64, result_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, result_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const result: *abi.HandResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_hand_result(sessionFromHandle(session), result));
}

export fn Java_com_gosslens_Gosslens_nativeEnablePoseTracking(env: *JniEnv, cls: jobject, session: i64, task_buffer: jobject, task_len: i32, threads: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, task_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_enable_pose_tracking(sessionFromHandle(session), bytes, @intCast(@max(task_len, 0)), threads));
}

export fn Java_com_gosslens_Gosslens_nativeDisablePoseTracking(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_disable_pose_tracking(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativePoseResult(env: *JniEnv, cls: jobject, session: i64, result_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, result_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const result: *abi.PoseResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_pose_result(sessionFromHandle(session), result));
}

export fn Java_com_gosslens_Gosslens_nativeFacePose(env: *JniEnv, cls: jobject, session: i64, matrix_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, matrix_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const matrix: *[16]f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_face_pose(sessionFromHandle(session), matrix));
}

export fn Java_com_gosslens_Gosslens_nativeFaceRegion(env: *JniEnv, cls: jobject, session: i64, region: i32, out_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: *[3]f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_face_region(sessionFromHandle(session), @intCast(region), out));
}

export fn Java_com_gosslens_Gosslens_nativeBodyJoint(env: *JniEnv, cls: jobject, session: i64, joint: i32, out_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: *[3]f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_body_joint(sessionFromHandle(session), @intCast(joint), out));
}

export fn Java_com_gosslens_Gosslens_nativeHandJoint(env: *JniEnv, cls: jobject, session: i64, hand_index: i32, joint: i32, out_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: *[3]f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_hand_joint(sessionFromHandle(session), @intCast(hand_index), @intCast(joint), out));
}

/// info_buffer receives {encoded_len: u64, width: u32, height: u32};
/// a too-small data buffer still fills it, so the caller can retry
/// with the exact size (the ABI's own probe contract).
export fn Java_com_gosslens_Gosslens_nativeCapturePhoto(env: *JniEnv, cls: jobject, engine: i64, session: i64, data_buffer: jobject, data_capacity: i64, info_buffer: jobject) i32 {
    _ = cls;
    const info_bytes = getDirectBufferAddress(env, info_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const info: *extern struct { encoded_len: u64, width: u32, height: u32 } = @ptrCast(@alignCast(info_bytes));
    const data = getDirectBufferAddress(env, data_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var encoded_len: usize = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    const status = abi.goss_engine_capture_photo(engineFromHandle(engine), sessionFromHandle(session), @ptrCast(data), @intCast(@max(data_capacity, 0)), &encoded_len, &width, &height);
    info.encoded_len = encoded_len;
    info.width = width;
    info.height = height;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeCaptureStill(env: *JniEnv, cls: jobject, engine: i64, session: i64, width: i32, height: i32, supersample: i32, format: i32, quality: i32, color_space: i32, bit_depth: i32, data_buffer: jobject, data_capacity: i64, info_buffer: jobject) i32 {
    _ = cls;
    const info_bytes = getDirectBufferAddress(env, info_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const info: *extern struct { encoded_len: u64, width: u32, height: u32 } = @ptrCast(@alignCast(info_bytes));
    const data = getDirectBufferAddress(env, data_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var config: abi.CaptureConfig = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .supersample = @intCast(@max(supersample, 0)),
        .format = @intCast(@max(format, 0)),
        .quality = @intCast(@max(quality, 0)),
        .color_space = @intCast(@max(color_space, 0)),
        .bit_depth = @intCast(@max(bit_depth, 0)),
    };
    var encoded_len: usize = 0;
    var out_width: u32 = 0;
    var out_height: u32 = 0;
    const status = abi.goss_engine_capture_still(engineFromHandle(engine), sessionFromHandle(session), &config, @ptrCast(data), @intCast(@max(data_capacity, 0)), &encoded_len, &out_width, &out_height);
    info.encoded_len = encoded_len;
    info.width = out_width;
    info.height = out_height;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeCaptureLiveFrame(env: *JniEnv, cls: jobject, engine: i64, session: i64, format: i32, data_buffer: jobject, data_capacity: i64, info_buffer: jobject) i32 {
    _ = cls;
    const info_bytes = getDirectBufferAddress(env, info_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const info: *extern struct { width: u32, height: u32 } = @ptrCast(@alignCast(info_bytes));
    const data = getDirectBufferAddress(env, data_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var width: u32 = 0;
    var height: u32 = 0;
    const status = abi.goss_engine_capture_live_frame(engineFromHandle(engine), sessionFromHandle(session), @intCast(@max(format, 0)), @ptrCast(data), @intCast(@max(data_capacity, 0)), &width, &height);
    info.width = width;
    info.height = height;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeRecordingStart(env: *JniEnv, cls: jobject, engine: i64, session: i64, path_buffer: jobject, path_len: i32, width: i32, height: i32, bitrate: i32, codec: i32) i32 {
    _ = cls;
    const path = getDirectBufferAddress(env, path_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const config: abi.RecordingConfig = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .bitrate_bps = @intCast(@max(bitrate, 0)),
        .codec = @intCast(@max(codec, 0)),
    };
    return @intFromEnum(abi.goss_engine_recording_start(engineFromHandle(engine), sessionFromHandle(session), @ptrCast(path), @intCast(@max(path_len, 0)), &config));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitAudio(env: *JniEnv, cls: jobject, session: i64, samples_buffer: jobject, frame_count: i32, sample_rate: i32, channels: i32, timestamp_us: i64) i32 {
    _ = cls;
    const samples = getDirectBufferAddress(env, samples_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_submit_audio(sessionFromHandle(session), @ptrCast(@alignCast(samples)), @intCast(@max(frame_count, 0)), @intCast(@max(sample_rate, 0)), @intCast(@max(channels, 0)), timestamp_us));
}

/// state_buffer packs goss_world_state; planes_buffer and
/// anchors_buffer pack their arrays; light_buffer the light estimate.
export fn Java_com_gosslens_Gosslens_nativeSubmitWorld(env: *JniEnv, cls: jobject, session: i64, state_buffer: jobject, planes_buffer: jobject, plane_count: i32, anchors_buffer: jobject, anchor_count: i32, light_buffer: jobject) i32 {
    _ = cls;
    const state = getDirectBufferAddress(env, state_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const planes: ?[*]const abi.WorldPlane = if (plane_count > 0)
        @ptrCast(@alignCast(getDirectBufferAddress(env, planes_buffer) orelse return @intFromEnum(abi.Status.invalid_argument)))
    else
        null;
    const anchors: ?[*]const abi.WorldAnchor = if (anchor_count > 0)
        @ptrCast(@alignCast(getDirectBufferAddress(env, anchors_buffer) orelse return @intFromEnum(abi.Status.invalid_argument)))
    else
        null;
    const light: ?*const abi.WorldLight = if (getDirectBufferAddress(env, light_buffer)) |raw| @ptrCast(@alignCast(raw)) else null;
    return @intFromEnum(abi.goss_session_submit_world(sessionFromHandle(session), @ptrCast(@alignCast(state)), planes, @intCast(@max(plane_count, 0)), anchors, @intCast(@max(anchor_count, 0)), light));
}

export fn Java_com_gosslens_Gosslens_nativeRecordingStop(env: *JniEnv, cls: jobject, engine: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_engine_recording_stop(engineFromHandle(engine)));
}

export fn Java_com_gosslens_Gosslens_nativeEnableBeauty(env: *JniEnv, cls: jobject, session: i64, path_buffer: jobject, path_len: i32) i32 {
    _ = cls;
    _ = path_len;
    const path = getDirectBufferAddress(env, path_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_enable_beauty(sessionFromHandle(session), @ptrCast(path)));
}

export fn Java_com_gosslens_Gosslens_nativeDisableBeauty(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_disable_beauty(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeSetBeauty(env: *JniEnv, cls: jobject, session: i64, effect: i32, value: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_set_beauty(sessionFromHandle(session), effect, value));
}

export fn Java_com_gosslens_Gosslens_nativeBeautifyFrame(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    rgba_in: jobject,
    rgba_out: jobject,
    width: i32,
    height: i32,
) i32 {
    _ = cls;
    const source = getDirectBufferAddress(env, rgba_in) orelse return @intFromEnum(abi.Status.invalid_argument);
    const destination = getDirectBufferAddress(env, rgba_out) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_beautify_frame(sessionFromHandle(session), source, @intCast(@max(width, 0)), @intCast(@max(height, 0)), destination));
}

export fn Java_com_gosslens_Gosslens_nativeActivateLens(env: *JniEnv, cls: jobject, session: i64, manifest_buffer: jobject, manifest_len: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, manifest_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_activate_lens(sessionFromHandle(session), bytes, @intCast(manifest_len)));
}

export fn Java_com_gosslens_Gosslens_nativeDeactivateLens(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_deactivate_lens(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeTickLens(env: *JniEnv, cls: jobject, session: i64, dt_us: i32, signals_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, signals_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const signals: *const abi.LensSignals = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_tick_lens(sessionFromHandle(session), @intCast(dt_us), signals));
}

export fn Java_com_gosslens_Gosslens_nativeParameterValue(env: *JniEnv, cls: jobject, session: i64, name_buffer: jobject, name_len: i32, out_buffer: jobject) i32 {
    _ = cls;
    const name = getDirectBufferAddress(env, name_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out_bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: *f32 = @ptrCast(@alignCast(out_bytes));
    return @intFromEnum(abi.goss_session_parameter_value(sessionFromHandle(session), name, @intCast(name_len), out));
}

export fn Java_com_gosslens_Gosslens_nativeHitTest(env: *JniEnv, cls: jobject, session: i64, screen_x: f32, screen_y: f32, out_buffer: jobject) i32 {
    _ = cls;
    const out_bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: *[3]f32 = @ptrCast(@alignCast(out_bytes));
    return @intFromEnum(abi.goss_session_hit_test(sessionFromHandle(session), screen_x, screen_y, out));
}

export fn Java_com_gosslens_Gosslens_nativePullAudio(env: *JniEnv, cls: jobject, session: i64, out_buffer: jobject, frames: i32) i32 {
    _ = cls;
    const out_bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: [*]i16 = @ptrCast(@alignCast(out_bytes));
    return @intFromEnum(abi.goss_session_pull_audio(sessionFromHandle(session), out, @intCast(frames)));
}

/// mic_buffer may be null to mix the lens sound over silence; out_buffer packs
/// frame_count*channels interleaved s16.
export fn Java_com_gosslens_Gosslens_nativeMixOutputAudio(env: *JniEnv, cls: jobject, session: i64, mic_buffer: jobject, out_buffer: jobject, frame_count: i32, sample_rate: i32, channels: i32) i32 {
    _ = cls;
    const out_bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: [*]i16 = @ptrCast(@alignCast(out_bytes));
    const mic: ?[*]const f32 = if (getDirectBufferAddress(env, mic_buffer)) |raw| @ptrCast(@alignCast(raw)) else null;
    return @intFromEnum(abi.goss_session_mix_output_audio(sessionFromHandle(session), mic, out, @intCast(@max(frame_count, 0)), @intCast(@max(sample_rate, 0)), @intCast(@max(channels, 0))));
}

/// buffer packs the 56-byte goss_camera_controls in native byte order.
export fn Java_com_gosslens_Gosslens_nativeSetCameraControls(env: *JniEnv, cls: jobject, session: i64, buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_set_camera_controls(sessionFromHandle(session), @ptrCast(@alignCast(bytes))));
}

export fn Java_com_gosslens_Gosslens_nativeSetRecordingPolicy(env: *JniEnv, cls: jobject, session: i64, buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_set_recording_policy(sessionFromHandle(session), @ptrCast(@alignCast(bytes))));
}

export fn Java_com_gosslens_Gosslens_nativeRecordingPolicy(env: *JniEnv, cls: jobject, session: i64, buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_recording_policy(sessionFromHandle(session), @ptrCast(@alignCast(bytes))));
}

export fn Java_com_gosslens_Gosslens_nativeSetCaptureUi(env: *JniEnv, cls: jobject, session: i64, buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_set_capture_ui(sessionFromHandle(session), @ptrCast(@alignCast(bytes))));
}

export fn Java_com_gosslens_Gosslens_nativeCaptureUi(env: *JniEnv, cls: jobject, session: i64, buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_capture_ui(sessionFromHandle(session), @ptrCast(@alignCast(bytes))));
}

export fn Java_com_gosslens_Gosslens_nativeCameraControls(env: *JniEnv, cls: jobject, session: i64, buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_camera_controls(sessionFromHandle(session), @ptrCast(@alignCast(bytes))));
}

export fn Java_com_gosslens_Gosslens_nativeFireEvent(env: *JniEnv, cls: jobject, session: i64, name_buffer: jobject, name_len: i32) i32 {
    _ = cls;
    const name = getDirectBufferAddress(env, name_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_fire_event(sessionFromHandle(session), name, @intCast(@max(name_len, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeDefineSource(env: *JniEnv, cls: jobject, session: i64, name_buffer: jobject, name_len: i32) i32 {
    _ = cls;
    const name = getDirectBufferAddress(env, name_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_define_source(sessionFromHandle(session), name, @intCast(@max(name_len, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeRemoveSource(env: *JniEnv, cls: jobject, session: i64, name_buffer: jobject, name_len: i32) i32 {
    _ = cls;
    const name = getDirectBufferAddress(env, name_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_remove_source(sessionFromHandle(session), name, @intCast(@max(name_len, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitSourceFrameRgba(env: *JniEnv, cls: jobject, session: i64, name_buffer: jobject, name_len: i32, rgba_buffer: jobject, width: i32, height: i32, stride: i32, pixel_format: i32) i32 {
    _ = cls;
    const name = getDirectBufferAddress(env, name_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const rgba = getDirectBufferAddress(env, rgba_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const desc: abi.FrameDesc = .{ .width = @intCast(@max(width, 0)), .height = @intCast(@max(height, 0)), .pixel_format = @intCast(@max(pixel_format, 0)), .color_standard = 0, .color_range = 1, .flags = 0, .timestamp_us = 0 };
    return @intFromEnum(abi.goss_session_submit_source_frame_rgba_copy(sessionFromHandle(session), name, @intCast(@max(name_len, 0)), &desc, rgba, @intCast(@max(stride, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSetSourceComposite(env: *JniEnv, cls: jobject, session: i64, name_buffer: jobject, name_len: i32, opacity: f32, key_mode: i32, key_r: f32, key_g: f32, key_b: f32, similarity: f32) i32 {
    _ = cls;
    const name = getDirectBufferAddress(env, name_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_set_source_composite(sessionFromHandle(session), name, @intCast(@max(name_len, 0)), opacity, @intCast(@max(key_mode, 0)), key_r, key_g, key_b, similarity));
}

export fn Java_com_gosslens_Gosslens_nativeDefineScreenShare(env: *JniEnv, cls: jobject, session: i64, name_buffer: jobject, name_len: i32) i32 {
    _ = cls;
    const name = getDirectBufferAddress(env, name_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_define_screen_share(sessionFromHandle(session), name, @intCast(@max(name_len, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSetLayout(env: *JniEnv, cls: jobject, session: i64, arrangement: i32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_set_layout(sessionFromHandle(session), @intCast(@max(arrangement, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeSetPoseUpperBody(env: *JniEnv, cls: jobject, session: i64, enabled: i32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_set_pose_upper_body(sessionFromHandle(session), @intCast(@max(enabled, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeClearLayout(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_clear_layout(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitLocation(env: *JniEnv, cls: jobject, session: i64, latitude: f64, longitude: f64, accuracy_m: f32, timestamp_us: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_submit_location(sessionFromHandle(session), latitude, longitude, accuracy_m, timestamp_us));
}

export fn Java_com_gosslens_Gosslens_nativeSetGeofence(env: *JniEnv, cls: jobject, session: i64, latitude: f64, longitude: f64, radius_m: f64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_set_geofence(sessionFromHandle(session), latitude, longitude, radius_m));
}

export fn Java_com_gosslens_Gosslens_nativeClearGeofence(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_clear_geofence(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeSetGeofenceBbox(env: *JniEnv, cls: jobject, session: i64, min_lat: f64, min_lon: f64, max_lat: f64, max_lon: f64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_set_geofence_bbox(sessionFromHandle(session), min_lat, min_lon, max_lat, max_lon));
}

/// coords_buffer is a direct double buffer of vertex_count lat, lon pairs.
export fn Java_com_gosslens_Gosslens_nativeSetGeofencePolygon(env: *JniEnv, cls: jobject, session: i64, coords_buffer: jobject, vertex_count: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, coords_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const coords: [*]const f64 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_set_geofence_polygon(sessionFromHandle(session), coords, @intCast(@max(vertex_count, 0))));
}

/// name_buffer is a direct byte buffer of the region name, name_len bytes.
export fn Java_com_gosslens_Gosslens_nativeSetNamedGeofence(env: *JniEnv, cls: jobject, session: i64, name_buffer: jobject, name_len: i32, latitude: f64, longitude: f64, radius_m: f64) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, name_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const name: [*]const u8 = @ptrCast(bytes);
    return @intFromEnum(abi.goss_session_set_named_geofence(sessionFromHandle(session), name, @intCast(@max(name_len, 0)), latitude, longitude, radius_m));
}

export fn Java_com_gosslens_Gosslens_nativeClearNamedGeofences(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_clear_named_geofences(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeSetGeoAccuracy(env: *JniEnv, cls: jobject, session: i64, max_accuracy_m: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_set_geo_accuracy(sessionFromHandle(session), max_accuracy_m));
}

export fn Java_com_gosslens_Gosslens_nativeBrushSetStyle(env: *JniEnv, cls: jobject, session: i64, r: f32, g: f32, b: f32, a: f32, width: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_brush_set_style(sessionFromHandle(session), r, g, b, a, width));
}

/// rgba_buffer is a direct byte buffer of width*height RGBA8 pixels.
export fn Java_com_gosslens_Gosslens_nativeBrushSetStamp(env: *JniEnv, cls: jobject, session: i64, rgba_buffer: jobject, width: i32, height: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, rgba_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const rgba: [*]const u8 = @ptrCast(bytes);
    return @intFromEnum(abi.goss_session_brush_set_stamp(sessionFromHandle(session), rgba, @intCast(@max(width, 0)), @intCast(@max(height, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeBrushBegin(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_brush_begin(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeBrushPoint(env: *JniEnv, cls: jobject, session: i64, x: f32, y: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_brush_point(sessionFromHandle(session), x, y));
}

export fn Java_com_gosslens_Gosslens_nativeBrushEnd(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_brush_end(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeBrushUndo(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_brush_undo(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeBrushRedo(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_brush_redo(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeBrushClear(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_brush_clear(sessionFromHandle(session)));
}

/// Reports the float count the finished ribbon needs; -1 on a bad session.
export fn Java_com_gosslens_Gosslens_nativeBrushVertexCount(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    var count: usize = 0;
    if (abi.goss_session_brush_vertices(sessionFromHandle(session), null, 0, &count) != .ok) return -1;
    return @intCast(count);
}

/// Fills out_buffer (a direct float buffer) with the ribbon; returns the float
/// count written, or -1 on a bad session or buffer.
export fn Java_com_gosslens_Gosslens_nativeBrushVertices(env: *JniEnv, cls: jobject, session: i64, out_buffer: jobject, capacity_floats: i32) i32 {
    _ = cls;
    const out_bytes = getDirectBufferAddress(env, out_buffer) orelse return -1;
    const out: [*]f32 = @ptrCast(@alignCast(out_bytes));
    var written: usize = 0;
    if (abi.goss_session_brush_vertices(sessionFromHandle(session), out, @intCast(@max(capacity_floats, 0)), &written) != .ok) return -1;
    return @intCast(written);
}

export fn Java_com_gosslens_Gosslens_nativeBrushSetMode(env: *JniEnv, cls: jobject, session: i64, mode: i32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_brush_set_mode(sessionFromHandle(session), @intCast(@max(mode, 0))));
}

/// Returns the number of strokes erased, or -1 on a bad session.
export fn Java_com_gosslens_Gosslens_nativeBrushEraseAt(env: *JniEnv, cls: jobject, session: i64, x: f32, y: f32, radius: f32) i32 {
    _ = env;
    _ = cls;
    var removed: usize = 0;
    if (abi.goss_session_brush_erase_at(sessionFromHandle(session), x, y, radius, &removed) != .ok) return -1;
    return @intCast(removed);
}

export fn Java_com_gosslens_Gosslens_nativeArBrushSetStyle(env: *JniEnv, cls: jobject, session: i64, r: f32, g: f32, b: f32, a: f32, width: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_ar_brush_set_style(sessionFromHandle(session), r, g, b, a, width));
}

export fn Java_com_gosslens_Gosslens_nativeArBrushSetMode(env: *JniEnv, cls: jobject, session: i64, mode: i32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_ar_brush_set_mode(sessionFromHandle(session), @intCast(@max(mode, 0))));
}

export fn Java_com_gosslens_Gosslens_nativeArBrushBegin(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_ar_brush_begin(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeArBrushPoint(env: *JniEnv, cls: jobject, session: i64, x: f32, y: f32, z: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_ar_brush_point(sessionFromHandle(session), x, y, z));
}

export fn Java_com_gosslens_Gosslens_nativeArBrushEnd(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_ar_brush_end(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeArBrushUndo(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_ar_brush_undo(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeArBrushClear(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_ar_brush_clear(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeGrab(env: *JniEnv, cls: jobject, session: i64, x: f32, y: f32, z: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_grab(sessionFromHandle(session), x, y, z));
}

export fn Java_com_gosslens_Gosslens_nativeTouch(env: *JniEnv, cls: jobject, session: i64, phase: i32, pointer_id: i32, x: f32, y: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_touch(sessionFromHandle(session), @intCast(@max(phase, 0)), @intCast(@max(pointer_id, 0)), x, y));
}

export fn Java_com_gosslens_Gosslens_nativePullHaptic(env: *JniEnv, cls: jobject, session: i64, out_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: *[2]f32 = @ptrCast(@alignCast(bytes));
    var style: u32 = 0;
    var intensity: f32 = 0;
    const rc = abi.goss_session_pull_haptic(sessionFromHandle(session), &style, &intensity);
    if (rc == .ok) {
        out[0] = @floatFromInt(style);
        out[1] = intensity;
    }
    return @intFromEnum(rc);
}

export fn Java_com_gosslens_Gosslens_nativeRelease(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_release(sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeAddCollider(env: *JniEnv, cls: jobject, session: i64, x: f32, y: f32, z: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_add_collider(sessionFromHandle(session), x, y, z));
}

export fn Java_com_gosslens_Gosslens_nativeEraseCollider(env: *JniEnv, cls: jobject, session: i64, x: f32, y: f32, z: f32, radius: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_erase_collider(sessionFromHandle(session), x, y, z, radius));
}

export fn Java_com_gosslens_Gosslens_nativeReportFrame(env: *JniEnv, cls: jobject, session: i64, frame_time_us: i32, thermal: i32) i32 {
    _ = env;
    _ = cls;
    return abi.goss_session_report_frame(sessionFromHandle(session), @intCast(frame_time_us), thermal);
}
