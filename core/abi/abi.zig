//! The goss_ export layer: the only file that exports symbols. Everything here
//! mirrors include/gosslens.h exactly; layouts are frozen and asserted at
//! compile time, and the abi gate diffs the surface on every change.
//!
//! Exports delegate to internal functions that take an allocator, so tests
//! exercise the same code paths under the leak-checking test allocator while
//! shipping builds use the platform allocator. The render backend arrives
//! through the `render` module import: the real bgfx binding on platforms
//! with a compiled render stack, a refusing stub elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const graph = @import("graph");
const math = @import("math");
const render = @import("render");
const tracking = @import("tracking");
const segmentation = @import("segmentation");
const face = @import("face");
const face_geometry = @import("face_geometry");
const png = @import("png");
const gif = @import("gif");
const jpeg = @import("jpeg");
const color = @import("color");
const media_recording = @import("media_recording");
const photo = @import("photo");
const audio_analysis = @import("audio_analysis");
const audio_mix = @import("audio_mix");
const comp = @import("layout");
const geo = @import("geo");
const font = @import("font");
const stroke = @import("stroke");
const wboard = @import("world_board");
const physics = @import("physics");
const script = @import("script");
const audio_playback = @import("audio_playback");
const particles = @import("particles");
const sph = @import("sph");
const video = @import("media_video");
const hand = @import("hand");
const pose = @import("pose");
const beauty = @import("beauty");
const manifest = @import("manifest");
const trigger = @import("trigger");
const asset = @import("asset");
const image = @import("image");
const gltf = @import("gltf");
const face106 = @import("face106");

/// Whether this build targets wasm32-emscripten - the only web target
/// with a real bgfx renderer under it (wasm32-freestanding, the other
/// wasm target this file compiles for, links render_stub.zig instead).
/// adapters/beauty.zig's gpupixel bridge isn't ported to web (2026-08-15
/// GPU-compositing decision), so beauty.face/beauty.reshape need their
/// own dispatch here in place of applyBeautyCompositing's gpupixel
/// calls - guarded on this rather than reachable from every target.
const is_web = builtin.os.tag == .emscripten;
const is_android = builtin.os.tag == .linux and builtin.abi.isAndroid();

// A directory-based lens activation needs to read files (manifest.json,
// compiled shader bytecode) from within an exported goss_ function, which
// no SDK hands an Io instance into - this library owns one blocking
// implementation for that, single-threaded since it's only ever
// occasional small reads at lens activation, never the frame path.
// std.Io.Threaded assumes a POSIX-like host and cannot even be typed
// for wasm32-freestanding (no threads, no file syscalls) - directory-
// based activation is unsupported there the same way beauty/tracking
// already are, guarded before this is ever reached, not by pretending
// the type exists.
const has_file_io = !builtin.cpu.arch.isWasm();
var default_threaded_io: if (has_file_io) std.Io.Threaded else void =
    if (has_file_io) std.Io.Threaded.init_single_threaded else {};
fn defaultIo() std.Io {
    return default_threaded_io.io();
}
const runtime = @import("runtime");

pub const FaceResult = face.Result;
pub const HandResult = hand.Result;
pub const PoseResult = pose.Result;

/// Re-exported for the conformance harness, which reads a face result's raw
/// landmarks and needs the same loops the face-part mattes fill.
pub const outer_lip_loop = face.outer_lip_loop;
pub const left_eye_loop = face.left_eye_loop;
pub const right_eye_loop = face.right_eye_loop;
pub const left_brow_loop = face.left_brow_loop;
pub const right_brow_loop = face.right_brow_loop;
pub const left_iris_loop = face.left_iris_loop;
pub const right_iris_loop = face.right_iris_loop;
pub const inner_lip_loop = face.inner_lip_loop;
pub const contour_regions = face.contour_regions;
pub const highlight_regions = face.highlight_regions;
pub const skin_patch = face.skin_patch;
pub const lashLineBand = face.lashLineBand;
pub const face_landmark_count = face.landmark_count;

pub const abi_major: u16 = 0;
// The frozen ABI surface lives here so the version and the dump tool read
// one list. A new export adds a line to abi_functions, its header decl, and
// its body - nothing else.
pub const abi_surface_types = .{ FrameDesc, Landmarks, EngineConfig, SessionConfig, RendererDesc, FramePlanes, FaceResult, HandResult, PoseResult, LensSignals, CameraControls, RecordingPolicy, CaptureUiIntent };

pub const abi_functions = [_][]const u8{
    "uint32_t goss_abi_version(void)",
    "void *goss_alloc(size_t size)",
    "void goss_free(void *ptr, size_t size)",
    "goss_status goss_engine_create(const goss_engine_config *config, goss_engine **out_engine)",
    "void goss_engine_destroy(goss_engine *engine)",
    "goss_status goss_session_create(goss_engine *engine, const goss_session_config *config, goss_session **out_session)",
    "void goss_session_destroy(goss_session *session)",
    "goss_status goss_engine_init_renderer(goss_engine *engine, const goss_renderer_desc *desc)",
    "void goss_engine_resize(goss_engine *engine, uint32_t width, uint32_t height)",
    "goss_status goss_engine_render_frame(goss_engine *engine, goss_session *session)",
    "goss_status goss_engine_request_screenshot(goss_engine *engine, const uint8_t *path, size_t path_len)",
    "goss_status goss_engine_capture_frame(goss_engine *engine, goss_session *session, uint8_t *out_data, size_t out_capacity, uint32_t *out_width, uint32_t *out_height)",
    "goss_status goss_engine_capture_photo(goss_engine *engine, goss_session *session, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height)",
    "goss_status goss_engine_capture_photo_as(goss_engine *engine, goss_session *session, uint32_t format, uint32_t quality, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height)",
    "goss_status goss_engine_recording_start(goss_engine *engine, goss_session *session, const uint8_t *path, size_t path_len, const goss_recording_config *config)",
    "goss_status goss_engine_recording_stop(goss_engine *engine)",
    "goss_status goss_session_submit_audio(goss_session *session, const float *samples, uint32_t frame_count, uint32_t sample_rate, uint32_t channels, int64_t timestamp_us)",
    "goss_status goss_session_submit_world(goss_session *session, const goss_world_state *state, const goss_world_plane *planes, size_t plane_count, const goss_world_anchor *anchors, size_t anchor_count, const goss_world_light *light)",
    "goss_status goss_engine_capture_still(goss_engine *engine, goss_session *session, const goss_capture_config *config, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height)",
    "goss_status goss_engine_capture_live_frame(goss_engine *engine, goss_session *session, uint32_t format, uint8_t *out_data, size_t out_capacity, uint32_t *out_width, uint32_t *out_height)",
    "goss_status goss_engine_render_to_live_texture(goss_engine *engine, goss_session *session, uint64_t native_handle, uint32_t width, uint32_t height)",
    "goss_status goss_session_parameter_value(goss_session *session, const uint8_t *name, size_t name_len, float *out_value)",
    "goss_status goss_session_pull_audio(goss_session *session, int16_t *out, uint32_t frames)",
    "goss_status goss_session_mix_output_audio(goss_session *session, const float *mic, int16_t *out, uint32_t frame_count, uint32_t sample_rate, uint32_t channels)",
    "goss_status goss_session_set_camera_controls(goss_session *session, const goss_camera_controls *controls)",
    "goss_status goss_session_camera_controls(goss_session *session, goss_camera_controls *out)",
    "goss_status goss_session_set_recording_policy(goss_session *session, const goss_recording_policy *policy)",
    "goss_status goss_session_recording_policy(goss_session *session, goss_recording_policy *out)",
    "goss_status goss_session_set_capture_ui(goss_session *session, const goss_capture_ui *ui)",
    "goss_status goss_session_capture_ui(goss_session *session, goss_capture_ui *out)",
    "goss_status goss_session_fire_event(goss_session *session, const uint8_t *name, size_t name_len)",
    "goss_status goss_session_define_source(goss_session *session, const uint8_t *name, size_t name_len)",
    "goss_status goss_session_remove_source(goss_session *session, const uint8_t *name, size_t name_len)",
    "goss_status goss_session_submit_source_frame_rgba_copy(goss_session *session, const uint8_t *name, size_t name_len, const goss_frame_desc *desc, const uint8_t *rgba, uint32_t stride)",
    "goss_status goss_session_set_layout(goss_session *session, uint32_t arrangement)",
    "goss_status goss_session_clear_layout(goss_session *session)",
    "goss_status goss_session_set_source_composite(goss_session *session, const uint8_t *name, size_t name_len, float opacity, uint32_t key_mode, float key_r, float key_g, float key_b, float similarity)",
    "goss_status goss_session_define_screen_share(goss_session *session, const uint8_t *name, size_t name_len)",
    "goss_status goss_session_submit_location(goss_session *session, double latitude, double longitude, float horizontal_accuracy_m, int64_t timestamp_us)",
    "goss_status goss_session_set_geofence(goss_session *session, double latitude, double longitude, double radius_m)",
    "goss_status goss_session_clear_geofence(goss_session *session)",
    "goss_status goss_session_set_geofence_bbox(goss_session *session, double min_lat, double min_lon, double max_lat, double max_lon)",
    "goss_status goss_session_set_geofence_polygon(goss_session *session, const double *coords, size_t vertex_count)",
    "goss_status goss_session_set_geo_accuracy(goss_session *session, float max_accuracy_m)",
    "goss_status goss_session_brush_set_style(goss_session *session, float r, float g, float b, float a, float width)",
    "goss_status goss_session_brush_begin(goss_session *session)",
    "goss_status goss_session_brush_point(goss_session *session, float x, float y)",
    "goss_status goss_session_brush_end(goss_session *session)",
    "goss_status goss_session_brush_undo(goss_session *session)",
    "goss_status goss_session_brush_redo(goss_session *session)",
    "goss_status goss_session_brush_clear(goss_session *session)",
    "goss_status goss_session_brush_vertices(goss_session *session, float *out, size_t capacity_floats, size_t *out_count)",
    "goss_status goss_session_brush_set_mode(goss_session *session, uint32_t mode)",
    "goss_status goss_session_brush_erase_at(goss_session *session, float x, float y, float radius, size_t *out_removed)",
    "goss_status goss_session_ar_brush_set_style(goss_session *session, float r, float g, float b, float a, float width)",
    "goss_status goss_session_ar_brush_set_mode(goss_session *session, uint32_t mode)",
    "goss_status goss_session_ar_brush_begin(goss_session *session)",
    "goss_status goss_session_ar_brush_point(goss_session *session, float x, float y, float z)",
    "goss_status goss_session_ar_brush_end(goss_session *session)",
    "goss_status goss_session_ar_brush_undo(goss_session *session)",
    "goss_status goss_session_ar_brush_clear(goss_session *session)",
    "goss_status goss_session_grab(goss_session *session, float x, float y, float z)",
    "goss_status goss_session_release(goss_session *session)",
    "goss_status goss_session_add_collider(goss_session *session, float x, float y, float z)",
    "goss_status goss_session_erase_collider(goss_session *session, float x, float y, float z, float radius)",
    "goss_status goss_session_submit_frame(goss_session *session, const goss_frame_desc *desc, const goss_frame_planes *planes)",
    "goss_status goss_session_submit_hardware_buffer(goss_session *session, const goss_frame_desc *desc, void *hardware_buffer)",
    "goss_status goss_session_submit_frame_copy(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride)",
    "goss_degrade_level goss_session_report_frame(goss_session *session, uint32_t frame_time_us, goss_thermal thermal)",
    "goss_degrade_level goss_session_degrade_level(const goss_session *session)",
    "goss_status goss_color_yuv_to_rgb(uint32_t color_standard, uint32_t color_range, float *out_matrix)",
    "goss_status goss_solve_two_bone_ik(const float *root, float upper_len, float lower_len, const float *target, const float *pole, float *out_mid, float *out_end)",
    "goss_status goss_session_enable_face_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads)",
    "void goss_session_disable_face_tracking(goss_session *session)",
    "goss_status goss_session_enable_hand_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads)",
    "void goss_session_disable_hand_tracking(goss_session *session)",
    "goss_status goss_session_hand_result(goss_session *session, goss_hand_result *out_result)",
    "goss_status goss_session_hand_joint(goss_session *session, uint32_t hand_index, uint32_t joint, float *out_xyz)",
    "goss_status goss_session_enable_pose_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads)",
    "void goss_session_disable_pose_tracking(goss_session *session)",
    "goss_status goss_session_set_pose_upper_body(goss_session *session, uint32_t enabled)",
    "goss_status goss_session_pose_result(goss_session *session, goss_pose_result *out_result)",
    "goss_status goss_session_body_joint(goss_session *session, uint32_t joint, float *out_xyz)",
    "goss_status goss_session_face_pose(goss_session *session, float *out_matrix)",
    "goss_status goss_session_face_region(goss_session *session, uint32_t region, float *out_xyz)",
    "goss_status goss_session_enable_segmentation(goss_session *session, const uint8_t *model_bytes, size_t model_len, int32_t threads)",
    "void goss_session_disable_segmentation(goss_session *session)",
    "goss_status goss_session_set_segmentation_mask(goss_session *session, const float *mask, uint32_t mask_len)",
    "uint32_t goss_session_segmentation_channels(goss_session *session)",
    "goss_status goss_session_set_segmentation_class_mask(goss_session *session, uint32_t channel, const float *mask, uint32_t mask_len)",
    "goss_status goss_session_track_frame(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride)",
    "goss_status goss_session_face_result(goss_session *session, goss_face_result *out_result)",
    "goss_status goss_session_submit_faces(goss_session *session, const goss_face_result *faces, uint32_t count)",
    "goss_status goss_session_face_count(goss_session *session, uint32_t *out_count)",
    "goss_status goss_session_face_result_at(goss_session *session, uint32_t index, goss_face_result *out_result)",
    "goss_status goss_session_submit_bodies(goss_session *session, const goss_pose_result *bodies, uint32_t count)",
    "goss_status goss_session_body_count(goss_session *session, uint32_t *out_count)",
    "goss_status goss_session_body_result_at(goss_session *session, uint32_t index, goss_pose_result *out_result)",
    "goss_status goss_session_submit_depth(goss_session *session, const float *depth, uint32_t width, uint32_t height, float near, float far)",
    "goss_status goss_session_submit_segmentation_image(goss_session *session, const uint8_t *rgba, uint32_t width, uint32_t height)",
    "goss_status goss_session_set_makeup_reference(goss_session *session, const uint8_t *rgba, uint32_t width, uint32_t height, const float *landmarks, uint32_t landmark_count)",
    "goss_status goss_session_enable_beauty(goss_session *session, const char *resource_path)",
    "void goss_session_disable_beauty(goss_session *session)",
    "goss_status goss_session_set_beauty(goss_session *session, int32_t effect, float value)",
    "goss_status goss_session_set_beauty_lut(goss_session *session, int32_t slot, const uint8_t *rgba, uint32_t width, uint32_t height)",
    "goss_status goss_session_set_beauty_makeup_texture(goss_session *session, int32_t effect, const uint8_t *rgba, uint32_t width, uint32_t height)",
    "goss_status goss_session_set_face_landmarks(goss_session *session, const float *points, uint32_t point_count)",
    "goss_status goss_session_submit_frame_rgba_copy(goss_session *session, const goss_frame_desc *desc, const uint8_t *rgba, uint32_t stride)",
    "goss_status goss_session_beautify_frame(goss_session *session, const uint8_t *rgba_in, uint32_t width, uint32_t height, uint8_t *rgba_out)",
    "goss_status goss_session_activate_lens(goss_session *session, const uint8_t *manifest_json, size_t manifest_len)",
    "goss_status goss_session_activate_lens_from_directory(goss_session *session, const uint8_t *bundle_path, size_t bundle_path_len)",
    "void goss_session_deactivate_lens(goss_session *session)",
    "goss_status goss_session_tick_lens(goss_session *session, uint32_t dt_us, const goss_lens_signals *signals)",
    "goss_status goss_physics_hair_remove(goss_session *session, uint32_t hair_id)",
    "goss_status goss_engine_release_live_texture(goss_engine *engine, uint64_t native_handle)",
};

// The minor advances from the surface, never by hand: a new op lengthens
// abi_functions so the number moves on its own and parallel branches cannot
// pick the same next value. The floor pins the value the day it landed.
const abi_minor_floor: u16 = 34;
const abi_functions_at_floor = 96;
pub const abi_minor: u16 = abi_minor_floor + @as(u16, @intCast(abi_functions.len - abi_functions_at_floor));

// As a library embedded in someone else's process the core never
// symbolizes its own stack: the hosting app owns crash reporting, and the
// symbolization machinery drags in loader interfaces mobile platforms do
// not export. A panic prints the message and traps; freestanding wasm has
// nowhere to print, so it traps directly.
pub const panic = if (builtin.os.tag == .freestanding) std.debug.no_panic else std.debug.simple_panic;

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    pool_exhausted = 3,
    abi_mismatch = 4,
    renderer_unavailable = 5,
    unsupported = 6,
    again = 7,
};

pub const FrameDesc = extern struct {
    width: u32,
    height: u32,
    pixel_format: u32,
    color_standard: u32,
    color_range: u32,
    flags: u32,
    timestamp_us: i64,
};

pub const frame_flag_mirror: u32 = 1 << 0;
pub const frame_rotation_shift: u5 = 8;
pub const frame_rotation_mask: u32 = 0x3 << 8;

/// The host may fire up to this many named events per tick; each name is
/// truncated to this many bytes. Bounded so firing allocates nothing.
const max_pending_events: usize = 8;
const max_event_name: usize = 31;

/// A composite source name is truncated to this many bytes.
const max_source_name: usize = 31;

pub const Landmarks = extern struct {
    points: ?[*]const f32,
    point_count: u32,
    confidence: f32,
    timestamp_us: i64,
};

pub const EngineConfig = extern struct {
    texture_pool_capacity: u32,
    staging_pool_capacity: u32,
};

pub const SessionConfig = extern struct {
    frame_budget_us: u32,
    reserved: u32,
};

pub const RendererDesc = extern struct {
    native_window_handle: ?*anyopaque,
    width: u32,
    height: u32,
};

pub const FramePlanes = extern struct {
    plane_count: u32,
    reserved: u32,
    planes: [3]u64,
};

/// The live signals a tick evaluates a lens's compiled triggers against -
/// blendshapes mirrors goss_face_result's own inline-array
/// convention rather than a pointer, so a caller reading a face result
/// can pass its blendshapes straight through. has_face false means no
/// face-driven signal (present or any blendshape) reads as true.
pub const LensSignals = extern struct {
    has_face: bool,
    hands_present: bool,
    tap: bool,
    reserved: u8 = 0,
    world_tracking_state: f64,
    audio_level: f64,
    blendshapes: [face.blendshape_count]f32,
};

comptime {
    std.debug.assert(@sizeOf(FrameDesc) == 32);
    std.debug.assert(@offsetOf(FrameDesc, "timestamp_us") == 24);
    std.debug.assert(@sizeOf(Landmarks) == 24);
    std.debug.assert(@offsetOf(Landmarks, "timestamp_us") == 16);
    std.debug.assert(@sizeOf(EngineConfig) == 8);
    std.debug.assert(@sizeOf(SessionConfig) == 8);
    std.debug.assert(@sizeOf(RendererDesc) == if (@sizeOf(usize) == 8) 16 else 12);
    std.debug.assert(@sizeOf(FramePlanes) == 32);
    std.debug.assert(@offsetOf(FramePlanes, "planes") == 8);
    std.debug.assert(@sizeOf(LensSignals) == 232);
    std.debug.assert(@offsetOf(LensSignals, "world_tracking_state") == 8);
    std.debug.assert(@offsetOf(LensSignals, "blendshapes") == 24);
}

const default_texture_pool_capacity: u32 = 16;
const default_staging_pool_capacity: u32 = 8;
const default_frame_budget_us: u32 = 33_333;

const pixel_format_nv12: u32 = 0;
const pixel_format_nv21: u32 = 1;
const pixel_format_i420: u32 = 2;
const pixel_format_bgra8: u32 = 3;
const pixel_format_rgba8: u32 = 4;

pub const Engine = struct {
    gpa: std.mem.Allocator,
    texture_pool: graph.Pool,
    staging_pool: graph.Pool,
    texture_pool_capacity: u16,
    staging_pool_capacity: u16,
    renderer: ?render.Renderer = null,
    /// Ping-pong offscreen targets a shader.pass chain renders through:
    /// camera capture and every pass but the last write into whichever
    /// of these it isn't reading from that frame. Sized to the active
    /// frame's dimensions and recreated only when that size changes,
    /// never per frame - only one chain is ever in flight at a time, so
    /// two targets are enough regardless of how many passes a lens has.
    chain_targets: [2]?render.Renderer.OffscreenTarget = .{ null, null },
    /// A bloom.pass node's own scratch pair, sized alongside chain_targets:
    /// the bright pass extracts into one, blurs H into the other and V back,
    /// leaving the chain's two ping-pong targets free to hold the frame
    /// being read and the composite being written.
    bloom_targets: [2]?render.Renderer.OffscreenTarget = .{ null, null },
    /// An edge.pass canny node's own scratch pair, sized alongside
    /// chain_targets: the blur, directional sobel, non-maximum suppression
    /// and hysteresis stages ping-pong through these two, leaving the chain's
    /// own targets holding the frame being read and the result being written.
    edge_targets: [2]?render.Renderer.OffscreenTarget = .{ null, null },
    chain_width: u16 = 0,
    chain_height: u16 = 0,
    /// Dedicated target for goss_engine_capture_frame - separate from
    /// chain_targets, which ping-pong and get overwritten mid-chain, so
    /// this one alone always holds the true final composited image
    /// after a capture-requested frame renders.
    capture_target: ?render.Renderer.OffscreenTarget = null,
    /// CPU-readable blit destination paired with capture_target -
    /// render targets are not directly readable on every backend.
    capture_staging: ?render.TextureHandle = null,
    capture_width: u16 = 0,
    capture_height: u16 = 0,
    /// Reused RGBA scratch for the NV12 live path, which reads back RGBA
    /// and packs it down - kept off the per-frame allocation path.
    capture_convert: []u8 = &.{},
    /// Active video recording, fed one composited frame per rendered
    /// frame of recording_session; frames commit two engine frames
    /// after they render so the GPU has finished writing them.
    recording: ?media_recording.Recording = null,
    recording_session: ?*Session = null,
    /// External render targets per encoder pool buffer, keyed by the
    /// native texture pointer - the pool cycles a few buffers, each
    /// needing its own persistent wrap.
    recording_slots: std.AutoHashMapUnmanaged(usize, RecordingSlot) = .empty,
    recording_pending: [2]?PendingRecordingFrame = .{ null, null },
    recording_pending_at: u8 = 0,
    /// The slot the current frame's composite renders into, when this
    /// frame both records and its wrap has landed.
    recording_frame_target: ?render.Renderer.OffscreenTarget = null,
    recording_last_timestamp: i64 = std.math.minInt(i64),
    recording_warmups: u32 = 0,
    recording_dropped: u32 = 0,
    /// Window-binding backends only: the encoder surface the composite
    /// re-presents into, separate from the sampleable frame target.
    recording_window_target: ?render.Renderer.OffscreenTarget = null,
    /// Live-output surfaces, keyed by the caller's native texture pointer -
    /// the zero-copy broadcast path renders the composite straight into these
    /// instead of reading it back. Same slot shape as recording's.
    live_output_slots: std.AutoHashMapUnmanaged(usize, RecordingSlot) = .empty,
    /// The live surface the current frame renders into, once its wrap lands.
    live_output_target: ?render.Renderer.OffscreenTarget = null,
    live_output_requested: bool = false,
    /// Monotonic use counter live-output slots stamp on every render, so
    /// the eviction below always drops the stalest wrap.
    live_output_seq: u64 = 0,
    /// Every live session, registered at create and removed at destroy:
    /// destroying the engine destroys these first, so a host that forgets
    /// a session gets a clean teardown instead of a leak, and a session
    /// can never outlive the engine state it dereferences.
    sessions: std.ArrayListUnmanaged(*Session) = .empty,
    /// The platform window reference behind the renderer surface, held
    /// per engine so instances never alias. The binding that acquired it
    /// (Android's JNI layer) owns storing and releasing it; the core only
    /// carries the slot.
    attached_window: ?*anyopaque = null,
};

const WorldStore = struct {
    state: WorldState = .{ .tracking_state = 0, .world_from_camera = identity16, .projection = identity16, .timestamp_us = 0 },
    planes: [max_world_planes]WorldPlane = undefined,
    plane_count: usize = 0,
    anchors: [max_world_anchors]WorldAnchor = undefined,
    anchor_count: usize = 0,
    light: WorldLight = .{ .ambient_intensity = 0, .color_temperature_kelvin = 0 },
    dropped_planes: u32 = 0,
    dropped_anchors: u32 = 0,
};

const identity16 = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

// A unit octahedron the mesh-particle draw scales and places at each particle:
// six axis tips and the eight triangles joining a pole to the equator ring.
const octahedron_positions = [6][3]f32{
    .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 },
};
const octahedron_indices = [24]u32{
    4, 0, 2, 4, 2, 1, 4, 1, 3, 4, 3, 0,
    5, 2, 0, 5, 1, 2, 5, 3, 1, 5, 0, 3,
};

// A unit cube: eight corners and the two triangles of each of its six faces.
const cube_positions = [8][3]f32{
    .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 },
    .{ -1, -1, 1 },  .{ 1, -1, 1 },  .{ 1, 1, 1 },  .{ -1, 1, 1 },
};
const cube_indices = [36]u32{
    0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6,
    0, 4, 5, 0, 5, 1, 3, 2, 6, 3, 6, 7,
    0, 3, 7, 0, 7, 4, 1, 5, 6, 1, 6, 2,
};

// A unit tetrahedron: four corners and its four triangular faces.
const tetra_positions = [4][3]f32{
    .{ 1, 1, 1 }, .{ 1, -1, -1 }, .{ -1, 1, -1 }, .{ -1, -1, 1 },
};
const tetra_indices = [12]u32{ 0, 1, 2, 0, 3, 1, 0, 2, 3, 1, 3, 2 };

const RecordingSlot = struct {
    persistent: render.Renderer.PersistentTexture = .{},
    target: ?render.Renderer.OffscreenTarget = null,
    /// Engine.live_output_seq at last use; only live-output slots read it.
    last_used: u64 = 0,
};

/// Whether this target's recording backend vends sampleable textures
/// (Apple) or a platform window the composite renders straight into
/// (Android's encoder input surface).
const recording_binds_window = media_recording.native_handle_kind == .window;

const PendingRecordingFrame = struct {
    frame: media_recording.Frame,
    timestamp_us: i64,
};

const CurrentFrame = struct {
    desc: FrameDesc,
    preview: render.PreviewFrame,
    owns_textures: bool = true,
};

/// The active geofilter region: a circle, an axis-aligned box, or a polygon
/// ring the app derives from a lens's intended place. The engine tests a
/// submitted location against it on-device and only the boolean crosses.
pub const GeoRegion = union(enum) {
    circle: geo.Circle,
    bbox: geo.BBox,
    polygon: struct { verts: [geo.max_polygon_verts][2]f64, count: usize },

    fn contains(self: GeoRegion, lat: f64, lon: f64) bool {
        return switch (self) {
            .circle => |c| geo.withinCircle(lat, lon, c.lat, c.lon, c.radius_m),
            .bbox => |b| geo.withinBBox(lat, lon, b.min_lat, b.min_lon, b.max_lat, b.max_lon),
            .polygon => |p| geo.withinPolygon(lat, lon, p.verts[0..p.count]),
        };
    }
};

/// A particle node whose sim runs on the GPU: the compute buffers plus the
/// field the draw reads its colour and size from.
const GpuParticleNode = struct {
    sim: render.Renderer.GpuParticleSim,
    field: manifest.ParticleField,
};

/// A deferred mesh collider: the placement to build the body at once the
/// node's glb geometry finishes decoding.
const PendingGlbCollider = struct {
    position: [3]f32,
    rotation: [4]f32,
    friction: f32,
    restitution: f32,
};

pub const Session = struct {
    /// Engine-side audio analysis, fed by goss_session_submit_audio;
    /// once fed, its level and beat outrank the host's tick value.
    audio: audio_analysis.Analysis = .{},
    audio_engine_fed: bool = false,
    /// The platform's world understanding, fed by
    /// goss_session_submit_world; once fed, its tracking state
    /// outranks the host's tick value.
    world: WorldStore = .{},
    world_engine_fed: bool = false,
    /// The lens's rigid-body world, created at activation when any
    /// model node declares a body; poses drive those model matrices.
    physics_world: ?physics.World = null,
    physics_bodies: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    /// Mesh colliders whose geometry is the node's own glb: their body is built
    /// once the glb decodes, from the decoded positions, at these placements.
    pending_glb_colliders: std.AutoHashMapUnmanaged(graph.NodeIndex, PendingGlbCollider) = .empty,
    /// Dynamic bodies a pointer can grab, the currently grabbed one (driven
    /// kinematically to grab_target each tick), and where it is being dragged.
    grabbable_bodies: std.ArrayListUnmanaged(u32) = .empty,
    grab_body: ?u32 = null,
    grab_target: [3]f32 = .{ 0, 0, 0 },
    /// A kinematic collider the engine drives to the tracked head each physics
    /// tick, so lens content collides with the head.
    head_collider_body: ?u32 = null,
    /// Static colliders added live by a pointer, each its body id and where it
    /// sits, so an erase pass can remove the ones near a point.
    live_colliders: std.ArrayListUnmanaged(struct { id: u32, pos: [3]f32 }) = .empty,
    /// Cloth nodes: the solver body and the dynamic render mesh, by
    /// graph index. Cloth replaces the glb mesh with a simulated grid.
    cloth_bodies: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    cloth_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, render.Renderer.ClothMesh) = .empty,
    cloth_cols: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    /// Hair nodes: the solver hair id and its strand render mesh, by
    /// graph index. Hair is driven by the tracked head pose.
    hair_ids: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    hair_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, render.Renderer.HairMesh) = .empty,
    particle_systems: std.AutoHashMapUnmanaged(graph.NodeIndex, particles.System) = .empty,
    particle_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, render.Renderer.ParticleMesh) = .empty,
    /// A mesh-mode particle node's shared base octahedron, drawn once per
    /// particle at its position instead of a billboard.
    particle_base_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, render.Renderer.ModelMesh) = .empty,
    /// 2D SPH fluid nodes: the fluid sim and the shared base mesh each particle
    /// draws at its position, by graph index.
    fluid_sims: std.AutoHashMapUnmanaged(graph.NodeIndex, sph.Fluid) = .empty,
    fluid_base_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, render.Renderer.ModelMesh) = .empty,
    /// A ribbon-mode particle node's dynamic strip buffer, rebaked each frame
    /// from the trail history and drawn as one connected ribbon per particle.
    particle_ribbon_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, render.Renderer.ParticleMesh) = .empty,
    /// Particle nodes whose sim runs on the GPU compute path.
    gpu_particle_sims: std.AutoHashMapUnmanaged(graph.NodeIndex, GpuParticleNode) = .empty,
    /// A fading fountain's own sprite texture, loaded once at activation from
    /// assets/<stem>.png when the particles field names one.
    particle_sprite_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, render.TextureHandle) = .empty,
    /// A reusable buffer of tracked-landmark spawn points (particle world
    /// space) for the face emission pattern, refilled each frame.
    particle_emitter_buf: [96][3]f32 = undefined,
    hair_vcount: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    physics_last_us: i64 = 0,

    engine: *Engine,
    controller: graph.DegradeController,
    current: ?CurrentFrame = null,
    /// Zero-copy camera ingress rebinds these every submit rather than
    /// creating a fresh bgfx handle per frame - see
    /// render.Renderer.PersistentTexture.rebind for why.
    preview_bgra: render.Renderer.PersistentTexture = .{},
    preview_y: render.Renderer.PersistentTexture = .{},
    preview_uv: render.Renderer.PersistentTexture = .{},
    copied_frames: u64 = 0,
    /// Set for exactly one renderCompositeChain call by
    /// goss_engine_capture_frame, then cleared - redirects the chain's
    /// true final stage into engine.capture_target instead of the swap
    /// chain directly, with an extra blit afterward so the swap chain
    /// still gets the same frame a normal render would have produced.
    capture_requested: bool = false,
    /// Nonzero only during a still capture: the resolution the capture
    /// target and final composite rect use instead of the preview swap
    /// chain, so a still is not clamped to preview size.
    capture_res_width: u16 = 0,
    capture_res_height: u16 = 0,
    /// Set while compositing one tile of a capture whose full size exceeds
    /// the GPU's max texture size: the capture target is the tile's own
    /// size and the final full-screen pass samples only this tile's UV
    /// span, so the tiles stitch byte-identical to a single full render.
    capture_tile: ?render.Renderer.Tile = null,
    /// The full capture's aspect ratio, so a tiled 3D draw builds its
    /// perspective from the whole frame (the scene's aspect never changes
    /// per tile) and the sub-frustum crop selects the tile's slice.
    capture_aspect: f32 = 0,
    /// Overrides the tile size a still capture splits at; zero uses the
    /// 16384 texture-size floor. Only conformance sets it, to force
    /// tiling at a small resolution and prove the stitch is byte-identical.
    capture_tile_cap: u32 = 0,
    /// Forces the full-buffer capture path even when the streaming path
    /// would apply. Only conformance sets it, to compare peak memory of
    /// the two paths and prove streaming holds no full render buffer.
    capture_no_stream: bool = false,
    face_tracking: ?*tracking.Tracking = null,
    hand_tracking: ?*tracking.hand_worker.HandTracking = null,
    pose_tracking: ?*tracking.pose_worker.PoseTracking = null,
    /// While set, the tracked pose reports only the upper body: the lower-body
    /// joints (knees down) read absent, for selfie framing with the legs out.
    pose_upper_body: bool = false,
    segmentation_worker: ?*segmentation.Segmentation = null,
    /// Monotonic timestamp for still images fed to the segmenter through
    /// goss_session_submit_segmentation_image, so each submit orders after the
    /// last the way successive camera frames do.
    segmentation_image_seq: i64 = 0,
    /// The most recent mask, uploaded as a real GPU texture the same way
    /// a lut.pass asset is - a raw byte array has no reason to cross the
    /// frozen ABI surface when nothing outside the render thread ever
    /// needs it, and a 256x256 texture upload is far cheaper than
    /// copying the mask through it. Recreated (not reused) each time a
    /// fresh mask is ready, since bgfx's static textures are immutable.
    segmentation_texture: ?render.TextureHandle = null,
    /// The reused GPU mask textures behind the subject and per-class mattes
    /// and the depth mask: each poll updates its store in place rather than
    /// destroying and recreating a texture, freed once at session teardown.
    /// The handles above alias these stores, null only when a channel clears.
    seg_tex: render.Renderer.DynamicMask = .{},
    class_tex: [manifest.mask_channels.len]render.Renderer.DynamicMask = @splat(.{}),
    depth_tex: render.Renderer.DynamicMask = .{},
    beauty_chain: ?*beauty.Beauty = null,
    /// The GPU beauty compositing bridge: beauty_input writes the live
    /// preview into a platform-shared surface gpupixel reads zero-copy,
    /// beauty_interop reads gpupixel's own output back out the same
    /// way. Both lazily created the first time a lens with a beauty
    /// node actually runs with beauty enabled, torn down on disable or
    /// session destroy.
    beauty_input: ?*beauty.InputSurface = null,
    beauty_interop: ?*beauty.Interop = null,
    /// beauty_input's shared surface wrapped as a render target bgfx
    /// draws the current frame into, and beauty_interop's composited
    /// result wrapped as a plain sampled texture - both recreated only
    /// when the underlying native surface actually changes (a resize,
    /// or first creation), tracked by comparing against the native
    /// pointer last wrapped rather than assuming stability from size
    /// alone.
    beauty_input_target: ?render.Renderer.OffscreenTarget = null,
    beauty_input_native: ?*anyopaque = null,
    beauty_input_persistent: render.Renderer.PersistentTexture = .{},
    /// The bgfx texture wrapping the Android hardware buffer behind
    /// beauty_input_target - Vulkan-only, owned by the session (the Apple
    /// path's texture belongs to beauty_input_persistent instead), so it
    /// is destroyed on every replace and at teardown.
    beauty_input_android_texture: ?render.TextureHandle = null,
    /// Apple's beauty output handle - rebind every frame like camera
    /// ingress does, not cached-and-overridden-once like Android's below.
    beauty_output_persistent: render.Renderer.PersistentTexture = .{},
    beauty_output_texture: ?render.TextureHandle = null,
    beauty_output_native: ?*anyopaque = null,
    /// beauty.face/beauty.reshape/beauty.lipstick/beauty.blusher's own
    /// state on web, where there is no gpupixel beauty_chain to hold
    /// the six effect amounts or drive compositing - unused on every
    /// other target. Indices match core/lens/runtime.zig's EffectSlot
    /// (smooth, whiten, thin_face, big_eye, lipstick, blush); whiten is
    /// tracked but not yet applied (its four LUT textures aren't loaded
    /// on web yet).
    web_beauty_amounts: [6]f32 = @splat(0),
    /// Native mirror of the amounts goss_session_set_beauty has written
    /// into the gpupixel chain (same EffectSlot order) - the chain is
    /// opaque, so this is what lets beautyActive() see a direct set
    /// with no beauty-node lens active. Unused on web.
    beauty_amounts: [6]f32 = @splat(0),
    /// fs_blur_pass.sc's own two-pass scratch space (H then V) ahead of
    /// submitBeautyFace, plus beauty.reshape's own output target -
    /// sized and recreated the same lazy way ensureChainTargets already
    /// manages the lens chain's own targets.
    web_beauty_blur_h_target: ?render.Renderer.OffscreenTarget = null,
    web_beauty_mean_target: ?render.Renderer.OffscreenTarget = null,
    web_beauty_reshape_target: ?render.Renderer.OffscreenTarget = null,
    /// beauty.lipstick/beauty.blusher's own ping-pong pair: unlike every
    /// other pass here, a makeup draw only rasterizes its own mesh
    /// triangles, never a full-screen quad, so its background sample
    /// and its own write target can never be the same texture - lipstick
    /// reads whichever of these was blitted to first and writes the
    /// other, blush does the same starting from lipstick's output (or
    /// the blit target directly if lipstick is off).
    web_beauty_makeup_targets: [2]?render.Renderer.OffscreenTarget = .{ null, null },
    web_beauty_targets_width: u16 = 0,
    web_beauty_targets_height: u16 = 0,
    /// beauty.face's whiten effect reads these four - gray, origin,
    /// skin, and custom, matching gpupixel's own beauty_face_unit_
    /// filter.cc lookup set. Uploaded via goss_session_set_beauty_lut, a
    /// caller's own PNG decode (a browser's native one, most likely -
    /// there is no decoder wired into this build for web) handed in as
    /// raw RGBA; whiten stays inert until all four are loaded.
    web_beauty_lut_textures: [4]?render.TextureHandle = @splat(null),
    /// beauty.lipstick/beauty.blusher's own source images (gpupixel's
    /// mouth.png/blusher.png) - uploaded via goss_session_set_beauty_
    /// makeup_texture the same caller-decodes-the-PNG way the whiten
    /// LUTs are. An effect stays inert until its own texture loads,
    /// same rule as whiten's four.
    web_beauty_lipstick_texture: ?render.TextureHandle = null,
    web_beauty_blush_texture: ?render.TextureHandle = null,
    /// beauty.reshape/beauty.lipstick/beauty.blusher's face contour on
    /// web, set directly by the caller via goss_session_set_face_landmarks
    /// - the internal tracking worker s.face_tracking drives everywhere
    /// else is permanently unavailable here (goss_session_enable_face_
    /// tracking reports unsupported on this target), so there is no
    /// other way for a landmark-driven web effect to ever see a face.
    /// Null means no face this frame, the same meaning a zero
    /// landmark_count carries elsewhere.
    web_face_landmarks: ?[face.landmark_count]face.Landmark = null,
    /// Faces the host submitted this frame, the source of truth for the
    /// multi-face read ops and the render fan-out. face_count is how many
    /// slots hold a real face; zero leaves the single-face tracker owning
    /// the anchor render, so a one-face lens never regresses.
    face_results: [face.max_faces]face.Result = @splat(std.mem.zeroes(face.Result)),
    face_count: u32 = 0,
    body_results: [pose.max_bodies]pose.Result = @splat(std.mem.zeroes(pose.Result)),
    body_count: u32 = 0,
    /// The most recent host-submitted depth map (metres per pixel, row
    /// major) with its plane size and near/far range, kept for depth
    /// occlusion. Empty until a frame arrives.
    depth_data: []f32 = &.{},
    depth_width: u32 = 0,
    depth_height: u32 = 0,
    depth_near: f32 = 0,
    depth_far: f32 = 0,
    /// The submitted depth normalized into an R8 texture the dof.pass
    /// samples, refreshed each submit_depth. Null until depth arrives.
    depth_texture: ?render.TextureHandle = null,
    /// Reused scratch for normalizing depth into R8 bytes, sized alongside
    /// depth_data, freed at destroy - submit_depth never allocates it.
    depth_scratch: []u8 = &.{},
    /// Per-frame vertex staging for the composite chain's dynamic meshes
    /// (particles, ribbons, fluid, hair, cloth). Grown to the largest mesh
    /// at lens activation, sliced fresh each frame, freed at destroy.
    frame_stage: []f32 = &.{},
    /// dof.pass nodes by graph index: their focus plane and blur strength.
    dof_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [2]f32) = .empty,
    /// fog.pass nodes by graph index: their fog color (rgb) and density.
    fog_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [4]f32) = .empty,
    /// outline.pass nodes by graph index: their line color (rgb) and threshold.
    outline_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [4]f32) = .empty,
    /// outline.pass nodes that trace a mask channel's edge instead of depth,
    /// by graph index, holding the channel (0 person, else a class).
    outline_masks: std.AutoHashMapUnmanaged(graph.NodeIndex, u8) = .empty,
    /// tint.pass nodes by graph index: their color (rgb) and opacity.
    tint_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [4]f32) = .empty,
    /// tint.pass nodes' mask channel by graph index (0 person, else a class).
    tint_masks: std.AutoHashMapUnmanaged(graph.NodeIndex, u8) = .empty,
    /// tint.pass nodes' blend mode by graph index: 0 normal blend, 1 multiply
    /// (contour darken), 2 screen (highlight lighten). Absent reads as normal.
    tint_modes: std.AutoHashMapUnmanaged(graph.NodeIndex, u8) = .empty,
    /// tint.pass nodes' finish by graph index: 1 gloss, 2 shimmer, 3 metallic.
    /// Absent reads as matte, the flat blend, so the effect is byte-identical.
    tint_finishes: std.AutoHashMapUnmanaged(graph.NodeIndex, u8) = .empty,
    /// tint.pass nodes whose color comes from the makeup reference, not the
    /// static field, by graph index.
    tint_reference: std.AutoHashMapUnmanaged(graph.NodeIndex, void) = .empty,
    /// Per-face-part color sampled from a reference photo by
    /// goss_session_set_makeup_reference; a reference-sourced tint.pass reads
    /// its channel's entry instead of a static color. null until set.
    makeup_reference: [manifest.mask_channels.len]?[3]f32 = @splat(null),
    /// smooth.pass nodes by graph index: their retouch amount.
    smooth_params: std.AutoHashMapUnmanaged(graph.NodeIndex, f32) = .empty,
    /// smooth.pass nodes' mask channel by graph index (0 person, else a class).
    smooth_masks: std.AutoHashMapUnmanaged(graph.NodeIndex, u8) = .empty,
    /// matte.refine nodes by graph index: their guided-filter parameters
    /// (radius, sensitivity, strength).
    matte_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [3]f32) = .empty,
    /// matte.refine nodes that refine a mask channel's matte instead of the
    /// submitted depth, by graph index (0 person, else a class).
    matte_masks: std.AutoHashMapUnmanaged(graph.NodeIndex, u8) = .empty,
    /// stylize.pass nodes by graph index: their artistic filter packed for
    /// u_stylize (mode, strength, threshold, levels), resolved at activation.
    stylize_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [4]f32) = .empty,
    /// edge.pass nodes by graph index: their detector packed as (mode, low,
    /// high, blur_radius, strength, invert), resolved at activation.
    edge_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [6]f32) = .empty,
    /// warp.pass nodes by graph index: their distortion packed as (mode,
    /// center_x, center_y, radius, strength, refractive_index, aspect_auto, 0),
    /// resolved at activation.
    warp_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [8]f32) = .empty,
    /// reshape.bank nodes by graph index: their sixty-six per-region sculpt
    /// amounts in ReshapeField order, resolved at activation. The live tracked
    /// contour joins them each frame in the draw arm.
    reshape_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [66]f32) = .empty,
    /// ssr.pass nodes by graph index: their reflection strength and floor plane.
    ssr_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [2]f32) = .empty,
    /// env.pass nodes by graph index: their sky gradient (top rgb, bottom rgb)
    /// and intensity, seven floats in that order.
    env_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [7]f32) = .empty,
    /// trail.pass nodes by graph index: their motion-trail echo amount.
    trail_params: std.AutoHashMapUnmanaged(graph.NodeIndex, f32) = .empty,
    /// The previous composited frame a trail.pass echoes, held across frames
    /// and re-copied each frame; sized to the frame and null until a trail
    /// node draws. `prev_frame_valid` gates the first frame (no echo yet).
    prev_frame_target: ?render.Renderer.OffscreenTarget = null,
    prev_frame_w: u16 = 0,
    prev_frame_h: u16 = 0,
    prev_frame_valid: bool = false,
    lens_graph: graph.Graph,
    camera_node: graph.NodeIndex,
    active_lens: ?runtime.Lens = null,
    /// The active lens's script driver, when it has a script node, plus the
    /// null-terminated parameter names it exchanges each tick. Both are built
    /// at activation and torn down at deactivation, never per frame.
    script_engine: ?script.Script = null,
    script_param_names: []const [:0]const u8 = &.{},
    /// The lens's sound mixer and the mixer id each play_sound path resolves
    /// to, built from the bundle at activation. Playback is pulled out by the
    /// SDK; the engine only decodes and mixes.
    audio_mixer: ?audio_playback.Mixer = null,
    sound_ids: std.StringHashMapUnmanaged(u32) = .{},
    /// Keeps the lens-to-outgoing-track resampler continuous across
    /// goss_session_mix_output_audio calls when the outgoing rate differs
    /// from the mixer's 48 kHz.
    mix_resampler: audio_mix.Resampler = .{},
    /// The caller's normalized camera-hardware intent (validated at set-time);
    /// the SDK reads it back and drives the platform camera. Inline POD.
    camera_controls: CameraControls = .{},
    /// One-tick pulses set when set_camera_controls changes the focus or
    /// exposure, so a lens fires once on the change. Cleared every tick, on both
    /// the active-lens and no-lens paths, so a change made before a lens loads
    /// does not fire a stale trigger on the first tick after it does.
    cam_focus_pulse: bool = false,
    cam_exposure_pulse: bool = false,
    /// Recent head-pose euler samples for the head-movement gesture detector,
    /// a fixed ring fed at tick from the tracked face. The pose is computed and
    /// scanned on-device; only the nod/shake/tilt edges reach a lens.
    head_samples: [head_pose_history]HeadSample = @splat(.{}),
    head_write: usize = 0,
    head_clock_us: i64 = 0,
    head_nod_refractory_us: i64 = 0,
    head_shake_refractory_us: i64 = 0,
    /// Recent body-motion samples for the jump/wave/dance detectors, a fixed
    /// ring fed at tick from the tracked pose; only the action edges reach a lens.
    body_samples: [body_history]BodySample = @splat(.{}),
    body_write: usize = 0,
    body_clock_us: i64 = 0,
    body_jump_refractory_us: i64 = 0,
    body_wave_refractory_us: i64 = 0,
    /// The current bone bend angles, filled at tick from the pose worker so a
    /// lens can compare one by name; the signal points here until the next tick.
    bone_angles: [pose.bone_count]f32 = @splat(0),
    /// The recording policy and capture-UI intent the SDK applies: the engine
    /// validates and stores them, never touching the recorder or drawing the UI.
    recording_policy: RecordingPolicy = .{},
    capture_ui: CaptureUiIntent = .{},
    /// Host-fired event names buffered until the next tick, where they reach
    /// the trigger rail for exactly one tick and then clear. Fixed-size, so
    /// firing an event allocates nothing.
    pending_event_buf: [max_pending_events][max_event_name]u8 = undefined,
    pending_event_len: [max_pending_events]u8 = undefined,
    pending_event_count: u8 = 0,
    /// Named RGBA sources for multi-source composition (Duet/Stitch, live
    /// grids), in definition order; the camera is the implicit source 0. Fixed
    /// arrays so the frame-path composite walks them without a hashmap.
    source_names: [comp.max_sources][max_source_name]u8 = undefined,
    source_name_len: [comp.max_sources]u8 = @splat(0),
    source_tex: [comp.max_sources]render.Renderer.PersistentTexture = @splat(.{}),
    source_dims: [comp.max_sources][2]u16 = @splat(.{ 0, 0 }),
    source_has_frame: [comp.max_sources]bool = @splat(false),
    source_count: u8 = 0,
    /// Per-source composite blend the layout draws with: opacity, key mode
    /// (0 none, 1 matte from the source alpha, 2 chroma-key), the chroma key
    /// color and its match softness, and whether the source letterboxes to fit
    /// its cell (a screen share) rather than filling it.
    source_opacity: [comp.max_sources]f32 = @splat(1),
    source_key: [comp.max_sources]u8 = @splat(0),
    source_chroma: [comp.max_sources][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    source_softness: [comp.max_sources]f32 = @splat(0.1),
    source_fit: [comp.max_sources]bool = @splat(false),
    /// The camera (composite placement 0) carries the same blend, so a lens can
    /// chroma-key the live camera over a guest.
    camera_opacity: f32 = 1,
    camera_key: u8 = 0,
    camera_chroma: [4]f32 = .{ 0, 0, 0, 0 },
    camera_softness: f32 = 0.1,
    /// Set when the active lens's layout.composite node drove the layout, so
    /// deactivating the lens clears it rather than leaving a host arrangement.
    layout_from_lens: bool = false,
    layout_active: ?comp.Layout = null,
    /// The last submitted location fix and the session's active geofence. The
    /// engine computes geo.in_region on-device from these; the location itself
    /// never crosses back over the ABI.
    location_lat: f64 = 0,
    location_lon: f64 = 0,
    location_accuracy_m: f32 = 0,
    location_engine_fed: bool = false,
    geofence: ?GeoRegion = null,
    /// The worst fix accuracy that still counts as inside a region. Zero means no
    /// gate: any fix is trusted. A fix reporting a larger radius reads outside.
    geo_required_accuracy_m: f32 = 0,
    /// The draw and AR-brush board. The engine owns stroke state and undo/redo;
    /// goss_session_brush_vertices reads the finished ribbon for the renderer.
    brush: stroke.Board = .{},
    /// World-anchored strokes and the screen-space board they project into each
    /// frame. The AR brush stores points in world space; the render path
    /// projects them through the camera pose and draws them like the screen
    /// brush, so they stay put in the scene as the camera moves.
    ar_board: wboard.WorldBoard = .{},
    ar_projected: stroke.Board = .{},
    /// One bgfx program per currently-spliced shader.pass node, keyed by
    /// its graph index. Created at activation (goss_session_activate_lens_
    /// from_directory only - the bytes-based activate has no bundle path
    /// to read compiled shaders from), destroyed on deactivation.
    shader_programs: std.AutoHashMapUnmanaged(graph.NodeIndex, u16) = .empty,
    /// shader.pass nodes that named a mask channel, by graph index -
    /// filled at directory activation alongside the programs.
    shader_masks: std.AutoHashMapUnmanaged(graph.NodeIndex, u8) = .empty,
    /// One uploaded texture per named mask channel in use; index 0
    /// (person) aliases segmentation_texture and stays null here.
    segmentation_class_textures: [manifest.mask_channels.len]?render.TextureHandle = @splat(null),
    /// Every shader.pass and lut.pass node the active lens spliced, in
    /// one real draw-order sequence (runtime.Lens.compositePassNodes) -
    /// built once at directory-based activation regardless of whether
    /// each entry's resource (a program, a texture) is ready yet, since
    /// a lut.pass node's load can still be in flight the same frame its
    /// chain position is already known. Owned, rebuilt every
    /// activation, freed on teardown.
    chain_order: []runtime.CompositePass = &.{},
    /// One background loader per currently-spliced lut.pass node still
    /// waiting on its LUT image, keyed by graph index. Started at
    /// activation (directory-based only, same reason as shader_programs
    /// above), removed once goss_engine_render_frame's poll turns its
    /// result into a real texture or observes it failed.
    lut_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ImageLoader) = .empty,
    /// One bgfx texture per lut.pass node whose asset finished loading.
    lut_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, render.TextureHandle) = .empty,
    /// One background loader per currently-spliced blend.pass node still
    /// waiting on its background image - mirrors lut_loaders exactly,
    /// one node type over.
    blend_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ImageLoader) = .empty,
    /// One bgfx texture per blend.pass node whose background finished
    /// loading.
    blend_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, render.TextureHandle) = .empty,
    /// One equirect loader per env.pass node that ships an environment image,
    /// still in flight - mirrors blend_loaders. A node with no image (or a
    /// load that fails) simply falls back to the gradient sky.
    env_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ImageLoader) = .empty,
    /// One bgfx texture per env.pass node whose equirect image finished
    /// loading, sampled by the camera pose instead of the gradient.
    env_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, render.TextureHandle) = .empty,
    /// The color adjustment of each spliced grade.pass node, packed as
    /// three vec4 (tone, white balance with hue, then posterize and
    /// invert) - resolved once at activation since grade.pass ships no
    /// asset and needs no loader.
    grade_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [12]f32) = .empty,
    /// The glow of each spliced bloom.pass node, packed as (threshold,
    /// intensity, 0, 0) - resolved once at activation like grade_params.
    bloom_params: std.AutoHashMapUnmanaged(graph.NodeIndex, [4]f32) = .empty,
    mesh_face_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ImageLoader) = .empty,
    mesh_face_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, render.TextureHandle) = .empty,
    /// sprite.2d nodes: the image load in flight, its resolved texture, and
    /// the normalized rect+opacity {x,y,w,h,opacity} the node draws at.
    sprite_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ImageLoader) = .empty,
    sprite_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, render.TextureHandle) = .empty,
    sprite_rects: std.AutoHashMapUnmanaged(graph.NodeIndex, [5]f32) = .empty,
    /// Extruded 3D text nodes: the glyph block mesh and its color, drawn via
    /// the model path, by graph index.
    text3d_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, struct { mesh: render.Renderer.ModelMesh, color: [4]f32 }) = .empty,
    /// video.texture nodes: the streaming decoder, the dynamic texture its
    /// frames upload into, and the playback cursor, by graph index. Drawn in
    /// the sprite branch like an animated sprite, one decoded frame at a time.
    video_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, VideoPlayback) = .empty,
    /// A sprite/text node's opacity parameter name (a slice into the lens
    /// manifest arena), when it binds one, so the draw reads a live opacity.
    sprite_opacity_params: std.AutoHashMapUnmanaged(graph.NodeIndex, []const u8) = .empty,
    /// An animated sprite's frame state, when it declares frames > 1: the
    /// per-frame loads in flight, the textures they land in, and the rate
    /// the draw cycles them at off the lens clock.
    sprite_anims: std.AutoHashMapUnmanaged(graph.NodeIndex, SpriteAnim) = .empty,
    /// model.gltf nodes anchored to the tracked face, by graph index.
    model_face_anchors: std.AutoHashMapUnmanaged(graph.NodeIndex, void) = .empty,
    model_body_anchors: std.AutoHashMapUnmanaged(graph.NodeIndex, void) = .empty,
    model_skeleton_anchors: std.AutoHashMapUnmanaged(graph.NodeIndex, void) = .empty,
    /// model.gltf nodes anchored to the tracked world, by graph index.
    model_world_anchors: std.AutoHashMapUnmanaged(graph.NodeIndex, void) = .empty,
    /// One background loader per currently-spliced model.gltf node
    /// still waiting on its .glb - mirrors lut_loaders/blend_loaders,
    /// one node type over.
    model_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ModelLoader) = .empty,
    /// One loaded model per model.gltf node whose .glb finished
    /// loading: the gpu mesh plus the plain animation-sampling data
    /// pollModelLoaders keeps around (not a bgfx resource, so it lives
    /// here rather than inside render.Renderer).
    model_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, LoadedModel) = .empty,
};

/// A model.gltf node's loaded state: real gpu buffers plus the plain
/// CPU-side animation data renderCompositeChain samples every frame at
/// the lens's own reported elapsed time.
/// Where a skin joint reads its world position from the tracked body:
/// one pose landmark, the mean of two (hip or shoulder centre), or none
/// for a joint whose name matched nothing, which holds its bind pose.
const JointTarget = union(enum) {
    none,
    point: u8,
    midpoint: [2]u8,
};

/// The per-model state a skinned body mesh deforms against every frame:
/// the parsed skin, a kept copy of the bind positions, scratch for the
/// skinned output, the joint palette, and each joint's landmark target.
const SkinnedRig = struct {
    mesh: render.Renderer.SkinnedMesh,
    skin: gltf.DecodedSkin,
    rest: [][3]f32,
    skinned: [][3]f32,
    palette: []math.Mat4,
    joint_targets: []JointTarget,
};

/// The most clips one model node blends in a frame. A model with more
/// clips than this keeps them all decoded, but only the first this many
/// contribute to the blended pose - far above any real rig's clip count.
const max_blend_clips = 16;

/// The most morph targets one model node blends in a frame; only the
/// first this many carry a weight. Above the 52 an ARKit face rig uses.
const max_morph_targets = 64;

const LoadedModel = struct {
    mesh: render.Renderer.ModelMesh,
    base_color: [4]f32,
    animations: []gltf.DecodedAnimation,
    rig: ?SkinnedRig = null,
    /// Per-vertex position deltas, one array per morph target, kept so a
    /// lens can blend them into the mesh by weight. Empty for a mesh with
    /// no blendshapes.
    morph_targets: []const []const [3]f32 = &.{},
    /// A morphable mesh keeps its rest positions and a scratch buffer to
    /// deform into each frame; its `mesh` is a dynamic model mesh. Both
    /// empty for a mesh with no morph targets.
    morph_rest: []const [3]f32 = &.{},
    morph_scratch: [][3]f32 = &.{},
};

/// Deforms rest positions by a weighted sum of morph target deltas into
/// `out`: out[v] = rest[v] + sum_t weight[t] * target[t][v]. Weights come
/// from the lens; a zero weight leaves that target out at no cost.
fn morphPositions(out: [][3]f32, rest: []const [3]f32, targets: []const []const [3]f32, weights: []const f32) void {
    for (out, rest) |*o, base| o.* = base;
    for (targets, weights) |target, w| {
        if (w == 0) continue;
        for (out, target) |*o, delta| {
            o[0] += w * delta[0];
            o[1] += w * delta[1];
            o[2] += w * delta[2];
        }
    }
}

/// The model node's local matrix this frame: its clips' sampled poses
/// blended by their bound weights (clip_weights). With none bound the
/// first clip carries full weight, so a single-clip model is unchanged;
/// a model with no clips draws on its rest transform.
fn modelPoseMatrix(loaded: LoadedModel, elapsed_seconds: f32, lens: ?*const runtime.Lens, graph_index: graph.NodeIndex) math.Mat4 {
    if (loaded.animations.len == 0) return math.Mat4.identity;
    const bound = if (lens) |l| l.bindsClipWeights(graph_index) else false;
    if (!bound and loaded.animations.len == 1) return loaded.animations[0].sample(elapsed_seconds);
    var poses: [max_blend_clips]gltf.Components = undefined;
    var weights: [max_blend_clips]f32 = undefined;
    const n = @min(loaded.animations.len, max_blend_clips);
    for (0..n) |ci| {
        poses[ci] = loaded.animations[ci].sampleComponents(elapsed_seconds);
        weights[ci] = if (bound) (lens.?.clipWeight(graph_index, ci) orelse 0) else (if (ci == 0) @as(f32, 1.0) else 0.0);
    }
    return gltf.blendComponents(poses[0..n], weights[0..n]).toMatrix();
}

fn abiAllocator() std.mem.Allocator {
    // wasm_allocator grows memory through a raw wasm memory.grow
    // instruction, invisible to Emscripten's own JS-side heap-view
    // tracking - real growth still happens, but any cached HEAP32/
    // HEAPU8 view the JS side is holding across the call goes stale
    // without Emscripten's own growth hook ever firing to refresh it
    // (confirmed: a plain _malloc-triggered growth refreshes correctly,
    // an allocation through here does not). Emscripten provides a real
    // libc malloc that coordinates that refresh correctly; freestanding
    // (the other wasm target this file compiles for) has no libc at
    // all, so it keeps wasm_allocator, the only option there.
    if (is_web) return std.heap.c_allocator;
    if (builtin.cpu.arch.isWasm()) return std.heap.wasm_allocator;
    if (builtin.single_threaded) return std.heap.page_allocator;
    return std.heap.smp_allocator;
}

fn clampCapacity(requested: u32, default: u32) u16 {
    const value = if (requested == 0) default else requested;
    return @intCast(@min(value, std.math.maxInt(u16)));
}

pub fn createEngine(gpa: std.mem.Allocator, config: EngineConfig) error{OutOfMemory}!*Engine {
    const engine = try gpa.create(Engine);
    engine.* = .{
        .gpa = gpa,
        .texture_pool = graph.Pool.init(gpa),
        .staging_pool = graph.Pool.init(gpa),
        .texture_pool_capacity = clampCapacity(config.texture_pool_capacity, default_texture_pool_capacity),
        .staging_pool_capacity = clampCapacity(config.staging_pool_capacity, default_staging_pool_capacity),
    };
    return engine;
}

pub fn destroyEngine(engine: *Engine) void {
    // Live sessions go first: every session teardown dereferences the
    // engine (allocator, renderer, recording), so the reverse order is a
    // use-after-free. destroySession unregisters itself from this list.
    while (engine.sessions.items.len > 0) {
        destroySession(engine.sessions.items[engine.sessions.items.len - 1]);
    }
    engine.sessions.deinit(engine.gpa);
    if (engine.recording != null) _ = finishRecording(engine);
    for (engine.chain_targets) |slot| {
        if (slot) |target| render.Renderer.destroyOffscreenTarget(target);
    }
    for (engine.bloom_targets) |slot| {
        if (slot) |target| render.Renderer.destroyOffscreenTarget(target);
    }
    for (engine.edge_targets) |slot| {
        if (slot) |target| render.Renderer.destroyOffscreenTarget(target);
    }
    if (engine.capture_target) |target| render.Renderer.destroyOffscreenTarget(target);
    if (engine.capture_staging) |staging| {
        if (engine.renderer) |*r| r.destroyTexture(staging);
    }
    var live_it = engine.live_output_slots.valueIterator();
    while (live_it.next()) |slot| {
        if (slot.target) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.persistent.deinit();
    }
    engine.live_output_slots.deinit(engine.gpa);
    if (engine.capture_convert.len > 0) engine.gpa.free(engine.capture_convert);
    if (engine.renderer) |*r| r.deinit();
    engine.texture_pool.deinit();
    engine.staging_pool.deinit();
    engine.gpa.destroy(engine);
}

/// (Re)creates both ping-pong chain targets when the frame size changes
/// or they don't exist yet - never per frame once a size is stable, so
/// the render path itself allocates nothing.
fn ensureChainTargets(e: *Engine, width: u16, height: u16) !void {
    if (e.chain_width == width and e.chain_height == height and e.chain_targets[0] != null) return;
    // Each slot is nulled between destroy and create, so a failed create
    // leaves null in the slot rather than a destroyed handle a later
    // render or teardown would use again.
    for (&e.chain_targets) |*slot| {
        if (slot.*) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.* = null;
        slot.* = try render.Renderer.createOffscreenTarget(width, height);
    }
    for (&e.bloom_targets) |*slot| {
        if (slot.*) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.* = null;
        slot.* = try render.Renderer.createOffscreenTarget(width, height);
    }
    for (&e.edge_targets) |*slot| {
        if (slot.*) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.* = null;
        slot.* = try render.Renderer.createOffscreenTarget(width, height);
    }
    e.chain_width = width;
    e.chain_height = height;
}

fn ensureCaptureTarget(e: *Engine, width: u16, height: u16) !void {
    if (e.capture_width == width and e.capture_height == height and e.capture_target != null and e.capture_staging != null) return;
    if (e.capture_target) |target| render.Renderer.destroyOffscreenTarget(target);
    e.capture_target = null;
    if (e.capture_staging) |staging| {
        if (e.renderer) |*r| r.destroyTexture(staging);
    }
    e.capture_staging = null;
    const target = try render.Renderer.createOffscreenTarget(width, height);
    errdefer render.Renderer.destroyOffscreenTarget(target);
    e.capture_staging = try render.Renderer.createReadbackTexture(width, height);
    e.capture_target = target;
    e.capture_width = width;
    e.capture_height = height;
}

/// (Re)creates the session-owned previous-frame target a trail.pass echoes,
/// only when the frame size changes or it doesn't exist yet. A resize drops
/// the stale echo (prev_frame_valid=false) so the next frame reseeds instead
/// of stretching a mismatched copy across the new size.
fn ensureTrailPrev(s: *Session, width: u16, height: u16) !void {
    if (s.prev_frame_w == width and s.prev_frame_h == height and s.prev_frame_target != null) return;
    if (s.prev_frame_target) |target| render.Renderer.destroyOffscreenTarget(target);
    s.prev_frame_target = null;
    s.prev_frame_target = try render.Renderer.createOffscreenTarget(width, height);
    s.prev_frame_w = width;
    s.prev_frame_h = height;
    s.prev_frame_valid = false;
}

/// Whether the live preview needs the GPU beauty compositing bridge
/// running this frame: an active lens with beauty nodes, or any direct
/// nonzero setBeauty amount - the same two sources webBeautyActive
/// already honors, so a slider works with no lens active on native too.
fn beautyActive(s: *const Session) bool {
    if (s.beauty_chain == null) return false;
    if (s.active_lens) |lens| {
        if (lens.hasBeautyNodes()) return true;
    }
    for (s.beauty_amounts) |amount| {
        if (amount > 0.0) return true;
    }
    return false;
}

/// Runs the beauty chain over the frame the PREVIOUS call wrote into the
/// shared surface, returns that as the composited result, then queues
/// this frame's own camera content into the same surface for the next
/// call to read - one frame of latency, and the reason this is
/// structured read-then-write rather than write-then-read. bgfx only
/// actually executes a queued draw (the write below) when this frame's
/// own bgfx_frame() call runs, at the end of goss_engine_render_frame,
/// strictly after this function returns; reading the surface for
/// content this same call just queued would race a Metal write that has
/// not happened on the GPU yet. Reading what a fully-executed PRIOR
/// frame wrote is what makes the cross-API bridge (Metal write, GL
/// read) correct without forcing a synchronous GPU stall every frame -
/// the CPU roundtrip goss_session_beautify_frame already accepts a much
/// larger per-frame cost than one frame of latency ever could.
///
/// The live-preview integration goss_session_beautify_frame's own doc
/// comment names as this row's device-side counterpart. Draws into its
/// own dedicated, platform-shared target rather than the ping-pong pair
/// the rest of the chain shares, since that target has to stay backed
/// by the same native surface gpupixel reads zero-copy on its own
/// thread; consumes exactly one view id, reserved by the caller in
/// next_view_id before any chain_order stage claims one. Degrades to
/// returning input_texture unchanged if any step fails - the SPEC's
/// rule for a node whose capability is unavailable holding its default
/// state, same as blend.pass's mask.
fn applyBeautyCompositing(r: *render.Renderer, s: *Session, next_view_id: *u8, width: u16, height: u16, rotation: u32, mirror: bool, input_texture: render.TextureHandle) render.TextureHandle {
    const chain = s.beauty_chain.?;

    // Android's GLES fallback has no route from the composited buffer
    // back into bgfx (the Metal-view bridge is apple-only, the
    // AHardwareBuffer import needs Vulkan) - running the chain there
    // burns a full gpupixel pass per frame nothing can ever display.
    if (is_android and !r.isAndroidVulkan()) return input_texture;

    const input_surface = s.beauty_input orelse blk: {
        const created = beauty.inputSurfaceCreate(s.engine.gpa) catch return input_texture;
        s.beauty_input = created;
        break :blk created;
    };
    const interop = s.beauty_interop orelse blk: {
        const created = beauty.interopCreate(s.engine.gpa) catch return input_texture;
        s.beauty_interop = created;
        break :blk created;
    };

    // null device on GLES: a context is implicit and thread-bound,
    // nothing to hand across this boundary - Metal needs one, GLES
    // ignores it.
    const android_vulkan = r.isAndroidVulkan();
    const device = r.nativeDevice();
    const native_texture = if (android_vulkan)
        beauty.inputSurfaceHardwareBuffer(input_surface, width, height) orelse return input_texture
    else
        beauty.inputSurfaceNativeTexture(input_surface, device, width, height) orelse return input_texture;

    const target_has_a_prior_write = s.beauty_input_target != null and s.beauty_input_native == native_texture;
    if (!target_has_a_prior_write) {
        if (s.beauty_input_target) |old| render.Renderer.destroyOffscreenTarget(old);
        s.beauty_input_target = null;
        // Every preview resize lands here on Android Vulkan; the wrap the
        // replaced target sampled goes with it or one VkImage leaks per resize.
        if (s.beauty_input_android_texture) |old_tex| r.destroyTexture(old_tex);
        s.beauty_input_android_texture = null;
        // May legitimately fail the very first time a given native
        // surface is wrapped: the underlying bgfx texture's own
        // creation is queued, not immediate, and nothing has forced it
        // to actually process yet this frame. Leaving beauty_input_
        // native unset here means the next call retries the whole wrap
        // rather than caching a handle that never resolved.
        const wrapped = if (android_vulkan)
            r.createAndroidBeautyRenderTarget(width, height, native_texture) orelse return input_texture
        else
            r.wrapExternalRenderTarget(&s.beauty_input_persistent, width, height, render.c.BGFX_TEXTURE_FORMAT_BGRA8, @intFromPtr(native_texture)) orelse return input_texture;
        s.beauty_input_target = render.Renderer.createExternalTarget(wrapped) catch {
            // android's handle is this call's own to destroy; the
            // persistent one beauty_input_persistent owns survives to
            // retry next frame instead of dangling under it.
            if (android_vulkan) r.destroyTexture(wrapped);
            return input_texture;
        };
        if (android_vulkan) s.beauty_input_android_texture = wrapped;
        s.beauty_input_native = native_texture;
    }

    var beautified = input_texture;
    if (target_has_a_prior_write) {
        var result: face.Result = undefined;
        var tracked: ?*const face.Result = null;
        if (s.face_tracking) |worker| {
            if (tracking.readResult(worker, &result)) tracked = &result;
        }
        const processed = beauty.processTexture(input_surface, chain, width, height, rotation, mirror, tracked);
        if (processed) {
            const composited = beauty.composite(interop, chain, width, height);
            if (composited) |c| {
                if (android_vulkan) {
                    if (s.beauty_output_texture == null or s.beauty_output_native != c) {
                        if (s.beauty_output_texture) |old| r.destroyTexture(old);
                        s.beauty_output_texture = r.wrapAndroidBeautyOutput(width, height, c);
                        s.beauty_output_native = c;
                    }
                    if (s.beauty_output_texture) |output| beautified = output;
                } else if (beauty.interopNativeTexture(interop, device)) |metal_texture| {
                    // metal_texture's override needs a frame gap to land,
                    // same as camera ingress - rebind every frame rather
                    // than caching a still-pending one.
                    beautified = s.beauty_output_persistent.rebind(width, height, render.c.BGFX_TEXTURE_FORMAT_BGRA8, @intFromPtr(metal_texture));
                }
            }
        }
    }

    const view_id = next_view_id.*;
    next_view_id.* += 1;
    render.Renderer.setViewTarget(view_id, s.beauty_input_target.?, width, height);
    r.submitShaderPass(view_id, r.passthroughProgram(), input_texture, r.default_mask_texture);

    return beautified;
}

/// Whether beauty.face or beauty.reshape has anything to actually draw
/// this frame on web - whiten alone only counts once its four LUT
/// textures have loaded (goss_session_set_beauty_lut), lipstick/blush
/// aren't wired (a mesh draw, not a full-screen pass like these two).
fn webBeautyActive(s: *const Session) bool {
    if (!is_web) return false;
    const smooth = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.smooth)];
    const whiten = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.whiten)];
    const thin_face = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.thin_face)];
    const big_eye = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.big_eye)];
    const lipstick = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.lipstick)];
    const blush = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.blush)];
    const luts_loaded = for (s.web_beauty_lut_textures) |slot| {
        if (slot == null) break false;
    } else true;
    return smooth > 0.0 or thin_face > 0.0 or big_eye > 0.0 or (whiten > 0.0 and luts_loaded) or
        (lipstick > 0.0 and s.web_beauty_lipstick_texture != null) or (blush > 0.0 and s.web_beauty_blush_texture != null);
}

/// The one beauty-active check every caller should reach through -
/// native's gpupixel chain on every other target, web_beauty_amounts
/// here. goss_engine_render_frame's own fast-path gate and
/// renderCompositeChain's chain dispatch both need this, and both once
/// called beautyActive() directly - a real bug, not hypothetical: with
/// no lens active (chain_order empty), render_frame's own gate skipped
/// renderCompositeChain (and therefore applyWebBeautyChain) entirely on
/// web, silently rendering the plain passthrough preview regardless of
/// what web_beauty_amounts held. Caught by an actual browser proof
/// (whiten toggled with real LUTs loaded, zero visible change), not by
/// any Zig-level test - anyBeautyActive exists so the two call sites
/// can't drift apart again the same way.
fn anyBeautyActive(s: *const Session) bool {
    return if (is_web) webBeautyActive(s) else beautyActive(s);
}

fn ensureWebBeautyTargets(s: *Session, width: u16, height: u16) !void {
    if (s.web_beauty_targets_width == width and s.web_beauty_targets_height == height and s.web_beauty_blur_h_target != null) return;
    for ([_]*?render.Renderer.OffscreenTarget{
        &s.web_beauty_blur_h_target,
        &s.web_beauty_mean_target,
        &s.web_beauty_reshape_target,
        &s.web_beauty_makeup_targets[0],
        &s.web_beauty_makeup_targets[1],
    }) |slot| {
        if (slot.*) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.* = null;
        slot.* = try render.Renderer.createOffscreenTarget(width, height);
    }
    s.web_beauty_targets_width = width;
    s.web_beauty_targets_height = height;
}

/// beauty.face and beauty.reshape's own dispatch on web, in place of
/// applyBeautyCompositing's gpupixel bridge above (not ported to this
/// target). Reshape runs first, matching the reference GLSL's own
/// composition order (warp which pixel gets sampled, then smooth/
/// whiten the color that lands) even though they're two separate bgfx
/// passes here rather than one combined shader.
fn applyWebBeautyChain(r: *render.Renderer, s: *Session, next_view_id: *u8, width: u16, height: u16, input_texture: render.TextureHandle) !render.TextureHandle {
    try ensureWebBeautyTargets(s, width, height);
    var current = input_texture;

    // Shared by beauty.reshape (only needs the base 106) and the
    // lipstick/blush mesh (needs all 111, including face106.zig's five
    // derived hub points) - computed once regardless of which of the
    // four landmark-driven effects are actually active this frame.
    var contour: [face106.point_count * 2]f32 = undefined;
    const has_face = blk: {
        // Web has no internal tracking worker (goss_session_enable_face_
        // tracking reports unsupported on this target) - the caller
        // feeds landmarks directly via goss_session_set_face_landmarks.
        const landmarks = s.web_face_landmarks orelse break :blk false;
        face106.fill(&landmarks, @floatFromInt(width), @floatFromInt(height), &contour);
        break :blk true;
    };

    const thin_face = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.thin_face)];
    const big_eye = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.big_eye)];
    if (has_face and (thin_face > 0.0 or big_eye > 0.0)) {
        const view_id = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(view_id, s.web_beauty_reshape_target.?, width, height);
        const aspect_ratio: f32 = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        r.submitBeautyReshape(view_id, current, contour[0 .. render.face_point_vec4_count * 4], aspect_ratio, thin_face, big_eye);
        current = s.web_beauty_reshape_target.?.texture;
    }

    const smooth = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.smooth)];
    const whiten_requested = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.whiten)];
    const luts_loaded = for (s.web_beauty_lut_textures) |slot| {
        if (slot == null) break false;
    } else true;
    // Whiten renders inert until all four LUT textures load on web
    // (goss_session_set_beauty_lut) - the amount the caller actually
    // requested still gets tracked either way, just not applied yet.
    const whiten = if (luts_loaded) whiten_requested else 0.0;
    if (smooth > 0.0 or whiten > 0.0) {
        const step_x = 1.0 / @as(f32, @floatFromInt(width));
        const step_y = 1.0 / @as(f32, @floatFromInt(height));
        var view_id = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(view_id, s.web_beauty_blur_h_target.?, width, height);
        r.submitBlurPass(view_id, current, .{ step_x, 0.0 });
        view_id = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(view_id, s.web_beauty_mean_target.?, width, height);
        r.submitBlurPass(view_id, s.web_beauty_blur_h_target.?.texture, .{ 0.0, step_y });

        const view_id2 = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(view_id2, s.web_beauty_blur_h_target.?, width, height);
        // default_mask_texture is a safe 1x1 placeholder for whichever
        // LUT slots aren't loaded yet - the shader never actually
        // samples them while whiten is 0.
        const lut = struct {
            fn textureOr(slot: ?render.TextureHandle, fallback: render.TextureHandle) render.TextureHandle {
                return slot orelse fallback;
            }
        }.textureOr;
        r.submitBeautyFace(
            view_id2,
            current,
            s.web_beauty_mean_target.?.texture,
            lut(s.web_beauty_lut_textures[0], r.default_mask_texture),
            lut(s.web_beauty_lut_textures[1], r.default_mask_texture),
            lut(s.web_beauty_lut_textures[2], r.default_mask_texture),
            lut(s.web_beauty_lut_textures[3], r.default_mask_texture),
            smooth,
            whiten,
        );
        current = s.web_beauty_blur_h_target.?.texture;
    }

    const lipstick = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.lipstick)];
    const blush = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.blush)];
    const lipstick_ready = lipstick > 0.0 and s.web_beauty_lipstick_texture != null;
    const blush_ready = blush > 0.0 and s.web_beauty_blush_texture != null;
    if (has_face and (lipstick_ready or blush_ready)) {
        // A makeup draw only rasterizes its own mesh triangles, so its
        // background sample and its write target can never be the same
        // texture (a read-write feedback hazard) - blit current into
        // slot 0 first, then each active effect reads whichever slot
        // holds the frame so far and writes the other.
        const blit_view = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(blit_view, s.web_beauty_makeup_targets[0].?, width, height);
        r.submitShaderPass(blit_view, r.passthroughProgram(), current, r.default_mask_texture);
        var slot: usize = 0;

        if (lipstick_ready) {
            const view_id = next_view_id.*;
            next_view_id.* += 1;
            const next_slot = 1 - slot;
            render.Renderer.setViewTarget(view_id, s.web_beauty_makeup_targets[next_slot].?, width, height);
            r.submitMakeup(view_id, s.web_beauty_makeup_targets[slot].?.texture, s.web_beauty_lipstick_texture.?, r.makeupLipstickUvBuffer(), &contour, lipstick);
            slot = next_slot;
        }
        if (blush_ready) {
            const view_id = next_view_id.*;
            next_view_id.* += 1;
            const next_slot = 1 - slot;
            render.Renderer.setViewTarget(view_id, s.web_beauty_makeup_targets[next_slot].?, width, height);
            r.submitMakeup(view_id, s.web_beauty_makeup_targets[slot].?.texture, s.web_beauty_blush_texture.?, r.makeupBlushUvBuffer(), &contour, blush);
            slot = next_slot;
        }
        current = s.web_beauty_makeup_targets[slot].?.texture;
    }

    return current;
}

/// Draws the active lens's full composite chain - beauty, shader.pass,
/// lut.pass, and blend.pass mixed freely: the camera preview captures
/// into one ping-pong target (view 0), beauty (when active) composites
/// into its own dedicated target right after, every ready lens stage
/// reads the previous stage and writes the other ping-pong target, and
/// whichever stage draws last presents straight to the swap chain
/// instead of an offscreen one. View ids increase monotonically because
/// bgfx orders view execution by id, not by submission order - that
/// ordering is what makes this an actual chain rather than stages
/// racing each other. A lens stage whose resource (a program, a
/// texture) isn't ready yet - most often a lut.pass or blend.pass node
/// whose asset hasn't landed - is skipped outright: the chain just has
/// one fewer stage this frame, not a gap that draws nothing. A
/// blend.pass node whose background HAS landed but segmentation is
/// unavailable still draws, against the renderer's always-foreground
/// default mask.
/// A 3D draw's aspect: the whole capture's when tiling (the scene keeps
/// its shape across the sub-frustum tiles), else the target rect's own.
fn tiledAspect(s: *Session, rect_w: u16, rect_h: u16) f32 {
    if (s.capture_tile != null and s.capture_aspect > 0) return s.capture_aspect;
    return @as(f32, @floatFromInt(rect_w)) / @as(f32, @floatFromInt(rect_h));
}

/// The tracked head's world position for the head collider: the head pose's
/// origin in landmark pixels, mapped into world space the same way the
/// face-anchored draw path maps content (the pixel_to_world transform). Null
/// when no head is tracked.
fn headWorldPosition(s: *Session, current: anytype) ?[3]f32 {
    const worker = s.face_tracking orelse return null;
    var tracked: face.Result = undefined;
    if (!(tracking.readResult(worker, &tracked) and tracked.landmark_count_out > 0 and tracked.presence >= 0.5)) return null;
    const h = face_geometry.estimateHeadPose(&tracked.landmarks) orelse return null;
    const fw: f32 = @floatFromInt(current.desc.width);
    const fh: f32 = @floatFromInt(current.desc.height);
    const world_height: f32 = 1.6568542;
    const scale = world_height / fh;
    return .{ scale * (h.cols[3][0] - 0.5 * fw), scale * (0.5 * fh - h.cols[3][1]), -scale * h.cols[3][2] };
}

/// True when the active lens carries a draw.board node, which draws the board
/// at its own place in the chain. The end-overlay stands down then so the board
/// is not drawn twice.
fn brushDrawnInChain(s: *Session) bool {
    for (s.chain_order) |entry| if (entry.kind == .draw_board) return true;
    return false;
}

/// Draws every committed stroke of `board` over view_id. Each stroke draws on
/// its own so neon blends additively while pen, highlighter, and marker blend on
/// alpha.
fn drawBrushStrokes(r: *render.Renderer, board: *const stroke.Board, view_id: u8) void {
    // One stroke's worst-case ribbon: every segment expanded to six vertices.
    var buf: [(stroke.max_points - 1) * 6 * stroke.floats_per_vertex]f32 = undefined;
    var si: u16 = 0;
    while (si < board.strokeCount()) : (si += 1) {
        const floats = board.buildStroke(si, &buf);
        if (floats == 0) continue;
        r.submitBrush(view_id, &buf, @intCast(floats / stroke.floats_per_vertex), board.strokeAdditive(si));
    }
}

/// Projects one world stroke into `out`, a screen-space stroke, through the
/// combined view-projection, applying the stroke's mode bias the same way the
/// screen brush does. A point behind the camera (w at or below zero) is dropped,
/// breaking the ribbon rather than smearing it. Screen y is measured down.
fn projectWorldStroke(view_proj: math.Mat4, ws: *const wboard.WorldStroke, out: *stroke.Stroke) void {
    const mode = stroke.Mode.fromU32(ws.mode);
    var col = ws.color;
    col[3] *= mode.alphaScale();
    out.* = .{ .color = col, .width = ws.width * mode.widthScale(), .mode = mode };
    var n: u16 = 0;
    var pi: u16 = 0;
    while (pi < ws.count) : (pi += 1) {
        const p = ws.points[pi];
        const clip = view_proj.mulVec(.{ p.x, p.y, p.z, 1.0 });
        if (clip[3] <= 1e-6) continue; // behind the camera
        out.points[n] = .{ .x = clip[0] / clip[3] * 0.5 + 0.5, .y = 0.5 - clip[1] / clip[3] * 0.5 };
        n += 1;
    }
    out.count = n;
}

/// Projects the world-anchored strokes into s.ar_projected using the camera view
/// and projection. Nothing projects without active world tracking. Clears the
/// projected board first, allocation-free.
fn projectArBoard(s: *Session) void {
    s.ar_projected.clear();
    if (!s.world_engine_fed or s.world.state.tracking_state != 2) return;
    const world_from_camera: math.Mat4 = .{ .cols = @bitCast(s.world.state.world_from_camera) };
    const projection: math.Mat4 = .{ .cols = @bitCast(s.world.state.projection) };
    const view_proj = projection.mul(world_from_camera.inverseRigid());
    var si: u16 = 0;
    while (si < s.ar_board.strokeCount()) : (si += 1) {
        const ws = s.ar_board.get(si) orelse continue;
        if (ws.count < 2 or s.ar_projected.count >= stroke.max_strokes) continue;
        const os = &s.ar_projected.strokes[s.ar_projected.count];
        projectWorldStroke(view_proj, ws, os);
        if (os.count >= 2) s.ar_projected.count += 1;
    }
}

/// Draws the brush over the final composited image on its own view. The screen
/// board stands down when a draw.board node already placed it in the chain; the
/// world-anchored board projects through the camera pose and draws whenever
/// tracking is live.
fn drawBrushOverlay(e: *Engine, r: *render.Renderer, s: *Session, view_id: u8, width: u16, height: u16) void {
    projectArBoard(s);
    const draw_screen = s.brush.strokeCount() > 0 and !brushDrawnInChain(s);
    const draw_ar = s.ar_projected.strokeCount() > 0;
    if (!draw_screen and !draw_ar) return;
    render.Renderer.setViewTarget(view_id, finalTarget(e, s), width, height);
    r.tile = null;
    if (draw_screen) drawBrushStrokes(r, &s.brush, view_id);
    if (draw_ar) drawBrushStrokes(r, &s.ar_projected, view_id);
}

/// Whether a reshape.bank node has a face to sculpt this frame: a valid
/// host-submitted face, else a valid native tracking result. readResult is
/// idempotent within a frame, so this matches fillReshapeContour's own gate
/// and the readiness pass and the draw arm never disagree.
fn reshapeFaceReady(s: *Session) bool {
    if (s.face_count > 0 and s.face_results[0].landmark_count_out == face.landmark_count and s.face_results[0].presence >= 0.5) return true;
    if (s.face_tracking) |worker| {
        var result: face.Result = undefined;
        if (tracking.readResult(worker, &result) and result.landmark_count_out == face.landmark_count and result.presence >= 0.5) return true;
    }
    return false;
}

/// Fills the reshape contour and its two derived hub anchors from the same
/// face reshapeFaceReady saw, normalized then carried into the preview blit's
/// own mirror-and-rotation space so the sculpt lands where the frame draws.
/// Returns false when no usable face holds, the hold-through degradation.
fn fillReshapeContour(s: *Session, width: u16, height: u16, rotation: u32, mirror: bool, contour: *[face106.point_count * 2]f32, hubs: *[4]f32) bool {
    var result: face.Result = undefined;
    var flat: ?*const [face.landmark_count * 3]f32 = null;
    if (s.face_count > 0 and s.face_results[0].landmark_count_out == face.landmark_count and s.face_results[0].presence >= 0.5) {
        flat = &s.face_results[0].landmarks;
    } else if (s.face_tracking) |worker| {
        if (tracking.readResult(worker, &result) and result.landmark_count_out == face.landmark_count and result.presence >= 0.5) {
            flat = &result.landmarks;
        }
    }
    const src = flat orelse return false;
    var landmarks: [face.landmark_count]face.Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        landmark.* = .{ .x = src[at * 3], .y = src[at * 3 + 1], .z = src[at * 3 + 2] };
    }
    face106.fill(&landmarks, @floatFromInt(width), @floatFromInt(height), contour);
    const raw_hubs = face106.reshapeHubs(contour);
    const fore = face106.transformPoint(raw_hubs[0], raw_hubs[1], rotation, mirror);
    const bridge = face106.transformPoint(raw_hubs[2], raw_hubs[3], rotation, mirror);
    hubs.* = .{ fore[0], fore[1], bridge[0], bridge[1] };
    var at: usize = 0;
    while (at < face106.point_count) : (at += 1) {
        const out = face106.transformPoint(contour[at * 2], contour[at * 2 + 1], rotation, mirror);
        contour[at * 2] = out[0];
        contour[at * 2 + 1] = out[1];
    }
    return true;
}

/// Grows the per-frame vertex staging to hold `floats`, called once per
/// dynamic mesh at lens activation. Never runs on the frame path.
fn reserveFrameStage(s: *Session, floats: usize) void {
    if (floats <= s.frame_stage.len) return;
    const grown = s.engine.gpa.alloc(f32, floats) catch return;
    if (s.frame_stage.len != 0) s.engine.gpa.free(s.frame_stage);
    s.frame_stage = grown;
}

/// The reserved staging sliced to `floats`, or null if activation could not
/// grow it - the caller then skips the draw, the same as an old alloc failure.
fn frameStage(s: *Session, floats: usize) ?[]f32 {
    if (floats > s.frame_stage.len) return null;
    return s.frame_stage[0..floats];
}

fn renderCompositeChain(e: *Engine, r: *render.Renderer, s: *Session, current: CurrentFrame, rotation: u32, mirror: bool) !void {
    // The tile is set per final full-screen pass below; every source-res
    // intermediate draw and every non-capture frame renders untiled.
    r.tile = null;
    var ready_count: usize = 0;
    for (s.chain_order) |entry| {
        const ready = switch (entry.kind) {
            .shader => s.shader_programs.contains(entry.graph_index),
            .lut => s.lut_textures.contains(entry.graph_index),
            // A blur pass needs no loaded resource - the blur program is
            // built in - so it is always ready to draw.
            .blur => true,
            // A grade pass ships no asset either; its params are resolved
            // at activation, so it is ready once they are in place.
            .grade => s.grade_params.contains(entry.graph_index),
            // Bloom is the same: no asset, params resolved at activation.
            .bloom => s.bloom_params.contains(entry.graph_index),
            // Depth of field needs the host's depth: with none submitted the
            // node holds the frame through, the standard capability degradation.
            .dof => s.dof_params.contains(entry.graph_index) and s.depth_texture != null,
            // Depth fog degrades the same way: it needs the submitted depth.
            .fog => s.fog_params.contains(entry.graph_index) and s.depth_texture != null,
            // The depth-edge outline needs the submitted depth to find edges.
            .outline => s.outline_params.contains(entry.graph_index) and (s.outline_masks.contains(entry.graph_index) or s.depth_texture != null),
            // A tint is a masked color layer: it needs both its params and a
            // named mask channel, else it holds the frame through.
            .tint => s.tint_params.contains(entry.graph_index) and s.tint_masks.contains(entry.graph_index),
            // A smooth is masked too: it needs its amount and a mask channel.
            .smooth => s.smooth_params.contains(entry.graph_index) and s.smooth_masks.contains(entry.graph_index),
            // A matte refine needs its params and a source: either a named
            // mask channel to refine or the submitted depth, like the outline.
            .matte => s.matte_params.contains(entry.graph_index) and (s.matte_masks.contains(entry.graph_index) or s.depth_texture != null),
            // A stylize pass ships no asset; its packed params resolve at
            // activation, so it is ready the moment they are in place.
            .stylize => s.stylize_params.contains(entry.graph_index),
            // An edge pass ships no asset either; its detector params resolve
            // at activation, so it is ready as soon as they are in place.
            .edge => s.edge_params.contains(entry.graph_index),
            // A warp pass ships no asset; its distortion params resolve at
            // activation, so it is ready as soon as they are in place.
            .warp => s.warp_params.contains(entry.graph_index),
            // A reshape bank needs a tracked face to sculpt around, like dof
            // needs depth: with its params resolved but no face it holds the
            // frame through, the standard capability degradation.
            .reshape => s.reshape_params.contains(entry.graph_index) and reshapeFaceReady(s),
            // A motion trail owns the frame it echoes (a session target it
            // seeds from the current frame on the first pass), so it is ready
            // as soon as its echo amount is resolved - no host input to gate on.
            .trail => s.trail_params.contains(entry.graph_index),
            // Screen-space reflection reads the submitted depth to know how
            // reflective the floor is, degrading the same way dof and fog do.
            .ssr => s.ssr_params.contains(entry.graph_index) and s.depth_texture != null,
            // The sky draws behind the segmented foreground; like blend it is
            // ready once its params resolve, degrading to the always-foreground
            // default mask (no sky visible) when segmentation is absent.
            .env => s.env_params.contains(entry.graph_index),
            // Only the background image gates readiness - the mask
            // degrades to the renderer's always-foreground default
            // when segmentation is unavailable (SPEC's rule: a node
            // consuming an unavailable capability's data holds its
            // default state, not blocks the chain).
            .blend => s.blend_textures.contains(entry.graph_index),
            // Like blend's mask: the face is a capability input whose
            // absence degrades (no draw), never blocks the chain.
            .mesh => s.mesh_face_textures.contains(entry.graph_index),
            .model => s.model_meshes.contains(entry.graph_index) or s.cloth_meshes.contains(entry.graph_index) or s.hair_meshes.contains(entry.graph_index) or s.particle_meshes.contains(entry.graph_index) or s.particle_base_meshes.contains(entry.graph_index) or s.particle_ribbon_meshes.contains(entry.graph_index) or s.gpu_particle_sims.contains(entry.graph_index) or s.fluid_sims.contains(entry.graph_index),
            // The draw board carries no loaded asset: it passes the frame
            // through and draws the session's brush strokes over it, so it is
            // always ready.
            .draw_board => true,
            // A sprite draws once its image has decoded (an animated sprite
            // once all its frames have); until then it holds the frame
            // through, never blocking the chain.
            .sprite => s.sprite_textures.contains(entry.graph_index) or s.text3d_meshes.contains(entry.graph_index) or
                s.video_textures.contains(entry.graph_index) or
                (if (s.sprite_anims.get(entry.graph_index)) |a| a.loaded == a.frames else false),
        };
        if (ready) ready_count += 1;
    }
    const beauty_active = anyBeautyActive(s);
    const capture_out_width: u16 = if (s.capture_requested and s.capture_res_width != 0) s.capture_res_width else @intCast(r.width);
    const capture_out_height: u16 = if (s.capture_requested and s.capture_res_height != 0) s.capture_res_height else @intCast(r.height);
    if (s.capture_requested) try ensureCaptureTarget(e, capture_out_width, capture_out_height);
    if (ready_count == 0 and !beauty_active and s.layout_active == null) {
        // view 0 may still be bound to an offscreen chain/beauty target
        // from an earlier frame that took the other branch below -
        // bgfx_set_view_frame_buffer is stateful across frames, nothing
        // resets it automatically once the chain/beauty that needed it
        // stops being active. Without this, this branch keeps drawing
        // into that stale offscreen target forever, never the real
        // backbuffer, and the visible canvas simply stops updating -
        // found via a real toggle-on-then-off repro (whiten set to 1
        // then back to 0), not a static read.
        const preview_rect_w: u16 = if (s.capture_requested) capture_out_width else @intCast(r.width);
        const preview_rect_h: u16 = if (s.capture_requested) capture_out_height else @intCast(r.height);
        // A plain capture (no passes) draws straight into the final target,
        // so the tile applies here too; capture_still only sets a tile when
        // the frame is upright, keeping the tiled quad axis-aligned.
        r.tile = s.capture_tile;
        render.Renderer.setViewTarget(0, finalTarget(e, s), preview_rect_w, preview_rect_h);
        r.submitPreview(0, current.preview, rotation * 90, mirror);
        drawBrushOverlay(e, r, s, 1, preview_rect_w, preview_rect_h);
        if (s.capture_requested) blitCaptureToSwapChain(e, r, 2);
        blitRecordingToSwapChain(e, r, 2);
        return;
    }

    const width: u16 = @intCast(current.desc.width);
    const height: u16 = @intCast(current.desc.height);
    // The swap chain's own real size, never the source frame's - a
    // stage whose output is null draws straight to the swap chain
    // (see the loop below), and that target is whatever size the
    // renderer was actually initialized/resized to, not the camera
    // frame's own resolution. Conflating the two used to size the
    // final view's rect to the frame's resolution regardless of the
    // swap chain's real size: harmless for a full-screen quad (still
    // fills whatever clamped viewport results) but silently
    // mis-scaled the picture whenever the two sizes differ, which a
    // model.gltf node's own non-full-screen mesh finally made visible
    // - found via a real corpus frame (2400x3000) rendered into a
    // 400x300 swap chain, the mesh landing entirely outside the
    // visible viewport.
    const output_width: u16 = if (s.capture_requested) capture_out_width else @intCast(r.width);
    const output_height: u16 = if (s.capture_requested) capture_out_height else @intCast(r.height);
    try ensureChainTargets(e, width, height);
    const targets = [2]render.Renderer.OffscreenTarget{ e.chain_targets[0].?, e.chain_targets[1].? };

    var next_view_id: u8 = 1;
    if (s.layout_active) |lay| {
        next_view_id = composeLayout(r, s, current, targets[0], targets[1], width, height, rotation, mirror, lay);
    } else {
        render.Renderer.setViewTarget(0, targets[0], width, height);
        r.submitPreview(0, current.preview, rotation * 90, mirror);
    }
    var input_texture = targets[0].texture;

    if (beauty_active) {
        input_texture = if (is_web)
            try applyWebBeautyChain(r, s, &next_view_id, width, height, input_texture)
        else
            applyBeautyCompositing(r, s, &next_view_id, width, height, rotation, mirror, input_texture);
    }

    var drawn: usize = 0;
    var next_slot: usize = 1;
    for (s.chain_order) |entry| {
        switch (entry.kind) {
            .shader => {
                const program_idx = s.shader_programs.get(entry.graph_index) orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                const shader_mask = blk: {
                    // A named channel with no live data samples zero:
                    // no signal means the subject is absent, so the
                    // effect draws nothing rather than everywhere.
                    const channel = s.shader_masks.get(entry.graph_index) orelse break :blk r.default_mask_texture;
                    if (channel == 0) break :blk s.segmentation_texture orelse r.zero_mask_texture;
                    break :blk s.segmentation_class_textures[channel] orelse r.zero_mask_texture;
                };
                r.submitShaderPass(view_id, .{ .idx = program_idx }, input_texture, shader_mask);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .lut => {
                const lut_texture = s.lut_textures.get(entry.graph_index) orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitLutPass(view_id, input_texture, lut_texture);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .blur => {
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                const rect_w = if (is_final) output_width else width;
                const rect_h = if (is_final) output_height else height;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, rect_w, rect_h) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                const step: [2]f32 = .{ 1.5 / @as(f32, @floatFromInt(rect_w)), 1.5 / @as(f32, @floatFromInt(rect_h)) };
                r.submitBlurPass(view_id, input_texture, step);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .grade => {
                const grade = s.grade_params.get(entry.graph_index) orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitGradePass(view_id, input_texture, grade);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .stylize => {
                const params = s.stylize_params.get(entry.graph_index) orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitStylizePass(view_id, input_texture, params);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .edge => {
                const edge = s.edge_params.get(entry.graph_index) orelse continue;
                drawn += 1;
                const is_final = drawn == ready_count;
                const texel = [2]f32{ 1.0 / @as(f32, @floatFromInt(width)), 1.0 / @as(f32, @floatFromInt(height)) };
                if (edge[0] < 0.5) {
                    // Single-pass sobel: mode 0, gain in .y, invert in .z.
                    const view_id = next_view_id;
                    next_view_id += 1;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    r.tile = if (is_final) s.capture_tile else null;
                    if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                    r.submitEdgeSobel(view_id, input_texture, .{ 0.0, edge[4], edge[5], 0.0 }, texel);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                } else {
                    // Canny: blur, directional sobel, non-maximum suppression
                    // and hysteresis ping-pong through the two edge scratch
                    // targets, leaving the frame in input_texture intact.
                    const scratch0 = e.edge_targets[0] orelse continue;
                    const scratch1 = e.edge_targets[1] orelse continue;
                    const base_texture = input_texture;
                    const blur_step = edge[3] / 4.0;
                    r.tile = null;
                    var edge_view = next_view_id;
                    next_view_id += 1;
                    render.Renderer.setViewTarget(edge_view, scratch0, width, height);
                    r.submitBlurPass(edge_view, base_texture, .{ blur_step * texel[0], 0.0 });

                    edge_view = next_view_id;
                    next_view_id += 1;
                    render.Renderer.setViewTarget(edge_view, scratch1, width, height);
                    r.submitBlurPass(edge_view, scratch0.texture, .{ 0.0, blur_step * texel[1] });

                    edge_view = next_view_id;
                    next_view_id += 1;
                    render.Renderer.setViewTarget(edge_view, scratch0, width, height);
                    r.submitEdgeSobel(edge_view, scratch1.texture, .{ 1.0, 0.0, 0.0, 0.0 }, texel);

                    edge_view = next_view_id;
                    next_view_id += 1;
                    render.Renderer.setViewTarget(edge_view, scratch1, width, height);
                    r.submitEdgeNms(edge_view, scratch0.texture, .{ edge[1], edge[2], 0.0, 0.0 }, texel);

                    const view_id = next_view_id;
                    next_view_id += 1;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    r.tile = if (is_final) s.capture_tile else null;
                    if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                    r.submitEdgeHyst(view_id, scratch1.texture, .{ edge[5], 0.0, 0.0, 0.0 }, texel);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                }
            },
            .warp => {
                const wp = s.warp_params.get(entry.graph_index) orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                // aspect_auto (wp[6]) reshapes the region into a circle on
                // screen by the source frame's own height/width, the way
                // gpupixel's sphere filters do; off keeps it square.
                const aspect = if (wp[6] > 0.5) @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(width)) else 1.0;
                r.submitWarpPass(view_id, input_texture, .{ wp[0], wp[1], wp[2], wp[3] }, .{ wp[4], wp[5], aspect, 0.0 });
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .reshape => {
                const bank = s.reshape_params.getPtr(entry.graph_index) orelse continue;
                var contour: [face106.point_count * 2]f32 = undefined;
                var hubs: [4]f32 = undefined;
                // Same gate the readiness pass used; readResult is idempotent
                // within a frame, so the two agree and is_final stays exact.
                if (!fillReshapeContour(s, width, height, rotation, mirror, &contour, &hubs)) continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                const aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
                r.submitReshapeBank(view_id, input_texture, contour[0 .. render.face_point_vec4_count * 4], hubs, bank, aspect_ratio);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .dof => {
                const params = s.dof_params.get(entry.graph_index) orelse continue;
                const depth_tex = s.depth_texture orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitDofPass(view_id, input_texture, depth_tex, params[0], params[1]);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .fog => {
                const fog = s.fog_params.get(entry.graph_index) orelse continue;
                const depth_tex = s.depth_texture orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitFogPass(view_id, input_texture, depth_tex, .{ fog[0], fog[1], fog[2] }, fog[3]);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .outline => {
                const line = s.outline_params.get(entry.graph_index) orelse continue;
                // Trace a named mask channel's edge when the node has one, else
                // the submitted depth; an absent class serves the zero mask, so
                // the outline degrades to nothing rather than drawing wrong.
                const edge_tex = if (s.outline_masks.get(entry.graph_index)) |channel|
                    (if (channel == 0) s.segmentation_texture orelse r.zero_mask_texture else s.segmentation_class_textures[channel] orelse r.zero_mask_texture)
                else
                    s.depth_texture orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitOutlinePass(view_id, input_texture, edge_tex, .{ line[0], line[1], line[2] }, line[3]);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .tint => {
                const params = s.tint_params.get(entry.graph_index) orelse continue;
                const channel = s.tint_masks.get(entry.graph_index) orelse continue;
                // The named channel's mask keys the color layer; an absent
                // class serves the zero mask, so the tint fades to nothing.
                const mask_tex = if (channel == 0) s.segmentation_texture orelse r.zero_mask_texture else s.segmentation_class_textures[channel] orelse r.zero_mask_texture;
                // A reference-sourced tint paints the channel in the makeup
                // reference's sampled color, falling back to the static color
                // when no reference is set.
                const tint_color: [3]f32 = if (s.tint_reference.contains(entry.graph_index))
                    (s.makeup_reference[channel] orelse [3]f32{ params[0], params[1], params[2] })
                else
                    [3]f32{ params[0], params[1], params[2] };
                const mode = s.tint_modes.get(entry.graph_index) orelse 0;
                const finish = s.tint_finishes.get(entry.graph_index) orelse 0;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitTintPass(view_id, input_texture, mask_tex, tint_color, params[3], mode, finish);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .smooth => {
                const amount = s.smooth_params.get(entry.graph_index) orelse continue;
                const channel = s.smooth_masks.get(entry.graph_index) orelse continue;
                const mask_tex = if (channel == 0) s.segmentation_texture orelse r.zero_mask_texture else s.segmentation_class_textures[channel] orelse r.zero_mask_texture;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitSmoothPass(view_id, input_texture, mask_tex, amount);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .matte => {
                const params = s.matte_params.get(entry.graph_index) orelse continue;
                // Refine a named channel's matte when the node has one, else
                // the submitted depth; an absent class serves the zero mask, so
                // the refinement degrades to an empty matte rather than wrong.
                const matte_tex = if (s.matte_masks.get(entry.graph_index)) |channel|
                    (if (channel == 0) s.segmentation_texture orelse r.zero_mask_texture else s.segmentation_class_textures[channel] orelse r.zero_mask_texture)
                else
                    s.depth_texture orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitMatteRefinePass(view_id, input_texture, matte_tex, params);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .ssr => {
                const ssr = s.ssr_params.get(entry.graph_index) orelse continue;
                const depth_tex = s.depth_texture orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitSsrPass(view_id, input_texture, depth_tex, ssr[0], ssr[1]);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .env => {
                const env = s.env_params.get(entry.graph_index) orelse continue;
                const mask_texture = s.segmentation_texture orelse r.default_mask_texture;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                if (s.env_textures.get(entry.graph_index)) |env_tex| {
                    // With an equirect image loaded, sample it by the pose. Its
                    // basis rows turn each pixel's view ray into world space, so
                    // the environment pans with the device; the upper 3x3 of the
                    // column-major pose reads out as rows here.
                    const wfc = s.world.state.world_from_camera;
                    const rot = [3][4]f32{
                        .{ wfc[0], wfc[4], wfc[8], 0 },
                        .{ wfc[1], wfc[5], wfc[9], 0 },
                        .{ wfc[2], wfc[6], wfc[10], 0 },
                    };
                    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
                    r.submitEnvmapPass(view_id, input_texture, env_tex, mask_texture, rot, env[6], aspect);
                } else {
                    // No image: the procedural sky, its gradient shifted by the
                    // pose pitch and sun slid by the yaw into screen fractions.
                    const cam_pose: math.Mat4 = .{ .cols = @bitCast(s.world.state.world_from_camera) };
                    const euler = headEuler(cam_pose);
                    r.submitEnvPass(view_id, input_texture, mask_texture, .{ env[0], env[1], env[2] }, .{ env[3], env[4], env[5] }, env[6], euler.pitch * 0.2, euler.yaw * 0.15915494);
                }
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .trail => {
                const amount = s.trail_params.get(entry.graph_index) orelse continue;
                ensureTrailPrev(s, width, height) catch continue;
                const prev = s.prev_frame_target orelse continue;
                drawn += 1;
                // First frame has no earlier frame to echo: seed prev with the
                // current one on a lower view so the blend is a no-op, not a
                // garbage echo. The copy is a passthrough draw (a render target
                // is no blit destination on every backend), like the rest of the chain.
                if (!s.prev_frame_valid) {
                    const seed_view = next_view_id;
                    next_view_id += 1;
                    r.tile = null;
                    render.Renderer.setViewTarget(seed_view, prev, width, height);
                    r.submitShaderPass(seed_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                    s.prev_frame_valid = true;
                }
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitTrailPass(view_id, input_texture, prev.texture, amount);
                // Keep this frame for the next one's echo. The copy runs on the
                // immediately following view so a later chain stage reusing this
                // ping-pong slot can't overwrite the frame before it is stored.
                const store_view = next_view_id;
                next_view_id += 1;
                r.tile = null;
                render.Renderer.setViewTarget(store_view, prev, width, height);
                r.submitShaderPass(store_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .bloom => {
                const bloom = s.bloom_params.get(entry.graph_index) orelse continue;
                const scratch0 = e.bloom_targets[0] orelse continue;
                const scratch1 = e.bloom_targets[1] orelse continue;
                drawn += 1;
                const is_final = drawn == ready_count;
                const base_texture = input_texture;

                // Bright pass, then a separable blur (H then V) through the
                // two bloom scratch targets - all at working resolution,
                // never tiled, leaving the frame in base_texture intact.
                r.tile = null;
                var bloom_view = next_view_id;
                next_view_id += 1;
                render.Renderer.setViewTarget(bloom_view, scratch0, width, height);
                r.submitBloomExtract(bloom_view, base_texture, bloom);

                bloom_view = next_view_id;
                next_view_id += 1;
                render.Renderer.setViewTarget(bloom_view, scratch1, width, height);
                r.submitBlurPass(bloom_view, scratch0.texture, .{ 2.0 / @as(f32, @floatFromInt(width)), 0.0 });

                bloom_view = next_view_id;
                next_view_id += 1;
                render.Renderer.setViewTarget(bloom_view, scratch0, width, height);
                r.submitBlurPass(bloom_view, scratch1.texture, .{ 0.0, 2.0 / @as(f32, @floatFromInt(height)) });

                // Composite the blurred glow back over the base, honoring
                // is_final's target, rect, and capture tile like every
                // other chain stage's final draw.
                const view_id = next_view_id;
                next_view_id += 1;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitBloomComposite(view_id, base_texture, scratch0.texture, bloom);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .blend => {
                const background_texture = s.blend_textures.get(entry.graph_index) orelse continue;
                const mask_texture = s.segmentation_texture orelse r.default_mask_texture;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitBlendPass(view_id, input_texture, background_texture, mask_texture);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .draw_board => {
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                // The frame passes through whole, then the brush board draws its
                // strokes over it at the node's own place in the chain.
                r.submitShaderPass(view_id, r.passthroughProgram(), input_texture, r.default_mask_texture);
                drawBrushStrokes(r, &s.brush, view_id);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .mesh => {
                const mesh_texture = s.mesh_face_textures.get(entry.graph_index) orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                // The frame passes through whole; the mesh then draws
                // only its own triangles over it. No tracked face means
                // no draw, the capability's defined degradation.
                r.submitShaderPass(view_id, r.passthroughProgram(), input_texture, r.default_mask_texture);
                if (s.face_tracking) |worker| {
                    var tracked: face.Result = undefined;
                    if (tracking.readResult(worker, &tracked) and tracked.landmark_count_out > 0 and tracked.presence >= 0.5) {
                        r.submitFaceMesh(view_id, input_texture, mesh_texture, &tracked.landmarks, @floatFromInt(width), @floatFromInt(height), 1.0);
                    }
                }
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .sprite => {
                if (s.text3d_meshes.get(entry.graph_index)) |text3d| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const out_w: u16 = if (output != null and !is_final) width else output_width;
                    const out_h: u16 = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, out_w, out_h);
                        render.Renderer.setViewTarget(mesh_view, target, out_w, out_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    const aspect: f32 = tiledAspect(s, out_w, out_h);
                    r.tile = if (is_final) s.capture_tile else null;
                    const rect = s.sprite_rects.get(entry.graph_index) orelse [5]f32{ 0, 0, 1, 1, 1 };
                    const cx = (rect[0] + rect[2] * 0.5) * 2.0 - 1.0;
                    const cy = 1.0 - (rect[1] + rect[3] * 0.5) * 2.0;
                    const sc = @max(rect[2], 0.1) * 0.7;
                    // Place the text at its rect centre and rotate it so the
                    // extruded sides show rather than reading as a flat label.
                    const model = math.Mat4.translation(.{ cx * 0.7, cy * 0.7, 0 }).mul(math.Mat4.rotationY(0.6)).mul(math.Mat4.rotationX(0.25)).mul(math.Mat4.scaling(.{ sc, sc, sc }));
                    r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                    r.drawModelMesh(mesh_view, text3d.mesh, model, text3d.color, aspect);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                var sprite_texture: render.TextureHandle = undefined;
                if (s.video_textures.getPtr(entry.graph_index)) |vid| {
                    // A video clip advances its decoded frame off the lens clock,
                    // uploading the next one into its dynamic texture.
                    advanceVideo(s, vid);
                    sprite_texture = vid.texture;
                } else if (s.sprite_anims.get(entry.graph_index)) |anim| {
                    // An animated sprite cycles its frames off the lens clock;
                    // wait until every frame has landed so the cycle is whole.
                    if (anim.loaded != anim.frames) continue;
                    const active_us = if (s.active_lens) |*lens| lens.elapsedUs() else 0;
                    const frame_idx: u64 = @intFromFloat(@as(f64, @floatFromInt(active_us)) / 1_000_000.0 * @as(f64, anim.fps));
                    sprite_texture = anim.textures[@intCast(frame_idx % anim.frames)];
                } else {
                    sprite_texture = s.sprite_textures.get(entry.graph_index) orelse continue;
                }
                const rect = s.sprite_rects.get(entry.graph_index) orelse [5]f32{ 0, 0, 1, 1, 1 };
                drawn += 1;
                const blit_view = next_view_id;
                next_view_id += 1;
                const sprite_view = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                const out_w: u16 = if (is_final) output_width else width;
                const out_h: u16 = if (is_final) output_height else height;
                // The frame passes through whole on the blit view, then the
                // sprite draws over it at its own rect on a second view (a
                // separate view because it narrows the view rect).
                if (output) |target| render.Renderer.setViewTarget(blit_view, target, out_w, out_h) else render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                if (output) |target| render.Renderer.setViewTarget(sprite_view, target, out_w, out_h) else render.Renderer.setViewTarget(sprite_view, null, output_width, output_height);
                const full_w: f32 = @floatFromInt(if (output != null) out_w else output_width);
                const full_h: f32 = @floatFromInt(if (output != null) out_h else output_height);
                const dx: u16 = @intFromFloat(std.math.clamp(rect[0], 0, 1) * full_w);
                const dy: u16 = @intFromFloat(std.math.clamp(rect[1], 0, 1) * full_h);
                const dw: u16 = @intFromFloat(std.math.clamp(rect[2], 0, 1) * full_w);
                const dh: u16 = @intFromFloat(std.math.clamp(rect[3], 0, 1) * full_h);
                // A bound opacity parameter overrides the static one each frame.
                var sprite_opacity = rect[4];
                if (s.sprite_opacity_params.get(entry.graph_index)) |pname| {
                    if (s.active_lens) |*lens| {
                        if (lens.paramValue(pname)) |v| sprite_opacity = std.math.clamp(v, 0, 1);
                    }
                }
                r.submitSpriteAtRect(sprite_view, sprite_texture, dx, dy, dw, dh, sprite_opacity);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .model => {
                if (s.particle_ribbon_meshes.get(entry.graph_index)) |ribbon_mesh| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    var base_color: [4]f32 = .{ 0.9, 0.8, 0.3, 1.0 };
                    if (s.particle_systems.getPtr(entry.graph_index)) |sys| {
                        if (sys.field.pattern == .face) feedFaceEmitters(s, sys, width, height);
                        if (!s.capture_requested) sys.step(1.0 / 60.0);
                        if (sys.field.color) |c_| base_color = .{ c_[0], c_[1], c_[2], 1.0 };
                        const sz: f32 = if (sys.field.size > 0) @floatFromInt(sys.field.size) else 8.0;
                        const width_w: f32 = sz * 0.003;
                        const aspect_ratio: f32 = tiledAspect(s, rect_w, rect_h);
                        r.tile = if (is_final) s.capture_tile else null;
                        if (frameStage(s, sys.ribbonVertexCount() * 3)) |verts| {
                            sys.writeRibbons(verts, width_w);
                            r.updateParticleMesh(ribbon_mesh, verts);
                            r.submitRibbons(blit_view, mesh_view, input_texture, ribbon_mesh, base_color, aspect_ratio);
                        }
                    }
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                if (s.fluid_sims.getPtr(entry.graph_index)) |fluid| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    if (!s.capture_requested) fluid.step(1.0 / 60.0);
                    if (s.fluid_base_meshes.get(entry.graph_index)) |base_mesh| {
                        const count: usize = fluid.particles.len;
                        if (frameStage(s, count * 3)) |verts| {
                            fluid.writePositions(verts);
                            const aspect_ratio: f32 = tiledAspect(s, rect_w, rect_h);
                            r.tile = if (is_final) s.capture_tile else null;
                            r.submitParticleMeshes(blit_view, mesh_view, input_texture, base_mesh, verts, 0.03, .{ 0.3, 0.6, 0.95, 1.0 }, aspect_ratio);
                        }
                    }
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                if (s.particle_base_meshes.get(entry.graph_index)) |base_mesh| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    var base_color: [4]f32 = .{ 0.9, 0.8, 0.3, 1.0 };
                    var scale: f32 = 0.04;
                    if (s.particle_systems.getPtr(entry.graph_index)) |sys| {
                        if (sys.field.pattern == .face) feedFaceEmitters(s, sys, width, height);
                        if (!s.capture_requested) sys.step(1.0 / 60.0);
                        if (sys.field.color) |c_| base_color = .{ c_[0], c_[1], c_[2], 1.0 };
                        const sz: f32 = if (sys.field.size > 0) @floatFromInt(sys.field.size) else 8.0;
                        scale = sz * 0.005;
                        const aspect_ratio: f32 = tiledAspect(s, rect_w, rect_h);
                        r.tile = if (is_final) s.capture_tile else null;
                        const count = sys.field.count;
                        if (frameStage(s, count * 3)) |verts| {
                            sys.writePositions(verts);
                            if (sys.field.instanced) {
                                r.submitParticleMeshesInstanced(blit_view, mesh_view, input_texture, base_mesh, verts, scale, base_color, aspect_ratio);
                            } else {
                                r.submitParticleMeshes(blit_view, mesh_view, input_texture, base_mesh, verts, scale, base_color, aspect_ratio);
                            }
                        }
                    }
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                if (s.particle_meshes.get(entry.graph_index)) |particle_mesh| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    // A capture is a snapshot; only a live frame advances the
                    // fountain, at a fixed step so the sim stays deterministic.
                    var fade = false;
                    var glow = false;
                    var particle_params: [4]f32 = .{ 0, 0, 1, 0 };
                    var particle_fx: [4]f32 = .{ 1, 1, 0, 0 };
                    var base_color: [4]f32 = .{ 0.9, 0.8, 0.3, 1.0 };
                    var cool_color = base_color;
                    if (s.particle_systems.getPtr(entry.graph_index)) |sys| {
                        if (sys.field.pattern == .face) feedFaceEmitters(s, sys, width, height);
                        if (!s.capture_requested) sys.step(1.0 / 60.0);
                        // A trail draws through the fading billboard program
                        // too, so it counts as a faded draw here.
                        const has_trail = sys.field.trail > 1;
                        fade = sys.field.fade or has_trail;
                        glow = sys.field.glow;
                        if (sys.field.color) |c_| base_color = .{ c_[0], c_[1], c_[2], 1.0 };
                        cool_color = base_color;
                        if (sys.field.cool) |c_| cool_color = .{ c_[0], c_[1], c_[2], 1.0 };
                        const count: u32 = @intCast(sys.renderCount());
                        if (fade) {
                            const sprite_px: f32 = if (sys.field.size > 0) @floatFromInt(sys.field.size) else 8.0;
                            // Size at death relative to birth (1 = unchanged), and
                            // the spin in turns over life, packed for u_particleSize.
                            const end_ratio: f32 = if (sys.field.size_end) |end_px| @as(f32, @floatFromInt(end_px)) / @max(sprite_px, 1.0) else 1.0;
                            particle_params = .{ sprite_px / @as(f32, @floatFromInt(rect_w)), sprite_px / @as(f32, @floatFromInt(rect_h)), end_ratio, sys.field.spin };
                            // Flip-book frames, the square sheet's cells per row,
                            // and the velocity stretch, for u_particleFx.
                            const frames: f32 = @floatFromInt(@max(sys.field.frames, 1));
                            const sheet_dim: f32 = @ceil(@sqrt(frames));
                            particle_fx = .{ frames, sheet_dim, sys.field.stretch, 0 };
                            if (has_trail) {
                                if (frameStage(s, sys.trailVertexCount() * 8)) |verts| {
                                    sys.writeTrailBillboards(verts);
                                    render.Renderer.updateParticleMeshFaded(particle_mesh, verts);
                                }
                            } else if (frameStage(s, count * 6 * 8)) |verts| {
                                sys.writeBillboards(verts);
                                render.Renderer.updateParticleMeshFaded(particle_mesh, verts);
                            }
                        } else {
                            if (frameStage(s, count * 3)) |verts| {
                                sys.writePositions(verts);
                                r.updateParticleMesh(particle_mesh, verts);
                            }
                        }
                    }
                    const aspect_ratio: f32 = tiledAspect(s, rect_w, rect_h);
                    const sprite_texture = s.particle_sprite_textures.get(entry.graph_index) orelse r.defaultSpriteTexture();
                    // The final pass draws into the capture target, so a tile
                    // crops the 3D sub-frustum (and the blit's UV) to its slice.
                    r.tile = if (is_final) s.capture_tile else null;
                    r.submitParticles(blit_view, mesh_view, input_texture, particle_mesh, base_color, cool_color, aspect_ratio, fade, particle_params, particle_fx, glow, sprite_texture);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                if (s.gpu_particle_sims.getPtr(entry.graph_index)) |node| {
                    drawn += 1;
                    // The compute runs on its own view, ordered before the draw
                    // views so bgfx barriers its written billboards into the draw.
                    const compute_view = next_view_id;
                    next_view_id += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    const pf = node.field;
                    // A capture is a snapshot; only a live frame advances the sim.
                    if (!s.capture_requested) {
                        const forces: render.Renderer.ParticleForces = .{
                            .drag = pf.drag,
                            .turbulence = pf.turbulence,
                            .wind = pf.wind,
                            .curl = pf.curl,
                            .attract = pf.attract orelse .{ 0, 0, 0 },
                            .attract_strength = if (pf.attract != null) pf.attract_strength else 0,
                            .vortex = pf.vortex,
                        };
                        r.dispatchGpuParticles(compute_view, &node.sim, 1.0 / 60.0, pf.gravity, pf.speed, pf.lifetime, forces);
                    }
                    var base_color: [4]f32 = .{ 0.9, 0.8, 0.3, 1.0 };
                    if (pf.color) |c_| base_color = .{ c_[0], c_[1], c_[2], 1.0 };
                    var cool_color = base_color;
                    if (pf.cool) |c_| cool_color = .{ c_[0], c_[1], c_[2], 1.0 };
                    const sprite_px: f32 = if (pf.size > 0) @floatFromInt(pf.size) else 8.0;
                    const end_ratio: f32 = if (pf.size_end) |end_px| @as(f32, @floatFromInt(end_px)) / @max(sprite_px, 1.0) else 1.0;
                    const particle_params: [4]f32 = .{ sprite_px / @as(f32, @floatFromInt(rect_w)), sprite_px / @as(f32, @floatFromInt(rect_h)), end_ratio, pf.spin };
                    const frames: f32 = @floatFromInt(@max(pf.frames, 1));
                    const particle_fx: [4]f32 = .{ frames, @ceil(@sqrt(frames)), pf.stretch, 0 };
                    const aspect_ratio: f32 = tiledAspect(s, rect_w, rect_h);
                    r.tile = if (is_final) s.capture_tile else null;
                    r.submitParticles(blit_view, mesh_view, input_texture, node.sim.billboard, base_color, cool_color, aspect_ratio, true, particle_params, particle_fx, pf.glow, r.defaultSpriteTexture());
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                if (s.hair_meshes.get(entry.graph_index)) |hair_mesh| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    if (s.hair_ids.get(entry.graph_index)) |hid| {
                        if (s.physics_world) |world| {
                            // Drive the hair with the tracked head pose;
                            // identity (hair just hangs) without a face.
                            var head = math.Mat4.identity;
                            if (s.face_tracking) |worker| {
                                var tracked: face.Result = undefined;
                                if (tracking.readResult(worker, &tracked) and tracked.landmark_count_out > 0 and tracked.presence >= 0.5) {
                                    if (face_geometry.estimateHeadPose(&tracked.landmarks)) |h| head = h;
                                }
                            }
                            const dt = if (s.physics_last_us != 0 and s.current != null and s.current.?.desc.timestamp_us > s.physics_last_us)
                                @min(@as(f32, @floatFromInt(s.current.?.desc.timestamp_us - s.physics_last_us)) / 1_000_000.0, 0.25)
                            else
                                1.0 / 60.0;
                            world.hairUpdate(hid, @bitCast(head.cols), dt);
                            const vcount = s.hair_vcount.get(entry.graph_index) orelse 0;
                            if (vcount > 0) {
                                if (frameStage(s, vcount * 3)) |positions| {
                                    _ = world.hairRead(hid, positions);
                                    r.updateHairMesh(hair_mesh, positions);
                                }
                            }
                        }
                    }
                    const aspect_ratio: f32 = tiledAspect(s, rect_w, rect_h);
                    r.tile = if (is_final) s.capture_tile else null;
                    r.submitHair(blit_view, mesh_view, input_texture, hair_mesh, .{ 0.15, 0.1, 0.08, 1.0 }, aspect_ratio);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                if (s.cloth_meshes.get(entry.graph_index)) |cloth_mesh| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    if (s.cloth_bodies.get(entry.graph_index)) |body| {
                        if (s.physics_world) |world| {
                            const vcount = s.cloth_cols.get(entry.graph_index) orelse 0;
                            if (vcount > 0) {
                                if (frameStage(s, vcount * 3)) |positions| {
                                    _ = world.clothRead(body, positions);
                                    r.updateClothMesh(cloth_mesh, positions);
                                }
                            }
                        }
                    }
                    const aspect_ratio: f32 = tiledAspect(s, rect_w, rect_h);
                    r.tile = if (is_final) s.capture_tile else null;
                    r.submitCloth(blit_view, mesh_view, input_texture, cloth_mesh, .{ 0.4, 0.55, 0.85, 1.0 }, aspect_ratio);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                const loaded = s.model_meshes.get(entry.graph_index) orelse continue;
                drawn += 1;
                // Two views, not one: the blit needs the flat ortho
                // every other pass shares, the mesh needs a real 3D
                // view/projection, and bgfx's view transform is a
                // per-view state, not per-draw - see submitModel's own
                // doc comment.
                const blit_view = next_view_id;
                next_view_id += 1;
                const mesh_view = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                // The final pass draws into the capture target, so a tile
                // crops the 3D sub-frustum (and the blit's UV) to its slice.
                r.tile = if (is_final) s.capture_tile else null;
                const rect_width = if (output != null and !is_final) width else output_width;
                const rect_height = if (output != null and !is_final) height else output_height;
                if (output) |target| {
                    render.Renderer.setViewTarget(blit_view, target, rect_width, rect_height);
                    render.Renderer.setViewTarget(mesh_view, target, rect_width, rect_height);
                } else {
                    render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                    render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                }
                const active_lens: ?*const runtime.Lens = if (s.active_lens) |*lens| lens else null;
                const elapsed_us = if (active_lens) |lens| lens.modelElapsedUs(entry.graph_index) orelse 0 else 0;
                const elapsed_seconds = @as(f32, @floatFromInt(elapsed_us)) / 1_000_000.0;
                var model_matrix = modelPoseMatrix(loaded, elapsed_seconds, active_lens, entry.graph_index);
                // A morphable mesh deforms its rest positions by the lens's
                // bound morph weights and re-uploads once, before any anchor
                // path draws it; an unbound mesh keeps its rest shape.
                if (loaded.morph_targets.len > 0 and loaded.morph_scratch.len > 0) {
                    if (active_lens) |lens| {
                        if (lens.bindsMorphWeights(entry.graph_index)) {
                            var weights: [max_morph_targets]f32 = undefined;
                            const n = @min(loaded.morph_targets.len, max_morph_targets);
                            for (0..n) |ti| weights[ti] = lens.morphWeight(entry.graph_index, ti);
                            morphPositions(loaded.morph_scratch, loaded.morph_rest, loaded.morph_targets[0..n], weights[0..n]);
                            r.updateModelMesh(loaded.mesh, loaded.morph_scratch);
                        }
                    }
                }
                if (s.physics_bodies.get(entry.graph_index)) |body_id| {
                    if (s.physics_world) |world| {
                        if (world.bodyPose(body_id)) |body_pose| {
                            model_matrix = .{ .cols = @bitCast(body_pose) };
                        } else |_| {}
                    }
                }
                if (s.model_world_anchors.contains(entry.graph_index)) {
                    // World-anchored content draws from the platform
                    // camera's own view and projection, at world anchor
                    // zero when one exists, else the world origin; no
                    // tracking means the standard nothing-drawn state.
                    if (s.world_engine_fed and s.world.state.tracking_state == 2) {
                        const world_from_camera: math.Mat4 = .{ .cols = @bitCast(s.world.state.world_from_camera) };
                        const projection: math.Mat4 = .{ .cols = @bitCast(s.world.state.projection) };
                        const view = world_from_camera.inverseRigid();
                        const anchor_pose: math.Mat4 = if (s.world.anchor_count > 0)
                            .{ .cols = @bitCast(s.world.anchors[0].pose) }
                        else
                            math.Mat4.identity;
                        r.submitModelWithCamera(blit_view, mesh_view, input_texture, loaded.mesh, anchor_pose.mul(model_matrix), view, projection, loaded.base_color);
                    } else {
                        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                    }
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                var anchored_without_target = false;
                if (s.model_face_anchors.contains(entry.graph_index)) {
                    // The head transform lands in source-frame pixels, stretched
                    // by the preview blit to fill a rect whose z=0 plane spans
                    // 4*tan(22.5) world units vertically.
                    const world_height: f32 = 1.6568542;
                    const rect_aspect = tiledAspect(s, rect_width, rect_height);
                    const sx = world_height * rect_aspect / @as(f32, @floatFromInt(width));
                    const sy = world_height / @as(f32, @floatFromInt(height));
                    const pixel_to_world: math.Mat4 = .{ .cols = .{
                        .{ sx, 0, 0, 0 },
                        .{ 0, -sy, 0, 0 },
                        .{ 0, 0, -sy, 0 },
                        .{ -0.5 * world_height * rect_aspect, 0.5 * world_height, 0, 1 },
                    } };
                    const base_model_matrix = model_matrix;
                    if (s.face_count > 0) {
                        // The host's submitted faces drive one model per face:
                        // blit the frame once through the first, draw the rest
                        // of the meshes over it.
                        var drawn_face = false;
                        for (s.face_results[0..s.face_count]) |*fr| {
                            const head = face_geometry.estimateHeadPose(&fr.landmarks) orelse continue;
                            const m = pixel_to_world.mul(head).mul(base_model_matrix);
                            if (!drawn_face) {
                                r.submitModel(blit_view, mesh_view, input_texture, loaded.mesh, m, loaded.base_color, rect_aspect);
                                drawn_face = true;
                            } else {
                                r.drawModelMesh(mesh_view, loaded.mesh, m, loaded.base_color, rect_aspect);
                            }
                        }
                        if (!drawn_face) r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                        if (output) |target| {
                            input_texture = target.texture;
                            if (!is_final) next_slot += 1;
                        }
                        continue;
                    }
                    anchored_without_target = true;
                    if (s.face_tracking) |worker| {
                        var tracked: face.Result = undefined;
                        if (tracking.readResult(worker, &tracked) and tracked.landmark_count_out > 0 and tracked.presence >= 0.5) {
                            if (face_geometry.estimateHeadPose(&tracked.landmarks)) |head| {
                                model_matrix = pixel_to_world.mul(head).mul(base_model_matrix);
                                anchored_without_target = false;
                            }
                        }
                    }
                }
                if (s.model_body_anchors.contains(entry.graph_index)) {
                    const world_height: f32 = 1.6568542;
                    const rect_aspect = tiledAspect(s, rect_width, rect_height);
                    const sx = world_height * rect_aspect / @as(f32, @floatFromInt(width));
                    const sy = world_height / @as(f32, @floatFromInt(height));
                    const pixel_to_world: math.Mat4 = .{ .cols = .{
                        .{ sx, 0, 0, 0 },
                        .{ 0, -sy, 0, 0 },
                        .{ 0, 0, -sy, 0 },
                        .{ -0.5 * world_height * rect_aspect, 0.5 * world_height, 0, 1 },
                    } };
                    const base_model_matrix = model_matrix;
                    if (loaded.rig) |*rig| {
                        // A skinned mesh deforms per body via its joint
                        // palette; the shared dynamic buffer holds one
                        // pose, so drive it from the first tracked body.
                        const cp: ?pose.Result = if (s.body_count > 0) null else currentPose(s);
                        var rig_lm: ?*const [pose.landmark_count * 3]f32 = null;
                        if (s.body_count > 0) {
                            rig_lm = &s.body_results[0].landmarks;
                        } else if (cp) |*body| {
                            rig_lm = &body.landmarks;
                        }
                        if (rig_lm) |lm| skinned: {
                            const bp = bodyAnchorPose(lm) orelse break :skinned;
                            const anchor_full = bp.mul(base_model_matrix);
                            buildBodySkinPalette(rig, lm, anchor_full);
                            skinPositions(rig.rest, rig.skin.vertex_joints, rig.skin.vertex_weights, rig.palette, rig.skinned);
                            r.updateSkinnedMesh(rig.mesh, rig.skinned);
                            r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                            r.drawSkinnedMesh(mesh_view, rig.mesh, pixel_to_world.mul(anchor_full), loaded.base_color, tiledAspect(s, rect_width, rect_height));
                            if (output) |target| {
                                input_texture = target.texture;
                                if (!is_final) next_slot += 1;
                            }
                            continue;
                        }
                        // No tracked body to skin against: pass the frame through.
                        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                        if (output) |target| {
                            input_texture = target.texture;
                            if (!is_final) next_slot += 1;
                        }
                        continue;
                    }
                    if (s.body_count > 0) {
                        // The host's submitted bodies drive one model per body:
                        // blit the frame once through the first, draw the rest
                        // of the meshes over it.
                        var drawn_body = false;
                        for (s.body_results[0..s.body_count]) |*br| {
                            const bp = bodyAnchorPose(&br.landmarks) orelse continue;
                            const m = pixel_to_world.mul(bp).mul(base_model_matrix);
                            if (!drawn_body) {
                                r.submitModel(blit_view, mesh_view, input_texture, loaded.mesh, m, loaded.base_color, rect_aspect);
                                drawn_body = true;
                            } else {
                                r.drawModelMesh(mesh_view, loaded.mesh, m, loaded.base_color, rect_aspect);
                            }
                        }
                        if (!drawn_body) r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                        if (output) |target| {
                            input_texture = target.texture;
                            if (!is_final) next_slot += 1;
                        }
                        continue;
                    }
                    anchored_without_target = true;
                    if (currentPose(s)) |body| {
                        if (bodyAnchorPose(&body.landmarks)) |bp| {
                            model_matrix = pixel_to_world.mul(bp).mul(base_model_matrix);
                            anchored_without_target = false;
                        }
                    }
                }
                if (s.model_skeleton_anchors.contains(entry.graph_index)) {
                    const world_height: f32 = 1.6568542;
                    const rect_aspect = tiledAspect(s, rect_width, rect_height);
                    const sx = world_height * rect_aspect / @as(f32, @floatFromInt(width));
                    const sy = world_height / @as(f32, @floatFromInt(height));
                    const pixel_to_world: math.Mat4 = .{ .cols = .{
                        .{ sx, 0, 0, 0 },
                        .{ 0, -sy, 0, 0 },
                        .{ 0, 0, -sy, 0 },
                        .{ -0.5 * world_height * rect_aspect, 0.5 * world_height, 0, 1 },
                    } };
                    const base_model_matrix = model_matrix;
                    var drawn_bone = false;
                    // One model per bone across every submitted body, or the
                    // single tracked figure, so the whole skeleton draws as a rig.
                    if (s.body_count > 0) {
                        for (s.body_results[0..s.body_count]) |*br| {
                            for (bone_segments) |seg| {
                                const sp = segmentPose(&br.landmarks, seg[0], seg[1]) orelse continue;
                                const m = pixel_to_world.mul(sp).mul(base_model_matrix);
                                if (!drawn_bone) {
                                    r.submitModel(blit_view, mesh_view, input_texture, loaded.mesh, m, loaded.base_color, rect_aspect);
                                    drawn_bone = true;
                                } else {
                                    r.drawModelMesh(mesh_view, loaded.mesh, m, loaded.base_color, rect_aspect);
                                }
                            }
                        }
                    } else if (currentPose(s)) |body| {
                        for (bone_segments) |seg| {
                            const sp = segmentPose(&body.landmarks, seg[0], seg[1]) orelse continue;
                            const m = pixel_to_world.mul(sp).mul(base_model_matrix);
                            if (!drawn_bone) {
                                r.submitModel(blit_view, mesh_view, input_texture, loaded.mesh, m, loaded.base_color, rect_aspect);
                                drawn_bone = true;
                            } else {
                                r.drawModelMesh(mesh_view, loaded.mesh, m, loaded.base_color, rect_aspect);
                            }
                        }
                    }
                    if (!drawn_bone) r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                const aspect_ratio: f32 = tiledAspect(s, rect_width, rect_height);
                if (anchored_without_target) {
                    // The anchor's capability degradation: the frame
                    // still passes through, the mesh alone stays off.
                    r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                } else {
                    r.submitModel(blit_view, mesh_view, input_texture, loaded.mesh, model_matrix, loaded.base_color, aspect_ratio);
                }
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
        }
    }

    if (ready_count > 0) drawBrushOverlay(e, r, s, next_view_id, output_width, output_height);
    if (s.capture_requested and ready_count > 0) blitCaptureToSwapChain(e, r, next_view_id + 1);
    if (ready_count > 0) blitRecordingToSwapChain(e, r, next_view_id + 2);

    if (ready_count == 0) {
        // Either beauty or a multi-source layout produced input_texture as a
        // plain sampled texture, not a view's render target, so with no lens
        // stage to hand it off to it still needs one real draw to reach the
        // swap chain. The no-beauty, no-layout case already returned above.
        render.Renderer.setViewTarget(next_view_id, finalTarget(e, s), output_width, output_height);
        r.submitShaderPass(next_view_id, r.passthroughProgram(), input_texture, r.default_mask_texture);
        drawBrushOverlay(e, r, s, next_view_id + 1, output_width, output_height);
        if (s.capture_requested) blitCaptureToSwapChain(e, r, next_view_id + 2);
        blitRecordingToSwapChain(e, r, next_view_id + 3);
    }
}

/// The composite chain's true final-stage target: the swap chain
/// directly, or - for exactly the one frame goss_engine_capture_frame
/// requested - the dedicated capture target instead, so the chain's
/// real output lands somewhere bgfx_read_texture can read it back from
/// after the frame completes.
fn finalTarget(e: *Engine, s: *Session) ?render.Renderer.OffscreenTarget {
    if (s.capture_requested) return e.capture_target;
    if (e.live_output_requested) return e.live_output_target;
    return e.recording_frame_target;
}

/// Draws the just-composited capture target to the swap chain, so a
/// captured frame still displays normally - the same passthrough blit
/// the ready_count == 0 beauty-only path already uses to reach the
/// swap chain, reused here for the same reason.
fn blitCaptureToSwapChain(e: *Engine, r: *render.Renderer, view_id: u8) void {
    const target = e.capture_target orelse return;
    render.Renderer.setViewTarget(view_id, null, @intCast(r.width), @intCast(r.height));
    r.submitShaderPass(view_id, r.passthroughProgram(), target.texture, r.default_mask_texture);
}

/// The recording sibling of blitCaptureToSwapChain: a recorded frame's
/// composite lands in the encoder's own surface, so the swap chain
/// still needs a passthrough of it to display normally.
fn blitRecordingToSwapChain(e: *Engine, r: *render.Renderer, view_id: u8) void {
    const target = e.recording_frame_target orelse return;
    render.Renderer.setViewTarget(view_id, null, @intCast(r.width), @intCast(r.height));
    r.submitShaderPass(view_id, r.passthroughProgram(), target.texture, r.default_mask_texture);
    if (recording_binds_window) {
        if (e.recording_window_target) |window| {
            const rec = &(e.recording.?);
            render.Renderer.setViewTarget(view_id + 1, window, @intCast(rec.config.width), @intCast(rec.config.height));
            r.submitShaderPass(view_id + 1, r.passthroughProgram(), target.texture, r.default_mask_texture);
        }
    }
}

pub fn createSession(engine: *Engine, config: SessionConfig) error{OutOfMemory}!*Session {
    const session = try engine.gpa.create(Session);
    errdefer engine.gpa.destroy(session);
    const budget = if (config.frame_budget_us == 0) default_frame_budget_us else config.frame_budget_us;
    session.* = .{
        .engine = engine,
        .controller = graph.DegradeController.init(.{ .budget_us = budget }),
        .lens_graph = graph.Graph.init(engine.gpa),
        .camera_node = undefined,
    };
    errdefer session.lens_graph.deinit();
    session.camera_node = session.lens_graph.addNode(.{
        .role = .source,
        .outputs = &.{.{ .kind = .texture }},
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // a fresh graph's first node cannot violate any other EditError
    };
    try engine.sessions.append(engine.gpa, session);
    return session;
}

pub fn destroySession(session: *Session) void {
    // Unregister first so engine teardown never walks a dying session.
    for (session.engine.sessions.items, 0..) |live, i| {
        if (live == session) {
            _ = session.engine.sessions.swapRemove(i);
            break;
        }
    }
    if (session.engine.recording_session == session) _ = finishRecording(session.engine);
    teardownScript(session);
    destroySounds(session);
    destroyShaderPrograms(session);
    session.shader_programs.deinit(session.engine.gpa);
    session.shader_masks.deinit(session.engine.gpa);
    destroyLutState(session);
    session.lut_loaders.deinit(session.engine.gpa);
    session.lut_textures.deinit(session.engine.gpa);
    destroyBlendState(session);
    destroySpriteState(session);
    destroyMeshFaceState(session);
    session.blend_loaders.deinit(session.engine.gpa);
    session.blend_textures.deinit(session.engine.gpa);
    session.env_loaders.deinit(session.engine.gpa);
    session.env_textures.deinit(session.engine.gpa);
    session.sprite_loaders.deinit(session.engine.gpa);
    session.sprite_textures.deinit(session.engine.gpa);
    session.text3d_meshes.deinit(session.engine.gpa);
    session.video_textures.deinit(session.engine.gpa);
    session.sprite_rects.deinit(session.engine.gpa);
    session.sprite_opacity_params.deinit(session.engine.gpa);
    session.sprite_anims.deinit(session.engine.gpa);
    session.grade_params.deinit(session.engine.gpa);
    session.dof_params.deinit(session.engine.gpa);
    session.fog_params.deinit(session.engine.gpa);
    session.outline_params.deinit(session.engine.gpa);
    session.outline_masks.deinit(session.engine.gpa);
    session.tint_params.deinit(session.engine.gpa);
    session.tint_masks.deinit(session.engine.gpa);
    session.tint_modes.deinit(session.engine.gpa);
    session.tint_finishes.deinit(session.engine.gpa);
    session.tint_reference.deinit(session.engine.gpa);
    session.smooth_params.deinit(session.engine.gpa);
    session.smooth_masks.deinit(session.engine.gpa);
    session.matte_params.deinit(session.engine.gpa);
    session.matte_masks.deinit(session.engine.gpa);
    session.stylize_params.deinit(session.engine.gpa);
    session.edge_params.deinit(session.engine.gpa);
    session.warp_params.deinit(session.engine.gpa);
    session.reshape_params.deinit(session.engine.gpa);
    session.trail_params.deinit(session.engine.gpa);
    session.ssr_params.deinit(session.engine.gpa);
    session.env_params.deinit(session.engine.gpa);
    if (session.prev_frame_target) |target| render.Renderer.destroyOffscreenTarget(target);
    session.bloom_params.deinit(session.engine.gpa);
    session.mesh_face_loaders.deinit(session.engine.gpa);
    session.mesh_face_textures.deinit(session.engine.gpa);
    session.model_face_anchors.deinit(session.engine.gpa);
    session.model_body_anchors.deinit(session.engine.gpa);
    session.model_skeleton_anchors.deinit(session.engine.gpa);
    session.model_world_anchors.deinit(session.engine.gpa);
    if (session.physics_world) |world| world.destroy();
    session.physics_bodies.deinit(session.engine.gpa);
    session.pending_glb_colliders.deinit(session.engine.gpa);
    session.grabbable_bodies.deinit(session.engine.gpa);
    session.live_colliders.deinit(session.engine.gpa);
    session.cloth_bodies.deinit(session.engine.gpa);
    session.cloth_meshes.deinit(session.engine.gpa);
    session.cloth_cols.deinit(session.engine.gpa);
    session.hair_ids.deinit(session.engine.gpa);
    session.hair_meshes.deinit(session.engine.gpa);
    session.hair_vcount.deinit(session.engine.gpa);
    session.particle_meshes.deinit(session.engine.gpa);
    session.particle_base_meshes.deinit(session.engine.gpa);
    session.particle_ribbon_meshes.deinit(session.engine.gpa);
    session.gpu_particle_sims.deinit(session.engine.gpa);
    session.particle_systems.deinit(session.engine.gpa);
    session.fluid_sims.deinit(session.engine.gpa);
    session.fluid_base_meshes.deinit(session.engine.gpa);
    session.particle_sprite_textures.deinit(session.engine.gpa);
    destroyModelState(session);
    session.model_loaders.deinit(session.engine.gpa);
    session.model_meshes.deinit(session.engine.gpa);
    if (session.depth_data.len != 0) session.engine.gpa.free(session.depth_data);
    if (session.depth_scratch.len != 0) session.engine.gpa.free(session.depth_scratch);
    if (session.frame_stage.len != 0) session.engine.gpa.free(session.frame_stage);
    destroyChainOrder(session);
    if (session.active_lens) |*lens| lens.deinit(&session.lens_graph);
    session.active_lens = null;
    session.lens_graph.deinit();
    if (session.beauty_chain) |chain| beauty.destroy(session.engine.gpa, chain);
    session.beauty_chain = null;
    destroyBeautyCompositing(session);
    destroyWebBeautyTargets(session);
    if (session.face_tracking) |worker| tracking.destroy(worker);
    session.face_tracking = null;
    if (session.hand_tracking) |worker| tracking.hand_worker.destroy(worker);
    session.hand_tracking = null;
    if (session.pose_tracking) |worker| tracking.pose_worker.destroy(worker);
    session.pose_tracking = null;
    if (session.segmentation_worker) |worker| segmentation.destroy(worker);
    session.segmentation_worker = null;
    clearSegmentationTextures(session);
    destroySegmentationStores(session);
    releaseCurrentFrame(session);
    if (session.engine.renderer != null) {
        session.preview_bgra.deinit();
        session.preview_y.deinit();
        session.preview_uv.deinit();
        for (0..session.source_count) |i| session.source_tex[i].deinit();
    }
    session.engine.gpa.destroy(session);
}

/// Tears down the GPU beauty compositing bridge's platform surfaces -
/// safe to call whether or not they were ever actually created (both
/// goss_session_disable_beauty and destroySession reach this unconditionally).
fn destroyBeautyCompositing(session: *Session) void {
    if (session.beauty_input_target) |target| render.Renderer.destroyOffscreenTarget(target);
    session.beauty_input_target = null;
    session.beauty_input_native = null;
    session.beauty_input_persistent.deinit();
    session.beauty_output_persistent.deinit();
    if (session.engine.renderer) |*r| {
        if (session.beauty_input_android_texture) |tex| r.destroyTexture(tex);
        if (session.beauty_output_texture) |tex| r.destroyTexture(tex);
    }
    session.beauty_input_android_texture = null;
    session.beauty_output_texture = null;
    session.beauty_output_native = null;
    if (session.beauty_input) |surface| beauty.inputSurfaceDestroy(session.engine.gpa, surface);
    session.beauty_input = null;
    if (session.beauty_interop) |interop| beauty.interopDestroy(session.engine.gpa, interop);
    session.beauty_interop = null;
}

/// Tears down beauty.face/beauty.reshape's own offscreen targets on
/// web - safe to call whether or not they were ever created, same as
/// destroyBeautyCompositing above.
fn destroyWebBeautyTargets(session: *Session) void {
    for ([_]*?render.Renderer.OffscreenTarget{
        &session.web_beauty_blur_h_target,
        &session.web_beauty_mean_target,
        &session.web_beauty_reshape_target,
        &session.web_beauty_makeup_targets[0],
        &session.web_beauty_makeup_targets[1],
    }) |slot| {
        if (slot.*) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.* = null;
    }
    session.web_beauty_targets_width = 0;
    session.web_beauty_targets_height = 0;
    if (session.engine.renderer) |*r| {
        for (&session.web_beauty_lut_textures) |*slot| {
            if (slot.*) |texture| r.destroyTexture(texture);
            slot.* = null;
        }
        if (session.web_beauty_lipstick_texture) |tex| r.destroyTexture(tex);
        session.web_beauty_lipstick_texture = null;
        if (session.web_beauty_blush_texture) |tex| r.destroyTexture(tex);
        session.web_beauty_blush_texture = null;
    }
}

fn releaseCurrentFrame(session: *Session) void {
    const current = session.current orelse return;
    if (!current.owns_textures) {
        session.current = null;
        return;
    }
    if (session.engine.renderer) |*r| {
        switch (current.preview) {
            .bgra => |p| r.destroyTexture(p.texture),
            .nv12 => |p| {
                r.destroyTexture(p.y);
                r.destroyTexture(p.uv);
            },
        }
    }
    session.current = null;
}

fn thermalFromC(value: c_int) graph.degrade.ThermalState {
    return switch (value) {
        0 => .nominal,
        1 => .fair,
        2 => .serious,
        else => .critical,
    };
}

/// Allocates from the engine allocator for embedders that cannot address
/// module memory themselves, the wasm host being the one that matters.
/// Pair every allocation with goss_free of the same size.
pub export fn goss_alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;
    const slice = abiAllocator().alloc(u8, size) catch return null;
    return slice.ptr;
}

pub export fn goss_free(ptr: ?[*]u8, size: usize) void {
    const p = ptr orelse return;
    if (size == 0) return;
    abiAllocator().free(p[0..size]);
}

pub export fn goss_abi_version() u32 {
    return (@as(u32, abi_major) << 16) | abi_minor;
}

pub export fn goss_engine_create(config: ?*const EngineConfig, out_engine: ?**Engine) Status {
    const out = out_engine orelse return .invalid_argument;
    const cfg: EngineConfig = if (config) |c| c.* else .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 };
    const engine = createEngine(abiAllocator(), cfg) catch return .out_of_memory;
    out.* = engine;
    return .ok;
}

pub export fn goss_engine_destroy(engine: ?*Engine) void {
    destroyEngine(engine orelse return);
}

/// Untrusted frame dimensions must fit the u16 the render and capture paths
/// narrow them to; reject 0 or over 65535 before any cast rather than trap
/// inside the ABI with a host width the caller cannot recover from.
fn validDims(width: u32, height: u32) bool {
    return width != 0 and width <= 65535 and height != 0 and height <= 65535;
}

pub export fn goss_engine_init_renderer(engine: ?*Engine, desc: ?*const RendererDesc) Status {
    const e = engine orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    if (!validDims(d.width, d.height)) return .invalid_argument;
    if (e.renderer != null) return .invalid_argument;
    e.renderer = render.Renderer.init(e.gpa, .{
        .native_window_handle = d.native_window_handle,
        .width = d.width,
        .height = d.height,
    }) catch return .renderer_unavailable;
    return .ok;
}

pub export fn goss_engine_resize(engine: ?*Engine, width: u32, height: u32) void {
    const e = engine orelse return;
    if (e.renderer) |*r| r.resize(width, height);
}

const screenshot_path_max = 480;

/// Requests a screenshot of the next presented frame, written as
/// path ++ ".tga" through the renderer's own default callback (the same
/// mechanism harness/conformance.zig already drives internally, exposed
/// here so a real SDK target - the ios simulator conformance run this
/// exists for - can trigger it too). Debug/test tooling only; no SDK
/// ships this behind a user-facing control.
pub export fn goss_engine_request_screenshot(engine: ?*Engine, path: ?[*]const u8, path_len: usize) Status {
    const e = engine orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const p = path orelse return .invalid_argument;
    if (path_len == 0 or path_len >= screenshot_path_max) return .invalid_argument;
    var buf: [screenshot_path_max]u8 = undefined;
    @memcpy(buf[0..path_len], p[0..path_len]);
    buf[path_len] = 0;
    const zpath: [:0]u8 = buf[0..path_len :0];
    r.requestScreenshot(zpath.ptr);
    return .ok;
}

/// Begins an encoder frame and wraps its surface as this frame's final
/// render target. Null while a pool slot warms up (its first wrap
/// cannot land the same frame) - that frame displays normally and is
/// counted, never silently lost.
fn prepareRecordingFrame(e: *Engine, r: *render.Renderer) ?media_recording.Frame {
    var rec = &(e.recording.?);
    const frame = rec.beginFrame() catch return null;
    const width: u16 = @intCast(rec.config.width);
    const height: u16 = @intCast(rec.config.height);
    const key = @intFromPtr(frame.native_texture);
    if (recording_binds_window) {
        // The window is not sampleable, so the composite lands in the
        // capture target (sampleable) and re-presents into both the
        // swap chain and the encoder window each frame.
        const slot = e.recording_slots.getOrPut(e.gpa, key) catch {
            rec.abortFrame(frame);
            return null;
        };
        if (!slot.found_existing) slot.value_ptr.* = .{};
        if (slot.value_ptr.target == null) {
            slot.value_ptr.target = render.Renderer.createWindowTarget(frame.native_texture, width, height) catch {
                e.recording_warmups += 1;
                rec.abortFrame(frame);
                return null;
            };
        }
        ensureCaptureTarget(e, @intCast(r.width), @intCast(r.height)) catch {
            e.recording_warmups += 1;
            rec.abortFrame(frame);
            return null;
        };
        e.recording_window_target = slot.value_ptr.target;
        e.recording_frame_target = e.capture_target;
        return frame;
    }
    const slot = e.recording_slots.getOrPut(e.gpa, key) catch {
        rec.abortFrame(frame);
        return null;
    };
    if (!slot.found_existing) slot.value_ptr.* = .{};
    const wrapped = r.wrapExternalRenderTarget(&slot.value_ptr.persistent, width, height, render.c.BGFX_TEXTURE_FORMAT_BGRA8, key) orelse {
        e.recording_warmups += 1;
        rec.abortFrame(frame);
        return null;
    };
    if (slot.value_ptr.target == null) {
        slot.value_ptr.target = render.Renderer.createExternalTarget(wrapped) catch {
            e.recording_warmups += 1;
            rec.abortFrame(frame);
            return null;
        };
    }
    e.recording_frame_target = slot.value_ptr.target;
    return frame;
}

/// Commits the pending frame whose GPU work two engine frames have now
/// finished, then queues this frame's own. Non-monotonic timestamps
/// abort rather than fail the writer.
fn queueRecordingCommit(e: *Engine, frame: ?media_recording.Frame, timestamp_us: i64) void {
    var rec = &(e.recording.?);
    const at = e.recording_pending_at % 2;
    if (e.recording_pending[at]) |aged| {
        if (aged.timestamp_us > e.recording_last_timestamp) {
            rec.commitFrame(aged.frame, aged.timestamp_us) catch {
                e.recording_dropped += 1;
            };
            e.recording_last_timestamp = aged.timestamp_us;
        } else {
            rec.abortFrame(aged.frame);
            e.recording_dropped += 1;
        }
        e.recording_pending[at] = null;
    }
    if (frame) |live| {
        e.recording_pending[at] = .{ .frame = live, .timestamp_us = timestamp_us };
    }
    e.recording_pending_at +%= 1;
}

/// Flushes the in-flight tail, finalizes the container, and releases
/// every recording resource. Returns whether the file finalized.
fn finishRecording(e: *Engine) bool {
    var ok = true;
    if (e.recording) |*rec| {
        if (e.renderer) |*r| {
            _ = r.frame();
            _ = r.frame();
        }
        for (0..2) |_| queueRecordingCommit(e, null, 0);
        rec.finish() catch {
            ok = false;
        };
    } else {
        ok = false;
    }
    var it = e.recording_slots.valueIterator();
    while (it.next()) |slot| {
        if (slot.target) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.persistent.deinit();
    }
    e.recording_slots.deinit(e.gpa);
    e.recording_slots = .empty;
    e.recording = null;
    e.recording_session = null;
    e.recording_frame_target = null;
    e.recording_window_target = null;
    e.recording_pending = .{ null, null };
    e.recording_pending_at = 0;
    e.recording_last_timestamp = std.math.minInt(i64);
    return ok;
}

pub export fn goss_engine_render_frame(engine: ?*Engine, session: ?*Session) Status {
    const e = engine orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    e.recording_frame_target = null;
    var recording_frame: ?media_recording.Frame = null;
    var recording_timestamp: i64 = 0;
    if (session) |s| {
        pollLutLoaders(s, r, s.engine.gpa);
        pollBlendLoaders(s, r, s.engine.gpa);
        pollEnvLoaders(s, r, s.engine.gpa);
        pollMeshFaceLoaders(s, r, s.engine.gpa);
        pollSpriteLoaders(s, r, s.engine.gpa);
        pollModelLoaders(s, r, s.engine.gpa);
        pollSegmentationMask(s);
        pollDepthOcclusion(s);
        pollLandmarkMattes(s);
        if (e.recording != null and e.recording_session == s and !s.capture_requested) {
            if (s.current) |current| {
                recording_frame = prepareRecordingFrame(e, r);
                recording_timestamp = current.desc.timestamp_us;
            }
        }
        if (s.physics_world) |world| {
            if (s.current) |current| {
                const now_us = current.desc.timestamp_us;
                if (s.physics_last_us != 0 and now_us > s.physics_last_us) {
                    const dt: f32 = @as(f32, @floatFromInt(now_us - s.physics_last_us)) / 1_000_000.0;
                    // A grabbed body is dragged toward the pointer each tick; the
                    // kinematic move imparts the velocity it throws with on release.
                    if (s.grab_body) |gid| world.moveBody(gid, s.grab_target, @min(dt, 0.25));
                    // A head collider is driven to the tracked head, its landmark
                    // pose mapped into world space the same way face-anchored
                    // content is, so lens content collides with the head.
                    if (s.head_collider_body) |hid| {
                        if (headWorldPosition(s, current)) |wp| world.moveBody(hid, wp, @min(dt, 0.25));
                    }
                    world.step(@min(dt, 0.25));
                }
                s.physics_last_us = now_us;
            }
        }
        if (s.current) |current| {
            const rotation = (current.desc.flags & frame_rotation_mask) >> frame_rotation_shift;
            const mirror = resolveMirror(s, current.desc.flags);
            // Always through renderCompositeChain, which owns the one
            // authoritative "is anything actually active" check and its
            // own view-0-target reset for the plain-preview case. This
            // used to duplicate that same check here first (skipping
            // renderCompositeChain, and its reset, whenever nothing was
            // active) - a real, found bug: once a frame went through
            // the composite path and rebound view 0 to an offscreen
            // target, this outer check took over again on the very next
            // frame beauty/chain state went back to inactive and called
            // submitPreview directly, with view 0 still pointed at that
            // now-stale offscreen target - the canvas simply stopped
            // updating. Same class of drift anyBeautyActive's own
            // comment already names for exactly this dispatch: two call
            // sites deciding the same thing separately eventually
            // disagree.
            renderCompositeChain(e, r, s, current, rotation, mirror) catch {
                // A chain target failed to (re)create - present the
                // plain preview rather than nothing this frame.
                r.submitPreview(0, current.preview, rotation * 90, mirror);
            };
        } else {
            r.touch();
        }
    } else {
        r.touch();
    }
    if (e.recording != null and (recording_frame != null or e.recording_pending[e.recording_pending_at % 2] != null)) {
        queueRecordingCommit(e, recording_frame, recording_timestamp);
    } else if (recording_frame) |frame| {
        e.recording.?.abortFrame(frame);
    }
    _ = r.frame();
    return .ok;
}

/// Renders one frame the same way goss_engine_render_frame does, and also
/// reads its composited output back into out_data as RGBA8, row 0
/// first. The WebGPU render path's own equivalent to what a WebGL2
/// canvas's readPixels already gives a caller directly - WebGPU has no
/// synchronous equivalent, so this does the capture on the render side
/// instead. out_width/out_height report the real image size; out_data
/// must be at least out_width * out_height * 4 bytes, reported through
/// the same two out params, and the call fails with invalid_argument
/// rather than truncating silently if out_capacity is smaller.
/// render.Renderer.readTexture only enqueues a read - bgfx's own
/// documented contract (bgfx_p.h's Context::readTexture) is that its
/// return value is the frame number bgfx_frame() must reach before the
/// buffer is safe to read, backend-dependent and not always the same
/// small number of extra calls, so this loops on frame()'s own return
/// value rather than assuming a fixed count.
/// Past every id the composite chain can allocate, so the readback
/// blit always runs after the last draw of the frame.
const capture_blit_view: u8 = 255;

/// Renders the session's current frame with capture enabled and
/// returns the landed capture target. Shared by the raw-pixel and
/// encoded-photo capture operations below.
fn renderForCapture(e: *Engine, r: *render.Renderer, s: *Session) ?render.Renderer.OffscreenTarget {
    s.capture_requested = true;
    defer s.capture_requested = false;

    pollLutLoaders(s, r, s.engine.gpa);
    pollBlendLoaders(s, r, s.engine.gpa);
    pollEnvLoaders(s, r, s.engine.gpa);
    pollSpriteLoaders(s, r, s.engine.gpa);
    pollModelLoaders(s, r, s.engine.gpa);
    pollSegmentationMask(s);
    pollDepthOcclusion(s);
    pollLandmarkMattes(s);
    if (s.current) |current| {
        const rotation = (current.desc.flags & frame_rotation_mask) >> frame_rotation_shift;
        const mirror = resolveMirror(s, current.desc.flags);
        renderCompositeChain(e, r, s, current, rotation, mirror) catch {
            r.submitPreview(0, current.preview, rotation * 90, mirror);
        };
    } else {
        r.touch();
    }
    _ = r.frame();
    return e.capture_target;
}

pub export fn goss_engine_capture_frame(engine: ?*Engine, session: ?*Session, out_data: ?[*]u8, out_capacity: usize, out_width: ?*u32, out_height: ?*u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;

    const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
    w.* = e.capture_width;
    h.* = e.capture_height;
    const full_size = @as(usize, e.capture_width) * @as(usize, e.capture_height) * 4;
    if (full_size == 0) return .ok;
    if (out_capacity < full_size) return .invalid_argument;

    const staging = e.capture_staging orelse return .renderer_unavailable;
    render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
    const ready_frame = render.Renderer.readTexture(staging, data);
    while (r.frame() < ready_frame) {}
    return .ok;
}

/// Swaps the red and blue channels of a packed 8-bit-per-channel image in
/// place - RGBA to BGRA and back, the one difference a WebRTC source needs.
fn swapRedBlue(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const red = pixels[i];
        pixels[i] = pixels[i + 2];
        pixels[i + 2] = red;
    }
}

/// The supported per-frame composited output for a live broadcast source:
/// renders the current frame with the lens chain baked in and reads it back
/// in a WebRTC-friendly format (rgba8, bgra8 or nv12), so a LiveKit or WebRTC
/// custom source publishes it directly. out_data holds the format's frame size.
pub export fn goss_engine_capture_live_frame(engine: ?*Engine, session: ?*Session, format: u32, out_data: ?[*]u8, out_capacity: usize, out_width: ?*u32, out_height: ?*u32) Status {
    if (format != pixel_format_rgba8 and format != pixel_format_bgra8 and format != pixel_format_nv12) return .invalid_argument;
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;

    const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
    w.* = e.capture_width;
    h.* = e.capture_height;
    const wpx: usize = e.capture_width;
    const hpx: usize = e.capture_height;
    const pixels = wpx * hpx;
    if (pixels == 0) return .ok;
    const rgba_size = pixels * 4;
    const y_size = pixels;
    const uv_size = 2 * ((wpx + 1) / 2) * ((hpx + 1) / 2);
    const out_size = if (format == pixel_format_nv12) y_size + uv_size else rgba_size;
    if (out_capacity < out_size) return .invalid_argument;
    const staging = e.capture_staging orelse return .renderer_unavailable;

    // NV12 reads back RGBA into the reused scratch and packs down; the packed
    // planes are smaller than the readback, so they cannot share out_data.
    if (format == pixel_format_nv12) {
        if (e.capture_convert.len < rgba_size) {
            if (e.capture_convert.len > 0) e.gpa.free(e.capture_convert);
            e.capture_convert = e.gpa.alloc(u8, rgba_size) catch return .out_of_memory;
        }
        render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
        const ready_frame = render.Renderer.readTexture(staging, e.capture_convert.ptr);
        while (r.frame() < ready_frame) {}
        // The readback is packed RGBA; rgbaToNv12 reads R,G,B in that order,
        // so it needs no swizzle. BT.709 video range, the broadcast default.
        const conv = math.color.rgbToYuv(.bt709, .video);
        math.color.rgbaToNv12(e.capture_convert[0..rgba_size], wpx, hpx, conv, data[0..y_size], data[y_size..out_size]);
        return .ok;
    }

    render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
    const ready_frame = render.Renderer.readTexture(staging, data);
    while (r.frame() < ready_frame) {}
    if (format == pixel_format_bgra8) swapRedBlue(data[0..rgba_size]);
    return .ok;
}

test "swapRedBlue turns rgba into bgra" {
    var pixels = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    swapRedBlue(&pixels);
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10, 40, 70, 60, 50, 80 }, &pixels);
}

/// Renders the current frame with the lens chain baked in, landing the final
/// composite in whatever finalTarget routes it to - here the live-output
/// surface - with no readback tail. The zero-copy sibling of renderForCapture.
fn renderLiveComposite(e: *Engine, r: *render.Renderer, s: *Session) void {
    pollLutLoaders(s, r, s.engine.gpa);
    pollBlendLoaders(s, r, s.engine.gpa);
    pollEnvLoaders(s, r, s.engine.gpa);
    pollSpriteLoaders(s, r, s.engine.gpa);
    pollModelLoaders(s, r, s.engine.gpa);
    pollSegmentationMask(s);
    pollDepthOcclusion(s);
    pollLandmarkMattes(s);
    if (s.current) |current| {
        const rotation = (current.desc.flags & frame_rotation_mask) >> frame_rotation_shift;
        const mirror = resolveMirror(s, current.desc.flags);
        renderCompositeChain(e, r, s, current, rotation, mirror) catch {
            r.submitPreview(0, current.preview, rotation * 90, mirror);
        };
    } else {
        r.touch();
    }
    _ = r.frame();
}

/// Renders the composited frame straight into a caller-supplied external
/// texture (an id<MTLTexture> over an IOSurface-backed CVPixelBuffer on Apple),
/// zero-copy - the mechanism recording already uses, for a live source. Returns
/// .again while a new handle or size warms up bgfx's override; re-submit next.
/// Bounds live_output_slots for hosts that publish from churning buffers
/// rather than a fixed pool: a fresh handle past this many wraps evicts
/// the least recently rendered one instead of growing for the engine's
/// lifetime. Encoder pools cycle a handful of buffers; eight is roomy.
const max_live_output_slots = 8;

fn evictStalestLiveSlot(e: *Engine) void {
    var stalest_key: ?usize = null;
    var stalest_used: u64 = std.math.maxInt(u64);
    var it = e.live_output_slots.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.last_used <= stalest_used) {
            stalest_used = entry.value_ptr.last_used;
            stalest_key = entry.key_ptr.*;
        }
    }
    const key = stalest_key orelse return;
    if (e.live_output_slots.fetchRemove(key)) |removed| {
        var slot = removed.value;
        if (slot.target) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.persistent.deinit();
    }
}

pub export fn goss_engine_render_to_live_texture(engine: ?*Engine, session: ?*Session, native_handle: u64, width: u32, height: u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    if (native_handle == 0 or width == 0 or height == 0) return .invalid_argument;

    const w: u16 = @intCast(width);
    const h: u16 = @intCast(height);
    const key: usize = @intCast(native_handle);
    if (!e.live_output_slots.contains(key) and e.live_output_slots.count() >= max_live_output_slots) {
        evictStalestLiveSlot(e);
    }
    const slot = e.live_output_slots.getOrPut(e.gpa, key) catch return .out_of_memory;
    if (!slot.found_existing) slot.value_ptr.* = .{};
    e.live_output_seq += 1;
    slot.value_ptr.last_used = e.live_output_seq;

    const wrapped = r.wrapExternalRenderTarget(&slot.value_ptr.persistent, w, h, render.c.BGFX_TEXTURE_FORMAT_BGRA8, key) orelse return .again;
    if (slot.value_ptr.target == null) {
        slot.value_ptr.target = render.Renderer.createExternalTarget(wrapped) catch return .renderer_unavailable;
    }

    e.live_output_target = slot.value_ptr.target;
    e.live_output_requested = true;
    defer {
        e.live_output_requested = false;
        e.live_output_target = null;
    }
    renderLiveComposite(e, r, s);
    return .ok;
}

/// Releases the persistent wrap goss_engine_render_to_live_texture keeps
/// for one native texture, for a host retiring a publish surface before
/// the engine goes away. Unknown handles report invalid_argument.
pub export fn goss_engine_release_live_texture(engine: ?*Engine, native_handle: u64) Status {
    const e = engine orelse return .invalid_argument;
    if (native_handle == 0) return .invalid_argument;
    const key = std.math.cast(usize, native_handle) orelse return .invalid_argument;
    var removed = e.live_output_slots.fetchRemove(key) orelse return .invalid_argument;
    if (removed.value.target) |target| render.Renderer.destroyOffscreenTarget(target);
    removed.value.persistent.deinit();
    return .ok;
}

/// Captures the composited frame and encodes it as a PNG into out_data.
/// out_len always receives the encoded size, so a too-small buffer
/// (invalid_argument) tells the caller exactly what to retry with.
/// Deterministic: the same composited pixels, the same bytes.
pub export fn goss_engine_capture_photo(engine: ?*Engine, session: ?*Session, out_data: ?[*]u8, out_capacity: usize, out_len: ?*usize, out_width: ?*u32, out_height: ?*u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;
    len_out.* = 0;

    const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
    w.* = e.capture_width;
    h.* = e.capture_height;
    const full_size = @as(usize, e.capture_width) * @as(usize, e.capture_height) * 4;
    if (full_size == 0) return .ok;

    const gpa = e.gpa;
    const pixels = gpa.alloc(u8, full_size) catch return .out_of_memory;
    defer gpa.free(pixels);
    const staging = e.capture_staging orelse return .renderer_unavailable;
    render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
    const ready_frame = render.Renderer.readTexture(staging, pixels.ptr);
    while (r.frame() < ready_frame) {}

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    png.encodeRgba(gpa, &encoded, pixels, e.capture_width, e.capture_height) catch return .out_of_memory;
    len_out.* = encoded.items.len;
    if (out_capacity < encoded.items.len) return .invalid_argument;
    @memcpy(data[0..encoded.items.len], encoded.items);
    return .ok;
}

/// Harness-facing re-exports of the recording backend's proof surface
/// (decode-probe and frame export); never part of the C ABI.
pub const recordingProbe = media_recording.probe;
pub const recordingProbeAudio = media_recording.probeAudio;
pub const recordingExportFrame = media_recording.exportFrame;
pub const recording_supported = media_recording.supported;

/// Harness-facing re-export of the photo backend's decode proof
/// surface; never part of the C ABI.
pub const photoDecode = photo.decode;
pub const photoProbeMetadata = photo.probeMetadata;
pub const photo_supported = photo.supported;

/// Encodes RGBA8 as a lossy photo into the caller buffer, setting
/// out_len so a too-small buffer can be retried. JPEG is the engine's
/// own encoder - on every target, never gated on a platform backend;
/// HEIC routes to the platform. color_space picks the JPEG ICC profile.
fn encodeLossyPhoto(gpa: std.mem.Allocator, pixels: []const u8, width: u32, height: u32, format: u32, quality: u32, color_space: u32, orientation: u8, data: []u8, out_len: *usize) Status {
    if (format == 1) {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(gpa);
        jpeg.encode(gpa, &encoded, pixels, width, height, .{
            .quality = if (quality == 0) 90 else @intCast(quality),
            .orientation = orientation,
            .icc_profile = color.iccProfile(color_space),
        }) catch return .out_of_memory;
        out_len.* = encoded.items.len;
        if (data.len < encoded.items.len) return .invalid_argument;
        @memcpy(data[0..encoded.items.len], encoded.items);
        return .ok;
    }
    if (!photo.supported) return .unsupported;
    photo.encode(pixels, width, height, @enumFromInt(format), quality, data, out_len) catch return .invalid_argument;
    return .ok;
}

/// Captures the composited frame as a photo (1 = JPEG, 2 = HEIC) at
/// quality percent; out_len always receives the needed size. Lossy and
/// not bit-stable across runs, so the plain goss_engine_capture_photo
/// stays the deterministic PNG surface.
pub export fn goss_engine_capture_photo_as(engine: ?*Engine, session: ?*Session, format: u32, quality: u32, out_data: ?[*]u8, out_capacity: usize, out_len: ?*usize, out_width: ?*u32, out_height: ?*u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;
    len_out.* = 0;
    if (format < 1 or format > 2 or quality > 100) return .invalid_argument;

    const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
    w.* = e.capture_width;
    h.* = e.capture_height;
    const full_size = @as(usize, e.capture_width) * @as(usize, e.capture_height) * 4;
    if (full_size == 0) return .ok;

    const gpa = e.gpa;
    const pixels = gpa.alloc(u8, full_size) catch return .out_of_memory;
    defer gpa.free(pixels);
    const staging = e.capture_staging orelse return .renderer_unavailable;
    render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
    const ready_frame = render.Renderer.readTexture(staging, pixels.ptr);
    while (r.frame() < ready_frame) {}

    return encodeLossyPhoto(gpa, pixels, e.capture_width, e.capture_height, format, quality, 0, 1, data[0..out_capacity], len_out);
}

pub const WorldState = extern struct {
    tracking_state: u32,
    world_from_camera: [16]f32,
    projection: [16]f32,
    timestamp_us: i64,
};

pub const WorldPlane = extern struct {
    id: u64,
    pose: [16]f32,
    extent_x: f32,
    extent_z: f32,
    classification: u32,
};

pub const WorldAnchor = extern struct {
    id: u64,
    pose: [16]f32,
};

pub const WorldLight = extern struct {
    ambient_intensity: f32,
    color_temperature_kelvin: f32,
};

pub const max_world_planes = 32;
pub const max_world_anchors = 32;

/// Feeds the platform's world understanding into the session: drives
/// the world.tracking_state signal and world-anchored lens content.
/// Planes and anchors beyond the fixed capacity are dropped oldest
/// last (the platform lists closest-first), counted, never silent.
pub export fn goss_session_submit_world(session: ?*Session, state: ?*const WorldState, planes: ?[*]const WorldPlane, plane_count: usize, anchors: ?[*]const WorldAnchor, anchor_count: usize, light: ?*const WorldLight) Status {
    const s = session orelse return .invalid_argument;
    const st = state orelse return .invalid_argument;
    if (st.tracking_state > 3) return .invalid_argument;
    if (plane_count > 0 and planes == null) return .invalid_argument;
    if (anchor_count > 0 and anchors == null) return .invalid_argument;

    s.world.state = st.*;
    s.world.plane_count = @min(plane_count, max_world_planes);
    if (planes) |p| @memcpy(s.world.planes[0..s.world.plane_count], p[0..s.world.plane_count]);
    s.world.dropped_planes +|= @intCast(plane_count -| max_world_planes);
    s.world.anchor_count = @min(anchor_count, max_world_anchors);
    if (anchors) |a| @memcpy(s.world.anchors[0..s.world.anchor_count], a[0..s.world.anchor_count]);
    s.world.dropped_anchors +|= @intCast(anchor_count -| max_world_anchors);
    if (light) |l| s.world.light = l.*;
    s.world_engine_fed = true;
    return .ok;
}

pub const RecordingConfig = extern struct {
    /// Zero picks the renderer's own output size (rounded down to
    /// even, as the encoders require).
    width: u32,
    height: u32,
    /// Zero lets the backend pick a rate fitting the dimensions.
    bitrate_bps: u32,
    /// 0 = H.264, 1 = HEVC.
    codec: u32,
};

/// Starts recording session's rendered frames, effects baked in, into
/// the file at path. One recording per engine; every subsequent
/// goss_engine_render_frame of this session appends one video frame at
/// the frame's own timestamp until goss_engine_recording_stop.
pub export fn goss_engine_recording_start(engine: ?*Engine, session: ?*Session, path: ?[*]const u8, path_len: usize, config: ?*const RecordingConfig) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const p = path orelse return .invalid_argument;
    if (path_len == 0) return .invalid_argument;
    if (!media_recording.supported) return .unsupported;
    if (e.recording != null) return .invalid_argument;

    const cfg: RecordingConfig = if (config) |c_| c_.* else .{ .width = 0, .height = 0, .bitrate_bps = 0, .codec = 0 };
    const width = (if (cfg.width == 0) @as(u32, r.width) else cfg.width) & ~@as(u32, 1);
    const height = (if (cfg.height == 0) @as(u32, r.height) else cfg.height) & ~@as(u32, 1);
    if (width == 0 or height == 0 or cfg.codec > 1) return .invalid_argument;

    e.recording = media_recording.Recording.start(p[0..path_len], .{
        .width = width,
        .height = height,
        .bitrate_bps = cfg.bitrate_bps,
        .codec = @enumFromInt(cfg.codec),
    }) catch return .invalid_argument;
    e.recording_session = s;
    e.recording_warmups = 0;
    e.recording_dropped = 0;
    return .ok;
}

/// Stops the engine's recording and finalizes the container, flushing
/// the frames still in flight first.
pub export fn goss_engine_recording_stop(engine: ?*Engine) Status {
    const e = engine orelse return .invalid_argument;
    if (e.recording == null) return .invalid_argument;
    return if (finishRecording(e)) .ok else .invalid_argument;
}

/// Feeds interleaved f32 PCM into the session: the engine's own level
/// and beat analysis always consumes it (driving audio.level and
/// audio.beat triggers), and an active recording of this session muxes
/// it as the audio track where the backend supports audio.
pub export fn goss_session_submit_audio(session: ?*Session, samples: ?[*]const f32, frame_count: u32, sample_rate: u32, channels: u32, timestamp_us: i64) Status {
    const s = session orelse return .invalid_argument;
    const data = samples orelse return .invalid_argument;
    if (frame_count == 0 or sample_rate == 0 or channels == 0 or channels > 8) return .invalid_argument;
    const slice = data[0 .. @as(usize, frame_count) * channels];
    s.audio.feed(slice, channels);
    s.audio_engine_fed = true;

    const e = s.engine;
    if (e.recording != null and e.recording_session == s) {
        if (media_recording.audio_supported) {
            var rec = &(e.recording.?);
            rec.submitAudio(slice, frame_count, sample_rate, channels, timestamp_us) catch {
                e.recording_dropped += 1;
            };
        }
    }
    return .ok;
}

pub const CaptureConfig = extern struct {
    /// Zero captures at the submitted frame's own resolution, so the
    /// still is not clamped to the preview swap chain.
    width: u32,
    height: u32,
    /// Reserved for the supersample factor; 0 or 1 means 1:1 today.
    supersample: u32,
    /// 0 = PNG, 1 = JPEG, 2 = HEIC (the photo format enum).
    format: u32,
    /// 1..100 for the lossy formats; 0 = the backend default.
    quality: u32,
    /// 0 = sRGB, 1 = Display-P3, 2 = Rec2020 - the gamut the file is
    /// tagged with (PNG chunks, JPEG ICC).
    color_space: u32 = 0,
    /// 8 or 16 bits per channel; 16 needs PNG and the HDR capture target.
    bit_depth: u32 = 8,
};

/// Composites the still at the configured resolution (the submitted
/// frame's own size when width and height are zero), independent of
/// the preview swap chain, and encodes it. PNG has no size ceiling;
/// JPEG and HEIC need the platform photo backend.
pub export fn goss_engine_capture_still(engine: ?*Engine, session: ?*Session, config: ?*const CaptureConfig, out_data: ?[*]u8, out_capacity: usize, out_len: ?*usize, out_width: ?*u32, out_height: ?*u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;
    const cfg: CaptureConfig = if (config) |c_| c_.* else .{ .width = 0, .height = 0, .supersample = 0, .format = 0, .quality = 0, .color_space = 0, .bit_depth = 8 };
    len_out.* = 0;
    if (cfg.format > 2) return .invalid_argument;
    // JPEG is the engine's own encoder, present everywhere; only HEIC
    // still needs the platform photo backend.
    if (cfg.format == 2 and !photo.supported) return .unsupported;
    // 16-bit output is the PNG-only high-bit-depth path.
    if (cfg.bit_depth == 16 and cfg.format != 0) return .invalid_argument;

    const current = s.current orelse return .again;
    const still_w: u16 = if (cfg.width != 0) @intCast(@min(cfg.width, 65535)) else @intCast(current.desc.width);
    const still_h: u16 = if (cfg.height != 0) @intCast(@min(cfg.height, 65535)) else @intCast(current.desc.height);
    if (still_w == 0 or still_h == 0) return .invalid_argument;

    // Supersample: render at N times the still size then box-downsample,
    // for photo-grade anti-aliased edges. 16384 is the conservative
    // texture-size floor; larger renders wait on the tiling path.
    const supersample: u16 = switch (cfg.supersample) {
        0, 1 => 1,
        2 => 2,
        4 => 4,
        else => return .invalid_argument,
    };
    const render_w: u32 = @as(u32, still_w) * supersample;
    const render_h: u32 = @as(u32, still_h) * supersample;
    // Above the max texture size a single target is impossible, so the
    // output composites in tiles and stitches. The perspective 3D content
    // (model, cloth, hair, particles) tiles through the per-tile
    // sub-frustum crop; the screen-space face-mesh overlay and rotated or
    // mirrored plain frames stay single-target under the cap.
    const tile_cap: u32 = if (s.capture_tile_cap != 0) s.capture_tile_cap else 16384;
    const has_screenspace_mesh = s.mesh_face_textures.count() > 0;
    const rot = (current.desc.flags & frame_rotation_mask) >> frame_rotation_shift;
    const upright = rot == 0 and (current.desc.flags & frame_flag_mirror) == 0;
    const tileable = !has_screenspace_mesh and upright;
    if ((render_w > tile_cap or render_h > tile_cap) and !tileable) return .invalid_argument;

    const gpa = e.gpa;
    const render_size = @as(usize, render_w) * @as(usize, render_h) * 4;
    if (render_size == 0) {
        w.* = 0;
        h.* = 0;
        return .ok;
    }

    const cols: u32 = if (render_w > tile_cap) (render_w + tile_cap - 1) / tile_cap else 1;
    const rows: u32 = if (render_h > tile_cap) (render_h + tile_cap - 1) / tile_cap else 1;
    // The whole frame's aspect, so tiled 3D draws keep the scene's shape.
    if (cols > 1 or rows > 1) s.capture_aspect = @as(f32, @floatFromInt(render_w)) / @as(f32, @floatFromInt(render_h));
    defer {
        s.capture_res_width = 0;
        s.capture_res_height = 0;
        s.capture_tile = null;
        s.capture_aspect = 0;
    }

    // Streaming tiled PNG: encode each tile-row band as it finishes and
    // free it, so peak memory is one band plus the compressed output, not
    // the whole render buffer - what lets a large capture fit in a phone's
    // RAM. Supersample and the lossy formats keep the full-buffer path.
    if ((cols > 1 or rows > 1) and cfg.format == 0 and supersample == 1 and !s.capture_no_stream) {
        const space = color.Space.fromInt(cfg.color_space);
        var tags: png.ColorTags = .{};
        if (space != .srgb) {
            tags.chrm = color.chromaticities(space);
            tags.gama = color.gamma(space);
        }
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(gpa);
        var enc: png.StreamEncoder = undefined;
        enc.begin(gpa, &encoded, render_w, render_h, .{
            .bit_depth = if (cfg.bit_depth == 16) 16 else 8,
            .color = tags,
        }) catch return .out_of_memory;
        defer enc.deinit();
        const band = gpa.alloc(u8, @as(usize, render_w) * @min(tile_cap, render_h) * 4) catch return .out_of_memory;
        defer gpa.free(band);
        var ty: u32 = 0;
        while (ty < rows) : (ty += 1) {
            const tile_y = ty * tile_cap;
            const th: u32 = @min(tile_cap, render_h - tile_y);
            var tx: u32 = 0;
            while (tx < cols) : (tx += 1) {
                const tile_x = tx * tile_cap;
                const tw: u32 = @min(tile_cap, render_w - tile_x);
                s.capture_res_width = @intCast(tw);
                s.capture_res_height = @intCast(th);
                s.capture_tile = .{
                    .u0 = @as(f32, @floatFromInt(tile_x)) / @as(f32, @floatFromInt(render_w)),
                    .v0 = @as(f32, @floatFromInt(tile_y)) / @as(f32, @floatFromInt(render_h)),
                    .u1 = @as(f32, @floatFromInt(tile_x + tw)) / @as(f32, @floatFromInt(render_w)),
                    .v1 = @as(f32, @floatFromInt(tile_y + th)) / @as(f32, @floatFromInt(render_h)),
                };
                const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
                if (e.capture_width == 0 or e.capture_height == 0) {
                    w.* = 0;
                    h.* = 0;
                    return .ok;
                }
                const staging = e.capture_staging orelse return .renderer_unavailable;
                const tile_buf = gpa.alloc(u8, @as(usize, tw) * @as(usize, th) * 4) catch return .out_of_memory;
                defer gpa.free(tile_buf);
                render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
                const ready_frame = render.Renderer.readTexture(staging, tile_buf.ptr);
                while (r.frame() < ready_frame) {}
                var row: u32 = 0;
                while (row < th) : (row += 1) {
                    const dst = (@as(usize, row) * @as(usize, render_w) + tile_x) * 4;
                    const src = @as(usize, row) * @as(usize, tw) * 4;
                    @memcpy(band[dst..][0 .. @as(usize, tw) * 4], tile_buf[src..][0 .. @as(usize, tw) * 4]);
                }
            }
            enc.writeBand(band[0 .. @as(usize, render_w) * th * 4], th) catch return .out_of_memory;
        }
        enc.finish() catch return .out_of_memory;
        w.* = render_w;
        h.* = render_h;
        len_out.* = encoded.items.len;
        if (out_capacity < encoded.items.len) return .invalid_argument;
        @memcpy(data[0..encoded.items.len], encoded.items);
        return .ok;
    }

    const rendered = gpa.alloc(u8, render_size) catch return .out_of_memory;
    defer gpa.free(rendered);

    if (cols == 1 and rows == 1) {
        // Whole frame in one target: read straight into the output buffer,
        // the same fast path a preview-size capture already takes.
        s.capture_res_width = @intCast(render_w);
        s.capture_res_height = @intCast(render_h);
        s.capture_tile = null;
        const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
        if (e.capture_width == 0 or e.capture_height == 0) {
            w.* = 0;
            h.* = 0;
            return .ok;
        }
        const staging = e.capture_staging orelse return .renderer_unavailable;
        render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
        const ready_frame = render.Renderer.readTexture(staging, rendered.ptr);
        while (r.frame() < ready_frame) {}
    } else {
        // Composite each tile into its own small target and stitch the
        // rows into the full buffer at the tile's offset.
        var ty: u32 = 0;
        while (ty < rows) : (ty += 1) {
            const tile_y = ty * tile_cap;
            const th: u32 = @min(tile_cap, render_h - tile_y);
            var tx: u32 = 0;
            while (tx < cols) : (tx += 1) {
                const tile_x = tx * tile_cap;
                const tw: u32 = @min(tile_cap, render_w - tile_x);
                s.capture_res_width = @intCast(tw);
                s.capture_res_height = @intCast(th);
                s.capture_tile = .{
                    .u0 = @as(f32, @floatFromInt(tile_x)) / @as(f32, @floatFromInt(render_w)),
                    .v0 = @as(f32, @floatFromInt(tile_y)) / @as(f32, @floatFromInt(render_h)),
                    .u1 = @as(f32, @floatFromInt(tile_x + tw)) / @as(f32, @floatFromInt(render_w)),
                    .v1 = @as(f32, @floatFromInt(tile_y + th)) / @as(f32, @floatFromInt(render_h)),
                };
                const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
                if (e.capture_width == 0 or e.capture_height == 0) {
                    w.* = 0;
                    h.* = 0;
                    return .ok;
                }
                const staging = e.capture_staging orelse return .renderer_unavailable;
                const tile_size = @as(usize, tw) * @as(usize, th) * 4;
                const tile_buf = gpa.alloc(u8, tile_size) catch return .out_of_memory;
                defer gpa.free(tile_buf);
                render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
                const ready_frame = render.Renderer.readTexture(staging, tile_buf.ptr);
                while (r.frame() < ready_frame) {}
                var row: u32 = 0;
                while (row < th) : (row += 1) {
                    const dst = (@as(usize, tile_y + row) * @as(usize, render_w) + tile_x) * 4;
                    const src = @as(usize, row) * @as(usize, tw) * 4;
                    @memcpy(rendered[dst..][0 .. @as(usize, tw) * 4], tile_buf[src..][0 .. @as(usize, tw) * 4]);
                }
            }
        }
    }

    // The pixels to encode: the rendered buffer directly at 1x, or the
    // box-downsampled buffer at the still size when supersampling.
    var pixels: []u8 = rendered;
    var out_w: u32 = render_w;
    var out_h: u32 = render_h;
    var downsampled: []u8 = &.{};
    defer if (downsampled.len > 0) gpa.free(downsampled);
    if (supersample > 1) {
        downsampled = gpa.alloc(u8, @as(usize, still_w) * still_h * 4) catch return .out_of_memory;
        image.downsampleBox(rendered, render_w, render_h, downsampled, still_w, still_h) catch return .unsupported;
        pixels = downsampled;
        out_w = still_w;
        out_h = still_h;
    }
    w.* = out_w;
    h.* = out_h;

    if (cfg.format == 0) {
        // Only wide-gamut and 16-bit captures carry extra chunks, so a
        // plain sRGB 8-bit PNG stays byte-identical to the base path.
        const space = color.Space.fromInt(cfg.color_space);
        var tags: png.ColorTags = .{};
        if (space != .srgb) {
            tags.chrm = color.chromaticities(space);
            tags.gama = color.gamma(space);
        }
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(gpa);
        png.encodeRgbaOpts(gpa, &encoded, pixels, out_w, out_h, .{
            .bit_depth = if (cfg.bit_depth == 16) 16 else 8,
            .color = tags,
        }) catch return .out_of_memory;
        len_out.* = encoded.items.len;
        if (out_capacity < encoded.items.len) return .invalid_argument;
        @memcpy(data[0..encoded.items.len], encoded.items);
        return .ok;
    }
    return encodeLossyPhoto(gpa, pixels, out_w, out_h, cfg.format, cfg.quality, cfg.color_space, 1, data[0..out_capacity], len_out);
}

/// Declarative camera-hardware intent. The engine validates and normalizes
/// every field and stores it on the session; the SDK reads the normalized
/// values back and drives the platform camera. The core never touches the
/// camera - it only owns the contract and the mirror-save policy.
pub const CameraControls = extern struct {
    flash_mode: u32 = 0, // 0 off, 1 on, 2 auto (still-capture LED)
    torch: u32 = 0, // 0 off, 1 on (continuous LED)
    focus_mode: u32 = 0, // 0 continuous-auto, 1 locked, 2 point-single
    exposure_mode: u32 = 0, // 0 continuous-auto, 1 locked
    focus_point_x: f32 = 0.5, // tap POI, normalized 0..1
    focus_point_y: f32 = 0.5,
    exposure_linked: u32 = 1, // 1 exposure POI follows focus POI, 0 decoupled
    exposure_point_x: f32 = 0.5, // used when decoupled
    exposure_point_y: f32 = 0.5,
    exposure_bias_ev: f32 = 0, // clamped to [-8, 8]; SDK re-clamps to device
    zoom_factor: f32 = 1, // >= 1; clamped to [1, max_zoom_factor or 128]
    max_zoom_factor: f32 = 0, // SDK-reported device ceiling; 0 = unknown
    mirror_save_policy: u32 = 0, // 0 uniform (front mirrors every surface)
    reserved: u32 = 0,
};

/// How the SDK should record: the engine stores this intent, it never drives
/// the recorder. Ten 4-byte fields, layout frozen at 40 bytes.
pub const RecordingPolicy = extern struct {
    max_duration_ms: u32 = 0, // 0 unlimited, else a hard clip cap
    min_clip_ms: u32 = 0, // a segment shorter than this is dropped
    segment_mode: u32 = 0, // 0 single take, 1 multi-clip pause/resume
    loop_playback: u32 = 0, // 0 off, 1 loop the recorded clip
    speed_preset: u32 = 0, // 0 1x, 1 0.3x, 2 0.5x, 3 2x, 4 3x
    mic_muted: u32 = 0, // 0 record mic, 1 mute
    save_original: u32 = 0, // 0 off, 1 keep the unprocessed take too
    stabilization: u32 = 0, // 0 off, 1 standard, 2 cinematic
    reserved0: u32 = 0,
    reserved1: u32 = 0,
};

/// The capture chrome the app draws over its own surface: the engine stores the
/// intent, it never renders the UI. The front-screen flash is a brightness and
/// warmth fill the app draws, deliberately not baked into the captured frame.
/// Ten 4-byte fields, layout frozen at 40 bytes.
pub const CaptureUiIntent = extern struct {
    grid_mode: u32 = 0, // 0 off, 1 thirds, 2 golden, 3 square/crosshair
    level_indicator: u32 = 0, // 0 off, 1 on
    shutter_mode: u32 = 0, // 0 photo, 1 hold-video, 2 handsfree, 3 loop, 4 timer
    countdown_s: u32 = 0, // self-timer seconds, 0 off
    night_mode: u32 = 0, // 0 off, 1 on, 2 auto
    screen_flash_mode: u32 = 0, // 0 off, 1 on, 2 auto (front-screen fill)
    screen_flash_intensity: f32 = 1.0, // 0..1 brightness of the fill
    screen_flash_warmth: f32 = 0.5, // 0 cool .. 1 warm
    reserved0: u32 = 0,
    reserved1: u32 = 0,
};

fn clampF32(v: f32, lo: f32, hi: f32) f32 {
    if (std.math.isNan(v)) return lo;
    return std.math.clamp(v, lo, hi);
}

/// Pure normalization: clamps every field to its valid envelope so the stored
/// controls (and the read-back the SDK applies) are always sane, whatever the
/// caller passed. No clock, no allocation - a fixed function of the input.
fn normalizeCameraControls(c: CameraControls) CameraControls {
    var out = c;
    out.flash_mode = if (c.flash_mode <= 2) c.flash_mode else 0;
    out.torch = if (c.torch != 0) 1 else 0;
    out.focus_mode = if (c.focus_mode <= 2) c.focus_mode else 0;
    out.exposure_mode = if (c.exposure_mode <= 1) c.exposure_mode else 0;
    out.focus_point_x = clampF32(c.focus_point_x, 0, 1);
    out.focus_point_y = clampF32(c.focus_point_y, 0, 1);
    out.exposure_linked = if (c.exposure_linked != 0) 1 else 0;
    out.exposure_point_x = clampF32(c.exposure_point_x, 0, 1);
    out.exposure_point_y = clampF32(c.exposure_point_y, 0, 1);
    out.exposure_bias_ev = clampF32(c.exposure_bias_ev, -8, 8);
    out.max_zoom_factor = if (c.max_zoom_factor >= 1 and !std.math.isNan(c.max_zoom_factor)) c.max_zoom_factor else 0;
    const zoom_ceiling: f32 = if (out.max_zoom_factor >= 1) out.max_zoom_factor else 128;
    out.zoom_factor = clampF32(c.zoom_factor, 1, zoom_ceiling);
    out.mirror_save_policy = 0; // only uniform today; reserved values normalize to 0
    out.reserved = 0;
    return out;
}

/// Stores the caller's normalized camera intent on the session. The SDK reads
/// it back with goss_session_camera_controls and applies it to the platform
/// camera; the engine itself never calls camera hardware.
pub export fn goss_session_set_camera_controls(session: ?*Session, controls: ?*const CameraControls) Status {
    const s = session orelse return .invalid_argument;
    const c = controls orelse return .invalid_argument;
    const next = normalizeCameraControls(c.*);
    const prev = s.camera_controls;
    // A focus or exposure change pulses the matching trigger for one tick. Both
    // operands are normalized, so re-sending identical controls fires nothing.
    if (next.focus_mode != prev.focus_mode or next.focus_point_x != prev.focus_point_x or next.focus_point_y != prev.focus_point_y) {
        s.cam_focus_pulse = true;
    }
    if (next.exposure_mode != prev.exposure_mode or next.exposure_linked != prev.exposure_linked or
        next.exposure_point_x != prev.exposure_point_x or next.exposure_point_y != prev.exposure_point_y or
        next.exposure_bias_ev != prev.exposure_bias_ev)
    {
        s.cam_exposure_pulse = true;
    }
    s.camera_controls = next;
    return .ok;
}

/// Reads the normalized camera controls back for the SDK to apply.
pub export fn goss_session_camera_controls(session: ?*Session, out: ?*CameraControls) Status {
    const s = session orelse return .invalid_argument;
    const o = out orelse return .invalid_argument;
    o.* = s.camera_controls;
    return .ok;
}

/// Clamps a recording policy to its valid envelope: the duration cap at ten
/// minutes (zero staying unlimited), a min clip no longer than the cap, the enum
/// fields to their ranges, the flags to 0/1, and the reserved slots to zero.
fn normalizeRecordingPolicy(p: RecordingPolicy) RecordingPolicy {
    var out = p;
    out.max_duration_ms = @min(p.max_duration_ms, 600_000);
    out.min_clip_ms = if (out.max_duration_ms != 0) @min(p.min_clip_ms, out.max_duration_ms) else p.min_clip_ms;
    out.segment_mode = if (p.segment_mode <= 1) p.segment_mode else 0;
    out.loop_playback = if (p.loop_playback != 0) 1 else 0;
    out.speed_preset = if (p.speed_preset <= 4) p.speed_preset else 0;
    out.mic_muted = if (p.mic_muted != 0) 1 else 0;
    out.save_original = if (p.save_original != 0) 1 else 0;
    out.stabilization = if (p.stabilization <= 2) p.stabilization else 0;
    out.reserved0 = 0;
    out.reserved1 = 0;
    return out;
}

/// Clamps a capture-UI intent to its valid envelope.
fn normalizeCaptureUi(u: CaptureUiIntent) CaptureUiIntent {
    var out = u;
    out.grid_mode = if (u.grid_mode <= 3) u.grid_mode else 0;
    out.level_indicator = if (u.level_indicator != 0) 1 else 0;
    out.shutter_mode = if (u.shutter_mode <= 4) u.shutter_mode else 0;
    out.night_mode = if (u.night_mode <= 2) u.night_mode else 0;
    out.screen_flash_mode = if (u.screen_flash_mode <= 2) u.screen_flash_mode else 0;
    out.screen_flash_intensity = clampF32(u.screen_flash_intensity, 0, 1);
    out.screen_flash_warmth = clampF32(u.screen_flash_warmth, 0, 1);
    out.reserved0 = 0;
    out.reserved1 = 0;
    return out;
}

/// Stores the SDK's normalized recording policy on the session. Read it back and
/// apply it to the platform recorder; the engine never records.
pub export fn goss_session_set_recording_policy(session: ?*Session, policy: ?*const RecordingPolicy) Status {
    const s = session orelse return .invalid_argument;
    const p = policy orelse return .invalid_argument;
    s.recording_policy = normalizeRecordingPolicy(p.*);
    return .ok;
}

pub export fn goss_session_recording_policy(session: ?*Session, out: ?*RecordingPolicy) Status {
    const s = session orelse return .invalid_argument;
    const o = out orelse return .invalid_argument;
    o.* = s.recording_policy;
    return .ok;
}

/// Stores the SDK's normalized capture-UI intent (grid, timer, night mode, the
/// front-screen flash). The app draws the chrome; the engine only holds intent.
pub export fn goss_session_set_capture_ui(session: ?*Session, ui: ?*const CaptureUiIntent) Status {
    const s = session orelse return .invalid_argument;
    const u = ui orelse return .invalid_argument;
    s.capture_ui = normalizeCaptureUi(u.*);
    return .ok;
}

pub export fn goss_session_capture_ui(session: ?*Session, out: ?*CaptureUiIntent) Status {
    const s = session orelse return .invalid_argument;
    const o = out orelse return .invalid_argument;
    o.* = s.capture_ui;
    return .ok;
}

/// The single point that resolves the effective mirror for every output
/// surface (preview, recording, live, capture). Policy 0 (uniform) bakes the
/// front-camera mirror the frame declares into all of them, so every viewer
/// sees the same flip; reserved policies normalize to 0.
fn resolveMirror(s: *const Session, flags: u32) bool {
    _ = s;
    return flags & frame_flag_mirror != 0;
}

fn findSource(s: *Session, name: []const u8) ?u8 {
    for (0..s.source_count) |i| {
        if (std.mem.eql(u8, s.source_names[i][0..s.source_name_len[i]], name)) return @intCast(i);
    }
    return null;
}

/// Registers a named RGBA source for multi-source composition. The camera is
/// always the implicit source 0; named sources fill the layout after it in the
/// order defined. Idempotent for a name already defined.
pub export fn goss_session_define_source(session: ?*Session, name: ?[*]const u8, name_len: usize) Status {
    const s = session orelse return .invalid_argument;
    const n = name orelse return .invalid_argument;
    if (name_len == 0) return .invalid_argument;
    const key = n[0..name_len];
    if (std.mem.eql(u8, key, "camera")) return .invalid_argument; // reserved for placement 0
    if (findSource(s, key) != null) return .ok;
    if (s.source_count + 1 >= comp.max_sources) return .invalid_argument; // camera + this
    const slot = s.source_count;
    const copy = @min(name_len, max_source_name);
    @memcpy(s.source_names[slot][0..copy], n[0..copy]);
    s.source_name_len[slot] = @intCast(copy);
    s.source_tex[slot] = .{};
    s.source_dims[slot] = .{ 0, 0 };
    s.source_has_frame[slot] = false;
    s.source_opacity[slot] = 1;
    s.source_key[slot] = 0;
    s.source_chroma[slot] = .{ 0, 0, 0, 0 };
    s.source_softness[slot] = 0.1;
    s.source_fit[slot] = false;
    s.source_count += 1;
    return .ok;
}

/// A screen-share source: like a defined source, but its frame letterboxes to
/// fit its cell (preserving aspect) instead of stretching to fill it.
pub export fn goss_session_define_screen_share(session: ?*Session, name: ?[*]const u8, name_len: usize) Status {
    const status = goss_session_define_source(session, name, name_len);
    if (status != .ok) return status;
    const s = session.?;
    if (findSource(s, name.?[0..name_len])) |idx| s.source_fit[idx] = true;
    return .ok;
}

/// Sets a source's composite blend for the layout: opacity in [0,1], key mode
/// (0 none, 1 matte from the source alpha, 2 chroma-key), the chroma key color,
/// and a match similarity. The name "camera" addresses the live camera base.
pub export fn goss_session_set_source_composite(session: ?*Session, name: ?[*]const u8, name_len: usize, opacity: f32, key_mode: u32, key_r: f32, key_g: f32, key_b: f32, similarity: f32) Status {
    const s = session orelse return .invalid_argument;
    const nm = name orelse return .invalid_argument;
    const op = std.math.clamp(opacity, 0, 1);
    const key: u8 = @intCast(@min(key_mode, 2));
    const sim = if (similarity > 0) similarity else 0;
    if (std.mem.eql(u8, nm[0..name_len], "camera")) {
        s.camera_opacity = op;
        s.camera_key = key;
        s.camera_chroma = .{ key_r, key_g, key_b, sim };
        return .ok;
    }
    const idx = findSource(s, nm[0..name_len]) orelse return .again;
    s.source_opacity[idx] = op;
    s.source_key[idx] = key;
    s.source_chroma[idx] = .{ key_r, key_g, key_b, sim };
    return .ok;
}

/// Removes a named source, freeing its texture; later sources shift down to
/// keep the definition order dense.
pub export fn goss_session_remove_source(session: ?*Session, name: ?[*]const u8, name_len: usize) Status {
    const s = session orelse return .invalid_argument;
    const n = name orelse return .invalid_argument;
    const idx = findSource(s, n[0..name_len]) orelse return .again;
    s.source_tex[idx].deinit();
    var i: u8 = idx;
    while (i + 1 < s.source_count) : (i += 1) {
        s.source_names[i] = s.source_names[i + 1];
        s.source_name_len[i] = s.source_name_len[i + 1];
        s.source_tex[i] = s.source_tex[i + 1];
        s.source_dims[i] = s.source_dims[i + 1];
        s.source_has_frame[i] = s.source_has_frame[i + 1];
        s.source_opacity[i] = s.source_opacity[i + 1];
        s.source_key[i] = s.source_key[i + 1];
        s.source_chroma[i] = s.source_chroma[i + 1];
        s.source_softness[i] = s.source_softness[i + 1];
        s.source_fit[i] = s.source_fit[i + 1];
    }
    s.source_count -= 1;
    s.source_tex[s.source_count] = .{}; // its handle moved down; do not deinit here
    s.source_has_frame[s.source_count] = false;
    s.source_opacity[s.source_count] = 1;
    s.source_key[s.source_count] = 0;
    s.source_fit[s.source_count] = false;
    return .ok;
}

/// Uploads one RGBA/BGRA frame into a named source's own texture (no shared
/// cache to clobber). Define the source first.
pub export fn goss_session_submit_source_frame_rgba_copy(session: ?*Session, name: ?[*]const u8, name_len: usize, desc: ?*const FrameDesc, rgba: ?[*]const u8, stride: u32) Status {
    const s = session orelse return .invalid_argument;
    const nm = name orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const rgba_ptr = rgba orelse return .invalid_argument;
    if (!validDims(d.width, d.height)) return .invalid_argument;
    if (d.pixel_format != pixel_format_bgra8 and d.pixel_format != pixel_format_rgba8) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;
    _ = r;
    const idx = findSource(s, nm[0..name_len]) orelse return .again;
    const format: u32 = if (d.pixel_format == pixel_format_bgra8) render.c.BGFX_TEXTURE_FORMAT_BGRA8 else render.c.BGFX_TEXTURE_FORMAT_RGBA8;
    _ = s.source_tex[idx].uploadCopy(@intCast(d.width), @intCast(d.height), format, rgba_ptr, stride);
    s.source_dims[idx] = .{ @intCast(d.width), @intCast(d.height) };
    s.source_has_frame[idx] = true;
    return .ok;
}

/// Sets the composite arrangement over the camera plus the named sources
/// (0 custom, 1 side-by-side, 2 top-bottom, 3 picture-in-picture, 4 grid). The
/// composite runs at the head of the render chain; the rest is unchanged.
pub export fn goss_session_set_layout(session: ?*Session, arrangement: u32) Status {
    const s = session orelse return .invalid_argument;
    const total: u8 = s.source_count + 1; // camera is source 0
    s.layout_active = switch (arrangement) {
        1 => comp.Layout.sideBySide(total),
        2 => comp.Layout.topBottom(total),
        3 => comp.Layout.pip(.{ 0.62, 0.62, 0.34, 0.34 }),
        0, 4 => comp.Layout.grid(total),
        5 => comp.Layout.overlay(total),
        else => return .invalid_argument,
    };
    return .ok;
}

/// Clears the composite, returning to a single-camera preview.
pub export fn goss_session_clear_layout(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.layout_active = null;
    return .ok;
}

/// Composites the camera (placement 0) and the named sources into targets0 at
/// the head of the render chain: a full-frame clear, then each placed source
/// drawn into its own viewport in draw order. Returns the next free view id for
/// the rest of the chain. Allocation-free; walks the fixed layout arrays only.
/// Letterboxes a source of aspect dims[0]/dims[1] inside the cell, centered, so
/// a screen share fits without stretching. Returns the sub-rect x, y, w, h.
fn fitRect(dims: [2]u16, dx: u16, dy: u16, dw: u16, dh: u16) [4]u16 {
    if (dims[0] == 0 or dims[1] == 0 or dw == 0 or dh == 0) return .{ dx, dy, dw, dh };
    const sa = @as(f32, @floatFromInt(dims[0])) / @as(f32, @floatFromInt(dims[1]));
    const ca = @as(f32, @floatFromInt(dw)) / @as(f32, @floatFromInt(dh));
    var w = dw;
    var h = dh;
    if (sa > ca) {
        h = @intFromFloat(@as(f32, @floatFromInt(dw)) / sa);
    } else {
        w = @intFromFloat(@as(f32, @floatFromInt(dh)) * sa);
    }
    return .{ dx + (dw - w) / 2, dy + (dh - h) / 2, w, h };
}

fn composeLayout(r: *render.Renderer, s: *Session, current: CurrentFrame, targets0: render.Renderer.OffscreenTarget, scratch: render.Renderer.OffscreenTarget, width: u16, height: u16, rotation: u32, mirror: bool, lay: comp.Layout) u8 {
    render.Renderer.clearComposite(0, targets0, width, height);
    var order: [comp.max_sources]u8 = undefined;
    const n = lay.drawOrder(&order);
    var view: u8 = 1;
    const fw: f32 = @floatFromInt(width);
    const fh: f32 = @floatFromInt(height);
    for (order[0..n]) |p| {
        if (p >= lay.count) continue;
        const rect = lay.placements[p].rect;
        const dx: u16 = @intFromFloat(std.math.clamp(rect[0], 0, 1) * fw);
        const dy: u16 = @intFromFloat(std.math.clamp(rect[1], 0, 1) * fh);
        const dw: u16 = @intFromFloat(std.math.clamp(rect[2], 0, 1) * fw);
        const dh: u16 = @intFromFloat(std.math.clamp(rect[3], 0, 1) * fh);
        if (dw == 0 or dh == 0) continue;
        if (p == 0) {
            if (s.camera_key == 0 and s.camera_opacity >= 1) {
                // Opaque camera base: draw the preview straight into its cell.
                render.Renderer.setLayoutViewport(view, targets0, dx, dy, dw, dh);
                r.submitPreview(view, current.preview, rotation * 90, mirror);
                view += 1;
            } else {
                // Keyed camera: render the preview full into the scratch, then
                // composite it into the cell with the camera's blend.
                render.Renderer.setViewTarget(view, scratch, width, height);
                render.Renderer.clearComposite(view, scratch, width, height);
                r.submitPreview(view, current.preview, rotation * 90, mirror);
                view += 1;
                const params = [4]f32{ s.camera_opacity, @floatFromInt(s.camera_key), s.camera_chroma[3], s.camera_softness };
                const chroma = [4]f32{ s.camera_chroma[0], s.camera_chroma[1], s.camera_chroma[2], 0 };
                r.submitCompositeSource(view, scratch.texture, targets0, dx, dy, dw, dh, params, chroma);
                view += 1;
            }
        } else {
            const src = p - 1;
            if (src >= s.source_count or !s.source_has_frame[src]) continue;
            var cx = dx;
            var cy = dy;
            var cw = dw;
            var ch = dh;
            if (s.source_fit[src]) {
                const fit = fitRect(s.source_dims[src], dx, dy, dw, dh);
                cx = fit[0];
                cy = fit[1];
                cw = fit[2];
                ch = fit[3];
                if (cw == 0 or ch == 0) continue;
            }
            if (s.source_key[src] == 0 and s.source_opacity[src] >= 1) {
                r.submitLayoutSource(view, s.source_tex[src].handle, targets0, cx, cy, cw, ch);
            } else {
                const params = [4]f32{ s.source_opacity[src], @floatFromInt(s.source_key[src]), s.source_chroma[src][3], s.source_softness[src] };
                const chroma = [4]f32{ s.source_chroma[src][0], s.source_chroma[src][1], s.source_chroma[src][2], 0 };
                r.submitCompositeSource(view, s.source_tex[src].handle, targets0, cx, cy, cw, ch, params, chroma);
            }
            view += 1;
        }
    }
    return view;
}

/// Submits a location fix. The engine computes geo.in_region on-device from this
/// and the session's geofence; the location never crosses back over the ABI,
/// only the boolean does. Overwrites in place, no allocation.
pub export fn goss_session_submit_location(session: ?*Session, latitude: f64, longitude: f64, horizontal_accuracy_m: f32, timestamp_us: i64) Status {
    const s = session orelse return .invalid_argument;
    _ = timestamp_us;
    if (latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180) return .invalid_argument;
    s.location_lat = latitude;
    s.location_lon = longitude;
    s.location_accuracy_m = if (horizontal_accuracy_m > 0) horizontal_accuracy_m else 0;
    s.location_engine_fed = true;
    return .ok;
}

/// Sets the session's active geofence: a circle the app derives from a lens's
/// intended location (the app owns lens metadata and discovery). geo.in_region
/// reads true when a submitted location is within radius_m of the center.
pub export fn goss_session_set_geofence(session: ?*Session, latitude: f64, longitude: f64, radius_m: f64) Status {
    const s = session orelse return .invalid_argument;
    if (latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180 or !(radius_m > 0)) return .invalid_argument;
    s.geofence = .{ .circle = .{ .lat = latitude, .lon = longitude, .radius_m = radius_m } };
    return .ok;
}

/// Sets the geofence to an axis-aligned lat/lon box. geo.in_region reads true
/// when a submitted location falls inside it.
pub export fn goss_session_set_geofence_bbox(session: ?*Session, min_lat: f64, min_lon: f64, max_lat: f64, max_lon: f64) Status {
    const s = session orelse return .invalid_argument;
    if (min_lat < -90 or max_lat > 90 or min_lon < -180 or max_lon > 180 or min_lat > max_lat or min_lon > max_lon) return .invalid_argument;
    s.geofence = .{ .bbox = .{ .min_lat = min_lat, .min_lon = min_lon, .max_lat = max_lat, .max_lon = max_lon } };
    return .ok;
}

/// Sets the geofence to a polygon ring: vertex_count pairs of lat, lon read from
/// coords (lat, lon, lat, lon, ...). A ring of three to max_polygon_verts
/// vertices; geo.in_region reads true when a location is inside it.
pub export fn goss_session_set_geofence_polygon(session: ?*Session, coords: ?[*]const f64, vertex_count: usize) Status {
    const s = session orelse return .invalid_argument;
    const src = coords orelse return .invalid_argument;
    if (vertex_count < 3 or vertex_count > geo.max_polygon_verts) return .invalid_argument;
    var poly: @FieldType(GeoRegion, "polygon") = .{ .verts = undefined, .count = vertex_count };
    var i: usize = 0;
    while (i < vertex_count) : (i += 1) {
        const lat = src[i * 2];
        const lon = src[i * 2 + 1];
        if (lat < -90 or lat > 90 or lon < -180 or lon > 180) return .invalid_argument;
        poly.verts[i] = .{ lat, lon };
    }
    s.geofence = .{ .polygon = poly };
    return .ok;
}

/// Sets the worst fix accuracy (meters) that still counts as inside a region.
/// Zero clears the gate. A location whose reported accuracy is larger reads
/// outside, so a lens does not fire on a vague fix.
pub export fn goss_session_set_geo_accuracy(session: ?*Session, max_accuracy_m: f32) Status {
    const s = session orelse return .invalid_argument;
    s.geo_required_accuracy_m = if (max_accuracy_m > 0) max_accuracy_m else 0;
    return .ok;
}

/// Clears the geofence; geo.in_region reads false with none set.
pub export fn goss_session_clear_geofence(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.geofence = null;
    return .ok;
}

/// Sets the color and half-width the next stroke begins with. Width is in
/// normalized units; a non-positive width falls back to a hairline.
pub export fn goss_session_brush_set_style(session: ?*Session, r: f32, g: f32, b: f32, a: f32, width: f32) Status {
    const s = session orelse return .invalid_argument;
    s.brush.setStyle(.{ r, g, b, a }, width);
    return .ok;
}

/// Opens a new stroke in the current style. A fresh stroke drops the redo stack.
pub export fn goss_session_brush_begin(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.brush.begin();
    return .ok;
}

/// Adds a point to the open stroke, in normalized screen space (0..1).
pub export fn goss_session_brush_point(session: ?*Session, x: f32, y: f32) Status {
    const s = session orelse return .invalid_argument;
    s.brush.point(x, y);
    return .ok;
}

/// Commits the open stroke. A stroke of fewer than two points is dropped.
pub export fn goss_session_brush_end(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.brush.end();
    return .ok;
}

/// Removes the last committed stroke onto the redo stack.
pub export fn goss_session_brush_undo(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.brush.undo();
    return .ok;
}

/// Replays the last undone stroke.
pub export fn goss_session_brush_redo(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.brush.redoLast();
    return .ok;
}

/// Drops every stroke and both stacks.
pub export fn goss_session_brush_clear(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.brush.clear();
    return .ok;
}

/// Writes the finished brush ribbon into out (x, y, r, g, b, a per vertex) and
/// returns the float count through out_count. Passing a null out reports the
/// float count the caller must size for. Allocation-free; reads finished
/// strokes only.
pub export fn goss_session_brush_vertices(session: ?*Session, out: ?[*]f32, capacity_floats: usize, out_count: ?*usize) Status {
    const s = session orelse return .invalid_argument;
    const count = out_count orelse return .invalid_argument;
    const dst = out orelse {
        count.* = s.brush.vertexFloatCount();
        return .ok;
    };
    count.* = s.brush.buildVertices(dst[0..capacity_floats]);
    return .ok;
}

/// Selects the brush preset the next stroke opens with: 0 pen, 1 highlighter,
/// 2 marker, 3 neon. An unknown value falls back to pen. The preset biases the
/// stroke's width and alpha; the renderer reads mode 3 to draw the ribbon
/// additively for the neon glow.
pub export fn goss_session_brush_set_mode(session: ?*Session, mode: u32) Status {
    const s = session orelse return .invalid_argument;
    s.brush.setMode(stroke.Mode.fromU32(mode));
    return .ok;
}

/// Erases every committed stroke whose ribbon passes within radius (normalized
/// units) of (x, y) and reports how many through out_removed. Refuses while a
/// stroke is open. Allocation-free; compacts the stroke array in place.
pub export fn goss_session_brush_erase_at(session: ?*Session, x: f32, y: f32, radius: f32, out_removed: ?*usize) Status {
    const s = session orelse return .invalid_argument;
    const removed = s.brush.eraseAt(x, y, radius);
    if (out_removed) |o| o.* = removed;
    return .ok;
}

/// Sets the color and half-width the next world-anchored stroke opens with. The
/// width is in normalized screen units, applied after projection.
pub export fn goss_session_ar_brush_set_style(session: ?*Session, r: f32, g: f32, b: f32, a: f32, width: f32) Status {
    const s = session orelse return .invalid_argument;
    s.ar_board.setStyle(.{ r, g, b, a }, width);
    return .ok;
}

/// Selects the brush preset the next world stroke opens with: 0 pen, 1
/// highlighter, 2 marker, 3 neon. Unknown values fall back to pen.
pub export fn goss_session_ar_brush_set_mode(session: ?*Session, mode: u32) Status {
    const s = session orelse return .invalid_argument;
    s.ar_board.setMode(@intCast(@min(mode, 3)));
    return .ok;
}

/// Opens a world-anchored stroke in the current style.
pub export fn goss_session_ar_brush_begin(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.ar_board.begin();
    return .ok;
}

/// Adds a point in world space (the same frame the platform world tracking
/// reports poses in). The engine projects it to screen each frame.
pub export fn goss_session_ar_brush_point(session: ?*Session, x: f32, y: f32, z: f32) Status {
    const s = session orelse return .invalid_argument;
    s.ar_board.point(x, y, z);
    return .ok;
}

/// Commits the open world stroke. A stroke of fewer than two points is dropped.
pub export fn goss_session_ar_brush_end(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.ar_board.end();
    return .ok;
}

pub export fn goss_session_ar_brush_undo(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.ar_board.undo();
    return .ok;
}

/// Grabs the nearest dynamic body to a world point and drags it there; while
/// something is grabbed the point just updates the drag target. The body is
/// driven kinematically each tick, so it follows the pointer and builds the
/// velocity it will throw with.
pub export fn goss_session_grab(session: ?*Session, x: f32, y: f32, z: f32) Status {
    const s = session orelse return .invalid_argument;
    if (s.physics_world) |world| {
        if (s.grab_body == null) {
            var best: ?u32 = null;
            var best_d2: f32 = 0.36;
            for (s.grabbable_bodies.items) |id| {
                const body_pose = world.bodyPose(id) catch continue;
                const dx = body_pose[12] - x;
                const dy = body_pose[13] - y;
                const dz = body_pose[14] - z;
                const d2 = dx * dx + dy * dy + dz * dz;
                if (d2 < best_d2) {
                    best_d2 = d2;
                    best = id;
                }
            }
            if (best) |id| {
                world.setBodyMotion(id, .kinematic);
                s.grab_body = id;
            }
        }
        s.grab_target = .{ x, y, z };
    }
    return .ok;
}

/// Releases the grabbed body back to dynamic, so it flies off carrying the
/// velocity the drag gave it - the throw.
pub export fn goss_session_release(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    if (s.physics_world) |world| {
        if (s.grab_body) |id| {
            world.setBodyMotion(id, .dynamic);
            s.grab_body = null;
        }
    }
    return .ok;
}

/// Adds a static sphere collider at a world point, live: dynamic content lands
/// on it at once. Drawing colliders in as the pointer moves builds a live 2D
/// world; goss_session_erase_collider takes them back out.
pub export fn goss_session_add_collider(session: ?*Session, x: f32, y: f32, z: f32) Status {
    const s = session orelse return .invalid_argument;
    if (!physics.supported) return .ok;
    if (s.physics_world == null) {
        s.physics_world = physics.World.create(-9.81) catch return .ok;
        s.physics_last_us = 0;
    }
    if (s.physics_world) |world| {
        const id = world.addBody(.sphere, .{ x, y, z }, .{ 0.12, 0, 0 }, .static) catch return .ok;
        s.live_colliders.append(s.engine.gpa, .{ .id = id, .pos = .{ x, y, z } }) catch {
            // Unregistered means unerasable; take the body back out.
            world.removeBody(id);
        };
    }
    return .ok;
}

/// Erases every live collider within `radius` of a world point - the eraser
/// stroke over drawn colliders.
pub export fn goss_session_erase_collider(session: ?*Session, x: f32, y: f32, z: f32, radius: f32) Status {
    const s = session orelse return .invalid_argument;
    if (s.physics_world) |world| {
        const r2 = radius * radius;
        var i: usize = 0;
        var erased_any = false;
        while (i < s.live_colliders.items.len) {
            const lc = s.live_colliders.items[i];
            const dx = lc.pos[0] - x;
            const dy = lc.pos[1] - y;
            const dz = lc.pos[2] - z;
            if (dx * dx + dy * dy + dz * dz <= r2) {
                world.removeBody(lc.id);
                _ = s.live_colliders.swapRemove(i);
                erased_any = true;
            } else {
                i += 1;
            }
        }
        // A body asleep on an erased collider must wake so it falls.
        if (erased_any) {
            var it = s.physics_bodies.valueIterator();
            while (it.next()) |bid| world.wakeBody(bid.*);
        }
    }
    return .ok;
}

/// Releases one solver hair by id, pairing the acquire a hair lens
/// performs at activation, so a hair can retire without tearing the
/// world down. The driving node's mesh and bookkeeping go with it.
/// Reports again with no physics world, invalid_argument otherwise.
pub export fn goss_physics_hair_remove(session: ?*Session, hair_id: u32) Status {
    const s = session orelse return .invalid_argument;
    const world = s.physics_world orelse return .again;
    if (!world.removeHair(hair_id)) return .invalid_argument;
    var node: ?graph.NodeIndex = null;
    var it = s.hair_ids.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == hair_id) {
            node = entry.key_ptr.*;
            break;
        }
    }
    if (node) |graph_index| {
        _ = s.hair_ids.remove(graph_index);
        _ = s.hair_vcount.remove(graph_index);
        if (s.hair_meshes.fetchRemove(graph_index)) |kv| {
            if (s.engine.renderer != null) render.Renderer.destroyHairMesh(kv.value);
        }
    }
    return .ok;
}

pub export fn goss_session_ar_brush_clear(session: ?*Session) Status {
    const s = session orelse return .invalid_argument;
    s.ar_board.clear();
    return .ok;
}

pub export fn goss_session_create(engine: ?*Engine, config: ?*const SessionConfig, out_session: ?**Session) Status {
    const out = out_session orelse return .invalid_argument;
    const parent = engine orelse return .invalid_argument;
    const cfg: SessionConfig = if (config) |c| c.* else .{ .frame_budget_us = 0, .reserved = 0 };
    const session = createSession(parent, cfg) catch return .out_of_memory;
    out.* = session;
    return .ok;
}

pub export fn goss_session_destroy(session: ?*Session) void {
    destroySession(session orelse return);
}

pub export fn goss_session_submit_frame(session: ?*Session, desc: ?*const FrameDesc, planes: ?*const FramePlanes) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const p = planes orelse return .invalid_argument;
    if (!validDims(d.width, d.height)) return .invalid_argument;
    if (s.engine.renderer == null) return .renderer_unavailable;

    releaseCurrentFrame(s);
    switch (d.pixel_format) {
        pixel_format_bgra8, pixel_format_rgba8 => {
            if (p.plane_count != 1) return .invalid_argument;
            const format: u32 = if (d.pixel_format == pixel_format_bgra8) render.c.BGFX_TEXTURE_FORMAT_BGRA8 else render.c.BGFX_TEXTURE_FORMAT_RGBA8;
            const texture = s.preview_bgra.rebind(@intCast(d.width), @intCast(d.height), format, @intCast(p.planes[0]));
            s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .bgra = .{ .texture = texture } } };
        },
        pixel_format_nv12 => {
            if (p.plane_count != 2) return .invalid_argument;
            const y = s.preview_y.rebind(@intCast(d.width), @intCast(d.height), render.c.BGFX_TEXTURE_FORMAT_R8, @intCast(p.planes[0]));
            const uv = s.preview_uv.rebind(@intCast(d.width / 2), @intCast(d.height / 2), render.c.BGFX_TEXTURE_FORMAT_RG8, @intCast(p.planes[1]));
            const standard: math.color.Standard = switch (d.color_standard) {
                0 => .bt601,
                2 => .bt2020,
                else => .bt709,
            };
            const range: math.color.Range = if (d.color_range == 1) .full else .video;
            s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .nv12 = .{
                .y = y,
                .uv = uv,
                .conversion = math.color.yuvToRgb(standard, range),
            } } };
        },
        else => return .invalid_argument,
    }
    return .ok;
}

/// Writes the YCbCr to RGB conversion for a standard and range as one
/// column-major homogeneous matrix: rgb = (m * vec4(yuv, 1)).xyz. SDKs
/// that own their GPU pipeline, the web SDK today, get their color math
/// from the core instead of hardcoding it.
pub export fn goss_color_yuv_to_rgb(color_standard: u32, color_range: u32, out_matrix: ?*[16]f32) Status {
    const out = out_matrix orelse return .invalid_argument;
    const standard: math.color.Standard = switch (color_standard) {
        0 => .bt601,
        1 => .bt709,
        2 => .bt2020,
        else => return .invalid_argument,
    };
    const range: math.color.Range = switch (color_range) {
        0 => .video,
        1 => .full,
        else => return .invalid_argument,
    };
    const m = math.color.yuvToRgb(standard, range).homogeneous();
    var index: usize = 0;
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            out[index] = m.cols[col][row];
            index += 1;
        }
    }
    return .ok;
}

/// A unit vector perpendicular to dir built from a reference axis, so a limb
/// whose pole runs parallel to it still bends somewhere sensible.
fn orthoFrom(dir: [3]f32, ref: [3]f32) [3]f32 {
    const cx = dir[1] * ref[2] - dir[2] * ref[1];
    const cy = dir[2] * ref[0] - dir[0] * ref[2];
    const cz = dir[0] * ref[1] - dir[1] * ref[0];
    const l = @sqrt(cx * cx + cy * cy + cz * cz);
    return if (l > 1e-6) .{ cx / l, cy / l, cz / l } else .{ 0, 1, 0 };
}

/// Analytic two-bone inverse kinematics: given a root, the two bone lengths, a
/// target for the end effector, and a pole the joint bends toward, returns the
/// mid joint and end. An out-of-reach target extends the limb straight at it; a
/// too-close one folds to the nearest it can reach.
fn solveTwoBoneIk(root: [3]f32, upper: f32, lower: f32, target: [3]f32, pole: [3]f32) struct { mid: [3]f32, end: [3]f32 } {
    const tx = target[0] - root[0];
    const ty = target[1] - root[1];
    const tz = target[2] - root[2];
    const d_raw = @sqrt(tx * tx + ty * ty + tz * tz);
    const total = upper + lower;
    const dir: [3]f32 = if (d_raw > 1e-6) .{ tx / d_raw, ty / d_raw, tz / d_raw } else .{ 1, 0, 0 };
    if (d_raw >= total) {
        return .{
            .mid = .{ root[0] + dir[0] * upper, root[1] + dir[1] * upper, root[2] + dir[2] * upper },
            .end = .{ root[0] + dir[0] * total, root[1] + dir[1] * total, root[2] + dir[2] * total },
        };
    }
    const d = @max(d_raw, @max(@abs(upper - lower), 1e-6));
    const proj = (upper * upper + d * d - lower * lower) / (2.0 * d);
    const h2 = upper * upper - proj * proj;
    const height = if (h2 > 0) @sqrt(h2) else 0;
    const px = pole[0] - root[0];
    const py = pole[1] - root[1];
    const pz = pole[2] - root[2];
    const pdotd = px * dir[0] + py * dir[1] + pz * dir[2];
    var perp: [3]f32 = .{ px - dir[0] * pdotd, py - dir[1] * pdotd, pz - dir[2] * pdotd };
    const plen = @sqrt(perp[0] * perp[0] + perp[1] * perp[1] + perp[2] * perp[2]);
    if (plen > 1e-6) {
        perp = .{ perp[0] / plen, perp[1] / plen, perp[2] / plen };
    } else {
        perp = if (@abs(dir[0]) < 0.9) orthoFrom(dir, .{ 1, 0, 0 }) else orthoFrom(dir, .{ 0, 1, 0 });
    }
    return .{
        .mid = .{
            root[0] + dir[0] * proj + perp[0] * height,
            root[1] + dir[1] * proj + perp[1] * height,
            root[2] + dir[2] * proj + perp[2] * height,
        },
        .end = .{ root[0] + dir[0] * d, root[1] + dir[1] * d, root[2] + dir[2] * d },
    };
}

/// Solves two-bone IK for a limb: root, the upper and lower bone lengths, the
/// target the end reaches for, and the pole the joint bends toward, writing the
/// mid joint and end (x, y, z each). Lengths must be positive.
pub export fn goss_solve_two_bone_ik(root: ?*const [3]f32, upper_len: f32, lower_len: f32, target: ?*const [3]f32, pole: ?*const [3]f32, out_mid: ?*[3]f32, out_end: ?*[3]f32) Status {
    const r = root orelse return .invalid_argument;
    const tgt = target orelse return .invalid_argument;
    const pl = pole orelse return .invalid_argument;
    const om = out_mid orelse return .invalid_argument;
    const oe = out_end orelse return .invalid_argument;
    if (!(upper_len > 0) or !(lower_len > 0)) return .invalid_argument;
    const sol = solveTwoBoneIk(r.*, upper_len, lower_len, tgt.*, pl.*);
    om.* = sol.mid;
    oe.* = sol.end;
    return .ok;
}

/// Copies NV12 planes into pooled textures. The stated CPU path: an SDK
/// uses it only where the zero-copy import is not wired yet, and the copy
/// is counted so the budget report shows it.
pub export fn goss_session_submit_frame_copy(session: ?*Session, desc: ?*const FrameDesc, y: ?[*]const u8, y_stride: u32, uv: ?[*]const u8, uv_stride: u32) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const y_ptr = y orelse return .invalid_argument;
    const uv_ptr = uv orelse return .invalid_argument;
    if (!validDims(d.width, d.height)) return .invalid_argument;
    if (d.pixel_format != pixel_format_nv12) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;

    releaseCurrentFrame(s);
    const standard: math.color.Standard = switch (d.color_standard) {
        0 => .bt601,
        2 => .bt2020,
        else => .bt709,
    };
    const range: math.color.Range = if (d.color_range == 1) .full else .video;
    const uploaded = r.uploadNv12(
        @intCast(d.width),
        @intCast(d.height),
        y_ptr,
        y_stride,
        uv_ptr,
        uv_stride,
    ) catch return .out_of_memory;
    s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .nv12 = .{
        .y = uploaded.y,
        .uv = uploaded.uv,
        .conversion = math.color.yuvToRgb(standard, range),
    } } };
    s.copied_frames += 1;
    return .ok;
}

/// The CPU-copy path for a single-plane BGRA8/RGBA8 frame - a canvas or
/// video element's own byte buffer, most likely, with no native GPU
/// handle behind it the way goss_session_submit_frame's zero-copy path
/// needs. Same shape as goss_session_submit_frame_copy above, just a
/// single interleaved plane instead of NV12's two.
pub export fn goss_session_submit_frame_rgba_copy(session: ?*Session, desc: ?*const FrameDesc, rgba: ?[*]const u8, stride: u32) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const rgba_ptr = rgba orelse return .invalid_argument;
    if (!validDims(d.width, d.height)) return .invalid_argument;
    if (d.pixel_format != pixel_format_bgra8 and d.pixel_format != pixel_format_rgba8) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;

    releaseCurrentFrame(s);
    const format: u32 = if (d.pixel_format == pixel_format_bgra8) render.c.BGFX_TEXTURE_FORMAT_BGRA8 else render.c.BGFX_TEXTURE_FORMAT_RGBA8;
    const texture = r.uploadRgba(@intCast(d.width), @intCast(d.height), format, rgba_ptr, stride) catch return .out_of_memory;
    s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .bgra = .{ .texture = texture } } };
    s.copied_frames += 1;
    return .ok;
}

/// Zero-copy camera submission for platforms delivering hardware buffers.
/// The render adapter converts on the gpu; a status other than ok means the
/// caller falls back to the declared copy path for this stream.
pub export fn goss_session_submit_hardware_buffer(session: ?*Session, desc: ?*const FrameDesc, hardware_buffer: ?*anyopaque) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const buffer = hardware_buffer orelse return .invalid_argument;
    if (!validDims(d.width, d.height)) return .invalid_argument;
    if (d.pixel_format != pixel_format_nv12) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;

    const standard: math.color.Standard = switch (d.color_standard) {
        0 => .bt601,
        2 => .bt2020,
        else => .bt709,
    };
    const range: math.color.Range = if (d.color_range == 1) .full else .video;
    const texture = r.submitHardwareBuffer(buffer, d.width, d.height, math.color.yuvToRgb(standard, range)) catch {
        return .renderer_unavailable;
    };
    releaseCurrentFrame(s);
    s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .bgra = .{ .texture = texture } } };
    return .ok;
}

pub export fn goss_session_report_frame(session: ?*Session, frame_time_us: u32, thermal: c_int) c_int {
    const s = session orelse return 0;
    _ = s.controller.step(.{ .frame_time_us = frame_time_us, .thermal = thermalFromC(thermal) });
    return @intFromEnum(s.controller.level);
}

pub export fn goss_session_degrade_level(session: ?*const Session) c_int {
    const s = session orelse return 0;
    return @intFromEnum(s.controller.level);
}

/// Stands the face tracking worker up from a model bundle. The bundle
/// bytes are copied; the caller may release them on return. On platforms
/// built without the inference stack this reports unsupported.
pub export fn goss_session_enable_face_tracking(session: ?*Session, task_bytes: ?[*]const u8, task_len: usize, threads: i32) Status {
    const s = session orelse return .invalid_argument;
    const bytes = task_bytes orelse return .invalid_argument;
    if (task_len == 0) return .invalid_argument;
    if (s.face_tracking != null) return .ok;
    const worker_threads = if (threads <= 0) 2 else threads;
    s.face_tracking = tracking.create(s.engine.gpa, bytes[0..task_len], worker_threads) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.InvalidBundle => return .invalid_argument,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_face_tracking(session: ?*Session) void {
    const s = session orelse return;
    if (s.face_tracking) |worker| tracking.destroy(worker);
    s.face_tracking = null;
}

/// Stands the hand tracking worker up from a hand landmarker task bundle.
/// The bundle bytes are copied; the caller may release them on return. On
/// platforms built without the inference stack this reports unsupported.
pub export fn goss_session_enable_hand_tracking(session: ?*Session, task_bytes: ?[*]const u8, task_len: usize, threads: i32) Status {
    const s = session orelse return .invalid_argument;
    const bytes = task_bytes orelse return .invalid_argument;
    if (task_len == 0) return .invalid_argument;
    if (s.hand_tracking != null) return .ok;
    const worker_threads = if (threads <= 0) 2 else threads;
    s.hand_tracking = tracking.hand_worker.create(s.engine.gpa, bytes[0..task_len], worker_threads) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.InvalidBundle => return .invalid_argument,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_hand_tracking(session: ?*Session) void {
    const s = session orelse return;
    if (s.hand_tracking) |worker| tracking.hand_worker.destroy(worker);
    s.hand_tracking = null;
}

/// Stands the pose tracking worker up from a pose landmarker task
/// bundle. The bundle bytes are copied; the caller may release them on
/// return. Builds without the inference stack report unsupported.
pub export fn goss_session_enable_pose_tracking(session: ?*Session, task_bytes: ?[*]const u8, task_len: usize, threads: i32) Status {
    const s = session orelse return .invalid_argument;
    const bytes = task_bytes orelse return .invalid_argument;
    if (task_len == 0) return .invalid_argument;
    if (s.pose_tracking != null) return .ok;
    const worker_threads = if (threads <= 0) 2 else threads;
    s.pose_tracking = tracking.pose_worker.create(s.engine.gpa, bytes[0..task_len], worker_threads) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.InvalidBundle => return .invalid_argument,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_pose_tracking(session: ?*Session) void {
    const s = session orelse return;
    if (s.pose_tracking) |worker| tracking.pose_worker.destroy(worker);
    s.pose_tracking = null;
}

/// Stands the segmentation worker up from a raw model (selfie or hair
/// segmenter, not bundled the way face_landmarker.task is). The model
/// bytes are copied; the caller may release them on return. On platforms
/// built without the inference stack this reports unsupported.
pub export fn goss_session_enable_segmentation(session: ?*Session, model_bytes: ?[*]const u8, model_len: usize, threads: i32) Status {
    const s = session orelse return .invalid_argument;
    const bytes = model_bytes orelse return .invalid_argument;
    if (model_len == 0) return .invalid_argument;
    if (s.segmentation_worker != null) return .ok;
    const worker_threads = if (threads <= 0) 2 else threads;
    s.segmentation_worker = segmentation.create(s.engine.gpa, bytes[0..model_len], worker_threads) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.InvalidModel => return .invalid_argument,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_segmentation(session: ?*Session) void {
    const s = session orelse return;
    if (s.segmentation_worker) |worker| segmentation.destroy(worker);
    s.segmentation_worker = null;
    clearSegmentationTextures(s);
}

/// Feeds one NV12 frame to the tracking worker. The planes are CPU
/// addresses valid for the duration of the call; the worker copies and
/// returns immediately, dropping stale frames in favor of this one.
pub export fn goss_session_track_frame(session: ?*Session, desc: ?*const FrameDesc, y: ?[*]const u8, y_stride: u32, uv: ?[*]const u8, uv_stride: u32) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const y_plane = y orelse return .invalid_argument;
    const uv_plane = uv orelse return .invalid_argument;
    if (s.face_tracking == null and s.hand_tracking == null and s.pose_tracking == null and s.segmentation_worker == null) return .again;
    if (d.pixel_format != pixel_format_nv12) return .invalid_argument;
    if (!validDims(d.width, d.height)) return .invalid_argument;
    if (y_stride < d.width or uv_stride < ((d.width + 1) / 2) * 2) return .invalid_argument;
    const standard: math.color.Standard = switch (d.color_standard) {
        0 => .bt601,
        2 => .bt2020,
        else => .bt709,
    };
    const range: math.color.Range = if (d.color_range == 1) .full else .video;
    const conversion = math.color.yuvToRgb(standard, range);
    if (s.face_tracking) |worker| {
        tracking.submitNv12(worker, d.width, d.height, d.timestamp_us, conversion, y_plane, y_stride, uv_plane, uv_stride);
    }
    if (s.hand_tracking) |worker| {
        tracking.hand_worker.submitNv12(worker, d.width, d.height, d.timestamp_us, conversion, y_plane, y_stride, uv_plane, uv_stride);
    }
    if (s.pose_tracking) |worker| {
        tracking.pose_worker.submitNv12(worker, d.width, d.height, d.timestamp_us, conversion, y_plane, y_stride, uv_plane, uv_stride);
    }
    if (s.segmentation_worker) |worker| {
        segmentation.submitNv12(worker, d.width, d.height, d.timestamp_us, conversion, y_plane, y_stride, uv_plane, uv_stride);
    }
    return .ok;
}

/// Reads the newest tracking result into caller memory. Reports again
/// until the worker has published its first result.
pub export fn goss_session_face_result(session: ?*Session, out_result: ?*face.Result) Status {
    const s = session orelse return .invalid_argument;
    const out = out_result orelse return .invalid_argument;
    const worker = s.face_tracking orelse return .again;
    if (!tracking.readResult(worker, out)) return .again;
    return .ok;
}

/// Submits the faces tracked this frame for the multi-face path. count past
/// GOSS_FACE_MAX is clamped; zero clears the path back to the single
/// tracker. A face below the tracked presence or with no landmarks drops,
/// so face_count only ever counts real faces.
pub export fn goss_session_submit_faces(session: ?*Session, faces: ?[*]const face.Result, count: u32) Status {
    const s = session orelse return .invalid_argument;
    if (count == 0) {
        s.face_count = 0;
        return .ok;
    }
    const src = faces orelse return .invalid_argument;
    var kept: u32 = 0;
    var i: u32 = 0;
    while (i < count and kept < face.max_faces) : (i += 1) {
        const f = src[i];
        if (f.landmark_count_out == 0 or f.presence < 0.5) continue;
        s.face_results[kept] = f;
        kept += 1;
    }
    s.face_count = kept;
    return .ok;
}

/// How many faces the last goss_session_submit_faces kept, zero to
/// GOSS_FACE_MAX. Zero also means the caller drives no multi-face path.
pub export fn goss_session_face_count(session: ?*Session, out_count: ?*u32) Status {
    const s = session orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = s.face_count;
    return .ok;
}

/// How many of the active lens's image and model assets are still decoding on
/// their loader threads. Zero once every asset has landed, so the harness can
/// wait for a deterministic frame before it reads the output.
pub fn loadsPending(session: ?*Session) u32 {
    const s = session orelse return 0;
    var n: usize = s.sprite_loaders.count() + s.model_loaders.count() + s.lut_loaders.count() + s.blend_loaders.count() + s.env_loaders.count() + s.mesh_face_loaders.count();
    var it = s.sprite_anims.valueIterator();
    while (it.next()) |anim| {
        for (anim.loaders) |maybe| {
            if (maybe != null) n += 1;
        }
    }
    return @intCast(n);
}

/// How many of the active lens's particle nodes run on the GPU compute path,
/// so the harness can prove the GPU sim was taken rather than the CPU fallback.
pub fn activeGpuParticleSims(session: ?*Session) u32 {
    const s = session orelse return 0;
    return @intCast(s.gpu_particle_sims.count());
}

/// Reads the index-th submitted face. invalid_argument once index reaches
/// face_count, so a caller loops zero to face_count to visit every face.
pub export fn goss_session_face_result_at(session: ?*Session, index: u32, out_result: ?*face.Result) Status {
    const s = session orelse return .invalid_argument;
    const out = out_result orelse return .invalid_argument;
    if (index >= s.face_count) return .invalid_argument;
    out.* = s.face_results[index];
    return .ok;
}

/// Submits the bodies tracked this frame for the multi-person path, so a lens
/// can instance effects across every body. Bodies past GOSS_BODY_MAX or with
/// no landmarks are dropped; count zero clears the path.
pub export fn goss_session_submit_bodies(session: ?*Session, bodies: ?[*]const pose.Result, count: u32) Status {
    const s = session orelse return .invalid_argument;
    if (count == 0) {
        s.body_count = 0;
        return .ok;
    }
    const src = bodies orelse return .invalid_argument;
    var kept: u32 = 0;
    var i: u32 = 0;
    while (i < count and kept < pose.max_bodies) : (i += 1) {
        const b = src[i];
        if (b.landmark_count_out == 0 or b.presence < 0.5) continue;
        s.body_results[kept] = b;
        kept += 1;
    }
    s.body_count = kept;
    return .ok;
}

/// How many bodies the last goss_session_submit_bodies kept, zero to
/// GOSS_BODY_MAX. Zero also means the caller drives no multi-person path.
pub export fn goss_session_body_count(session: ?*Session, out_count: ?*u32) Status {
    const s = session orelse return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = s.body_count;
    return .ok;
}

/// Reads the index-th submitted body. invalid_argument once index reaches
/// body_count, so a caller loops zero to body_count to visit every body.
pub export fn goss_session_body_result_at(session: ?*Session, index: u32, out_result: ?*pose.Result) Status {
    const s = session orelse return .invalid_argument;
    const out = out_result orelse return .invalid_argument;
    if (index >= s.body_count) return .invalid_argument;
    out.* = s.body_results[index];
    return .ok;
}

/// Submits one frame's depth map from the host AR backend (ARKit scene
/// depth, ARCore Depth API, WebXR depth-sensing): width*height metres
/// per pixel, row major, with the near and far metres that bound it. A
/// zero size clears it. Kept for depth occlusion against the content.
pub export fn goss_session_submit_depth(session: ?*Session, depth: ?[*]const f32, width: u32, height: u32, near: f32, far: f32) Status {
    const s = session orelse return .invalid_argument;
    const gpa = s.engine.gpa;
    const count = @as(usize, width) * height;
    if (count == 0) {
        if (s.depth_data.len != 0) gpa.free(s.depth_data);
        s.depth_data = &.{};
        s.depth_width = 0;
        s.depth_height = 0;
        // The alias clears so nothing samples a stale depth mask; the store's
        // texture is kept for reuse and freed once at session teardown.
        s.depth_texture = null;
        return .ok;
    }
    const src = depth orelse return .invalid_argument;
    if (!validDims(width, height)) return .invalid_argument;
    if (s.depth_data.len != count) {
        if (s.depth_data.len != 0) gpa.free(s.depth_data);
        s.depth_data = gpa.alloc(f32, count) catch {
            s.depth_data = &.{};
            s.depth_width = 0;
            s.depth_height = 0;
            return .out_of_memory;
        };
        // The R8 normalization scratch tracks the depth plane's size, so
        // updateDepthTexture reuses it instead of allocating each submit.
        if (s.depth_scratch.len != 0) gpa.free(s.depth_scratch);
        s.depth_scratch = gpa.alloc(u8, count) catch &.{};
    }
    @memcpy(s.depth_data, src[0..count]);
    s.depth_width = width;
    s.depth_height = height;
    s.depth_near = near;
    s.depth_far = far;
    updateDepthTexture(s, gpa);
    return .ok;
}

/// Segments a host-provided still RGBA image: converts it to NV12 and feeds
/// the running segmenter, so the next render picks up the mask the same way a
/// camera frame would. again when no segmenter is enabled.
pub export fn goss_session_submit_segmentation_image(session: ?*Session, rgba: ?[*]const u8, width: u32, height: u32) Status {
    const s = session orelse return .invalid_argument;
    const pixels = rgba orelse return .invalid_argument;
    if (!validDims(width, height)) return .invalid_argument;
    const worker = s.segmentation_worker orelse return .again;
    const gpa = s.engine.gpa;
    const w: usize = width;
    const h: usize = height;
    const half_w = (w + 1) / 2;
    const half_h = (h + 1) / 2;
    const y_out = gpa.alloc(u8, w * h) catch return .out_of_memory;
    defer gpa.free(y_out);
    const uv_out = gpa.alloc(u8, half_w * half_h * 2) catch return .out_of_memory;
    defer gpa.free(uv_out);
    const conv = math.color.rgbToYuv(.bt601, .video);
    math.color.rgbaToNv12(pixels[0 .. w * h * 4], w, h, conv, y_out, uv_out);
    s.segmentation_image_seq += 1;
    segmentation.submitNv12(worker, width, height, s.segmentation_image_seq, conv, y_out.ptr, width, uv_out.ptr, @intCast(half_w * 2));
    return .ok;
}

/// The mean RGB (0..1) of a reference image sampled at a landmark loop's
/// points by nearest pixel, standing in for that face part's makeup color.
fn averageLoopColor(rgba: []const u8, width: u32, height: u32, lm: [*]const f32, loop: []const u16) [3]f32 {
    var sum: [3]f32 = .{ 0, 0, 0 };
    var n: f32 = 0;
    const max_x: f32 = @floatFromInt(width - 1);
    const max_y: f32 = @floatFromInt(height - 1);
    for (loop) |idx| {
        const x: u32 = @intFromFloat(std.math.clamp(lm[@as(usize, idx) * 3], 0, max_x));
        const y: u32 = @intFromFloat(std.math.clamp(lm[@as(usize, idx) * 3 + 1], 0, max_y));
        const o = (@as(usize, y) * width + x) * 4;
        sum[0] += @as(f32, @floatFromInt(rgba[o])) / 255.0;
        sum[1] += @as(f32, @floatFromInt(rgba[o + 1])) / 255.0;
        sum[2] += @as(f32, @floatFromInt(rgba[o + 2])) / 255.0;
        n += 1;
    }
    if (n == 0) return .{ 0, 0, 0 };
    return .{ sum[0] / n, sum[1] / n, sum[2] / n };
}

/// Samples a reference photo's makeup color per face part: each face-part loop
/// averages the reference RGBA at its points, so a reference-sourced tint.pass
/// paints the live face in the photo's color. The caller passes the reference
/// face landmarks (478, reference-pixel space); a zero count clears it.
pub export fn goss_session_set_makeup_reference(session: ?*Session, rgba: ?[*]const u8, width: u32, height: u32, landmarks: ?[*]const f32, landmark_count: u32) Status {
    const s = session orelse return .invalid_argument;
    if (landmark_count == 0) {
        s.makeup_reference = @splat(null);
        return .ok;
    }
    if (landmark_count != face.landmark_count) return .invalid_argument;
    if (width == 0 or height == 0) return .invalid_argument;
    const pixels = rgba orelse return .invalid_argument;
    const lm = landmarks orelse return .invalid_argument;
    const rgba_slice = pixels[0 .. @as(usize, width) * height * 4];
    s.makeup_reference = @splat(null);
    s.makeup_reference[manifest.lips_channel] = averageLoopColor(rgba_slice, width, height, lm, &face.outer_lip_loop);
    s.makeup_reference[manifest.eyes_channel] = averageLoopColor(rgba_slice, width, height, lm, &face.left_eye_loop);
    s.makeup_reference[manifest.brows_channel] = averageLoopColor(rgba_slice, width, height, lm, &face.left_brow_loop);
    s.makeup_reference[manifest.skin_channel] = averageLoopColor(rgba_slice, width, height, lm, &face.skin_patch);
    return .ok;
}

/// Normalizes the submitted depth (near..far metres) into an R8 texture the
/// dof.pass samples, replacing the previous frame's. A best-effort upload:
/// on allocation failure the old texture stays, so the pass just holds.
fn updateDepthTexture(s: *Session, gpa: std.mem.Allocator) void {
    _ = gpa;
    if (s.engine.renderer == null) return;
    if (s.depth_data.len == 0 or s.depth_scratch.len < s.depth_data.len) return;
    const bytes = s.depth_scratch[0..s.depth_data.len];
    const span = if (s.depth_far > s.depth_near) s.depth_far - s.depth_near else 1.0;
    for (s.depth_data, bytes) |d, *b| {
        const n = std.math.clamp((d - s.depth_near) / span, 0.0, 1.0);
        b.* = @intFromFloat(n * 255.0);
    }
    // A dynamic R8 texture updated in place, so a per-frame depth submit
    // never destroys and recreates a GPU texture; recreated on a size change.
    s.depth_texture = s.depth_tex.upload(@intCast(s.depth_width), @intCast(s.depth_height), bytes);
}

/// The depth (metres) at a normalized frame coordinate, nearest sample,
/// or null when no depth has been submitted. The occlusion pass reads
/// this to tell whether real geometry sits in front of the content.
fn depthAt(s: *const Session, u: f32, v: f32) ?f32 {
    if (s.depth_data.len == 0) return null;
    const fx = std.math.clamp(u, 0, 1) * @as(f32, @floatFromInt(s.depth_width - 1));
    const fy = std.math.clamp(v, 0, 1) * @as(f32, @floatFromInt(s.depth_height - 1));
    const x: usize = @intFromFloat(fx);
    const y: usize = @intFromFloat(fy);
    return s.depth_data[y * s.depth_width + x];
}

/// Derives an occlusion mask from the submitted depth into out, one
/// value per depth pixel: 1 where content sitting at plane_metres is
/// visible, 0 where nearer real geometry hides it. A non-positive depth
/// reads as no occluder. A small bias keeps the plane itself visible.
fn depthOcclusionMask(s: *const Session, plane_metres: f32, out: []f32) usize {
    const count = @min(out.len, s.depth_data.len);
    const bias: f32 = 0.02;
    for (0..count) |i| {
        const scene = s.depth_data[i];
        out[i] = if (scene > 0 and scene < plane_metres - bias) 0 else 1;
    }
    return count;
}

/// Reads the newest hand tracking result into caller memory. Reports
/// again until the worker has published its first result.
pub export fn goss_session_hand_result(session: ?*Session, out_result: ?*hand.Result) Status {
    const s = session orelse return .invalid_argument;
    const out = out_result orelse return .invalid_argument;
    const worker = s.hand_tracking orelse return .again;
    if (!tracking.hand_worker.readResult(worker, out)) return .again;
    return .ok;
}

/// Writes the hand_index-th tracked hand's named joint point (x, y in frame
/// pixels, z in the same scale) into out_xyz, so a lens pins content to a
/// fingertip or the wrist. invalid_argument on an unknown joint or a hand
/// index past the tracked count; again with no worker or a faint hand.
pub export fn goss_session_hand_joint(session: ?*Session, hand_index: u32, joint: u32, out_xyz: ?*[3]f32) Status {
    const s = session orelse return .invalid_argument;
    const out = out_xyz orelse return .invalid_argument;
    const j = hand.Joint.fromU32(joint) orelse return .invalid_argument;
    const worker = s.hand_tracking orelse return .again;
    var result: hand.Result = undefined;
    if (!tracking.hand_worker.readResult(worker, &result)) return .again;
    if (hand_index >= result.hand_count or hand_index >= hand.max_hands) return .invalid_argument;
    const h = &result.hands[hand_index];
    if (h.presence < 0.5) return .again;
    out.* = hand.jointPoint(&h.landmarks, j);
    return .ok;
}

/// Reads the newest pose tracking result into caller memory. Reports
/// again until the worker has published its first result.
/// The first lower-body landmark. Upper-body mode suppresses the knees, ankles,
/// and feet (25..32), keeping the face, torso, arms, and hips.
const pose_lower_body_start = 25;

/// Zeros the lower-body joints of a pose result when upper-body mode is on, so
/// every reader of the pose sees the same suppressed skeleton.
fn applyPoseMode(s: *const Session, out: *pose.Result) void {
    if (!s.pose_upper_body) return;
    var i: usize = pose_lower_body_start;
    while (i < pose.landmark_count) : (i += 1) {
        out.landmarks[i * 3] = 0;
        out.landmarks[i * 3 + 1] = 0;
        out.landmarks[i * 3 + 2] = 0;
        out.visibilities[i] = 0;
        out.presences[i] = 0;
    }
}

/// Sets upper-body pose mode: while enabled, the tracked pose reports only the
/// upper body (face, torso, arms, hips); the lower-body joints read absent, for
/// selfie framing where the legs are out of shot.
pub export fn goss_session_set_pose_upper_body(session: ?*Session, enabled: u32) Status {
    const s = session orelse return .invalid_argument;
    s.pose_upper_body = enabled != 0;
    return .ok;
}

pub export fn goss_session_pose_result(session: ?*Session, out_result: ?*pose.Result) Status {
    const s = session orelse return .invalid_argument;
    const out = out_result orelse return .invalid_argument;
    const worker = s.pose_tracking orelse return .again;
    if (!tracking.pose_worker.readResult(worker, out)) return .again;
    applyPoseMode(s, out);
    return .ok;
}

/// Writes the tracked body's named skeleton joint point (x, y in frame
/// pixels, z in the same scale) into out_xyz, so a lens pins content to a
/// shoulder, a wrist, or a knee. invalid_argument on an unknown joint;
/// again with no worker, no body, or presence below the tracked threshold.
pub export fn goss_session_body_joint(session: ?*Session, joint: u32, out_xyz: ?*[3]f32) Status {
    const s = session orelse return .invalid_argument;
    const out = out_xyz orelse return .invalid_argument;
    const j = pose.Joint.fromU32(joint) orelse return .invalid_argument;
    const worker = s.pose_tracking orelse return .again;
    var result: pose.Result = undefined;
    if (!tracking.pose_worker.readResult(worker, &result)) return .again;
    if (result.landmark_count_out == 0 or result.presence < 0.5) return .again;
    out.* = pose.jointPoint(&result.landmarks, j);
    return .ok;
}

/// Fits the canonical face onto the newest tracked landmarks and writes
/// the head transform - canonical metric space into frame pixels - as a
/// column-major 4x4. Reports again until a face is tracked or while the
/// fit is degenerate.
pub export fn goss_session_face_pose(session: ?*Session, out_matrix: ?*[16]f32) Status {
    const s = session orelse return .invalid_argument;
    const out = out_matrix orelse return .invalid_argument;
    const worker = s.face_tracking orelse return .again;
    var result: face.Result = undefined;
    if (!tracking.readResult(worker, &result)) return .again;
    if (result.landmark_count_out == 0 or result.presence < 0.5) return .again;
    const head = face_geometry.estimateHeadPose(&result.landmarks) orelse return .again;
    var at: usize = 0;
    for (head.cols) |col| {
        out[at] = col[0];
        out[at + 1] = col[1];
        out[at + 2] = col[2];
        out[at + 3] = col[3];
        at += 4;
    }
    return .ok;
}

/// Writes the newest tracked face's named region point (x, y in frame
/// pixels, z in the same scale) into out_xyz, so a lens pins content to the
/// forehead, a cheek, or the chin. invalid_argument on an unknown region;
/// again with no worker, no face, or presence below the tracked threshold.
pub export fn goss_session_face_region(session: ?*Session, region: u32, out_xyz: ?*[3]f32) Status {
    const s = session orelse return .invalid_argument;
    const out = out_xyz orelse return .invalid_argument;
    const r = face.Region.fromU32(region) orelse return .invalid_argument;
    if (s.face_tracking) |worker| {
        var result: face.Result = undefined;
        if (tracking.readResult(worker, &result) and result.landmark_count_out > 0 and result.presence >= 0.5) {
            out.* = face.regionPoint(&result.landmarks, r);
            return .ok;
        }
    }
    // The web host-submitted landmark path, where there is no native worker.
    if (s.web_face_landmarks) |*landmarks| {
        out.* = face.regionPointFromLandmarks(landmarks, r);
        return .ok;
    }
    return .again;
}

/// Stands the beauty chain up for a session. The resource path names the
/// directory holding the effect engine's shader and image assets; builds
/// without the effects engine report unsupported.
pub export fn goss_session_enable_beauty(session: ?*Session, resource_path: ?[*:0]const u8) Status {
    const s = session orelse return .invalid_argument;
    const path = resource_path orelse return .invalid_argument;
    if (s.beauty_chain != null) return .ok;
    s.beauty_chain = beauty.create(s.engine.gpa, path) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_beauty(session: ?*Session) void {
    const s = session orelse return;
    if (s.beauty_chain) |chain| beauty.destroy(s.engine.gpa, chain);
    s.beauty_chain = null;
    s.beauty_amounts = @splat(0);
    destroyBeautyCompositing(s);
    if (is_web) {
        s.web_beauty_amounts = @splat(0);
        destroyWebBeautyTargets(s);
    }
}

/// Effect identifiers follow the header: smooth, whiten, thin face, big
/// eye, lipstick, blush. Values clamp to zero and one; zero disables the
/// effect. On web this writes web_beauty_amounts directly rather than a
/// gpupixel chain (there is no chain on this target, so it works
/// regardless of goss_session_enable_beauty's own result - that call
/// still goes through the native/stub beauty module unchanged).
pub export fn goss_session_set_beauty(session: ?*Session, effect: i32, value: f32) Status {
    const s = session orelse return .invalid_argument;
    if (effect < 0 or effect > 5) return .invalid_argument;
    if (is_web) {
        s.web_beauty_amounts[@intCast(effect)] = std.math.clamp(value, 0.0, 1.0);
        return .ok;
    }
    const chain = s.beauty_chain orelse return .again;
    beauty.set(chain, @enumFromInt(effect), value);
    s.beauty_amounts[@intCast(effect)] = std.math.clamp(value, 0.0, 1.0);
    return .ok;
}

/// Uploads one of beauty.face's four whiten lookup textures on web -
/// slot 0 gray, 1 origin, 2 skin, 3 custom, matching gpupixel's own
/// lookup_gray/lookup_origin/lookup_skin/lookup_light asset order. rgba
/// is a caller-decoded image (this build has no PNG decoder wired in
/// for web); whiten renders inert until all four slots are loaded.
/// Unsupported on every other target - native's whiten runs through
/// adapters/beauty.zig's own gpupixel chain, not this texture set.
pub export fn goss_session_set_beauty_lut(session: ?*Session, slot: i32, rgba: ?[*]const u8, width: u32, height: u32) Status {
    if (!is_web) return .unsupported;
    const s = session orelse return .invalid_argument;
    if (slot < 0 or slot > 3) return .invalid_argument;
    const bytes = rgba orelse return .invalid_argument;
    if (width == 0 or height == 0) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;
    const texture = render.Renderer.createStaticTexture(@intCast(width), @intCast(height), bytes[0 .. @as(usize, width) * height * 4]);
    const index: usize = @intCast(slot);
    if (s.web_beauty_lut_textures[index]) |old| r.destroyTexture(old);
    s.web_beauty_lut_textures[index] = texture;
    return .ok;
}

/// Uploads beauty.lipstick's (effect 0) or beauty.blusher's (effect 1)
/// own source image on web - gpupixel's mouth.png/blusher.png,
/// caller-decoded the same way goss_session_set_beauty_lut's rgba is.
/// Unsupported on every other target - native's lipstick/blush run
/// through adapters/beauty.zig's own gpupixel chain.
pub export fn goss_session_set_beauty_makeup_texture(session: ?*Session, effect: i32, rgba: ?[*]const u8, width: u32, height: u32) Status {
    if (!is_web) return .unsupported;
    const s = session orelse return .invalid_argument;
    const bytes = rgba orelse return .invalid_argument;
    if (width == 0 or height == 0) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;
    const texture = render.Renderer.createStaticTexture(@intCast(width), @intCast(height), bytes[0 .. @as(usize, width) * height * 4]);
    const slot = switch (effect) {
        @intFromEnum(runtime.EffectSlot.lipstick) => &s.web_beauty_lipstick_texture,
        @intFromEnum(runtime.EffectSlot.blush) => &s.web_beauty_blush_texture,
        else => {
            r.destroyTexture(texture);
            return .invalid_argument;
        },
    };
    if (slot.*) |old| r.destroyTexture(old);
    slot.* = texture;
    return .ok;
}

/// Feeds one frame's tracked face landmarks into a web session directly.
/// There is no internal tracking worker to drive beauty.reshape/
/// beauty.lipstick/beauty.blusher on web (goss_session_enable_face_
/// tracking reports unsupported here) - the caller runs its own
/// tracker (a separate wasm module, most likely) and hands the result
/// straight in. points holds point_count * 3 floats (x, y in frame
/// pixels, z in the same scale, matching goss_face_result's own
/// landmarks convention); point_count must be GOSS_FACE_LANDMARK_COUNT,
/// or zero to clear any previously set landmarks (no face this frame).
/// Unsupported on every other target, where goss_session_track_frame
/// feeds the same three effects instead.
pub export fn goss_session_set_face_landmarks(session: ?*Session, points: ?[*]const f32, point_count: u32) Status {
    if (!is_web) return .unsupported;
    const s = session orelse return .invalid_argument;
    if (point_count == 0) {
        s.web_face_landmarks = null;
        return .ok;
    }
    if (point_count != face.landmark_count) return .invalid_argument;
    const p = points orelse return .invalid_argument;
    var landmarks: [face.landmark_count]face.Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        landmark.* = .{ .x = p[at * 3], .y = p[at * 3 + 1], .z = p[at * 3 + 2] };
    }
    s.web_face_landmarks = landmarks;
    return .ok;
}

/// Feeds a segmentation mask the web tracking module computed into the
/// session, uploaded as the subject texture the blend and mask channels
/// sample - the web counterpart to the in-engine segmentation worker. A
/// zero length clears it; the mask is mask_side x mask_side floats.
pub export fn goss_session_set_segmentation_mask(session: ?*Session, mask: ?[*]const f32, mask_len: u32) Status {
    if (!is_web) return .unsupported;
    const s = session orelse return .invalid_argument;
    clearSegmentationTextures(s);
    if (mask_len == 0) return .ok;
    if (mask_len != segmentation.mask_len) return .invalid_argument;
    const m = mask orelse return .invalid_argument;
    s.segmentation_texture = uploadMaskFromF32(&s.seg_tex, @ptrCast(m));
    return .ok;
}

/// The class channels the active lens samples, as a bitmask over
/// mask_channels (bit 0 person, bit 1 background, and so on). The web app
/// uploads exactly these class masks each frame; the in-engine worker path
/// names the same set. Zero means only the subject mask is wanted.
pub export fn goss_session_segmentation_channels(session: ?*Session) u32 {
    const s = session orelse return 0;
    var channels: u32 = 0;
    var it = s.shader_masks.valueIterator();
    while (it.next()) |channel| channels |= @as(u32, 1) << @intCast(channel.*);
    return channels;
}

/// Uploads one class channel's mask (mask_side x mask_side floats) as the
/// texture that channel's shader passes sample. Channel indexes
/// mask_channels; channel 0 (person) rides set_segmentation_mask, which
/// clears every class channel first, so upload the classes after it.
pub export fn goss_session_set_segmentation_class_mask(session: ?*Session, channel: u32, mask: ?[*]const f32, mask_len: u32) Status {
    if (!is_web) return .unsupported;
    const s = session orelse return .invalid_argument;
    if (channel == 0 or channel >= manifest.mask_channels.len) return .invalid_argument;
    s.segmentation_class_textures[channel] = null;
    if (mask_len == 0) return .ok;
    if (mask_len != segmentation.mask_len) return .invalid_argument;
    const m = mask orelse return .invalid_argument;
    s.segmentation_class_textures[channel] = uploadMaskFromF32(&s.class_tex[channel], @ptrCast(m));
    return .ok;
}

/// Runs the beauty chain over one RGBA frame on the calling thread,
/// reading the newest tracking result for the landmark driven effects
/// when face tracking is enabled. The stated CPU path: live preview
/// integration on the render thread is the device side of this row.
pub export fn goss_session_beautify_frame(session: ?*Session, rgba_in: ?[*]const u8, width: u32, height: u32, rgba_out: ?[*]u8) Status {
    const s = session orelse return .invalid_argument;
    const source = rgba_in orelse return .invalid_argument;
    const destination = rgba_out orelse return .invalid_argument;
    if (width == 0 or height == 0) return .invalid_argument;
    const chain = s.beauty_chain orelse return .again;

    var result: face.Result = undefined;
    var tracked: ?*const face.Result = null;
    if (s.face_tracking) |worker| {
        if (tracking.readResult(worker, &result)) tracked = &result;
    }
    beauty.process(chain, source, width, height, tracked, destination) catch return .invalid_argument;
    return .ok;
}

/// Takes s by pointer, not value: the returned Signals borrows
/// &s.blendshapes directly, and a by-value parameter's address does not
/// outlive this call - the caller's own LensSignals storage (guaranteed
/// live for the whole ABI call per goss_session_tick_lens's own contract)
/// is what the borrow must point into instead.
fn toTriggerSignals(s: *const LensSignals) trigger.Signals {
    return .{
        .face_present = s.has_face,
        .hands_present = s.hands_present,
        .world_tracking_state = s.world_tracking_state,
        .audio_level = s.audio_level,
        .tap = s.tap,
        .blendshapes = if (s.has_face) &s.blendshapes else null,
    };
}

fn applyLensEffects(session: *Session, effects: []const runtime.AppliedEffect) void {
    if (is_web) {
        for (effects) |applied| session.web_beauty_amounts[@intFromEnum(applied.effect)] = std.math.clamp(applied.value, 0.0, 1.0);
        return;
    }
    const chain = session.beauty_chain orelse return;
    for (effects) |applied| beauty.set(chain, @enumFromInt(@intFromEnum(applied.effect)), applied.value);
}

fn destroyShaderPrograms(session: *Session) void {
    var it = session.shader_programs.valueIterator();
    while (it.next()) |handle| render.Renderer.destroyProgram(.{ .idx = handle.* });
    session.shader_programs.clearRetainingCapacity();
    session.shader_masks.clearRetainingCapacity();
}

fn destroyChainOrder(session: *Session) void {
    session.engine.gpa.free(session.chain_order);
    session.chain_order = &.{};
}

/// Clears the subject and class matte aliases so a consumer reads the zero
/// mask until the next poll refills them. The GPU textures behind them live
/// on their stores, reused across polls and freed once at session teardown.
fn clearSegmentationTextures(session: *Session) void {
    session.segmentation_texture = null;
    for (&session.segmentation_class_textures) |*slot| slot.* = null;
}

/// Frees the reused matte and depth mask textures at session teardown.
fn destroySegmentationStores(session: *Session) void {
    if (session.engine.renderer == null) return;
    session.seg_tex.deinit();
    for (&session.class_tex) |*store| store.deinit();
    session.depth_tex.deinit();
}

/// Turns the newest published mask into a real GPU texture - runs every
/// frame from goss_engine_render_frame since texture creation belongs on
/// the render thread, mirroring pollLutLoaders. Replaces the previous
/// texture outright since bgfx's static textures are immutable; nothing
/// consumes segmentation_texture yet (background-swap compositing is
/// future work), so this only ever does the upload.
fn uploadMaskFromF32(store: *render.Renderer.DynamicMask, mask: *const [segmentation.mask_len]f32) render.TextureHandle {
    var bytes: [segmentation.mask_len]u8 = undefined;
    for (mask, 0..) |value, i| {
        bytes[i] = @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0);
    }
    return store.upload(segmentation.mask_side, segmentation.mask_side, &bytes);
}

/// Which model output class feeds a named mask channel. selfie_multiclass
/// lays its six labels in mask_channels[1..model_class_end] order, so channel
/// c reads class c-1. Channels past that range derive another way and any
/// other model's order is unknown, so both serve the zero mask.
fn classChannelSource(class_count: u32, channel: usize) ?u32 {
    if (channel >= manifest.model_class_end) return null;
    if (class_count == manifest.model_class_end - 1) return @intCast(channel - 1);
    return null;
}

/// When depth is submitted alongside the segmenter, prunes subject pixels the
/// depth places at or behind the occlusion plane, so the two fuse into a
/// sharper cut than the segmentation mask alone. No depth leaves it untouched.
fn fuseDepthIntoMask(session: *Session, mask: *[segmentation.mask_len]f32) void {
    if (session.depth_data.len == 0) return;
    const plane = (session.depth_near + session.depth_far) * 0.5;
    const side = segmentation.mask_side;
    for (0..side) |y| {
        for (0..side) |x| {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(side));
            const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(side));
            const scene = depthAt(session, u, v) orelse continue;
            if (scene > 0 and scene >= plane) mask[y * side + x] = 0;
        }
    }
}

fn pollSegmentationMask(session: *Session) void {
    const worker = session.segmentation_worker orelse return;
    var mask: [segmentation.mask_len]f32 = undefined;
    if (!segmentation.readMask(worker, &mask)) return;
    fuseDepthIntoMask(session, &mask);

    clearSegmentationTextures(session);
    session.segmentation_texture = uploadMaskFromF32(&session.seg_tex, &mask);

    // Class channels upload only when a consumer of the active lens names
    // them, shader or outline or tint, and the active model's label order
    // maps to them; the person channel (index zero) rides the subject
    // texture above.
    const class_count = segmentation.classCount(worker);
    for (1..manifest.mask_channels.len) |channel| {
        if (!maskChannelNeeded(session, @intCast(channel))) continue;
        const source = classChannelSource(class_count, channel) orelse continue;
        if (!segmentation.readClassMask(worker, source, &mask)) continue;
        session.segmentation_class_textures[channel] = uploadMaskFromF32(&session.class_tex[channel], &mask);
    }
}

/// True when any active mask consumer, shader or outline or tint, names this
/// channel, so a class the running lens never reads is never built.
fn maskChannelNeeded(session: *Session, channel: u8) bool {
    var shader_it = session.shader_masks.valueIterator();
    while (shader_it.next()) |c| if (c.* == channel) return true;
    var outline_it = session.outline_masks.valueIterator();
    while (outline_it.next()) |c| if (c.* == channel) return true;
    var tint_it = session.tint_masks.valueIterator();
    while (tint_it.next()) |c| if (c.* == channel) return true;
    var smooth_it = session.smooth_masks.valueIterator();
    while (smooth_it.next()) |c| if (c.* == channel) return true;
    var matte_it = session.matte_masks.valueIterator();
    while (matte_it.next()) |c| if (c.* == channel) return true;
    return false;
}

fn clearClassTexture(session: *Session, channel: u8) void {
    // The alias clears; the store keeps its texture for the next fill.
    session.segmentation_class_textures[channel] = null;
}

/// The current face landmarks projected into the [0,1] mask grid: the
/// internal tracking worker where it runs, else the host-fed web set. Fills
/// out with one (u, v) per landmark and returns true when a face is present.
fn faceMattePoints(session: *Session, out: *[face.landmark_count][2]f32) bool {
    const desc = (session.current orelse return false).desc;
    const w: f32 = @floatFromInt(desc.width);
    const h: f32 = @floatFromInt(desc.height);
    if (w <= 0 or h <= 0) return false;
    if (session.face_tracking) |worker| {
        var result: face.Result = undefined;
        if (tracking.readResult(worker, &result) and result.landmark_count_out > 0 and result.presence >= 0.5) {
            for (0..face.landmark_count) |i| {
                out[i] = .{ result.landmarks[i * 3] / w, result.landmarks[i * 3 + 1] / h };
            }
            return true;
        }
    }
    if (session.web_face_landmarks) |landmarks| {
        for (0..face.landmark_count) |i| out[i] = .{ landmarks[i].x / w, landmarks[i].y / h };
        return true;
    }
    return false;
}

fn hullCross(o: [2]f32, a: [2]f32, b: [2]f32) f32 {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

/// Rasterizes the convex hull of the landmark points into the mask grid,
/// without clearing, so several hulls union by filling in turn. Monotone
/// chain over points sorted by x then y, then fillPolygon fills the hull.
fn fillLandmarkHull(points: []const [2]f32, mask: *[segmentation.mask_len]f32) void {
    if (points.len < 3 or points.len > face.landmark_count) return;
    var pts_buf: [face.landmark_count][2]f32 = undefined;
    @memcpy(pts_buf[0..points.len], points);
    const pts = pts_buf[0..points.len];
    std.sort.pdq([2]f32, pts, {}, struct {
        fn lt(_: void, a: [2]f32, b: [2]f32) bool {
            return if (a[0] == b[0]) a[1] < b[1] else a[0] < b[0];
        }
    }.lt);
    var hull: [face.landmark_count * 2][2]f32 = undefined;
    var k: usize = 0;
    for (pts) |pt| {
        while (k >= 2 and hullCross(hull[k - 2], hull[k - 1], pt) <= 0) k -= 1;
        hull[k] = pt;
        k += 1;
    }
    const upper_floor = k + 1;
    var j: usize = pts.len - 1;
    while (j > 0) : (j -= 1) {
        const pt = pts[j - 1];
        while (k >= upper_floor and hullCross(hull[k - 2], hull[k - 1], pt) <= 0) k -= 1;
        hull[k] = pt;
        k += 1;
    }
    const hull_len = k - 1;
    fillPolygon(hull[0..hull_len], mask);
}

/// Rasterizes an ordered polygon into the mask grid by the even-odd rule,
/// setting one inside without clearing, so several fills union. Sorts each
/// scanline's edge crossings and fills between successive pairs, so a concave
/// ring rasterizes as faithfully as a convex one.
fn fillPolygon(poly: []const [2]f32, mask: *[segmentation.mask_len]f32) void {
    if (poly.len < 3) return;
    const side = segmentation.mask_side;
    const side_f: f32 = @floatFromInt(side);
    for (0..side) |y| {
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / side_f;
        var xs: [face.landmark_count]f32 = undefined;
        var n: usize = 0;
        var e: usize = 0;
        while (e < poly.len and n < xs.len) : (e += 1) {
            const a = poly[e];
            const b = poly[(e + 1) % poly.len];
            if ((a[1] <= v) == (b[1] <= v)) continue;
            xs[n] = a[0] + (v - a[1]) / (b[1] - a[1]) * (b[0] - a[0]);
            n += 1;
        }
        if (n < 2) continue;
        std.sort.pdq(f32, xs[0..n], {}, struct {
            fn lt(_: void, p: f32, q: f32) bool {
                return p < q;
            }
        }.lt);
        var i: usize = 0;
        while (i + 1 < n) : (i += 2) {
            var x0: i64 = @intFromFloat(@floor(xs[i] * side_f));
            var x1: i64 = @intFromFloat(@ceil(xs[i + 1] * side_f));
            if (x0 < 0) x0 = 0;
            if (x1 > @as(i64, @intCast(side))) x1 = @intCast(side);
            var x: i64 = x0;
            while (x < x1) : (x += 1) mask[y * side + @as(usize, @intCast(x))] = 1;
        }
    }
}

/// Builds the landmark-derived mattes each frame: the face hull feeds the
/// head channel, every tracked hand's hull unions into the hand channel, so
/// a mask consumer can rim or key those regions with no segmentation model.
fn pollLandmarkMattes(session: *Session) void {
    pollHeadMatte(session);
    pollHandMatte(session);
    pollFacePartMatte(session, manifest.lips_channel, &.{&face.outer_lip_loop});
    pollFacePartMatte(session, manifest.eyes_channel, &.{ &face.left_eye_loop, &face.right_eye_loop });
    pollFacePartMatte(session, manifest.brows_channel, &.{ &face.left_brow_loop, &face.right_brow_loop });
    pollFacePartMatte(session, manifest.iris_channel, &.{ &face.left_iris_loop, &face.right_iris_loop });
    pollFacePartMatte(session, manifest.teeth_channel, &.{&face.inner_lip_loop});
    pollFaceHullMatte(session, manifest.contour_channel, &face.contour_regions);
    pollFaceHullMatte(session, manifest.highlight_channel, &face.highlight_regions);
    pollLashLineMatte(session, manifest.lash_line_channel);
}

/// Builds the upper lash-line band matte from both eyes' upper lid arcs: each
/// eye's arc rises off its centroid into a thin ribbon hugging the lash line,
/// unioned across the two, so an eyeliner, mascara, or false-lash tint paints
/// it. No face this frame leaves the channel on the zero mask.
fn pollLashLineMatte(session: *Session, channel: u8) void {
    if (!maskChannelNeeded(session, channel)) return;
    var points: [face.landmark_count][2]f32 = undefined;
    if (!faceMattePoints(session, &points)) return clearClassTexture(session, channel);
    var mask: [segmentation.mask_len]f32 = undefined;
    @memset(&mask, 0);
    var band: [18][2]f32 = undefined;
    fillPolygon(face.lashLineBand(&points, &face.left_eye_loop, &band), &mask);
    fillPolygon(face.lashLineBand(&points, &face.right_eye_loop, &band), &mask);
    clearClassTexture(session, channel);
    session.segmentation_class_textures[channel] = uploadMaskFromF32(&session.class_tex[channel], &mask);
}

/// Builds a contour or highlight matte from clustered face landmarks: each
/// region's convex hull fills into the mask and unions, so a tint keying the
/// channel darkens or lightens those planes. No face this frame leaves the
/// channel on the zero mask, so the makeup degrades to nothing.
fn pollFaceHullMatte(session: *Session, channel: u8, regions: []const []const u16) void {
    if (!maskChannelNeeded(session, channel)) return;
    var points: [face.landmark_count][2]f32 = undefined;
    if (!faceMattePoints(session, &points)) return clearClassTexture(session, channel);
    var mask: [segmentation.mask_len]f32 = undefined;
    @memset(&mask, 0);
    var cluster: [face.landmark_count][2]f32 = undefined;
    for (regions) |region| {
        for (region, 0..) |idx, i| cluster[i] = points[idx];
        fillLandmarkHull(cluster[0..region.len], &mask);
    }
    clearClassTexture(session, channel);
    session.segmentation_class_textures[channel] = uploadMaskFromF32(&session.class_tex[channel], &mask);
}

/// Builds a face-part matte channel from one or more landmark loops, unioned,
/// when a lens names it: each loop is a ring of mesh landmark indices filled
/// as a polygon, so a consumer can rim or tint the mouth or eyes with no
/// segmentation model. No face this frame leaves the channel on the zero mask.
fn pollFacePartMatte(session: *Session, channel: u8, loops: []const []const u16) void {
    if (!maskChannelNeeded(session, channel)) return;
    var points: [face.landmark_count][2]f32 = undefined;
    if (!faceMattePoints(session, &points)) return clearClassTexture(session, channel);
    var mask: [segmentation.mask_len]f32 = undefined;
    @memset(&mask, 0);
    var ring: [face.landmark_count][2]f32 = undefined;
    for (loops) |loop| {
        for (loop, 0..) |idx, i| ring[i] = points[idx];
        fillPolygon(ring[0..loop.len], &mask);
    }
    clearClassTexture(session, channel);
    session.segmentation_class_textures[channel] = uploadMaskFromF32(&session.class_tex[channel], &mask);
}

fn pollHeadMatte(session: *Session) void {
    const head: u8 = manifest.head_channel;
    if (!maskChannelNeeded(session, head)) return;
    var points: [face.landmark_count][2]f32 = undefined;
    if (!faceMattePoints(session, &points)) return clearClassTexture(session, head);
    var mask: [segmentation.mask_len]f32 = undefined;
    @memset(&mask, 0);
    fillLandmarkHull(points[0..], &mask);
    clearClassTexture(session, head);
    session.segmentation_class_textures[head] = uploadMaskFromF32(&session.class_tex[head], &mask);
}

fn pollHandMatte(session: *Session) void {
    const chan: u8 = manifest.hand_channel;
    if (!maskChannelNeeded(session, chan)) return;
    const worker = session.hand_tracking orelse return clearClassTexture(session, chan);
    const desc = (session.current orelse return clearClassTexture(session, chan)).desc;
    const w: f32 = @floatFromInt(desc.width);
    const h: f32 = @floatFromInt(desc.height);
    var result: hand.Result = undefined;
    if (w <= 0 or h <= 0 or !tracking.hand_worker.readResult(worker, &result) or result.hand_count == 0) {
        return clearClassTexture(session, chan);
    }
    var mask: [segmentation.mask_len]f32 = undefined;
    @memset(&mask, 0);
    var any = false;
    for (result.hands[0..result.hand_count]) |tracked| {
        if (tracked.presence < 0.5) continue;
        var pts: [hand.landmark_count][2]f32 = undefined;
        for (0..hand.landmark_count) |i| pts[i] = .{ tracked.landmarks[i * 3] / w, tracked.landmarks[i * 3 + 1] / h };
        fillLandmarkHull(pts[0..], &mask);
        any = true;
    }
    clearClassTexture(session, chan);
    if (any) session.segmentation_class_textures[chan] = uploadMaskFromF32(&session.class_tex[chan], &mask);
}

/// When the host submits depth and no in-engine segmenter runs, the depth
/// doubles as the subject mask: geometry nearer than the submitted range's
/// midpoint reads as foreground, so a blend.pass lens shows the camera
/// frame through it and hides content behind it.
fn pollDepthOcclusion(session: *Session) void {
    if (session.segmentation_worker != null) return;
    if (session.depth_data.len == 0) return;
    const plane = (session.depth_near + session.depth_far) * 0.5;
    const bias: f32 = 0.02;
    const side = segmentation.mask_side;
    var mask: [segmentation.mask_len]f32 = undefined;
    for (0..side) |y| {
        for (0..side) |x| {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(side));
            const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(side));
            const scene = depthAt(session, u, v) orelse 0;
            mask[y * side + x] = if (scene > 0 and scene < plane - bias) 1 else 0;
        }
    }
    clearSegmentationTextures(session);
    session.segmentation_texture = uploadMaskFromF32(&session.seg_tex, &mask);
}

fn destroyLutState(session: *Session) void {
    var loader_it = session.lut_loaders.valueIterator();
    while (loader_it.next()) |loader| loader.*.deinit();
    session.lut_loaders.clearRetainingCapacity();

    if (session.engine.renderer) |*r| {
        var texture_it = session.lut_textures.valueIterator();
        while (texture_it.next()) |handle| r.destroyTexture(handle.*);
    }
    session.lut_textures.clearRetainingCapacity();
}

fn destroyBlendState(session: *Session) void {
    var loader_it = session.blend_loaders.valueIterator();
    while (loader_it.next()) |loader| loader.*.deinit();
    session.blend_loaders.clearRetainingCapacity();

    if (session.engine.renderer) |*r| {
        var texture_it = session.blend_textures.valueIterator();
        while (texture_it.next()) |handle| r.destroyTexture(handle.*);
    }
    session.blend_textures.clearRetainingCapacity();

    var env_loader_it = session.env_loaders.valueIterator();
    while (env_loader_it.next()) |loader| loader.*.deinit();
    session.env_loaders.clearRetainingCapacity();
    if (session.engine.renderer) |*r| {
        var env_texture_it = session.env_textures.valueIterator();
        while (env_texture_it.next()) |handle| r.destroyTexture(handle.*);
    }
    session.env_textures.clearRetainingCapacity();
    // grade.pass and bloom.pass hold only plain params, nothing to free.
    session.grade_params.clearRetainingCapacity();
    session.dof_params.clearRetainingCapacity();
    session.fog_params.clearRetainingCapacity();
    session.outline_params.clearRetainingCapacity();
    session.outline_masks.clearRetainingCapacity();
    session.tint_params.clearRetainingCapacity();
    session.tint_masks.clearRetainingCapacity();
    session.tint_modes.clearRetainingCapacity();
    session.tint_finishes.clearRetainingCapacity();
    session.tint_reference.clearRetainingCapacity();
    session.smooth_params.clearRetainingCapacity();
    session.smooth_masks.clearRetainingCapacity();
    session.matte_params.clearRetainingCapacity();
    session.matte_masks.clearRetainingCapacity();
    session.stylize_params.clearRetainingCapacity();
    session.edge_params.clearRetainingCapacity();
    session.warp_params.clearRetainingCapacity();
    session.reshape_params.clearRetainingCapacity();
    session.trail_params.clearRetainingCapacity();
    session.ssr_params.clearRetainingCapacity();
    session.env_params.clearRetainingCapacity();
    // The prev-frame target is reused across lenses, but its echo belongs to
    // the lens that just left: drop it so the next trail reseeds cleanly.
    session.prev_frame_valid = false;
    session.bloom_params.clearRetainingCapacity();
}

fn destroySpriteState(session: *Session) void {
    var loader_it = session.sprite_loaders.valueIterator();
    while (loader_it.next()) |loader| loader.*.deinit();
    session.sprite_loaders.clearRetainingCapacity();
    if (session.engine.renderer) |*r| {
        var texture_it = session.sprite_textures.valueIterator();
        while (texture_it.next()) |handle| r.destroyTexture(handle.*);
        var mesh_it = session.text3d_meshes.valueIterator();
        while (mesh_it.next()) |t3d| render.Renderer.destroyModelMesh(t3d.mesh);
    }
    // The platform decoder and its rgba buffer exist whether or not a
    // renderer does; only the texture destroy is renderer-gated.
    var video_it = session.video_textures.valueIterator();
    while (video_it.next()) |vid| {
        if (session.engine.renderer) |*r| r.destroyTexture(vid.texture);
        vid.decoder.close();
        session.engine.gpa.free(vid.rgba);
    }
    session.video_textures.clearRetainingCapacity();
    session.text3d_meshes.clearRetainingCapacity();
    session.sprite_textures.clearRetainingCapacity();
    session.sprite_rects.clearRetainingCapacity();
    session.sprite_opacity_params.clearRetainingCapacity();
    var anim_it = session.sprite_anims.valueIterator();
    while (anim_it.next()) |anim| {
        for (anim.loaders) |maybe| if (maybe) |l| l.deinit();
        if (session.engine.renderer) |*r| {
            for (anim.textures) |tex| if (tex.idx != render.invalid_handle) r.destroyTexture(tex);
        }
        session.engine.gpa.free(anim.loaders);
        session.engine.gpa.free(anim.textures);
    }
    session.sprite_anims.clearRetainingCapacity();
}

fn destroyMeshFaceState(session: *Session) void {
    session.model_face_anchors.clearRetainingCapacity();
    session.model_body_anchors.clearRetainingCapacity();
    session.model_skeleton_anchors.clearRetainingCapacity();
    session.model_world_anchors.clearRetainingCapacity();
    if (session.engine.renderer) |*r| {
        _ = r;
        var cm_it = session.cloth_meshes.valueIterator();
        while (cm_it.next()) |mesh| render.Renderer.destroyClothMesh(mesh.*);
    }
    if (session.engine.renderer) |*r| {
        _ = r;
        var hm_it = session.hair_meshes.valueIterator();
        while (hm_it.next()) |mesh| render.Renderer.destroyHairMesh(mesh.*);
    }
    if (session.engine.renderer) |*r| {
        var pm_it = session.particle_meshes.valueIterator();
        while (pm_it.next()) |mesh| render.Renderer.destroyParticleMesh(mesh.*);
        var pbm_it = session.particle_base_meshes.valueIterator();
        while (pbm_it.next()) |mesh| render.Renderer.destroyModelMesh(mesh.*);
        var prm_it = session.particle_ribbon_meshes.valueIterator();
        while (prm_it.next()) |mesh| render.Renderer.destroyParticleMesh(mesh.*);
        var sprite_it = session.particle_sprite_textures.valueIterator();
        while (sprite_it.next()) |tex| r.destroyTexture(tex.*);
        var gps_it = session.gpu_particle_sims.valueIterator();
        while (gps_it.next()) |node| render.Renderer.destroyGpuParticleSim(node.sim);
        var fbm_it = session.fluid_base_meshes.valueIterator();
        while (fbm_it.next()) |mesh| render.Renderer.destroyModelMesh(mesh.*);
    }
    var ps_it = session.particle_systems.valueIterator();
    while (ps_it.next()) |sys| sys.deinit();
    var fl_it = session.fluid_sims.valueIterator();
    while (fl_it.next()) |fluid| fluid.deinit();
    session.gpu_particle_sims.clearRetainingCapacity();
    session.fluid_sims.clearRetainingCapacity();
    session.fluid_base_meshes.clearRetainingCapacity();
    session.particle_meshes.clearRetainingCapacity();
    session.particle_base_meshes.clearRetainingCapacity();
    session.particle_ribbon_meshes.clearRetainingCapacity();
    session.particle_systems.clearRetainingCapacity();
    session.particle_sprite_textures.clearRetainingCapacity();
    session.hair_meshes.clearRetainingCapacity();
    session.hair_ids.clearRetainingCapacity();
    session.hair_vcount.clearRetainingCapacity();
    session.cloth_meshes.clearRetainingCapacity();
    session.cloth_bodies.clearRetainingCapacity();
    session.cloth_cols.clearRetainingCapacity();
    if (session.physics_world) |world| world.destroy();
    session.physics_world = null;
    session.physics_bodies.clearRetainingCapacity();
    session.pending_glb_colliders.clearRetainingCapacity();
    session.grabbable_bodies.clearRetainingCapacity();
    session.grab_body = null;
    session.head_collider_body = null;
    session.live_colliders.clearRetainingCapacity();
    var loader_it = session.mesh_face_loaders.valueIterator();
    while (loader_it.next()) |loader| loader.*.deinit();
    session.mesh_face_loaders.clearRetainingCapacity();

    if (session.engine.renderer) |*r| {
        var texture_it = session.mesh_face_textures.valueIterator();
        while (texture_it.next()) |handle| r.destroyTexture(handle.*);
    }
    session.mesh_face_textures.clearRetainingCapacity();
}

fn destroyModelState(session: *Session) void {
    var loader_it = session.model_loaders.valueIterator();
    while (loader_it.next()) |loader| loader.*.deinit();
    session.model_loaders.clearRetainingCapacity();

    var mesh_it = session.model_meshes.valueIterator();
    while (mesh_it.next()) |loaded| {
        render.Renderer.destroyModelMesh(loaded.mesh);
        gltf.freeAnimations(session.engine.gpa, loaded.animations);
        gltf.freeMorphTargets(session.engine.gpa, loaded.morph_targets);
        if (loaded.morph_rest.len > 0) session.engine.gpa.free(loaded.morph_rest);
        if (loaded.morph_scratch.len > 0) session.engine.gpa.free(loaded.morph_scratch);
        if (loaded.rig) |*rig| destroySkinnedRig(session.engine.gpa, rig);
    }
    session.model_meshes.clearRetainingCapacity();
}

/// Replaces any currently active lens with the one manifest_json
/// describes, splicing its nodes into the session's graph and applying
/// its default effect values to the beauty chain if one is enabled. The
/// new lens is fully parsed and spliced before the old one is torn
/// down: a manifest that fails to parse, or that names an unsupported
/// node type, leaves whatever was already active running rather than
/// destroying a working lens over a failed swap.
fn activateLens(session: *Session, gpa: std.mem.Allocator, manifest_json: []const u8) !void {
    var diag_arena = std.heap.ArenaAllocator.init(gpa);
    defer diag_arena.deinit();
    var diags = manifest.Diagnostics{ .arena = diag_arena.allocator() };
    var parsed = try manifest.parse(gpa, &diags, manifest_json) orelse return error.InvalidManifest;
    // Once activate succeeds the lens owns the manifest arena and
    // new_lens.deinit frees it; the disarm keeps a later failure from
    // walking the same arena twice.
    var parsed_owned = false;
    errdefer if (!parsed_owned) parsed.deinit();

    var new_lens = try runtime.activate(gpa, &session.lens_graph, session.camera_node, parsed);
    parsed_owned = true;
    errdefer new_lens.deinit(&session.lens_graph);

    const effects = try new_lens.currentEffects(gpa);
    defer gpa.free(effects);

    destroyShaderPrograms(session);
    destroyLutState(session);
    destroyBlendState(session);
    destroySpriteState(session);
    destroyMeshFaceState(session);
    destroyModelState(session);
    destroyChainOrder(session);
    teardownScript(session);
    destroySounds(session);
    if (session.active_lens) |*old| old.deinit(&session.lens_graph);
    session.active_lens = new_lens;
    applyLensLayout(session);
    setupScript(session);
    applyLensEffects(session, effects);
}

/// Drives the head composite from the active lens's layout.composite node, if it
/// has one: its arrangement becomes the active layout and its blend the camera
/// base's, marked so it clears when the lens changes. A previous lens-driven
/// layout never carries over to a new lens.
fn applyLensLayout(s: *Session) void {
    if (s.layout_from_lens) {
        s.layout_active = null;
        s.camera_opacity = 1;
        s.camera_key = 0;
        s.camera_chroma = .{ 0, 0, 0, 0 };
        s.layout_from_lens = false;
    }
    const lens = if (s.active_lens) |*l| l else return;
    const lf = lens.layoutComposite() orelse return;
    const total: u8 = s.source_count + 1;
    s.layout_active = switch (lf.arrangement) {
        1 => comp.Layout.sideBySide(total),
        2 => comp.Layout.topBottom(total),
        3 => comp.Layout.pip(.{ 0.62, 0.62, 0.34, 0.34 }),
        5 => comp.Layout.overlay(total),
        else => comp.Layout.grid(total),
    };
    s.camera_opacity = std.math.clamp(lf.opacity, 0, 1);
    s.camera_key = @min(lf.key, 2);
    s.camera_chroma = .{ lf.chroma[0], lf.chroma[1], lf.chroma[2], if (lf.similarity > 0) lf.similarity else 0 };
    s.layout_from_lens = true;
}

const script_fuel_per_tick: u32 = 2_000_000;

/// Frees the active script driver and its parameter-name table. Safe to
/// call when there is no script; leaves the fields empty.
fn teardownScript(s: *Session) void {
    if (s.script_engine) |*e| e.destroy();
    s.script_engine = null;
    for (s.script_param_names) |n| s.engine.gpa.free(n);
    s.engine.gpa.free(s.script_param_names);
    s.script_param_names = &.{};
}

/// Builds the script driver for the just-activated lens, if it carries a
/// script node. A compile or allocation failure leaves the script absent,
/// the defined degradation: the lens keeps its default parameter values.
fn setupScript(s: *Session) void {
    const lens = if (s.active_lens) |*l| l else return;
    const src = lens.scriptSource() orelse return;
    var engine = script.Script.create(src, script_fuel_per_tick) catch return;
    const params = lens.manifest.parameters;
    const names = s.engine.gpa.alloc([:0]const u8, params.len) catch {
        engine.destroy();
        return;
    };
    var built: usize = 0;
    for (params, 0..) |p, i| {
        names[i] = s.engine.gpa.dupeZ(u8, p.name) catch {
            for (names[0..built]) |n| s.engine.gpa.free(n);
            s.engine.gpa.free(names);
            engine.destroy();
            return;
        };
        built += 1;
    }
    s.script_engine = engine;
    s.script_param_names = names;
}

/// Runs the lens script's update(lens) once, exposing the current signals
/// and passing the live parameters in and out. Bounded stack buffers, no
/// per-frame allocation; a script exception or timeout just skips the write.
// The signal names a script reads as lens.signals.<name>: the six live
// signals, then the full ARKit blendshape set by name so a script can react
// to an expression (lens.signals.jawOpen) the way a trigger reads
// jawOpen.blendshape. Built once - every name is a static string.
const base_signal_names = [_][*:0]const u8{ "face_present", "hands_present", "audio_level", "audio_beat", "world_tracking_state", "tap" };
const script_signal_names = blk: {
    var arr: [base_signal_names.len + face.blendshape_count][*:0]const u8 = undefined;
    for (base_signal_names, 0..) |name, i| arr[i] = name;
    for (face.blendshape_names, 0..) |name, i| arr[base_signal_names.len + i] = @ptrCast(name.ptr);
    break :blk arr;
};

fn runScript(s: *Session, signals: *const trigger.Signals) void {
    const engine = if (s.script_engine) |*e| e else return;
    const lens = if (s.active_lens) |*l| l else return;
    var sig_values: [script_signal_names.len]f64 = undefined;
    sig_values[0] = if (signals.face_present) 1.0 else 0.0;
    sig_values[1] = if (signals.hands_present) 1.0 else 0.0;
    sig_values[2] = signals.audio_level;
    sig_values[3] = if (signals.audio_beat) 1.0 else 0.0;
    sig_values[4] = signals.world_tracking_state;
    sig_values[5] = if (signals.tap) 1.0 else 0.0;
    for (0..face.blendshape_count) |i| {
        sig_values[base_signal_names.len + i] = if (signals.blendshapes) |bs| bs[i] else 0.0;
    }
    const n = @min(s.script_param_names.len, 256);
    var name_ptrs: [256][*:0]const u8 = undefined;
    var values: [256]f64 = undefined;
    for (0..n) |i| {
        name_ptrs[i] = s.script_param_names[i].ptr;
        values[i] = lens.param_values[i];
    }
    engine.tick(&script_signal_names, &sig_values, name_ptrs[0..n], values[0..n]) catch return;
    for (0..n) |i| lens.setParam(s.script_param_names[i], @floatCast(values[i]));
}

const audio_sample_rate: u32 = 48000;
const audio_channels: u32 = 1;

/// Frees the lens mixer and its decoded sounds. Safe with no audio active.
fn destroySounds(s: *Session) void {
    if (s.audio_mixer) |*m| m.destroy();
    s.audio_mixer = null;
    s.mix_resampler.reset();
    var it = s.sound_ids.keyIterator();
    while (it.next()) |k| s.engine.gpa.free(k.*);
    s.sound_ids.deinit(s.engine.gpa);
    s.sound_ids = .{};
}

/// Builds the lens mixer and decodes every play_sound target from the bundle.
/// Best-effort: a missing or unreadable sound is skipped, the defined
/// degradation, rather than failing activation.
fn createSounds(s: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) void {
    const lens = if (s.active_lens) |*l| l else return;
    var has_sound = false;
    for (lens.manifest.triggers) |trig| {
        if (trig.action.kind == .play_sound and trig.action.target.len > 0) {
            has_sound = true;
            break;
        }
    }
    if (!has_sound) return;
    var mixer = audio_playback.Mixer.create(audio_sample_rate, audio_channels) catch return;
    for (lens.manifest.triggers) |trig| {
        if (trig.action.kind != .play_sound) continue;
        const rel = trig.action.target;
        if (rel.len == 0 or s.sound_ids.contains(rel)) continue;
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ bundle_path, rel }) catch continue;
        defer gpa.free(full);
        const id = mixer.load(full) catch continue;
        const key = s.engine.gpa.dupe(u8, rel) catch continue;
        s.sound_ids.put(s.engine.gpa, key, id) catch {
            s.engine.gpa.free(key);
            continue;
        };
    }
    s.audio_mixer = mixer;
    s.mix_resampler.reset();
}

/// Starts a voice for every sound a play_sound trigger fired this tick.
fn playFiredSounds(s: *Session) void {
    const mixer = if (s.audio_mixer) |*m| m else return;
    const lens = if (s.active_lens) |*l| l else return;
    for (lens.firedSounds()) |path| {
        if (s.sound_ids.get(path)) |id| mixer.play(id, false, 1.0);
    }
}

/// Pulls the next block of mixed lens audio (frames * channels, s16) for the
/// SDK to play. Silence when no lens sound is active.
pub export fn goss_session_pull_audio(session: ?*Session, out: ?[*]i16, frames: u32) Status {
    const s = session orelse return .invalid_argument;
    const data = out orelse return .invalid_argument;
    const buf = data[0 .. frames * audio_channels];
    if (s.audio_mixer) |*mixer| mixer.pull(buf, frames) else @memset(buf, 0);
    return .ok;
}

/// Folds the active lens sound into the caller's outgoing call/live track:
/// `mic` (interleaved f32 at `sample_rate`/`channels`, or null for silence)
/// summed with the 48 kHz mono lens mixer resampled to that rate, into `out`
/// (frame_count*channels s16). Advances the mixer once, replacing pull_audio.
pub export fn goss_session_mix_output_audio(session: ?*Session, mic: ?[*]const f32, out: ?[*]i16, frame_count: u32, sample_rate: u32, channels: u32) Status {
    const s = session orelse return .invalid_argument;
    const data = out orelse return .invalid_argument;
    if (frame_count == 0 or sample_rate == 0 or channels == 0 or channels > 8) return .invalid_argument;
    const span_all = @as(usize, frame_count) * channels;
    const out_slice = data[0..span_all];
    const mic_slice: ?[]const f32 = if (mic) |m| m[0..span_all] else null;

    const ratio = @as(f64, @floatFromInt(audio_sample_rate)) / @as(f64, @floatFromInt(sample_rate));
    const MixCtx = struct {
        m: *audio_playback.Mixer,
        fn pull(self: *@This()) i16 {
            var one: [audio_channels]i16 = .{0};
            self.m.pull(&one, 1);
            return one[0];
        }
    };

    // The lens mixer is 48 kHz mono. Resample its stream to the outgoing rate a
    // bounded chunk at a time, then sum with the mic. A missing mixer (no lens
    // sound) mixes silence, so the outgoing track is the mic alone.
    var lens_chunk: [1024]i16 = undefined;
    var done: u32 = 0;
    while (done < frame_count) {
        const n = @min(@as(u32, lens_chunk.len), frame_count - done);
        const lens = lens_chunk[0..n];
        if (s.audio_mixer) |*mixer| {
            if (sample_rate == audio_sample_rate) {
                mixer.pull(lens, n);
            } else {
                var ctx = MixCtx{ .m = mixer };
                s.mix_resampler.process(ratio, lens, &ctx, MixCtx.pull);
            }
        } else {
            @memset(lens, 0);
        }
        const base = @as(usize, done) * channels;
        const span = @as(usize, n) * channels;
        const mic_chunk: ?[]const f32 = if (mic_slice) |m| m[base .. base + span] else null;
        audio_mix.combine(lens, mic_chunk, out_slice[base .. base + span], n, channels);
        done += n;
    }
    return .ok;
}

pub export fn goss_session_activate_lens(session: ?*Session, manifest_json: ?[*]const u8, manifest_len: usize) Status {
    const s = session orelse return .invalid_argument;
    const bytes = manifest_json orelse return .invalid_argument;
    if (manifest_len == 0) return .invalid_argument;
    const gpa = s.engine.gpa;
    activateLens(s, gpa, bytes[0..manifest_len]) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        else => .invalid_argument,
    };
    // The asset-free composite nodes (blur.pass, grade.pass, bloom.pass) need
    // no bundle, so build the chain and their params here too - a lens
    // activated from raw json, as on the web, gets its post-effects. Nodes
    // that need packaged assets stay not-ready until a directory load.
    createGradeParams(s, gpa) catch {};
    createBloomParams(s, gpa) catch {};
    createDofParams(s, gpa) catch {};
    createFogParams(s, gpa) catch {};
    createOutlineParams(s, gpa) catch {};
    createTintParams(s, gpa) catch {};
    createSmoothParams(s, gpa) catch {};
    createMatteParams(s, gpa) catch {};
    createStylizeParams(s, gpa) catch {};
    createEdgeParams(s, gpa) catch {};
    createWarpParams(s, gpa) catch {};
    createReshapeParams(s, gpa) catch {};
    createTrailParams(s, gpa) catch {};
    createSsrParams(s, gpa) catch {};
    createEnvParams(s, gpa) catch {};
    // A particle fountain also needs no bundle (the CPU sim and its mesh are
    // built from the field alone), so create it here too; the empty bundle
    // path just means a glTF model's own asset never loads, degrading it,
    // while the fountain runs. A sprite image would need a directory.
    createModelLoaders(s, gpa, "") catch {};
    buildChainOrder(s, gpa) catch {};
    return .ok;
}

/// Loads whatever compiled bytecode a spliced shader.pass node names
/// (shaders/<stem>.<profile>.bin) and creates its bgfx program.
/// Best-effort per node: a packaged bundle was already proven
/// to compile by the validator, so a failure here is a genuine runtime
/// anomaly (missing file, wrong profile) rather than an authoring
/// error - that one pass simply has no program and does not draw,
/// rather than failing the whole activation over it.
fn createShaderPrograms(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const passes = try lens.shaderPassNodes(gpa, &session.lens_graph);
    defer gpa.free(passes);
    if (passes.len == 0) return;

    const tag = render.Renderer.currentShaderProfileTag() catch return;
    const io = defaultIo();
    for (passes) |pass| {
        const bin_path = std.fmt.allocPrint(gpa, "{s}/shaders/{s}.{s}.bin", .{ bundle_path, pass.shader_stem, tag }) catch continue;
        defer gpa.free(bin_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, bin_path, gpa, .limited(256 * 1024)) catch continue;
        defer gpa.free(bytes);
        const program = render.Renderer.loadLensProgram(bytes) catch continue;
        session.shader_programs.put(gpa, pass.graph_index, program.idx) catch {
            render.Renderer.destroyProgram(program);
            continue;
        };
        if (pass.mask_channel) |channel| {
            session.shader_masks.put(gpa, pass.graph_index, channel) catch {};
        }
    }
}

/// Resolves every spliced grade.pass node's parametric grade into
/// session.grade_params, once at activation - grade.pass ships no asset
/// and runs no loader, so its params are ready the moment the chain is.
fn createGradeParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const grades = try lens.gradePassNodes(gpa, &session.lens_graph);
    defer gpa.free(grades);
    for (grades) |g| {
        session.grade_params.put(gpa, g.graph_index, g.grade) catch {};
    }
}

/// Resolves every spliced dof.pass node's focus and strength into
/// session.dof_params, once at activation - mirrors createGradeParams.
fn createDofParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const dofs = try lens.dofPassNodes(gpa, &session.lens_graph);
    defer gpa.free(dofs);
    for (dofs) |d| {
        session.dof_params.put(gpa, d.graph_index, .{ d.focus, d.strength }) catch {};
    }
}

/// Resolves every spliced fog.pass node's color and density into
/// session.fog_params, once at activation - mirrors createDofParams.
fn createFogParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const fogs = try lens.fogPassNodes(gpa, &session.lens_graph);
    defer gpa.free(fogs);
    for (fogs) |f| {
        session.fog_params.put(gpa, f.graph_index, .{ f.color[0], f.color[1], f.color[2], f.density }) catch {};
    }
}

/// Resolves every spliced outline.pass node's color and threshold into
/// session.outline_params, once at activation - mirrors createFogParams.
fn createOutlineParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const outlines = try lens.outlinePassNodes(gpa, &session.lens_graph);
    defer gpa.free(outlines);
    for (outlines) |o| {
        session.outline_params.put(gpa, o.graph_index, .{ o.color[0], o.color[1], o.color[2], o.threshold }) catch {};
        if (o.mask_channel) |channel| session.outline_masks.put(gpa, o.graph_index, channel) catch {};
    }
}

/// Resolves the active lens's tint.pass nodes into session.tint_params and
/// tint_masks, once at activation - mirrors createOutlineParams.
fn createTintParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const tints = try lens.tintPassNodes(gpa, &session.lens_graph);
    defer gpa.free(tints);
    for (tints) |tp| {
        session.tint_params.put(gpa, tp.graph_index, .{ tp.color[0], tp.color[1], tp.color[2], tp.opacity }) catch {};
        if (tp.mask_channel) |channel| session.tint_masks.put(gpa, tp.graph_index, channel) catch {};
        if (tp.from_reference) session.tint_reference.put(gpa, tp.graph_index, {}) catch {};
        if (tp.blend != 0) session.tint_modes.put(gpa, tp.graph_index, tp.blend) catch {};
        if (tp.finish != 0) session.tint_finishes.put(gpa, tp.graph_index, tp.finish) catch {};
    }
}

/// Resolves the active lens's smooth.pass nodes into session.smooth_params and
/// smooth_masks, once at activation - mirrors createTintParams.
fn createSmoothParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const smooths = try lens.smoothPassNodes(gpa, &session.lens_graph);
    defer gpa.free(smooths);
    for (smooths) |sp| {
        session.smooth_params.put(gpa, sp.graph_index, sp.amount) catch {};
        if (sp.mask_channel) |channel| session.smooth_masks.put(gpa, sp.graph_index, channel) catch {};
    }
}

/// Resolves the active lens's matte.refine nodes into session.matte_params and
/// matte_masks, once at activation - mirrors createSmoothParams. A node with
/// no named channel refines the submitted depth instead.
fn createMatteParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const mattes = try lens.matteRefinePassNodes(gpa, &session.lens_graph);
    defer gpa.free(mattes);
    for (mattes) |mp| {
        session.matte_params.put(gpa, mp.graph_index, mp.params) catch {};
        if (mp.mask_channel) |channel| session.matte_masks.put(gpa, mp.graph_index, channel) catch {};
    }
}

/// Resolves the active lens's stylize.pass nodes into session.stylize_params,
/// once at activation - mirrors createGradeParams, no asset or loader.
fn createStylizeParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const stylizes = try lens.stylizePassNodes(gpa, &session.lens_graph);
    defer gpa.free(stylizes);
    for (stylizes) |yp| {
        session.stylize_params.put(gpa, yp.graph_index, yp.params) catch {};
    }
}

/// Resolves the active lens's edge.pass nodes into session.edge_params,
/// once at activation - mirrors createStylizeParams, no asset or loader.
fn createEdgeParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const edges = try lens.edgePassNodes(gpa, &session.lens_graph);
    defer gpa.free(edges);
    for (edges) |ep| {
        session.edge_params.put(gpa, ep.graph_index, ep.params) catch {};
    }
}

/// Resolves the active lens's warp.pass nodes into session.warp_params,
/// once at activation - mirrors createEdgeParams, no asset or loader.
fn createWarpParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const warps = try lens.warpPassNodes(gpa, &session.lens_graph);
    defer gpa.free(warps);
    for (warps) |wp| {
        session.warp_params.put(gpa, wp.graph_index, wp.params) catch {};
    }
}

/// Resolves the active lens's reshape.bank nodes into session.reshape_params,
/// once at activation - mirrors createWarpParams, no asset or loader. The live
/// tracked contour joins these amounts each frame in the draw arm.
fn createReshapeParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const reshapes = try lens.reshapePassNodes(gpa, &session.lens_graph);
    defer gpa.free(reshapes);
    for (reshapes) |rp| {
        session.reshape_params.put(gpa, rp.graph_index, rp.params) catch {};
    }
}

/// Resolves every spliced trail.pass node's echo amount into
/// session.trail_params, once at activation - mirrors createOutlineParams.
fn createTrailParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const trails = try lens.trailPassNodes(gpa, &session.lens_graph);
    defer gpa.free(trails);
    for (trails) |tr| {
        session.trail_params.put(gpa, tr.graph_index, tr.amount) catch {};
    }
}

/// Resolves every spliced ssr.pass node's reflection strength and floor
/// plane into session.ssr_params, once at activation.
fn createSsrParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const ssrs = try lens.ssrPassNodes(gpa, &session.lens_graph);
    defer gpa.free(ssrs);
    for (ssrs) |sr| {
        session.ssr_params.put(gpa, sr.graph_index, .{ sr.strength, sr.plane }) catch {};
    }
}

/// Resolves every spliced env.pass node's sky gradient and intensity into
/// session.env_params, once at activation.
fn createEnvParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const envs = try lens.envPassNodes(gpa, &session.lens_graph);
    defer gpa.free(envs);
    for (envs) |ev| {
        session.env_params.put(gpa, ev.graph_index, .{ ev.top[0], ev.top[1], ev.top[2], ev.bottom[0], ev.bottom[1], ev.bottom[2], ev.intensity }) catch {};
    }
}

/// Resolves every spliced bloom.pass node's glow into session.bloom_params,
/// once at activation - mirrors createGradeParams, one node type over.
fn createBloomParams(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const blooms = try lens.bloomPassNodes(gpa, &session.lens_graph);
    defer gpa.free(blooms);
    for (blooms) |b| {
        session.bloom_params.put(gpa, b.graph_index, b.bloom) catch {};
    }
}

/// The active lens's real chain draw order, spanning both node kinds -
/// built once here regardless of whether each entry's resource is
/// ready yet, since a lut.pass node's load can still be in flight the
/// same frame its position in the chain is already fixed.
fn buildChainOrder(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    session.chain_order = try lens.compositePassNodes(gpa, &session.lens_graph);
}

/// Starts a background load for every spliced lut.pass node's LUT image
/// (assets/<stem>.png). Best-effort per node like createShaderPrograms:
/// a loader that fails to even start just leaves that node without a
/// texture rather than failing the whole activation.
fn createLutLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const luts = try lens.lutPassNodes(gpa, &session.lens_graph);
    defer gpa.free(luts);
    for (luts) |lut| {
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.png", .{ bundle_path, lut.lut_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ImageLoader.start(gpa, path) catch continue;
        session.lut_loaders.put(gpa, lut.graph_index, loader) catch {
            loader.deinit();
        };
    }
}

/// Turns every LUT load that finished (or failed) since the last frame
/// into a real texture (or drops it) - runs every frame from
/// goss_engine_render_frame since texture creation belongs on the render
/// thread, but each loader is otherwise untouched here except the one
/// frame its result actually lands on.
fn pollLutLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.lut_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            const texture = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
            gpa.free(decoded.rgba);
            session.lut_textures.put(gpa, entry.key_ptr.*, texture) catch {
                r.destroyTexture(texture);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.lut_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }
}

/// Starts a background load for every spliced blend.pass node's
/// background image (assets/<stem>.png) - mirrors createLutLoaders
/// exactly, one node type over.
fn createBlendLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const blends = try lens.blendPassNodes(gpa, &session.lens_graph);
    defer gpa.free(blends);
    for (blends) |blend| {
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.png", .{ bundle_path, blend.background_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ImageLoader.start(gpa, path) catch continue;
        session.blend_loaders.put(gpa, blend.graph_index, loader) catch {
            loader.deinit();
        };
    }
}

/// Turns every background load that finished (or failed) since the last
/// frame into a real texture (or drops it) - mirrors pollLutLoaders
/// exactly, one node type over.
fn pollBlendLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.blend_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            const texture = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
            gpa.free(decoded.rgba);
            session.blend_textures.put(gpa, entry.key_ptr.*, texture) catch {
                r.destroyTexture(texture);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.blend_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }
}

/// Starts an equirect load for every env.pass node that ships an environment
/// image (assets/<stem>.png) - mirrors createBlendLoaders. A node with no
/// image, or one whose file is absent, keeps its gradient sky.
fn createEnvLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const envs = try lens.envPassNodes(gpa, &session.lens_graph);
    defer gpa.free(envs);
    for (envs) |ev| {
        const stem = ev.image_stem orelse continue;
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.png", .{ bundle_path, stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ImageLoader.start(gpa, path) catch continue;
        session.env_loaders.put(gpa, ev.graph_index, loader) catch {
            loader.deinit();
        };
    }
}

/// Turns every finished (or failed) env-image load into a texture (or drops
/// it) - mirrors pollBlendLoaders.
fn pollEnvLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.env_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            const texture = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
            gpa.free(decoded.rgba);
            session.env_textures.put(gpa, entry.key_ptr.*, texture) catch {
                r.destroyTexture(texture);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.env_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }
}

/// An animated sprite's frame state: the per-frame loads in flight, the
/// textures they resolve into (in frame order), and the count landed so
/// far, plus the rate the draw cycles them at.
const SpriteAnim = struct {
    frames: u32,
    fps: f32,
    loaders: []?*asset.ImageLoader,
    textures: []render.TextureHandle,
    loaded: u32 = 0,
};

/// A video.texture node's live playback: the streaming decoder, the
/// dynamic texture the current frame sits in, a reused decode buffer,
/// and how many frames have been pulled so the draw only advances when
/// the lens clock crosses the next frame boundary.
const VideoPlayback = struct {
    decoder: video.Decoder,
    texture: render.TextureHandle,
    rgba: []u8,
    width: u32,
    height: u32,
    fps: f32,
    loop: bool,
    /// Frames pulled and presented so far; the first frame lands at load,
    /// so this starts at 1.
    advanced: u64 = 1,
    /// The frame timestamp playback started from, so the clip advances off
    /// the same submitted-frame clock physics rides. Unset until the first
    /// draw stamps it.
    base_us: i64 = std.math.minInt(i64),
    /// Set once a non-looping clip runs out, so the draw holds the last
    /// frame instead of retrying the decoder every frame.
    ended: bool = false,
};

/// Loads a sprite.2d node's animated GIF (assets/<stem>.gif) as a video
/// texture: every frame decodes to a texture up front and a fully-loaded
/// SpriteAnim the render loop cycles at the clip's own rate. Returns false
/// when the node ships no GIF, so the caller falls back to a PNG.
fn tryStartGifSprite(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8, sprite: runtime.SpriteNode) bool {
    if (session.engine.renderer == null) return false;
    const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.gif", .{ bundle_path, sprite.image_stem }) catch return false;
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, gpa, .limited(32 << 20)) catch return false;
    defer gpa.free(bytes);
    const decoded = gif.decode(gpa, bytes) catch return false;
    defer decoded.deinit(gpa);
    const n: u32 = @intCast(decoded.frames.len);
    if (n == 0) return false;

    const loaders = gpa.alloc(?*asset.ImageLoader, 0) catch return false;
    const textures = gpa.alloc(render.TextureHandle, n) catch {
        gpa.free(loaders);
        return false;
    };
    for (decoded.frames, 0..) |frame, i| {
        textures[i] = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), frame);
    }
    // Cycle at the clip's own rate: the mean frame delay in centiseconds,
    // defaulting to a lively rate when the file leaves it unset.
    var total_cs: u32 = 0;
    for (decoded.delays_cs) |d| total_cs += d;
    const avg_cs: f32 = @as(f32, @floatFromInt(total_cs)) / @as(f32, @floatFromInt(n));
    const fps: f32 = if (avg_cs > 0) 100.0 / avg_cs else 12.0;

    session.sprite_anims.put(gpa, sprite.graph_index, .{ .frames = n, .fps = fps, .loaders = loaders, .textures = textures, .loaded = n }) catch {
        if (session.engine.renderer) |*r| for (textures) |tex| r.destroyTexture(tex);
        gpa.free(loaders);
        gpa.free(textures);
        return false;
    };
    return true;
}

/// Starts a background load for every spliced sprite.2d node's image
/// (assets/<stem>.png, or assets/<stem>_<i>.png for an animated sprite)
/// and records the rect it draws at - mirrors createBlendLoaders, plus the
/// static rect the render loop needs.
fn createSpriteLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const sprites = try lens.spriteNodes(gpa, &session.lens_graph);
    defer gpa.free(sprites);
    for (sprites) |sprite| {
        session.sprite_rects.put(gpa, sprite.graph_index, .{ sprite.rect[0], sprite.rect[1], sprite.rect[2], sprite.rect[3], sprite.opacity }) catch {};
        if (sprite.opacity_param.len > 0) session.sprite_opacity_params.put(gpa, sprite.graph_index, sprite.opacity_param) catch {};
        // An animated GIF upgrades the node to a video texture; a node with no
        // GIF falls through to the still or image-sequence PNG path.
        if (tryStartGifSprite(session, gpa, bundle_path, sprite)) continue;
        if (sprite.frames > 1) {
            startSpriteAnim(session, gpa, bundle_path, sprite);
            continue;
        }
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.png", .{ bundle_path, sprite.image_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ImageLoader.start(gpa, path) catch continue;
        session.sprite_loaders.put(gpa, sprite.graph_index, loader) catch {
            loader.deinit();
        };
    }
}

/// Opens each video.texture node's clip (assets/<source>.mp4) on the
/// platform decoder, decodes its first frame into a dynamic texture, and
/// registers it so the sprite branch draws and advances it. Best-effort
/// per node: a missing or undecodable clip just leaves the node blank.
fn createVideoLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    // No renderer, no entries: a decoder registered before the renderer
    // exists could never draw, and its teardown path must stay uniform.
    if (session.engine.renderer == null) return;
    const videos = try lens.videoNodes(gpa, &session.lens_graph);
    defer gpa.free(videos);
    for (videos) |v| {
        session.sprite_rects.put(gpa, v.graph_index, .{ v.rect[0], v.rect[1], v.rect[2], v.rect[3], v.opacity }) catch {};
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.mp4", .{ bundle_path, v.source }) catch continue;
        defer gpa.free(path);
        var decoder = video.Decoder.open(path) orelse continue;
        const rgba = gpa.alloc(u8, @as(usize, decoder.width) * decoder.height * 4) catch {
            decoder.close();
            continue;
        };
        if (decoder.read(rgba) != .frame) {
            gpa.free(rgba);
            decoder.close();
            continue;
        }
        const tex = render.Renderer.createDynamicBgraTexture(@intCast(decoder.width), @intCast(decoder.height));
        render.Renderer.updateDynamicBgraTexture(tex, @intCast(decoder.width), @intCast(decoder.height), rgba);
        session.video_textures.put(gpa, v.graph_index, .{
            .decoder = decoder,
            .texture = tex,
            .rgba = rgba,
            .width = decoder.width,
            .height = decoder.height,
            .fps = v.fps,
            .loop = v.loop,
        }) catch {
            if (session.engine.renderer) |*r| r.destroyTexture(tex);
            gpa.free(rgba);
            decoder.close();
        };
    }
}

/// Pulls decoded frames forward until the texture holds the frame the
/// lens clock now points at, uploading each. A non-looping clip holds its
/// last frame; a looping one rewinds. Catch-up is bounded so a long clock
/// jump cannot stall a frame decoding hundreds of frames.
fn advanceVideo(s: *Session, vid: *VideoPlayback) void {
    if (vid.fps <= 0 or vid.ended) return;
    const current = s.current orelse return;
    if (vid.base_us == std.math.minInt(i64)) vid.base_us = current.desc.timestamp_us;
    const elapsed_us = current.desc.timestamp_us - vid.base_us;
    if (elapsed_us <= 0) return;
    const target: u64 = @as(u64, @intFromFloat(@as(f64, @floatFromInt(elapsed_us)) / 1_000_000.0 * @as(f64, vid.fps))) + 1;
    var budget: u32 = 512;
    while (vid.advanced < target and budget > 0) : (budget -= 1) {
        switch (vid.decoder.read(vid.rgba)) {
            .frame => {
                render.Renderer.updateDynamicBgraTexture(vid.texture, @intCast(vid.width), @intCast(vid.height), vid.rgba);
                vid.advanced += 1;
            },
            .end => {
                if (!(vid.loop and vid.decoder.reset())) {
                    vid.ended = true;
                    break;
                }
            },
            .failed => {
                vid.ended = true;
                break;
            },
        }
    }
}

/// Kicks off one image load per frame of an animated sprite
/// (assets/<stem>_<i>.png) into a fresh SpriteAnim, so pollSpriteLoaders
/// can fill its texture list as the frames land.
fn startSpriteAnim(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8, sprite: runtime.SpriteNode) void {
    const n = sprite.frames;
    const loaders = gpa.alloc(?*asset.ImageLoader, n) catch return;
    const textures = gpa.alloc(render.TextureHandle, n) catch {
        gpa.free(loaders);
        return;
    };
    @memset(loaders, null);
    @memset(textures, .{ .idx = render.invalid_handle });
    for (0..n) |i| {
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}_{d}.png", .{ bundle_path, sprite.image_stem, i }) catch continue;
        defer gpa.free(path);
        loaders[i] = asset.ImageLoader.start(gpa, path) catch null;
    }
    session.sprite_anims.put(gpa, sprite.graph_index, .{ .frames = n, .fps = sprite.fps, .loaders = loaders, .textures = textures }) catch {
        for (loaders) |maybe| if (maybe) |l| l.deinit();
        gpa.free(loaders);
        gpa.free(textures);
    };
}

/// Turns every sprite image load that finished (or failed) since the last
/// frame into a real texture (or drops it) - mirrors pollBlendLoaders.
fn pollSpriteLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.sprite_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            const texture = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
            gpa.free(decoded.rgba);
            session.sprite_textures.put(gpa, entry.key_ptr.*, texture) catch {
                r.destroyTexture(texture);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.sprite_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }

    // Animated sprites carry one loader per frame; land each into its slot.
    var anim_it = session.sprite_anims.iterator();
    while (anim_it.next()) |entry| {
        const anim = entry.value_ptr;
        for (anim.loaders, 0..) |*maybe, i| {
            const loader = maybe.* orelse continue;
            if (loader.take()) |decoded| {
                anim.textures[i] = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
                gpa.free(decoded.rgba);
                anim.loaded += 1;
                loader.deinit();
                maybe.* = null;
            } else if (loader.hasFailed()) {
                loader.deinit();
                maybe.* = null;
            }
        }
    }
}

/// Rasterizes every spliced text.2d node's string with the built-in font
/// and uploads it as a texture, storing it and its rect in the same maps
/// the sprite draw reads - so text draws through the sprite path with no
/// async load, since rasterization is synchronous.
fn createTextTextures(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const r = if (session.engine.renderer) |*rr| rr else return;
    const texts = try lens.textNodes(gpa, &session.lens_graph);
    defer gpa.free(texts);
    for (texts) |txt| {
        // Extruded text builds a 3D block mesh drawn through the model path,
        // instead of a flat sprite texture.
        if (txt.depth > 0) {
            const mesh_geo = font.extrudeMesh(gpa, txt.content, txt.depth) catch continue;
            defer gpa.free(mesh_geo.positions);
            defer gpa.free(mesh_geo.indices);
            if (r.createModelMesh(mesh_geo.positions, mesh_geo.indices)) |mesh| {
                const col: [4]f32 = .{ @as(f32, @floatFromInt(txt.color[0])) / 255.0, @as(f32, @floatFromInt(txt.color[1])) / 255.0, @as(f32, @floatFromInt(txt.color[2])) / 255.0, 1.0 };
                session.text3d_meshes.put(gpa, txt.graph_index, .{ .mesh = mesh, .color = col }) catch {
                    render.Renderer.destroyModelMesh(mesh);
                    continue;
                };
                session.sprite_rects.put(gpa, txt.graph_index, .{ txt.rect[0], txt.rect[1], txt.rect[2], txt.rect[3], txt.opacity }) catch {};
            } else |_| {}
            continue;
        }
        const rich = txt.gradient != null or txt.shadow or txt.stroke != null;
        const raster = if (rich)
            font.rasterizeRich(gpa, txt.content, 4, .{ txt.color[0], txt.color[1], txt.color[2], 255 }, txt.gradient, txt.shadow, txt.stroke) catch continue
        else
            font.rasterize(gpa, txt.content, 4, .{ txt.color[0], txt.color[1], txt.color[2], 255 }) catch continue;
        defer gpa.free(raster.rgba);
        const texture = render.Renderer.createStaticTexture(@intCast(raster.width), @intCast(raster.height), raster.rgba);
        session.sprite_textures.put(gpa, txt.graph_index, texture) catch {
            r.destroyTexture(texture);
            continue;
        };
        session.sprite_rects.put(gpa, txt.graph_index, .{ txt.rect[0], txt.rect[1], txt.rect[2], txt.rect[3], txt.opacity }) catch {};
        if (txt.opacity_param.len > 0) session.sprite_opacity_params.put(gpa, txt.graph_index, txt.opacity_param) catch {};
    }
}

/// Starts a background load for every spliced mesh.face node's texture
/// (assets/<stem>.png) - mirrors createBlendLoaders exactly.
fn createMeshFaceLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const meshes = try lens.meshFaceNodes(gpa, &session.lens_graph);
    defer gpa.free(meshes);
    for (meshes) |mesh| {
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.png", .{ bundle_path, mesh.texture_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ImageLoader.start(gpa, path) catch continue;
        session.mesh_face_loaders.put(gpa, mesh.graph_index, loader) catch {
            loader.deinit();
        };
    }
}

/// Turns every finished mesh.face texture load into a real texture -
/// mirrors pollBlendLoaders exactly.
fn pollMeshFaceLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.mesh_face_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            const texture = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
            gpa.free(decoded.rgba);
            session.mesh_face_textures.put(gpa, entry.key_ptr.*, texture) catch {
                r.destroyTexture(texture);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.mesh_face_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }
}

/// Fills the session's emitter buffer with a sampled subset of the live face
/// landmarks, mapped from frame pixels into the particle camera's world space,
/// and points the face-pattern sim at them. No tracked face leaves the buffer
/// empty and the fountain at rest.
fn feedFaceEmitters(s: *Session, sys: *particles.System, frame_w: u32, frame_h: u32) void {
    const worker = s.face_tracking orelse {
        sys.setEmitters(&.{});
        return;
    };
    var tracked: face.Result = undefined;
    if (!tracking.readResult(worker, &tracked) or tracked.landmark_count_out == 0 or tracked.presence < 0.5) {
        sys.setEmitters(&.{});
        return;
    }
    const fw: f32 = @floatFromInt(@max(frame_w, 1));
    const fh: f32 = @floatFromInt(@max(frame_h, 1));
    const aspect = fw / fh;
    const half: f32 = 0.828; // tan(22.5 deg) * the particle camera's eye z (2)
    const total = @min(tracked.landmark_count_out, face.landmark_count);
    const stride = @max(total / s.particle_emitter_buf.len, 1);
    var n: usize = 0;
    var i: usize = 0;
    while (i < total and n < s.particle_emitter_buf.len) : (i += stride) {
        const px = tracked.landmarks[i * 3 + 0];
        const py = tracked.landmarks[i * 3 + 1];
        const ndc_x = (px / fw) * 2.0 - 1.0;
        const ndc_y = (py / fh) * 2.0 - 1.0;
        s.particle_emitter_buf[n] = .{ ndc_x * half * aspect, -ndc_y * half, 0 };
        n += 1;
    }
    sys.setEmitters(s.particle_emitter_buf[0..n]);
}

/// Maps a lens-format particle pattern name to the sim's emission shape,
/// defaulting to the fountain for anything unrecognised.
fn particlePattern(name: []const u8) particles.Pattern {
    const names = [_]struct { s: []const u8, p: particles.Pattern }{
        .{ .s = "rain", .p = .rain },       .{ .s = "burst", .p = .burst },
        .{ .s = "ring", .p = .ring },       .{ .s = "cone", .p = .cone },
        .{ .s = "sphere", .p = .sphere },   .{ .s = "box", .p = .box },
        .{ .s = "disc", .p = .disc },       .{ .s = "hemisphere", .p = .hemisphere },
        .{ .s = "face", .p = .face },
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n.s)) return n.p;
    }
    return .fountain;
}

/// Loads a fading fountain's sprite texture synchronously at activation - a
/// small image, so no background loader: assets/<stem>.png decoded to a
/// static texture, best-effort, leaving the node on the built-in soft round
/// default when the sprite is missing or unreadable.
fn loadParticleSprite(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8, graph_index: graph.NodeIndex, stem: []const u8) void {
    if (comptime !has_file_io) return;
    const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.png", .{ bundle_path, stem }) catch return;
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, gpa, .limited(4 * 1024 * 1024)) catch return;
    defer gpa.free(bytes);
    const decoded = image.decode(gpa, bytes) catch return;
    defer gpa.free(decoded.rgba);
    const texture = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
    session.particle_sprite_textures.put(gpa, graph_index, texture) catch {
        if (session.engine.renderer) |*r| r.destroyTexture(texture);
    };
}

/// Starts a background load for every spliced model.gltf node's .glb
/// (assets/<stem>.glb) - mirrors createLutLoaders/createBlendLoaders
/// exactly, one node type over.
fn createModelLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const models = try lens.modelNodes(gpa, &session.lens_graph);
    defer gpa.free(models);
    for (models) |model| {
        if (model.face_anchor) {
            session.model_face_anchors.put(gpa, model.graph_index, {}) catch {};
        }
        if (model.body_anchor) {
            session.model_body_anchors.put(gpa, model.graph_index, {}) catch {};
        }
        if (model.skeleton_anchor) {
            session.model_skeleton_anchors.put(gpa, model.graph_index, {}) catch {};
        }
        if (model.world_anchor) {
            session.model_world_anchors.put(gpa, model.graph_index, {}) catch {};
        }
        if (model.particles) |pf| {
            if (session.engine.renderer) |*r| {
                if (pf.sph) {
                    // A 2D SPH fluid: its own sim, drawn as a shared base mesh
                    // per particle at that particle's pooled position.
                    if (sph.Fluid.init(gpa, pf.count, .{ .gravity = pf.gravity })) |fluid| {
                        if (r.createModelMesh(&octahedron_positions, &octahedron_indices)) |base| {
                            session.fluid_sims.put(gpa, model.graph_index, fluid) catch {
                                var f = fluid;
                                f.deinit();
                            };
                            session.fluid_base_meshes.put(gpa, model.graph_index, base) catch {
                                render.Renderer.destroyModelMesh(base);
                            };
                            reserveFrameStage(session, fluid.particles.len * 3);
                        } else |_| {
                            var f = fluid;
                            f.deinit();
                        }
                    } else |_| {}
                    continue;
                }
                if (pf.gpu) {
                    if (r.createGpuParticleSim(pf.count)) |sim| {
                        session.gpu_particle_sims.put(gpa, model.graph_index, .{ .sim = sim, .field = pf }) catch {
                            render.Renderer.destroyGpuParticleSim(sim);
                        };
                        // The GPU node generates its own billboards; no glb, no CPU sim.
                        continue;
                    }
                    // Compute is unavailable on this backend; fall through to the CPU sim.
                }
                const pattern = particlePattern(pf.pattern);
                if (particles.System.init(gpa, .{ .count = pf.count, .gravity = pf.gravity, .speed = pf.speed, .lifetime = pf.lifetime, .speed_spread = pf.speed_spread, .lifetime_spread = pf.lifetime_spread, .drag = pf.drag, .wind = pf.wind, .turbulence = pf.turbulence, .curl = pf.curl, .attract = pf.attract, .attract_strength = pf.attract_strength, .vortex = pf.vortex, .floor = pf.floor, .bounce = pf.bounce, .colliders = pf.colliders, .box_colliders = pf.box_colliders, .plane_colliders = pf.plane_colliders, .oneshot = pf.oneshot, .fade = pf.fade, .color = pf.color, .cool = pf.cool, .size = pf.size, .size_end = pf.size_end, .spin = pf.spin, .stretch = pf.stretch, .frames = pf.frames, .glow = pf.glow, .trail = pf.trail, .sub_count = pf.sub_count, .sub_speed = pf.sub_speed, .sub_lifetime = pf.sub_lifetime, .instanced = pf.instanced, .pattern = pattern })) |sys| {
                    // A trail draws a fading billboard per particle per trail
                    // slot; a fading fountain one quad per particle; a plain one
                    // a single point each. Trails and fades share the billboard
                    // program, so both take the faded mesh path.
                    if (pf.mesh) {
                        // Mesh mode: each particle draws a shared 3D shape, so
                        // there is no billboard buffer, just the base mesh.
                        const base_positions: []const [3]f32 = if (std.mem.eql(u8, pf.mesh_shape, "cube")) &cube_positions else if (std.mem.eql(u8, pf.mesh_shape, "tetra")) &tetra_positions else &octahedron_positions;
                        const base_indices: []const u32 = if (std.mem.eql(u8, pf.mesh_shape, "cube")) &cube_indices else if (std.mem.eql(u8, pf.mesh_shape, "tetra")) &tetra_indices else &octahedron_indices;
                        if (r.createModelMesh(base_positions, base_indices)) |base| {
                            session.particle_systems.put(gpa, model.graph_index, sys) catch {
                                var s2 = sys;
                                s2.deinit();
                            };
                            session.particle_base_meshes.put(gpa, model.graph_index, base) catch {
                                render.Renderer.destroyModelMesh(base);
                            };
                            reserveFrameStage(session, sys.renderCount() * 3);
                        } else |_| {
                            var s2 = sys;
                            s2.deinit();
                        }
                    } else if (pf.ribbon and pf.trail > 1) {
                        // Ribbon mode: a solid strip baked from the trail history
                        // each frame, drawn as flat triangles, not billboards.
                        if (r.createParticleMesh(@intCast(sys.ribbonVertexCount()), false)) |mesh| {
                            session.particle_systems.put(gpa, model.graph_index, sys) catch {
                                var s2 = sys;
                                s2.deinit();
                            };
                            session.particle_ribbon_meshes.put(gpa, model.graph_index, mesh) catch {
                                render.Renderer.destroyParticleMesh(mesh);
                            };
                            reserveFrameStage(session, sys.ribbonVertexCount() * 3);
                        } else |_| {
                            var s2 = sys;
                            s2.deinit();
                        }
                    } else {
                        const faded = pf.fade or pf.trail > 1;
                        const render_count: u32 = @intCast(sys.renderCount());
                        const vertex_count: u32 = if (pf.trail > 1) @intCast(sys.trailVertexCount()) else if (pf.fade) render_count * 6 else render_count;
                        if (r.createParticleMesh(vertex_count, faded)) |mesh| {
                            session.particle_systems.put(gpa, model.graph_index, sys) catch {
                                var s2 = sys;
                                s2.deinit();
                            };
                            session.particle_meshes.put(gpa, model.graph_index, mesh) catch {
                                render.Renderer.destroyParticleMesh(mesh);
                            };
                            reserveFrameStage(session, if (faded) @as(usize, vertex_count) * 8 else @as(usize, vertex_count) * 3);
                            if (pf.sprite) |stem| loadParticleSprite(session, gpa, bundle_path, model.graph_index, stem);
                        } else |_| {
                            var s2 = sys;
                            s2.deinit();
                        }
                    }
                } else |_| {}
            }
            // Particles generate their own points; no glb load.
            continue;
        }
        if (model.hair) |hair| {
            if (physics.supported) {
                if (session.physics_world == null) {
                    session.physics_world = physics.World.create(-9.81) catch null;
                    session.physics_last_us = 0;
                }
                if (session.physics_world) |world| {
                    const hid = world.addHair(hair.strands, hair.verts, hair.length) catch physics.invalid_body;
                    if (hid != physics.invalid_body) {
                        // A solver hair that fails to register fully is removed
                        // again; a half-registered one would strand its mesh.
                        var registered = false;
                        if (session.engine.renderer) |*r| {
                            if (r.createHairMesh(hair.strands, hair.verts)) |mesh| {
                                registered = register: {
                                    session.hair_ids.put(gpa, model.graph_index, hid) catch break :register false;
                                    session.hair_meshes.put(gpa, model.graph_index, mesh) catch {
                                        _ = session.hair_ids.remove(model.graph_index);
                                        break :register false;
                                    };
                                    session.hair_vcount.put(gpa, model.graph_index, hair.strands * hair.verts) catch {};
                                    reserveFrameStage(session, @as(usize, hair.strands) * hair.verts * 3);
                                    break :register true;
                                };
                                if (!registered) render.Renderer.destroyHairMesh(mesh);
                            } else |_| {}
                        }
                        if (!registered) _ = world.removeHair(hid);
                    }
                }
            }
            continue;
        }
        if (model.cloth) |cloth| {
            if (physics.supported) {
                if (session.physics_world == null) {
                    session.physics_world = physics.World.create(-9.81) catch null;
                    session.physics_last_us = 0;
                }
                if (session.physics_world) |world| {
                    const body = world.addCloth(cloth.cols, cloth.rows, cloth.width, cloth.height, .{ 0, 0.4, 0 }) catch physics.invalid_body;
                    if (body != physics.invalid_body) {
                        // Same unwind as hair: an unregistered solver body
                        // comes back out rather than simulating unrendered.
                        var registered = false;
                        if (session.engine.renderer) |*r| {
                            if (r.createClothMesh(cloth.cols, cloth.rows)) |mesh| {
                                registered = register: {
                                    session.cloth_bodies.put(gpa, model.graph_index, body) catch break :register false;
                                    session.cloth_meshes.put(gpa, model.graph_index, mesh) catch {
                                        _ = session.cloth_bodies.remove(model.graph_index);
                                        break :register false;
                                    };
                                    session.cloth_cols.put(gpa, model.graph_index, cloth.cols * cloth.rows) catch {};
                                    reserveFrameStage(session, @as(usize, cloth.cols) * cloth.rows * 3);
                                    break :register true;
                                };
                                if (!registered) render.Renderer.destroyClothMesh(mesh);
                            } else |_| {}
                        }
                        if (!registered) world.removeBody(body);
                    }
                }
            }
            // Cloth generates its own mesh; no glb load.
            continue;
        }
        if (model.balloon) |balloon| {
            if (physics.supported) {
                if (session.physics_world == null) {
                    session.physics_world = physics.World.create(-9.81) catch null;
                    session.physics_last_us = 0;
                }
                if (session.physics_world) |world| {
                    if (buildUnitSphere(gpa, balloon.subdivisions, balloon.radius)) |sphere| {
                        defer sphere.deinit(gpa);
                        const body = world.addSoftBody(sphere.verts, sphere.indices, balloon.pressure, balloon.pinned, .{ 0, 0.4, 0 }) catch physics.invalid_body;
                        if (body != physics.invalid_body) {
                            var registered = false;
                            if (session.engine.renderer) |*r| {
                                if (r.createSoftMesh(@intCast(sphere.verts.len), sphere.indices)) |mesh| {
                                    registered = register: {
                                        session.cloth_bodies.put(gpa, model.graph_index, body) catch break :register false;
                                        session.cloth_meshes.put(gpa, model.graph_index, mesh) catch {
                                            _ = session.cloth_bodies.remove(model.graph_index);
                                            break :register false;
                                        };
                                        session.cloth_cols.put(gpa, model.graph_index, @intCast(sphere.verts.len)) catch {};
                                        reserveFrameStage(session, sphere.verts.len * 3);
                                        break :register true;
                                    };
                                    if (!registered) render.Renderer.destroyClothMesh(mesh);
                                } else |_| {}
                            }
                            if (!registered) world.removeBody(body);
                        }
                    } else |_| {}
                }
            }
            // The balloon generates its own mesh; no glb load.
            continue;
        }
        if (model.physics) |body| {
            if (physics.supported) {
                if (session.physics_world == null) {
                    session.physics_world = physics.World.create(-9.81) catch null;
                    session.physics_last_us = 0;
                }
                if (session.physics_world) |world| {
                    const motion: physics.Motion = if (body.kinematic) .kinematic else if (body.dynamic) .dynamic else .static;
                    const rotation = eulerDegreesToQuat(body.rotation);
                    const id = if (body.shape == .mesh and body.mesh_from_glb) id: {
                        // The collider is the node's own glb; build it once the
                        // geometry decodes (pollModelLoaders), not now.
                        session.pending_glb_colliders.put(gpa, model.graph_index, .{ .position = body.position, .rotation = rotation, .friction = body.friction, .restitution = body.restitution }) catch {};
                        break :id physics.invalid_body;
                    } else switch (body.shape) {
                        .hull => world.addBodyHull(body.hull_points, body.position, rotation, body.friction, body.restitution, motion, body.planar) catch physics.invalid_body,
                        .mesh => world.addBodyMesh(body.hull_points, body.mesh_indices, body.position, rotation, body.friction, body.restitution) catch physics.invalid_body,
                        else => id: {
                            const shape: physics.Shape = switch (body.shape) {
                                .box => .box,
                                .sphere => .sphere,
                                .cylinder => .cylinder,
                                .capsule => .capsule,
                                .hull, .mesh => unreachable,
                            };
                            break :id world.addBodyMaterial(shape, body.position, body.size, rotation, body.friction, body.restitution, motion, body.planar) catch physics.invalid_body;
                        },
                    };
                    if (id != physics.invalid_body) {
                        session.physics_bodies.put(gpa, model.graph_index, id) catch {};
                        // A dynamic body can be grabbed and thrown by a pointer.
                        if (body.dynamic and !body.kinematic) session.grabbable_bodies.append(gpa, id) catch {};
                        // A head-following collider is driven to the tracked head.
                        if (body.follow == .head) session.head_collider_body = id;
                    }
                }
            }
        }
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.glb", .{ bundle_path, model.model_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ModelLoader.start(gpa, path) catch continue;
        session.model_loaders.put(gpa, model.graph_index, loader) catch {
            loader.deinit();
        };
    }

    // Wire chains now that every body exists: a dynamic node chained to
    // an anchor node hangs off it by a distance constraint. Node counts
    // are tiny, so a direct id match beats a map.
    if (session.physics_world) |world| {
        for (models) |model| {
            const body = model.physics orelse continue;
            const chain_to = body.chain_to orelse continue;
            const child = session.physics_bodies.get(model.graph_index) orelse continue;
            for (models) |anchor_model| {
                if (!std.mem.eql(u8, anchor_model.node_id, chain_to)) continue;
                const anchor = session.physics_bodies.get(anchor_model.graph_index) orelse break;
                if (body.jiggle_segments > 1) {
                    // Build a spring chain of hidden proxy bodies between the
                    // anchor and this node, so the node lags and sways after the
                    // anchor moves - jiggle for hair, jewelry, and tails. The
                    // node's own body is the tip; the proxies hang between.
                    const segments = body.jiggle_segments;
                    const seg_len = body.chain_length / @as(f32, @floatFromInt(segments));
                    const anchor_pos = if (anchor_model.physics) |ap| ap.position else .{ 0, 0, 0 };
                    var prev = anchor;
                    var prev_pos = anchor_pos;
                    var link: u32 = 1;
                    while (link < segments) : (link += 1) {
                        const pos: [3]f32 = .{ prev_pos[0], prev_pos[1] - seg_len, prev_pos[2] };
                        const proxy = world.addBody(.sphere, pos, .{ 0.02, 0, 0 }, .dynamic) catch break;
                        world.constrainSpring(prev, proxy, .{ 0, 0, 0 }, .{ 0, 0, 0 }, seg_len, body.jiggle_stiffness, body.jiggle_damping) catch {};
                        prev = proxy;
                        prev_pos = pos;
                    }
                    world.constrainSpring(prev, child, .{ 0, 0, 0 }, .{ 0, 0, 0 }, seg_len, body.jiggle_stiffness, body.jiggle_damping) catch {};
                    break;
                }
                switch (body.joint) {
                    .distance => world.constrainDistance(anchor, child, .{ 0, 0, 0 }, .{ 0, 0, 0 }, 0.0, body.chain_length) catch {},
                    .point => world.constrainPoint(anchor, child, .{ 0, 0, 0 }, .{ 0, 0, 0 }) catch {},
                    .fixed => world.constrainFixed(anchor, child) catch {},
                    .hinge => {
                        // Hinge about z at the anchor's world position, so the
                        // child swings in the anchor's xy plane only.
                        const pivot = if (anchor_model.physics) |ap| ap.position else .{ 0, 0, 0 };
                        world.constrainHinge(anchor, child, pivot, .{ 0, 0, 1 }) catch {};
                    },
                    .spring => world.constrainSpring(anchor, child, .{ 0, 0, 0 }, .{ 0, 0, 0 }, body.chain_length, 1.2, 0.6) catch {},
                }
                break;
            }
        }
    }
}

/// Turns every .glb load that finished (or failed) since the last
/// frame into a real gpu mesh (or drops it) - mirrors pollLutLoaders/
/// pollBlendLoaders, except the decoded geometry is freed right after
/// upload (bgfx_copy takes its own copy) while the decoded animation
/// data is kept: there is no gpu resource for it, renderCompositeChain
/// samples it fresh every frame at the lens's own reported elapsed
/// time.
fn pollModelLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.model_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            // A node whose mesh collider is its own glb builds that static body
            // now, from the just-decoded geometry, before it is freed below.
            if (session.pending_glb_colliders.get(entry.key_ptr.*)) |pc| {
                if (session.physics_world) |world| {
                    if (world.addBodyMesh(decoded.positions, decoded.indices, pc.position, pc.rotation, pc.friction, pc.restitution)) |bid| {
                        session.physics_bodies.put(gpa, entry.key_ptr.*, bid) catch {};
                    } else |_| {}
                }
                _ = session.pending_glb_colliders.remove(entry.key_ptr.*);
            }
            // A morphable mesh draws from a dynamic buffer the morph pass
            // re-uploads each frame; a plain mesh uploads once and stays static.
            const has_morph = decoded.morph_targets.len > 0;
            const mesh = (if (has_morph)
                r.createDynamicModelMesh(decoded.positions, decoded.indices)
            else
                r.createModelMesh(decoded.positions, decoded.indices)) catch {
                gpa.free(decoded.positions);
                gpa.free(decoded.indices);
                gltf.freeAnimations(gpa, decoded.animations);
                if (decoded.skin) |*sk| gltf.freeSkin(gpa, sk);
                gltf.freeMorphTargets(gpa, decoded.morph_targets);
                finished.append(gpa, entry.key_ptr.*) catch {};
                continue;
            };
            // A skinned mesh keeps its geometry to deform each frame; the
            // rig takes over the skin and a copy of the bind positions,
            // while the static mesh still uploaded and can drop them.
            const rig: ?SkinnedRig = if (decoded.skin) |sk|
                (buildSkinnedRig(r, gpa, decoded.positions, decoded.indices, sk) catch null)
            else
                null;
            // A morph mesh keeps its rest positions to deform against and a
            // scratch buffer for the deformed output; a plain mesh drops them.
            var morph_rest: []const [3]f32 = &.{};
            var morph_scratch: [][3]f32 = &.{};
            if (has_morph) {
                if (gpa.alloc([3]f32, decoded.positions.len)) |scratch| {
                    morph_rest = decoded.positions;
                    morph_scratch = scratch;
                } else |_| {
                    gpa.free(decoded.positions);
                }
            } else {
                gpa.free(decoded.positions);
            }
            gpa.free(decoded.indices);
            session.model_meshes.put(gpa, entry.key_ptr.*, .{
                .mesh = mesh,
                .base_color = decoded.base_color,
                .animations = decoded.animations,
                .rig = rig,
                .morph_targets = decoded.morph_targets,
                .morph_rest = morph_rest,
                .morph_scratch = morph_scratch,
            }) catch {
                render.Renderer.destroyModelMesh(mesh);
                if (rig) |rg| {
                    var owned = rg;
                    destroySkinnedRig(gpa, &owned);
                }
                gltf.freeAnimations(gpa, decoded.animations);
                gltf.freeMorphTargets(gpa, decoded.morph_targets);
                if (morph_rest.len > 0) gpa.free(morph_rest);
                if (morph_scratch.len > 0) gpa.free(morph_scratch);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.model_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }
}

/// Activates the lens bundle at bundle_path (bundle_path/manifest.json),
/// then creates a bgfx program for every shader.pass node it spliced
/// and starts a background load for every lut.pass node's LUT image.
/// Additive alongside goss_session_activate_lens rather than a new
/// parameter on it: that function's signature is frozen the moment it
/// shipped, and only a bundle directory - not raw manifest bytes - can
/// name where a shader.pass node's compiled bytecode or a lut.pass
/// node's image lives.
// Explicit anyerror, not inferred: the has_file_io branch below prunes
// away entirely on wasm, which would otherwise narrow the inferred
// error set to just Unsupported there and break the OutOfMemory arm
// goss_session_activate_lens_from_directory's catch already handles for
// every other target.
fn activateLensFromDirectory(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) anyerror!void {
    if (comptime !has_file_io) return error.Unsupported;
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.json", .{bundle_path});
    defer gpa.free(manifest_path);
    const manifest_json = try std.Io.Dir.cwd().readFileAlloc(defaultIo(), manifest_path, gpa, .limited(manifest.max_manifest_bytes + 1));
    defer gpa.free(manifest_json);
    try activateLens(session, gpa, manifest_json);
    try createShaderPrograms(session, gpa, bundle_path);
    try createLutLoaders(session, gpa, bundle_path);
    try createBlendLoaders(session, gpa, bundle_path);
    try createEnvLoaders(session, gpa, bundle_path);
    try createMeshFaceLoaders(session, gpa, bundle_path);
    try createSpriteLoaders(session, gpa, bundle_path);
    try createVideoLoaders(session, gpa, bundle_path);
    try createTextTextures(session, gpa);
    try createModelLoaders(session, gpa, bundle_path);
    try createGradeParams(session, gpa);
    try createBloomParams(session, gpa);
    try createDofParams(session, gpa);
    try createFogParams(session, gpa);
    try createOutlineParams(session, gpa);
    try createTintParams(session, gpa);
    try createSmoothParams(session, gpa);
    try createMatteParams(session, gpa);
    try createStylizeParams(session, gpa);
    try createEdgeParams(session, gpa);
    try createWarpParams(session, gpa);
    try createReshapeParams(session, gpa);
    try createTrailParams(session, gpa);
    try createSsrParams(session, gpa);
    try createEnvParams(session, gpa);
    try buildChainOrder(session, gpa);
    createSounds(session, gpa, bundle_path);
}

pub export fn goss_session_activate_lens_from_directory(session: ?*Session, bundle_path: ?[*]const u8, bundle_path_len: usize) Status {
    const s = session orelse return .invalid_argument;
    const path = bundle_path orelse return .invalid_argument;
    if (bundle_path_len == 0) return .invalid_argument;
    activateLensFromDirectory(s, s.engine.gpa, path[0..bundle_path_len]) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Unsupported => .unsupported,
        else => .invalid_argument,
    };
    return .ok;
}

pub export fn goss_session_deactivate_lens(session: ?*Session) void {
    const s = session orelse return;
    destroyShaderPrograms(s);
    destroyLutState(s);
    destroyBlendState(s);
    destroySpriteState(s);
    destroyMeshFaceState(s);
    destroyModelState(s);
    destroyChainOrder(s);
    teardownScript(s);
    destroySounds(s);
    if (s.active_lens) |*lens| lens.deinit(&s.lens_graph);
    s.active_lens = null;
    if (s.layout_from_lens) {
        s.layout_active = null;
        s.camera_opacity = 1;
        s.camera_key = 0;
        s.camera_chroma = .{ 0, 0, 0, 0 };
        s.layout_from_lens = false;
    }
}

/// Reads a live parameter of the active lens by name, including whatever a
/// script node last wrote. Returns again with no lens active, and
/// invalid_argument for an unknown name, so the two cases stay distinct.
pub export fn goss_session_parameter_value(session: ?*Session, name: ?[*]const u8, name_len: usize, out_value: ?*f32) Status {
    const s = session orelse return .invalid_argument;
    const n = name orelse return .invalid_argument;
    const out = out_value orelse return .invalid_argument;
    const lens = if (s.active_lens) |*l| l else return .again;
    out.* = lens.paramValue(n[0..name_len]) orelse return .invalid_argument;
    return .ok;
}

/// Advances the active lens by dt_us of real time and applies every
/// effect value its triggers/ramps changed to the beauty chain, if one
/// is enabled. Reports GOSS_AGAIN with no active lens, matching the
/// no-chain-yet convention goss_session_set_beauty already uses.
/// Fires a named event the next tick delivers to the lens's event('name')
/// triggers for exactly one tick - drives an on-screen effect from an app
/// moment; the engine knows the name, never its meaning. Buffered without
/// allocation; a full buffer or over-long name is dropped/truncated, not error.
pub export fn goss_session_fire_event(session: ?*Session, name: ?[*]const u8, name_len: usize) Status {
    const s = session orelse return .invalid_argument;
    const n = name orelse return .invalid_argument;
    if (name_len == 0) return .invalid_argument;
    if (s.pending_event_count >= max_pending_events) return .ok; // dropped this tick
    const copy_len = @min(name_len, max_event_name);
    const slot = s.pending_event_count;
    @memcpy(s.pending_event_buf[slot][0..copy_len], n[0..copy_len]);
    s.pending_event_len[slot] = @intCast(copy_len);
    s.pending_event_count += 1;
    return .ok;
}

const head_pose_history = 64;
/// One head-pose reading in the detector's ring: euler radians plus the
/// session clock it was taken at.
const HeadSample = struct {
    yaw: f32 = 0,
    pitch: f32 = 0,
    roll: f32 = 0,
    t_us: i64 = 0,
    valid: bool = false,
};

const head_window_us: i64 = 900_000;
const head_gesture_amplitude: f32 = 0.26;
const head_gesture_reversals: u32 = 2;
const head_gesture_vel_eps: f32 = 0.01;
const head_gesture_refractory_us: i64 = 700_000;
const head_dominant_ratio: f32 = 1.5;

/// Decomposes the canonical->frame head transform into yaw, pitch, and roll.
/// The basis columns carry the fit's uniform scale, so normalize first.
fn headEuler(m: math.Mat4) HeadSample {
    const x = math.vec.normalizeOrZero(math.vec.vec3From4(m.cols[0]));
    const z = math.vec.normalizeOrZero(math.vec.vec3From4(m.cols[2]));
    const pitch = std.math.asin(std.math.clamp(-z[1], -1.0, 1.0));
    const yaw = std.math.atan2(z[0], z[2]);
    const roll = std.math.atan2(x[1], x[0]);
    return .{ .yaw = yaw, .pitch = pitch, .roll = roll };
}

/// Pushes a head-pose sample into the ring at the current session clock.
fn pushHeadSample(s: *Session, e: HeadSample) void {
    s.head_samples[s.head_write] = .{ .yaw = e.yaw, .pitch = e.pitch, .roll = e.roll, .t_us = s.head_clock_us, .valid = true };
    s.head_write = (s.head_write + 1) % head_pose_history;
}

/// A nod is a pitch oscillation, a shake a yaw oscillation: at least two
/// direction reversals in the window, total travel past the amplitude, and
/// the moving axis dominating the other so a diagonal wobble fires neither.
/// The refractory window makes each completed gesture a single edge.
fn detectHeadGestures(s: *Session) struct { nod: bool, shake: bool } {
    var buf: [head_pose_history]HeadSample = undefined;
    var n: usize = 0;
    const now = s.head_clock_us;
    var idx: usize = s.head_write;
    for (0..head_pose_history) |_| {
        idx = (idx + head_pose_history - 1) % head_pose_history;
        const smp = s.head_samples[idx];
        if (!smp.valid or now - smp.t_us > head_window_us) break;
        buf[n] = smp;
        n += 1;
    }
    if (n < 4) return .{ .nod = false, .shake = false };
    std.mem.reverse(HeadSample, buf[0..n]);

    var pitch_rev: u32 = 0;
    var yaw_rev: u32 = 0;
    var p_min = buf[0].pitch;
    var p_max = buf[0].pitch;
    var y_min = buf[0].yaw;
    var y_max = buf[0].yaw;
    var p_dir: i2 = 0;
    var y_dir: i2 = 0;
    for (1..n) |i| {
        const dp = buf[i].pitch - buf[i - 1].pitch;
        const dy = buf[i].yaw - buf[i - 1].yaw;
        const pd: i2 = if (dp > head_gesture_vel_eps) 1 else if (dp < -head_gesture_vel_eps) -1 else 0;
        const yd: i2 = if (dy > head_gesture_vel_eps) 1 else if (dy < -head_gesture_vel_eps) -1 else 0;
        if (pd != 0 and p_dir != 0 and pd != p_dir) pitch_rev += 1;
        if (yd != 0 and y_dir != 0 and yd != y_dir) yaw_rev += 1;
        if (pd != 0) p_dir = pd;
        if (yd != 0) y_dir = yd;
        p_min = @min(p_min, buf[i].pitch);
        p_max = @max(p_max, buf[i].pitch);
        y_min = @min(y_min, buf[i].yaw);
        y_max = @max(y_max, buf[i].yaw);
    }
    const p_span = p_max - p_min;
    const y_span = y_max - y_min;

    var nod = false;
    var shake = false;
    if (now >= s.head_nod_refractory_us and pitch_rev >= head_gesture_reversals and
        p_span > head_gesture_amplitude and p_span > y_span * head_dominant_ratio)
    {
        nod = true;
        s.head_nod_refractory_us = now + head_gesture_refractory_us;
    }
    if (now >= s.head_shake_refractory_us and yaw_rev >= head_gesture_reversals and
        y_span > head_gesture_amplitude and y_span > p_span * head_dominant_ratio)
    {
        shake = true;
        s.head_shake_refractory_us = now + head_gesture_refractory_us;
    }
    return .{ .nod = nod, .shake = shake };
}

/// The head transform for the newest tracked face, or null with no face.
fn currentHeadPose(s: *Session) ?math.Mat4 {
    const worker = s.face_tracking orelse return null;
    var result: face.Result = undefined;
    if (!tracking.readResult(worker, &result)) return null;
    if (result.landmark_count_out == 0 or result.presence < 0.5) return null;
    return face_geometry.estimateHeadPose(&result.landmarks);
}

/// The newest tracked pose landmarks, or null with no body.
fn currentPose(s: *Session) ?pose.Result {
    const worker = s.pose_tracking orelse return null;
    var result: pose.Result = undefined;
    if (!tracking.pose_worker.readResult(worker, &result)) return null;
    if (result.landmark_count_out == 0 or result.presence < 0.5) return null;
    applyPoseMode(s, &result);
    return result;
}

/// A source-frame-pixel anchor transform for a tracked body: positioned at the
/// torso centre, scaled by torso length, and rolled by the torso's tilt, so a
/// body-anchored model rides the figure the way a head-anchored one rides a
/// face. Null when the torso is degenerate.
fn bodyAnchorPose(landmarks: *const [pose.landmark_count * 3]f32) ?math.Mat4 {
    const at = struct {
        fn p(l: *const [pose.landmark_count * 3]f32, i: usize) [2]f32 {
            return .{ l[i * 3], l[i * 3 + 1] };
        }
    }.p;
    const lsh = at(landmarks, 11);
    const rsh = at(landmarks, 12);
    const lhip = at(landmarks, 23);
    const rhip = at(landmarks, 24);
    const sh_cx = (lsh[0] + rsh[0]) * 0.5;
    const sh_cy = (lsh[1] + rsh[1]) * 0.5;
    const hip_cx = (lhip[0] + rhip[0]) * 0.5;
    const hip_cy = (lhip[1] + rhip[1]) * 0.5;
    const ux = sh_cx - hip_cx;
    const uy = sh_cy - hip_cy;
    const torso = @sqrt(ux * ux + uy * uy);
    if (torso <= 0) return null;
    const nux = ux / torso;
    const nuy = uy / torso;
    return .{ .cols = .{
        .{ nuy * torso, -nux * torso, 0, 0 },
        .{ nux * torso, nuy * torso, 0, 0 },
        .{ 0, 0, torso, 0 },
        .{ (sh_cx + hip_cx) * 0.5, (sh_cy + hip_cy) * 0.5, 0, 1 },
    } };
}

/// The skeleton's bones as landmark index pairs: limbs, then the shoulder and
/// hip spans and the torso sides. A skeleton-anchored model draws once per bone.
const bone_segments = [_][2]usize{
    .{ 11, 13 }, .{ 13, 15 }, // left upper arm, forearm
    .{ 12, 14 }, .{ 14, 16 }, // right upper arm, forearm
    .{ 23, 25 }, .{ 25, 27 }, // left thigh, shin
    .{ 24, 26 }, .{ 26, 28 }, // right thigh, shin
    .{ 11, 12 }, .{ 23, 24 }, // shoulders, hips
    .{ 11, 23 }, .{ 12, 24 }, // torso sides
};

/// A source-frame-pixel transform placing a unit model along one bone: its long
/// (y) axis spans the two joints, scaled to the bone length, and its cross
/// section sits at a fraction of that. Null when the bone is degenerate.
fn segmentPose(landmarks: *const [pose.landmark_count * 3]f32, a_idx: usize, b_idx: usize) ?math.Mat4 {
    const ax = landmarks[a_idx * 3];
    const ay = landmarks[a_idx * 3 + 1];
    const bx = landmarks[b_idx * 3];
    const by = landmarks[b_idx * 3 + 1];
    const dx = bx - ax;
    const dy = by - ay;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0) return null;
    const ndx = dx / len;
    const ndy = dy / len;
    const half = len * 0.5;
    const thick = @max(len * 0.15, 1.0);
    return .{ .cols = .{
        .{ ndy * thick, -ndx * thick, 0, 0 },
        .{ ndx * half, ndy * half, 0, 0 },
        .{ 0, 0, thick, 0 },
        .{ (ax + bx) * 0.5, (ay + by) * 0.5, 0, 1 },
    } };
}

test "bodyAnchorPose centres on the torso, scales by its length, and rejects a degenerate torso" {
    const set = struct {
        fn p(l: *[pose.landmark_count * 3]f32, i: usize, x: f32, y: f32) void {
            l[i * 3] = x;
            l[i * 3 + 1] = y;
        }
    }.p;
    var lm: [pose.landmark_count * 3]f32 = @splat(0);
    // Upright: shoulders at y=100, hips at y=300, both centred at x=200.
    set(&lm, 11, 180, 100);
    set(&lm, 12, 220, 100);
    set(&lm, 23, 180, 300);
    set(&lm, 24, 220, 300);
    const m = bodyAnchorPose(&lm).?;
    try t.expectApproxEqAbs(@as(f32, 200), m.cols[3][0], 0.01); // torso centre x
    try t.expectApproxEqAbs(@as(f32, 200), m.cols[3][1], 0.01); // torso centre y
    try t.expectApproxEqAbs(@as(f32, 0), m.cols[1][0], 0.01); // model up maps straight up,
    try t.expectApproxEqAbs(@as(f32, -200), m.cols[1][1], 0.01); // scaled by the torso length

    var flat: [pose.landmark_count * 3]f32 = @splat(0);
    try t.expect(bodyAnchorPose(&flat) == null);
}

/// Linear-blend skinning: writes each rest position deformed by its up
/// to four weighted joint matrices, renormalizing by the summed weight
/// so an unnormalized asset does not scale the mesh. A joint matrix is
/// the tracked joint's world transform times the mesh's inverse bind.
fn skinPositions(
    positions: []const [3]f32,
    vertex_joints: []const [4]u16,
    vertex_weights: []const [4]f32,
    joint_matrices: []const math.Mat4,
    out: [][3]f32,
) void {
    for (positions, vertex_joints, vertex_weights, out) |pos, joints, weights, *dst| {
        const rest: math.Vec3 = pos;
        var blended: math.Vec3 = .{ 0, 0, 0 };
        var total: f32 = 0;
        for (0..4) |k| {
            const w = weights[k];
            if (w == 0) continue;
            blended += @as(math.Vec3, @splat(w)) * joint_matrices[joints[k]].mulPoint(rest);
            total += w;
        }
        const skinned: math.Vec3 = if (total > 0) blended / @as(math.Vec3, @splat(total)) else rest;
        dst.* = skinned;
    }
}

test "skinPositions blends weighted joint transforms and renormalizes" {
    const positions = [_][3]f32{ .{ 1, 0, 0 }, .{ 0, 0, 0 } };
    const joints = [_][4]u16{ .{ 0, 1, 0, 0 }, .{ 1, 0, 0, 0 } };
    const weights = [_][4]f32{ .{ 0.5, 0.5, 0, 0 }, .{ 1, 0, 0, 0 } };
    const mats = [_]math.Mat4{ math.Mat4.identity, math.Mat4.translation(.{ 10, 0, 0 }) };
    var out: [2][3]f32 = undefined;
    skinPositions(&positions, &joints, &weights, &mats, &out);
    // Half rest, half shifted by ten: the midpoint at x=6.
    try t.expectApproxEqAbs(@as(f32, 6), out[0][0], 0.001);
    // Fully joint 1: the origin shifted straight to x=10.
    try t.expectApproxEqAbs(@as(f32, 10), out[1][0], 0.001);
}

test "morphPositions adds weighted target deltas to the rest pose" {
    const rest = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 } };
    const smile = [_][3]f32{ .{ 0, 1, 0 }, .{ 0, 1, 0 } };
    const blink = [_][3]f32{ .{ 0, 0, 2 }, .{ 0, 0, 0 } };
    const targets = [_][]const [3]f32{ &smile, &blink };
    var out: [2][3]f32 = undefined;

    // Half smile, quarter blink: vertex 0 rises 0.5 in y and 0.5 in z.
    morphPositions(&out, &rest, &targets, &.{ 0.5, 0.25 });
    try t.expectApproxEqAbs(@as(f32, 0.0), out[0][0], 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.5), out[0][1], 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.5), out[0][2], 0.001);
    // Vertex 1 keeps its x, takes half the smile's y, no blink.
    try t.expectApproxEqAbs(@as(f32, 1.0), out[1][0], 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.5), out[1][1], 0.001);

    // All weights zero returns the rest pose untouched.
    morphPositions(&out, &rest, &targets, &.{ 0.0, 0.0 });
    try t.expectApproxEqAbs(@as(f32, 1.0), out[1][0], 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.0), out[1][1], 0.001);
}

/// Lowercases into buf and drops a "mixamorig:" style prefix (anything
/// up to the last colon) so the mixamo and vrm/gltf conventions match
/// the same table.
fn normalizeJointName(name: []const u8, buf: *[64]u8) []const u8 {
    var src = name;
    if (std.mem.lastIndexOfScalar(u8, src, ':')) |colon| src = src[colon + 1 ..];
    const n = @min(src.len, buf.len);
    for (buf[0..n], src[0..n]) |*d, ch| d.* = std.ascii.toLower(ch);
    return buf[0..n];
}

/// Maps a humanoid joint name to the pose landmark that drives it,
/// tolerant of mixamo and vrm/gltf naming. Order matters: forearm
/// before arm, upper-leg before leg. An unrecognized name gets .none
/// and holds its bind pose.
fn mapJointTarget(name: []const u8) JointTarget {
    var buf: [64]u8 = undefined;
    const j = normalizeJointName(name, &buf);
    const has = struct {
        fn f(h: []const u8, n: []const u8) bool {
            return std.mem.indexOf(u8, h, n) != null;
        }
    }.f;
    const side = struct {
        fn f(h: []const u8, left: u8, right: u8) JointTarget {
            return .{ .point = if (std.mem.indexOf(u8, h, "right") != null) right else left };
        }
    }.f;
    if (has(j, "hips") or std.mem.eql(u8, j, "hip")) return .{ .midpoint = .{ 23, 24 } };
    if (has(j, "forearm") or has(j, "lowerarm")) return side(j, 13, 14);
    if (has(j, "hand") or has(j, "wrist")) return side(j, 15, 16);
    if (has(j, "shoulder")) return side(j, 11, 12);
    if (has(j, "arm")) return side(j, 11, 12);
    if (has(j, "upleg") or has(j, "upperleg") or has(j, "thigh")) return side(j, 23, 24);
    if (has(j, "leg") or has(j, "shin") or has(j, "calf")) return side(j, 25, 26);
    if (has(j, "foot") or has(j, "ankle") or has(j, "toe")) return side(j, 27, 28);
    if (has(j, "head")) return .{ .point = 0 };
    if (has(j, "neck") or has(j, "chest") or has(j, "spine")) return .{ .midpoint = .{ 11, 12 } };
    return .none;
}

fn jointTargetPixel(landmarks: *const [pose.landmark_count * 3]f32, target: JointTarget) ?math.Vec3 {
    return switch (target) {
        .none => null,
        .point => |i| .{ landmarks[@as(usize, i) * 3], landmarks[@as(usize, i) * 3 + 1], 0 },
        .midpoint => |ab| .{
            (landmarks[@as(usize, ab[0]) * 3] + landmarks[@as(usize, ab[1]) * 3]) * 0.5,
            (landmarks[@as(usize, ab[0]) * 3 + 1] + landmarks[@as(usize, ab[1]) * 3 + 1]) * 0.5,
            0,
        },
    };
}

/// Fills the rig's joint palette for one tracked body: each mapped joint
/// moves to its landmark, brought into mesh space by the anchor inverse
/// so the anchor the draw re-applies cancels and lands it there.
/// Unmapped joints and a singular anchor hold the bind pose.
fn buildBodySkinPalette(rig: *const SkinnedRig, landmarks: *const [pose.landmark_count * 3]f32, anchor_full: math.Mat4) void {
    const inv = math.Mat4.inverse(anchor_full) orelse {
        for (rig.palette) |*p| p.* = math.Mat4.identity;
        return;
    };
    for (rig.palette, rig.joint_targets, rig.skin.inverse_bind) |*p, target, ibm| {
        const pixel = jointTargetPixel(landmarks, target) orelse {
            p.* = math.Mat4.identity;
            continue;
        };
        p.* = math.Mat4.translation(inv.mulPoint(pixel)).mul(ibm);
    }
}

/// Stands a skinned rig up from a decoded model: a dynamic render mesh,
/// a kept copy of the bind positions, scratch for the skinned output,
/// the joint palette, and each joint's resolved landmark target. Takes
/// ownership of the passed skin.
fn buildSkinnedRig(r: *render.Renderer, gpa: std.mem.Allocator, positions: []const [3]f32, indices: []const u32, skin: gltf.DecodedSkin) !SkinnedRig {
    var owned = skin;
    errdefer gltf.freeSkin(gpa, &owned);
    const mesh = try r.createSkinnedMesh(@intCast(positions.len), indices);
    errdefer render.Renderer.destroySkinnedMesh(mesh);
    const rest = try gpa.dupe([3]f32, positions);
    errdefer gpa.free(rest);
    const skinned = try gpa.alloc([3]f32, positions.len);
    errdefer gpa.free(skinned);
    const palette = try gpa.alloc(math.Mat4, owned.joint_count);
    errdefer gpa.free(palette);
    const joint_targets = try gpa.alloc(JointTarget, owned.joint_count);
    errdefer gpa.free(joint_targets);
    for (joint_targets, owned.joint_names) |*jt, name| jt.* = mapJointTarget(name);
    return .{ .mesh = mesh, .skin = owned, .rest = rest, .skinned = skinned, .palette = palette, .joint_targets = joint_targets };
}

fn destroySkinnedRig(gpa: std.mem.Allocator, rig: *SkinnedRig) void {
    render.Renderer.destroySkinnedMesh(rig.mesh);
    gltf.freeSkin(gpa, &rig.skin);
    gpa.free(rig.rest);
    gpa.free(rig.skinned);
    gpa.free(rig.palette);
    gpa.free(rig.joint_targets);
}

test "mapJointTarget covers mixamo and vrm naming" {
    try t.expectEqual(JointTarget{ .midpoint = .{ 23, 24 } }, mapJointTarget("mixamorig:Hips"));
    try t.expectEqual(JointTarget{ .point = 13 }, mapJointTarget("mixamorig:LeftForeArm"));
    try t.expectEqual(JointTarget{ .point = 11 }, mapJointTarget("LeftArm"));
    try t.expectEqual(JointTarget{ .point = 16 }, mapJointTarget("rightHand"));
    try t.expectEqual(JointTarget{ .point = 26 }, mapJointTarget("RightLowerLeg"));
    try t.expectEqual(JointTarget{ .point = 23 }, mapJointTarget("leftUpperLeg"));
    try t.expectEqual(JointTarget{ .point = 0 }, mapJointTarget("Head"));
    try t.expect(mapJointTarget("Camera") == .none);
}

test "buildBodySkinPalette lands a mapped joint on its landmark" {
    // One joint, identity inverse-bind, mapped to the nose (landmark 0).
    var inverse_bind = [_]math.Mat4{math.Mat4.identity};
    var targets = [_]JointTarget{.{ .point = 0 }};
    var palette: [1]math.Mat4 = undefined;
    const rig: SkinnedRig = .{
        .mesh = undefined,
        .skin = .{ .joint_count = 1, .inverse_bind = &inverse_bind, .joint_names = &.{}, .vertex_joints = &.{}, .vertex_weights = &.{} },
        .rest = &.{},
        .skinned = &.{},
        .palette = &palette,
        .joint_targets = &targets,
    };
    var lm: [pose.landmark_count * 3]f32 = @splat(0);
    lm[0] = 200; // nose x
    lm[1] = 120; // nose y
    const anchor = math.Mat4.translation(.{ 10, 20, 0 });
    buildBodySkinPalette(&rig, &lm, anchor);
    // palette = translate(anchor^-1 * nose) with identity bind; anchor
    // re-applied puts the joint origin back at the nose pixel.
    const placed = anchor.mul(palette[0]).mulPoint(.{ 0, 0, 0 });
    try t.expectApproxEqAbs(@as(f32, 200), placed[0], 0.001);
    try t.expectApproxEqAbs(@as(f32, 120), placed[1], 0.001);
}

const body_history = 64;
const body_window_us: i64 = 1_200_000;
const body_jump_amplitude: f32 = 0.18;
const body_wave_amplitude: f32 = 0.15;
const body_wave_reversals: u32 = 2;
const body_move_eps: f32 = 0.01;
const body_action_refractory_us: i64 = 700_000;
const body_dance_energy: f32 = 0.6;
const body_dance_reversals: u32 = 3;

/// One body-motion reading in the action detector's ring: torso-normalized
/// features plus the session clock, so detection is free of scale and distance.
const BodySample = struct {
    hip_y: f32 = 0,
    lwrist_x: f32 = 0,
    rwrist_x: f32 = 0,
    lwrist_up: bool = false,
    rwrist_up: bool = false,
    t_us: i64 = 0,
    valid: bool = false,
};

/// Derives the torso-normalized motion features from a pose, or null if the
/// torso is degenerate, so a bad frame is skipped rather than dividing by zero.
fn bodySampleFrom(landmarks: *const [pose.landmark_count * 3]f32, t_us: i64) ?BodySample {
    const at = struct {
        fn p(l: *const [pose.landmark_count * 3]f32, i: usize) [2]f32 {
            return .{ l[i * 3], l[i * 3 + 1] };
        }
    }.p;
    const lsh = at(landmarks, 11);
    const rsh = at(landmarks, 12);
    const lhip = at(landmarks, 23);
    const rhip = at(landmarks, 24);
    const lwr = at(landmarks, 15);
    const rwr = at(landmarks, 16);
    const sh_cx = (lsh[0] + rsh[0]) * 0.5;
    const sh_cy = (lsh[1] + rsh[1]) * 0.5;
    const hip_cx = (lhip[0] + rhip[0]) * 0.5;
    const hip_cy = (lhip[1] + rhip[1]) * 0.5;
    const dxt = sh_cx - hip_cx;
    const dyt = sh_cy - hip_cy;
    const torso = @sqrt(dxt * dxt + dyt * dyt);
    if (torso <= 0) return null;
    return .{
        .hip_y = hip_cy / torso,
        .lwrist_x = (lwr[0] - sh_cx) / torso,
        .rwrist_x = (rwr[0] - sh_cx) / torso,
        .lwrist_up = lwr[1] < lsh[1],
        .rwrist_up = rwr[1] < rsh[1],
        .t_us = t_us,
        .valid = true,
    };
}

fn pushBodySample(s: *Session, sample: BodySample) void {
    s.body_samples[s.body_write] = sample;
    s.body_write = (s.body_write + 1) % body_history;
}

/// Copies the recent in-window samples into buf, oldest first, and returns how
/// many there were.
fn recentBodySamples(s: *Session, buf: *[body_history]BodySample) usize {
    var n: usize = 0;
    const now = s.body_clock_us;
    var idx: usize = s.body_write;
    for (0..body_history) |_| {
        idx = (idx + body_history - 1) % body_history;
        const smp = s.body_samples[idx];
        if (!smp.valid or now - smp.t_us > body_window_us) break;
        buf[n] = smp;
        n += 1;
    }
    std.mem.reverse(BodySample, buf[0..n]);
    return n;
}

/// True if one hand is raised through most of the window and swings sideways
/// past the amplitude with enough reversals, the shape of a wave.
fn waveOn(buf: []const BodySample, left: bool) bool {
    var up_count: usize = 0;
    var reversals: u32 = 0;
    var dir: i2 = 0;
    var x_min = if (left) buf[0].lwrist_x else buf[0].rwrist_x;
    var x_max = x_min;
    for (buf, 0..) |smp, i| {
        if (if (left) smp.lwrist_up else smp.rwrist_up) up_count += 1;
        const x = if (left) smp.lwrist_x else smp.rwrist_x;
        x_min = @min(x_min, x);
        x_max = @max(x_max, x);
        if (i > 0) {
            const prev = if (left) buf[i - 1].lwrist_x else buf[i - 1].rwrist_x;
            const d: i2 = if (x - prev > body_move_eps) 1 else if (x - prev < -body_move_eps) -1 else 0;
            if (d != 0 and dir != 0 and d != dir) reversals += 1;
            if (d != 0) dir = d;
        }
    }
    return up_count * 2 >= buf.len and reversals >= body_wave_reversals and (x_max - x_min) > body_wave_amplitude;
}

/// A jump is an upward hip excursion that returns, a wave a raised hand
/// swinging sideways, a dance sustained rhythmic motion. Each edge fires once
/// per refractory window; dance is a level held while the motion lasts.
fn detectBodyActions(s: *Session) struct { jump: bool, wave: bool, dance: bool } {
    var buf: [body_history]BodySample = undefined;
    const n = recentBodySamples(s, &buf);
    if (n < 4) return .{ .jump = false, .wave = false, .dance = false };
    const now = s.body_clock_us;

    // The highest point (smallest y, since y grows down) must sit a jump above
    // both ends: the body rose and came back, not just drifted.
    var hip_min = buf[0].hip_y;
    for (buf[0..n]) |smp| hip_min = @min(hip_min, smp.hip_y);
    const jumped = (@min(buf[0].hip_y, buf[n - 1].hip_y) - hip_min) > body_jump_amplitude;

    const waved = waveOn(buf[0..n], true) or waveOn(buf[0..n], false);

    // Sustained rhythmic motion: total travel past the energy floor with
    // several hip-direction reversals over the window.
    var energy: f32 = 0;
    var reversals: u32 = 0;
    var dir: i2 = 0;
    for (1..n) |i| {
        const dh = buf[i].hip_y - buf[i - 1].hip_y;
        energy += @abs(dh) + @abs(buf[i].lwrist_x - buf[i - 1].lwrist_x);
        const d: i2 = if (dh > body_move_eps) 1 else if (dh < -body_move_eps) -1 else 0;
        if (d != 0 and dir != 0 and d != dir) reversals += 1;
        if (d != 0) dir = d;
    }
    const dancing = energy > body_dance_energy and reversals >= body_dance_reversals;

    var jump = false;
    var wave = false;
    if (jumped and now >= s.body_jump_refractory_us) {
        jump = true;
        s.body_jump_refractory_us = now + body_action_refractory_us;
    }
    if (waved and now >= s.body_wave_refractory_us) {
        wave = true;
        s.body_wave_refractory_us = now + body_action_refractory_us;
    }
    return .{ .jump = jump, .wave = wave, .dance = dancing };
}

/// Whether a world-space point is inside a lens trigger volume - a sphere when
/// its radius is set, otherwise an axis-aligned box of its half-extents.
fn volumeContains(vol: manifest.Volume, p: [3]f32) bool {
    const dx = p[0] - vol.center[0];
    const dy = p[1] - vol.center[1];
    const dz = p[2] - vol.center[2];
    if (vol.radius > 0) return dx * dx + dy * dy + dz * dz <= vol.radius * vol.radius;
    return @abs(dx) <= vol.half[0] and @abs(dy) <= vol.half[1] and @abs(dz) <= vol.half[2];
}

const SphereMesh = struct {
    verts: [][3]f32,
    indices: []u32,
    fn deinit(self: SphereMesh, gpa: std.mem.Allocator) void {
        gpa.free(self.verts);
        gpa.free(self.indices);
    }
};

/// Builds a closed sphere shell of `radius` by subdividing an octahedron
/// `subdivisions` times and projecting each vertex onto the sphere, with every
/// triangle wound outward. Used for a soft-body balloon's mesh and render.
fn buildUnitSphere(gpa: std.mem.Allocator, subdivisions: u32, radius: f32) !SphereMesh {
    var verts: std.ArrayList([3]f32) = .empty;
    errdefer verts.deinit(gpa);
    var faces: std.ArrayList([3]u32) = .empty;
    defer faces.deinit(gpa);
    try verts.appendSlice(gpa, &.{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } });
    try faces.appendSlice(gpa, &.{
        .{ 2, 0, 4 }, .{ 2, 4, 1 }, .{ 2, 1, 5 }, .{ 2, 5, 0 },
        .{ 3, 4, 0 }, .{ 3, 1, 4 }, .{ 3, 5, 1 }, .{ 3, 0, 5 },
    });
    var s: u32 = 0;
    while (s < subdivisions) : (s += 1) {
        var midpoints: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer midpoints.deinit(gpa);
        var next: std.ArrayList([3]u32) = .empty;
        errdefer next.deinit(gpa);
        for (faces.items) |f| {
            const ab = try edgeMidpoint(gpa, &verts, &midpoints, f[0], f[1]);
            const bc = try edgeMidpoint(gpa, &verts, &midpoints, f[1], f[2]);
            const ca = try edgeMidpoint(gpa, &verts, &midpoints, f[2], f[0]);
            try next.appendSlice(gpa, &.{ .{ f[0], ab, ca }, .{ ab, f[1], bc }, .{ ca, bc, f[2] }, .{ ab, bc, ca } });
        }
        faces.deinit(gpa);
        faces = next;
    }
    const indices = try gpa.alloc(u32, faces.items.len * 3);
    errdefer gpa.free(indices);
    for (faces.items, 0..) |f, i| {
        const a = verts.items[f[0]];
        const b = verts.items[f[1]];
        const c = verts.items[f[2]];
        // Wind outward: flip if the triangle normal points toward the centre.
        const n = cross3(sub3(b, a), sub3(c, a));
        const outward = n[0] * (a[0] + b[0] + c[0]) + n[1] * (a[1] + b[1] + c[1]) + n[2] * (a[2] + b[2] + c[2]);
        indices[i * 3] = f[0];
        indices[i * 3 + 1] = if (outward < 0) f[2] else f[1];
        indices[i * 3 + 2] = if (outward < 0) f[1] else f[2];
    }
    for (verts.items) |*v| v.* = .{ v[0] * radius, v[1] * radius, v[2] * radius };
    return .{ .verts = try verts.toOwnedSlice(gpa), .indices = indices };
}

fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn edgeMidpoint(gpa: std.mem.Allocator, verts: *std.ArrayList([3]f32), midpoints: *std.AutoHashMapUnmanaged(u64, u32), a: u32, b: u32) !u32 {
    const key = (@as(u64, @min(a, b)) << 32) | @as(u64, @max(a, b));
    if (midpoints.get(key)) |idx| return idx;
    const va = verts.items[a];
    const vb = verts.items[b];
    var mid: [3]f32 = .{ (va[0] + vb[0]) / 2, (va[1] + vb[1]) / 2, (va[2] + vb[2]) / 2 };
    const len = @sqrt(mid[0] * mid[0] + mid[1] * mid[1] + mid[2] * mid[2]);
    if (len > 0) mid = .{ mid[0] / len, mid[1] / len, mid[2] / len };
    const idx: u32 = @intCast(verts.items.len);
    try verts.append(gpa, mid);
    try midpoints.put(gpa, key, idx);
    return idx;
}

/// Turns an euler orientation in degrees (x, y, z) into a quaternion
/// (x, y, z, w) for a physics body, applied in x-then-y-then-z order.
fn eulerDegreesToQuat(euler: [3]f32) [4]f32 {
    const deg2rad = std.math.pi / 180.0;
    const hx = euler[0] * deg2rad * 0.5;
    const hy = euler[1] * deg2rad * 0.5;
    const hz = euler[2] * deg2rad * 0.5;
    const cx = @cos(hx);
    const sx = @sin(hx);
    const cy = @cos(hy);
    const sy = @sin(hy);
    const cz = @cos(hz);
    const sz = @sin(hz);
    return .{
        sx * cy * cz - cx * sy * sz,
        cx * sy * cz + sx * cy * sz,
        cx * cy * sz - sx * sy * cz,
        cx * cy * cz + sx * sy * sz,
    };
}

pub export fn goss_session_tick_lens(session: ?*Session, dt_us: u32, signals: ?*const LensSignals) Status {
    const s = session orelse return .invalid_argument;
    const sig = signals orelse return .invalid_argument;
    if (s.active_lens == null) {
        // Consume any camera focus/exposure change even with no lens, so it does
        // not fire a stale trigger on the first tick after a lens loads.
        s.cam_focus_pulse = false;
        s.cam_exposure_pulse = false;
        return .again;
    }
    // Borrowed from the lens's own activation-sized storage, valid
    // until the next tick - nothing to free, nothing allocated.
    var live_signals = toTriggerSignals(sig);
    // The camera zoom rides the stored controls; normalizeCameraControls clamps
    // it to at least one, and one is the resting value before any control is set.
    live_signals.camera_zoom = @max(s.camera_controls.zoom_factor, 1);
    live_signals.camera_focus = s.cam_focus_pulse;
    live_signals.camera_exposure = s.cam_exposure_pulse;
    // Head movement rides the tracked head pose, computed and scanned
    // on-device; only the nod/shake/tilt edges reach the lens, never the pose.
    s.head_clock_us += @as(i64, dt_us);
    if (currentHeadPose(s)) |head| {
        const e = headEuler(head);
        pushHeadSample(s, e);
        live_signals.head_tilt = e.roll;
        const gestures = detectHeadGestures(s);
        live_signals.head_nod = gestures.nod;
        live_signals.head_shake = gestures.shake;
    }
    // The hand gesture and pinch ride the hand worker: the first non-None
    // gesture and whether any tracked hand is pinching, so a lens fires on
    // `hands.gesture('Thumb_Up')` or `hands.pinch`.
    if (s.hand_tracking) |worker| {
        var hands: hand.Result = undefined;
        if (tracking.hand_worker.readResult(worker, &hands)) {
            for (hands.hands[0..@min(hands.hand_count, hand.max_hands)]) |*h| {
                if (h.gesture != 0 and live_signals.hand_gesture == 0) live_signals.hand_gesture = h.gesture;
                if (hand.isPinching(&h.landmarks)) live_signals.hand_pinch = true;
            }
        }
    }
    // Body presence, bone angles, and action edges ride the pose worker, so a
    // lens fires on body.present, a joint bend, or body.jump/wave/dance. The
    // raw pose is scanned on-device; only these signals reach a lens.
    s.body_clock_us += @as(i64, dt_us);
    if (currentPose(s)) |body| {
        live_signals.body_present = true;
        pose.fillBoneAngles(&body.landmarks, &s.bone_angles);
        live_signals.bone_angles = &s.bone_angles;
        if (bodySampleFrom(&body.landmarks, s.body_clock_us)) |sample| {
            pushBodySample(s, sample);
            const actions = detectBodyActions(s);
            live_signals.body_jump = actions.jump;
            live_signals.body_wave = actions.wave;
            live_signals.body_dance = actions.dance;
        }
    }
    if (s.audio_engine_fed) {
        live_signals.audio_level = s.audio.level;
        live_signals.audio_beat = s.audio.beat;
    }
    if (s.world_engine_fed) {
        live_signals.world_tracking_state = @floatFromInt(s.world.state.tracking_state);
        // The device's world position is the translation column of the pose;
        // a lens with a trigger volume fires device.in_volume while it is
        // inside the region, computed on-device (the pose never reaches a lens).
        if (s.active_lens.?.manifest.volume) |vol| {
            const wfc = s.world.state.world_from_camera;
            live_signals.device_in_volume = volumeContains(vol, .{ wfc[12], wfc[13], wfc[14] });
        }
    }
    if (s.location_engine_fed) {
        if (s.geofence) |region| {
            // An accuracy gate, when set, refuses a fix vaguer than it asks for,
            // so a lens does not fire on a location the device is unsure of.
            const accurate = s.geo_required_accuracy_m == 0 or
                (s.location_accuracy_m > 0 and s.location_accuracy_m <= s.geo_required_accuracy_m);
            live_signals.geo_in_region = accurate and region.contains(s.location_lat, s.location_lon);
        }
    }
    // The events fired since the last tick reach the triggers for this tick
    // only, then clear below - a one-tick pulse an edge-triggered action reads
    // once. The view borrows the session's fixed buffer, valid for this call.
    var event_view: [max_pending_events][]const u8 = undefined;
    for (0..s.pending_event_count) |i| event_view[i] = s.pending_event_buf[i][0..s.pending_event_len[i]];
    live_signals.events = event_view[0..s.pending_event_count];
    // The script drives parameters before triggers and ramps read them, so
    // its writes flow into this tick's effects.
    runScript(s, &live_signals);
    const effects = runtime.tick(&s.active_lens.?, dt_us, live_signals);
    applyLensEffects(s, effects);
    playFiredSounds(s);
    s.pending_event_count = 0;
    s.cam_focus_pulse = false;
    s.cam_exposure_pulse = false;
    return .ok;
}

const t = std.testing;

test "alloc and free round-trip through the abi allocator" {
    const p = goss_alloc(64) orelse return error.TestUnexpectedResult;
    p[0] = 0xa5;
    p[63] = 0x5a;
    goss_free(p, 64);
    try t.expect(goss_alloc(0) == null);
    goss_free(null, 16);
}

test "abi version packs major and minor" {
    try t.expectEqual((@as(u32, abi_major) << 16) | abi_minor, goss_abi_version());
}

test "camera controls normalize to their valid envelope" {
    const out = normalizeCameraControls(.{
        .flash_mode = 99,
        .torch = 7,
        .focus_mode = 5,
        .exposure_mode = 9,
        .focus_point_x = 5.0,
        .focus_point_y = -2.0,
        .exposure_linked = 3,
        .exposure_point_x = 1.5,
        .exposure_point_y = 0.25,
        .exposure_bias_ev = 40,
        .zoom_factor = 99,
        .max_zoom_factor = 4,
        .mirror_save_policy = 1,
        .reserved = 123,
    });
    try t.expectEqual(@as(u32, 0), out.flash_mode); // invalid enum -> off
    try t.expectEqual(@as(u32, 1), out.torch); // nonzero -> on
    try t.expectEqual(@as(u32, 0), out.focus_mode);
    try t.expectEqual(@as(u32, 0), out.exposure_mode);
    try t.expectEqual(@as(f32, 1.0), out.focus_point_x); // clamped to [0,1]
    try t.expectEqual(@as(f32, 0.0), out.focus_point_y);
    try t.expectEqual(@as(u32, 1), out.exposure_linked);
    try t.expectEqual(@as(f32, 1.0), out.exposure_point_x);
    try t.expectEqual(@as(f32, 0.25), out.exposure_point_y);
    try t.expectEqual(@as(f32, 8.0), out.exposure_bias_ev); // clamped to [-8,8]
    try t.expectEqual(@as(f32, 4.0), out.zoom_factor); // clamped to [1, max=4]
    try t.expectEqual(@as(u32, 0), out.mirror_save_policy); // reserved -> uniform
    try t.expectEqual(@as(u32, 0), out.reserved);

    // Unknown device ceiling (max < 1) falls back to the 128x cap.
    const wide = normalizeCameraControls(.{ .zoom_factor = 200, .max_zoom_factor = 0 });
    try t.expectEqual(@as(f32, 128.0), wide.zoom_factor);
    try t.expectEqual(@as(f32, 0.0), wide.max_zoom_factor);
}

test "camera controls set-get round-trips the normalized value" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);
    var in: CameraControls = .{ .zoom_factor = 0.1, .exposure_bias_ev = -99, .focus_point_x = 2.0 };
    try t.expectEqual(Status.ok, goss_session_set_camera_controls(session, &in));
    var back: CameraControls = undefined;
    try t.expectEqual(Status.ok, goss_session_camera_controls(session, &back));
    try t.expectEqual(@as(f32, 1.0), back.zoom_factor);
    try t.expectEqual(@as(f32, -8.0), back.exposure_bias_ev);
    try t.expectEqual(@as(f32, 1.0), back.focus_point_x);
    // Null args are rejected, not crashes.
    try t.expectEqual(Status.invalid_argument, goss_session_set_camera_controls(null, &in));
    try t.expectEqual(Status.invalid_argument, goss_session_camera_controls(session, null));
}

test "recording policy clamps to its envelope and set-get round-trips" {
    const out = normalizeRecordingPolicy(.{
        .max_duration_ms = 5_000_000,
        .min_clip_ms = 9_000_000,
        .segment_mode = 7,
        .loop_playback = 42,
        .speed_preset = 9,
        .mic_muted = 3,
        .save_original = 5,
        .stabilization = 8,
        .reserved0 = 111,
        .reserved1 = 222,
    });
    try t.expectEqual(@as(u32, 600_000), out.max_duration_ms); // capped at 10 min
    try t.expectEqual(@as(u32, 600_000), out.min_clip_ms); // clamped to max_duration
    try t.expectEqual(@as(u32, 0), out.segment_mode); // out of range -> off
    try t.expectEqual(@as(u32, 1), out.loop_playback); // nonzero -> on
    try t.expectEqual(@as(u32, 0), out.speed_preset);
    try t.expectEqual(@as(u32, 1), out.mic_muted);
    try t.expectEqual(@as(u32, 1), out.save_original);
    try t.expectEqual(@as(u32, 0), out.stabilization);
    try t.expectEqual(@as(u32, 0), out.reserved0);
    try t.expectEqual(@as(u32, 0), out.reserved1);

    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);
    var in: RecordingPolicy = .{ .max_duration_ms = 30_000, .speed_preset = 2, .mic_muted = 1 };
    try t.expectEqual(Status.ok, goss_session_set_recording_policy(session, &in));
    var back: RecordingPolicy = undefined;
    try t.expectEqual(Status.ok, goss_session_recording_policy(session, &back));
    try t.expectEqual(@as(u32, 30_000), back.max_duration_ms);
    try t.expectEqual(@as(u32, 2), back.speed_preset);
    try t.expectEqual(@as(u32, 1), back.mic_muted);
    try t.expectEqual(Status.invalid_argument, goss_session_set_recording_policy(null, &in));
    try t.expectEqual(Status.invalid_argument, goss_session_recording_policy(session, null));
}

test "capture ui clamps to its envelope and set-get round-trips" {
    const out = normalizeCaptureUi(.{
        .grid_mode = 9,
        .level_indicator = 5,
        .shutter_mode = 8,
        .countdown_s = 10,
        .night_mode = 7,
        .screen_flash_mode = 6,
        .screen_flash_intensity = 4.0,
        .screen_flash_warmth = -1.0,
        .reserved0 = 5,
        .reserved1 = 6,
    });
    try t.expectEqual(@as(u32, 0), out.grid_mode); // out of range -> off
    try t.expectEqual(@as(u32, 1), out.level_indicator); // nonzero -> on
    try t.expectEqual(@as(u32, 0), out.shutter_mode);
    try t.expectEqual(@as(u32, 10), out.countdown_s); // free integer, unchanged
    try t.expectEqual(@as(u32, 0), out.night_mode);
    try t.expectEqual(@as(u32, 0), out.screen_flash_mode);
    try t.expectEqual(@as(f32, 1.0), out.screen_flash_intensity); // clamped to [0,1]
    try t.expectEqual(@as(f32, 0.0), out.screen_flash_warmth);
    try t.expectEqual(@as(u32, 0), out.reserved0);
    try t.expectEqual(@as(u32, 0), out.reserved1);

    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);
    var in: CaptureUiIntent = .{ .grid_mode = 2, .night_mode = 1, .screen_flash_intensity = 0.5 };
    try t.expectEqual(Status.ok, goss_session_set_capture_ui(session, &in));
    var back: CaptureUiIntent = undefined;
    try t.expectEqual(Status.ok, goss_session_capture_ui(session, &back));
    try t.expectEqual(@as(u32, 2), back.grid_mode);
    try t.expectEqual(@as(u32, 1), back.night_mode);
    try t.expectEqual(@as(f32, 0.5), back.screen_flash_intensity);
    try t.expectEqual(Status.invalid_argument, goss_session_set_capture_ui(null, &in));
    try t.expectEqual(Status.invalid_argument, goss_session_capture_ui(session, null));
}

test "engine and session lifecycle is leak-free" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    try t.expectEqual(@as(u16, 16), engine.texture_pool_capacity);

    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);
    try t.expectEqual(@as(u32, default_frame_budget_us), session.controller.config.budget_us);
}

test "report frame walks the ladder like the controller" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 4, .staging_pool_capacity = 4 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 16_000, .reserved = 0 });
    defer destroySession(session);

    try t.expectEqual(@as(c_int, 0), goss_session_degrade_level(session));
    var level: c_int = 0;
    for (0..64) |_| level = goss_session_report_frame(session, 40_000, 0);
    try t.expect(level > 0);
    try t.expectEqual(level, goss_session_degrade_level(session));

    const jumped = goss_session_report_frame(session, 8_000, 3);
    try t.expectEqual(@as(c_int, 4), jumped);
}

test "null arguments are rejected without crashing" {
    try t.expectEqual(Status.invalid_argument, goss_engine_create(null, null));
    try t.expectEqual(Status.invalid_argument, goss_session_create(null, null, null));
    goss_engine_destroy(null);
    goss_session_destroy(null);
    try t.expectEqual(@as(c_int, 0), goss_session_degrade_level(null));
    try t.expectEqual(Status.invalid_argument, goss_engine_init_renderer(null, null));
    try t.expectEqual(Status.invalid_argument, goss_engine_render_frame(null, null));
}

test "frame submission without a renderer reports it" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const desc: FrameDesc = .{
        .width = 1920,
        .height = 1080,
        .pixel_format = pixel_format_nv12,
        .color_standard = 1,
        .color_range = 0,
        .flags = frame_flag_mirror | (1 << frame_rotation_shift),
        .timestamp_us = 0,
    };
    const planes: FramePlanes = .{ .plane_count = 2, .reserved = 0, .planes = .{ 1, 2, 0 } };
    try t.expectEqual(Status.renderer_unavailable, goss_session_submit_frame(session, &desc, &planes));
    try t.expectEqual(Status.renderer_unavailable, goss_engine_render_frame(engine, session));
}

test "color conversion export writes the homogeneous matrix" {
    var out: [16]f32 = undefined;
    try t.expectEqual(Status.ok, goss_color_yuv_to_rgb(1, 0, &out));
    const direct = math.color.yuvToRgb(.bt709, .video).homogeneous();
    try t.expectEqual(direct.cols[0][0], out[0]);
    try t.expectEqual(direct.cols[3][2], out[14]);
    try t.expectEqual(Status.invalid_argument, goss_color_yuv_to_rgb(9, 0, &out));
    try t.expectEqual(Status.invalid_argument, goss_color_yuv_to_rgb(0, 9, null));
}

test "two-bone ik reaches a target, keeps bone lengths, and extends when out of reach" {
    const root = [3]f32{ 0, 0, 0 };
    const pole = [3]f32{ 0, 1, 0 };
    var mid: [3]f32 = undefined;
    var end: [3]f32 = undefined;

    // Reachable: unit bones, target 1.5 along +x, pole +y.
    const target = [3]f32{ 1.5, 0, 0 };
    try t.expectEqual(Status.ok, goss_solve_two_bone_ik(&root, 1.0, 1.0, &target, &pole, &mid, &end));
    try t.expectApproxEqAbs(@as(f32, 1.5), end[0], 0.001); // the end reaches the target
    try t.expectApproxEqAbs(@as(f32, 0), end[1], 0.001);
    try t.expect(mid[1] > 0.1); // the joint bends toward the pole
    const upper = @sqrt(mid[0] * mid[0] + mid[1] * mid[1] + mid[2] * mid[2]);
    try t.expectApproxEqAbs(@as(f32, 1.0), upper, 0.001); // upper bone length held
    const lx = end[0] - mid[0];
    const ly = end[1] - mid[1];
    const lz = end[2] - mid[2];
    try t.expectApproxEqAbs(@as(f32, 1.0), @sqrt(lx * lx + ly * ly + lz * lz), 0.001);

    // Out of reach: target 3 along +x, total reach 2 -> straight and extended.
    const far = [3]f32{ 3, 0, 0 };
    try t.expectEqual(Status.ok, goss_solve_two_bone_ik(&root, 1.0, 1.0, &far, &pole, &mid, &end));
    try t.expectApproxEqAbs(@as(f32, 2.0), end[0], 0.001);
    try t.expectApproxEqAbs(@as(f32, 1.0), mid[0], 0.001);
    try t.expect(@abs(mid[1]) < 0.001);

    // Guards: null pointers and non-positive lengths.
    try t.expectEqual(Status.invalid_argument, goss_solve_two_bone_ik(null, 1, 1, &target, &pole, &mid, &end));
    try t.expectEqual(Status.invalid_argument, goss_solve_two_bone_ik(&root, 0, 1, &target, &pole, &mid, &end));
    try t.expectEqual(Status.invalid_argument, goss_solve_two_bone_ik(&root, 1, 1, &target, &pole, null, &end));
}

test "rotation and mirror decode from the flags field" {
    const flags: u32 = frame_flag_mirror | (3 << frame_rotation_shift);
    try t.expectEqual(@as(u32, 3), (flags & frame_rotation_mask) >> frame_rotation_shift);
    try t.expect(flags & frame_flag_mirror != 0);
}

test "face tracking on a build without the inference stack refuses" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const bytes = [_]u8{ 1, 2, 3 };
    try t.expectEqual(Status.unsupported, goss_session_enable_face_tracking(session, &bytes, bytes.len, 0));
    var result: FaceResult = undefined;
    try t.expectEqual(Status.again, goss_session_face_result(session, &result));
    const desc: FrameDesc = .{ .width = 2, .height = 2, .pixel_format = 0, .color_standard = 0, .color_range = 0, .flags = 0, .timestamp_us = 0 };
    const planes = [_]u8{0} ** 8;
    try t.expectEqual(Status.again, goss_session_track_frame(session, &desc, &planes, 2, &planes, 2));
    goss_session_disable_face_tracking(session);
    try t.expectEqual(Status.invalid_argument, goss_session_face_result(session, null));
}

test "submitted faces round-trip by index and drop the ones no real face fills" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    // No faces submitted yet.
    var count: u32 = 99;
    try t.expectEqual(Status.ok, goss_session_face_count(session, &count));
    try t.expectEqual(@as(u32, 0), count);
    var one: FaceResult = undefined;
    try t.expectEqual(Status.invalid_argument, goss_session_face_result_at(session, 0, &one));

    // Two real faces, one too faint and one with no landmarks, in that order.
    var faces: [4]FaceResult = @splat(std.mem.zeroes(FaceResult));
    faces[0] = .{ .frame_serial = 10, .timestamp_us = 1, .presence = 0.9, .landmark_count_out = face.landmark_count, .landmarks = @splat(1.0), .blendshapes = @splat(0) };
    faces[1] = .{ .frame_serial = 20, .timestamp_us = 2, .presence = 0.2, .landmark_count_out = face.landmark_count, .landmarks = @splat(2.0), .blendshapes = @splat(0) };
    faces[2] = .{ .frame_serial = 30, .timestamp_us = 3, .presence = 0.95, .landmark_count_out = 0, .landmarks = @splat(3.0), .blendshapes = @splat(0) };
    faces[3] = .{ .frame_serial = 40, .timestamp_us = 4, .presence = 0.8, .landmark_count_out = face.landmark_count, .landmarks = @splat(4.0), .blendshapes = @splat(0) };
    try t.expectEqual(Status.ok, goss_session_submit_faces(session, &faces, 4));

    // Only faces 0 and 3 survive, compacted to slots 0 and 1 in order.
    try t.expectEqual(Status.ok, goss_session_face_count(session, &count));
    try t.expectEqual(@as(u32, 2), count);
    try t.expectEqual(Status.ok, goss_session_face_result_at(session, 0, &one));
    try t.expectEqual(@as(u64, 10), one.frame_serial);
    try t.expectEqual(@as(f32, 1.0), one.landmarks[0]);
    try t.expectEqual(Status.ok, goss_session_face_result_at(session, 1, &one));
    try t.expectEqual(@as(u64, 40), one.frame_serial);
    try t.expectEqual(@as(f32, 4.0), one.landmarks[0]);
    try t.expectEqual(Status.invalid_argument, goss_session_face_result_at(session, 2, &one));

    // A count past the cap is clamped to the buffer, never overruns it.
    var many: [8]FaceResult = @splat(faces[0]);
    try t.expectEqual(Status.ok, goss_session_submit_faces(session, &many, 8));
    try t.expectEqual(Status.ok, goss_session_face_count(session, &count));
    try t.expectEqual(@as(u32, face.max_faces), count);

    // Zero clears the multi-face path.
    try t.expectEqual(Status.ok, goss_session_submit_faces(session, null, 0));
    try t.expectEqual(Status.ok, goss_session_face_count(session, &count));
    try t.expectEqual(@as(u32, 0), count);

    // Null arguments are rejected, not crashes.
    try t.expectEqual(Status.invalid_argument, goss_session_submit_faces(session, null, 3));
    try t.expectEqual(Status.invalid_argument, goss_session_face_count(session, null));
    try t.expectEqual(Status.invalid_argument, goss_session_face_result_at(session, 0, null));
}

test "submitted bodies round-trip by index and drop the ones no real body fills" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var count: u32 = 99;
    try t.expectEqual(Status.ok, goss_session_body_count(session, &count));
    try t.expectEqual(@as(u32, 0), count);
    var one: PoseResult = undefined;
    try t.expectEqual(Status.invalid_argument, goss_session_body_result_at(session, 0, &one));

    // Two real bodies, one too faint and one with no landmarks, in that order.
    var bodies: [4]PoseResult = @splat(std.mem.zeroes(PoseResult));
    bodies[0] = .{ .frame_serial = 10, .timestamp_us = 1, .presence = 0.9, .landmark_count_out = pose.landmark_count, .landmarks = @splat(1.0), .visibilities = @splat(1), .presences = @splat(1) };
    bodies[1] = .{ .frame_serial = 20, .timestamp_us = 2, .presence = 0.2, .landmark_count_out = pose.landmark_count, .landmarks = @splat(2.0), .visibilities = @splat(1), .presences = @splat(1) };
    bodies[2] = .{ .frame_serial = 30, .timestamp_us = 3, .presence = 0.95, .landmark_count_out = 0, .landmarks = @splat(3.0), .visibilities = @splat(1), .presences = @splat(1) };
    bodies[3] = .{ .frame_serial = 40, .timestamp_us = 4, .presence = 0.8, .landmark_count_out = pose.landmark_count, .landmarks = @splat(4.0), .visibilities = @splat(1), .presences = @splat(1) };
    try t.expectEqual(Status.ok, goss_session_submit_bodies(session, &bodies, 4));

    // Only bodies 0 and 3 survive, compacted to slots 0 and 1 in order.
    try t.expectEqual(Status.ok, goss_session_body_count(session, &count));
    try t.expectEqual(@as(u32, 2), count);
    try t.expectEqual(Status.ok, goss_session_body_result_at(session, 0, &one));
    try t.expectEqual(@as(u64, 10), one.frame_serial);
    try t.expectEqual(@as(f32, 1.0), one.landmarks[0]);
    try t.expectEqual(Status.ok, goss_session_body_result_at(session, 1, &one));
    try t.expectEqual(@as(u64, 40), one.frame_serial);
    try t.expectEqual(Status.invalid_argument, goss_session_body_result_at(session, 2, &one));

    // A count past the cap is clamped to the buffer, never overruns it.
    var many: [8]PoseResult = @splat(bodies[0]);
    try t.expectEqual(Status.ok, goss_session_submit_bodies(session, &many, 8));
    try t.expectEqual(Status.ok, goss_session_body_count(session, &count));
    try t.expectEqual(@as(u32, pose.max_bodies), count);

    // Zero clears the multi-person path, and null arguments are rejected.
    try t.expectEqual(Status.ok, goss_session_submit_bodies(session, null, 0));
    try t.expectEqual(Status.ok, goss_session_body_count(session, &count));
    try t.expectEqual(@as(u32, 0), count);
    try t.expectEqual(Status.invalid_argument, goss_session_submit_bodies(session, null, 3));
    try t.expectEqual(Status.invalid_argument, goss_session_body_count(session, null));
    try t.expectEqual(Status.invalid_argument, goss_session_body_result_at(session, 0, null));
}

test "submitted depth stores the map, resamples on resize, and clears" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    try t.expect(depthAt(session, 0.5, 0.5) == null);
    const depth = [_]f32{ 1.0, 2.0, 3.0, 4.0 }; // 2x2 metres, row major
    try t.expectEqual(Status.ok, goss_session_submit_depth(session, &depth, 2, 2, 0.1, 5.0));
    try t.expectEqual(@as(u32, 2), session.depth_width);
    try t.expectApproxEqAbs(@as(f32, 1.0), depthAt(session, 0.0, 0.0).?, 0.001);
    try t.expectApproxEqAbs(@as(f32, 4.0), depthAt(session, 1.0, 1.0).?, 0.001);
    try t.expectApproxEqAbs(@as(f32, 5.0), session.depth_far, 0.001);

    // A differently sized frame reallocates rather than reading stale data.
    const wide = [_]f32{ 7.0, 8.0, 9.0 };
    try t.expectEqual(Status.ok, goss_session_submit_depth(session, &wide, 3, 1, 0.1, 5.0));
    try t.expectEqual(@as(u32, 3), session.depth_width);
    try t.expectApproxEqAbs(@as(f32, 9.0), depthAt(session, 1.0, 0.0).?, 0.001);

    // Zero size clears; a null buffer with a real size is rejected.
    try t.expectEqual(Status.ok, goss_session_submit_depth(session, null, 0, 0, 0, 0));
    try t.expect(depthAt(session, 0.5, 0.5) == null);
    try t.expectEqual(Status.invalid_argument, goss_session_submit_depth(session, null, 4, 4, 0, 1));
}

test "depthOcclusionMask hides content behind nearer real geometry" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    // Two pixels nearer than the plane, one beyond it, one invalid (zero).
    const depth = [_]f32{ 0.5, 2.0, 0.0, 3.0 };
    try t.expectEqual(Status.ok, goss_session_submit_depth(session, &depth, 2, 2, 0.1, 5.0));
    var mask: [4]f32 = undefined;
    try t.expectEqual(@as(usize, 4), depthOcclusionMask(session, 1.0, &mask));
    try t.expectEqual([4]f32{ 0, 1, 1, 1 }, mask); // 0.5 occludes; 2.0, invalid, 3.0 stay visible
}

test "face region guards its arguments and refuses with no tracked face" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var out: [3]f32 = undefined;
    // Null session/out and an unknown region are rejected, not crashes.
    try t.expectEqual(Status.invalid_argument, goss_session_face_region(null, 0, &out));
    try t.expectEqual(Status.invalid_argument, goss_session_face_region(session, 0, null));
    try t.expectEqual(Status.invalid_argument, goss_session_face_region(session, 99, &out));
    // A valid region with no worker reports again, never a stale point.
    try t.expectEqual(Status.again, goss_session_face_region(session, 0, &out));
}

test "upper-body pose mode suppresses the lower-body joints and keeps the hips" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var result: PoseResult = std.mem.zeroes(PoseResult);
    var i: usize = 0;
    while (i < pose.landmark_count) : (i += 1) {
        result.landmarks[i * 3] = 1;
        result.visibilities[i] = 1;
        result.presences[i] = 1;
    }

    // Off by default: every joint survives.
    applyPoseMode(session, &result);
    try t.expectEqual(@as(f32, 1), result.visibilities[27]); // an ankle stays

    // On: the hips (24) stay, the knee (25) and ankle (27) read absent.
    try t.expectEqual(Status.ok, goss_session_set_pose_upper_body(session, 1));
    applyPoseMode(session, &result);
    try t.expectEqual(@as(f32, 1), result.visibilities[24]);
    try t.expectEqual(@as(f32, 0), result.visibilities[25]);
    try t.expectEqual(@as(f32, 0), result.landmarks[27 * 3]);

    try t.expectEqual(Status.invalid_argument, goss_session_set_pose_upper_body(null, 1));
}

test "body joint guards its arguments and refuses with no tracked body" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var out: [3]f32 = undefined;
    // Null session/out and an unknown joint are rejected, not crashes.
    try t.expectEqual(Status.invalid_argument, goss_session_body_joint(null, 0, &out));
    try t.expectEqual(Status.invalid_argument, goss_session_body_joint(session, 0, null));
    try t.expectEqual(Status.invalid_argument, goss_session_body_joint(session, 99, &out));
    // A valid joint with no worker reports again, never a stale point.
    try t.expectEqual(Status.again, goss_session_body_joint(session, 0, &out));
}

test "hand joint guards its arguments and refuses with no tracked hand" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var out: [3]f32 = undefined;
    // Null session/out and an unknown joint are rejected, not crashes.
    try t.expectEqual(Status.invalid_argument, goss_session_hand_joint(null, 0, 0, &out));
    try t.expectEqual(Status.invalid_argument, goss_session_hand_joint(session, 0, 0, null));
    try t.expectEqual(Status.invalid_argument, goss_session_hand_joint(session, 0, 99, &out));
    // A valid joint with no worker reports again, never a stale point.
    try t.expectEqual(Status.again, goss_session_hand_joint(session, 0, 0, &out));
}

test "head euler decomposes identity to zero and the detector separates nod from shake" {
    const identity = headEuler(math.Mat4.identity);
    try t.expectApproxEqAbs(@as(f32, 0), identity.yaw, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0), identity.pitch, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0), identity.roll, 1e-5);

    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    // A nod: pitch swings there and back while yaw holds. Samples 30 ms apart.
    const swing = [_]f32{ 0.0, 0.15, 0.30, 0.15, 0.0, -0.05, 0.0 };
    for (swing) |p| {
        session.head_clock_us += 30_000;
        pushHeadSample(session, .{ .pitch = p, .yaw = 0, .roll = 0 });
    }
    const nod = detectHeadGestures(session);
    try t.expect(nod.nod);
    try t.expect(!nod.shake);

    // Advance well past the window so the nod samples age out, then a shake.
    session.head_clock_us += 2_000_000;
    for (swing) |y| {
        session.head_clock_us += 30_000;
        pushHeadSample(session, .{ .yaw = y, .pitch = 0, .roll = 0 });
    }
    const shake = detectHeadGestures(session);
    try t.expect(shake.shake);
    try t.expect(!shake.nod);
}

test "body action detectors separate a jump, a wave, sustained motion, and stillness" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const feed = struct {
        fn push(sess: *Session, hip_y: f32, lx: f32, up: bool) void {
            sess.body_clock_us += 33_000;
            pushBodySample(sess, .{ .hip_y = hip_y, .lwrist_x = lx, .lwrist_up = up, .t_us = sess.body_clock_us, .valid = true });
        }
    };

    // A hop: the hip rises past the amplitude (smaller y is higher) and returns.
    const hop = [_]f32{ 3.0, 3.0, 2.8, 2.6, 2.75, 2.9, 3.0, 3.0 };
    for (hop) |y| feed.push(session, y, 0.0, false);
    const j = detectBodyActions(session);
    try t.expect(j.jump);
    try t.expect(!j.dance);

    // A raised hand swinging side to side, the hip holding still.
    session.body_clock_us += 2_000_000;
    const xs = [_]f32{ 0.2, 0.45, 0.2, 0.45, 0.2, 0.45, 0.2 };
    for (xs) |x| feed.push(session, 3.0, x, true);
    const w = detectBodyActions(session);
    try t.expect(w.wave);
    try t.expect(!w.jump);

    // Sustained hip oscillation reads as dancing, not a single jump.
    session.body_clock_us += 2_000_000;
    const osc = [_]f32{ 3.0, 3.3, 3.0, 3.3, 3.0, 3.3, 3.0, 3.3 };
    for (osc) |y| feed.push(session, y, 0.0, false);
    const d = detectBodyActions(session);
    try t.expect(d.dance);
    try t.expect(!d.jump);

    // A still body is none of the three.
    session.body_clock_us += 2_000_000;
    for (0..8) |_| feed.push(session, 3.0, 0.2, false);
    const still = detectBodyActions(session);
    try t.expect(!still.jump and !still.wave and !still.dance);
}

test "beauty on a build without the effects engine refuses" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    try t.expectEqual(Status.unsupported, goss_session_enable_beauty(session, "res"));
    try t.expectEqual(Status.again, goss_session_set_beauty(session, 0, 0.5));
    var pixels = [_]u8{0} ** 16;
    try t.expectEqual(Status.again, goss_session_beautify_frame(session, &pixels, 2, 2, &pixels));
    goss_session_disable_beauty(session);
}

const test_lens_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.abi", "version": "1.0.0", "display_name": "ABI",
    \\  "engine_compat": ">=0.5", "capabilities": ["face"],
    \\  "parameters": [
    \\    {"name": "smooth_amount", "type": "float", "default": 0.25, "min": 0.0, "max": 1.0}
    \\  ],
    \\  "nodes": [
    \\    {"id": "reshape", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {"thin_face": "$smooth_amount"}}
    \\  ],
    \\  "triggers": [
    \\    {"when": "face.blendshape('jawOpen') > 0.6", "action": {"kind": "param_ramp", "target": "smooth_amount", "to": 1.0, "duration_ms": 200}}
    \\  ]
    \\}
;

test "activating a lens splices its nodes and applies its default effect values" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    try t.expectEqual(Status.ok, goss_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));
    try t.expect(session.active_lens != null);
    try t.expectEqual(@as(usize, 1), session.active_lens.?.nodes.len);
    try t.expectEqual(@as(f32, 0.25), session.active_lens.?.param_values[0]);
    // No beauty chain enabled: applying effect values is a silent no-op,
    // not an error - activation still succeeds.

    goss_session_deactivate_lens(session);
    try t.expect(session.active_lens == null);
    // Only the camera source remains scheduled - the lens node was
    // unspliced, not just detached.
    try t.expectEqual(@as(usize, 1), (try session.lens_graph.executionOrder()).len);
}

test "activating a second lens replaces the first, and invalid input is rejected cleanly" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    try t.expectEqual(Status.ok, goss_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));
    try t.expectEqual(Status.ok, goss_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));
    try t.expectEqual(@as(usize, 1), session.active_lens.?.nodes.len);

    const garbage = "not a manifest";
    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens(session, garbage.ptr, garbage.len));
    // A failed activation does not disturb the previously active lens.
    try t.expect(session.active_lens != null);

    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens(null, garbage.ptr, garbage.len));
    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens(session, null, 0));

    goss_session_deactivate_lens(session);
    goss_session_deactivate_lens(session); // idempotent
}

test "ticking with no active lens reports again; ticking a firing trigger advances its ramp" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var closed_signals = std.mem.zeroes(LensSignals);
    try t.expectEqual(Status.again, goss_session_tick_lens(session, 8_333, &closed_signals));

    try t.expectEqual(Status.ok, goss_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));

    var open_signals = std.mem.zeroes(LensSignals);
    open_signals.has_face = true;
    const jaw_open = face.blendshapeIndex("jawOpen").?;
    open_signals.blendshapes[jaw_open] = 0.9;

    try t.expectEqual(Status.ok, goss_session_tick_lens(session, 8_333, &open_signals));
    try t.expect(session.active_lens.?.param_values[0] > 0.25);
    try t.expect(session.active_lens.?.param_values[0] < 1.0);

    try t.expectEqual(Status.invalid_argument, goss_session_tick_lens(session, 8_333, null));
}

test "a script node drives a parameter from a signal" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const manifest_json =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [{"name": "intensity", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [{"id": "drive", "type": "script", "params": {},
        \\   "source": "function update(lens) { lens.params.intensity = lens.signals.face_present > 0.5 ? 0.8 : 0.2; }"}],
        \\ "triggers": []}
    ;
    try t.expectEqual(Status.ok, goss_session_activate_lens(session, manifest_json.ptr, manifest_json.len));

    var present = std.mem.zeroes(LensSignals);
    present.has_face = true;
    try t.expectEqual(Status.ok, goss_session_tick_lens(session, 16_000, &present));

    var v: f32 = -1;
    try t.expectEqual(Status.ok, goss_session_parameter_value(session, "intensity", "intensity".len, &v));
    try t.expectApproxEqAbs(@as(f32, 0.8), v, 1e-6);
}

test "activating a lens from a real bundle directory splices it, and a build without a renderer creates no shader programs" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const bundle_path = "lenses/reference/shader-tint";
    try t.expectEqual(Status.ok, goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len));
    try t.expect(session.active_lens != null);
    try t.expectEqual(@as(usize, 1), session.active_lens.?.nodes.len);
    // This build has no compiled render stack (the stub always reports
    // RendererUnavailable) - the lens still activates cleanly, its
    // shader.pass node just has no program, exactly the degradation
    // goss_session_set_beauty already establishes for a missing engine.
    try t.expectEqual(@as(usize, 0), session.shader_programs.count());
    // The chain's structure is still known even though nothing in it
    // has a resource yet - that's what lets a lut.pass node's load
    // land on some later frame without needing to reactivate.
    try t.expectEqual(@as(usize, 1), session.chain_order.len);
    try t.expectEqual(runtime.PassKind.shader, session.chain_order[0].kind);

    goss_session_deactivate_lens(session);
    try t.expect(session.active_lens == null);
    try t.expectEqual(@as(usize, 0), session.shader_programs.count());
    try t.expectEqual(@as(usize, 0), session.chain_order.len);

    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens_from_directory(null, bundle_path.ptr, bundle_path.len));
    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens_from_directory(session, null, 0));
    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens_from_directory(session, bundle_path.ptr, 0));
}

const lut_pass_bundle_manifest =
    \\{"glf":"1.0","id":"com.example.lut","version":"1.0.0","display_name":"LUT",
    \\ "engine_compat":">=0.5","capabilities":[],"parameters":[],
    \\ "nodes":[{"id":"warm-lut","type":"lut.pass","inputs":{"frame":"camera"},"params":{}}],
    \\ "triggers":[]}
;

// The same 8x8 checker PNG adapters/image and adapters/asset's own
// tests decode - real bytes, so this proves the real background thread
// and real lodepng decode, not a mock standing in for either.
const lut_checker_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x08, 0x06, 0x00, 0x00, 0x00, 0xc4, 0x0f, 0xbe,
    0x8b, 0x00, 0x00, 0x00, 0x19, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0x8f, 0x0e, 0x18,
    0x18, 0x50, 0x30, 0x03, 0x3d, 0x14, 0xa0, 0x09, 0x60, 0xa8, 0xa7, 0xbd, 0x02, 0x00, 0xa3, 0xc6,
    0xbf, 0x41, 0x50, 0xd7, 0xe9, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
    0x60, 0x82,
};

test "activating a lens with a lut.pass node loads its LUT image for real, off the calling thread" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = lut_pass_bundle_manifest });
    try tmp.dir.createDirPath(t.io, "assets");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "assets/warm-lut.png", .data = &lut_checker_png });

    var path_buf: [64]u8 = undefined;
    const bundle_path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    try t.expectEqual(Status.ok, goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len));
    try t.expectEqual(@as(usize, 1), session.lut_loaders.count());
    try t.expectEqual(@as(usize, 1), session.chain_order.len);
    try t.expectEqual(runtime.PassKind.lut, session.chain_order[0].kind);

    var loader_it = session.lut_loaders.valueIterator();
    const loader = loader_it.next().?.*;
    var decoded: ?image.Image = null;
    var spins: u32 = 0;
    while (decoded == null and spins < 1_000_000) : (spins += 1) {
        decoded = loader.take();
        if (decoded == null) std.atomic.spinLoopHint();
    }
    const got = decoded orelse return error.TestUnexpectedResult;
    defer t.allocator.free(got.rgba);
    try t.expectEqual(@as(u32, 8), got.width);
    try t.expectEqual(@as(u32, 8), got.height);
    try t.expect(!loader.hasFailed());

    // A load that finished but was never polled through
    // goss_engine_render_frame (this build has no compiled render stack)
    // is still cleaned up correctly on deactivation, not leaked or
    // double-freed.
    goss_session_deactivate_lens(session);
    try t.expectEqual(@as(usize, 0), session.lut_loaders.count());
}

const blend_pass_bundle_manifest =
    \\{"glf":"1.0","id":"com.example.blend","version":"1.0.0","display_name":"Blend",
    \\ "engine_compat":">=0.5","capabilities":["segmentation"],"parameters":[],
    \\ "nodes":[{"id":"beach","type":"blend.pass","inputs":{"frame":"camera"},"params":{}}],
    \\ "triggers":[]}
;

test "activating a lens with a blend.pass node loads its background image for real, off the calling thread" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = blend_pass_bundle_manifest });
    try tmp.dir.createDirPath(t.io, "assets");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "assets/beach.png", .data = &lut_checker_png });

    var path_buf: [64]u8 = undefined;
    const bundle_path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    try t.expectEqual(Status.ok, goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len));
    try t.expectEqual(@as(usize, 1), session.blend_loaders.count());
    try t.expectEqual(@as(usize, 1), session.chain_order.len);
    try t.expectEqual(runtime.PassKind.blend, session.chain_order[0].kind);

    var loader_it = session.blend_loaders.valueIterator();
    const loader = loader_it.next().?.*;
    var decoded: ?image.Image = null;
    var spins: u32 = 0;
    while (decoded == null and spins < 1_000_000) : (spins += 1) {
        decoded = loader.take();
        if (decoded == null) std.atomic.spinLoopHint();
    }
    const got = decoded orelse return error.TestUnexpectedResult;
    defer t.allocator.free(got.rgba);
    try t.expectEqual(@as(u32, 8), got.width);
    try t.expectEqual(@as(u32, 8), got.height);
    try t.expect(!loader.hasFailed());

    goss_session_deactivate_lens(session);
    try t.expectEqual(@as(usize, 0), session.blend_loaders.count());
}

test "the ar brush projects a world stroke to screen and drops points behind the camera" {
    var ws = wboard.WorldStroke{ .count = 2, .mode = 3, .color = .{ 1, 1, 1, 1 }, .width = 0.02 };
    ws.points[0] = .{ .x = 0, .y = 0, .z = 0 };
    ws.points[1] = .{ .x = 0.5, .y = -0.5, .z = 0 };
    var out: stroke.Stroke = undefined;
    projectWorldStroke(math.Mat4.identity, &ws, &out);
    try t.expectEqual(@as(u16, 2), out.count);
    // (0,0,0) -> screen centre; (0.5,-0.5,0) -> (0.75, 0.75) with y measured down.
    try t.expectApproxEqAbs(@as(f32, 0.5), out.points[0].x, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5), out.points[0].y, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.75), out.points[1].x, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.75), out.points[1].y, 1e-6);
    // Neon mode biases the width and alpha the same way the screen brush does.
    try t.expectApproxEqAbs(@as(f32, 0.04), out.width, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.6), out.color[3], 1e-6);

    // A projection that puts the points behind the camera drops them all.
    var vp = math.Mat4.identity;
    vp.cols[2][3] = -1.0; // w = -z
    vp.cols[3][3] = 0.0;
    var ws2 = wboard.WorldStroke{ .count = 2, .mode = 0, .color = .{ 1, 1, 1, 1 }, .width = 0.01 };
    ws2.points[0] = .{ .x = 0, .y = 0, .z = 1 };
    ws2.points[1] = .{ .x = 0, .y = 0, .z = 2 };
    var out2: stroke.Stroke = undefined;
    projectWorldStroke(vp, &ws2, &out2);
    try t.expectEqual(@as(u16, 0), out2.count);
}
